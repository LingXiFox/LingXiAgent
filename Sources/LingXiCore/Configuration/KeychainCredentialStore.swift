import Foundation
import LingXiProtocol
#if canImport(Security)
import Security
#endif

/// Legacy Keychain store preserved strictly for non-interactive read migration.
public actor KeychainCredentialStore: CredentialStore {
    public let service: String

    public init(service: String = "com.lingxi.agent") {
        self.service = service
    }

    public func secret(for reference: CredentialRef) async throws -> String? {
        #if os(macOS)
        guard ProcessInfo.processInfo.environment["LINGXI_DISABLE_KEYCHAIN"] != "1" else {
            return nil
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound || status == errSecInteractionNotAllowed {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    public func setSecret(_ secret: String, for reference: CredentialRef) async throws {
        // No-op: writes to system keychain are deprecated and disabled in favor of UniversalCredentialStore.
    }

    public func removeSecret(for reference: CredentialRef) async throws {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.rawValue
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }
}

/// Unified, cross-platform autonomous secure credential store.
/// Decoupled from OS keychain; stores credentials in authenticated AES-256-GCM vault
/// with machine-bound protection and optional passphrase derivation.
public actor PlatformSecureCredentialStore: CredentialStore {
    private let universalStore: UniversalCredentialStore
    private let legacyKeychain: KeychainCredentialStore

    public init(
        dataRoot: URL,
        passphrase: String? = nil,
        allowMemoryOnlyFallback: Bool = false,
        service: String = "com.lingxi.agent"
    ) throws {
        self.universalStore = try UniversalCredentialStore(
            dataRoot: dataRoot,
            passphrase: passphrase,
            isMemoryOnly: allowMemoryOnlyFallback
        )
        self.legacyKeychain = KeychainCredentialStore(service: service)
    }

    public func secret(for reference: CredentialRef) async throws -> String? {
        // 1. Primary: read from autonomous universal vault
        if let val = try await universalStore.secret(for: reference) {
            return val
        }

        // 2. Fallback: transparent one-time migration from legacy keychain if available (never prompts)
        if let legacySecret = try? await legacyKeychain.secret(for: reference), !legacySecret.isEmpty {
            // Automatically persist to autonomous vault so keychain is never queried again
            try? await universalStore.setSecret(legacySecret, for: reference)
            return legacySecret
        }

        return nil
    }

    public func setSecret(_ secret: String, for reference: CredentialRef) async throws {
        // Exclusively write to the autonomous universal vault
        try await universalStore.setSecret(secret, for: reference)
    }

    public func removeSecret(for reference: CredentialRef) async throws {
        try await universalStore.removeSecret(for: reference)
        try? await legacyKeychain.removeSecret(for: reference)
    }

    /// Verifies store integrity and key correctness.
    public func verifyStoreIntegrity() async throws -> Bool {
        try await universalStore.verifyStoreIntegrity()
    }
}
