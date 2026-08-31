import CoreFoundation
import CryptoKit
import Foundation

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
    private var cachedKey: (salt: Data, key: SymmetricKey)?

    public init(dataRoot: URL, passphrase: String? = nil, permissions: any FilePermissionAdapter = PlatformFilePermissionAdapter()) throws {
        self.dataRoot = dataRoot.standardizedFileURL
        vaultURL = self.dataRoot.appendingPathComponent("credentials.vault")
        backupURL = self.dataRoot.appendingPathComponent("credentials.vault.v1-migration-backup")
        self.permissions = permissions
        self.passphrase = passphrase?.isEmpty == false ? passphrase : nil
        try FileManager.default.createDirectory(at: self.dataRoot, withIntermediateDirectories: true)
        try permissions.secureDirectory(at: self.dataRoot)
        if FileManager.default.fileExists(atPath: vaultURL.path) {
            try permissions.secureFile(at: vaultURL)
        }
    }

    public func secret(for reference: CredentialRef) throws -> String? {
        try load()[reference.rawValue]
    }

    public func setSecret(_ secret: String, for reference: CredentialRef) throws {
        try requireReference(reference)
        var values = try load()
        values[reference.rawValue] = secret
        try write(values, to: vaultURL)
    }

    public func removeSecret(for reference: CredentialRef) throws {
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
        guard let version = root["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == Double(version.intValue)
        else {
            throw ConfigurationValidationError(path: "$.version", reason: "expected integer")
        }
        return version.intValue
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
              CFGetTypeID(iterations) != CFBooleanGetTypeID(),
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
            let box = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(box, using: try encryptionKey(salt: salt, iterations: iterations.intValue), authenticating: Self.associatedData)
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
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let key = try encryptionKey(salt: salt, iterations: Self.kdfIterations)
        let plaintext = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .withoutEscapingSlashes])
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Self.associatedData)
        guard let combined = sealed.combined else {
            throw ConfigurationValidationError(path: "$", reason: "unable to encrypt credentials.vault")
        }
        let vault = EncryptedVault(
            version: 2,
            kdf: .init(name: "PBKDF2-HMAC-SHA256", iterations: Self.kdfIterations, salt: salt.base64EncodedString()),
            encryption: .init(name: "AES-256-GCM", ciphertext: combined.base64EncodedString())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(vault)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try permissions.secureFile(at: url)
    }

    private func encryptionKey(salt: Data, iterations: Int) throws -> SymmetricKey {
        guard let passphrase else {
            throw ConfigurationValidationError(path: "$", reason: "LINGXI_CREDENTIALS_PASSPHRASE is required for credentials.vault")
        }
        if let cachedKey, cachedKey.salt == salt { return cachedKey.key }
        let password = SymmetricKey(data: Data(passphrase.utf8))
        var input = salt
        input.append(contentsOf: [0, 0, 0, 1])
        var block = Data(HMAC<SHA256>.authenticationCode(for: input, using: password))
        var derived = [UInt8](block)
        if iterations > 1 {
            for _ in 1..<iterations {
                block = Data(HMAC<SHA256>.authenticationCode(for: block, using: password))
                for index in derived.indices { derived[index] ^= block[index] }
            }
        }
        let key = SymmetricKey(data: Data(derived))
        cachedKey = (salt, key)
        return key
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
