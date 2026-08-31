import Foundation
import LingXiProtocol

/// Provider 实例与已解析端点必须原子组装，endpoint 是运行时唯一真相。
public struct ModelRuntimeAssembly: Sendable {
    public let provider: any ModelProvider
    public let endpoint: ResolvedModelEndpoint
    public var modelID: ModelID { endpoint.modelID }
    public var contextProfile: ModelContextProfile { endpoint.contextProfile }

    public init(provider: any ModelProvider, modelID: ModelID, contextProfile: ModelContextProfile = ModelContextProfile(), endpoint: ResolvedModelEndpoint? = nil) {
        self.provider = provider
        self.endpoint = endpoint ?? ResolvedModelEndpoint(providerID: "default", modelID: modelID, baseURL: nil, wireProtocol: .chatCompletions, contextProfile: contextProfile)
    }

    public static let unavailable = ModelRuntimeAssembly(provider: UnavailableProvider(), modelID: ModelID(""))
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
    public let requiredHeaders: [String: String]

    public init(
        baseURL: URL,
        apiKey: String?,
        model: String,
        wireProtocol: ModelWireProtocol = .chatCompletions,
        diagnosticsEnabled: Bool = false,
        performanceDiagnosticsEnabled: Bool = false,
        remoteStateEnabled: Bool = false,
        maxOutputTokens: Int? = nil,
        requiredHeaders: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        authentication = apiKey.map(ProviderAuthentication.bearer) ?? .none
        self.model = model
        self.wireProtocol = wireProtocol
        self.diagnosticsEnabled = diagnosticsEnabled
        self.performanceDiagnosticsEnabled = performanceDiagnosticsEnabled
        self.remoteStateEnabled = remoteStateEnabled
        self.maxOutputTokens = maxOutputTokens
        self.requiredHeaders = requiredHeaders
    }

    public init(
        baseURL: URL,
        authentication: ProviderAuthentication,
        model: String,
        wireProtocol: ModelWireProtocol,
        diagnosticsEnabled: Bool = false,
        performanceDiagnosticsEnabled: Bool = false,
        remoteStateEnabled: Bool = false,
        maxOutputTokens: Int? = nil,
        requiredHeaders: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.authentication = authentication
        self.model = model
        self.wireProtocol = wireProtocol
        self.diagnosticsEnabled = diagnosticsEnabled
        self.performanceDiagnosticsEnabled = performanceDiagnosticsEnabled
        self.remoteStateEnabled = remoteStateEnabled
        self.maxOutputTokens = maxOutputTokens
        self.requiredHeaders = requiredHeaders
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
    public let productID: String
    public let endpointID: String?
    public let accountID: String?
    public let profileID: String?
    public let modelID: ModelID
    public let baseURL: URL?
    public let wireProtocol: ModelWireProtocol
    public let contextProfile: ModelContextProfile
    public let capabilities: ModelCapabilities

    public init(providerID: String, productID: String? = nil, endpointID: String? = nil, accountID: String? = nil, profileID: String? = nil, modelID: ModelID, baseURL: URL?, wireProtocol: ModelWireProtocol, contextProfile: ModelContextProfile = ModelContextProfile(), capabilities: ModelCapabilities = ModelCapabilities()) {
        self.providerID = providerID
        self.productID = productID ?? providerID
        self.endpointID = endpointID
        self.accountID = accountID
        self.profileID = profileID
        self.modelID = modelID
        self.baseURL = baseURL
        self.wireProtocol = wireProtocol
        self.contextProfile = contextProfile
        self.capabilities = capabilities
    }
}

public struct ModelCapabilities: Codable, Sendable, Equatable {
    public let toolCalling: Bool?
    public let parallelToolCalling: Bool?
    public let reasoning: Bool?
    public let vision: Bool?
    public let structuredOutput: Bool?

    public init(toolCalling: Bool? = nil, parallelToolCalling: Bool? = nil, reasoning: Bool? = nil, vision: Bool? = nil, structuredOutput: Bool? = nil) {
        self.toolCalling = toolCalling
        self.parallelToolCalling = parallelToolCalling
        self.reasoning = reasoning
        self.vision = vision
        self.structuredOutput = structuredOutput
    }
}
