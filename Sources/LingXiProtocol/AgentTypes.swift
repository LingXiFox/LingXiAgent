import Foundation

public struct ProjectID: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct AgentRunID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public enum SessionKind: String, Sendable, Equatable, Codable {
    case primary
    case subagent
}

/// Agent 行为策略；只读策略还会在 Tool Runtime 中收窄 capability，不能仅依赖 prompt。
public enum AgentBehaviorProfile: String, Sendable, Equatable, Codable {
    case build
    case plan
    case explore

    public var executionProfile: SubagentExecutionProfile? {
        switch self {
        case .build: nil
        case .plan, .explore: SubagentExecutionProfile(permissionProfile: ExecutionProfile.readOnly.rawValue)
        }
    }
}

public enum AgentRunStatus: String, Sendable, Equatable, Codable {
    case queued
    case starting
    case running
    case waitingForTool
    case waitingForUser
    case completed
    case failed
    case cancelled
    case timedOut
    case recoveryRequired

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .timedOut, .recoveryRequired: true
        default: false
        }
    }
}

/// A model choice belongs to one execution, never to a durable Session.
public struct ModelSelection: Sendable, Equatable, Codable {
    public let providerID: String
    public let accountID: String?
    public let profileID: String?
    public let modelID: String
    public let reasoning: String?
    public let contextProfile: String?

    public init(providerID: String = "default", accountID: String? = nil, profileID: String? = nil, modelID: String, reasoning: String? = nil, contextProfile: String? = nil) {
        self.providerID = providerID
        self.accountID = accountID
        self.profileID = profileID
        self.modelID = modelID
        self.reasoning = reasoning
        self.contextProfile = contextProfile
    }
}

public struct SubagentExecutionProfile: Sendable, Equatable, Codable {
    public let modelSelection: ModelSelection?
    public let permissionProfile: String?
    public let toolProfile: [String]?
    public let budgetProfile: String?
    public let contextProfile: String?
    public let maxSteps: Int?
    public let timeoutSeconds: Int?

    public init(modelSelection: ModelSelection? = nil, permissionProfile: String? = nil, toolProfile: [String]? = nil, budgetProfile: String? = nil, contextProfile: String? = nil, maxSteps: Int? = nil, timeoutSeconds: Int? = nil) {
        self.modelSelection = modelSelection
        self.permissionProfile = permissionProfile
        self.toolProfile = toolProfile
        self.budgetProfile = budgetProfile
        self.contextProfile = contextProfile
        self.maxSteps = maxSteps
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct AgentRunUsage: Sendable, Equatable, Codable {
    public let model: ModelUsage?
    public let toolCalls: Int
    public let mcpCalls: Int
    public let elapsedMilliseconds: Double?

    public init(model: ModelUsage? = nil, toolCalls: Int = 0, mcpCalls: Int = 0, elapsedMilliseconds: Double? = nil) {
        self.model = model
        self.toolCalls = toolCalls
        self.mcpCalls = mcpCalls
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public struct AgentRunInfo: Sendable, Equatable, Codable {
    public let runID: AgentRunID
    public let sessionID: SessionID
    public let projectID: ProjectID?
    public let parentRunID: AgentRunID?
    public let rootRunID: AgentRunID
    public let agentKind: SessionKind
    public let status: AgentRunStatus
    public let modelSelection: ModelSelection
    public let startedAt: Date?
    public let finishedAt: Date?
    public let latestActivityAt: Date
    public let error: CoreError?
    public let usage: AgentRunUsage
    public let title: String?

    public init(runID: AgentRunID, sessionID: SessionID, projectID: ProjectID?, parentRunID: AgentRunID? = nil, rootRunID: AgentRunID, agentKind: SessionKind, status: AgentRunStatus, modelSelection: ModelSelection, startedAt: Date? = nil, finishedAt: Date? = nil, latestActivityAt: Date = .now, error: CoreError? = nil, usage: AgentRunUsage = AgentRunUsage(), title: String? = nil) {
        self.runID = runID
        self.sessionID = sessionID
        self.projectID = projectID
        self.parentRunID = parentRunID
        self.rootRunID = rootRunID
        self.agentKind = agentKind
        self.status = status
        self.modelSelection = modelSelection
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.latestActivityAt = latestActivityAt
        self.error = error
        self.usage = usage
        self.title = title
    }
}

public struct SubagentResult: Sendable, Equatable, Codable {
    public let childSessionID: SessionID
    public let runID: AgentRunID
    public let status: AgentRunStatus
    public let finalText: String?
    public let touchedResources: [ToolTouchedResource]
    public let artifactReferences: [String]
    public let usage: AgentRunUsage
    public let error: CoreError?
    public let timestamp: Date

    public init(childSessionID: SessionID, runID: AgentRunID, status: AgentRunStatus, finalText: String? = nil, touchedResources: [ToolTouchedResource] = [], artifactReferences: [String] = [], usage: AgentRunUsage = AgentRunUsage(), error: CoreError? = nil, timestamp: Date = .now) {
        self.childSessionID = childSessionID
        self.runID = runID
        self.status = status
        self.finalText = finalText
        self.touchedResources = touchedResources
        self.artifactReferences = artifactReferences
        self.usage = usage
        self.error = error
        self.timestamp = timestamp
    }
}

public struct AgentTreeNode: Sendable, Equatable, Codable {
    public let session: SessionInfo
    public let latestRun: AgentRunInfo?
    public let children: [AgentTreeNode]

    public init(session: SessionInfo, latestRun: AgentRunInfo?, children: [AgentTreeNode]) {
        self.session = session
        self.latestRun = latestRun
        self.children = children
    }
}
