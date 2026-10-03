import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiProtocol

/// A runtime-specific dialect on top of the shared Chat Completions wire.
///
/// Two hooks and nothing else: extra top-level request fields, and a read-only look at each SSE
/// payload. The shared adapter keeps owning messages, tools, streaming and events, so a local
/// runtime cannot drift into a second, subtly different copy of the OpenAI protocol.
public protocol ChatCompletionsWireExtension: Sendable {
    func additionalBodyFields(for request: ModelRequest) -> [String: JSONValue]
    func observe(ssePayload: String, request: ModelRequest)
}

// MARK: - Native discovery DTOs (LM Studio `GET /api/v1/models`)

/// Shapes taken from a live LM Studio response, not from documentation: where the two disagree
/// the wire wins.
struct LMStudioNativeModelList: Decodable, Sendable {
    let models: [Model]

    struct Model: Decodable, Sendable {
        let type: String?
        let key: String
        let displayName: String?
        let architecture: String?
        let quantization: Quantization?
        let sizeBytes: Int?
        let loadedInstances: [Instance]?
        let maxContextLength: Int?
        let capabilities: Capabilities?

        enum CodingKeys: String, CodingKey {
            case type, key, architecture, quantization, capabilities
            case displayName = "display_name"
            case sizeBytes = "size_bytes"
            case loadedInstances = "loaded_instances"
            case maxContextLength = "max_context_length"
        }
    }

    struct Quantization: Decodable, Sendable {
        let name: String?
        let bitsPerWeight: Double?
        enum CodingKeys: String, CodingKey {
            case name
            case bitsPerWeight = "bits_per_weight"
        }
    }

    struct Instance: Decodable, Sendable {
        let id: String
        let config: Config?
    }

    struct Config: Decodable, Sendable {
        let contextLength: Int?
        let evalBatchSize: Int?
        let parallel: Int?
        let flashAttention: Bool?
        let offloadKVCacheToGPU: Bool?
        let speculativeDraftMTP: Bool?
        let speculativeDraftModel: String?
        let speculativeDraftMaxTokens: Int?
        let speculativeDraftMinContinueProbability: Double?

        enum CodingKeys: String, CodingKey {
            case parallel
            case contextLength = "context_length"
            case evalBatchSize = "eval_batch_size"
            case flashAttention = "flash_attention"
            case offloadKVCacheToGPU = "offload_kv_cache_to_gpu"
            case speculativeDraftMTP = "speculative_draft_mtp"
            case speculativeDraftModel = "speculative_draft_model"
            case speculativeDraftMaxTokens = "speculative_draft_max_tokens"
            case speculativeDraftMinContinueProbability = "speculative_draft_min_continue_probability"
        }
    }

    struct Capabilities: Decodable, Sendable {
        let vision: Bool?
        let trainedForToolUse: Bool?
        let reasoning: Reasoning?
        enum CodingKeys: String, CodingKey {
            case vision, reasoning
            case trainedForToolUse = "trained_for_tool_use"
        }
    }

    struct Reasoning: Decodable, Sendable {
        let allowedOptions: [String]?
        let defaultOption: String?
        enum CodingKeys: String, CodingKey {
            case allowedOptions = "allowed_options"
            case defaultOption = "default"
        }
    }
}

// MARK: - Discovery

