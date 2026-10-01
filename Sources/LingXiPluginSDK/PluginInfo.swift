import Foundation

// Read-only projections of LingXiAgent Core state, as published to a plugin.
//
// Every value here originates in Core and arrives through `host.snapshot`.
// Nothing in this file is measured, estimated or defaulted by the SDK: a field
// Core has not stated is `nil`, and a whole section Core cannot state is absent
// from the snapshot. An absent section is reported as unavailable, never as
// `idle`, `unknown` or `0` — a plugin cannot tell a stopped host from a
// sleeping one if "no data" looks like real data.

/// 简化的轮次信息概要(脱敏,剔除系统提示与私密凭据)。
public struct PluginTurnSummary: Codable, Sendable, Equatable {
    public let turnIndex: Int
    public let userPromptSnippet: String
    public let assistantResponseSnippet: String
    public let tokenUsage: Int

    public init(turnIndex: Int, userPromptSnippet: String, assistantResponseSnippet: String, tokenUsage: Int) {
        self.turnIndex = turnIndex
        self.userPromptSnippet = userPromptSnippet
        self.assistantResponseSnippet = assistantResponseSnippet
        self.tokenUsage = tokenUsage
    }
}

/// 上下文状态与 Token 预算只读感知。
public struct PluginContextStateInfo: Codable, Sendable, Equatable {
    /// 当前活动模型;没有活动会话时为 nil(而不是 "unknown")。
    public let activeModelID: String?
    public let totalTokenUsage: Int?
    /// 上下文窗口占用比例,0...1;Core 未计算时为 nil。
    public let contextWindowPercentage: Double?
    /// 本轮上下文是否已被压缩;未发生过压缩也未运行过时会话时为 nil。
    public let isCompacted: Bool?
    public let messageCount: Int?
    /// Core 主动附上的近期轮次;不提供时为 nil。
    public let recentTurns: [PluginTurnSummary]?

    public init(
        activeModelID: String? = nil,
        totalTokenUsage: Int? = nil,
        contextWindowPercentage: Double? = nil,
        isCompacted: Bool? = nil,
        messageCount: Int? = nil,
        recentTurns: [PluginTurnSummary]? = nil
    ) {
        self.activeModelID = activeModelID
        self.totalTokenUsage = totalTokenUsage
        self.contextWindowPercentage = contextWindowPercentage
        self.isCompacted = isCompacted
        self.messageCount = messageCount
        self.recentTurns = recentTurns
    }
}

/// P-Core / E-Core 运行指标。
///
/// P-Core 是留在模型请求上下文里的那部分(Stable Prefix + Growing Context +
/// E-Core Index Projection);E-Core 是被 page-out 的完整上下文对象库,负责
/// 精确恢复与语义召回。两者职责不同:P-Core 的淘汰由 P 侧保留价值策略决定,
/// E-Core 的热度只服务于召回、缓存与可观测性,不参与也不驱动 P-Core 淘汰。
public struct PluginPECoreInfo: Codable, Sendable, Equatable {
    /// P-Core 当前占用的 token 数;Core 未组装请求时为 nil。
    public let pCoreTokens: Int?
    /// E-Core 中该会话的上下文对象数。
    public let eCoreObjects: Int?
    /// E-Core 中该会话的引用(index projection)数。
    public let eCoreReferences: Int?
    /// 最近一次驱逐触发原因(Core 的 eviction trace),没有则为 nil。
    public let lastEvictionTrigger: String?
    public let reasoningEffort: String?
    public let backgroundTaskCount: Int?

    public init(
        pCoreTokens: Int? = nil,
        eCoreObjects: Int? = nil,
        eCoreReferences: Int? = nil,
        lastEvictionTrigger: String? = nil,
        reasoningEffort: String? = nil,
        backgroundTaskCount: Int? = nil
    ) {
        self.pCoreTokens = pCoreTokens
        self.eCoreObjects = eCoreObjects
        self.eCoreReferences = eCoreReferences
        self.lastEvictionTrigger = lastEvictionTrigger
        self.reasoningEffort = reasoningEffort
        self.backgroundTaskCount = backgroundTaskCount
    }
}

/// 运行时耗时分解与性能指标。
///
/// Core 目前不发布首 token 时延,所以整个 section 往往缺席;缺席就是缺席,
/// SDK 不会用 0 冒充测量值。
public struct PluginPerformanceInfo: Codable, Sendable, Equatable {
    public let timeToFirstTokenMs: Double?
    public let reasoningDurationMs: Double?
    public let toolExecutionDurationMs: Double?
    public let providerLatencyAverageMs: Double?
    public let isRateLimited: Bool?

