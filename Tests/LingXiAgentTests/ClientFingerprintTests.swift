import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LingXiCore

struct ClientFingerprintTests {

    @Test func platformDetectionMatchesHostOrCustomEnvironment() {
        let platform = ClientFingerprint.currentPlatform()
        #expect(!platform.osName.isEmpty)
        #expect(!platform.capitalizedOS.isEmpty)
        #expect(!platform.arch.isEmpty)
        #expect(!platform.term.isEmpty)

        #if os(macOS)
        #expect(platform.osName == "darwin")
        #expect(platform.capitalizedOS == "Darwin")
        #endif

        #if arch(arm64)
        #expect(platform.arch == "arm64")
        #endif
    }

    @Test func officialUserAgentsAlignWithOfficialClients() {
        let platform = ClientFingerprint.currentPlatform()

        // 1. OpenAI Codex
        let codexUA = ClientFingerprint.userAgent(for: "openai-codex")
        #expect(codexUA.hasPrefix("codex-cli/"))
        #expect(codexUA.contains("(\(platform.osName); \(platform.arch))"))

        // 2. Claude Subscription (matches official Claude Code CLI)
        let claudeUA = ClientFingerprint.userAgent(for: "anthropic-claude-subscription")
        #expect(claudeUA.hasPrefix("claude-cli/"))
        #expect(claudeUA.contains("(external, cli)"))

        // 3. Antigravity (updated to 2.9.1)
        let antigravityUA = ClientFingerprint.userAgent(for: "antigravity")
        #expect(antigravityUA.hasPrefix("antigravity/2.9.1"))
        #expect(antigravityUA.contains("\(platform.osName)/\(platform.arch)"))

        // 4. Gemini Code Assist
        let geminiUA = ClientFingerprint.userAgent(for: "gemini-code-assist")
        #expect(geminiUA.hasPrefix("GeminiCLI/0.1.5"))
        #expect(geminiUA.contains("(\(platform.capitalizedOS); \(platform.arch))"))

        // 5. Grok CLI
        let grokUA = ClientFingerprint.userAgent(for: "xai-grok-subscription")
        #expect(grokUA.hasPrefix("xai-grok-workspace/0.2.120"))
    }

    @Test func officialHeadersContainFullCompanionSuites() {
        // 1. OpenAI Codex Headers
        let mockToken = "header.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoib3JnLTEyMzQ1In19.signature"
        let codexHeaders = ClientFingerprint.headers(for: "openai-codex", authToken: mockToken, isStream: true)
        #expect(codexHeaders["originator"] == "codex-cli")
        #expect(codexHeaders["OpenAI-Beta"] == "responses=v1")
        #expect(codexHeaders["chatgpt-account-id"] == "org-12345")
        #expect(codexHeaders["Accept"] == "text/event-stream")
        #expect(codexHeaders["User-Agent"]?.hasPrefix("codex-cli/") == true)

        // 2. Claude Subscription Headers
        let claudeHeaders = ClientFingerprint.headers(for: "anthropic-claude-subscription")
        #expect(claudeHeaders["anthropic-version"] == "2023-06-01")
        #expect(claudeHeaders["anthropic-beta"]?.contains("prompt-caching-2024-07-31") == true)
        #expect(claudeHeaders["anthropic-client"]?.hasPrefix("claude-code/") == true)
        #expect(claudeHeaders["User-Agent"]?.hasPrefix("claude-cli/") == true)

        // 3. Claude API Key transparent mode (must NOT impersonate Claude Code)
        let claudeAPIHeaders = ClientFingerprint.headers(for: "anthropic-api")
        #expect(claudeAPIHeaders["anthropic-version"] == "2023-06-01")
        #expect(claudeAPIHeaders["anthropic-beta"] == nil)
        #expect(claudeAPIHeaders["anthropic-client"] == nil)

        // 4. Antigravity Headers
        let antigravityHeaders = ClientFingerprint.headers(for: "antigravity")
        #expect(antigravityHeaders["X-Goog-Api-Client"] == "antigravity/2.9.1")
        #expect(antigravityHeaders["User-Agent"]?.hasPrefix("antigravity/2.9.1") == true)

        // 5. Gemini Code Assist Headers
        let geminiHeaders = ClientFingerprint.headers(for: "gemini-code-assist")
        #expect(geminiHeaders["X-Goog-Api-Client"] == "gl-swift/5.x gccl/0.1.5")
        #expect(geminiHeaders["User-Agent"]?.hasPrefix("GeminiCLI/0.1.5") == true)
    }

