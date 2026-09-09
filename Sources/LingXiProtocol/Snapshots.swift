import Foundation

/// Protocol 产品层 Message 角色：严格限制为 User 与 Assistant。
public enum ProtocolMessageRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
}

/// 用户可见的持久化消息快照。
public struct MessageSnapshot: Codable, Sendable, Equatable {
    public let messageID: MessageID
    public let role: ProtocolMessageRole
    public let text: String
    public let attachments: [ContentRef]
    public let createdAt: Date

    public init(
        messageID: MessageID = MessageID(),
        role: ProtocolMessageRole,
        text: String,
        attachments: [ContentRef] = [],
        createdAt: Date = Date()
    ) {
        self.messageID = messageID
        self.role = role
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
    }
}

/// Turn 提交时冻结的执行意图。
public struct TurnExecutionIntent: Codable, Sendable, Equatable {
    public let modelSelection: String?
    public let mode: AgentMode
    public let permissionConfiguration: PermissionConfiguration
    public let attachments: [ContentRef]
    public let contextReferences: [String]

    public init(
        modelSelection: String? = nil,
        mode: AgentMode = .build,
        permissionConfiguration: PermissionConfiguration = .askWorkspace,
        attachments: [ContentRef] = [],
        contextReferences: [String] = []
    ) {
        self.modelSelection = modelSelection
        self.mode = mode
        self.permissionConfiguration = permissionConfiguration
        self.attachments = attachments
        self.contextReferences = contextReferences
    }
}

/// Turn 生命周期状态。
public enum TurnStatus: String, Codable, Sendable, Equatable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = TurnStatus(rawValue: raw) ?? .unknown
    }
}

/// Turn 快照。
public struct TurnSnapshot: Codable, Sendable, Equatable {
    public let turnID: TurnID
    public let sessionID: SessionID
    public let userMessage: MessageSnapshot
    public let executionIntent: TurnExecutionIntent
    public let status: TurnStatus
    public let rootRunID: RunID?
    public let createdAt: Date
    public let completedAt: Date?

    public init(
        turnID: TurnID = TurnID(),
        sessionID: SessionID,
        userMessage: MessageSnapshot,
        executionIntent: TurnExecutionIntent,
        status: TurnStatus = .queued,
        rootRunID: RunID? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.turnID = turnID
        self.sessionID = sessionID
        self.userMessage = userMessage
        self.executionIntent = executionIntent
        self.status = status
        self.rootRunID = rootRunID
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

/// Run 生命周期状态。
public enum RunStatus: String, Codable, Sendable, Equatable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = RunStatus(rawValue: raw) ?? .unknown
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }
}

/// Run 快照。
public struct RunSnapshot: Codable, Sendable, Equatable {
    public let runID: RunID
    public let sessionID: SessionID
    public let turnID: TurnID
    public let rootRunID: RunID?
    public let parentRunID: RunID?
    public let status: RunStatus
    public let model: String
    public let createdAt: Date
    public let completedAt: Date?
    public let terminalReason: TerminalReason?

    public init(
        runID: RunID = RunID(),
        sessionID: SessionID,
        turnID: TurnID,
        rootRunID: RunID? = nil,
        parentRunID: RunID? = nil,
        status: RunStatus = .running,
        model: String,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        terminalReason: TerminalReason? = nil
    ) {
        self.runID = runID
        self.sessionID = sessionID
        self.turnID = turnID
        self.rootRunID = rootRunID
        self.parentRunID = parentRunID
        self.status = status
        self.model = model
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.terminalReason = terminalReason
    }
}

/// Run 摘要（例如 Child Run 汇总）。
public struct RunSummary: Codable, Sendable, Equatable {
    public let runID: RunID
    public let sessionID: SessionID
    public let parentRunID: RunID?
    public let title: String?
    public let status: RunStatus
    public let createdAt: Date

    public init(
        runID: RunID,
        sessionID: SessionID,
        parentRunID: RunID? = nil,
        title: String? = nil,
        status: RunStatus,
        createdAt: Date = Date()
    ) {
        self.runID = runID
        self.sessionID = sessionID
        self.parentRunID = parentRunID
        self.title = title
        self.status = status
        self.createdAt = createdAt
    }
}

