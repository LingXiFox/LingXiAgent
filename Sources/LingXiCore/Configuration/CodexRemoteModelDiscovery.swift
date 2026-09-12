import Foundation
import LingXiProtocol

public enum CodexRemoteModelDiscovery {
    public static var defaultCodexModelsEndpoint: URL {
        URL(string: "https://chatgpt.com/backend-api/codex/models?client_version=\(ClientFingerprint.codexVersion())")!
    }
    public static var defaultChatGPTModelsEndpoint: URL {
        defaultCodexModelsEndpoint
    }

    /// Extracts the chatgpt_account_id claim from a JWT access token if present.
    public static func extractChatGPTAccountID(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let auth = json["https://api.openai.com/auth"] as? [String: Any],
           let accountID = auth["chatgpt_account_id"] as? String, !accountID.isEmpty {
            return accountID
        }
        if let accountID = json["chatgpt_account_id"] as? String, !accountID.isEmpty {
            return accountID
        }
        return nil
    }

    public static func discoverModels(
        tokens: OAuthTokens,
        endpoint: URL? = nil,
        requestProfile: OverlayRequestProfile? = nil,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async throws -> [DiscoveredRemoteModel] {
        let candidateEndpoints: [URL] = {
            if let custom = endpoint { return [custom] }
            if let profileOverride = requestProfile?.endpointOverride, let url = URL(string: profileOverride) {
                return [url]
            }
            // The subscription backend is the only authority on what this
            // account can reach. LingXi's registry deliberately does not mirror
            // an OAuth product's model list, so there is no cloud endpoint to
            // fall back to here.
            return [defaultCodexModelsEndpoint]
        }()

        var lastError: Error?
        for targetURL in candidateEndpoints {
            do {
                var request = URLRequest(url: targetURL)
                request.timeoutInterval = 10
                request.httpMethod = "GET"
                request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                let defaultUA = ClientFingerprint.userAgent(for: "openai-codex")
                let ua = requestProfile?.userAgentProfile ?? defaultUA
                request.setValue(ua, forHTTPHeaderField: "User-Agent")

                // Official Codex originator header (or from requestProfile requiredHeaders)
                if let originator = requestProfile?.requiredHeaders?["originator"] {
                    request.setValue(originator, forHTTPHeaderField: "originator")
                } else {
                    let defaultOriginator = ClientFingerprint.headers(for: "openai-codex")["originator"] ?? "codex-cli"
                    request.setValue(defaultOriginator, forHTTPHeaderField: "originator")
                }

                // Account metadata if present in token JWT claims
                if let accountID = extractChatGPTAccountID(from: tokens.accessToken) {
                    request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
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
                    let err = CoreError(code: .provider, message: "ChatGPT remote model catalog request to \(targetURL) failed with HTTP \(status)")
                    if httpClient != nil || endpoint != nil {
                        throw err
                    }
                    lastError = err
                    continue
                }

                let parsed = try parseRemoteModels(from: data)
                if !parsed.isEmpty {
                    return parsed
                }
            } catch {
                if httpClient != nil || endpoint != nil {
                    throw error
                }
                lastError = error
                continue
            }
        }

        if let lastError {
            throw lastError
        }
        // Every candidate endpoint failed. A hardcoded fallback roster would
        // re-anchor the catalog to whatever models shipped with this build;
        // reporting nothing instead lets the caller keep its last-known-good
        // cache, which is what the account actually saw last.
        return []
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

    private static func parseEffort(_ raw: String) -> ReasoningEffort? {
        ReasoningEffort(rawValue: raw.lowercased())
    }

    private static func parseChatGPTModelDict(_ dict: [String: Any]) -> DiscoveredRemoteModel? {
        guard let slug = (dict["slug"] as? String) ?? (dict["id"] as? String), !slug.isEmpty else {
            return nil
        }
        // 过滤内部水印影子镜像模型 (watermark models)，避免与公开正式模型重复混淆
        if slug.hasSuffix("-wm") || slug.contains("-wm-") {
            return nil
        }

        var displayName = (dict["display_name"] as? String) ?? (dict["displayName"] as? String) ?? (dict["title"] as? String) ?? (dict["name"] as? String) ?? slug
        let lowerSlug = slug.lowercased()
        let lowerDisplay = displayName.lowercased()
        if lowerSlug.contains("instant") && !lowerDisplay.contains("instant") {
            displayName += " Instant"
        } else if (lowerSlug.contains("thinking") || lowerSlug.contains("-t-mini")) && !lowerDisplay.contains("thinking") {
            if lowerSlug.contains("mini") && !lowerDisplay.contains("mini") {
                displayName += " Thinking Mini"
            } else {
                displayName += " Thinking"
            }
        } else if lowerSlug.contains("mini") && !lowerDisplay.contains("mini") {
            displayName += " Mini"
        }

        let priority = (dict["priority"] as? Int) ?? 100
        let visibility = (dict["visibility"] as? String) ?? "public"
        let isDefault = (dict["is_default"] as? Bool) ?? (dict["default"] as? Bool) ?? false
        let minClientVersion = dict["minimal_client_version"] as? String

        var efforts: [ReasoningEffort] = []
        if let rawObjects = dict["supported_reasoning_levels"] as? [[String: Any]] {
            efforts = rawObjects.compactMap { obj in
                (obj["effort"] as? String).flatMap(parseEffort)
            }
        } else if let rawStrings = dict["supported_reasoning_levels"] as? [String] {
            efforts = rawStrings.compactMap(parseEffort)
        } else if let rawEfforts = dict["supported_reasoning_efforts"] as? [String] {
            efforts = rawEfforts.compactMap(parseEffort)
        }

        let capabilities = dict["capabilities"] as? [String: Any]
        let inputModalities = (dict["input_modalities"] as? [String]) ?? []
        let toolCalling = (dict["tool_mode"] as? String != nil)
            || (capabilities?["tools"] as? Bool ?? false)
            || (capabilities?["tool_calling"] as? Bool ?? false)
            || true
        let vision = inputModalities.contains("image")
            || (capabilities?["vision"] as? Bool ?? false)

        let maxTokens = (dict["max_tokens"] as? Int)
        let contextWindow = (dict["context_window"] as? Int) ?? (dict["contextWindow"] as? Int) ?? maxTokens
        let maxOutputTokens = (dict["max_output_tokens"] as? Int) ?? (dict["maxOutputTokens"] as? Int)

        let hasReasoning = !efforts.isEmpty || (capabilities?["reasoning"] as? Bool ?? false)
        let modelCapabilities = DiscoveredModelCapabilities(
            reasoning: hasReasoning ? true : nil,
            reasoningMode: hasReasoning ? "effort" : nil,
            modalities: inputModalities.isEmpty ? nil : inputModalities
        )

        let (canonicalID, variantKind) = CanonicalModelParser.parseSlug(slug)

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
            metadataIncomplete: false,
            capabilities: modelCapabilities,
            upstreamModelID: slug,
            displayNameSource: (dict["display_name"] as? String != nil) ? "display_name" : ((dict["title"] as? String != nil) ? "title" : "slug"),
            canonicalModelID: canonicalID,
            backendVariant: variantKind.rawValue
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
            metadataIncomplete: false,
            upstreamModelID: id,
            displayNameSource: (dict["name"] as? String != nil) ? "name" : "id"
        )
    }
}
