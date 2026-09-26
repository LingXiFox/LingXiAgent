import Foundation

/// ModelStep 输出元数据。
public struct ModelStepOutputMetadata: Codable, Sendable, Equatable {
    public let totalTokens: Int?
    public let finishReason: String?
    public let model: String?
    public let durationMs: Double?
    public let firstTokenMs: Double?
    public let tokenRate: Double?
    public let completedAt: Date?

    public init(
        totalTokens: Int? = nil,
        finishReason: String? = nil,
        model: String? = nil,
        durationMs: Double? = nil,
        firstTokenMs: Double? = nil,
        tokenRate: Double? = nil,
        completedAt: Date? = nil
    ) {
        self.totalTokens = totalTokens
        self.finishReason = finishReason
        self.model = model
        self.durationMs = durationMs
        self.firstTokenMs = firstTokenMs
        self.tokenRate = tokenRate
        self.completedAt = completedAt
    }
}

/// Provider 请求状态。
public enum ProviderRequestState: String, Codable, Sendable, Equatable {
    case scheduled
    case waitingForRateBudget
    case requesting
    case streaming
    case rateLimited
    case retryScheduled
    case completed
    case failed
    case cancelled
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = ProviderRequestState(rawValue: raw) ?? .unknown
    }
}

/// Context Policy 快照（P-Core + E-Core 双核预算体系）。
public struct ContextPolicySnapshot: Codable, Sendable, Equatable {
    public let addressableBudget: Int
    public let pCoreTarget: Int
    public let pCoreSoftLimit: Int
    public let pCoreHardLimit: Int
    public let eCoreStorageBudget: Int
    public let eCoreRecallBudget: Int
    public let eCorePressureThreshold: Double

    public var l1Target: Int { pCoreTarget }
    public var l2Max: Int { eCoreRecallBudget }
    public var l3Capacity: Int { eCoreStorageBudget }

    public init(
        addressableBudget: Int,
        pCoreTarget: Int,
        pCoreSoftLimit: Int = 235_000,
        pCoreHardLimit: Int = 250_000,
        eCoreStorageBudget: Int = 456_576,
        eCoreRecallBudget: Int = 350_000,
        eCorePressureThreshold: Double = 0.85
    ) {
        self.addressableBudget = addressableBudget
        self.pCoreTarget = pCoreTarget
        self.pCoreSoftLimit = pCoreSoftLimit
        self.pCoreHardLimit = pCoreHardLimit
        self.eCoreStorageBudget = eCoreStorageBudget
        self.eCoreRecallBudget = eCoreRecallBudget
        self.eCorePressureThreshold = eCorePressureThreshold
    }

    public init(addressableBudget: Int, l1Target: Int, l2Max: Int, l3Capacity: Int) {
        self.init(
            addressableBudget: addressableBudget,
            pCoreTarget: l1Target,
            pCoreSoftLimit: Int(Double(l1Target) * 1.07),
            pCoreHardLimit: Int(Double(l1Target) * 1.14),
            eCoreStorageBudget: l3Capacity,
            eCoreRecallBudget: l2Max,
            eCorePressureThreshold: 0.85
        )
    }
}

/// Context 压缩事件快照。
public struct ContextCompactedSnapshot: Codable, Sendable, Equatable {
    public let beforeTokens: Int
    public let afterTokens: Int
    public let reductionTokens: Int
    public let triggerSource: String

    public init(beforeTokens: Int, afterTokens: Int, reductionTokens: Int, triggerSource: String) {
        self.beforeTokens = beforeTokens
        self.afterTokens = afterTokens
        self.reductionTokens = reductionTokens
        self.triggerSource = triggerSource
    }
}

/// Goal Mode 的会话级投影：锚定目标本身、何时建立、已推进的模型步数。
/// 缺省即「当前 Session 没有 Goal」，清除 Goal 时 Core 发布 `nil`。
public struct GoalRuntimeSnapshot: Codable, Sendable, Equatable {
    public let text: String
    public let since: Date
    public let steps: Int

    public init(text: String, since: Date, steps: Int) {
        self.text = text
        self.since = since
        self.steps = steps
    }
}

