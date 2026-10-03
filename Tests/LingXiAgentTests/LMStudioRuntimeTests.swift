import Foundation
import Testing
@testable import LingXiCore
import LingXiProtocol

/// LM Studio as a local inference runtime.
///
/// Fixtures are trimmed copies of what a live LM Studio (10.0.0.128:1234, Qwen3.8-9B Q6_K, 64K,
/// MTP on) actually returned on 2026-10-03. Where the wire and the docs disagree, the wire wins:
/// `reasoning: "off"` is silently ignored there, `reasoning_effort: "none"` is what works.
@Suite("LM Studio local runtime")
struct LMStudioRuntimeTests {

    static let nativeJSON = """
    {"models":[{"type":"llm","publisher":"empero-ai","key":"qwen3.8-9b","display_name":"Qwen3.8 9B",
      "architecture":"qwen35","quantization":{"name":"Q6_K","bits_per_weight":6},"size_bytes":7558901056,
      "params_string":"9B","loaded_instances":[{"id":"qwen3.8-9b-q6k","config":{"context_length":65536,
      "eval_batch_size":2048,"physical_batch_size":512,"parallel":4,"flash_attention":true,
      "context_checkpoints":32,"reasoning_budget_message":"","speculative_draft_mtp":true,
      "speculative_draft_simple":false,"speculative_draft_model":"","speculative_draft_max_tokens":2,
      "speculative_draft_min_tokens":0,"speculative_draft_min_continue_probability":0.75,
      "offload_kv_cache_to_gpu":true}}],"max_context_length":262144,"format":"gguf",
      "capabilities":{"vision":false,"trained_for_tool_use":true,
      "reasoning":{"allowed_options":["off","on"],"default":"on"}},"description":null},
     {"type":"embedding","publisher":"nomic-ai","key":"text-embedding-nomic-embed-text-v1.5",
      "quantization":{"name":"Q4_K_M","bits_per_weight":4},"size_bytes":84106624,"params_string":null,
      "loaded_instances":[],"max_context_length":2048,"format":"gguf"}]}
    """

    /// The final usage chunk of a real streaming response.
    static let statsChunk = """
    {"id":"chatcmpl-x","object":"chat.completion.chunk","created":1791016175,"model":"qwen3.8-9b-q6k","choices":[],"usage":{"prompt_tokens":22,"completion_tokens":200,"total_tokens":222,"completion_tokens_details":{"reasoning_tokens":184}},"stats":{"total_draft_tokens_count":551,"accepted_draft_tokens_count":480,"rejected_draft_tokens_count":71}}
    """