/// ModelStep 快照。
public struct ModelStepSnapshot: Codable, Sendable, Equatable {
    public let stepID: ModelStepID
    public let runID: RunID
    public let stepNumber: Int
    public let status: String
    public let visibleReasoningStreamID: StreamID?
    public let assistantStreamID: StreamID?
    public let startedAt: Date
    public let completedAt: Date?

    public init(
        stepID: ModelStepID = ModelStepID(),
        runID: RunID,
        stepNumber: Int,
        status: String = "running",
        visibleReasoningStreamID: StreamID? = nil,
        assistantStreamID: StreamID? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.stepID = stepID
        self.runID = runID
        self.stepNumber = stepNumber
        self.status = status
        self.visibleReasoningStreamID = visibleReasoningStreamID
        self.assistantStreamID = assistantStreamID
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// ToolInvocation 状态。
public enum ToolInvocationState: String, Codable, Sendable, Equatable {
    case requested
    case waitingForPermission
    case scheduled
    case running
    case completed
    case failed
    case cancelled
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = ToolInvocationState(rawValue: raw) ?? .unknown
    }
}

/// Tool 执行结果快照。
public struct ToolResultSnapshot: Codable, Sendable, Equatable {
    public let callID: ToolCallID
    public let success: Bool
    public let summary: String
    public let preview: String?
    public let contentRef: ContentRef?
    public let error: RuntimeError?
    public let timing: ToolTiming

    public init(
        callID: ToolCallID,
        success: Bool,
        summary: String,
        preview: String? = nil,
        contentRef: ContentRef? = nil,
        error: RuntimeError? = nil,
        timing: ToolTiming = ToolTiming()
    ) {
        self.callID = callID
        self.success = success
        self.summary = summary
        self.preview = preview
        self.contentRef = contentRef
        self.error = error
        self.timing = timing
    }

    private enum CodingKeys: String, CodingKey {
        case callID, success, summary, preview, contentRef, error, timing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callID = try container.decode(ToolCallID.self, forKey: .callID)
        success = try container.decode(Bool.self, forKey: .success)
        summary = try container.decode(String.self, forKey: .summary)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        contentRef = try container.decodeIfPresent(ContentRef.self, forKey: .contentRef)
        error = try container.decodeIfPresent(RuntimeError.self, forKey: .error)
        timing = try container.decodeIfPresent(ToolTiming.self, forKey: .timing) ?? ToolTiming()
    }
}

/// ToolInvocation 快照：单一 ToolCallID 的全生命周期聚合。
public struct ToolInvocationSnapshot: Codable, Sendable, Equatable {
    public let callID: ToolCallID
    public let toolID: ToolID
    public let displayName: String
    public let argumentsSummary: String
    public let state: ToolInvocationState
    public let resultPreview: String?
    public let resultRef: ContentRef?
    public let durationMs: Double?
    public let error: RuntimeError?

    public init(
        callID: ToolCallID,
        toolID: ToolID,
        displayName: String,
        argumentsSummary: String,
        state: ToolInvocationState,
        resultPreview: String? = nil,
        resultRef: ContentRef? = nil,
        durationMs: Double? = nil,
        error: RuntimeError? = nil
    ) {
        self.callID = callID
        self.toolID = toolID
        self.displayName = displayName
        self.argumentsSummary = argumentsSummary
        self.state = state
        self.resultPreview = resultPreview
        self.resultRef = resultRef
        self.durationMs = durationMs
        self.error = error
    }
}


/// Interaction 类型。
public enum InteractionKind: String, Codable, Sendable, Equatable {
    case permission
    case question
    case decision
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = InteractionKind(rawValue: raw) ?? .unknown
    }
}

/// Interaction 快照：统合 Permission / Question / Decision。
public struct InteractionSnapshot: Codable, Sendable, Equatable {
    public let interactionID: InteractionID
    public let kind: InteractionKind
    public let causal: CausalContext
    public let createdAt: Date
    public let permissionRequest: PermissionRequest?
    public let questionRequest: QuestionRequest?
    public let decisionRequest: DecisionRequest?