/// SessionEventPayload：Session 内部规范语义事实。
public enum SessionEventPayload: Codable, Sendable, Equatable {
    // MARK: - Turn / Message
    case turnCreated(TurnSnapshot)
    case userMessageCommitted(MessageSnapshot)
    case assistantMessageStarted(messageID: MessageID, assistantStreamID: StreamID)
    case assistantMessageCommitted(messageID: MessageID, content: String, assistantFinalIndex: UInt64)
    case turnCompleted(turnID: TurnID, terminalReason: TerminalReason)
    case turnFailed(turnID: TurnID, error: RuntimeError)

    // MARK: - Run
    case runCreated(RunSnapshot)
    case runQueued(runID: RunID)
    case runStarted(runID: RunID)
    case runPaused(runID: RunID, reason: String?)
    case runResumed(runID: RunID)
    case runCompleted(runID: RunID, terminalReason: TerminalReason)
    case runFailed(runID: RunID, error: RuntimeError)
    case runCancelled(runID: RunID, reason: String?)

    // MARK: - ModelStep
    case modelStepStarted(stepID: ModelStepID, visibleReasoningStreamID: StreamID?, assistantStreamID: StreamID?)
    case modelStepCompleted(stepID: ModelStepID, visibleReasoningFinalIndex: UInt64?, outputMetadata: ModelStepOutputMetadata?)
    case modelStepFailed(stepID: ModelStepID, error: RuntimeError)

    // MARK: - Tool
    case toolRequested(ToolInvocationSnapshot)
    case toolWaitingForPermission(callID: ToolCallID, permissionID: PermissionID)
    case toolScheduled(callID: ToolCallID)
    case toolRunning(callID: ToolCallID, stdoutStreamID: StreamID?, stderrStreamID: StreamID?)
    case toolCompleted(callID: ToolCallID, result: ToolResultSnapshot, stdoutFinalIndex: UInt64?, stderrFinalIndex: UInt64?)
    case toolFailed(callID: ToolCallID, error: RuntimeError, stdoutFinalIndex: UInt64?, stderrFinalIndex: UInt64?)
    case toolCancelled(callID: ToolCallID, stdoutFinalIndex: UInt64?, stderrFinalIndex: UInt64?)
    case toolExecutionStateUnknown(callID: ToolCallID)

    // MARK: - Interaction
    case interactionRequested(InteractionSnapshot)
    case interactionResolved(interactionID: InteractionID, resolution: InteractionResolution)
    case interactionCancelled(interactionID: InteractionID)

    // MARK: - Subagent
    case subagentCreated(runID: RunID, parentRunID: RunID)
    case subagentStateChanged(runID: RunID, status: String)
    case subagentTerminal(runID: RunID, terminalReason: TerminalReason, resultPreview: String?, late: Bool = false)

    // MARK: - Provider
    case providerRequestStateChanged(requestID: ProviderRequestID, state: ProviderRequestState, detail: String? = nil, statusCode: Int? = nil)

    // MARK: - Context
    case contextStateChanged(ContextStateSnapshot)
    case contextPolicyChanged(ContextPolicySnapshot)
    case contextCompacted(ContextCompactedSnapshot)

    // MARK: - Goal Mode
    /// `nil` is a fact, not an absence: it means the goal was cleared.
    case goalChanged(GoalRuntimeSnapshot?)

    // MARK: - Extensible fallback
    case unknown(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case turn, message, messageID, streamID, content, finalIndex, turnID, terminalReason, error
        case run, runID, reason
        case stepID, reasoningStreamID, assistantStreamID, reasoningFinalIndex, metadata
        case toolInvocation, callID, permissionID, stdoutStreamID, stderrStreamID, toolResult, stdoutFinalIndex, stderrFinalIndex
        case interaction, interactionID, resolution
        case parentRunID, status, resultPreview, late
        case requestID, providerState, detail, statusCode
        case contextState, contextPolicy, contextCompacted
        case goal
        case rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)

