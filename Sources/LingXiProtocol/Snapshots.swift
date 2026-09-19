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

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
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
    public let toolName: String?
    public let success: Bool
    public let summary: String
    public let preview: String?
    public let contentRef: ContentRef?
    public let error: RuntimeError?
    public let timing: ToolTiming

    public init(
        callID: ToolCallID,
        toolName: String? = nil,
        success: Bool,
        summary: String,
        preview: String? = nil,
        contentRef: ContentRef? = nil,
        error: RuntimeError? = nil,
        timing: ToolTiming = ToolTiming()
    ) {
        self.callID = callID
        self.toolName = toolName
        self.success = success
        self.summary = summary
        self.preview = preview
        self.contentRef = contentRef
        self.error = error
        self.timing = timing
    }

    private enum CodingKeys: String, CodingKey {
        case callID, toolName, success, summary, preview, contentRef, error, timing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callID = try container.decode(ToolCallID.self, forKey: .callID)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
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

/// P-Core 状态快照
public struct PCoreStateSnapshot: Codable, Sendable, Equatable {
    public let usedTokens: Int
    public let targetTokens: Int
    public let softLimitTokens: Int
    public let hardLimitTokens: Int

    public init(
        usedTokens: Int = 0,
        targetTokens: Int = 0,
        softLimitTokens: Int = 0,
        hardLimitTokens: Int = 0
    ) {
        self.usedTokens = usedTokens
        self.targetTokens = targetTokens
        self.softLimitTokens = softLimitTokens
        self.hardLimitTokens = hardLimitTokens
    }
}

/// E-Core 状态快照
public struct ECoreStateSnapshot: Codable, Sendable, Equatable {
    public let objectCount: Int
    public let totalBytes: Int
    public let hotObjectCount: Int?
    public let coldObjectCount: Int?
    public let revision: UInt64

    public init(
        objectCount: Int = 0,
        totalBytes: Int = 0,
        hotObjectCount: Int? = nil,
        coldObjectCount: Int? = nil,
        revision: UInt64 = 0
    ) {
        self.objectCount = objectCount
        self.totalBytes = totalBytes
        self.hotObjectCount = hotObjectCount
        self.coldObjectCount = coldObjectCount
        self.revision = revision
    }
}

/// Provider Cache 状态快照
public struct ProviderCacheStateSnapshot: Codable, Sendable, Equatable {
    public let promptTokens: Int?
    public let previousPromptTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheEpoch: Int?
    public let epochReason: String?
    public let cacheDebt: Int?
    public let clientHealthStatus: String?
    public let stablePrefixHash: String?
    public let cacheStatus: String?
    public let missDiagnostics: String?

    public init(
        promptTokens: Int? = nil,
        previousPromptTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheEpoch: Int? = nil,
        epochReason: String? = nil,
        cacheDebt: Int? = nil,
        clientHealthStatus: String? = nil,
        stablePrefixHash: String? = nil,
        cacheStatus: String? = nil,
        missDiagnostics: String? = nil
    ) {
        self.promptTokens = promptTokens
        self.previousPromptTokens = previousPromptTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheEpoch = cacheEpoch
        self.epochReason = epochReason
        self.cacheDebt = cacheDebt
        self.clientHealthStatus = clientHealthStatus
        self.stablePrefixHash = stablePrefixHash
        self.cacheStatus = cacheStatus
        self.missDiagnostics = missDiagnostics
    }
}

/// Context 状态增量补丁
public struct ContextStatePatch: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let revision: UInt64
    public let pCore: PCoreStateSnapshot?
    public let eCore: ECoreStateSnapshot?
    public let providerCache: ProviderCacheStateSnapshot?
    public let compactionGeneration: Int?

    public init(
        sessionID: SessionID,
        revision: UInt64,
        pCore: PCoreStateSnapshot? = nil,
        eCore: ECoreStateSnapshot? = nil,
        providerCache: ProviderCacheStateSnapshot? = nil,
        compactionGeneration: Int? = nil
    ) {
        self.sessionID = sessionID
        self.revision = revision
        self.pCore = pCore
        self.eCore = eCore
        self.providerCache = providerCache
        self.compactionGeneration = compactionGeneration
    }
}

