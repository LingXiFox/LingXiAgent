import Foundation
import LingXiProtocol

// MARK: - Adapter protocol

/// Normalizes one upstream model-listing wire format into `DiscoveredRemoteModel`.
///
/// Every provider-specific listing shape lives in this file. Nothing downstream
/// of an adapter is allowed to branch on a provider or product name to decide
/// what a model list looks like — the `kind` carried by the registry's
/// discovery profile selects the parser, and that is the whole mechanism.
public protocol ModelListAdapter: Sendable {
    /// The `kind` string this adapter handles, matching the registry value.
    var kind: String { get }
    /// Converts a response body into discovered models.
    func parse(_ data: Data) throws -> [DiscoveredRemoteModel]
}

public enum ModelDiscoveryError: Error, LocalizedError, Equatable {
    case unsupportedKind(String)
    case malformedResponse(String)
    case emptyListing(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedKind(kind): return "No model-list adapter for kind '\(kind)'"
        case let .malformedResponse(detail): return "Malformed model listing: \(detail)"
        case let .emptyListing(source): return "Model listing from '\(source)' contained no models"
        }
    }
}

// MARK: - Registry

public enum ModelListAdapters {
    /// Adapter kinds understood by this client. The strings match the registry's
    /// `discoveryProfile.kind` values.
    public static let openAIModels = "openai-models"
    public static let openRouterModels = "openrouter-models"
    public static let anthropicModels = "anthropic-models"
    public static let geminiModels = "gemini-models"
    public static let ollamaTags = "ollama-tags"
    public static let plainArray = "plain-array"
    /// ChatGPT's subscription backend, which uses its own envelope. This one is
    /// LingXi-maintained because it is not a documented public API.
    public static let chatGPTBackend = "chatgpt-backend"

    private static let registry: [String: any ModelListAdapter] = [
        openAIModels: OpenAIModelsAdapter(),
        openRouterModels: OpenRouterModelsAdapter(),
        anthropicModels: AnthropicModelsAdapter(),
        geminiModels: GeminiModelsAdapter(),
        ollamaTags: OllamaTagsAdapter(),
        plainArray: PlainArrayAdapter(),
        chatGPTBackend: ChatGPTBackendAdapter(),
    ]

    public static func adapter(for kind: String) -> (any ModelListAdapter)? {
        registry[kind]
    }

    /// Parses a listing, trying the declared kind first and falling back to the
    /// most permissive adapter when the declared kind is unknown. A registry
    /// that adds a new kind therefore degrades to "may not extract every field"
    /// instead of "this product shows no models at all".
    public static func parse(kind: String, data: Data, source: String) throws -> [DiscoveredRemoteModel] {
        if let adapter = registry[kind] {
            return try adapter.parse(data)
        }
        return try ChatGPTBackendAdapter().parse(data)
    }
}

// MARK: - OpenAI-style: {"data":[{"id":"…","owned_by":"…"}]}

public struct OpenAIModelsAdapter: ModelListAdapter {
    public let kind = ModelListAdapters.openAIModels
    public init() {}

    public func parse(_ data: Data) throws -> [DiscoveredRemoteModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelDiscoveryError.malformedResponse("response is not a JSON object")
        }
        guard let items = root["data"] as? [[String: Any]] else {
            // Some OpenAI-compatible servers answer with a bare array.
            if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return normalize(array)
            }
            throw ModelDiscoveryError.malformedResponse("missing 'data' array")
        }
        return normalize(items)
    }

    private func normalize(_ items: [[String: Any]]) -> [DiscoveredRemoteModel] {
        items.compactMap { dict in
            guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
            let name = (dict["name"] as? String) ?? (dict["display_name"] as? String) ?? id
            let source = (dict["name"] as? String != nil) ? "name" : ((dict["display_name"] as? String != nil) ? "display_name" : "id")
            return DiscoveredRemoteModel(
                id: id,
                displayName: name,
                contextWindow: dict["context_window"] as? Int,
                maxOutputTokens: dict["max_output_tokens"] as? Int,
                toolCalling: (dict["tool_calling"] as? Bool) ?? true,
                vision: (dict["vision"] as? Bool) ?? false,
                upstreamModelID: id,
                displayNameSource: source
            )
        }
    }
}

