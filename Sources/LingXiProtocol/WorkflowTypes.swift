import Foundation

public struct WorkflowID: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct WorkflowTaskID: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct DecisionID: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum WorkflowStatus: String, Sendable, Equatable, Codable {
    case pending, running, waitingForUser, completed, failed, cancelled, recoveryRequired

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }
}

public enum WorkflowTaskStatus: String, Sendable, Equatable, Codable {
    case pending, running, waitingForQuestion, waitingForPermission, waitingForDecision
    case completed, failed, cancelled, timedOut, blocked, recoveryRequired

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .timedOut, .blocked: true
        default: false
        }
    }
}

public enum WorkflowTaskKind: String, Sendable, Equatable, Codable {
    case agent
    case decision
}

/// Immutable task definition. Agent input is explicit so sibling sessions never inherit each other's context.
public struct WorkflowTaskDefinition: Sendable, Equatable, Codable {
    public let id: WorkflowTaskID
    public let title: String?
    public let kind: WorkflowTaskKind
    public let task: String
    public let dependencies: [WorkflowTaskID]
    public let role: String?
    public let instructions: String?
    public let context: String?
    public let modelSelection: ModelSelection?
    public let executionProfile: SubagentExecutionProfile?

    public init(id: WorkflowTaskID, title: String? = nil, kind: WorkflowTaskKind = .agent, task: String, dependencies: [WorkflowTaskID] = [], role: String? = nil, instructions: String? = nil, context: String? = nil, modelSelection: ModelSelection? = nil, executionProfile: SubagentExecutionProfile? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.task = task
        self.dependencies = dependencies
        self.role = role
        self.instructions = instructions
        self.context = context
        self.modelSelection = modelSelection
        self.executionProfile = executionProfile
    }
}

public struct WorkflowTaskProvenance: Sendable, Equatable, Codable {
    public let parentSessionID: SessionID
    public let parentRunID: AgentRunID
    public let childSessionID: SessionID?
    public let childRunID: AgentRunID?

    public init(parentSessionID: SessionID, parentRunID: AgentRunID, childSessionID: SessionID? = nil, childRunID: AgentRunID? = nil) {
        self.parentSessionID = parentSessionID
        self.parentRunID = parentRunID
        self.childSessionID = childSessionID
        self.childRunID = childRunID
    }
}

public struct WorkflowCheckpoint: Sendable, Equatable, Codable {
    public let sequence: Int
    public let taskID: WorkflowTaskID?
    public let label: String
    public let createdAt: Date

    public init(sequence: Int, taskID: WorkflowTaskID? = nil, label: String, createdAt: Date = .now) {
        self.sequence = sequence
        self.taskID = taskID
        self.label = label
        self.createdAt = createdAt
    }
}

public struct DecisionRequest: Sendable, Equatable, Codable {
    public let decisionID: DecisionID
    public let question: String
    public let options: [String]
    public let originSessionID: SessionID
    public let originRunID: AgentRunID

    public init(decisionID: DecisionID, question: String, options: [String], originSessionID: SessionID, originRunID: AgentRunID) {
        self.decisionID = decisionID
        self.question = question
        self.options = options
        self.originSessionID = originSessionID
        self.originRunID = originRunID
    }
}

public enum WorkflowPendingInput: Sendable, Equatable, Codable {
    case question(QuestionRequest)
    case permission(PermissionRequest)
    case decision(DecisionRequest)
}

public struct WorkflowTaskState: Sendable, Equatable, Codable {
    public let definition: WorkflowTaskDefinition
    public let status: WorkflowTaskStatus
    public let provenance: WorkflowTaskProvenance?
    public let result: SubagentResult?
    public let pendingInput: WorkflowPendingInput?
    public let error: CoreError?

    public init(definition: WorkflowTaskDefinition, status: WorkflowTaskStatus = .pending, provenance: WorkflowTaskProvenance? = nil, result: SubagentResult? = nil, pendingInput: WorkflowPendingInput? = nil, error: CoreError? = nil) {
        self.definition = definition
        self.status = status
        self.provenance = provenance
        self.result = result
        self.pendingInput = pendingInput
        self.error = error
    }
}

/// Complete durable workflow fact. A checkpoint is committed with every state transition.
public struct WorkflowSnapshot: Sendable, Equatable, Codable {
    public let id: WorkflowID
    public let rootSessionID: SessionID
    public let rootRunID: AgentRunID
    public let status: WorkflowStatus
    public let tasks: [WorkflowTaskState]
    public let checkpoint: WorkflowCheckpoint
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: WorkflowID, rootSessionID: SessionID, rootRunID: AgentRunID, status: WorkflowStatus = .pending, tasks: [WorkflowTaskState], checkpoint: WorkflowCheckpoint = WorkflowCheckpoint(sequence: 0, label: "created"), createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.rootSessionID = rootSessionID
        self.rootRunID = rootRunID
        self.status = status
        self.tasks = tasks
        self.checkpoint = checkpoint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
