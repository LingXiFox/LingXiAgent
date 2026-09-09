import Foundation

/// Client 端自身结构化缓存健康度指标（跨 Provider 第一权威真相）。
/// 无论上游 Provider 是否支持/返回 Cache Telemetry，LingXi 均可独立计算并断言。
public struct ClientStructuralCacheHealth: Codable, Sendable, Equatable {
    /// 稳定前缀 Hash（基于 ImmutableBase 确定性序列化计算）
    public let stablePrefixHash: String
    /// 稳定前缀大致字节数
    public let stablePrefixBytes: Int
    /// 稳定前缀拆分段数
    public let stablePrefixSegments: Int
    /// 历史是否为严格 append-only
    public let appendOnlyHistory: Bool
    /// 是否检测到客户端引起的缓存破坏（例如前缀被篡改、工具重排）
    public let prefixMutationDetected: Bool
    /// 当前缓存代 (Epoch)
    public let cacheEpoch: Int
    /// 客户端引起的 Cache Bust 率（0.0 ~ 1.0，目标为 0.0）
    public let clientCausedBustRate: Double
    /// 历史追加比例（1.0 表示完全 append-only）
    public let appendOnlyRatio: Double
    /// Volatile Tail 字节数
    public let volatileTailBytes: Int
    /// 客户端结构状态 ("stable", "bustDetected", "newEpoch")
    public let status: String
    /// 客户端引发的 Cache Bust 实际累计次数
    public let clientCausedBusts: Int
    /// 同 Epoch 内可比对的请求总次数
    public let comparableRequests: Int
    /// 违反 Append-Only 规则的累计次数
    public let appendOnlyViolations: Int

    public var bustRatioString: String {
        "\(clientCausedBusts) / \(comparableRequests)"
    }

    public init(
        stablePrefixHash: String,
        stablePrefixBytes: Int = 0,
        stablePrefixSegments: Int = 1,
        appendOnlyHistory: Bool = true,
        prefixMutationDetected: Bool = false,
        cacheEpoch: Int = 1,
        clientCausedBustRate: Double = 0.0,
        appendOnlyRatio: Double = 1.0,
        volatileTailBytes: Int = 0,
        status: String = "stable",
        clientCausedBusts: Int = 0,
        comparableRequests: Int = 0,
        appendOnlyViolations: Int = 0
    ) {
        self.stablePrefixHash = stablePrefixHash
        self.stablePrefixBytes = stablePrefixBytes
        self.stablePrefixSegments = stablePrefixSegments
        self.appendOnlyHistory = appendOnlyHistory
        self.prefixMutationDetected = prefixMutationDetected
        self.cacheEpoch = cacheEpoch
        self.clientCausedBustRate = clientCausedBustRate
        self.appendOnlyRatio = appendOnlyRatio
        self.volatileTailBytes = volatileTailBytes
        self.status = status
        self.clientCausedBusts = clientCausedBusts
        self.comparableRequests = comparableRequests
        self.appendOnlyViolations = appendOnlyViolations
    }
}

/// Provider 缓存能力抽象描述。仅用于 Adapter 协议编码优化与外部指标呈现，
/// 严禁将具体参数（如 observedGranularity）写入 Agent Runtime 的上下文构造策略。
public struct ProviderCacheCapabilities: Codable, Sendable, Equatable {
    public enum Reporting: String, Codable, Sendable, Equatable {
        case none
        case readTokens
        case readWriteTokens
    }

    public enum Behavior: String, Codable, Sendable, Equatable {
        case unknown
        case implicitPrefix
        case explicitSegments
        case serverState
    }

    public let reporting: Reporting
    public let behavior: Behavior
    public let explicitCacheControlSupported: Bool
    /// 观测到的块步长（纯外部遥测/证据，严禁作为内部构造依据）
    public let observedGranularity: Int?

    public init(
        reporting: Reporting = .none,
        behavior: Behavior = .unknown,
        explicitCacheControlSupported: Bool = false,
        observedGranularity: Int? = nil
    ) {
        self.reporting = reporting
        self.behavior = behavior
        self.explicitCacheControlSupported = explicitCacheControlSupported
        self.observedGranularity = observedGranularity
    }
}