/// Context 状态更新指令
public enum ContextStateUpdate: Codable, Sendable, Equatable {
    case full(ContextStateSnapshot)
    case patch(ContextStatePatch)
    case reset(sessionID: SessionID, revision: UInt64)
}

/// Context 状态快照。
public struct ContextStateSnapshot: Codable, Sendable, Equatable {
    // 权威规范运行时存储属性 (Canonical Runtime Storage)
    public let sessionID: SessionID
    public let revision: UInt64
    public let pCore: PCoreStateSnapshot?
    public let eCore: ECoreStateSnapshot?
    public let providerCache: ProviderCacheStateSnapshot?
    public let estimatedTokens: Int
    public let compactionGeneration: Int

    // 遥测诊断指标 (Telemetry & Diagnostics)
    public let structuralPrefixStability: Double?
    public let clientCausedBustRate: Double?
    public let appendOnlyContextRatio: Double?
    public let volatileTailBytes: Int?
    public let observedGranularity: Int?
    public let clientCausedBusts: Int?
    public let comparableRequests: Int?
    public let appendOnlyViolations: Int?

    // MARK: - Legacy Compatibility Computed Properties (Non-stored runtime properties)

    public var l1Tokens: Int {
        pCore?.usedTokens ?? estimatedTokens
    }

    public var l2Tokens: Int {
        0
    }

    public var l3Tokens: Int {
        0
    }

    public var pCoreTokens: Int? {
        pCore?.usedTokens
    }

    public var eCoreObjectCount: Int? {
        eCore?.objectCount
    }

    public var eCoreTotalBytes: Int? {
        eCore?.totalBytes
    }

    public var cacheReadTokens: Int? {
        providerCache?.cacheReadTokens
    }

    public var promptTokens: Int? {
        providerCache?.promptTokens
    }

    public var previousPromptTokens: Int? {
        providerCache?.previousPromptTokens
    }

    public var cacheStatus: String? {
        providerCache?.cacheStatus
    }

    public var cacheEpoch: Int? {
        providerCache?.cacheEpoch
    }

    public var epochReason: String? {
        providerCache?.epochReason
    }

    public var stablePrefixHash: String? {
        providerCache?.stablePrefixHash
    }

    public var missDiagnostics: String? {
        providerCache?.missDiagnostics
    }

    public var clientHealthStatus: String? {
        providerCache?.clientHealthStatus
    }

    public var cacheDebt: Int? {
        providerCache?.cacheDebt
    }

    public var activePCoreTokens: Int {
        pCore?.usedTokens ?? 0
    }

    // MARK: - Initializer

    public init(
        sessionID: SessionID,
        revision: UInt64 = 0,
        pCore: PCoreStateSnapshot? = nil,
        eCore: ECoreStateSnapshot? = nil,
        providerCache: ProviderCacheStateSnapshot? = nil,
        estimatedTokens: Int = 0,
        l1Tokens: Int? = nil,
        l2Tokens: Int? = nil,
        l3Tokens: Int? = nil,
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
        appendOnlyViolations: Int? = nil,
        pCoreTokens: Int? = nil,
        eCoreObjectCount: Int? = nil,
        eCoreTotalBytes: Int? = nil,
        cacheDebt: Int? = nil
    ) {
        self.sessionID = sessionID
        self.revision = revision

        // Adapt pCore
        if let pCore {
            self.pCore = pCore
        } else if let pCoreTokens {
            self.pCore = PCoreStateSnapshot(usedTokens: pCoreTokens)
        } else {
            self.pCore = nil
        }

        // Adapt eCore
        if let eCore {
            self.eCore = eCore
        } else if eCoreObjectCount != nil || eCoreTotalBytes != nil {
            self.eCore = ECoreStateSnapshot(
                objectCount: eCoreObjectCount ?? 0,
                totalBytes: eCoreTotalBytes ?? 0,
                revision: revision
            )
        } else {
            self.eCore = nil
        }

        // Adapt providerCache
        if let providerCache {
            self.providerCache = providerCache
        } else if cacheReadTokens != nil || promptTokens != nil || cacheStatus != nil || clientHealthStatus != nil || cacheDebt != nil {
            self.providerCache = ProviderCacheStateSnapshot(
                promptTokens: promptTokens,
                previousPromptTokens: previousPromptTokens,
                cacheReadTokens: cacheReadTokens,
                cacheEpoch: cacheEpoch,
                epochReason: epochReason,
                cacheDebt: cacheDebt,
                clientHealthStatus: clientHealthStatus,
                stablePrefixHash: stablePrefixHash,
                cacheStatus: cacheStatus,
                missDiagnostics: missDiagnostics
            )
        } else {
            self.providerCache = nil
        }

        self.estimatedTokens = estimatedTokens
        self.compactionGeneration = compactionGeneration
        self.structuralPrefixStability = structuralPrefixStability
        self.clientCausedBustRate = clientCausedBustRate
        self.appendOnlyContextRatio = appendOnlyContextRatio
        self.volatileTailBytes = volatileTailBytes
        self.observedGranularity = observedGranularity
        self.clientCausedBusts = clientCausedBusts
        self.comparableRequests = comparableRequests
        self.appendOnlyViolations = appendOnlyViolations
    }

