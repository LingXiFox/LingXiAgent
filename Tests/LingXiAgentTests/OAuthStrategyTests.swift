import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

struct OAuthStrategyTests {
    @Test func pkceVerifierAndChallengeAreStandardCompliant() {
        let verifier = PKCE.generateVerifier()
        #expect(verifier.count >= 43)
        #expect(!verifier.contains("+"))
        #expect(!verifier.contains("/"))
        #expect(!verifier.contains("="))

        let challenge = PKCE.challenge(for: verifier)
        #expect(!challenge.isEmpty)
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
        #expect(!challenge.contains("="))

        // Deterministic challenge for same verifier
        #expect(PKCE.challenge(for: verifier) == challenge)
    }

    @Test func callbackStateValidationProtectsAgainstCSRF() async {
        let expectedState = "safe_secure_random_state_123"
        let server = OAuthCallbackServer(expectedState: expectedState)

        // Valid callback
        let validURL = URL(string: "http://127.0.0.1:18420/callback?code=auth_code_xyz&state=\(expectedState)")!
        let validRes = await server.handleCallbackURL(validURL)
        #expect(validRes == .success(code: "auth_code_xyz"))

        // CSRF state mismatch
        let attackerURL = URL(string: "http://127.0.0.1:18420/callback?code=auth_code_xyz&state=malicious_state")!
        let attackRes = await server.handleCallbackURL(attackerURL)
        #expect(attackRes == .stateMismatch)

        // OAuth error response from provider
        let errorURL = URL(string: "http://127.0.0.1:18420/callback?error=access_denied&state=\(expectedState)")!
        let errorRes = await server.handleCallbackURL(errorURL)
        #expect(errorRes == .error("access_denied"))
    }

    @Test func tokenExchangeParsesTokensAccurately() async throws {
        let mockData = """
        {
            "access_token": "mock_access_token_123",
            "token_type": "Bearer",
            "expires_in": 3600,
            "refresh_token": "mock_refresh_token_456",
            "scope": "openid profile model.request"
        }
        """.data(using: .utf8)!

        let mockClient: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (mockData, response)
        }

        let tokens = try await OAuthFlowCoordinator.exchangeCodeForTokens(
            tokenEndpoint: URL(string: "https://auth.openai.com/oauth/token")!,
            clientID: "test-client",
            redirectURI: URL(string: "http://127.0.0.1:18420/callback")!,
            code: "test-auth-code",
            codeVerifier: "test-verifier",
            client: mockClient
        )