    @Test("the Codex client version is resolved from the release tag, never from a guess")
    func codexClientVersionResolution() {
        // Tags carry a `rust-v` prefix; the release feed is full of `-alpha.N`.
        #expect(CodexClientVersion.version(fromTag: "rust-v0.160.0") == "0.160.0")
        #expect(CodexClientVersion.version(fromTag: "v0.160.0") == "0.160.0")
        #expect(CodexClientVersion.version(fromTag: "0.159.3") == "0.159.3")
        // A prerelease would put LingXi behind a protocol shape it has not implemented.
        #expect(CodexClientVersion.version(fromTag: "rust-v0.162.0-alpha.7") == nil)
        #expect(CodexClientVersion.version(fromTag: "nightly") == nil)
        #expect(CodexClientVersion.version(fromTag: "") == nil)

        // Numeric compare, so `0.9.0` cannot beat `0.159.3` the way a string compare would.
        #expect(CodexClientVersion.compare("0.160.0", "0.159.3") == 1)
        #expect(CodexClientVersion.compare("0.9.0", "0.159.3") == -1)
        #expect(CodexClientVersion.compare("0.159.3", "0.159.3") == 0)
    }

    @Test("an unreached GitHub leaves a working version, and the override still wins")
    func codexClientVersionNeverEmpty() async {
        CodexClientVersion.resetForTesting()
        // Nothing fetched yet: the floor, never empty and never `0`.
        #expect(CodexClientVersion.current(environment: [:]) == CodexClientVersion.floor)
        // An explicit pin outranks both the floor and whatever was fetched.
        #expect(CodexClientVersion.current(environment: ["CODEX_CLI_VERSION": "0.200.0"]) == "0.200.0")

        // A failed fetch keeps the floor and backs off rather than hammering GitHub.
        actor Counter { var n = 0; func bump() { n += 1 }; func read() -> Int { n } }
        let hits = Counter()
        struct Offline: Error {}
        let failing: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { _ in
            await hits.bump()
            throw Offline()
        }
        #expect(await CodexClientVersion.refresh(httpClient: failing) == CodexClientVersion.floor)
        #expect(await CodexClientVersion.refresh(httpClient: failing) == CodexClientVersion.floor)
        #expect(await hits.read() == 1, "失败后应退避，第二次调用不该再打网络")

        // A successful one is adopted.
        CodexClientVersion.resetForTesting()
        let body = Data(#"{"tag_name":"rust-v0.161.0","prerelease":false}"#.utf8)
        let afterSuccess = await CodexClientVersion.refresh { _ in
            (body, HTTPURLResponse(url: CodexClientVersion.releasesURL, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!)
        }
        #expect(afterSuccess == "0.161.0")
        #expect(CodexClientVersion.current(environment: [:]) == "0.161.0")

        // A prerelease release is refused, keeping the last good value.
        CodexClientVersion.resetForTesting()
        _ = await CodexClientVersion.refresh { _ in
            (body, HTTPURLResponse(url: CodexClientVersion.releasesURL, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!)
        }
        let pre = Data(#"{"tag_name":"rust-v0.162.0-alpha.1","prerelease":true}"#.utf8)
        let afterPre = await CodexClientVersion.refresh { _ in
            (pre, HTTPURLResponse(url: CodexClientVersion.releasesURL, statusCode: 200,
                                  httpVersion: nil, headerFields: nil)!)
        }
        #expect(afterPre == "0.161.0", "prerelease 不该被采纳，更不能覆盖已知可用值")
        CodexClientVersion.resetForTesting()
    }

    @Test func providerMakeURLRequestRespectsRequiredHeadersUserAgent() throws {
        let dummyURL = URL(string: "https://example.com/v1")!
        let customUA = "CustomClient/9.9.9"
        let config = ProviderConfig(
            baseURL: dummyURL,
            authentication: .none,
            model: "test-model",
            wireProtocol: .chatCompletions,
            requiredHeaders: ["User-Agent": customUA]
        )

        let provider = OpenAICompatibleProvider(config: config)
        let dummyRequest = ModelRequest(model: ModelID("test-model"), messages: [ModelMessage(role: .user, content: "hello")])
        let urlReq = try provider.makeURLRequest(dummyRequest)

        #expect(urlReq.value(forHTTPHeaderField: "User-Agent") == customUA)
    }

    @Test func builtinProviderCatalogRequestProfilesUseClientFingerprint() {
        let metadata = BuiltinProviderCatalog.metadata(for: "openai-codex")
        let activeProfile = metadata.activeRequestProfile
        #expect(activeProfile != nil)
        #expect(activeProfile?.userAgentProfile?.hasPrefix("codex-cli/") == true)
        #expect(activeProfile?.requiredHeaders?["originator"] == "codex-cli")
        #expect(activeProfile?.endpointOverride?.contains("client_version=") == true)

        let claudeMetadata = BuiltinProviderCatalog.metadata(for: "anthropic-claude-subscription")
        let claudeProfile = claudeMetadata.activeRequestProfile
        #expect(claudeProfile != nil)
        #expect(claudeProfile?.userAgentProfile?.hasPrefix("claude-cli/") == true)
        #expect(claudeProfile?.requiredHeaders?["anthropic-version"] == "2023-06-01")

        let antigravityMetadata = BuiltinProviderCatalog.metadata(for: "antigravity")
        let antigravityProfile = antigravityMetadata.activeRequestProfile
        #expect(antigravityProfile != nil)
        #expect(antigravityProfile?.userAgentProfile?.hasPrefix("antigravity/2.9.1") == true)
    }
}