    public init(
        interactionID: InteractionID = InteractionID(),
        kind: InteractionKind,
        causal: CausalContext,
        createdAt: Date = Date(),
        permissionRequest: PermissionRequest? = nil,
        questionRequest: QuestionRequest? = nil,
        decisionRequest: DecisionRequest? = nil
    ) {
        self.interactionID = interactionID
        self.kind = kind
        self.causal = causal
        self.createdAt = createdAt
        self.permissionRequest = permissionRequest
        self.questionRequest = questionRequest
        self.decisionRequest = decisionRequest
    }
}

/// Interaction 解决结论。
public enum InteractionResolution: Codable, Sendable, Equatable {
    case permission(PermissionDecision)
    case question(QuestionReply)
    case decision(String)
    case unknown(String)

    private enum CodingKeys: String, CodingKey {
        case kind, permission, question, decision, rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "permission":
            self = .permission(try container.decode(PermissionDecision.self, forKey: .permission))
        case "question":
            self = .question(try container.decode(QuestionReply.self, forKey: .question))
        case "decision":
            self = .decision(try container.decode(String.self, forKey: .decision))
        default:
            let raw = (try? container.decode(String.self, forKey: .rawValue)) ?? kind
            self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .permission(decision):
            try container.encode("permission", forKey: .kind)
            try container.encode(decision, forKey: .permission)
        case let .question(reply):
            try container.encode("question", forKey: .kind)
            try container.encode(reply, forKey: .question)
        case let .decision(choice):
            try container.encode("decision", forKey: .kind)
            try container.encode(choice, forKey: .decision)
        case let .unknown(raw):
            try container.encode("unknown", forKey: .kind)
            try container.encode(raw, forKey: .rawValue)
        }
    }
}

/// Context 状态快照。
public struct ContextStateSnapshot: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let estimatedTokens: Int
    public let l1Tokens: Int
    public let l2Tokens: Int
    public let l3Tokens: Int
    public let compactionGeneration: Int
    public let cacheReadTokens: Int?
    public let promptTokens: Int?
    public let previousPromptTokens: Int?
    public let cacheStatus: String?
    public let cacheEpoch: Int?
    public let epochReason: String?
    public let stablePrefixHash: String?
    public let missDiagnostics: String?
    public let structuralPrefixStability: Double?
    public let clientCausedBustRate: Double?
    public let appendOnlyContextRatio: Double?
    public let volatileTailBytes: Int?
    public let clientHealthStatus: String?
    public let observedGranularity: Int?
    public let clientCausedBusts: Int?
    public let comparableRequests: Int?
    public let appendOnlyViolations: Int?

    public init(
        sessionID: SessionID,
        estimatedTokens: Int = 0,
        l1Tokens: Int = 0,
        l2Tokens: Int = 0,
        l3Tokens: Int = 0,
        compactionGeneration: Int = 0,
        cacheReadTokens: Int? = nil,
        promptTokens: Int? = nil,
        previousPromptTokens: Int? = nil,
        cacheStatus: String? = nil,
        cacheEpoch: Int? = nil,
        epochReason: String? = nil,
        stablePrefixHash: String? = nil,
        missDiagnostics: String? = nil,
        structuralPrefixStability: Double? = nil,
        clientCausedBustRate: Double? = nil,
        appendOnlyContextRatio: Double? = nil,
        volatileTailBytes: Int? = nil,
        clientHealthStatus: String? = nil,
        observedGranularity: Int? = nil,
        clientCausedBusts: Int? = nil,
        comparableRequests: Int? = nil,
        appendOnlyViolations: Int? = nil
    ) {
        self.sessionID = sessionID
        self.estimatedTokens = estimatedTokens
        self.l1Tokens = l1Tokens
        self.l2Tokens = l2Tokens
        self.l3Tokens = l3Tokens
        self.compactionGeneration = compactionGeneration
        self.cacheReadTokens = cacheReadTokens
        self.promptTokens = promptTokens
        self.previousPromptTokens = previousPromptTokens
        self.cacheStatus = cacheStatus
        self.cacheEpoch = cacheEpoch
        self.epochReason = epochReason
        self.stablePrefixHash = stablePrefixHash
        self.missDiagnostics = missDiagnostics
        self.structuralPrefixStability = structuralPrefixStability
        self.clientCausedBustRate = clientCausedBustRate
        self.appendOnlyContextRatio = appendOnlyContextRatio
        self.volatileTailBytes = volatileTailBytes
        self.clientHealthStatus = clientHealthStatus
        self.observedGranularity = observedGranularity
        self.clientCausedBusts = clientCausedBusts
        self.comparableRequests = comparableRequests
        self.appendOnlyViolations = appendOnlyViolations
    }

    /// Prefix Reuse Efficiency = 实际复用旧前缀 token (cacheRead) / 上一轮可复用前缀 token (previousPromptTokens)
    public var prefixReuseEfficiency: Double? {
        guard let cached = cacheReadTokens, let prev = previousPromptTokens, prev > 0 else { return nil }
        return min(1.0, Double(cached) / Double(prev))
    }

    /// Cached Input Share = 本次输入 token 中有多少来自缓存 (cacheRead / promptTokens)
    public var cachedInputShare: Double? {
        guard let cached = cacheReadTokens, let total = promptTokens, total > 0 else { return nil }
        return min(1.0, Double(cached) / Double(total))
    }

    public var isClientCacheStable: Bool {
        clientHealthStatus == nil || clientHealthStatus == "stable" || clientHealthStatus == "newEpoch"
    }
}

