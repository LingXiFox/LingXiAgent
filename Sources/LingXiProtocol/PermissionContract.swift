import Foundation

/// AgentMode 定义代理运行模式。只读模式收窄工具能力上限。
public enum AgentMode: String, Codable, Sendable, Equatable {
    case build
    case plan
    case explore
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = AgentMode(rawValue: raw) ?? .unknown
    }

    public var displayName: String {
        switch self {
        case .build: "Build"
        case .plan: "Plan"
        case .explore: "Explore"
        case .unknown: "Unknown"
        }
    }

    public var next: AgentMode {
        switch self {
        case .build: .plan
        case .plan: .explore
        case .explore, .unknown: .build
        }
    }
}

/// AccessScope 定义不可由普通审批越过的 hard maximum 作用域。
public enum AccessScope: String, Codable, Sendable, Equatable {
    case workspace
    case fullAccess
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = AccessScope(rawValue: raw) ?? .unknown
    }
}

/// 审批动作决策。
public enum ApprovalDecision: String, Codable, Sendable, Equatable {
    case allow
    case ask
    case deny
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = ApprovalDecision(rawValue: raw) ?? .unknown
    }
}

/// OperationApprovalPolicy 定义细粒度操作策略。
public struct OperationApprovalPolicy: Codable, Sendable, Equatable {
    public let safeRead: ApprovalDecision
    public let workspaceMutation: ApprovalDecision
    public let processExecution: ApprovalDecision
    public let externalRead: ApprovalDecision
    public let externalMutation: ApprovalDecision
    public let sensitiveAccess: ApprovalDecision

    public init(
        safeRead: ApprovalDecision = .allow,
        workspaceMutation: ApprovalDecision = .ask,
        processExecution: ApprovalDecision = .ask,
        externalRead: ApprovalDecision = .deny,
        externalMutation: ApprovalDecision = .deny,
        sensitiveAccess: ApprovalDecision = .deny
    ) {
        self.safeRead = safeRead
        self.workspaceMutation = workspaceMutation
        self.processExecution = processExecution
        self.externalRead = externalRead
        self.externalMutation = externalMutation
        self.sensitiveAccess = sensitiveAccess
    }
}
