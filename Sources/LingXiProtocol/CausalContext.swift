import Foundation

/// CausalContext 统一表达 Workflow / Subagent / HITL 的因果溯源。
/// 任何 Permission / Question / Decision / Stream / Event 均可明确确定所属归属。
public struct CausalContext: Codable, Sendable, Equatable, Hashable {
    public let sessionID: SessionID
    public let turnID: TurnID?
    public let runID: RunID?

    public let rootSessionID: SessionID?
    public let originSessionID: SessionID?

    public let rootRunID: RunID?
    public let parentRunID: RunID?

    public let workflowID: WorkflowID?
    public let workflowTaskID: WorkflowTaskID?

    public let modelStepID: ModelStepID?
    public let toolCallID: ToolCallID?
    public let providerRequestID: ProviderRequestID?

    public init(
        sessionID: SessionID,
        turnID: TurnID? = nil,
        runID: RunID? = nil,
        rootSessionID: SessionID? = nil,
        originSessionID: SessionID? = nil,
        rootRunID: RunID? = nil,
        parentRunID: RunID? = nil,
        workflowID: WorkflowID? = nil,
        workflowTaskID: WorkflowTaskID? = nil,
        modelStepID: ModelStepID? = nil,
        toolCallID: ToolCallID? = nil,
        providerRequestID: ProviderRequestID? = nil
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.runID = runID
        self.rootSessionID = rootSessionID ?? sessionID
        self.originSessionID = originSessionID ?? sessionID
        self.rootRunID = rootRunID ?? runID
        self.parentRunID = parentRunID
        self.workflowID = workflowID
        self.workflowTaskID = workflowTaskID
        self.modelStepID = modelStepID
        self.toolCallID = toolCallID
        self.providerRequestID = providerRequestID
    }
}