// MARK: - OpenRouter: richer per-model metadata

public struct OpenRouterModelsAdapter: ModelListAdapter {
    public let kind = ModelListAdapters.openRouterModels
    public init() {}

    public func parse(_ data: Data) throws -> [DiscoveredRemoteModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else {
            throw ModelDiscoveryError.malformedResponse("missing 'data' array")
        }
        return items.compactMap { dict in
            guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
            let name = (dict["name"] as? String) ?? id
            let source = (dict["name"] as? String != nil) ? "name" : "id"

            let architecture = dict["architecture"] as? [String: Any]
            let inputModalities = (architecture?["input_modalities"] as? [String]) ?? []
            let outputModalities = (architecture?["output_modalities"] as? [String]) ?? []
            let supported = (dict["supported_parameters"] as? [String]) ?? []
            let topProvider = dict["top_provider"] as? [String: Any]

            let reasoning = supported.contains("reasoning") || supported.contains("reasoning_effort")
            let modalities = Array(Set(inputModalities + outputModalities)).sorted()

            return DiscoveredRemoteModel(
                id: id,
                displayName: name,
                supportedReasoningEfforts: reasoning ? [.low, .medium, .high] : [],
                contextWindow: dict["context_length"] as? Int,
                maxOutputTokens: topProvider?["max_completion_tokens"] as? Int,
                toolCalling: supported.contains("tools"),
                vision: inputModalities.contains("image"),
                capabilities: DiscoveredModelCapabilities(
                    parallelToolCalling: supported.isEmpty ? nil : supported.contains("parallel_tool_calls"),
                    structuredOutput: supported.isEmpty ? nil : supported.contains("response_format"),
                    cache: nil,
                    reasoning: supported.isEmpty ? nil : reasoning,
                    reasoningMode: reasoning ? "effort" : nil,
                    modalities: modalities.isEmpty ? nil : modalities
                ),
                upstreamModelID: id,
                displayNameSource: source
            )
        }
    }
}

// MARK: - Anthropic: {"data":[{"id":"…","display_name":"…","type":"model"}]}

public struct AnthropicModelsAdapter: ModelListAdapter {
    public let kind = ModelListAdapters.anthropicModels
    public init() {}

    public func parse(_ data: Data) throws -> [DiscoveredRemoteModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else {
            throw ModelDiscoveryError.malformedResponse("missing 'data' array")
        }
        return items.compactMap { dict in
            guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
            let name = (dict["display_name"] as? String) ?? id
            let source = (dict["display_name"] as? String != nil) ? "display_name" : "id"
            return DiscoveredRemoteModel(
                id: id,
                displayName: name,
                upstreamModelID: id,
                displayNameSource: source
            )
        }
    }
}

// MARK: - Gemini: {"models":[{"name":"models/…","displayName":"…"}]}

public struct GeminiModelsAdapter: ModelListAdapter {
    public let kind = ModelListAdapters.geminiModels
    public init() {}

    public func parse(_ data: Data) throws -> [DiscoveredRemoteModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["models"] as? [[String: Any]] else {
            throw ModelDiscoveryError.malformedResponse("missing 'models' array")
        }
        return items.compactMap { dict in
            guard let raw = dict["name"] as? String, !raw.isEmpty else { return nil }
            // Gemini prefixes every model with the "models/" collection segment;
            // bare ID is used for registry catalog mapping, while upstreamModelID
            // stores the verbatim upstream identifier ("models/...").
            let id = raw.hasPrefix("models/") ? String(raw.dropFirst("models/".count)) : raw
            guard !id.isEmpty else { return nil }
            let methods = (dict["supportedGenerationMethods"] as? [String]) ?? []
            let name = (dict["displayName"] as? String) ?? id
            let source = (dict["displayName"] as? String != nil) ? "displayName" : "name"
            return DiscoveredRemoteModel(
                id: id,
                displayName: name,
                contextWindow: dict["inputTokenLimit"] as? Int,
                maxOutputTokens: dict["outputTokenLimit"] as? Int,
                toolCalling: methods.isEmpty ? true : methods.contains("generateContent"),
                upstreamModelID: raw,
                displayNameSource: source
            )
        }
    }
}