        switch kind {
        // Turn / Message
        case "turnCreated":
            self = .turnCreated(try container.decode(TurnSnapshot.self, forKey: .turn))
        case "userMessageCommitted":
            self = .userMessageCommitted(try container.decode(MessageSnapshot.self, forKey: .message))
        case "assistantMessageStarted":
            let messageID = try container.decode(MessageID.self, forKey: .messageID)
            let streamID = try container.decode(StreamID.self, forKey: .streamID)
            self = .assistantMessageStarted(messageID: messageID, assistantStreamID: streamID)
        case "assistantMessageCommitted":
            let messageID = try container.decode(MessageID.self, forKey: .messageID)
            let content = try container.decode(String.self, forKey: .content)
            let finalIndex = try container.decode(UInt64.self, forKey: .finalIndex)
            self = .assistantMessageCommitted(messageID: messageID, content: content, assistantFinalIndex: finalIndex)
        case "turnCompleted":
            let turnID = try container.decode(TurnID.self, forKey: .turnID)
            let reason = try container.decode(TerminalReason.self, forKey: .terminalReason)
            self = .turnCompleted(turnID: turnID, terminalReason: reason)
        case "turnFailed":
            let turnID = try container.decode(TurnID.self, forKey: .turnID)
            let error = try container.decode(RuntimeError.self, forKey: .error)
            self = .turnFailed(turnID: turnID, error: error)

        // Run
        case "runCreated":
            self = .runCreated(try container.decode(RunSnapshot.self, forKey: .run))
        case "runQueued":
            self = .runQueued(runID: try container.decode(RunID.self, forKey: .runID))
        case "runStarted":
            self = .runStarted(runID: try container.decode(RunID.self, forKey: .runID))
        case "runPaused":
            let runID = try container.decode(RunID.self, forKey: .runID)
            let reason = try container.decodeIfPresent(String.self, forKey: .reason)
            self = .runPaused(runID: runID, reason: reason)
        case "runResumed":
            self = .runResumed(runID: try container.decode(RunID.self, forKey: .runID))
        case "runCompleted":
            let runID = try container.decode(RunID.self, forKey: .runID)
            let reason = try container.decode(TerminalReason.self, forKey: .terminalReason)
            self = .runCompleted(runID: runID, terminalReason: reason)
        case "runFailed":
            let runID = try container.decode(RunID.self, forKey: .runID)
            let error = try container.decode(RuntimeError.self, forKey: .error)
            self = .runFailed(runID: runID, error: error)
        case "runCancelled":
            let runID = try container.decode(RunID.self, forKey: .runID)
            let reason = try container.decodeIfPresent(String.self, forKey: .reason)
            self = .runCancelled(runID: runID, reason: reason)

        // ModelStep
        case "modelStepStarted":
            let stepID = try container.decode(ModelStepID.self, forKey: .stepID)
            let reasoningStreamID = try container.decodeIfPresent(StreamID.self, forKey: .reasoningStreamID)
            let assistantStreamID = try container.decodeIfPresent(StreamID.self, forKey: .assistantStreamID)
            self = .modelStepStarted(stepID: stepID, visibleReasoningStreamID: reasoningStreamID, assistantStreamID: assistantStreamID)
        case "modelStepCompleted":
            let stepID = try container.decode(ModelStepID.self, forKey: .stepID)
            let finalIndex = try container.decodeIfPresent(UInt64.self, forKey: .reasoningFinalIndex)
            let metadata = try container.decodeIfPresent(ModelStepOutputMetadata.self, forKey: .metadata)
            self = .modelStepCompleted(stepID: stepID, visibleReasoningFinalIndex: finalIndex, outputMetadata: metadata)
        case "modelStepFailed":
            let stepID = try container.decode(ModelStepID.self, forKey: .stepID)
            let error = try container.decode(RuntimeError.self, forKey: .error)
            self = .modelStepFailed(stepID: stepID, error: error)

        // Tool
        case "toolRequested":
            self = .toolRequested(try container.decode(ToolInvocationSnapshot.self, forKey: .toolInvocation))
        case "toolWaitingForPermission":
            let callID = try container.decode(ToolCallID.self, forKey: .callID)
            let permissionID = try container.decode(PermissionID.self, forKey: .permissionID)
            self = .toolWaitingForPermission(callID: callID, permissionID: permissionID)
        case "toolScheduled":
            self = .toolScheduled(callID: try container.decode(ToolCallID.self, forKey: .callID))
        case "toolRunning":
            let callID = try container.decode(ToolCallID.self, forKey: .callID)
            let stdoutStreamID = try container.decodeIfPresent(StreamID.self, forKey: .stdoutStreamID)
            let stderrStreamID = try container.decodeIfPresent(StreamID.self, forKey: .stderrStreamID)
            self = .toolRunning(callID: callID, stdoutStreamID: stdoutStreamID, stderrStreamID: stderrStreamID)
        case "toolCompleted":
            let callID = try container.decode(ToolCallID.self, forKey: .callID)
            let result = try container.decode(ToolResultSnapshot.self, forKey: .toolResult)
            let outFinal = try container.decodeIfPresent(UInt64.self, forKey: .stdoutFinalIndex)
            let errFinal = try container.decodeIfPresent(UInt64.self, forKey: .stderrFinalIndex)
            self = .toolCompleted(callID: callID, result: result, stdoutFinalIndex: outFinal, stderrFinalIndex: errFinal)
        case "toolFailed":
            let callID = try container.decode(ToolCallID.self, forKey: .callID)
            let error = try container.decode(RuntimeError.self, forKey: .error)
            let outFinal = try container.decodeIfPresent(UInt64.self, forKey: .stdoutFinalIndex)
            let errFinal = try container.decodeIfPresent(UInt64.self, forKey: .stderrFinalIndex)
            self = .toolFailed(callID: callID, error: error, stdoutFinalIndex: outFinal, stderrFinalIndex: errFinal)
        case "toolCancelled":
            let callID = try container.decode(ToolCallID.self, forKey: .callID)
            let outFinal = try container.decodeIfPresent(UInt64.self, forKey: .stdoutFinalIndex)
            let errFinal = try container.decodeIfPresent(UInt64.self, forKey: .stderrFinalIndex)
            self = .toolCancelled(callID: callID, stdoutFinalIndex: outFinal, stderrFinalIndex: errFinal)
        case "toolExecutionStateUnknown":
            self = .toolExecutionStateUnknown(callID: try container.decode(ToolCallID.self, forKey: .callID))

        // Interaction
        case "interactionRequested":
            self = .interactionRequested(try container.decode(InteractionSnapshot.self, forKey: .interaction))
        case "interactionResolved":
            let interactionID = try container.decode(InteractionID.self, forKey: .interactionID)
            let resolution = try container.decode(InteractionResolution.self, forKey: .resolution)
            self = .interactionResolved(interactionID: interactionID, resolution: resolution)
        case "interactionCancelled":
            self = .interactionCancelled(interactionID: try container.decode(InteractionID.self, forKey: .interactionID))

        // Subagent
        case "subagentCreated":
            let runID = try container.decode(RunID.self, forKey: .runID)
            let parentRunID = try container.decode(RunID.self, forKey: .parentRunID)
            self = .subagentCreated(runID: runID, parentRunID: parentRunID)
        case "subagentStateChanged":
            let runID = try container.decode(RunID.self, forKey: .runID)
            let status = try container.decode(String.self, forKey: .status)
            self = .subagentStateChanged(runID: runID, status: status)
        case "subagentTerminal":
            let runID = try container.decode(RunID.self, forKey: .runID)
            let reason = try container.decode(TerminalReason.self, forKey: .terminalReason)
            self = .subagentTerminal(
                runID: runID,
                terminalReason: reason,
                resultPreview: try container.decodeIfPresent(String.self, forKey: .resultPreview),
                late: try container.decodeIfPresent(Bool.self, forKey: .late) ?? false
            )

        // Provider
        case "providerRequestStateChanged":
            let requestID = try container.decode(ProviderRequestID.self, forKey: .requestID)
            let state = try container.decode(ProviderRequestState.self, forKey: .providerState)
            let detail = try container.decodeIfPresent(String.self, forKey: .detail)
            let statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode)
            self = .providerRequestStateChanged(requestID: requestID, state: state, detail: detail, statusCode: statusCode)

