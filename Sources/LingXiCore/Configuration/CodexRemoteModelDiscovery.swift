import Foundation
import LingXiProtocol

public enum CodexRemoteModelDiscovery {
    public static let defaultChatGPTModelsEndpoint = URL(string: "https://chatgpt.com/backend-api/models")!
    public static let fallbackOpenAIModelsEndpoint = URL(string: "https://api.openai.com/v1/models")!

    public static func discoverModels(
        tokens: OAuthTokens,
        endpoint: URL? = nil,
        requestProfile: OverlayRequestProfile? = nil,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async throws -> [DiscoveredRemoteModel] {
        let targetURL = endpoint ?? defaultChatGPTModelsEndpoint
        var request = URLRequest(url: targetURL)
        request.timeoutInterval = 10
        request.httpMethod = "GET"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let ua = requestProfile?.userAgentProfile {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        } else {
            request.setValue("LingXiAgent-Codex/2.0 (macOS)", forHTTPHeaderField: "User-Agent")
        }

        if let headers = requestProfile?.requiredHeaders {
            for (k, v) in headers {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }

        let data: Data
        let response: URLResponse
        if let httpClient {
            (data, response) = try await httpClient(request)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CoreError(code: .provider, message: "ChatGPT remote model catalog request failed with HTTP \(status)")
        }

        return try parseRemoteModels(from: data)
    }

    public static func parseRemoteModels(from data: Data) throws -> [DiscoveredRemoteModel] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        // 1. Check ChatGPT backend structure: { "models": [ { "slug": "...", ... } ] } or { "categories": ... }
        if let rawModels = json["models"] as? [[String: Any]] {
            return rawModels.compactMap { dict in
                parseChatGPTModelDict(dict)
            }
        }

        // 2. Check standard OpenAI structure: { "data": [ { "id": "...", ... } ] }
        if let rawData = json["data"] as? [[String: Any]] {
            return rawData.compactMap { dict in
                parseOpenAIModelDict(dict)
            }
        }

        // 3. Fallback: Check if top level is an array
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap { dict in
                parseChatGPTModelDict(dict) ?? parseOpenAIModelDict(dict)
            }
        }

        return []
    }

    private static func parseChatGPTModelDict(_ dict: [String: Any]) -> DiscoveredRemoteModel? {
        guard let slug = (dict["slug"] as? String) ?? (dict["id"] as? String), !slug.isEmpty else {
            return nil
        }
        let displayName = (dict["display_name"] as? String) ?? (dict["title"] as? String) ?? (dict["name"] as? String) ?? slug
        let priority = (dict["priority"] as? Int) ?? 100
        let visibility = (dict["visibility"] as? String) ?? "public"
        let isDefault = (dict["is_default"] as? Bool) ?? (dict["default"] as? Bool) ?? false
        let minClientVersion = dict["minimal_client_version"] as? String

        var efforts: [ReasoningEffort] = []
        let tags = (dict["tags"] as? [String]) ?? []
        if let rawEfforts = dict["supported_reasoning_levels"] as? [String] {
            efforts = rawEfforts.compactMap { ReasoningEffort(rawValue: $0) }
        } else if let rawEfforts = dict["supported_reasoning_efforts"] as? [String] {
            efforts = rawEfforts.compactMap { ReasoningEffort(rawValue: $0) }
        } else if slug.contains("thinking") || slug.contains("-t-") || tags.contains("thinking") {
            efforts = [.auto, .low, .high, .max]
        }

        let capabilities = dict["capabilities"] as? [String: Any]
        let toolCalling = (capabilities?["tools"] as? Bool) ?? (capabilities?["tool_calling"] as? Bool) ?? true
        let vision = (capabilities?["vision"] as? Bool) ?? false

        let maxTokens = (dict["max_tokens"] as? Int)
        let contextWindow = (dict["context_window"] as? Int) ?? (dict["contextWindow"] as? Int) ?? maxTokens
        let maxOutputTokens = (dict["max_output_tokens"] as? Int) ?? (dict["maxOutputTokens"] as? Int)

        return DiscoveredRemoteModel(
            id: slug,
            displayName: displayName,
            priority: priority,
            visibility: visibility,
            isDefault: isDefault,
            supportedReasoningEfforts: efforts,
            minimalClientVersion: minClientVersion,
            contextWindow: contextWindow,
            maxOutputTokens: maxOutputTokens,
            toolCalling: toolCalling,
            vision: vision,
            metadataIncomplete: false
        )
    }

    private static func parseOpenAIModelDict(_ dict: [String: Any]) -> DiscoveredRemoteModel? {
        guard let id = dict["id"] as? String, !id.isEmpty else {
            return nil
        }
        let displayName = (dict["name"] as? String) ?? id
        return DiscoveredRemoteModel(
            id: id,
            displayName: displayName,
            priority: 100,
            visibility: "public",
            isDefault: false,
            supportedReasoningEfforts: [],
            minimalClientVersion: nil,
            contextWindow: nil,
            maxOutputTokens: nil,
            toolCalling: true,
            vision: false,
            metadataIncomplete: false
        )
    }
}
