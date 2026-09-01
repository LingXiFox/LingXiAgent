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

/// Coding Tool 共享的权限动作域。write、edit 与 patch 必须使用同一个 edit 域。
public enum PermissionAction: String, Sendable, Equatable, Codable {
    case read
    case edit
    case shell
    case externalDirectory
}

public struct PermissionResourceRule: Sendable, Equatable, Codable {
    public let action: PermissionAction
    /// 支持 * 通配符；文件动作匹配 canonical path，shell 匹配原始 command。
    public let resourcePattern: String
    public let decision: PermissionDecision

    public init(action: PermissionAction, resourcePattern: String = "*", decision: PermissionDecision) {
        self.action = action
        self.resourcePattern = resourcePattern
        self.decision = decision
    }
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
    public let capability: ToolCapabilityKind?
    public let decision: PermissionDecision

    public init(toolID: ToolID, capability: ToolCapabilityKind? = nil, decision: PermissionDecision) {
        self.toolID = toolID
        self.capability = capability
        self.decision = decision
    }
}

public struct PermissionRequest: Sendable, Equatable, Codable {
    public let permissionID: PermissionID
    public let sessionID: SessionID
    public let toolCallID: ToolCallID
    public let toolID: ToolID
    public let capabilities: Set<ToolCapabilityKind>
    /// 经过 Workspace Root 解析后的资源路径。
    public let resource: String
    public let description: String

    public init(
        permissionID: PermissionID,
        sessionID: SessionID,
        toolCallID: ToolCallID,
        toolID: ToolID,
        capabilities: Set<ToolCapabilityKind> = [],
        resource: String,
        description: String
    ) {
        self.permissionID = permissionID
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.toolID = toolID
        self.capabilities = capabilities
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
