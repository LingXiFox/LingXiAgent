import Foundation

/// 侧提问请求 (临时只读 Run，不进入主会话历史)
public struct SubmitSideQuestionRequest: Sendable, Codable, Equatable {
    public let sessionID: SessionID
    public let question: String
    public let contextTurnID: TurnID?

    public init(sessionID: SessionID, question: String, contextTurnID: TurnID? = nil) {
        self.sessionID = sessionID
        self.question = question
        self.contextTurnID = contextTurnID
    }
}

/// 侧提问结果
public struct SideQuestionResult: Sendable, Codable, Equatable {
    public let answer: String
    public let modelUsed: String
    public let durationMs: Int

    public init(answer: String, modelUsed: String, durationMs: Int = 0) {
        self.answer = answer
        self.modelUsed = modelUsed
        self.durationMs = durationMs
    }
}

/// Agent 运行模式 (Build / Plan / Explore)
public enum AgentRunMode: String, Sendable, Codable, CaseIterable {
    case build = "Build"
    case plan = "Plan"
    case explore = "Explore"
}

/// 思考等级 (Auto / Off / Low / Med / High / Max)
public enum ReasoningEffortLevel: String, Sendable, Codable, CaseIterable {
    case auto = "Auto"
    case off = "Off"
    case low = "Low"
    case med = "Med"
    case high = "High"
    case max = "Max"
}

/// 权限策略 (Ask / Auto / YOLO)
public enum PermissionPolicyLevel: String, Sendable, Codable, CaseIterable {
    case ask = "Ask"
    case auto = "Auto"
    case yolo = "YOLO"
}

/// Agent 预设配置
public struct AgentPresetInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var mode: AgentRunMode
    public var recommendedModel: String
    public var reasoningEffort: ReasoningEffortLevel
    public var permissionPolicy: PermissionPolicyLevel

    public init(
        id: String,
        name: String,
        description: String,
        mode: AgentRunMode = .build,
        recommendedModel: String = "auto",
        reasoningEffort: ReasoningEffortLevel = .auto,
        permissionPolicy: PermissionPolicyLevel = .ask
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.mode = mode
        self.recommendedModel = recommendedModel
        self.reasoningEffort = reasoningEffort
        self.permissionPolicy = permissionPolicy
    }
}

/// Agent 运行详情
public struct AgentRunDetail: Sendable, Codable, Equatable, Identifiable {
    public var id: AgentRunID { runID }
    public let runID: AgentRunID
    public let parentRunID: AgentRunID?
    public let taskID: TaskID?
    public var name: String
    public var model: String
    public var reasoningEffort: ReasoningEffortLevel
    public var permissionPolicy: PermissionPolicyLevel
    public var status: String
    public let createdAt: Date

    public init(
        runID: AgentRunID = .generate(),
        parentRunID: AgentRunID? = nil,
        taskID: TaskID? = nil,
        name: String,
        model: String = "auto",
        reasoningEffort: ReasoningEffortLevel = .auto,
        permissionPolicy: PermissionPolicyLevel = .ask,
        status: String = "running",
        createdAt: Date = .now
    ) {
        self.runID = runID
        self.parentRunID = parentRunID
        self.taskID = taskID
        self.name = name
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.permissionPolicy = permissionPolicy
        self.status = status
        self.createdAt = createdAt
    }
}

/// 多模型并行对比请求
public struct MultiRunCompareRequest: Sendable, Codable, Equatable {
    public let prompt: String
    public let modelIDs: [String]
    public let systemPrompt: String?

    public init(prompt: String, modelIDs: [String], systemPrompt: String? = nil) {
        self.prompt = prompt
        self.modelIDs = modelIDs
        self.systemPrompt = systemPrompt
    }
}

/// 多模型对比结果
public struct MultiRunCompareResult: Sendable, Codable, Equatable {
    public let runs: [String: String]
    public let fusionResult: String?

    public init(runs: [String: String], fusionResult: String? = nil) {
        self.runs = runs
        self.fusionResult = fusionResult
    }
}