enum LMStudioDiscovery {
    typealias HTTPClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The server root: the OpenAI-compatible surface lives under `/v1`, the native one under
    /// `/api/v1`, both off the same host and port.
    static func serverRoot(of baseURL: String) -> String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/v1") { value.removeLast(3) }
        return value
    }

    /// Discovers what the server has for `modelID`, which may be a model key (`qwen3.8-9b`) or a
    /// loaded instance id (`qwen3.8-9b-q6k`) — the latter is what requests are addressed to once
    /// LM Studio has given an instance its own identifier.
    static func discover(baseURL: String, modelID: String, credential: String? = nil,
                         timeout: TimeInterval = 5, httpClient: HTTPClient? = nil) async -> LocalRuntimeModelStatus {
        let root = serverRoot(of: baseURL)
        let endpoint = URL(string: root)?.host.map { host in URL(string: root)?.port.map { "\(host):\($0)" } ?? host } ?? root
        let client: HTTPClient = httpClient ?? { try await URLSession.shared.data(for: $0) }

        var nativeNote: String?
        if let url = URL(string: root + "/api/v1/models") {
            do {
                let (data, response) = try await client(request(url, credential: credential, timeout: timeout))
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code), let list = try? JSONDecoder().decode(LMStudioNativeModelList.self, from: data) {
                    return Self.status(from: list, modelID: modelID, endpoint: endpoint)
                }
                nativeNote = (200..<300).contains(code) ? "原生 /api/v1/models 返回了无法识别的结构" : "原生 /api/v1/models 返回 HTTP \(code)"
            } catch {
                // A transport failure on the native endpoint usually means the server is down, but
                // the fallback is still asked: a proxy may expose only the OpenAI surface.
                nativeNote = "原生 /api/v1/models 无法连接：\(error.localizedDescription)"
            }
        }

        if let url = URL(string: root + "/v1/models") {
            do {
                let (data, response) = try await client(request(url, credential: credential, timeout: timeout))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) {
                    let ids = ProviderConnectivityProbe.modelIDs(in: data)
                    return LocalRuntimeModelStatus(
                        backend: .lmStudio, endpoint: endpoint, source: .openAICompatibleFallback,
                        note: [nativeNote, "仅 OpenAI 兼容 /v1/models 可用，运行时状态（上下文、量化、MTP）未知"]
                            .compactMap { $0 }.joined(separator: "；"),
                        modelKey: ids.contains(modelID) ? modelID : nil)
                }
                return unreachable(endpoint, note: [nativeNote, "/v1/models 返回 HTTP \(status)"].compactMap { $0 }.joined(separator: "；"))
            } catch {
                return unreachable(endpoint, note: [nativeNote, "/v1/models 无法连接：\(error.localizedDescription)"]
                    .compactMap { $0 }.joined(separator: "；"))
            }
        }
        return unreachable(endpoint, note: "Base URL 无效")
    }

    /// The chat models a server offers, addressed the way requests address them: a loaded
    /// instance by its instance id, an unloaded model by its key. Embedding models are left out —
    /// they cannot hold a conversation. Nil when the server cannot be reached at all, which is
    /// different from a server that answers with no models.
    static func listChatModels(baseURL: String, credential: String? = nil, timeout: TimeInterval = 5,
                               httpClient: HTTPClient? = nil) async -> [String]? {
        let root = serverRoot(of: baseURL)
        let client: HTTPClient = httpClient ?? { try await URLSession.shared.data(for: $0) }
        if let url = URL(string: root + "/api/v1/models"),
           let (data, response) = try? await client(request(url, credential: credential, timeout: timeout)),
           ((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false),
           let list = try? JSONDecoder().decode(LMStudioNativeModelList.self, from: data) {
            return list.models.filter { ($0.type ?? "llm") == "llm" }.flatMap { model -> [String] in
                let instances = model.loadedInstances?.map(\.id) ?? []
                return instances.isEmpty ? [model.key] : instances
            }
        }
        guard let url = URL(string: root + "/v1/models"),
              let (data, response) = try? await client(request(url, credential: credential, timeout: timeout)),
              ((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false) else { return nil }
        return ProviderConnectivityProbe.modelIDs(in: data).filter { !$0.lowercased().contains("embed") }
    }

    static func status(from list: LMStudioNativeModelList, modelID: String, endpoint: String) -> LocalRuntimeModelStatus {
        let byInstance = list.models.first { $0.loadedInstances?.contains { $0.id == modelID } == true }
        guard let model = byInstance ?? list.models.first(where: { $0.key == modelID }) else {
            return LocalRuntimeModelStatus(backend: .lmStudio, endpoint: endpoint, source: .native,
                                           note: "LM Studio 未列出模型 \(modelID)")
        }
        // Prefer the instance the request is addressed to; otherwise the first loaded one.
        let instance = model.loadedInstances?.first { $0.id == modelID } ?? model.loadedInstances?.first
        let config = instance?.config
        let draft = config?.speculativeDraftModel.flatMap { $0.isEmpty ? nil : $0 }
        return LocalRuntimeModelStatus(
            backend: .lmStudio, endpoint: endpoint, source: .native,
            note: instance == nil ? "模型未加载：运行时上下文未知" : nil,
            modelKey: model.key,
            loadedInstanceID: instance?.id,
            isLoaded: instance != nil,
            architecture: model.architecture,
            quantization: model.quantization?.name,
            quantizationBits: model.quantization?.bitsPerWeight,
            sizeBytes: model.sizeBytes,
            // Only a loaded instance has a runtime context. Max context is what the weights allow.
            runtimeContextTokens: config?.contextLength,
            modelMaxContextTokens: model.maxContextLength,
            toolUse: model.capabilities?.trainedForToolUse,
            vision: model.capabilities?.vision,
            reasoningOptions: model.capabilities?.reasoning?.allowedOptions,
            reasoningDefault: model.capabilities?.reasoning?.defaultOption,
            flashAttention: config?.flashAttention,
            kvCacheOnGPU: config?.offloadKVCacheToGPU,
            evalBatchSize: config?.evalBatchSize,
            parallel: config?.parallel,
            mtpEnabled: config?.speculativeDraftMTP,
            externalDraftModel: draft,
            draftMaxTokens: config?.speculativeDraftMaxTokens,
            draftMinContinueProbability: config?.speculativeDraftMinContinueProbability)
    }

    private static func unreachable(_ endpoint: String, note: String) -> LocalRuntimeModelStatus {
        LocalRuntimeModelStatus(backend: .lmStudio, endpoint: endpoint, source: .unreachable, note: note)
    }

    private static func request(_ url: URL, credential: String?, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credential, !credential.isEmpty {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// The reasoning capability the GUI may offer. A toggle model gets exactly Off and On; it must
    /// not grow Low/Medium/High it cannot honour.
    static func reasoningCapability(_ status: LocalRuntimeModelStatus) -> ReasoningCapability? {
        guard let options = status.reasoningOptions?.map({ $0.lowercased() }), !options.isEmpty else { return nil }
        if Set(options).isSubset(of: ["off", "on"]) {
            let defaultOn = (status.reasoningDefault?.lowercased() ?? "on") == "on"
            return ReasoningCapability(mode: .toggle,
                                       supportedEfforts: options.contains("off") ? [.off, .auto] : [.auto],
                                       defaultEffort: defaultOn ? .auto : .off,
                                       emitsVisibleReasoning: true)
        }
        let efforts = options.compactMap { ReasoningEffort(rawValue: $0 == "none" ? "off" : $0) }
        return efforts.isEmpty ? nil : ReasoningCapability(mode: .effort, supportedEfforts: efforts,
                                                           defaultEffort: .auto, emitsVisibleReasoning: true)
    }
}

// MARK: - Request / response dialect

/// LM Studio's dialect on the Chat Completions wire.
///
/// Request side, verified against a live server: `reasoning_effort: "none"` turns thinking off
/// (`"reasoning": "off"` is accepted and silently ignored), and a toggle model treats every other
/// effort as "on". `draft_model` is sent only when the user configured an external draft model;
/// MTP needs nothing in the request.
///
/// Response side: the final usage chunk carries a top-level `stats` object with draft counts.
struct LMStudioChatExtension: ChatCompletionsWireExtension {
    let reasoningToggle: Bool
    let reasoningDefaultOn: Bool
    let externalDraftModel: String?
    let mtpConfigured: Bool
    let sink: @Sendable (SpeculativeDecodingMetrics) -> Void

    func additionalBodyFields(for request: ModelRequest) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        if reasoningToggle, let effort = request.reasoning?.lowercased() {
            if effort == "off" || effort == "none" {
                fields["reasoning_effort"] = .string("none")
            } else if !reasoningDefaultOn {
                fields["reasoning_effort"] = .string("medium")
            }
        }
        if let externalDraftModel, !externalDraftModel.isEmpty {
            fields["draft_model"] = .string(externalDraftModel)
        }
        return fields
    }

    func observe(ssePayload: String, request: ModelRequest) {
        guard ssePayload.contains("\"stats\""), let metrics = Self.metrics(fromPayload: ssePayload,
                                                                         externalDraftModel: externalDraftModel,
                                                                         mtpConfigured: mtpConfigured) else { return }
        sink(metrics)
    }

    /// Reads draft statistics from one SSE payload (or a whole non-streaming body). Absent counts
    /// stay nil; nothing is estimated.
    static func metrics(fromPayload payload: String, externalDraftModel: String?, mtpConfigured: Bool) -> SpeculativeDecodingMetrics? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stats = object["stats"] as? [String: Any] else { return nil }
        let drafted = stats["total_draft_tokens_count"] as? Int
        let accepted = stats["accepted_draft_tokens_count"] as? Int
        let rejected = stats["rejected_draft_tokens_count"] as? Int
        let ignored = stats["ignored_draft_tokens_count"] as? Int
        guard drafted != nil || accepted != nil || rejected != nil else { return nil }
        let mode: SpeculativeDecodingMode
        if let externalDraftModel, !externalDraftModel.isEmpty { mode = .externalDraftModel }
        else if mtpConfigured { mode = .mtp }
        else { mode = .unavailable }
        return SpeculativeDecodingMetrics(backend: .lmStudio, mode: mode, draftModel: externalDraftModel,
                                          draftedTokens: drafted, acceptedTokens: accepted,
                                          rejectedTokens: rejected, ignoredTokens: ignored)
    }
}

// MARK: - Registry

/// What Core currently knows about each local-runtime provider, keyed by provider id.
///
/// Written by discovery at model assembly and by the response observer; read by the model list
/// and the Observatory. Reading it never triggers a network call, so opening the Observatory
/// cannot change what the runtime does.
final class LocalRuntimeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String: LocalRuntimeModelStatus] = [:]

    func record(_ status: LocalRuntimeModelStatus, providerID: String) {
        lock.lock(); defer { lock.unlock() }
        var next = status
        // A fresh discovery keeps the last observation; it describes the same server.
        if next.lastSpeculative == nil { next.lastSpeculative = statuses[providerID]?.lastSpeculative }
        statuses[providerID] = next
    }

    func observe(_ metrics: SpeculativeDecodingMetrics, providerID: String) {
        lock.lock(); defer { lock.unlock() }
        statuses[providerID]?.lastSpeculative = metrics
    }

    func status(providerID: String) -> LocalRuntimeModelStatus? {
        lock.lock(); defer { lock.unlock() }
        return statuses[providerID]
    }
}
