import Foundation
import LingXiProtocol

/// Provider 运行时组装结果：Provider 实例 + 模型名。
public struct ModelRuntimeAssembly: Sendable {
    public let provider: any ModelProvider
    public let modelID: ModelID
    public let contextProfile: ModelContextProfile
    public let endpoint: ResolvedModelEndpoint

    public init(provider: any ModelProvider, modelID: ModelID, contextProfile: ModelContextProfile = ModelContextProfile(), endpoint: ResolvedModelEndpoint? = nil) {
        self.provider = provider
        self.modelID = modelID
        self.contextProfile = contextProfile
        self.endpoint = endpoint ?? ResolvedModelEndpoint(providerID: "default", modelID: modelID, baseURL: nil, wireProtocol: .chatCompletions, contextProfile: contextProfile)
    }
}

/// Provider 调试覆盖装载。正式用户配置由 App/Bootstrap 解析后进入 typed runtime。
public enum ProviderSetup {
    public static let baseURLKey = "LINGXI_PROVIDER_BASE_URL"
    public static let apiKeyKey = "LINGXI_PROVIDER_API_KEY"
    public static let modelKey = "LINGXI_PROVIDER_MODEL"
    public static let wireProtocolKey = "LINGXI_PROVIDER_WIRE_PROTOCOL"

    /// 环境未配置时返回占位 Provider + 缺失项清单；
    /// API Key 允许为空，因为部分 Provider 不要求认证。
    public static func resolve(_ environment: [String: String]) -> (assembly: ModelRuntimeAssembly, missing: [String]) {
        let baseString = (environment[baseURLKey] ?? "").trimmingCharacters(in: .whitespaces)
        let model = environment[modelKey] ?? ""
        let apiKey = environment[apiKeyKey] ?? ""
        let wireProtocol = ModelWireProtocol(rawValue: environment[wireProtocolKey] ?? "chatCompletions")

        var missing: [String] = []
        if baseString.isEmpty { missing.append(baseURLKey) }
        if model.isEmpty { missing.append(modelKey) }
        if !baseString.isEmpty, baseURLValue(baseString) == nil {
            missing.append("\(baseURLKey)（URL 无法解析）")
        }
        if wireProtocol == nil { missing.append("\(wireProtocolKey)（仅支持 chatCompletions、responses 或 anthropicMessages）") }

        guard missing.isEmpty, let baseURL = baseURLValue(baseString), let wireProtocol else {
            return (assembly: unavailable, missing: missing)
        }

        let config = ProviderConfig(
            baseURL: baseURL,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            model: model,
            wireProtocol: wireProtocol,
            diagnosticsEnabled: environment["LINGXI_PROVIDER_DIAGNOSTICS"] == "1",
            performanceDiagnosticsEnabled: environment["LINGXI_PERF_DEBUG"] == "1"
        )
        let provider: any ModelProvider
        switch wireProtocol {
        case .chatCompletions: provider = OpenAICompatibleProvider(config: config)
        case .responses: provider = OpenAIResponsesProvider(config: config)
        case .anthropicMessages: provider = AnthropicMessagesProvider(config: config)
        }
        return (
            assembly: ModelRuntimeAssembly(
                provider: provider,
                modelID: ModelID(model),
                endpoint: ResolvedModelEndpoint(providerID: "default", modelID: ModelID(model), baseURL: baseURL, wireProtocol: wireProtocol)
            ),
            missing: []
        )
    }

    static var unavailable: ModelRuntimeAssembly {
        ModelRuntimeAssembly(provider: UnavailableProvider(), modelID: ModelID(""))
    }

    static func baseURLValue(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme != nil, url.host() != nil else { return nil }
        return url
    }
}

private struct UnavailableProvider: ModelProvider {
    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        throw CoreError(code: .provider, message: "未配置模型 Provider")
    }
}

/// Provider 连接配置（仅存在于 Core 内部，不进入协议层）。
public struct ProviderConfig: Sendable {
    public let baseURL: URL
    public let authentication: ProviderAuthentication
    public let model: String
    public let wireProtocol: ModelWireProtocol
    public let diagnosticsEnabled: Bool
    public let performanceDiagnosticsEnabled: Bool
    public let remoteStateEnabled: Bool
    public let maxOutputTokens: Int?

    public init(
        baseURL: URL,
        apiKey: String?,
        model: String,
        wireProtocol: ModelWireProtocol = .chatCompletions,
        diagnosticsEnabled: Bool = false,
        performanceDiagnosticsEnabled: Bool = false,
        remoteStateEnabled: Bool = false,
        maxOutputTokens: Int? = nil
    ) {
        self.baseURL = baseURL
        authentication = apiKey.map(ProviderAuthentication.bearer) ?? .none
        self.model = model
        self.wireProtocol = wireProtocol
        self.diagnosticsEnabled = diagnosticsEnabled
        self.performanceDiagnosticsEnabled = performanceDiagnosticsEnabled
        self.remoteStateEnabled = remoteStateEnabled
        self.maxOutputTokens = maxOutputTokens
    }

    public init(
        baseURL: URL,
        authentication: ProviderAuthentication,
        model: String,
        wireProtocol: ModelWireProtocol,
        diagnosticsEnabled: Bool = false,
        performanceDiagnosticsEnabled: Bool = false,
        remoteStateEnabled: Bool = false,
        maxOutputTokens: Int? = nil
    ) {
        self.baseURL = baseURL
        self.authentication = authentication
        self.model = model
        self.wireProtocol = wireProtocol
        self.diagnosticsEnabled = diagnosticsEnabled
        self.performanceDiagnosticsEnabled = performanceDiagnosticsEnabled
        self.remoteStateEnabled = remoteStateEnabled
        self.maxOutputTokens = maxOutputTokens
    }

    /// OpenAI-compatible chat completions 端点。
    /// Base URL 已包含最终兼容层级（如 .../chat/completions）时不再追加，避免 /v1/v1。
    public var chatCompletionsURL: URL {
        let trimmedString = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedString.hasSuffix("/chat/completions") {
            return baseURL
        }
        return URL(string: trimmedString + "/chat/completions") ?? baseURL
    }

    public var responsesURL: URL {
        let trimmedString = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedString.hasSuffix("/responses") { return baseURL }
        return URL(string: trimmedString + "/responses") ?? baseURL
    }

    public var anthropicMessagesURL: URL {
        let trimmedString = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedString.hasSuffix("/v1/messages") || trimmedString.hasSuffix("/messages") { return baseURL }
        return URL(string: trimmedString + "/v1/messages") ?? baseURL
    }
}

public enum ProviderAuthentication: Sendable, Equatable {
    case none
    case bearer(String)
    case header(name: String, value: String)
}

/// Wire protocol is selected by the resolved endpoint, not by a Provider brand.
public enum ModelWireProtocol: String, Sendable, Equatable, Codable {
    case chatCompletions
    case responses
    case anthropicMessages
}

public struct ResolvedModelEndpoint: Sendable, Equatable {
    public let providerID: String
    public let modelID: ModelID
    public let baseURL: URL?
    public let wireProtocol: ModelWireProtocol
    public let contextProfile: ModelContextProfile

    public init(providerID: String, modelID: ModelID, baseURL: URL?, wireProtocol: ModelWireProtocol, contextProfile: ModelContextProfile = ModelContextProfile()) {
        self.providerID = providerID
        self.modelID = modelID
        self.baseURL = baseURL
        self.wireProtocol = wireProtocol
        self.contextProfile = contextProfile
    }
}
