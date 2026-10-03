import Foundation
import Testing
@testable import LingXiCore
import LingXiProtocol
import LingXiClient

/// A self-hosted endpoint on the LAN — LM Studio, llama.cpp, vLLM on another machine — added
/// through the custom provider form: no TLS, often no key, and a Base URL typed in whichever of
/// the three usual shapes the user happened to copy.
@Suite("Custom provider endpoints")
struct ProviderCustomEndpointTests {

    // MARK: - Endpoint policy

    @Test("plain HTTP is accepted on loopback and private LAN addresses")
    func lanHTTPAccepted() throws {
        for url in ["http://127.0.0.1:1234/v1", "http://localhost:1234", "http://192.168.1.20:1234/v1",
                    "http://10.0.0.5:8080", "http://172.20.3.4:8000/v1", "http://100.101.102.103:1234",
                    "http://studio.local:1234/v1", "http://169.254.10.1:1234", "http://[fd12:3456::1]:1234",
                    "http://[fe80::1]:1234", "http://[::1]:1234"] {
            #expect(throws: Never.self, "局域网地址被拒：\(url)") {
                _ = try ConfigurationEndpointPolicy.resolve(url, path: "$.t")
            }
        }
    }

    @Test("plain HTTP to a public host is still refused")
    func publicHTTPRefused() {
        for url in ["http://api.example.com/v1", "http://8.8.8.8:1234", "http://172.32.0.1:1234",
                    "http://192.169.1.1", "http://100.128.0.1", "http://[2001:db8::1]:1234",
                    "http://192.168.1.20.evil.com"] {
            #expect(throws: ConfigurationValidationError.self, "公网 http 被放行：\(url)") {
                _ = try ConfigurationEndpointPolicy.resolve(url, path: "$.t")
            }
        }
        #expect(throws: Never.self) { _ = try ConfigurationEndpointPolicy.resolve("https://api.example.com/v1", path: "$.t") }
    }

    // MARK: - Base URL normalisation

    @Test("the three shapes users paste land on the same API root")
    func normalizesToAPIRoot() {
        let openAI = "openai-compatible"
        #expect(ProviderBaseURLNormalizer.normalize("http://192.168.1.20:1234", adapter: openAI) == "http://192.168.1.20:1234/v1")
        #expect(ProviderBaseURLNormalizer.normalize("http://192.168.1.20:1234/", adapter: openAI) == "http://192.168.1.20:1234/v1")
        #expect(ProviderBaseURLNormalizer.normalize("http://192.168.1.20:1234/v1/", adapter: openAI) == "http://192.168.1.20:1234/v1")
        #expect(ProviderBaseURLNormalizer.normalize("http://192.168.1.20:1234/v1/chat/completions", adapter: openAI)
                == "http://192.168.1.20:1234/v1")
        #expect(ProviderBaseURLNormalizer.normalize(" https://relay.test/v1/models ", adapter: openAI) == "https://relay.test/v1")
        #expect(ProviderBaseURLNormalizer.normalize("https://h.test/v1/responses", adapter: "openai-responses") == "https://h.test/v1")
        // A relay's own layout is left exactly as typed.
        #expect(ProviderBaseURLNormalizer.normalize("https://api.z.ai/api/paas/v4", adapter: openAI) == "https://api.z.ai/api/paas/v4")
        // Anthropic's root carries no version; its runtime appends /v1/messages itself.
        #expect(ProviderBaseURLNormalizer.normalize("https://api.anthropic.com", adapter: "anthropic-messages")
                == "https://api.anthropic.com")
        #expect(ProviderBaseURLNormalizer.normalize("http://192.168.1.20:1234/v1/messages", adapter: "anthropic-messages")
                == "http://192.168.1.20:1234")
    }

    @Test("an Anthropic base ending in /v1 is not doubled, and the probe asks the matching list URL")
    func anthropicURLsAreNotDoubled() throws {
        let lan = ProviderConfig(baseURL: try #require(URL(string: "http://192.168.1.20:1234/v1")),
                                 apiKey: nil, model: "m")
        #expect(lan.anthropicMessagesURL.absoluteString == "http://192.168.1.20:1234/v1/messages")
        let official = ProviderConfig(baseURL: try #require(URL(string: "https://api.anthropic.com")),
                                      apiKey: nil, model: "m")
        #expect(official.anthropicMessagesURL.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(ProviderConnectivityProbe.modelsURL(baseURL: "https://api.anthropic.com", adapter: "anthropic-messages")?
                .absoluteString == "https://api.anthropic.com/v1/models")
    }

    // MARK: - Keyless endpoints

    private func accounts(_ json: String) throws -> [ProviderAccountConfiguration] {
        try JSONDecoder().decode(ProvidersConfiguration.self, from: Data(json.utf8)).accounts
    }

    @Test("no key means no authentication, even with a header name filled in")
    func keylessIsAnonymous() throws {
        let withHeader = try accounts("""
        {"providers":{"lms":{"name":"LMS","adapter":"openai-compatible",
          "options":{"baseURL":"http://192.168.1.20:1234/v1","apiKeyHeader":"Authorization"},
          "models":{"qwen":{"name":"qwen"}}}}}
        """)
        #expect(withHeader.first?.authentication == StoredProviderAuthenticationKind.none,
                "只填请求头不填 Key 被当成 header 鉴权，运行时会因缺凭据失败")
        #expect(withHeader.first?.accountType == .anonymousLocal)
    }

    @Test("an Authorization header name with a key is the bearer scheme, as the probe sends it")
    func authorizationHeaderIsBearer() throws {
        let bearer = try accounts("""
        {"providers":{"r":{"name":"R","adapter":"openai-compatible",
          "options":{"baseURL":"https://relay.test/v1","apiKey":"{vault:k}","apiKeyHeader":"Authorization"},
          "models":{"m":{"name":"m"}}}}}
        """)
        #expect(bearer.first?.authentication == .bearer)
        let custom = try accounts("""
        {"providers":{"r":{"name":"R","adapter":"openai-compatible",
          "options":{"baseURL":"https://relay.test/v1","apiKey":"{vault:k}","apiKeyHeader":"X-Api-Key"},
          "models":{"m":{"name":"m"}}}}}
        """)
        #expect(custom.first?.authentication == .header)
    }

    @Test("a keyless probe sends no credential and returns the listed model ids")
    func keylessProbeListsModels() async throws {
        let captured = CapturedRequest()
        let outcome = try await ProviderConnectivityProbe.probe(
            baseURL: "http://192.168.1.20:1234/v1", adapter: "openai-compatible", credential: nil,
            httpClient: { request in
                await captured.set(request)
                let body = #"{"data":[{"id":"qwen3.8-9b"},{"id":"text-embedding-nomic"}]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        #expect(outcome.modelIDs == ["qwen3.8-9b", "text-embedding-nomic"])
        let request = try #require(await captured.request)
        #expect(request.url?.absoluteString == "http://192.168.1.20:1234/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil, "无 Key 时不应发送鉴权头")
    }

    // MARK: - Model selection, end to end

    private func host(providers: String) async throws -> (CoreHost, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-keyless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try providers.write(to: root.appendingPathComponent("providers.json"), atomically: false, encoding: .utf8)
        let host = try CoreHost(modelRuntimes: [:], dataRoot: root, permissionDecision: .allow)
        await host.start()
        return (host, root)
    }

    /// The path the GUI's model switch takes. It had its own credential pre-check that demanded a
    /// key from every user-defined provider, so a keyless LM Studio saved fine and then could not
    /// be selected.
    @Test("a keyless LAN provider can be selected")
    func keylessProviderSelectable() async throws {
        let (host, root) = try await host(providers: """
        {"version":1,"providers":{"lmstudio":{"name":"LM Studio","adapter":"openai-compatible",
          "options":{"baseURL":"http://10.0.0.128:1234/v1","headers":{}},
          "models":{"qwen3.8-9b-q6k":{"name":"qwen3.8-9b-q6k","limit":{"context":65536,"output":8192}}}}}}
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await LingXiClientVNext.inProcess(service: host)
        let receipt = try await client.model.select(model: "lmstudio/qwen3.8-9b-q6k")
        #expect(receipt.applied)
        #expect(receipt.result?.providerID == "lmstudio")
        await host.shutdown()
    }

    @Test("a provider that names a key which cannot be resolved is still refused")
    func namedButMissingKeyRefused() async throws {
        let (host, root) = try await host(providers: """
        {"version":1,"providers":{"relay":{"name":"Relay","adapter":"openai-compatible",
          "options":{"baseURL":"https://relay.test/v1","apiKey":"{env:LX_TEST_SURELY_UNSET_KEY_42}"},
          "models":{"m":{"name":"m"}}}}}
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await LingXiClientVNext.inProcess(service: host)
        await #expect(throws: (any Error).self, "配置了 Key 却解析不到，不该被当成无鉴权端点放行") {
            _ = try await client.model.select(model: "relay/m")
        }
        await host.shutdown()
    }
}

private actor CapturedRequest {
    var request: URLRequest?
    func set(_ value: URLRequest) { request = value }
}
