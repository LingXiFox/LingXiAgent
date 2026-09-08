import Foundation
import LingXiProtocol
#if canImport(Security)
import Security
#endif

public actor KeychainCredentialStore: CredentialStore {
    public let service: String

    public init(service: String = "com.lingxi.agent") {
        self.service = service
    }

    public func secret(for reference: CredentialRef) async throws -> String? {
        #if os(macOS)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        #if os(macOS)
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        #endif

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CoreError(code: .provider, message: "Keychain read failed with OSStatus \(status)")
        }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    public func setSecret(_ secret: String, for reference: CredentialRef) async throws {
        #if os(macOS)
        guard let data = secret.data(using: .utf8) else {
            throw CoreError(code: .provider, message: "Invalid UTF-8 secret payload")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.rawValue
        ]

        let updateFields: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, updateFields as CFDictionary)
        if status == errSecItemNotFound {
            var newQuery = query
            newQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(newQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CoreError(code: .provider, message: "Keychain add failed with OSStatus \(addStatus)")
            }
        } else if status != errSecSuccess {
            throw CoreError(code: .provider, message: "Keychain update failed with OSStatus \(status)")
        }
        #endif
    }

    public func removeSecret(for reference: CredentialRef) async throws {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw CoreError(code: .provider, message: "Keychain delete failed with OSStatus \(status)")
        }
        #endif
    }
}

public actor PlatformSecureCredentialStore: CredentialStore {
    private let keychainStore: KeychainCredentialStore
    private let fallbackFileStore: FileCredentialStore
    private let allowMemoryOnlyFallback: Bool
    private var memoryVault: [String: String] = [:]
    private let hasPassphrase: Bool

    public init(
        dataRoot: URL,
        passphrase: String? = nil,
        allowMemoryOnlyFallback: Bool = false,
        service: String = "com.lingxi.agent"
    ) throws {
        self.keychainStore = KeychainCredentialStore(service: service)
        self.fallbackFileStore = try FileCredentialStore(dataRoot: dataRoot, passphrase: passphrase)
        self.allowMemoryOnlyFallback = allowMemoryOnlyFallback
        let explicitPass = passphrase?.isEmpty == false ? passphrase : nil
        let envPass = ProcessInfo.processInfo.environment["LINGXI_CREDENTIALS_PASSPHRASE"]
        self.hasPassphrase = (explicitPass != nil) || (envPass != nil && !envPass!.isEmpty)
    }

    public func secret(for reference: CredentialRef) async throws -> String? {
        #if os(macOS)
        do {
            if let val = try await keychainStore.secret(for: reference) {
                return val
            }
        } catch {
            // Fallback when Keychain read fails
        }
        #endif

        if hasPassphrase {
            return try await fallbackFileStore.secret(for: reference)
        }
        if allowMemoryOnlyFallback {
            return memoryVault[reference.rawValue]
        }
        // If file vault doesn't exist, reading a non-existent secret can safely return nil
        // But if file exists and cannot be decrypted without passphrase, fallbackFileStore will throw ConfigurationValidationError
        return try await fallbackFileStore.secret(for: reference)
    }

    public func setSecret(_ secret: String, for reference: CredentialRef) async throws {
        #if os(macOS)
        do {
            try await keychainStore.setSecret(secret, for: reference)
            return
        } catch {
            // Fallback when Keychain write fails
        }
        #endif

        if hasPassphrase {
            try await fallbackFileStore.setSecret(secret, for: reference)
            return
        }
        if allowMemoryOnlyFallback {
            memoryVault[reference.rawValue] = secret
            return
        }
        // Fail-closed: Never store secrets in an unauthenticated or pseudo-encrypted file vault
        throw CoreError(
            code: .provider,
            message: "Keychain is unavailable and no LINGXI_CREDENTIALS_PASSPHRASE was configured. Insecure file persistence is rejected."
        )
    }

    public func removeSecret(for reference: CredentialRef) async throws {
        #if os(macOS)
        try? await keychainStore.removeSecret(for: reference)
        #endif

        if hasPassphrase {
            try? await fallbackFileStore.removeSecret(for: reference)
        }
        if allowMemoryOnlyFallback {
            memoryVault.removeValue(forKey: reference.rawValue)
        }
    }
}
