import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LingXiCore
@testable import LingXiProtocol

private func fakeOK(_ body: String, url: String = "https://r.test/v1/models") -> (Data, URLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

@Suite("Provider sign-in and connection probes", .serialized)
struct ProviderAuthAndProbeTests {

    @Test("Auth products are catalog-backed and the loopback flag matches the declared redirect")
    func authProductsAreCatalogBacked() throws {
        let products = ProviderAuthCoordinator.authProducts()
        #expect(!products.isEmpty, "内置目录里有 OAuth 产品，登录目录不应为空")
        for product in products {
            #expect(BuiltinProviderCatalog.metadata(for: product.productID).oauth != nil,
                    "\(product.productID) 没有 OAuth 配置却出现在登录目录")
            #expect(BuiltinProviderCatalog.profile(for: product.productID) != nil)
            if product.loopbackCallback {
                let redirect = URL(string: BuiltinProviderCatalog.metadata(for: product.productID).oauth?.redirectURI ?? "")
                #expect(redirect?.host == "localhost" || redirect?.host == "127.0.0.1")
            }
        }
    }

    @Test("The probe asks for the model list at the configured endpoint")
    func modelsURLPerAdapter() {
        #expect(ProviderConnectivityProbe.modelsURL(baseURL: "https://relay.test/v1/", adapter: "openai-compatible")?
                .absoluteString == "https://relay.test/v1/models")
        #expect(ProviderConnectivityProbe.modelsURL(baseURL: "https://relay.test/v1/chat/completions", adapter: "openai-compatible")?
                .absoluteString == "https://relay.test/v1/models")
        #expect(ProviderConnectivityProbe.modelsURL(baseURL: "https://api.anthropic.com/v1", adapter: "anthropic-messages")?
                .absoluteString == "https://api.anthropic.com/v1/models")
        #expect(ProviderConnectivityProbe.modelsURL(baseURL: "", adapter: "openai-compatible") == nil)
    }

    @Test("The probe authenticates the way the runtime does")
    func probeAuthenticationHeaders() {
        let bearer = ProviderConnectivityProbe.request(baseURL: "https://r.test/v1", adapter: "openai-compatible",
                                                       apiKeyHeader: nil, credential: "sk-1", headers: [:])
        #expect(bearer?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        let explicitBearer = ProviderConnectivityProbe.request(baseURL: "https://r.test/v1", adapter: "openai-compatible",
                                                               apiKeyHeader: "Authorization", credential: "sk-1", headers: [:])
        #expect(explicitBearer?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")

        let named = ProviderConnectivityProbe.request(baseURL: "https://r.test/v1", adapter: "openai-compatible",
                                                      apiKeyHeader: "X-Team-Key", credential: "sk-1",
                                                      headers: ["x-team": "lingxi"])
        #expect(named?.value(forHTTPHeaderField: "X-Team-Key") == "sk-1")
        #expect(named?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(named?.value(forHTTPHeaderField: "x-team") == "lingxi")

        let anthropic = ProviderConnectivityProbe.request(baseURL: "https://api.anthropic.com/v1",
                                                          adapter: "anthropic-messages", apiKeyHeader: nil,
                                                          credential: "sk-ant", headers: [:])
        #expect(anthropic?.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(anthropic?.value(forHTTPHeaderField: "anthropic-version") != nil)

        // A local instance without a key is still worth testing.
        let anonymous = ProviderConnectivityProbe.request(baseURL: "http://127.0.0.1:11434/v1",
                                                          adapter: "openai-compatible", apiKeyHeader: nil,
                                                          credential: nil, headers: [:])
        #expect(anonymous?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("A rejected connection reads as upstream said it, without the credential")
    func probeFailureIsReadable() async {
        let response = HTTPURLResponse(url: URL(string: "https://r.test/v1/models")!,
                                       statusCode: 401, httpVersion: nil, headerFields: nil)!
        await #expect(throws: (any Error).self) {
            _ = try await ProviderConnectivityProbe.probe(baseURL: "https://r.test/v1",
                                                          adapter: "openai-compatible", credential: "sk-secret") { _ in
                (Data(), response)
            }
        }
        do {
            _ = try await ProviderConnectivityProbe.probe(baseURL: "https://r.test/v1",
                                                          adapter: "openai-compatible", credential: "sk-secret") { _ in
                (Data(), response)
            }
        } catch {
            let message = CoreHost.providerTestMessage(error)
            #expect(message.contains("401"))
            #expect(!message.contains("sk-secret"))
        }
    }

    @Test("A successful probe measures the round trip and counts the listed models")
    func probeSuccessReportsRealNumbers() async throws {
        let outcome = try await ProviderConnectivityProbe.probe(
            baseURL: "https://r.test/v1", adapter: "openai-compatible", credential: "sk") { _ in
            fakeOK(#"{"data":[{"id":"a"},{"id":"b"}]}"#)
        }
        #expect(outcome.models == 2)
        #expect(outcome.latencyMs >= 0)

        let empty = try await ProviderConnectivityProbe.probe(
            baseURL: "https://r.test/v1", adapter: "openai-compatible", credential: nil) { _ in fakeOK("{}") }
        #expect(empty.models == 0)
    }

    @Test("A model list reads from every envelope the relay variants answer with")
    func modelListShapesAllRead() async throws {
        // The connection test counted `{"models":[…]}` while the add-model picker called the same
        // endpoint empty: two readers, two ideas of what a model list looks like, one of them wrong.
        let shapes: [(body: String, expected: [String])] = [
            (#"{"data":[{"id":"b"},{"id":"a"}]}"#, ["a", "b"]),
            (#"{"data":["a","b"]}"#, ["a", "b"]),
            (#"{"models":[{"id":"a"},{"name":"b"}]}"#, ["a", "b"]),
            (#"{"modelsList":["a"]}"#, ["a"]),
            (#"{"results":[{"model":"a"}]}"#, ["a"]),
            (#"{"items":["a",{"id":"b"}]}"#, ["a", "b"]),
            (#"[{"id":"a"}]"#, ["a"]),
        ]
        for shape in shapes {
            #expect(ProviderConnectivityProbe.modelIDs(in: Data(shape.body.utf8)) == shape.expected,
                    "读不出 \(shape.body) 里的模型 ID")
        }
        #expect(ProviderConnectivityProbe.modelIDs(in: Data("not json".utf8)).isEmpty)
        #expect(ProviderConnectivityProbe.modelIDs(in: Data(#"{"error":{"message":"denied"}}"#.utf8)).isEmpty)
        #expect(ProviderConnectivityProbe.modelIDs(in: Data(#"{"data":{"object":"list"}}"#.utf8)).isEmpty)

        let counted = try await ProviderConnectivityProbe.probe(
            baseURL: "https://r.test/v1", adapter: "openai-compatible", credential: "sk") { _ in
            fakeOK(#"{"models":[{"id":"a"},{"id":"b"},{"id":"c"}]}"#)
        }
        #expect(counted.models == 3, "连接测试数出的模型数，候选列表必须一个不少地读到")
    }

    @Test("A sign-in finishes over the loopback callback and no token reaches the client contract")
    func loopbackSignInStoresTokensInVault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase", iterations: 100_000)

        let product = try #require(ProviderAuthCoordinator.authProducts().first { $0.loopbackCallback },
                                  "没有任何使用 loopback 回调的 OAuth 产品")
        let fakeClient: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.httpMethod == "POST" {
                return (Data(#"{"access_token":"at-1","refresh_token":"rt-1","expires_in":3600}"#.utf8), response)
            }
            return (Data(#"{"data":[]}"#.utf8), response)
        }
        let coordinator = ProviderAuthCoordinator(credentialStore: vault, configurationStore: nil,
                                                 httpClient: fakeClient)
        let started = try await coordinator.begin(productID: product.productID)
        let query = URLComponents(string: started.authorizeURL)?.queryItems ?? []
        let state = try #require(query.first { $0.name == "state" }?.value)
        let redirect = try #require(query.first { $0.name == "redirect_uri" }?.value)
        #expect(redirect.hasPrefix("http://localhost:") || redirect.hasPrefix("http://127.0.0.1:"))
        #expect(started.authorizeURL.contains(state), "授权链接必须带上 Core 生成的 state")

        // What the browser does when the provider redirects back.
        let callbackURL = URL(string: redirect + (redirect.contains("?") ? "&" : "?") + "code=abc123&state=\(state)")!
        _ = try? await URLSession.shared.data(from: callbackURL)

        var phase = ProviderAuthPhase.awaitingCallback
        for _ in 0..<60 {
            guard let status = await coordinator.status(flowID: started.flowID) else { break }
            phase = status.phase
            if phase != .awaitingCallback && phase != .exchanging { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(phase == .connected, "回调已送达，流程应完成；实际停在 \(phase)")
        #expect(try await vault.secret(for: CredentialRef("provider-\(product.productID)-oauth")) != nil)

        // The front-end contract carries a phase, never a token.
        let flow = try #require(await coordinator.status(flowID: started.flowID))
        let encoded = try JSONEncoder().encode(flow)
        let text = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!text.contains("at-1"))
        #expect(!text.contains("rt-1"))
        #expect(flow.authorizeURL == nil, "流程结束后不必再暴露授权链接")

        // A finished login cannot be talked out of existence.
        await coordinator.cancel(flowID: started.flowID)
        #expect(await coordinator.status(flowID: started.flowID)?.phase == .connected)
    }

    @Test("A callback with the wrong state does not authenticate")
    func mismatchedStateIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase", iterations: 100_000)
        let product = try #require(ProviderAuthCoordinator.authProducts().first { $0.loopbackCallback })
        let coordinator = ProviderAuthCoordinator(credentialStore: vault, configurationStore: nil, httpClient: { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"access_token":"at-1"}"#.utf8), response)
        })
        let started = try await coordinator.begin(productID: product.productID)
        let query = URLComponents(string: started.authorizeURL)?.queryItems ?? []
        let redirect = try #require(query.first { $0.name == "redirect_uri" }?.value)
        let url = URL(string: redirect + "?code=abc123&state=not-the-state")!
        _ = try? await URLSession.shared.data(from: url)

        try await Task.sleep(for: .milliseconds(400))
        let status = await coordinator.status(flowID: started.flowID)
        // A callback that does not carry Core's own state must never authenticate;
        // the flow ends as a failure instead of silently waiting on.
        #expect(status?.phase != .connected)
        #expect(status?.phase != .exchanging)
        #expect(try await vault.secret(for: CredentialRef("provider-\(product.productID)-oauth")) == nil,
                "state 不匹配不得写入凭据")
        await coordinator.cancel(flowID: started.flowID)
    }
}