    public init(
        timeToFirstTokenMs: Double? = nil,
        reasoningDurationMs: Double? = nil,
        toolExecutionDurationMs: Double? = nil,
        providerLatencyAverageMs: Double? = nil,
        isRateLimited: Bool? = nil
    ) {
        self.timeToFirstTokenMs = timeToFirstTokenMs
        self.reasoningDurationMs = reasoningDurationMs
        self.toolExecutionDurationMs = toolExecutionDurationMs
        self.providerLatencyAverageMs = providerLatencyAverageMs
        self.isRateLimited = isRateLimited
    }
}

/// 工作区只读元数据。
public struct PluginWorkspaceInfo: Codable, Sendable, Equatable {
    public let rootPath: String
    public let isGitRepository: Bool
    public let currentGitBranch: String?
    /// 变更文件数;非 Git 工作区为 nil。
    public let dirtyFileCount: Int?
    public let primaryLanguages: [String]?
    public let coreVersion: String

    public init(
        rootPath: String,
        isGitRepository: Bool,
        currentGitBranch: String? = nil,
        dirtyFileCount: Int? = nil,
        primaryLanguages: [String]? = nil,
        coreVersion: String
    ) {
        self.rootPath = rootPath
        self.isGitRepository = isGitRepository
        self.currentGitBranch = currentGitBranch
        self.dirtyFileCount = dirtyFileCount
        self.primaryLanguages = primaryLanguages
        self.coreVersion = coreVersion
    }
}

/// 一次 Core 权威运行快照。插件读到的所有运行时信息都来自它。
public struct PluginRuntimeSnapshot: Codable, Sendable, Equatable {
    /// Core 采集该快照的时刻。
    public let observedAt: Date
    /// 采集该快照时 Core 使用的 IPC 版本,便于插件判断协议兼容。
    public let ipcVersion: Int
    public let contextState: PluginContextStateInfo?
    public let peCore: PluginPECoreInfo?
    public let performance: PluginPerformanceInfo?
    public let workspace: PluginWorkspaceInfo?

    public init(
        observedAt: Date = Date(),
        ipcVersion: Int = PluginIPC.currentVersion,
        contextState: PluginContextStateInfo? = nil,
        peCore: PluginPECoreInfo? = nil,
        performance: PluginPerformanceInfo? = nil,
        workspace: PluginWorkspaceInfo? = nil
    ) {
        self.observedAt = observedAt
        self.ipcVersion = ipcVersion
        self.contextState = contextState
        self.peCore = peCore
        self.performance = performance
        self.workspace = workspace
    }
}

/// 请求的运行时信息不在最近一次权威快照里。
///
/// 这是显式失败:插件因此能区分「宿主没告诉我」和「宿主告诉我它是 0」。
public struct PluginInfoUnavailable: Error, Sendable, Equatable, CustomStringConvertible {
    /// 缺失的信息段落。
    public let field: PluginInfoField
    /// 快照采集时间;完全没收到过快照时为 nil。
    public let lastObservedAt: Date?

    public init(field: PluginInfoField, lastObservedAt: Date? = nil) {
        self.field = field
        self.lastObservedAt = lastObservedAt
    }

    public var description: String {
        let observed = lastObservedAt.map { " (last snapshot \($0.ISO8601Format()))" } ?? " (no snapshot received)"
        return "Plugin runtime info unavailable: \(field.rawValue)\(observed)"
    }
}

/// `PluginInfoHub` 可读的四个段落。
public enum PluginInfoField: String, Codable, Sendable, Equatable, CaseIterable {
    case contextState
    case peCore
    case performance
    case workspace
}

/// 只读信息枢纽。提供对 LingXiAgent Core 内部状态的高维观察能力。
///
/// 实现必须只回传 Core 推送的权威快照;没有数据时抛 `PluginInfoUnavailable`。
public protocol PluginInfoHub: Sendable {
    func getContextState() async throws -> PluginContextStateInfo
    func getPECoreInfo() async throws -> PluginPECoreInfo
    func getPerformanceInfo() async throws -> PluginPerformanceInfo
    func getWorkspaceInfo() async throws -> PluginWorkspaceInfo
}