// MARK: - Ollama: {"models":[{"name":"llama3.2:latest"}]}

public struct OllamaTagsAdapter: ModelListAdapter {
    public let kind = ModelListAdapters.ollamaTags
    public init() {}

    public func parse(_ data: Data) throws -> [DiscoveredRemoteModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["models"] as? [[String: Any]] else {
            throw ModelDiscoveryError.malformedResponse("missing 'models' array")
        }
        return items.compactMap { dict in
            let id = (dict["model"] as? String) ?? (dict["name"] as? String)
            guard let id, !id.isEmpty else { return nil }
            let name = (dict["name"] as? String) ?? id
            let source = (dict["name"] as? String != nil) ? "name" : "model"
            return DiscoveredRemoteModel(
                id: id,
                displayName: name,
                upstreamModelID: id,
                displayNameSource: source
            )
        }
    }
}

// MARK: - Bare JSON array

public struct PlainArrayAdapter: ModelListAdapter {
    public let kind = ModelListAdapters.plainArray
    public init() {}

    public func parse(_ data: Data) throws -> [DiscoveredRemoteModel] {
        if let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let parsed = objects.compactMap { dict -> DiscoveredRemoteModel? in
                let id = (dict["id"] as? String) ?? (dict["name"] as? String)
                guard let id, !id.isEmpty else { return nil }
                let name = (dict["name"] as? String) ?? id
                let source = (dict["name"] as? String != nil) ? "name" : "id"
                return DiscoveredRemoteModel(id: id, displayName: name, upstreamModelID: id, displayNameSource: source)
            }
            if !parsed.isEmpty { return parsed }
        }
        if let names = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return names.filter { !$0.isEmpty }.map { DiscoveredRemoteModel(id: $0, displayName: $0, upstreamModelID: $0, displayNameSource: "name") }
        }
        throw ModelDiscoveryError.malformedResponse("not a JSON array of models")
    }
}

// MARK: - ChatGPT subscription backend

/// Parses the ChatGPT backend model listing, which uses `slug`/`title` and
/// carries capability and reasoning metadata inline.
///
/// This format is LingXi-maintained rather than derived from public
/// documentation: it backs OAuth-subscription products, whose catalogs the
/// public registry deliberately does not attempt to discover.
public struct ChatGPTBackendAdapter: ModelListAdapter {
    public let kind = ModelListAdapters.chatGPTBackend
    public init() {}

