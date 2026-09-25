import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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

        let credStore = try FileCredentialStore(dataRoot: tempDir, passphrase: "test-passphrase", iterations: 100_000)
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

        let credStore = try FileCredentialStore(dataRoot: tempDir, passphrase: "test", iterations: 100_000)
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

    @Test func oauthRefresherAutoRefreshesWhenNearExpiry() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-expiry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let credStore = try FileCredentialStore(dataRoot: tempDir, passphrase: "test-passphrase", iterations: 100_000)
        let tokenRef = CredentialRef("test-oauth-token-near-expiry")

        // 1. Token expiring in 20s (< 30s threshold) -> Should trigger automatic refresh
        let nearExpiryTokens = OAuthTokens(
            accessToken: "near_expired_at",
            refreshToken: "rt_initial",
            expiresAt: Date().addingTimeInterval(20)
        )

        let mockResponseData = """
        {
            "access_token": "auto_refreshed_at",
            "expires_in": 3600,
            "refresh_token": "rt_rotated_1"
        }
        """.data(using: .utf8)!

        let mockClient: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { req in
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
            tokens: nearExpiryTokens,
            credentialStore: credStore,
            tokenRef: tokenRef,
            client: mockClient
        )

        let validToken = try await refresher.validAccessToken()
        #expect(validToken == "auto_refreshed_at")
        #expect(await refresher.refreshCallCount == 1)

        // 2. Token far from expiry (3600s) -> Should return immediately without HTTP call
        let freshToken = try await refresher.validAccessToken()
        #expect(freshToken == "auto_refreshed_at")
        #expect(await refresher.refreshCallCount == 1) // unchanged

        // 3. forceRefresh: true -> Should refresh even if token is not expired
        let forceRefreshed = try await refresher.validAccessToken(forceRefresh: true)
        #expect(forceRefreshed == "auto_refreshed_at")
        #expect(await refresher.refreshCallCount == 2) // incremented
    }

    @Test func oauthRefresherClassifiesInvalidGrantAndTransientErrors() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-errors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let credStore = try FileCredentialStore(dataRoot: tempDir, passphrase: "test-passphrase", iterations: 100_000)
        let tokenRef = CredentialRef("test-oauth-token-errors")

        let expiredTokens = OAuthTokens(
            accessToken: "expired",
            refreshToken: "bad_rt",
            expiresAt: Date().addingTimeInterval(-60)
        )

        let metadata = OAuthCredentialMetadata(
            providerID: "openai-codex",
            clientID: "test-client",
            scopes: ["model.request"],
            tokenEndpoint: "https://auth.openai.com/oauth/token"
        )

        // Test invalid_grant -> reauthenticationRequired
        let invalidGrantResponse = """
        {"error": "invalid_grant", "error_description": "Refresh token is expired or revoked"}
        """.data(using: .utf8)!

        let invalidGrantClient: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (invalidGrantResponse, response)
        }

        let refresher1 = OAuthTokenRefresher(
            metadata: metadata,
            tokens: expiredTokens,
            credentialStore: credStore,
            tokenRef: tokenRef,
            client: invalidGrantClient
        )

        do {
            _ = try await refresher1.validAccessToken()
            Issue.record("Expected error")
        } catch let err as OAuthRefreshError {
            #expect(err.isRevokedOrInvalidGrant)
            let state = await refresher1.authState
            #expect(state == .reauthenticationRequired)
        }

        // Test 500 error -> transient failure
        let serverErrorClient: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: [:])!
            return (Data(), response)
        }

        let refresher2 = OAuthTokenRefresher(
            metadata: metadata,
            tokens: expiredTokens,
            credentialStore: credStore,
            tokenRef: tokenRef,
            client: serverErrorClient
        )

        do {
            _ = try await refresher2.validAccessToken()
            Issue.record("Expected error")
        } catch let err as OAuthRefreshError {
            #expect(!err.isRevokedOrInvalidGrant)
            let state = await refresher2.authState
            #expect(state == .refreshFailedTransient)
        }
    }

    @Test func openAICompatibleProviderTransparent401RetryWithOAuthRefresher() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-401-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let credStore = try FileCredentialStore(dataRoot: tempDir, passphrase: "test-passphrase", iterations: 100_000)
        let tokenRef = CredentialRef("test-oauth-token-401")

        // Initial token considered valid locally, but server rejects with 401
        let initialTokens = OAuthTokens(
            accessToken: "stale_token_that_server_rejects",
            refreshToken: "good_rt",
            expiresAt: Date().addingTimeInterval(3600)
        )

        let refreshResponseData = """
        {
            "access_token": "fresh_valid_access_token",
            "expires_in": 3600,
            "refresh_token": "rotated_rt_2"
        }
        """.data(using: .utf8)!

        let refreshClient: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (refreshResponseData, response)
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
            client: refreshClient
        )

        // Mock HTTP transport that gives 401 on first request, and 200 on second request
        let ssePayload = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello after 401 retry!\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        let response401 = ProviderHTTPResponse(
            statusCode: 401,
            headers: ["Content-Type": "application/json"],
            body: AsyncThrowingStream { continuation in
                continuation.yield(Data("{\"error\": {\"message\": \"token_expired\"}}".utf8))
                continuation.finish()
            }
        )
        let response200 = ProviderHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: AsyncThrowingStream { continuation in
                continuation.yield(Data(ssePayload.utf8))
                continuation.finish()
            }
        )

        let transport = TestScriptedTransport(responses: [response401, response200])

        let config = ProviderConfig(
            baseURL: URL(string: "https://api.openai.com/v1")!,
            authentication: .oauth(refresher),
            model: "gpt-4o",
            wireProtocol: .chatCompletions
        )

        let provider = OpenAICompatibleProvider(config: config, transport: transport)
        let stream = try await provider.stream(ModelRequest(
            model: ModelID("gpt-4o"),
            messages: [ModelMessage(role: .user, content: "hi")]
        ))

        var deltas: [String] = []
        for try await event in stream {
            if case .textDelta(let delta) = event {
                deltas.append(delta)
            }
        }

        #expect(deltas.contains("Hello after 401 retry!"))
        // Check that 2 requests were sent to transport
        let sent = await transport.sentRequests
        #expect(sent.count == 2)
        #expect(sent[0].value(forHTTPHeaderField: "Authorization") == "Bearer stale_token_that_server_rejects")
        #expect(sent[1].value(forHTTPHeaderField: "Authorization") == "Bearer fresh_valid_access_token")

        // Refresher call count should be 1
        #expect(await refresher.refreshCallCount == 1)
    }

    @Test func coreHostDynamicOAuthRefresherDecouplesAssemblyFromStaleTokens() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-decouple-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let credStore = try FileCredentialStore(dataRoot: tempDir, passphrase: "test-passphrase", iterations: 100_000)
        let tokenRef = CredentialRef("test-oauth-token-decouple")

        let tokens = OAuthTokens(
            accessToken: "token_v1",
            refreshToken: "rt_v1",
            expiresAt: Date().addingTimeInterval(3600)
        )

        let refreshResponseData = """
        {
            "access_token": "token_v2_rotated",
            "expires_in": 3600,
            "refresh_token": "rt_v2"
        }
        """.data(using: .utf8)!

        let refreshClient: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (refreshResponseData, response)
        }

        let metadata = OAuthCredentialMetadata(
            providerID: "openai-codex",
            clientID: "test-client",
            scopes: ["model.request"],
            tokenEndpoint: "https://auth.openai.com/oauth/token"
        )

        let refresher = OAuthTokenRefresher(
            metadata: metadata,
            tokens: tokens,
            credentialStore: credStore,
            tokenRef: tokenRef,
            client: refreshClient
        )

        let config = ProviderConfig(
            baseURL: URL(string: "https://api.openai.com/v1")!,
            authentication: .oauth(refresher),
            model: "gpt-4o",
            wireProtocol: .chatCompletions
        )

        // First resolve: returns token_v1
        let auth1 = try await config.resolveAuthHeader()
        #expect(auth1?.value == "Bearer token_v1")

        // Simulate background / token expiry refresh
        _ = try await refresher.validAccessToken(forceRefresh: true)

        // Same config / assembly resolves auth header dynamically: returns token_v2_rotated
        let auth2 = try await config.resolveAuthHeader()
        #expect(auth2?.value == "Bearer token_v2_rotated")
    }

    @Test func providerErrorClassifierDistinguishesOAuthRevocation() {
        // OAuth revocation: errorType contains invalid_grant or token_expired
        let err1 = ClassifiedProviderError(
            category: .authFailure,
            statusCode: 401,
            errorType: "invalid_grant",
            serverMessage: "refresh token was revoked"
        )
        #expect(err1.userFacingSummary.contains("OAuth 授权凭据已失效或被撤销"))
        #expect(!err1.userFacingSummary.contains("API Key"))

        // OAuth refresh failed
        let err2 = ClassifiedProviderError(
            category: .authFailure,
            statusCode: 401,
            errorType: "oauth_refresh_failed",
            serverMessage: "connection timed out"
        )
        #expect(err2.userFacingSummary.contains("OAuth 令牌自动刷新失败"))
        #expect(!err2.userFacingSummary.contains("API Key"))

        // Standard API Key 401
        let err3 = ClassifiedProviderError(
            category: .authFailure,
            statusCode: 401,
            serverMessage: "Incorrect API key provided: sk-***"
        )
        #expect(err3.userFacingSummary.contains("请检查提供商配置中的 API Key 是否有效或过期"))
    }
}

private actor TestScriptedTransport: ProviderHTTPTransport {
    private var responses: [ProviderHTTPResponse]
    private(set) var sentRequests: [URLRequest] = []

    init(responses: [ProviderHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest, context: ProviderHTTPRequestContext) async throws -> ProviderHTTPResponse {
        sentRequests.append(request)
        guard !responses.isEmpty else {
            throw CoreError(code: .provider, message: "No more scripted responses")
        }
        return responses.removeFirst()
    }
}

