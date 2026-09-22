import Foundation
import LingXiPlatform
import LingXiProtocol

public protocol CredentialStore: Sendable {
    func secret(for reference: CredentialRef) async throws -> String?
    func setSecret(_ secret: String, for reference: CredentialRef) async throws
    func removeSecret(for reference: CredentialRef) async throws
}

/// Application-level encrypted vault. The caller supplies the passphrase; no platform secret service is required.
public actor FileCredentialStore: CredentialStore {
    public let vaultURL: URL
    private let backupURL: URL
    private let dataRoot: URL
    private let permissions: any FilePermissionAdapter
    private let passphrase: String?
    private let kdfIterations: Int
    private var cachedKey: (salt: Data, key: Data)?

    public let isMemoryOnly: Bool
    private var memoryStore: [String: String] = [:]

    /// - Parameter iterations: PBKDF2 rounds for vaults this instance writes. It defaults to the
    ///   production cost and cannot be lowered below the floor the reader already enforces, so the
    ///   only caller that can get a cheap vault is one that asks for it explicitly -- tests, where a
    ///   debug-binary derivation costs seconds per instance and a whole CI chunk with it.
    public init(
        dataRoot: URL,
        passphrase: String? = nil,
        isMemoryOnly: Bool = false,
        iterations: Int? = nil,
        permissions: any FilePermissionAdapter = PlatformFilePermissionAdapter()
    ) throws {
        if let iterations, iterations < 100_000 {
            throw ConfigurationValidationError(path: "$kdf.iterations", reason: "PBKDF2 iterations must be >= 100000")
        }
        self.dataRoot = dataRoot.standardizedFileURL
        self.vaultURL = self.dataRoot.appendingPathComponent("credentials.vault")
        self.backupURL = self.dataRoot.appendingPathComponent("credentials.vault.v1-migration-backup")
        self.permissions = permissions
        self.passphrase = passphrase?.isEmpty == false ? passphrase : nil
        self.kdfIterations = iterations ?? Self.kdfIterations
        self.isMemoryOnly = isMemoryOnly
        if !isMemoryOnly {
            try FileManager.default.createDirectory(at: self.dataRoot, withIntermediateDirectories: true)
            try permissions.secureDirectory(at: self.dataRoot)
            // Purge any insecure legacy .master_key files
            let legacyKeyFile = self.dataRoot.appendingPathComponent(".master_key")
            if FileManager.default.fileExists(atPath: legacyKeyFile.path) {
                try? FileManager.default.removeItem(at: legacyKeyFile)
            }
            if FileManager.default.fileExists(atPath: vaultURL.path) {
                try permissions.secureFile(at: vaultURL)
            }
        }
    }

    public func secret(for reference: CredentialRef) throws -> String? {
        if isMemoryOnly {
            return memoryStore[reference.rawValue]
        }
        return try load()[reference.rawValue]
    }

    public func setSecret(_ secret: String, for reference: CredentialRef) throws {
        try requireReference(reference)
        if isMemoryOnly {
            memoryStore[reference.rawValue] = secret
            return
        }
        var values = try load()
        values[reference.rawValue] = secret
        try write(values, to: vaultURL)
    }

    public func removeSecret(for reference: CredentialRef) throws {
        if isMemoryOnly {
            memoryStore.removeValue(forKey: reference.rawValue)
            return
        }
        var values = try load()
        values.removeValue(forKey: reference.rawValue)
        try write(values, to: vaultURL)
    }

    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else { return [:] }
        let root = try readRoot(from: vaultURL)
        switch try vaultVersion(in: root) {
        case 1:
            let values = try legacyCredentials(in: root)
            guard !FileManager.default.fileExists(atPath: backupURL.path) else {
                throw ConfigurationValidationError(path: "$", reason: "credentials.vault v1 migration backup already exists")
            }
            try write(values, to: backupURL)
            try write(values, to: vaultURL)
            return values
        case 2:
            return try decryptCredentials(in: root)
        default:
            throw ConfigurationValidationError(path: "$.version", reason: "unsupported credentials.vault version")
        }
    }

    private func readRoot(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConfigurationValidationError(path: "$", reason: "expected object")
            }
            return root
        } catch let error as ConfigurationValidationError {
            throw error
        } catch {
            throw ConfigurationValidationError(path: "$", reason: "invalid credentials.vault JSON")
        }
    }

    private func vaultVersion(in root: [String: Any]) throws -> Int {
        guard let version = root["version"] as? Int else {
            throw ConfigurationValidationError(path: "$.version", reason: "expected integer")
        }
        return version
    }

    private func legacyCredentials(in root: [String: Any]) throws -> [String: String] {
        try requireOnly(root, allowed: ["version", "credentials"])
        guard let credentials = root["credentials"] as? [String: Any] else {
            throw ConfigurationValidationError(path: "$.credentials", reason: "expected object")
        }
        var values: [String: String] = [:]
        for (key, value) in credentials {
            guard !key.isEmpty else {
                throw ConfigurationValidationError(path: "$.credentials", reason: "credential reference must not be empty")
            }
            guard let secret = value as? String else {
                throw ConfigurationValidationError(path: "$.credentials.\(key)", reason: "expected string")
            }
            values[key] = secret
        }
        return values
    }

    private func decryptCredentials(in root: [String: Any]) throws -> [String: String] {
        try requireOnly(root, allowed: ["version", "kdf", "encryption"])
        guard let kdf = root["kdf"] as? [String: Any], let encryption = root["encryption"] as? [String: Any] else {
            throw ConfigurationValidationError(path: "$", reason: "expected encrypted vault metadata")
        }
        try requireOnly(kdf, allowed: ["name", "iterations", "salt"])
        try requireOnly(encryption, allowed: ["name", "ciphertext"])
        guard kdf["name"] as? String == "PBKDF2-HMAC-SHA256",
              let iterations = kdf["iterations"] as? NSNumber,
              !(iterations is Bool),
              iterations.doubleValue == Double(iterations.intValue),
              iterations.intValue >= 100_000,
              let saltText = kdf["salt"] as? String,
              let salt = Data(base64Encoded: saltText),
              salt.count >= 16,
              encryption["name"] as? String == "AES-256-GCM",
              let ciphertextText = encryption["ciphertext"] as? String,
              let combined = Data(base64Encoded: ciphertextText)
        else {
            throw ConfigurationValidationError(path: "$", reason: "invalid encrypted vault metadata")
        }
        do {
            let key = try encryptionKey(salt: salt, iterations: iterations.intValue)
            let plaintext = try LingXiPlatform.crypto.openAESGCM(combined: combined, keyData: key, authenticating: Self.associatedData)
            guard let values = try JSONSerialization.jsonObject(with: plaintext) as? [String: String] else {
                throw ConfigurationValidationError(path: "$.credentials", reason: "expected object")
            }
            for key in values.keys where key.isEmpty {
                throw ConfigurationValidationError(path: "$.credentials", reason: "credential reference must not be empty")
            }
            return values
        } catch let error as ConfigurationValidationError {
            throw error
        } catch {
            throw ConfigurationValidationError(path: "$", reason: "unable to decrypt credentials.vault")
        }
    }

    private func write(_ values: [String: String], to url: URL) throws {
        let salt = LingXiPlatform.secureStorage.generateSecureRandomBytes(count: 16)
        let key = try encryptionKey(salt: salt, iterations: kdfIterations)
        let plaintext = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .withoutEscapingSlashes])
        let combined = try LingXiPlatform.crypto.sealAESGCM(plaintext: plaintext, keyData: key, authenticating: Self.associatedData)
        let vault = EncryptedVault(
            version: 2,
            kdf: .init(name: "PBKDF2-HMAC-SHA256", iterations: kdfIterations, salt: salt.base64EncodedString()),
            encryption: .init(name: "AES-256-GCM", ciphertext: combined.base64EncodedString())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(vault)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try permissions.secureFile(at: url)
    }

    private func encryptionKey(salt: Data, iterations: Int) throws -> Data {
        let secretPassphrase: String
        if let passphrase {
            secretPassphrase = passphrase
        } else if let envPass = ProcessInfo.processInfo.environment["LINGXI_CREDENTIALS_PASSPHRASE"], !envPass.isEmpty {
            secretPassphrase = envPass
        } else {
            throw ConfigurationValidationError(path: "$", reason: "Passphrase is required for FileCredentialStore (set via parameter or LINGXI_CREDENTIALS_PASSPHRASE). Pseudo-encryption with local key file is strictly prohibited.")
        }
        if let cachedKey, cachedKey.salt == salt { return cachedKey.key }
        let derived = LingXiPlatform.crypto.derivePBKDF2(passphrase: secretPassphrase, salt: salt, iterations: iterations)
        cachedKey = (salt, derived)
        return derived
    }

    private func requireOnly(_ object: [String: Any], allowed: Set<String>) throws {
        for key in object.keys where !allowed.contains(key) {
            throw ConfigurationValidationError(path: "$.\(key)", reason: "unknown property")
        }
    }

    private func requireReference(_ reference: CredentialRef) throws {
        guard !reference.rawValue.isEmpty else {
            throw ConfigurationValidationError(path: "$.credentials", reason: "credential reference must not be empty")
        }
    }

    private static let kdfIterations = 600_000
    private static let associatedData = Data("LingXiAgent credentials.vault v2".utf8)

    private struct EncryptedVault: Codable {
        let version: Int
        let kdf: KDF
        let encryption: Encryption

        struct KDF: Codable {
            let name: String
            let iterations: Int
            let salt: String
        }

        struct Encryption: Codable {
            let name: String
            let ciphertext: String
        }
    }
}
