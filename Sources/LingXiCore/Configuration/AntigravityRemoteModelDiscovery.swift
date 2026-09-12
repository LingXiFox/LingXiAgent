import Foundation
import LingXiProtocol

/// Concrete implementation of first-party model discovery for Antigravity,
/// observed from official Antigravity CLI (agy 1.2.1).
///
/// Discovers models via:
///   POST https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels
/// Preceded by layered Google Account & Project bootstrap:
///   POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist
public enum AntigravityRemoteModelDiscovery {
    public static let defaultModelsEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!

    public static func discoverModels(
        tokens: OAuthTokens,
        endpoint: URL? = nil,
        requestProfile: OverlayRequestProfile? = nil,
        context: AuthenticatedDiscoveryContext? = nil,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async throws -> [DiscoveredRemoteModel] {
        // 1. Layered Bootstrap: Project / Tier resolution
        let bootstrap = try await GoogleAccountProjectBootstrap.bootstrap(
            tokens: tokens,
            requestProfile: requestProfile,
            context: context,
            httpClient: httpClient
        )

        // 2. Fetch Available Models RPC
        let targetURL = endpoint
            ?? requestProfile?.endpointOverride.flatMap(URL.init(string:))
            ?? defaultModelsEndpoint

        var request = URLRequest(url: targetURL)
        request.timeoutInterval = 10
        request.httpMethod = "POST"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let defaultUA = ClientFingerprint.userAgent(for: "antigravity")
        let ua = requestProfile?.userAgentProfile ?? defaultUA
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        let clientHeader = ClientFingerprint.headers(for: "antigravity")["X-Goog-Api-Client"]
        if let clientHeader {
            request.setValue(clientHeader, forHTTPHeaderField: "X-Goog-Api-Client")
        }

        if let headers = requestProfile?.requiredHeaders {
            for (key, val) in headers {
                request.setValue(val, forHTTPHeaderField: key)
            }
        }

        // Body with project context if resolved by bootstrap
        var bodyDict: [String: Any] = [:]
        if let project = bootstrap.project {
            bodyDict["project"] = project
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [])

        let execute = httpClient ?? { req in
            try await URLSession.shared.data(for: req)
        }

        let (data, response) = try await execute(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AccountModelDiscovery.DiscoveryFailure.http(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountModelDiscovery.DiscoveryFailure.empty(productID: "antigravity")
        }

        return parseModels(json: json, bootstrap: bootstrap)
    }

    public static func parseModels(json: [String: Any], bootstrap: GoogleBootstrapResult) -> [DiscoveredRemoteModel] {
        guard let modelsDict = (json["models"] as? [String: Any]) else {
            return []
        }

        let defaultAgentModelID = (json["default_agent_model_id"] as? String)
            ?? (json["defaultAgentModelId"] as? String)

        var result: [DiscoveredRemoteModel] = []

        for (upstreamKey, rawDetails) in modelsDict {
            guard let details = rawDetails as? [String: Any] else { continue }

            let upstreamModelID = upstreamKey
            let displayName = (details["display_name"] as? String)
                ?? (details["displayName"] as? String)
                ?? upstreamModelID

            let supportsThinking = (details["supports_thinking"] as? Bool)
                ?? (details["supportsThinking"] as? Bool)
                ?? false

            let supportsImages = (details["supports_images"] as? Bool)
                ?? (details["supportsImages"] as? Bool)
                ?? false

            let disabled = (details["disabled"] as? Bool) ?? false
            let isInternal = (details["is_internal"] as? Bool)
                ?? (details["isInternal"] as? Bool)
                ?? false
            let preview = (details["preview"] as? Bool) ?? false

            let maxTokens = (details["max_tokens"] as? Int)
                ?? (details["maxTokens"] as? Int)
            let maxOutputTokens = (details["max_output_tokens"] as? Int)
                ?? (details["maxOutputTokens"] as? Int)

            let thinkingBudget = (details["thinking_budget"] as? Int)
                ?? (details["thinkingBudget"] as? Int)
            let minThinkingBudget = (details["min_thinking_budget"] as? Int)
                ?? (details["minThinkingBudget"] as? Int)

            let thinkingLevel: String? = {
                if let str = details["thinking_level"] as? String ?? details["thinkingLevel"] as? String {
                    return str
                }
                if let num = details["thinking_level"] as? Int ?? details["thinkingLevel"] as? Int {
                    return String(num)
                }
                return nil
            }()

            // listingVerified ≠ selectable:
            // Explicit upstream "disabled: true" marks model disabled.
            // Under Rule 4, disabled=false does NOT imply public visibility,
            // and is_internal=true does not map to public.
            // Canonical visibility remains "unspecified" unless upstream explicitly returns visibility.
            let explicitVisibility = (details["visibility"] as? String)
                ?? (details["selectability"] as? String)

            let visibility: String = {
                if let explicit = explicitVisibility, !explicit.isEmpty {
                    return explicit
                }
                if disabled {
                    return "disabled"
                }
                return "unspecified"
            }()

            // Canonical reasoning effort mapped conservatively based on verified facts
            var efforts: [ReasoningEffort] = []
            if let level = thinkingLevel?.lowercased() {
                switch level {
                case "high", "3": efforts = [.high]
                case "medium", "2": efforts = [.medium]
                case "low", "1": efforts = [.low]
                default: break
                }
            } else if supportsThinking {
                if upstreamModelID.hasSuffix("-high") { efforts = [.high] }
                else if upstreamModelID.hasSuffix("-medium") { efforts = [.medium] }
                else if upstreamModelID.hasSuffix("-low") { efforts = [.low] }
            }

            // Lossless native metadata preservation
            var nativeMeta: [String: String] = [
                "supports_thinking": supportsThinking ? "true" : "false",
                "disabled": disabled ? "true" : "false",
                "is_internal": isInternal ? "true" : "false",
                "preview": preview ? "true" : "false",
                "project_source": bootstrap.projectSource.rawValue
            ]
            if let p = bootstrap.project { nativeMeta["project"] = p }
            if let t = bootstrap.tier { nativeMeta["current_tier"] = t }
            if let thinkingLevel { nativeMeta["thinking_level"] = thinkingLevel }
            if let thinkingBudget { nativeMeta["thinking_budget"] = String(thinkingBudget) }
            if let minThinkingBudget { nativeMeta["min_thinking_budget"] = String(minThinkingBudget) }
            if let tok = details["tokenizer_type"] as? String ?? details["tokenizerType"] as? String {
                nativeMeta["tokenizer_type"] = tok
            }

            let model = DiscoveredRemoteModel(
                id: upstreamModelID,
                displayName: displayName,
                priority: 100,
                visibility: visibility,
                isDefault: (upstreamModelID == defaultAgentModelID),
                supportedReasoningEfforts: efforts,
                contextWindow: maxTokens,
                maxOutputTokens: maxOutputTokens,
                toolCalling: true,
                vision: supportsImages,
                metadataIncomplete: false,
                capabilities: DiscoveredModelCapabilities(
                    reasoning: supportsThinking,
                    modalities: supportsImages ? ["text", "image"] : ["text"]
                ),
                upstreamModelID: upstreamModelID,
                displayNameSource: "upstream",
                nativeMetadata: nativeMeta
            )

            result.append(model)
        }

        // Stable sort by upstream ID
        return result.sorted { $0.id < $1.id }
    }
}

/// Backend adapter for Antigravity authenticated discovery in the registry.
public struct AntigravityAuthenticatedDiscoveryBackend: AuthenticatedDiscoveryBackend {
    public let backendID = "antigravityAuthenticatedCatalog"

    public init() {}

    public func discoverModels(
        tokens: OAuthTokens,
        endpoint: URL?,
        requestProfile: OverlayRequestProfile?,
        context: AuthenticatedDiscoveryContext?,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    ) async throws -> [DiscoveredRemoteModel] {
        try await AntigravityRemoteModelDiscovery.discoverModels(
            tokens: tokens,
            endpoint: endpoint,
            requestProfile: requestProfile,
            context: context,
            httpClient: httpClient
        )
    }
}