    public func parse(_ data: Data) throws -> [DiscoveredRemoteModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelDiscoveryError.malformedResponse("response is not a JSON object")
        }
        if let items = root["models"] as? [[String: Any]] {
            return items.compactMap(Self.normalize)
        }
        if let items = root["data"] as? [[String: Any]] {
            return items.compactMap(Self.normalize)
        }
        if let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return items.compactMap(Self.normalize)
        }
        throw ModelDiscoveryError.malformedResponse("unrecognized ChatGPT backend envelope")
    }

    private static func parseEffort(_ raw: String) -> ReasoningEffort? {
        ReasoningEffort(rawValue: raw.lowercased())
    }

    static func normalize(_ dict: [String: Any]) -> DiscoveredRemoteModel? {
        let id = (dict["slug"] as? String) ?? (dict["id"] as? String)
        guard let id, !id.isEmpty else { return nil }

        let displayName = (dict["display_name"] as? String)
            ?? (dict["displayName"] as? String)
            ?? (dict["title"] as? String)
            ?? (dict["name"] as? String)
            ?? id
        let source = (dict["title"] as? String != nil) ? "title"
            : ((dict["name"] as? String != nil) ? "name"
            : ((dict["display_name"] as? String != nil) ? "display_name" : "slug"))

        var efforts: [ReasoningEffort] = []
        if let rawObjects = dict["supported_reasoning_levels"] as? [[String: Any]] {
            efforts = rawObjects.compactMap { obj in
                (obj["effort"] as? String).flatMap(parseEffort)
            }
        } else if let raw = dict["supported_reasoning_levels"] as? [String] {
            efforts = raw.compactMap(parseEffort)
        } else if let raw = dict["supported_reasoning_efforts"] as? [String] {
            efforts = raw.compactMap(parseEffort)
        }

        let capabilities = dict["capabilities"] as? [String: Any]
        let inputModalities = (dict["input_modalities"] as? [String]) ?? []
        let maxTokens = dict["max_tokens"] as? Int

        let (canonicalID, variantKind) = CanonicalModelParser.parseSlug(id)

        let hasReasoning = !efforts.isEmpty || (capabilities?["reasoning"] as? Bool ?? false)
        return DiscoveredRemoteModel(
            id: id,
            displayName: displayName,
            priority: (dict["priority"] as? Int) ?? 100,
            visibility: (dict["visibility"] as? String) ?? "public",
            isDefault: (dict["is_default"] as? Bool) ?? (dict["default"] as? Bool) ?? false,
            supportedReasoningEfforts: efforts,
            minimalClientVersion: dict["minimal_client_version"] as? String,
            contextWindow: (dict["context_window"] as? Int) ?? (dict["contextWindow"] as? Int) ?? maxTokens,
            maxOutputTokens: (dict["max_output_tokens"] as? Int) ?? (dict["maxOutputTokens"] as? Int),
            toolCalling: (dict["tool_mode"] as? String != nil) || (capabilities?["tools"] as? Bool) ?? (capabilities?["tool_calling"] as? Bool) ?? true,
            vision: inputModalities.contains("image") || (capabilities?["vision"] as? Bool ?? false),
            capabilities: DiscoveredModelCapabilities(
                reasoning: hasReasoning ? true : nil,
                reasoningMode: hasReasoning ? "effort" : nil,
                modalities: inputModalities.isEmpty ? nil : inputModalities
            ),
            upstreamModelID: id,
            displayNameSource: source,
            canonicalModelID: canonicalID,
            backendVariant: variantKind.rawValue
        )
    }
}

// MARK: - Request construction

/// Applies a credential to a discovery request in whatever shape the profile's
/// wire format expects, and returns the URL to call.
///
/// The credential only ever travels from the user's own store to the upstream
/// vendor. It is never sent to the LingXi registry.
public enum DiscoveryRequestBuilder {
    public static func build(
        profile: RegistryDiscoveryProfile,
        credential: String?
    ) -> URLRequest? {
        guard let url = URL(string: profile.url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LingXiAgent/2.0 (macOS; discovery)", forHTTPHeaderField: "User-Agent")

        for (key, value) in profile.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }

        guard let credential, !credential.isEmpty else {
            // A public profile needs no credential; anything else without one
            // is left unauthenticated so the upstream's own 401 is what the
            // caller sees, rather than a fabricated local error.
            return request
        }

        switch profile.auth {
        case "bearer":
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        case "apiKeyHeader":
            request.setValue(credential, forHTTPHeaderField: "x-api-key")
        case "apiKeyQuery":
            let param = profile.authKeyParam ?? "key"
            if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var items = components.queryItems ?? []
                items.append(URLQueryItem(name: param, value: credential))
                components.queryItems = items
                if let rebuilt = components.url {
                    request.url = rebuilt
                }
            }
        case "none", .none:
            break
        default:
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