        #expect(tokens.accessToken == "mock_access_token_123")
        #expect(tokens.refreshToken == "mock_refresh_token_456")
        #expect(tokens.expiresAt != nil)
    }

    @Test func oauthRefresherDebouncesConcurrentlyWithSingleFlightAndRotatesToken() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let credStore = try FileCredentialStore(dataRoot: tempDir, passphrase: "test-passphrase")
        let tokenRef = CredentialRef("test-oauth-token")

        // Initial expired token
        let initialTokens = OAuthTokens(
            accessToken: "expired_token",
            refreshToken: "refresh_token_v1",
            expiresAt: Date().addingTimeInterval(-100)
        )

        let mockResponseData = """
        {
            "access_token": "new_refreshed_access_token",
            "expires_in": 3600,
            "refresh_token": "rotated_refresh_token_v2"
        }
        """.data(using: .utf8)!

        let mockClient: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { req in
            // Add a small delay to simulate network flight
            try? await Task.sleep(nanoseconds: 50_000_000)
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (mockResponseData, response)
        }

        let metadata = OAuthCredentialMetadata(
            providerID: "openai-codex",
            clientID: "test-client",
            scopes: ["model.request"],
            tokenEndpoint: "https://auth.openai.com/oauth/token"
        )

        let refresher = OAuthTokenRefresher(
            metadata: metadata,
            tokens: initialTokens,
            credentialStore: credStore,
            tokenRef: tokenRef,
            client: mockClient
        )

        // Launch 10 concurrent requests to validAccessToken()
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
        #expect(results.allSatisfy { $0 == "new_refreshed_access_token" })

        // Verify single-flight debounce: exactly 1 HTTP refresh was performed!
        let callCount = await refresher.refreshCallCount
        #expect(callCount == 1)

        // Verify rotating refresh token was updated in-memory
        let currentTokens = await refresher.currentTokens
        #expect(currentTokens.refreshToken == "rotated_refresh_token_v2")

        // Verify rotating refresh token was persisted into the CredentialStore
        let savedRaw = try await credStore.secret(for: tokenRef)
        #expect(savedRaw != nil)
        let savedTokens = try JSONDecoder().decode(OAuthTokens.self, from: savedRaw!.data(using: .utf8)!)
        #expect(savedTokens.refreshToken == "rotated_refresh_token_v2")
    }

    @Test func requestProfileRewritesEndpointAndInjectsHeadersAndRedacts() {
        let provenance = RequestProfileProvenance(
            profileVersion: "2026-09",
            verifiedAt: "2026-09-08T00:00:00Z",
            evidenceSources: ["https://platform.openai.com/docs/guides/reasoning"],
            compatibilityStatus: "compatibleNonOfficial",
            knownRequiredHeaders: ["OpenAI-Beta": "assistants=v2"],
            optionalOfficialLikeHeaders: ["User-Agent": "LingXiAgent-OfficialLike/2.0"]
        )
        let profile = OAuthRequestProfile(
            id: "openai-codex@2026-09",
            version: "2026-09",
            compatibilityMode: .officialLike,
            endpointOverride: URL(string: "https://custom-gateway.internal:8443")!,
            requiredHeaders: ["OpenAI-Beta": "assistants=v2"],
            dynamicHeaders: ["X-Session-ID": "sess-999"],
            userAgentProfile: "LingXiAgent-OfficialLike/2.0",
            stripHeaders: ["X-Legacy-Header"],
            provenance: provenance
        )

        #expect(profile.provenance?.profileVersion == "2026-09")
        #expect(profile.provenance?.compatibilityStatus == "compatibleNonOfficial")

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.setValue("old-value", forHTTPHeaderField: "X-Legacy-Header")

        profile.apply(to: &request)

        // URL host & port overridden while path preserved
        #expect(request.url?.host == "custom-gateway.internal")
        #expect(request.url?.port == 8443)
        #expect(request.url?.path == "/v1/responses")

        // Headers injected
        #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "assistants=v2")
        #expect(request.value(forHTTPHeaderField: "X-Session-ID") == "sess-999")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "LingXiAgent-OfficialLike/2.0")

        // Header stripped
        #expect(request.value(forHTTPHeaderField: "X-Legacy-Header") == nil)

        // Redaction verification
        let redactedAuth = OAuthRequestProfile.redactSensitiveValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.token", header: "Authorization")
        #expect(!redactedAuth.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        #expect(redactedAuth.hasPrefix("Bearer [REDACTED:len="))

        let redactedKey = OAuthRequestProfile.redactSensitiveValue("sk-proj-super-secret-key-12345678", header: "x-api-key")
        #expect(!redactedKey.contains("super-secret-key"))
        #expect(redactedKey.hasPrefix("[REDACTED:len="))
    }

    @Test func authCLIFlowListsAndLogsInOAuthProduct() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-auth-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let credStore = try FileCredentialStore(dataRoot: tempDir, passphrase: "test")
        let configStore = try ConfigurationStore(dataRoot: tempDir)

        // 1. Initial list
        let initialList = try await AuthCLI.run(
            arguments: ["auth", "list"],
            dataRoot: tempDir,
            credentialStore: credStore,
            configurationStore: configStore
        )
        #expect(initialList.contains("openai-codex"))
        #expect(initialList.contains("○ OAuth Required"))

        // 2. OAuth login with simulated callback URL input
        let mockTokensJSON = """
        {
            "access_token": "test_access_token_cli",
            "token_type": "Bearer",
            "expires_in": 3600,
            "refresh_token": "test_refresh_token_cli"
        }
        """.data(using: .utf8)!

        let mockClient: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (mockTokensJSON, response)
        }

        let loginOutput = try await AuthCLI.run(
            arguments: ["auth", "login", "openai-codex"],
            dataRoot: tempDir,
            credentialStore: credStore,
            configurationStore: configStore,
            inputReader: { prompt in
                // Extract state from prompt
                if let range = prompt.range(of: "state=") {
                    let statePart = prompt[range.upperBound...].components(separatedBy: "&")[0].components(separatedBy: "\n")[0]
                    return "http://127.0.0.1:18420/callback?code=mock_code&state=\(statePart)"
                }
                return "mock_code"
            },
            httpClient: mockClient
        )

        #expect(loginOutput.contains("Successfully authenticated OpenAI Codex via OAuth!"))

        // 3. Status now reflects authenticated
        let statusOutput = try await AuthCLI.run(
            arguments: ["auth", "status", "openai-codex"],
            dataRoot: tempDir,
            credentialStore: credStore,
            configurationStore: configStore
        )
        #expect(statusOutput.contains("✓ OAuth Authenticated"))

        // 4. Logout removes credentials
        let logoutOutput = try await AuthCLI.run(
            arguments: ["auth", "logout", "openai-codex"],
            dataRoot: tempDir,
            credentialStore: credStore,
            configurationStore: configStore
        )
        #expect(logoutOutput.contains("Successfully logged out from 'openai-codex'."))

        let postLogoutStatus = try await AuthCLI.run(
            arguments: ["auth", "status", "openai-codex"],
            dataRoot: tempDir,
            credentialStore: credStore,
            configurationStore: configStore
        )
        #expect(postLogoutStatus.contains("○ OAuth Required"))
    }
}
