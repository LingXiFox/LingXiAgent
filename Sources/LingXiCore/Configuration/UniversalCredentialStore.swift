import CoreFoundation
import CryptoKit
import Foundation
import LingXiProtocol

/// Autonomous vault key provider that manages high-entropy protected local keys
/// without relying on operating-system-specific keychains or secret services.
public struct AutonomousVaultKeyProvider: Sendable {
    public let keyURL: URL
    private let permissions: any FilePermissionAdapter

    public init(dataRoot: URL, permissions: any FilePermissionAdapter = PlatformFilePermissionAdapter()) {
        self.keyURL = dataRoot.standardizedFileURL.appendingPathComponent(".vault_key")
        self.permissions = permissions
    }

    /// Resolves or generates the protected symmetric key using strict POSIX file isolation
    /// and identity-bound HKDF key derivation.
    public func resolveKey() throws -> SymmetricKey {
        let rawEntropy: Data
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: keyURL.path) {
            // Re-enforce strict owner-only permissions (0o600)
            try permissions.secureFile(at: keyURL)
            rawEntropy = try Data(contentsOf: keyURL)
            guard rawEntropy.count >= 32 else {
                throw ConfigurationValidationError(path: "$.vault_key", reason: "Corrupted vault key: insufficient entropy")
            }
        } else {
            // Generate 32 bytes (256-bit) cryptographically secure random entropy
            var bytes = [UInt8](repeating: 0, count: 32)
            #if canImport(Security)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            if status != errSecSuccess {
                bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
            }
            #else
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
            #endif

            let freshEntropy = Data(bytes)
            try freshEntropy.write(to: keyURL, options: .atomic)
            try permissions.secureFile(at: keyURL)
            rawEntropy = freshEntropy
        }

        // Bind raw entropy with current user identity context via HKDF
        let identity = NSUserName().data(using: .utf8) ?? Data("lingxi-user".utf8)
        let salt = Data("LingXiUniversalVaultSalt-v1".utf8)
        let info = Data("LingXiAgent.UniversalVaultKey.HKDF.AES-256-GCM".utf8)

        var combinedIKM = rawEntropy
        combinedIKM.append(identity)

        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: combinedIKM), salt: salt)
        let derivedKey = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: info, outputByteCount: 32)
        return derivedKey
    }
}