        // Context
        case "contextStateChanged":
            self = .contextStateChanged(try container.decode(ContextStateSnapshot.self, forKey: .contextState))
        case "contextPolicyChanged":
            self = .contextPolicyChanged(try container.decode(ContextPolicySnapshot.self, forKey: .contextPolicy))
        case "contextCompacted":
            self = .contextCompacted(try container.decode(ContextCompactedSnapshot.self, forKey: .contextCompacted))

        // Goal Mode
        case "goalChanged":
            self = .goalChanged(try container.decodeIfPresent(GoalRuntimeSnapshot.self, forKey: .goal))

        default:
            let raw = (try? container.decode(String.self, forKey: .rawValue)) ?? kind
            self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        // Turn / Message
        case let .turnCreated(turn):
            try container.encode("turnCreated", forKey: .kind)
            try container.encode(turn, forKey: .turn)
        case let .userMessageCommitted(message):
            try container.encode("userMessageCommitted", forKey: .kind)
            try container.encode(message, forKey: .message)
        case let .assistantMessageStarted(messageID, streamID):
            try container.encode("assistantMessageStarted", forKey: .kind)
            try container.encode(messageID, forKey: .messageID)
            try container.encode(streamID, forKey: .streamID)
        case let .assistantMessageCommitted(messageID, content, finalIndex):
            try container.encode("assistantMessageCommitted", forKey: .kind)
            try container.encode(messageID, forKey: .messageID)
            try container.encode(content, forKey: .content)
            try container.encode(finalIndex, forKey: .finalIndex)
        case let .turnCompleted(turnID, reason):
            try container.encode("turnCompleted", forKey: .kind)
            try container.encode(turnID, forKey: .turnID)
            try container.encode(reason, forKey: .terminalReason)
        case let .turnFailed(turnID, error):
            try container.encode("turnFailed", forKey: .kind)
            try container.encode(turnID, forKey: .turnID)
            try container.encode(error, forKey: .error)