    // MARK: - Codable & Legacy Decode Adapter

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case revision
        case pCore
        case eCore
        case providerCache
        case estimatedTokens
        case compactionGeneration
        case structuralPrefixStability
        case clientCausedBustRate
        case appendOnlyContextRatio
        case volatileTailBytes
        case observedGranularity
        case clientCausedBusts
        case comparableRequests
        case appendOnlyViolations

        // Legacy decoding keys
        case l1Tokens
        case l2Tokens
        case l3Tokens
        case pCoreTokens
        case eCoreObjectCount
        case eCoreTotalBytes
        case cacheReadTokens
        case promptTokens
        case previousPromptTokens
        case cacheStatus
        case cacheEpoch
        case epochReason
        case stablePrefixHash
        case missDiagnostics
        case clientHealthStatus
        case cacheDebt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let directSessionID = try? container.decode(SessionID.self, forKey: .sessionID) {
            self.sessionID = directSessionID
        } else if let rawString = try? container.decode(String.self, forKey: .sessionID) {
            self.sessionID = SessionID(rawString)
        } else {
            self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        }
        self.revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        self.estimatedTokens = try container.decodeIfPresent(Int.self, forKey: .estimatedTokens) ?? 0
        self.compactionGeneration = try container.decodeIfPresent(Int.self, forKey: .compactionGeneration) ?? 0

        self.structuralPrefixStability = try container.decodeIfPresent(Double.self, forKey: .structuralPrefixStability)
        self.clientCausedBustRate = try container.decodeIfPresent(Double.self, forKey: .clientCausedBustRate)
        self.appendOnlyContextRatio = try container.decodeIfPresent(Double.self, forKey: .appendOnlyContextRatio)
        self.volatileTailBytes = try container.decodeIfPresent(Int.self, forKey: .volatileTailBytes)
        self.observedGranularity = try container.decodeIfPresent(Int.self, forKey: .observedGranularity)
        self.clientCausedBusts = try container.decodeIfPresent(Int.self, forKey: .clientCausedBusts)
        self.comparableRequests = try container.decodeIfPresent(Int.self, forKey: .comparableRequests)
        self.appendOnlyViolations = try container.decodeIfPresent(Int.self, forKey: .appendOnlyViolations)

        // 1. Decode or adapt PCore
        if let decodedPCore = try container.decodeIfPresent(PCoreStateSnapshot.self, forKey: .pCore) {
            self.pCore = decodedPCore
        } else if let legacyPCoreTokens = try container.decodeIfPresent(Int.self, forKey: .pCoreTokens) {
            self.pCore = PCoreStateSnapshot(usedTokens: legacyPCoreTokens)
        } else if let legacyL1 = try container.decodeIfPresent(Int.self, forKey: .l1Tokens), legacyL1 > 0 {
            self.pCore = PCoreStateSnapshot(usedTokens: legacyL1)
        } else {
            self.pCore = nil
        }

