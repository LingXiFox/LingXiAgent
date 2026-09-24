import Foundation

/// 任务收尾动作 (Accept / Discard / Finish)
public enum TaskFinalizeAction: String, Sendable, Codable, CaseIterable {
    case accept = "accept"
    case discard = "discard"
    case finish = "finish"
}

/// 任务收尾请求
public struct TaskFinalizeRequest: Sendable, Codable, Equatable {
    public let taskID: TaskID
    public let action: TaskFinalizeAction
    public let message: String?

    public init(taskID: TaskID, action: TaskFinalizeAction, message: String? = nil) {
        self.taskID = taskID
        self.action = action
        self.message = message
    }
}

/// 任务执行总结报告
public struct TaskReport: Sendable, Codable, Equatable {
    public let taskID: TaskID
    public let summary: String
    public let changesSummary: String
    public let verificationSummary: String
    public let unresolvedIssues: [String]
    public let finalVerdict: String
    public let createdAt: Date

    public init(
        taskID: TaskID,
        summary: String,
        changesSummary: String = "",
        verificationSummary: String = "",
        unresolvedIssues: [String] = [],
        finalVerdict: String = "completed",
        createdAt: Date = .now
    ) {
        self.taskID = taskID
        self.summary = summary
        self.changesSummary = changesSummary
        self.verificationSummary = verificationSummary
        self.unresolvedIssues = unresolvedIssues
        self.finalVerdict = finalVerdict
        self.createdAt = createdAt
    }
}

/// 任务阶段计划
public struct TaskPlanPhase: Sendable, Codable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public var steps: [String]
    public var status: String // pending, in_progress, completed, failed

    public init(name: String, steps: [String] = [], status: String = "pending") {
        self.name = name
        self.steps = steps
        self.status = status
    }
}

/// 任务规划 (TaskPlan)
public struct TaskPlan: Sendable, Codable, Equatable {
    public let taskID: TaskID
    public var phases: [TaskPlanPhase]

    public init(taskID: TaskID, phases: [TaskPlanPhase] = []) {
        self.taskID = taskID
        self.phases = phases
    }
}

/// 任务规格 (TaskSpec)
public struct TaskSpec: Sendable, Codable, Equatable {
    public let taskID: TaskID
    public var requirements: [String]
    public var acceptanceCriteria: [String]
    public var filesInScope: [String]
    public var filesOutOfScope: [String]
    public var forbiddenActions: [String]

    public init(
        taskID: TaskID,
        requirements: [String] = [],
        acceptanceCriteria: [String] = [],
        filesInScope: [String] = [],
        filesOutOfScope: [String] = [],
        forbiddenActions: [String] = []
    ) {
        self.taskID = taskID
        self.requirements = requirements
        self.acceptanceCriteria = acceptanceCriteria
        self.filesInScope = filesInScope
        self.filesOutOfScope = filesOutOfScope
        self.forbiddenActions = forbiddenActions
    }
}

/// 任务运行限制 (TaskLimits)
public struct TaskLimits: Sendable, Codable, Equatable {
    public var maxSteps: Int
    public var maxTokens: Int
    public var maxExecutionTimeSeconds: Int

    public init(
        maxSteps: Int = 100,
        maxTokens: Int = 1_000_000,
        maxExecutionTimeSeconds: Int = 3600
    ) {
        self.maxSteps = maxSteps
        self.maxTokens = maxTokens
        self.maxExecutionTimeSeconds = maxExecutionTimeSeconds
    }
}

/// 更新成功条件请求
public struct UpdateTaskCriteriaRequest: Sendable, Codable, Equatable {
    public let taskID: TaskID
    public let criteria: [SuccessCriterion]

    public init(taskID: TaskID, criteria: [SuccessCriterion]) {
        self.taskID = taskID
        self.criteria = criteria
    }
}

/// 任务分叉请求
public struct ForkTaskRequest: Sendable, Codable, Equatable {
    public let sourceTaskID: TaskID
    public let newSessionID: SessionID?

    public init(sourceTaskID: TaskID, newSessionID: SessionID? = nil) {
        self.sourceTaskID = sourceTaskID
        self.newSessionID = newSessionID
    }
}

/// 创建任务请求
public struct CreateTaskRequest: Sendable, Codable, Equatable {
    public let sessionID: SessionID
    public let objective: String
    public let projectID: String
    public let successCriteria: [SuccessCriterion]
    public let limits: TaskLimits

    public init(
        sessionID: SessionID,
        objective: String,
        projectID: String = "default",
        successCriteria: [SuccessCriterion] = [],
        limits: TaskLimits = TaskLimits()
    ) {
        self.sessionID = sessionID
        self.objective = objective
        self.projectID = projectID
        self.successCriteria = successCriteria
        self.limits = limits
    }
}

/// 获取任务请求
public struct GetTaskRequest: Sendable, Codable, Equatable {
    public let taskID: TaskID

    public init(taskID: TaskID) {
        self.taskID = taskID
    }
}

/// 列出任务请求
public struct ListTasksRequest: Sendable, Codable, Equatable {
    public let sessionID: SessionID?
    public let projectID: String?

    public init(sessionID: SessionID? = nil, projectID: String? = nil) {
        self.sessionID = sessionID
        self.projectID = projectID
    }
}

