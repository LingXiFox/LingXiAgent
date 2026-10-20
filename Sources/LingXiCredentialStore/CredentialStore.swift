import Foundation
import LingXiPluginABI
import Security

/// Where a provider's secret comes from. Reported to the frontend as status; the value itself never
/// leaves the Core.
public enum CredentialSource: String, Sendable, Equatable, CaseIterable {
    /// A secret saved through the frontend and held by the platform secret store (Keychain).
    case keychain
    /// An explicit development/automation variable. Only used when the Core was started with
    /// `LINGXI_CREDENTIAL_SOURCE=environment`; it is never an implicit fallback.
    case environment
    case missing
}

/// A durable secret address: one provider, one declared requirement. The platform key is composed
/// from the owner and requirement so two providers can both call their secret `apiKey` without colliding.
public struct CredentialKey: Sendable, Hashable, Equatable {
    public let bundleID: String
    public let providerID: String
    public let credentialID: String

    public init(bundleID: String, providerID: String, credentialID: String) {
        self.bundleID = bundleID
        self.providerID = providerID
        self.credentialID = credentialID
    }

    /// The account name used in the platform secret store. Readable on purpose: an operator must be
    /// able to audit which provider owns which item, and the account name is not a secret.
    public var account: String { "\(bundleID)/\(providerID)/\(credentialID)" }

    public init?(account: String) {
        let parts = account.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        bundleID = String(parts[0])
        providerID = String(parts[1])
        credentialID = String(parts[2])
    }
}

/// Status-only view of one declared credential. There is deliberately no member that could carry
/// the secret: every frontend reply is built from this type.
public struct CredentialAvailability: Sendable, Equatable {
    public let providerID: String
    public let credentialID: String
    public let label: String
    public let source: CredentialSource

    public init(providerID: String, credentialID: String, label: String, source: CredentialSource) {
        self.providerID = providerID
        self.credentialID = credentialID
        self.label = label
        self.source = source
    }

    public var configured: Bool { source != .missing }
}

public enum CredentialStoreError: Error, CustomStringConvertible, Equatable {
    /// A platform secret store call failed. Only the status code is carried; never the secret.
    case backend(OSStatus)
    case emptySecret
    case environmentOverride

    public var description: String {
        switch self {
        case .backend(let status):
            return "the platform secret store refused the operation (OSStatus \(status))"
        case .environmentOverride:
            return "an explicit environment override is active; restart without LINGXI_CREDENTIAL_SOURCE=environment before managing saved credentials"
        case .emptySecret:
            return "an API key must be nonempty, at most 8192 bytes, and contain no whitespace"
        }
    }
}

/// The minimal platform secret store surface. Separate from the authority so the resolution rules can
/// be tested without touching a real Keychain, and so the Keychain itself is reachable from exactly
/// one implementation.
public protocol SecretBackend: Sendable {
    func read(account: String) throws -> String?
    func write(_ secret: String, account: String) throws
    func delete(account: String) throws
    func accounts() throws -> [String]
}

/// Resolves, stores and removes provider credentials. Pure value type: callers on any thread may use
/// one instance, and it holds no cache, so a saved or removed secret is visible to the very next
/// provider request without restarting the Core.
public struct CredentialAuthority: Sendable {
    public enum SourceMode: String, Sendable {
        /// The shipped default: the platform secret store only.
        case keychain
        /// Explicit development/automation mode: the declared variable first, saved secrets second.
        case environment

        public static func parse(_ raw: String?) -> SourceMode {
            guard let raw else { return .keychain }
            return SourceMode(rawValue: raw) ?? .keychain
        }
    }

    private let backend: any SecretBackend
    private let mode: SourceMode
    private let environment: [String: String]
    private let environmentOverrides: [String: String]

    /// - Parameters:
    ///   - environment: the Core's own environment, passed explicitly so tests never read the
    ///     developer's real variables.
    ///   - environmentOverrides: optional `capability id -> variable name` map from
    ///     `credentials.json`; a deployment override, not the normal path. The plugin declaration
    ///     suggests a variable; only this operator-controlled mapping grants environment access.
    public init(
        backend: any SecretBackend,
        mode: SourceMode = .keychain,
        environment: [String: String] = [:],
        environmentOverrides: [String: String] = [:]
    ) {
        self.backend = backend
        self.mode = mode
        self.environment = environment
        self.environmentOverrides = environmentOverrides
    }

    private func environmentSecret(providerID: String) -> String? {
        guard mode == .environment, let name = environmentOverrides["provider.\(providerID)"],
              let value = environment[name], !value.isEmpty else { return nil }
        return value
    }

    /// The secret for one requirement, or `nil` when the provider must stay unauthorized. Read on
    /// every provider request, which is what makes update and removal take effect immediately.
    public func secret(bundleID: String, providerID: String, requirement: CredentialRequirement) throws -> String? {
        if let value = environmentSecret(providerID: providerID) { return value }
        let key = CredentialKey(bundleID: bundleID, providerID: providerID, credentialID: requirement.id)
        guard let value = try backend.read(account: key.account), !value.isEmpty else { return nil }
        return value
    }

    public func availability(
        bundleID: String, providerID: String, requirement: CredentialRequirement
    ) throws -> CredentialAvailability {
        let key = CredentialKey(bundleID: bundleID, providerID: providerID, credentialID: requirement.id)
        let source: CredentialSource
        if environmentSecret(providerID: providerID) != nil {
            source = .environment
        } else if try backend.accounts().contains(key.account) {
            source = .keychain
        } else {
            source = .missing
        }
        return CredentialAvailability(
            providerID: providerID, credentialID: requirement.id, label: requirement.label,
            source: source
        )
    }

    /// Saves or replaces the secret; an active environment override must be removed first.
    public func set(_ secret: String, bundleID: String, providerID: String, requirement: CredentialRequirement) throws {
        try requirePersistentMode(providerID: providerID)
        guard !secret.isEmpty,
              secret.utf8.count <= 8192, !secret.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw CredentialStoreError.emptySecret }
        let key = CredentialKey(bundleID: bundleID, providerID: providerID, credentialID: requirement.id)
        try backend.write(secret, account: key.account)
    }

    public func remove(bundleID: String, providerID: String, requirement: CredentialRequirement) throws {
        try requirePersistentMode(providerID: providerID)
        let key = CredentialKey(bundleID: bundleID, providerID: providerID, credentialID: requirement.id)
        try backend.delete(account: key.account)
    }

    /// Every saved key, for reporting providers whose plugin is currently disabled. Only account
    /// names are read back; the secrets are not touched.
    public func storedKeys() throws -> [CredentialKey] {
        let accounts = try backend.accounts()
        return accounts.compactMap(CredentialKey.init(account:)).sorted {
            ($0.providerID, $0.credentialID) < ($1.providerID, $1.credentialID)
        }
    }

    private func requirePersistentMode(providerID: String) throws {
        if environmentSecret(providerID: providerID) != nil { throw CredentialStoreError.environmentOverride }
    }
}
