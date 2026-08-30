/// 控制面命令的响应。
public enum CoreResponse: Sendable, Equatable {
    case pong
    case info(CoreInfo)
    case state(CoreState)
    case streamOpened(StreamID)
    case providerStatus(ProviderStatus)
    case sessionCreated(SessionInfo)
    case sessionList([SessionInfo])
    case sessionDetail(SessionSnapshot)
    case permissionReplyAccepted(PermissionID)
    case questionReplyAccepted(QuestionID)
    case context(ContextDebugSnapshot?)
    case performance(TurnPerformanceReport?)
    case permissionConfiguration(PermissionConfiguration)
    case projectCache(ProjectCacheDebugSnapshot)
    case compactSession(CompactSessionResponse)
    case childSessionList([SessionInfo])
    case agentRunList([AgentRunInfo])
    case agentRun(AgentRunInfo)
    case agentTree(AgentTreeNode)
    case subagentResult(SubagentResult)
    case agentRunCancelled(AgentRunID)
    case error(CoreError)
}

public struct CompactSessionResponse: Sendable, Equatable, Codable {
    public let triggerSource: String
    public let beforeEstimatedTokens: Int
    public let afterEstimatedTokens: Int
    public let reductionTokens: Int
    public let reductionPercent: Double
    public let targetLowWater: Int
    public let mandatoryFloor: Int
    public let unitsKept: Int
    public let unitsPagedOut: Int
    public let historicalToolBatchesPagedOut: Int
    public let projectBackedOffloads: Int
    public let derivedPagesCreated: Int
    public let redundantDrops: Int
    public let emergencyTrims: Int
    public let compactionGeneration: Int
    public let noEligibleReduction: Bool

    public init(triggerSource: String, beforeEstimatedTokens: Int, afterEstimatedTokens: Int, targetLowWater: Int, mandatoryFloor: Int, unitsKept: Int, unitsPagedOut: Int, historicalToolBatchesPagedOut: Int, projectBackedOffloads: Int, derivedPagesCreated: Int, redundantDrops: Int, emergencyTrims: Int, compactionGeneration: Int, noEligibleReduction: Bool) {
        self.triggerSource = triggerSource
        self.beforeEstimatedTokens = beforeEstimatedTokens
        self.afterEstimatedTokens = afterEstimatedTokens
        reductionTokens = max(0, beforeEstimatedTokens - afterEstimatedTokens)
        reductionPercent = beforeEstimatedTokens == 0 ? 0 : Double(reductionTokens) / Double(beforeEstimatedTokens) * 100
        self.targetLowWater = targetLowWater
        self.mandatoryFloor = mandatoryFloor
        self.unitsKept = unitsKept
        self.unitsPagedOut = unitsPagedOut
        self.historicalToolBatchesPagedOut = historicalToolBatchesPagedOut
        self.projectBackedOffloads = projectBackedOffloads
        self.derivedPagesCreated = derivedPagesCreated
        self.redundantDrops = redundantDrops
        self.emergencyTrims = emergencyTrims
        self.compactionGeneration = compactionGeneration
        self.noEligibleReduction = noEligibleReduction
    }
}

/// 协议层错误。
public struct CoreError: Sendable, Equatable, Error {
    public enum Code: String, Sendable {
        case unsupportedCommand
        case notReady
        case streamNotFound
        case sessionNotFound
        /// 同一 Session 已有进行中的 turn（Session Lane 串行保护）。
        case turnAlreadyRunning
        case transport
        /// Provider HTTP / API 错误（Provider Error）。
        case provider
        /// 推理已开始但流中途失败（Model Stream Error）。
        case modelStream
        case toolNotFound
        case toolArgumentInvalid
        case toolValidationError
        case toolExecutionFailed
        case permissionDenied
        case permissionCancelled
        case workspaceViolation
        case resourceNotFound
        case resourceOutsideWorkspace
        case symlinkEscape
        case binaryFileUnsupported
        case contentChanged
        case ambiguousEdit
        case invalidPatch
        case patchConflict
        case commandFailed
        case commandTimedOut
        case sandboxUnavailable
        case processNotFound
        case processNotRunning
        case editTargetNotFound
        case gitError
        case questionUnavailable
        case toolCancelled
        case agentStepLimitReached
        case contextBudgetExceeded
        case contextProtocolViolation
        case mcpToolLeaseMissing
        case mcpToolSchemaChanged
        case mcpToolSchemaTooLarge
        case mcpToolSchemaBudgetExceeded
        case mcpServerUnavailable
        case mcpDiscoveryLimitExceeded
        case mcpProtocolUnsupported
        case mcpTaskExecutionUnsupported
        case mcpInputRequiredUnavailable
        case subagentModelNotAllowed
        case subagentDepthExceeded
        case agentRunNotFound
    }

    public let code: Code
    public let message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}
