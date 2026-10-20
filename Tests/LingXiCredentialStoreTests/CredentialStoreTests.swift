import Foundation
import LingXiCredentialStore
import LingXiPluginABI
import Testing

private final class MemorySecrets: SecretBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func read(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }; return values[account]
    }
    func write(_ secret: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }; values[account] = secret
    }
    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }; values[account] = nil
    }
    func accounts() throws -> [String] {
        lock.lock(); defer { lock.unlock() }; return Array(values.keys)
    }
}

private let requirement = CredentialRequirement(id: "apiKey", label: "API Key", envVariable: "TEST_API_KEY", helpURL: nil)
private let owner = "site.lingxi.test.provider"

@Test("AUTH-001 credentials resolve afresh, stay scoped to a bundle, and never implicitly use environment")
func AUTH_001_resolutionAndRevocation() throws {
    let backend = MemorySecrets()
    let authority = CredentialAuthority(backend: backend, environment: ["TEST_API_KEY": "environment-sentinel"])
    #expect(try authority.secret(bundleID: owner, providerID: "test", requirement: requirement) == nil)
    try authority.set("first-sentinel", bundleID: owner, providerID: "test", requirement: requirement)
    #expect(try authority.secret(bundleID: owner, providerID: "test", requirement: requirement) == "first-sentinel")
    #expect(try authority.secret(bundleID: "other.bundle", providerID: "test", requirement: requirement) == nil)
    try authority.set("second-sentinel", bundleID: owner, providerID: "test", requirement: requirement)
    #expect(try authority.secret(bundleID: owner, providerID: "test", requirement: requirement) == "second-sentinel")
    let key = CredentialKey(bundleID: owner, providerID: "test", credentialID: "apiKey")
    #expect(CredentialKey(account: key.account) == key)
    #expect(try authority.storedKeys() == [key])
    try authority.remove(bundleID: owner, providerID: "test", requirement: requirement)
    #expect(try authority.availability(bundleID: owner, providerID: "test", requirement: requirement).source == .missing)
    #expect(try authority.secret(bundleID: owner, providerID: "test", requirement: requirement) == nil)
    #expect(throws: CredentialStoreError.emptySecret) {
        try authority.set(" \n", bundleID: owner, providerID: "test", requirement: requirement)
    }
}

@Test("AUTH-001 explicit environment mode reports its source and cannot pretend to update or remove it")
func AUTH_001_environmentIsExplicit() throws {
    let authority = CredentialAuthority(backend: MemorySecrets(), mode: .environment,
        environment: ["OVERRIDE_KEY": "environment-sentinel"], environmentOverrides: ["provider.test": "OVERRIDE_KEY"])
    let undelegated = CredentialAuthority(backend: MemorySecrets(), mode: .environment,
        environment: ["TEST_API_KEY": "unmapped-sentinel"])
    #expect(try undelegated.secret(bundleID: owner, providerID: "test", requirement: requirement) == nil)
    #expect(try authority.availability(bundleID: owner, providerID: "test", requirement: requirement).source == .environment)
    #expect(try authority.secret(bundleID: owner, providerID: "test", requirement: requirement) == "environment-sentinel")
    #expect(throws: CredentialStoreError.environmentOverride) {
        try authority.remove(bundleID: owner, providerID: "test", requirement: requirement)
    }
    #expect(throws: CredentialStoreError.environmentOverride) {
        try authority.set("new-sentinel", bundleID: owner, providerID: "test", requirement: requirement)
    }
}

@Test("AUTH-001 declaration extension decodes old providers without granting undeclared credentials")
func AUTH_001_oldDeclaration() throws {
    let json = Data(#"{"id":"legacy","models":["m"],"supportsParallelToolCalls":false,"toolResultPlacement":"anywhereInHistory"}"#.utf8)
    let identity = try JSONDecoder().decode(ProviderIdentity.self, from: json)
    #expect(identity.credentials == nil)
}

@Test("AUTH-002 real macOS Keychain round trip", .enabled(if: ProcessInfo.processInfo.environment["LINGXI_RUN_KEYCHAIN_TESTS"] == "1"))
func AUTH_002_realKeychain() throws {
    let backend = KeychainSecretBackend(service: "site.lingxi.credentials.test.\(UUID().uuidString)")
    let account = CredentialKey(bundleID: owner, providerID: "test", credentialID: "apiKey").account
    defer { try? backend.delete(account: account) }
    #expect(try backend.read(account: account) == nil)
    try backend.write("keychain-first-sentinel", account: account)
    #expect(try backend.read(account: account) == "keychain-first-sentinel")
    #expect(try backend.accounts() == [account])
    try backend.write("keychain-second-sentinel", account: account)
    #expect(try backend.read(account: account) == "keychain-second-sentinel")
    try backend.delete(account: account)
    #expect(try backend.read(account: account) == nil)
}
