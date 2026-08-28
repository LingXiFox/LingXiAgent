/// 模型推理结果的语义摘要（LingXi 领域抽象，跨 Client/Core 边界）。
/// Provider 原生字段（如 finish_reason 字符串）只在 Provider Adapter 内部，
/// 转换为本层类型后才可离开 Adapter。

/// 推理结束原因。
public enum ModelFinishReason: String, Sendable, Equatable, Codable {
    case stop
    case maxTokens
    case contentFilter
    case toolCalls
    case cancelled
    case unknown
}

/// Token 用量。Provider 提供不了的字段允许为 nil。
public struct ModelUsage: Sendable, Equatable, Codable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let reasoningTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

/// Provider 配置状态（面向客户端，永不含 API Key）。
public struct ProviderStatus: Sendable, Equatable, Codable {
    public let configured: Bool
    public let model: String?
    public let baseURL: String?
    /// 未配置时说明缺哪些环境变量。
    public let missingRequirements: [String]

    public init(configured: Bool, model: String?, baseURL: String?, missingRequirements: [String]) {
        self.configured = configured
        self.model = model
        self.baseURL = baseURL
        self.missingRequirements = missingRequirements
    }
}