/// 前缀各稳定区域指纹信息
public struct PrefixFingerprint: Codable, Sendable, Equatable {
    public let systemHash: String
    public let developerHash: String
    public let coreToolsHash: String
    public let skillPrefixHash: String
    public let leasedToolsHash: String
    public let historyStableHash: String
    public let requestProfileHash: String
    public let stablePrefixHash: String

    public init(
        systemHash: String,
        developerHash: String = "",
        coreToolsHash: String,
        skillPrefixHash: String = "",
        leasedToolsHash: String = "",
        historyStableHash: String = "",
        requestProfileHash: String,
        stablePrefixHash: String
    ) {
        self.systemHash = systemHash
        self.developerHash = developerHash
        self.coreToolsHash = coreToolsHash
        self.skillPrefixHash = skillPrefixHash
        self.leasedToolsHash = leasedToolsHash
        self.historyStableHash = historyStableHash
        self.requestProfileHash = requestProfileHash
        self.stablePrefixHash = stablePrefixHash
    }
}

/// SessionSnapshot：Head Snapshot + Recent Activity Window，足以恢复当前 Application 状态。
public struct SessionSnapshot: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let info: SessionSummary
    public let recentTurns: [TurnSnapshot]
    public let activeRootRun: RunSnapshot?
    public let activeChildRuns: [RunSummary]
    public let pendingInteractions: [InteractionSnapshot]
    public let activeModelSteps: [ModelStepSnapshot]
    public let recentToolInvocations: [ToolInvocationSnapshot]
    public let contextState: ContextStateSnapshot
    public let permissionConfiguration: PermissionConfiguration
    public let agentMode: AgentMode
    public let recentEvents: [SessionEventEnvelope]
    public let historyBeforeCursor: EventCursor?
    public let eventCursor: EventCursor
    public let revision: UInt64

    public init(
        sessionID: SessionID,
        info: SessionSummary,
        recentTurns: [TurnSnapshot] = [],
        activeRootRun: RunSnapshot? = nil,
        activeChildRuns: [RunSummary] = [],
        pendingInteractions: [InteractionSnapshot] = [],
        activeModelSteps: [ModelStepSnapshot] = [],
        recentToolInvocations: [ToolInvocationSnapshot] = [],
        contextState: ContextStateSnapshot,
        permissionConfiguration: PermissionConfiguration = .askWorkspace,
        agentMode: AgentMode = .build,
        recentEvents: [SessionEventEnvelope] = [],
        historyBeforeCursor: EventCursor? = nil,
        eventCursor: EventCursor,
        revision: UInt64 = 0
    ) {
        self.sessionID = sessionID
        self.info = info
        self.recentTurns = recentTurns
        self.activeRootRun = activeRootRun
        self.activeChildRuns = activeChildRuns
        self.pendingInteractions = pendingInteractions
        self.activeModelSteps = activeModelSteps
        self.recentToolInvocations = recentToolInvocations
        self.contextState = contextState
        self.permissionConfiguration = permissionConfiguration
        self.agentMode = agentMode
        self.recentEvents = recentEvents
        self.historyBeforeCursor = historyBeforeCursor
        self.eventCursor = eventCursor
        self.revision = revision
    }
}
