import Foundation
import LingXiProtocol

/// The single authority and repository-wide access point for sensitive provider credentials.
///
/// CredentialBroker strictly enforces scoped, non-escaping credential borrowing:
/// credentials are only provided to caller-supplied closures during active execution
/// and are NEVER written to process environment variables, task snapshots, or persisted events.
public actor CredentialBroker {
    private let credentialStore: any CredentialStore

    public init(credentialStore: any CredentialStore) {
        self.credentialStore = credentialStore
    }

    /// Scoped, non-escaping access to a stored credential secret.
    ///
    /// The secret value is passed to the temporary closure and discarded immediately after return.
    /// It must never be assigned to child-process environments or serialized objects.
    public func withProviderCredential<T: Sendable>(
        for runID: RunID?,
        reference: CredentialRef,
        _ body: (String) async throws -> T
    ) async throws -> T {
        guard let secret = try await credentialStore.secret(for: reference), !secret.isEmpty else {
            throw CoreError(code: .resourceNotFound, message: "Credential \(reference.rawValue) not found in vault")
        }
        return try await body(secret)
    }

    /// Stores a new secret in the backing secure vault.
    public func storeSecret(_ secret: String, for reference: CredentialRef) async throws {
        try await credentialStore.setSecret(secret, for: reference)
    }

    /// Deletes a secret from the backing secure vault.
    public func deleteSecret(for reference: CredentialRef) async throws {
        try await credentialStore.removeSecret(for: reference)
    }

    /// Checks if a secret exists in the vault without revealing its value.
    public func hasSecret(for reference: CredentialRef) async -> Bool {
        guard let secret = try? await credentialStore.secret(for: reference) else { return false }
        return !secret.isEmpty
    }
}