        // Run
        case let .runCreated(run):
            try container.encode("runCreated", forKey: .kind)
            try container.encode(run, forKey: .run)
        case let .runQueued(runID):
            try container.encode("runQueued", forKey: .kind)
            try container.encode(runID, forKey: .runID)
        case let .runStarted(runID):
            try container.encode("runStarted", forKey: .kind)
            try container.encode(runID, forKey: .runID)
        case let .runPaused(runID, reason):
            try container.encode("runPaused", forKey: .kind)
            try container.encode(runID, forKey: .runID)
            try container.encodeIfPresent(reason, forKey: .reason)
        case let .runResumed(runID):
            try container.encode("runResumed", forKey: .kind)
            try container.encode(runID, forKey: .runID)
        case let .runCompleted(runID, reason):
            try container.encode("runCompleted", forKey: .kind)
            try container.encode(runID, forKey: .runID)
            try container.encode(reason, forKey: .terminalReason)
        case let .runFailed(runID, error):
            try container.encode("runFailed", forKey: .kind)
            try container.encode(runID, forKey: .runID)
            try container.encode(error, forKey: .error)
        case let .runCancelled(runID, reason):
            try container.encode("runCancelled", forKey: .kind)
            try container.encode(runID, forKey: .runID)
            try container.encodeIfPresent(reason, forKey: .reason)

        // ModelStep
        case let .modelStepStarted(stepID, reasoningID, assistantID):
            try container.encode("modelStepStarted", forKey: .kind)
            try container.encode(stepID, forKey: .stepID)
            try container.encodeIfPresent(reasoningID, forKey: .reasoningStreamID)
            try container.encodeIfPresent(assistantID, forKey: .assistantStreamID)
        case let .modelStepCompleted(stepID, finalIndex, metadata):
            try container.encode("modelStepCompleted", forKey: .kind)
            try container.encode(stepID, forKey: .stepID)
            try container.encodeIfPresent(finalIndex, forKey: .reasoningFinalIndex)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        case let .modelStepFailed(stepID, error):
            try container.encode("modelStepFailed", forKey: .kind)
            try container.encode(stepID, forKey: .stepID)
            try container.encode(error, forKey: .error)

