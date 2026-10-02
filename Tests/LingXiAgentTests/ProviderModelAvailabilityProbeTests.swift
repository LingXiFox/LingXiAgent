import Foundation
import Testing
import LingXiClient
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LingXiCore
@testable import LingXiProtocol

/// The availability probe that keeps a `/v1/models` over-report out of the picker.
@Suite("Provider model availability probe", .serialized)
struct ProviderModelAvailabilityProbeTests {

    /// The model a probe request asked about. URLSession moves an `httpBody` into a stream before it
    /// reaches a URLProtocol, so reading only `httpBody` silently yields nothing and every stubbed
    /// branch falls through to its default.
    static func modelID(in request: URLRequest) -> String? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        }
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["model"] as? String
    }

    @Test("only 'this model is not offered here' is a failure; a rate limit is a pass")
    func verdictRule() {
        #expect(ProviderModelAvailabilityProbe.verdict(statusCode: 200, body: "data: {}") == .available)
        // 429 is the strongest proof a model resolved: throttling is applied after routing, so a name
        // that does not exist never reaches one. Treating it as failure would black out a busy account.
        #expect(ProviderModelAvailabilityProbe.verdict(
            statusCode: 429, body: #"{"error":{"message":"inference exceeds tpm/rpm limit"}}"#) == .available)
        // The real BAI answer for a plan-excluded model.
        #expect(ProviderModelAvailabilityProbe.verdict(
            statusCode: 403,
            body: #"{"error":{"message":"model is not available in the current token plan","type":"permission_denied_error","code":"7"}}"#
        ) == .unavailable)
        #expect(ProviderModelAvailabilityProbe.verdict(
            statusCode: 404, body: #"{"error":{"message":"The model `nope` does not exist"}}"#) == .unavailable)
        // Nothing about the model can be concluded from these; they must not hide a working model.
        #expect(ProviderModelAvailabilityProbe.verdict(
            statusCode: 401, body: #"{"error":{"message":"Authorization Not Found"}}"#) == .unknown)
        #expect(ProviderModelAvailabilityProbe.verdict(statusCode: 500, body: "boom") == .unknown)
        #expect(ProviderModelAvailabilityProbe.verdict(statusCode: 503, body: "unavailable") == .unknown)
    }

    @Test("each adapter probes its own endpoint, and a full base URL is not doubled")
    func requestPerAdapter() throws {
        let chat = ProviderModelAvailabilityProbe.request(
            baseURL: "https://relay.test/v1", adapter: "openai-compatible", modelID: "m1",
            apiKeyHeader: nil, credential: "sk-1", headers: [:])
        #expect(chat?.url?.absoluteString == "https://relay.test/v1/chat/completions")
        #expect(chat?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")

        let alreadySuffixed = ProviderModelAvailabilityProbe.request(
            baseURL: "https://relay.test/v1/chat/completions", adapter: "openai-compatible", modelID: "m1",
            apiKeyHeader: nil, credential: "sk-1", headers: [:])
        #expect(alreadySuffixed?.url?.absoluteString == "https://relay.test/v1/chat/completions",
                "又拼出一层 /chat/completions")

        let responses = ProviderModelAvailabilityProbe.request(
            baseURL: "https://relay.test/v1", adapter: "openai-responses", modelID: "m1",
            apiKeyHeader: nil, credential: "sk-1", headers: [:])
        #expect(responses?.url?.absoluteString == "https://relay.test/v1/responses")

        let anthropic = ProviderModelAvailabilityProbe.request(
            baseURL: "https://api.anthropic.com/v1", adapter: "anthropic-messages", modelID: "m1",
            apiKeyHeader: nil, credential: "sk-1", headers: [:])
        #expect(anthropic?.value(forHTTPHeaderField: "x-api-key") == "sk-1")
        #expect(anthropic?.value(forHTTPHeaderField: "anthropic-version") != nil)

        // The smallest turn that still reaches model routing.
        let payload = try #require(chat?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(json["model"] as? String == "m1")
        #expect(json["stream"] as? Bool == true)
        #expect((json["max_tokens"] as? Int) == 1 || (json["max_output_tokens"] as? Int) == 1)
    }

    @Test("a transport failure is unknown, never a verdict about the model")
    func networkFailureIsUnknown() async {
        let verdict = await ProviderModelAvailabilityProbe.probe(
            baseURL: "https://relay.test/v1", adapter: "openai-compatible", modelID: "m1",
            apiKeyHeader: nil, credential: "sk-1") { _ in throw URLError(.timedOut) }
        #expect(verdict == .unknown)
    }

    /// A client that answers per model id. Deliberately not `StubURLProtocol`: its `handler` is a
    /// global static that other suites reset while this test is mid-flight, which made these verdicts
    /// depend on what else happened to be running.
    static func client(_ decide: @escaping @Sendable (String?) -> (Int, String)) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            let (status, body) = decide(modelID(in: request))
            return (Data(body.utf8), HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("the picker hides only the models this account cannot use")
    func pickerHidesPlanExcludedModelsOnly() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ConfigurationStore(dataRoot: dir)
        var providers = try await store.load().providers
        providers.providers["relay"] = PublicProviderConfiguration(
            name: "Relay", adapter: "openai-compatible",
            options: PublicProviderOptions(baseURL: "https://relay.test/v1", apiKey: "{vault:provider-relay-key}"),
            models: [:])
        try await store.saveProviders(providers)
        let credentials = try FileCredentialStore(dataRoot: dir, passphrase: "test-passphrase", iterations: 100_000)
        try await credentials.setSecret("sk-relay-\(UUID().uuidString)", for: CredentialRef("provider-relay-key"))
        let host = try CoreHost(configurationStore: store, credentialStore: credentials)

        let filtered = await host.filteringUnavailableModels(
            ["works", "plan-excluded", "throttled", "missing", "gateway-down"], providerID: "relay",
            httpClient: Self.client { model in
                switch model {
                case "plan-excluded": return (403, #"{"error":{"message":"model is not available in the current token plan"}}"#)
                case "throttled": return (429, #"{"error":{"message":"inference exceeds tpm/rpm limit"}}"#)
                case "missing": return (404, #"{"error":{"message":"model does not exist"}}"#)
                case "gateway-down": return (502, "bad gateway")
                default: return (200, "data: [DONE]\n\n")
                }
            })

        #expect(filtered.hidden == ["plan-excluded", "missing"],
                "只有套餐不含/不存在该隐藏：\(filtered.hidden)")
        // 429 and a dead gateway both keep their candidate: neither says anything about the model.
        #expect(filtered.kept == ["works", "throttled", "gateway-down"])
    }

    @Test("verdicts survive the run that produced them, so the picker marks models without re-billing")
    func verdictsAreRememberedPerAccount() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-remember-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let providerID = "remembered-\(UUID().uuidString.prefix(8))"
        let store = try ConfigurationStore(dataRoot: dir)
        var providers = try await store.load().providers
        providers.providers[providerID] = PublicProviderConfiguration(
            name: "Relay", adapter: "openai-compatible",
            options: PublicProviderOptions(baseURL: "https://relay.test/v1", apiKey: "{vault:provider-relay-key}"),
            models: ["dead": PublicModelConfiguration(name: "Dead"), "fine": PublicModelConfiguration(name: "Fine")])
        try await store.saveProviders(providers)
        let credentials = try FileCredentialStore(dataRoot: dir, passphrase: "test-passphrase", iterations: 100_000)
        try await credentials.setSecret("sk-remember-\(UUID().uuidString)", for: CredentialRef("provider-relay-key"))
        let host = try CoreHost(configurationStore: store, credentialStore: credentials)

        #expect(await host.recordedModelAvailability(providerID: providerID).isEmpty,
                "没人探测过，不该凭空有结论")

        _ = await host.probeModelAvailability(
            ids: ["dead", "fine"], providerID: providerID,
            httpClient: Self.client { model in
                model == "dead"
                    ? (403, #"{"error":{"message":"not available in the current token plan"}}"#)
                    : (200, "data: [DONE]")
            })
        // Read back through a fresh host on the same account: this is the composer picker's path, which
        // must not spend a request to know what a probe already settled.
        let reader = try CoreHost(configurationStore: store, credentialStore: credentials)
        let remembered = await reader.recordedModelAvailability(providerID: providerID)
        #expect(remembered["dead"] == .unavailable)
        #expect(remembered["fine"] == .available)
        // And over the wire, which is what the settings page actually calls on every visit.
        let viaRPC = try await reader.getProviderModelAvailability(
            envelope: QueryEnvelope(payload: GetProviderModelAvailabilityRequest(providerID: providerID)))
        #expect(viaRPC.payload["dead"] == .unavailable)
        #expect(viaRPC.payload["fine"] == .available)
        // The last link, and the one that actually broke: the model list the composer builds its menu
        // from has to carry the verdict, or a dead model stays one click away no matter what is cached.
        let client = try await LingXiClientVNext.inProcess(service: reader)
        let listed = try await client.model.list()
        let dead = try #require(listed.first { $0.modelID == "dead" && $0.providerID == providerID })
        #expect(dead.availability == .unavailable, "模型列表没带上探测结论，选择器就还能选中它")
        let fine = try #require(listed.first { $0.modelID == "fine" && $0.providerID == providerID })
        #expect(fine.availability == .available)
    }

    @Test("markAllStale reaches every cached account, which is what makes 重新发现 forceful")
    func markAllStaleCoversEveryAccount() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = AccountScopedCatalogCache(baseCacheDirectory: dir)
        // One product, two accounts: a divergent accountRef is exactly the shape that used to make
        // the read order-dependent, so the force has to cover both.
        _ = try await cache.save(productID: "p-one", accountRef: "auth0_abc",
                                 models: [DiscoveredRemoteModel(id: "m1", displayName: "M1")])
        _ = try await cache.save(productID: "p-one", accountRef: "deadbeefdeadbeef",
                                 models: [DiscoveredRemoteModel(id: "m2", displayName: "M2")])
        _ = try await cache.save(productID: "p-two", accountRef: "auth0_xyz",
                                 models: [DiscoveredRemoteModel(id: "m3", displayName: "M3")])

        #expect(await cache.markAllStale() == 3)
        // Idempotent: a second force must not claim work it did not do.
        #expect(await cache.markAllStale() == 0)
        for (product, account) in [("p-one", "auth0_abc"), ("p-one", "deadbeefdeadbeef"), ("p-two", "auth0_xyz")] {
            #expect(await cache.load(productID: product, accountRef: account)?.isStale == true,
                    "\(product)/\(account) 未被标记，读路径会继续用旧缓存")
        }
    }
}