        // 2. Decode or adapt ECore
        if let decodedECore = try container.decodeIfPresent(ECoreStateSnapshot.self, forKey: .eCore) {
            self.eCore = decodedECore
        } else {
            let legacyCount = try container.decodeIfPresent(Int.self, forKey: .eCoreObjectCount)
            let legacyBytes = try container.decodeIfPresent(Int.self, forKey: .eCoreTotalBytes)
            if legacyCount != nil || legacyBytes != nil {
                self.eCore = ECoreStateSnapshot(
                    objectCount: legacyCount ?? 0,
                    totalBytes: legacyBytes ?? 0,
                    revision: self.revision
                )
            } else {
                self.eCore = nil
            }
        }

        // 3. Decode or adapt ProviderCache
        if let decodedCache = try container.decodeIfPresent(ProviderCacheStateSnapshot.self, forKey: .providerCache) {
            self.providerCache = decodedCache
        } else {
            let cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
            let prompt = try container.decodeIfPresent(Int.self, forKey: .promptTokens)
            let prevPrompt = try container.decodeIfPresent(Int.self, forKey: .previousPromptTokens)
            let cacheStat = try container.decodeIfPresent(String.self, forKey: .cacheStatus)
            let epoch = try container.decodeIfPresent(Int.self, forKey: .cacheEpoch)
            let reason = try container.decodeIfPresent(String.self, forKey: .epochReason)
            let stableHash = try container.decodeIfPresent(String.self, forKey: .stablePrefixHash)
            let missDiag = try container.decodeIfPresent(String.self, forKey: .missDiagnostics)
            let clientHealth = try container.decodeIfPresent(String.self, forKey: .clientHealthStatus)
            let debt = try container.decodeIfPresent(Int.self, forKey: .cacheDebt)

            if cacheRead != nil || prompt != nil || cacheStat != nil || clientHealth != nil || debt != nil {
                self.providerCache = ProviderCacheStateSnapshot(
                    promptTokens: prompt,
                    previousPromptTokens: prevPrompt,
                    cacheReadTokens: cacheRead,
                    cacheEpoch: epoch,
                    epochReason: reason,
                    cacheDebt: debt,
                    clientHealthStatus: clientHealth,
                    stablePrefixHash: stableHash,
                    cacheStatus: cacheStat,
                    missDiagnostics: missDiag
                )
            } else {
                self.providerCache = nil
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(pCore, forKey: .pCore)
        try container.encodeIfPresent(eCore, forKey: .eCore)
        try container.encodeIfPresent(providerCache, forKey: .providerCache)
        try container.encode(estimatedTokens, forKey: .estimatedTokens)
        try container.encode(compactionGeneration, forKey: .compactionGeneration)

        try container.encodeIfPresent(structuralPrefixStability, forKey: .structuralPrefixStability)
        try container.encodeIfPresent(clientCausedBustRate, forKey: .clientCausedBustRate)
        try container.encodeIfPresent(appendOnlyContextRatio, forKey: .appendOnlyContextRatio)
        try container.encodeIfPresent(volatileTailBytes, forKey: .volatileTailBytes)
        try container.encodeIfPresent(observedGranularity, forKey: .observedGranularity)
        try container.encodeIfPresent(clientCausedBusts, forKey: .clientCausedBusts)
        try container.encodeIfPresent(comparableRequests, forKey: .comparableRequests)
        try container.encodeIfPresent(appendOnlyViolations, forKey: .appendOnlyViolations)
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
    public let todos: [TodoItemData]

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
        revision: UInt64 = 0,
        todos: [TodoItemData] = []
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
        self.todos = todos
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, info, recentTurns, activeRootRun, activeChildRuns
        case pendingInteractions, activeModelSteps, recentToolInvocations
        case contextState, permissionConfiguration, agentMode, recentEvents
        case historyBeforeCursor, eventCursor, revision, todos
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        info = try container.decode(SessionSummary.self, forKey: .info)
        recentTurns = try container.decodeIfPresent([TurnSnapshot].self, forKey: .recentTurns) ?? []
        activeRootRun = try container.decodeIfPresent(RunSnapshot.self, forKey: .activeRootRun)
        activeChildRuns = try container.decodeIfPresent([RunSummary].self, forKey: .activeChildRuns) ?? []
        pendingInteractions = try container.decodeIfPresent([InteractionSnapshot].self, forKey: .pendingInteractions) ?? []
        activeModelSteps = try container.decodeIfPresent([ModelStepSnapshot].self, forKey: .activeModelSteps) ?? []
        recentToolInvocations = try container.decodeIfPresent([ToolInvocationSnapshot].self, forKey: .recentToolInvocations) ?? []
        contextState = try container.decode(ContextStateSnapshot.self, forKey: .contextState)
        permissionConfiguration = try container.decodeIfPresent(PermissionConfiguration.self, forKey: .permissionConfiguration) ?? .askWorkspace
        agentMode = try container.decodeIfPresent(AgentMode.self, forKey: .agentMode) ?? .build
        recentEvents = try container.decodeIfPresent([SessionEventEnvelope].self, forKey: .recentEvents) ?? []
        historyBeforeCursor = try container.decodeIfPresent(EventCursor.self, forKey: .historyBeforeCursor)
        eventCursor = try container.decode(EventCursor.self, forKey: .eventCursor)
        revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        todos = try container.decodeIfPresent([TodoItemData].self, forKey: .todos) ?? []
    }
}

// MARK: - Branch Prediction Telemetry DTO

/// PredictionSnapshot: Read-only telemetry snapshot of Branch Predictor state.
/// Designed for TUI/GUI diagnostics inspection; strictly immutable and isolated from model decision authority.
public struct PredictionSnapshot: Codable, Sendable, Equatable {
    public struct CandidateDTO: Codable, Sendable, Equatable {
        public let action: String
        public let probability: Double
        public let count: Int