        // Tool
        case let .toolRequested(snapshot):
            try container.encode("toolRequested", forKey: .kind)
            try container.encode(snapshot, forKey: .toolInvocation)
        case let .toolWaitingForPermission(callID, permissionID):
            try container.encode("toolWaitingForPermission", forKey: .kind)
            try container.encode(callID, forKey: .callID)
            try container.encode(permissionID, forKey: .permissionID)
        case let .toolScheduled(callID):
            try container.encode("toolScheduled", forKey: .kind)
            try container.encode(callID, forKey: .callID)
        case let .toolRunning(callID, stdoutStreamID, stderrStreamID):
            try container.encode("toolRunning", forKey: .kind)
            try container.encode(callID, forKey: .callID)
            try container.encodeIfPresent(stdoutStreamID, forKey: .stdoutStreamID)
            try container.encodeIfPresent(stderrStreamID, forKey: .stderrStreamID)
        case let .toolCompleted(callID, result, stdoutFinal, stderrFinal):
            try container.encode("toolCompleted", forKey: .kind)
            try container.encode(callID, forKey: .callID)
            try container.encode(result, forKey: .toolResult)
            try container.encodeIfPresent(stdoutFinal, forKey: .stdoutFinalIndex)
            try container.encodeIfPresent(stderrFinal, forKey: .stderrFinalIndex)
        case let .toolFailed(callID, error, stdoutFinal, stderrFinal):
            try container.encode("toolFailed", forKey: .kind)
            try container.encode(callID, forKey: .callID)
            try container.encode(error, forKey: .error)
            try container.encodeIfPresent(stdoutFinal, forKey: .stdoutFinalIndex)
            try container.encodeIfPresent(stderrFinal, forKey: .stderrFinalIndex)
        case let .toolCancelled(callID, stdoutFinal, stderrFinal):
            try container.encode("toolCancelled", forKey: .kind)
            try container.encode(callID, forKey: .callID)
            try container.encodeIfPresent(stdoutFinal, forKey: .stdoutFinalIndex)
            try container.encodeIfPresent(stderrFinal, forKey: .stderrFinalIndex)
        case let .toolExecutionStateUnknown(callID):
            try container.encode("toolExecutionStateUnknown", forKey: .kind)
            try container.encode(callID, forKey: .callID)

        // Interaction
        case let .interactionRequested(snapshot):
            try container.encode("interactionRequested", forKey: .kind)
            try container.encode(snapshot, forKey: .interaction)
        case let .interactionResolved(interactionID, resolution):
            try container.encode("interactionResolved", forKey: .kind)
            try container.encode(interactionID, forKey: .interactionID)
            try container.encode(resolution, forKey: .resolution)
        case let .interactionCancelled(interactionID):
            try container.encode("interactionCancelled", forKey: .kind)
            try container.encode(interactionID, forKey: .interactionID)

        // Subagent
        case let .subagentCreated(runID, parentRunID):
            try container.encode("subagentCreated", forKey: .kind)
            try container.encode(runID, forKey: .runID)
            try container.encode(parentRunID, forKey: .parentRunID)
        case let .subagentStateChanged(runID, status):
            try container.encode("subagentStateChanged", forKey: .kind)
            try container.encode(runID, forKey: .runID)
            try container.encode(status, forKey: .status)
        case let .subagentTerminal(runID, reason, resultPreview, late):
            try container.encode("subagentTerminal", forKey: .kind)
            try container.encode(runID, forKey: .runID)
            try container.encode(reason, forKey: .terminalReason)
            try container.encodeIfPresent(resultPreview, forKey: .resultPreview)
            // Omitted unless set so the payload keeps the shape every other frontend already reads.
            if late { try container.encode(true, forKey: .late) }

        // Provider
        case let .providerRequestStateChanged(requestID, state, detail, statusCode):
            try container.encode("providerRequestStateChanged", forKey: .kind)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(state, forKey: .providerState)
            try container.encodeIfPresent(detail, forKey: .detail)
            try container.encodeIfPresent(statusCode, forKey: .statusCode)

        // Context
        case let .contextStateChanged(snapshot):
            try container.encode("contextStateChanged", forKey: .kind)
            try container.encode(snapshot, forKey: .contextState)
        case let .contextPolicyChanged(snapshot):
            try container.encode("contextPolicyChanged", forKey: .kind)
            try container.encode(snapshot, forKey: .contextPolicy)
        case let .contextCompacted(snapshot):
            try container.encode("contextCompacted", forKey: .kind)
            try container.encode(snapshot, forKey: .contextCompacted)

        // Goal Mode
        case let .goalChanged(snapshot):
            try container.encode("goalChanged", forKey: .kind)
            try container.encodeIfPresent(snapshot, forKey: .goal)

        case let .unknown(raw):
            try container.encode("unknown", forKey: .kind)
            try container.encode(raw, forKey: .rawValue)
        }
    }
}

/// SessionEventEnvelope：Session 语义事件完整信封，附带全局 EventCursor 与统一 CausalContext。
public struct SessionEventEnvelope: Codable, Sendable, Equatable {
    public let cursor: EventCursor
    public let timestamp: Date
    public let causal: CausalContext
    public let payload: SessionEventPayload

    public init(
        cursor: EventCursor,
        timestamp: Date = Date(),
        causal: CausalContext,
        payload: SessionEventPayload
    ) {
        self.cursor = cursor
        self.timestamp = timestamp
        self.causal = causal
        self.payload = payload
    }
}