/// Cross-platform autonomous credential vault supporting AES-256-GCM authenticated encryption,
/// PBKDF2 passphrase derivation, and autonomous protected key storage.
public actor UniversalCredentialStore: CredentialStore {
    public let vaultURL: URL
    private let dataRoot: URL
    private let permissions: any FilePermissionAdapter
    private let passphrase: String?
    private let keyProvider: AutonomousVaultKeyProvider
    public let isMemoryOnly: Bool

    private var memoryVault: [String: String] = [:]
    private var cachedKey: SymmetricKey?
    private var isLoaded: Bool = false

    public init(
        dataRoot: URL,
        passphrase: String? = nil,
        isMemoryOnly: Bool = false,
        permissions: any FilePermissionAdapter = PlatformFilePermissionAdapter()
    ) throws {
        self.dataRoot = dataRoot.standardizedFileURL
        self.vaultURL = self.dataRoot.appendingPathComponent("credentials.vault")
        self.permissions = permissions
        self.passphrase = passphrase?.isEmpty == false ? passphrase : nil
        self.keyProvider = AutonomousVaultKeyProvider(dataRoot: self.dataRoot, permissions: permissions)
        self.isMemoryOnly = isMemoryOnly

        if !isMemoryOnly {
            try FileManager.default.createDirectory(at: self.dataRoot, withIntermediateDirectories: true)
            try permissions.secureDirectory(at: self.dataRoot)

            // Purge any legacy insecure master_key file
            let legacyKeyFile = self.dataRoot.appendingPathComponent(".master_key")
            if FileManager.default.fileExists(atPath: legacyKeyFile.path) {
                try? FileManager.default.removeItem(at: legacyKeyFile)
            }
            if FileManager.default.fileExists(atPath: vaultURL.path) {
                try permissions.secureFile(at: vaultURL)
            }
        }
    }

    public func secret(for reference: CredentialRef) async throws -> String? {
        if isMemoryOnly {
            return memoryVault[reference.rawValue]
        }
        if !isLoaded {
            try loadVault()
        }
        return memoryVault[reference.rawValue]
    }

    public func setSecret(_ secret: String, for reference: CredentialRef) async throws {
        guard !reference.rawValue.isEmpty else {
            throw ConfigurationValidationError(path: "$.credentials", reason: "credential reference must not be empty")
        }
        if isMemoryOnly {
            memoryVault[reference.rawValue] = secret
            return
        }
        if !isLoaded {
            try loadVault()
        }
        memoryVault[reference.rawValue] = secret
        try saveVault()
    }

    public func removeSecret(for reference: CredentialRef) async throws {
        if isMemoryOnly {
            memoryVault.removeValue(forKey: reference.rawValue)
            return
        }
        if !isLoaded {
            try loadVault()
        }
        guard memoryVault.removeValue(forKey: reference.rawValue) != nil else { return }
        try saveVault()
    }

    /// Verifies that the store can be unlocked and its authenticated encryption verified.
    public func verifyStoreIntegrity() throws -> Bool {
        if isMemoryOnly { return true }
        guard FileManager.default.fileExists(atPath: vaultURL.path) else { return true }
        _ = try loadVault()
        return true
    }

    // MARK: - Internal Vault Management

    private func loadVault() throws {
        guard !isMemoryOnly else { return }
        guard FileManager.default.fileExists(atPath: vaultURL.path) else {
            self.memoryVault = [:]
            self.isLoaded = true
            return
        }

        let data = try Data(contentsOf: vaultURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurationValidationError(path: "$", reason: "invalid credentials.vault JSON")
        }

        guard let version = root["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == Double(version.intValue)
        else {
            throw ConfigurationValidationError(path: "$.version", reason: "expected integer version")
        }

        switch version.intValue {
        case 1:
            // Legacy plaintext credentials migration
            guard let credentials = root["credentials"] as? [String: String] else {
                throw ConfigurationValidationError(path: "$.credentials", reason: "expected string dictionary")
            }
            self.memoryVault = credentials
            self.isLoaded = true
            // Immediately migrate to version 2 encrypted vault
            try saveVault()

        case 2:
            guard let kdf = root["kdf"] as? [String: Any],
                  let encryption = root["encryption"] as? [String: Any]
            else {
                throw ConfigurationValidationError(path: "$", reason: "expected encrypted vault metadata")
            }

            guard encryption["name"] as? String == "AES-256-GCM",
                  let ciphertextText = encryption["ciphertext"] as? String,
                  let combined = Data(base64Encoded: ciphertextText)
            else {
                throw ConfigurationValidationError(path: "$.encryption", reason: "unsupported or corrupted encryption payload")
            }

            let key: SymmetricKey
            if let saltText = kdf["salt"] as? String,
               let salt = Data(base64Encoded: saltText),
               let iterations = (kdf["iterations"] as? NSNumber)?.intValue,
               iterations >= 100_000
            {
                key = try resolveKey(salt: salt, iterations: iterations)
            } else {
                key = try resolveKey(salt: Data(), iterations: 0)
            }

            do {
                let box = try AES.GCM.SealedBox(combined: combined)
                let plaintext = try AES.GCM.open(box, using: key, authenticating: Self.associatedData)
                guard let values = try JSONSerialization.jsonObject(with: plaintext) as? [String: String] else {
                    throw ConfigurationValidationError(path: "$.credentials", reason: "expected object")
                }
                self.memoryVault = values
                self.isLoaded = true
            } catch {
                throw ConfigurationValidationError(
                    path: "$",
                    reason: "unable to decrypt credentials.vault: key verification failed or data corrupted"
                )
            }

        default:
            throw ConfigurationValidationError(path: "$.version", reason: "unsupported credentials.vault version \(version.intValue)")
        }
    }

    private func saveVault() throws {
        guard !isMemoryOnly else { return }

        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let key = try resolveKey(salt: salt, iterations: Self.kdfIterations)
        let plaintext = try JSONSerialization.data(withJSONObject: memoryVault, options: [.sortedKeys, .withoutEscapingSlashes])

        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Self.associatedData)
        guard let combined = sealed.combined else {
            throw ConfigurationValidationError(path: "$", reason: "unable to encrypt credentials.vault")
        }

        let vaultData: [String: Any] = [
            "version": 2,
            "kdf": [
                "name": "PBKDF2-HMAC-SHA256",
                "iterations": Self.kdfIterations,
                "salt": salt.base64EncodedString()
            ],
            "encryption": [
                "name": "AES-256-GCM",
                "ciphertext": combined.base64EncodedString()
            ]
        ]

        let serialized = try JSONSerialization.data(withJSONObject: vaultData, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        var finalData = serialized
        finalData.append(0x0A)
        try finalData.write(to: vaultURL, options: .atomic)
        try permissions.secureFile(at: vaultURL)
    }

    private func resolveKey(salt: Data, iterations: Int) throws -> SymmetricKey {
        if let cached = cachedKey {
            return cached
        }

        let explicitPass = passphrase
        let envPass = ProcessInfo.processInfo.environment["LINGXI_CREDENTIALS_PASSPHRASE"]
        let effectivePassphrase = explicitPass ?? (envPass?.isEmpty == false ? envPass : nil)

        if let pass = effectivePassphrase {
            // Tier 1: Derive key via PBKDF2 with passphrase
            let password = SymmetricKey(data: Data(pass.utf8))
            var input = salt.isEmpty ? Data("LingXiDefaultSalt".utf8) : salt
            input.append(contentsOf: [0, 0, 0, 1])
            var block = Data(HMAC<SHA256>.authenticationCode(for: input, using: password))
            var derived = [UInt8](block)
            let iterCount = max(iterations, Self.kdfIterations)
            if iterCount > 1 {
                for _ in 1..<iterCount {
                    block = Data(HMAC<SHA256>.authenticationCode(for: block, using: password))
                    for index in derived.indices { derived[index] ^= block[index] }
                }
            }
            let key = SymmetricKey(data: Data(derived))
            self.cachedKey = key
            return key
        } else {
            // Tier 2: Autonomous protected machine-bound key
            let key = try keyProvider.resolveKey()
            self.cachedKey = key
            return key
        }
    }

    private static let kdfIterations = 100_000
    private static let associatedData = Data("LingXiAgent credentials.vault v2".utf8)
}
