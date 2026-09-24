import Foundation

/// 任务胶囊 (TaskCapsule)
/// V1.1 核心状态载体，将执行上下文、工作区、控制点、产物与恢复点聚合为单一真理源。
public struct TaskCapsule: Sendable, Codable, Equatable {
    public let taskID: TaskID
    public let parentTaskID: TaskID?
    public let forkedFromTaskID: TaskID?
    public let workspaceID: WorkspaceID
    public let sessionID: SessionID
    public let rootRunID: AgentRunID?
    public let projectID: String
    public let objective: String
    public var successCriteria: [SuccessCriterion]
    public var state: TaskState
    public var waitingReason: WaitingReason?
    public var resumePoint: ResumePoint?
    public var contextRef: String?
    public var toolStates: [ToolExecutionState]
    public var artifacts: [TaskArtifact]
    public var validationEvidence: [ValidationEvidence]
    public var riskState: RiskState
    public var revision: Int
    public var modelSelection: [String: String]
    public let createdAt: Date
    public var updatedAt: Date
    public let protocolVersion: ProtocolVersion

    public init(
        taskID: TaskID = .generate(),
        parentTaskID: TaskID? = nil,
        forkedFromTaskID: TaskID? = nil,
        workspaceID: WorkspaceID = .generate(),
        sessionID: SessionID,
        rootRunID: AgentRunID? = nil,
        projectID: String,
        objective: String,
        successCriteria: [SuccessCriterion] = [],
        state: TaskState = .queued,
        waitingReason: WaitingReason? = nil,
        resumePoint: ResumePoint? = nil,
        contextRef: String? = nil,
        toolStates: [ToolExecutionState] = [],
        artifacts: [TaskArtifact] = [],
        validationEvidence: [ValidationEvidence] = [],
        riskState: RiskState = RiskState(),
        revision: Int = 1,
        modelSelection: [String: String] = [:],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        protocolVersion: ProtocolVersion = .current
    ) {
        self.taskID = taskID
        self.parentTaskID = parentTaskID
        self.forkedFromTaskID = forkedFromTaskID
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.rootRunID = rootRunID
        self.projectID = projectID
        self.objective = objective
        self.successCriteria = successCriteria
        self.state = state
        self.waitingReason = waitingReason
        self.resumePoint = resumePoint
        self.contextRef = contextRef
        self.toolStates = toolStates
        self.artifacts = artifacts
        self.validationEvidence = validationEvidence
        self.riskState = riskState
        self.revision = revision
        self.modelSelection = modelSelection
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.protocolVersion = protocolVersion
    }
}
