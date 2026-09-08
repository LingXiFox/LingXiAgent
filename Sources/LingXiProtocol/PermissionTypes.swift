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
    public let accessScope: AccessScope
    public let approvalPolicy: OperationApprovalPolicy

    public var policy: PermissionPolicy {
        approvalPolicy.workspaceMutation == .allow ? .auto : .ask
    }
    public var profile: ExecutionProfile {
        accessScope == .fullAccess ? .fullAccess : .workspace
    }

    public var displayName: String {
        if accessScope == .fullAccess {
            let isYOLO = approvalPolicy.workspaceMutation == .allow
                && approvalPolicy.processExecution == .allow
                && approvalPolicy.externalRead == .allow
                && approvalPolicy.externalMutation == .allow
            return isYOLO ? "YOLO" : "FullAccess"
        }
        return approvalPolicy.workspaceMutation == .allow ? "Auto/Workspace" : "Ask/Workspace"
    }

    public init(accessScope: AccessScope, approvalPolicy: OperationApprovalPolicy) {
        self.accessScope = accessScope
        self.approvalPolicy = approvalPolicy
    }

    public init(policy: PermissionPolicy, profile: ExecutionProfile) {
        let scope: AccessScope = (profile == .fullAccess) ? .fullAccess : .workspace
        self.accessScope = scope
        switch (policy, profile) {
        case (.ask, .workspace), (.ask, .readOnly):
            self.approvalPolicy = OperationApprovalPolicy(
                safeRead: .allow,
                workspaceMutation: .ask,
                processExecution: .ask,
                externalRead: .deny,
                externalMutation: .deny,
                sensitiveAccess: .deny
            )
        case (.auto, .workspace), (.auto, .readOnly):
            self.approvalPolicy = OperationApprovalPolicy(
                safeRead: .allow,
                workspaceMutation: .allow,
                processExecution: .allow,
                externalRead: .deny,
                externalMutation: .deny,
                sensitiveAccess: .deny
            )
        case (.ask, .fullAccess):
            self.approvalPolicy = OperationApprovalPolicy(
                safeRead: .allow,
                workspaceMutation: .ask,
                processExecution: .ask,
                externalRead: .ask,
                externalMutation: .ask,
                sensitiveAccess: .deny
            )
        case (.auto, .fullAccess):
            self.approvalPolicy = OperationApprovalPolicy(
                safeRead: .allow,
                workspaceMutation: .allow,
                processExecution: .allow,
                externalRead: .allow,
                externalMutation: .allow,
                sensitiveAccess: .deny
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case accessScope, approvalPolicy, policy, profile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let scope = try? container.decode(AccessScope.self, forKey: .accessScope),
           let policy = try? container.decode(OperationApprovalPolicy.self, forKey: .approvalPolicy) {
            self.init(accessScope: scope, approvalPolicy: policy)
        } else if let legacyPolicy = try? container.decode(PermissionPolicy.self, forKey: .policy),
                  let legacyProfile = try? container.decode(ExecutionProfile.self, forKey: .profile) {
            self.init(policy: legacyPolicy, profile: legacyProfile)
        } else {
            self = .askWorkspace
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessScope, forKey: .accessScope)
        try container.encode(approvalPolicy, forKey: .approvalPolicy)
        try container.encode(policy, forKey: .policy)
        try container.encode(profile, forKey: .profile)
    }

    // Frozen Presets
    public static let askWorkspace = PermissionConfiguration(
        accessScope: .workspace,
        approvalPolicy: OperationApprovalPolicy(
            safeRead: .allow,
            workspaceMutation: .ask,
            processExecution: .ask,
            externalRead: .deny,
            externalMutation: .deny,
            sensitiveAccess: .deny
        )
    )

    public static let autoWorkspace = PermissionConfiguration(
        accessScope: .workspace,
        approvalPolicy: OperationApprovalPolicy(
            safeRead: .allow,
            workspaceMutation: .allow,
            processExecution: .allow,
            externalRead: .deny,
            externalMutation: .deny,
            sensitiveAccess: .deny
        )
    )

    public static let askFullAccess = PermissionConfiguration(
        accessScope: .fullAccess,
        approvalPolicy: OperationApprovalPolicy(
            safeRead: .allow,
            workspaceMutation: .ask,
            processExecution: .ask,
            externalRead: .ask,
            externalMutation: .ask,
            sensitiveAccess: .deny
        )
    )

    public static let yoloFullAccess = PermissionConfiguration(
        accessScope: .fullAccess,
        approvalPolicy: OperationApprovalPolicy(
            safeRead: .allow,
            workspaceMutation: .allow,
            processExecution: .allow,
            externalRead: .allow,
            externalMutation: .allow,
            sensitiveAccess: .deny
        )
    )

    // Legacy Aliases
    public static let strict = askWorkspace
    public static let agent = autoWorkspace
    public static let yolo = yoloFullAccess
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
