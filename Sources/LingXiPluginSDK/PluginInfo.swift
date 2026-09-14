import Foundation

/// 简化的轮次信息概要（脱敏，剔除系统提示与私密凭据）。
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
    public let activeModelID: String
    public let totalTokenUsage: Int
    public let contextWindowPercentage: Double
    public let isCompacted: Bool
    public let messageCount: Int
    public let recentTurns: [PluginTurnSummary]

    public init(
        activeModelID: String,
        totalTokenUsage: Int,
        contextWindowPercentage: Double,
        isCompacted: Bool,
        messageCount: Int,
        recentTurns: [PluginTurnSummary] = []
    ) {
        self.activeModelID = activeModelID
        self.totalTokenUsage = totalTokenUsage
        self.contextWindowPercentage = contextWindowPercentage
        self.isCompacted = isCompacted
        self.messageCount = messageCount
        self.recentTurns = recentTurns
    }
}

/// P-Core 决策核与 E-Core 执行核运行指标。
public struct PluginPECoreInfo: Codable, Sendable, Equatable {
    public let pCoreRole: String
    public let eCoreRole: String
    public let reasoningEffort: String
    public let pCoreToECoreTimeRatio: Double
    public let cacheDebt: Double
    public let backgroundTaskCount: Int

    public init(
        pCoreRole: String,
        eCoreRole: String,
        reasoningEffort: String,
        pCoreToECoreTimeRatio: Double,
        cacheDebt: Double,
        backgroundTaskCount: Int
    ) {
        self.pCoreRole = pCoreRole
        self.eCoreRole = eCoreRole
        self.reasoningEffort = reasoningEffort
        self.pCoreToECoreTimeRatio = pCoreToECoreTimeRatio
        self.cacheDebt = cacheDebt
        self.backgroundTaskCount = backgroundTaskCount
    }
}

/// 运行时耗时分解与性能指标。
public struct PluginPerformanceInfo: Codable, Sendable, Equatable {
    public let timeToFirstTokenMs: Double
    public let reasoningDurationMs: Double
    public let toolExecutionDurationMs: Double
    public let providerLatencyAverageMs: Double
    public let isRateLimited: Bool

    public init(
        timeToFirstTokenMs: Double,
        reasoningDurationMs: Double,
        toolExecutionDurationMs: Double,
        providerLatencyAverageMs: Double,
        isRateLimited: Bool
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
    public let dirtyFileCount: Int
    public let primaryLanguages: [String]
    public let coreVersion: String

    public init(
        rootPath: String,
        isGitRepository: Bool,
        currentGitBranch: String?,
        dirtyFileCount: Int,
        primaryLanguages: [String],
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

/// 只读信息枢纽。提供对 LingXiAgent Core 内部状态的高维观察能力。
public protocol PluginInfoHub: Sendable {
    func getContextState() async throws -> PluginContextStateInfo
    func getPECoreInfo() async throws -> PluginPECoreInfo
    func getPerformanceInfo() async throws -> PluginPerformanceInfo
    func getWorkspaceInfo() async throws -> PluginWorkspaceInfo
}
