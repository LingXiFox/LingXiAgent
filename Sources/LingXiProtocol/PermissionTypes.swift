import Foundation

public struct PermissionID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum PermissionDecision: String, Sendable, Equatable, Codable {
    case allow
    case ask
    case deny
}

public enum PermissionPolicy: String, Sendable, Equatable, Codable {
    case ask
    case auto
}

public enum ExecutionProfile: String, Sendable, Equatable, Codable {
    case readOnly
    case workspace
    case fullAccess
}

public struct PermissionConfiguration: Sendable, Equatable, Codable {
    public let policy: PermissionPolicy
    public let profile: ExecutionProfile

    public init(policy: PermissionPolicy, profile: ExecutionProfile) {
        self.policy = policy
        self.profile = profile
    }

    public static let strict = PermissionConfiguration(policy: .ask, profile: .workspace)
    public static let agent = PermissionConfiguration(policy: .auto, profile: .workspace)
    public static let yolo = PermissionConfiguration(policy: .auto, profile: .fullAccess)
}

public struct PermissionRule: Sendable, Equatable, Codable {
    public let toolID: ToolID
    public let decision: PermissionDecision

    public init(toolID: ToolID, decision: PermissionDecision) {
        self.toolID = toolID
        self.decision = decision
    }
}

public struct PermissionRequest: Sendable, Equatable, Codable {
    public let permissionID: PermissionID
    public let sessionID: SessionID
    public let toolCallID: ToolCallID
    public let toolID: ToolID
    /// 经过 Workspace Root 解析后的资源路径。
    public let resource: String
    public let description: String

    public init(
        permissionID: PermissionID,
        sessionID: SessionID,
        toolCallID: ToolCallID,
        toolID: ToolID,
        resource: String,
        description: String
    ) {
        self.permissionID = permissionID
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.toolID = toolID
        self.resource = resource
        self.description = description
    }
}

public struct PermissionReply: Sendable, Equatable, Codable {
    public let permissionID: PermissionID
    /// 本阶段仅接受 allow（once）或 deny。
    public let decision: PermissionDecision

    public init(permissionID: PermissionID, decision: PermissionDecision) {
        self.permissionID = permissionID
        self.decision = decision
    }
}
