import Foundation
import LingXiProtocol

/// Provider 运行时组装结果：Provider 实例 + 模型名。
public struct ModelRuntimeAssembly: Sendable {
    public let provider: any ModelProvider
    public let modelID: ModelID
    public let contextProfile: ModelContextProfile

    public init(provider: any ModelProvider, modelID: ModelID, contextProfile: ModelContextProfile = ModelContextProfile()) {
        self.provider = provider
        self.modelID = modelID
        self.contextProfile = contextProfile
    }
}

/// Provider 配置装载：只从环境读取，永不写死、永不提交、不输出 Key。
public enum ProviderSetup {
    public static let baseURLKey = "LINGXI_PROVIDER_BASE_URL"
    public static let apiKeyKey = "LINGXI_PROVIDER_API_KEY"
    public static let modelKey = "LINGXI_PROVIDER_MODEL"

    /// 环境未配置时返回占位 Provider + 缺失项清单；
    /// API Key 允许为空，因为部分 Provider 不要求认证。
    public static func resolve(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (assembly: ModelRuntimeAssembly, missing: [String]) {
        let baseString = (environment[baseURLKey] ?? "").trimmingCharacters(in: .whitespaces)
        let model = environment[modelKey] ?? ""
        let apiKey = environment[apiKeyKey] ?? ""

        var missing: [String] = []
        if baseString.isEmpty { missing.append(baseURLKey) }
        if model.isEmpty { missing.append(modelKey) }
        if !baseString.isEmpty, baseURLValue(baseString) == nil {
            missing.append("\(baseURLKey)（URL 无法解析）")
        }

        guard missing.isEmpty, let baseURL = baseURLValue(baseString) else {
            return (assembly: unavailable, missing: missing)
        }

        let config = ProviderConfig(baseURL: baseURL, apiKey: apiKey.isEmpty ? nil : apiKey, model: model)
        return (
            assembly: ModelRuntimeAssembly(
                provider: OpenAICompatibleProvider(config: config),
                modelID: ModelID(model)
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
    /// 允许为空：部分 Provider 不要求认证。
    public let apiKey: String?
    public let model: String

    public init(baseURL: URL, apiKey: String?, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
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
}
