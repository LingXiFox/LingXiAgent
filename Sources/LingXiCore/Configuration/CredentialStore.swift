import CoreFoundation
import Foundation

public protocol CredentialStore: Sendable {
    func secret(for reference: CredentialRef) async throws -> String?
    func setSecret(_ secret: String, for reference: CredentialRef) async throws
    func removeSecret(for reference: CredentialRef) async throws
}

/// Plain file backend. It does not encrypt values; its security boundary is the 0700 data root and 0600 vault file.
public actor FileCredentialStore: CredentialStore {
    public let vaultURL: URL
    private let dataRoot: URL
    private let permissions: any FilePermissionAdapter

    public init(dataRoot: URL, permissions: any FilePermissionAdapter = PlatformFilePermissionAdapter()) throws {
        self.dataRoot = dataRoot.standardizedFileURL
        vaultURL = self.dataRoot.appendingPathComponent("credentials.vault")
        self.permissions = permissions
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
        try write(values)
    }

    public func removeSecret(for reference: CredentialRef) throws {
        var values = try load()
        values.removeValue(forKey: reference.rawValue)
        try write(values)
    }

    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else { return [:] }
        let data = try Data(contentsOf: vaultURL)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConfigurationValidationError(path: "$", reason: "invalid credentials.vault JSON: \(error.localizedDescription)")
        }
        guard let root = object as? [String: Any] else {
            throw ConfigurationValidationError(path: "$", reason: "expected object")
        }
        for key in root.keys where key != "version" && key != "credentials" {
            throw ConfigurationValidationError(path: "$.\(key)", reason: "unknown property")
        }
        guard
            let version = root["version"] as? NSNumber,
            CFGetTypeID(version) != CFBooleanGetTypeID(),
            version.intValue == ConfigurationFormat.currentVersion,
            version.doubleValue == Double(version.intValue)
        else {
            throw ConfigurationValidationError(path: "$.version", reason: "expected version \(ConfigurationFormat.currentVersion)")
        }
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

    private func write(_ values: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(Vault(version: ConfigurationFormat.currentVersion, credentials: values))
        data.append(0x0A)
        try data.write(to: vaultURL, options: .atomic)
        try permissions.secureFile(at: vaultURL)
    }

    private func requireReference(_ reference: CredentialRef) throws {
        guard !reference.rawValue.isEmpty else {
            throw ConfigurationValidationError(path: "$.credentials", reason: "credential reference must not be empty")
        }
    }

    private struct Vault: Codable {
        let version: Int
        let credentials: [String: String]
    }
}