        public init(action: String, probability: Double, count: Int) {
            self.action = action
            self.probability = probability
            self.count = count
        }
    }

    public let epoch: UInt64
    public let sessionID: String
    public let runID: String?
    public let top1Action: String?
    public let topConfidence: Double
    public let support: Int
    public let matchedOrder: Int
    public let candidates: [CandidateDTO]
    public let mode: String // e.g. "shadow"
    public let isLowSupport: Bool
    public let isStale: Bool
    public let timestamp: Date

    public init(
        epoch: UInt64,
        sessionID: String,
        runID: String? = nil,
        top1Action: String?,
        topConfidence: Double,
        support: Int,
        matchedOrder: Int,
        candidates: [CandidateDTO],
        mode: String = "shadow",
        isLowSupport: Bool? = nil,
        isStale: Bool = false,
        timestamp: Date = Date()
    ) {
        self.epoch = epoch
        self.sessionID = sessionID
        self.runID = runID
        self.top1Action = top1Action
        self.topConfidence = topConfidence
        self.support = support
        self.matchedOrder = matchedOrder
        self.candidates = candidates
        self.mode = mode
        self.isLowSupport = isLowSupport ?? (support < 3)
        self.isStale = isStale
        self.timestamp = timestamp
    }

    /// Compact telemetry strip formatted for TUI/GUI observability display, adhering to Round 13 audit invariants
    public var compactSummary: String {
        guard !candidates.isEmpty else {
            return "Branch · (no prior) · SHADOW"
        }

        let branchParts = candidates.prefix(3).map { cand in
            let pct = Int((cand.probability * 100).rounded())
            let shortAction = cand.action.replacingOccurrences(of: "tool:", with: "").uppercased()
            return "\(shortAction) \(pct)%"
        }.joined(separator: " · ")

        let statusTag = isStale ? "STALE" : (isLowSupport ? "LOW SUPPORT" : mode.uppercased())
        return "Branch · \(branchParts) (h=\(matchedOrder), n=\(support), \(statusTag))"
    }
}
