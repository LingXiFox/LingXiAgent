import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

@Suite struct AuthCLITests {
    private func makeTestStores() throws -> (URL, FileCredentialStore, ConfigurationStore) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-auth-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let credStore = try FileCredentialStore(dataRoot: tempDir, passphrase: "test-passphrase-1234")
        let configStore = try ConfigurationStore(dataRoot: tempDir)
        return (tempDir, credStore, configStore)
    }

    @Test func authListDisplaysAllProvidersAndLocalNoAuth() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await AuthCLI.run(
            arguments: ["auth", "list"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )

        #expect(output.contains("=== Available Providers ==="))
        #expect(output.contains("anthropic-api"))
        #expect(output.contains("openai-api"))
        #expect(output.contains("ollama-local"))
        #expect(output.contains("No Auth Needed"))
        #expect(output.contains("Unauthenticated"))
    }

    @Test func authLoginStoresSecretInVaultAndUpdatesConfig() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Login with mock key
        let output = try await AuthCLI.run(
            arguments: ["auth", "login", "deepseek-api"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore,
            inputReader: { _ in "sk-mock-deepseek-key-999" }
        )

        #expect(output.contains("Successfully authenticated DeepSeek API"))

        // Verify stored in encrypted vault
        let storedSecret = try await credStore.secret(for: CredentialRef("provider-deepseek-api-key"))
        #expect(storedSecret == "sk-mock-deepseek-key-999")

        // Verify built-in providers are NEVER saved into providers.json (providers.json is for custom providers only)
        let snapshot = try await configStore.load()
        #expect(snapshot.providers.providers["deepseek-api"] == nil)

        // Verify status
        let statusOutput = try await AuthCLI.run(
            arguments: ["auth", "status", "deepseek-api"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )
        #expect(statusOutput.contains("Authenticated (Credentials Securely Stored)"))
    }

    @Test func authLogoutRemovesSecretAndConfig() async throws {
        let (dir, credStore, configStore) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Login first
        _ = try await AuthCLI.run(
            arguments: ["auth", "login", "openai-api"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore,
            inputReader: { _ in "sk-mock-openai-key" }
        )
        #expect(try await credStore.secret(for: CredentialRef("provider-openai-api-key")) == "sk-mock-openai-key")

        // Logout
        let logoutOutput = try await AuthCLI.run(
            arguments: ["auth", "logout", "openai-api"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )
        #expect(logoutOutput.contains("Successfully logged out from 'openai-api'"))

        // Secret should be gone
        let secretAfter = try await credStore.secret(for: CredentialRef("provider-openai-api-key"))
        #expect(secretAfter == nil)

        // Status should be unauthenticated
        let statusOutput = try await AuthCLI.run(
            arguments: ["auth", "status", "openai-api"],
            dataRoot: dir,
            credentialStore: credStore,
            configurationStore: configStore
        )
        #expect(statusOutput.contains("Unauthenticated"))
    }

    @Test func oauthTokenRefresherDebouncesConcurrentRequestsAndRotatesToken() async throws {
        let (dir, credStore, _) = try makeTestStores()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tokenRef = CredentialRef("secret:test-oauth-token")
        let metadata = OAuthCredentialMetadata(
            providerID: "test-oauth-provider",
            clientID: "client-123",
            scopes: ["model:read"],
            tokenEndpoint: "https://auth.example.com/token"
        )
        // Expired tokens
        let expiredTokens = OAuthTokens(
            accessToken: "expired-access-token",
            refreshToken: "refresh-token-v1",
            expiresAt: Date().addingTimeInterval(-100)
        )

        let mockResponseJSON = """
        {
            "access_token": "new-rotated-access-token",
            "refresh_token": "refresh-token-v2",
            "expires_in": 3600
        }
        """.data(using: .utf8)!

        let refresher = OAuthTokenRefresher(
            metadata: metadata,
            tokens: expiredTokens,
            credentialStore: credStore,
            tokenRef: tokenRef,
            client: { request in
                // Artificial delay to simulate real network request and test concurrency race
                try? await Task.sleep(nanoseconds: 50_000_000)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (mockResponseJSON, response)
            }
        )

        // Launch 10 concurrent requests
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await refresher.validAccessToken()
                }
            }
            var tokens: [String] = []
            for try await token in group {
                tokens.append(token)
            }
            return tokens
        }

        #expect(results.count == 10)
        #expect(results.allSatisfy { $0 == "new-rotated-access-token" })

        // Verify mutual exclusion & debouncing: exactly 1 HTTP call made
        let callCount = await refresher.refreshCallCount
        #expect(callCount == 1)

        // Verify token rotation
        let currentTokens = await refresher.currentTokens
        #expect(currentTokens.accessToken == "new-rotated-access-token")
        #expect(currentTokens.refreshToken == "refresh-token-v2")
        #expect(currentTokens.expiresAt != nil && currentTokens.expiresAt! > Date())
    }

    @Test func authStrategyHeaderInjection() async throws {
        var req1 = URLRequest(url: URL(string: "https://example.com")!)
        try await NoAuthStrategy().apply(to: &req1)
        #expect(req1.value(forHTTPHeaderField: "Authorization") == nil)

        var req2 = URLRequest(url: URL(string: "https://example.com")!)
        try await BearerAuthStrategy(token: "secret-bearer").apply(to: &req2)
        #expect(req2.value(forHTTPHeaderField: "Authorization") == "Bearer secret-bearer")

        var req3 = URLRequest(url: URL(string: "https://example.com")!)
        try await APIKeyHeaderAuthStrategy(headerName: "x-api-key", key: "anthropic-key").apply(to: &req3)
        #expect(req3.value(forHTTPHeaderField: "x-api-key") == "anthropic-key")
    }
}