    private static func client(_ routes: [String: (Int, String)], failing: Set<String> = []) -> LMStudioDiscovery.HTTPClient {
        { request in
            let path = request.url?.path ?? ""
            if failing.contains(path) { throw URLError(.cannotConnectToHost) }
            guard let (status, body) = routes[path] else {
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func discover(_ modelID: String = "qwen3.8-9b-q6k") async -> LocalRuntimeModelStatus {
        await LMStudioDiscovery.discover(baseURL: "http://10.0.0.128:1234/v1", modelID: modelID,
                                         httpClient: Self.client(["/api/v1/models": (200, Self.nativeJSON)]))
    }

    // MARK: 1–3. Native discovery and the two contexts

    @Test("native /api/v1/models decodes to the loaded instance's real state")
    func nativeDecode() async {
        let status = await discover()
        #expect(status.source == .native)
        #expect(status.endpoint == "10.0.0.128:1234")
        #expect(status.modelKey == "qwen3.8-9b")
        #expect(status.loadedInstanceID == "qwen3.8-9b-q6k")
        #expect(status.isLoaded)
        #expect(status.architecture == "qwen35")
        #expect(status.quantization == "Q6_K")
        #expect(status.sizeBytes == 7_558_901_056)
        #expect(status.toolUse == true)
        #expect(status.vision == false)
        #expect(status.flashAttention == true)
        #expect(status.kvCacheOnGPU == true)
    }

    @Test("runtime context is the loaded instance's, and is never confused with max context")
    func runtimeVersusMaximumContext() async {
        let status = await discover()
        #expect(status.runtimeContextTokens == 65_536, "活跃预算必须是 loaded instance 的 context_length")
        #expect(status.modelMaxContextTokens == 262_144)
        #expect(status.runtimeContextTokens != status.modelMaxContextTokens)
        // Addressed by model key instead of instance id: same answer.
        #expect(await discover("qwen3.8-9b").runtimeContextTokens == 65_536)
    }

    @Test("a model with no loaded instance does not claim a runtime context")
    func unloadedModelHasNoRuntimeContext() async {
        let status = await discover("text-embedding-nomic-embed-text-v1.5")
        #expect(status.isLoaded == false)
        #expect(status.runtimeContextTokens == nil, "未加载时不得声称活跃上下文已知")
        #expect(status.modelMaxContextTokens == 2_048)
        #expect(status.note != nil)
    }

    // MARK: 4. Reasoning

    @Test("reasoning allowed_options on/off becomes a two-state toggle, default on")
    func reasoningToggle() async throws {
        let capability = try #require(LMStudioDiscovery.reasoningCapability(await discover()))
        #expect(capability.mode == .toggle)
        #expect(Set(capability.supportedEfforts) == [.off, .auto], "不得伪造 Low/Medium/High")
        #expect(capability.defaultEffort == .auto)
    }

    @Test("Off sends reasoning_effort none; On sends nothing when the default is already on")
    func reasoningWire() {
        let wire = LMStudioChatExtension(reasoningToggle: true, reasoningDefaultOn: true, externalDraftModel: nil,
                                         mtpConfigured: true, sink: { _ in })
        let off = ModelRequest(model: ModelID("qwen3.8-9b-q6k"), messages: [], reasoning: "off")
        #expect(wire.additionalBodyFields(for: off) == ["reasoning_effort": .string("none")])
        for effort in [nil, "auto", "high", "low"] as [String?] {
            let request = ModelRequest(model: ModelID("qwen3.8-9b-q6k"), messages: [], reasoning: effort)
            #expect(wire.additionalBodyFields(for: request).isEmpty, "\(String(describing: effort)) 不应改写默认开启")
        }
        let defaultOff = LMStudioChatExtension(reasoningToggle: true, reasoningDefaultOn: false, externalDraftModel: nil,
                                               mtpConfigured: false, sink: { _ in })
        #expect(defaultOff.additionalBodyFields(for: ModelRequest(model: ModelID("m"), messages: [], reasoning: "high"))
                == ["reasoning_effort": .string("medium")])
    }

    // MARK: 5–7. MTP and speculative statistics

    @Test("MTP is read from config, and an empty draft model is no draft model")
    func mtpConfig() async {
        let status = await discover()
        #expect(status.mtpEnabled == true)
        #expect(status.externalDraftModel == nil, "空字符串 speculative_draft_model 不是外部草稿模型")
        #expect(status.draftMaxTokens == 2)
        #expect(status.draftMinContinueProbability == 0.75)
        #expect(status.configuredSpeculativeMode == .mtp)
    }

    @Test("speculative stats parse exactly, and missing fields stay missing")
    func speculativeStats() throws {
        let metrics = try #require(LMStudioChatExtension.metrics(fromPayload: Self.statsChunk, externalDraftModel: nil, mtpConfigured: true))
        #expect(metrics.mode == .mtp)
        #expect(metrics.draftedTokens == 551)
        #expect(metrics.acceptedTokens == 480)
        #expect(metrics.rejectedTokens == 71)
        #expect(metrics.ignoredTokens == nil, "响应没有的字段不得估算")
        let rate = try #require(metrics.acceptanceRate)
        #expect(abs(rate - 0.8711) < 0.001)

        let partial = try #require(LMStudioChatExtension.metrics(
            fromPayload: #"{"stats":{"accepted_draft_tokens_count":3}}"#, externalDraftModel: nil, mtpConfigured: true))
        #expect(partial.draftedTokens == nil && partial.acceptanceRate == nil, "缺 drafted 时不得算出接受率")
        #expect(LMStudioChatExtension.metrics(fromPayload: #"{"choices":[]}"#, externalDraftModel: nil, mtpConfigured: true) == nil)
    }

    @Test("draft_model is sent only when an external draft model is configured")
    func draftModelOnlyWhenConfigured() {
        let request = ModelRequest(model: ModelID("m"), messages: [])
        let mtp = LMStudioChatExtension(reasoningToggle: false, reasoningDefaultOn: true, externalDraftModel: nil,
                                        mtpConfigured: true, sink: { _ in })
        #expect(mtp.additionalBodyFields(for: request)["draft_model"] == nil)
        let external = LMStudioChatExtension(reasoningToggle: false, reasoningDefaultOn: true, externalDraftModel: "qwen-0.5b",
                                             mtpConfigured: false, sink: { _ in })
        #expect(external.additionalBodyFields(for: request)["draft_model"] == .string("qwen-0.5b"))
    }

    // MARK: 8. Cloud providers are untouched

    @Test("without an extension the request body is byte-identical to before")
    func cloudRequestEquivalence() throws {
        let config = ProviderConfig(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "k", model: "gpt")
        let request = ModelRequest(model: ModelID("gpt"), system: "sys",
                                   messages: [ModelMessage(role: .user, content: "hi")], reasoning: "off")
        let plain = try OpenAICompatibleProvider(config: config).makeURLRequest(request)
        #expect(plain.httpBody == (try OpenAICompatibleProvider.makeRequestBody(request, parallelToolCalls: true)),
                "云 Provider 的请求体必须与共享编码器逐字节一致")
        let body = try #require(plain.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["reasoning_effort"] == nil && body["draft_model"] == nil)

        let lmstudio = OpenAICompatibleProvider(config: config, wireExtension: LMStudioChatExtension(
            reasoningToggle: true, reasoningDefaultOn: true, externalDraftModel: nil, mtpConfigured: true, sink: { _ in }))
        let extended = try #require(try lmstudio.makeURLRequest(request).httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(extended["reasoning_effort"] as? String == "none")
        #expect(extended["messages"] != nil && extended["stream"] as? Bool == true, "扩展只能追加字段，不能改写通用请求")
    }

    @Test("the stream observer sees the final stats chunk without changing the events")
    func streamObservation() async throws {
        let observed = MetricsBox()
        let wire = LMStudioChatExtension(reasoningToggle: true, reasoningDefaultOn: true, externalDraftModel: nil,
                                         mtpConfigured: true, sink: { observed.set($0) })
        let sse = """
        data: {"choices":[{"index":0,"delta":{"content":"1"},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: \(Self.statsChunk)

        data: [DONE]

        """
        let transport = OneShotTransport(body: sse)
        let config = ProviderConfig(baseURL: URL(string: "http://10.0.0.128:1234/v1")!, apiKey: nil, model: "qwen3.8-9b-q6k")
        let provider = OpenAICompatibleProvider(config: config, transport: transport, wireExtension: wire)
        var events: [ModelEvent] = []
        for try await event in try await provider.stream(ModelRequest(model: ModelID("qwen3.8-9b-q6k"), messages: [])) {
            events.append(event)
        }
        #expect(events.contains(.textDelta("1")))
        #expect(events.contains { if case .usage = $0 { return true } else { return false } })
        #expect(observed.value?.draftedTokens == 551)
    }

    // MARK: 9–10. Offline and fallback

    @Test("an offline endpoint is reported as unreachable, not as an empty model list")
    func offlineIsNotEmpty() async {
        let status = await LMStudioDiscovery.discover(
            baseURL: "http://10.0.0.128:1234/v1", modelID: "m",
            httpClient: Self.client([:], failing: ["/api/v1/models", "/v1/models"]))
        #expect(status.source == .unreachable)
        #expect(status.runtimeContextTokens == nil)
        #expect(status.note?.isEmpty == false)
    }

    @Test("when the native endpoint is unavailable, /v1/models is the fallback and claims nothing more")
    func fallbackToOpenAIList() async {
        let status = await LMStudioDiscovery.discover(
            baseURL: "http://10.0.0.128:1234/v1", modelID: "qwen3.8-9b-q6k",
            httpClient: Self.client(["/v1/models": (200, #"{"data":[{"id":"qwen3.8-9b-q6k"}]}"#)]))
        #expect(status.source == .openAICompatibleFallback)
        #expect(status.modelKey == "qwen3.8-9b-q6k")
        #expect(status.runtimeContextTokens == nil, "回退路径不知道运行时上下文，不能编造")
        #expect(status.mtpEnabled == nil)
    }

    @Test("the registry keeps the last observation across a fresh discovery")
    func registryKeepsObservation() async throws {
        let registry = LocalRuntimeRegistry()
        registry.record(await discover(), providerID: "lmstudio")
        let metrics = try #require(LMStudioChatExtension.metrics(fromPayload: Self.statsChunk, externalDraftModel: nil, mtpConfigured: true))
        registry.observe(metrics, providerID: "lmstudio")
        registry.record(await discover(), providerID: "lmstudio")
        #expect(registry.status(providerID: "lmstudio")?.lastSpeculative?.acceptedTokens == 480)
    }

    @Test("providers.json carries localRuntime and the schema accepts only real backends")
    func configurationRoundTrip() throws {
        let json = """
        {"providers":{"lmstudio":{"name":"LM Studio","adapter":"openai-compatible",
          "options":{"baseURL":"http://10.0.0.128:1234/v1","localRuntime":{"backend":"lmstudio"}},
          "models":{"qwen3.8-9b-q6k":{"name":"qwen"}}}}}
        """
        let config = try JSONDecoder().decode(ProvidersConfiguration.self, from: Data(json.utf8))
        #expect(config.providers["lmstudio"]?.options.localRuntime?.backend == .lmStudio)
        let reencoded = try JSONDecoder().decode(ProvidersConfiguration.self, from: JSONEncoder().encode(config))
        #expect(reencoded.providers["lmstudio"]?.options.localRuntime == config.providers["lmstudio"]?.options.localRuntime)
        #expect(LocalInferenceBackend.allCases == [.lmStudio], "其他运行时不得以占位实现出现")
    }
}

private final class MetricsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SpeculativeDecodingMetrics?
    func set(_ value: SpeculativeDecodingMetrics) { lock.lock(); stored = value; lock.unlock() }
    var value: SpeculativeDecodingMetrics? { lock.lock(); defer { lock.unlock() }; return stored }
}

private struct OneShotTransport: ProviderHTTPTransport {
    let body: String
    func send(_ request: URLRequest, context: ProviderHTTPRequestContext) async throws -> ProviderHTTPResponse {
        let data = Data(body.utf8)
        return ProviderHTTPResponse(statusCode: 200, body: AsyncThrowingStream { continuation in
            continuation.yield(data)
            continuation.finish()
        })
    }
}
