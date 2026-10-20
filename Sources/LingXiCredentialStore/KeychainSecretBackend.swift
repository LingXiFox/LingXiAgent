import Foundation
import Security

/// The one implementation that talks to macOS Keychain. Everything else in the Core sees the
/// `SecretBackend` protocol, so auditing "who can read a saved key" means auditing this file: the TUI
/// never links it, the plugin host never links it, and a third-party plugin has no path to it.
///
/// Deliberately the **legacy login keychain** (the classic file-based keychain) rather than the data
/// protection keychain: the latter requires the
/// `com.apple.security.application-groups`/keychain-access-group entitlement, and an ad-hoc
/// SwiftPM-built binary has no entitlement. File-based Keychain ACLs trust the creating Core code
/// identity only. Restarting the same build preserves access; rebuilding ad-hoc code may require
/// macOS authorization again because its designated requirement contains the code hash.
public struct KeychainSecretBackend: SecretBackend {
    /// Service namespace. Every item written by this agent shares it, so `security` and the Keychain
    /// Access app show them as one group. Tests pass a throwaway service.
    public let service: String

    public init(service: String = KeychainSecretBackend.defaultService) {
        self.service = service
    }

    /// Not a secret: it names the group, and an operator needs it to find or clear the items.
    public static let defaultService = "site.lingxi.credentials"

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.backend(status)
        }
    }

    public func write(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery(account: account)
            var access: SecAccess?
            let accessStatus = SecAccessCreate("LingXiAgent provider credential" as CFString, nil, &access)
            guard accessStatus == errSecSuccess, let access else {
                throw CredentialStoreError.backend(accessStatus)
            }
            item[kSecAttrAccess as String] = access
            item[kSecValueData as String] = data
            // Visible in Keychain Access as the agent's own group; still not the secret.
            item[kSecAttrLabel as String] = "LingXiAgent provider credential"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialStoreError.backend(added) }
        default:
            throw CredentialStoreError.backend(updated)
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        // Removing a credential the user never saved is a valid no-op, not an error.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.backend(status)
        }
    }

    /// Account names only. Used to report providers whose plugin is currently disabled, so their key
    /// still shows as configured (a disabled plugin must not look like a forgotten credential).
    public func accounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            let entries = items as? [[String: Any]] ?? []
            return entries.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw CredentialStoreError.backend(status)
        }
    }
}
