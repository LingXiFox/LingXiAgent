import Foundation

public enum PrincipalKind: String, Codable, Sendable, Equatable, Hashable {
    case session
    case task
    case subagent
    case mcpServer
    case plugin
    case browserHost
}

public struct CapabilityPrincipal: Codable, Sendable, Equatable, Hashable {
    public let kind: PrincipalKind
    public let id: String
    public let parentPrincipal: PrincipalKind?
    public let parentID: String?

    public init(
        kind: PrincipalKind,
        id: String,
        parentPrincipal: PrincipalKind? = nil,
        parentID: String? = nil
    ) {
        self.kind = kind
        self.id = id
        self.parentPrincipal = parentPrincipal
        self.parentID = parentID
    }
}

public enum CapabilityGrantState: String, Codable, Sendable, Equatable {
    case active
    case revoked
    case expired
}

public struct CapabilityGrant: Codable, Sendable, Equatable, Identifiable {
    public var id: String { grantID }
    public let grantID: String
    public let principalKind: PrincipalKind
    public let principalID: String
    public let capabilityKind: String
    public let resourcePattern: String
    public let scope: String
    public let issuedBy: String
    public let issuedAt: Date
    public let expiresAt: Date?
    public let state: CapabilityGrantState
    public let revokedAt: Date?
    public let revokeReason: String?

    public init(
        grantID: String = UUID().uuidString,
        principalKind: PrincipalKind,
        principalID: String,
        capabilityKind: String,
        resourcePattern: String,
        scope: String = "*",
        issuedBy: String = "system",
        issuedAt: Date = Date(),
        expiresAt: Date? = nil,
        state: CapabilityGrantState = .active,
        revokedAt: Date? = nil,
        revokeReason: String? = nil
    ) {
        self.grantID = grantID
        self.principalKind = principalKind
        self.principalID = principalID
        self.capabilityKind = capabilityKind
        self.resourcePattern = resourcePattern
        self.scope = scope
        self.issuedBy = issuedBy
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.state = state
        self.revokedAt = revokedAt
        self.revokeReason = revokeReason
    }
}

public struct CapabilityAuditEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64? { auditID }
    public let auditID: Int64?
    public let timestamp: Date
    public let grantID: String?
    public let principalKind: PrincipalKind
    public let principalID: String
    public let taskID: String?
    public let sessionID: String?
    public let runID: String?
    public let capabilityKind: String
    public let resource: String
    public let outcome: String // "granted", "denied", "revoked", "used"
    public let decisionReason: String?
    public let credentialHandedOver: Int // Hard invariant: must remain 0

    public init(
        auditID: Int64? = nil,
        timestamp: Date = Date(),
        grantID: String? = nil,
        principalKind: PrincipalKind,
        principalID: String,
        taskID: String? = nil,
        sessionID: String? = nil,
        runID: String? = nil,
        capabilityKind: String,
        resource: String,
        outcome: String,
        decisionReason: String? = nil,
        credentialHandedOver: Int = 0
    ) {
        self.auditID = auditID
        self.timestamp = timestamp
        self.grantID = grantID
        self.principalKind = principalKind
        self.principalID = principalID
        self.taskID = taskID
        self.sessionID = sessionID
        self.runID = runID
        self.capabilityKind = capabilityKind
        self.resource = resource
        self.outcome = outcome
        self.decisionReason = decisionReason
        self.credentialHandedOver = credentialHandedOver
    }
}

public struct GrantCapabilityRequest: Codable, Sendable, Equatable {
    public let principalKind: PrincipalKind
    public let principalID: String
    public let capabilityKind: String
    public let resourcePattern: String
    public let scope: String
    public let expiresAt: Date?

    public init(
        principalKind: PrincipalKind,
        principalID: String,
        capabilityKind: String,
        resourcePattern: String,
        scope: String = "*",
        expiresAt: Date? = nil
    ) {
        self.principalKind = principalKind
        self.principalID = principalID
        self.capabilityKind = capabilityKind
        self.resourcePattern = resourcePattern
        self.scope = scope
        self.expiresAt = expiresAt
    }
}

public struct RevokeCapabilityRequest: Codable, Sendable, Equatable {
    public let grantID: String
    public let reason: String

    public init(grantID: String, reason: String) {
        self.grantID = grantID
        self.reason = reason
    }
}

public struct ListCapabilityGrantsRequest: Codable, Sendable, Equatable {
    public let principalKind: PrincipalKind?
    public let principalID: String?
    public let activeOnly: Bool

    public init(principalKind: PrincipalKind? = nil, principalID: String? = nil, activeOnly: Bool = true) {
        self.principalKind = principalKind
        self.principalID = principalID
        self.activeOnly = activeOnly
    }
}

public struct QueryCapabilityAuditRequest: Codable, Sendable, Equatable {
    public let principalKind: PrincipalKind?
    public let principalID: String?
    public let taskID: String?
    public let sessionID: String?
    public let limit: Int

    public init(
        principalKind: PrincipalKind? = nil,
        principalID: String? = nil,
        taskID: String? = nil,
        sessionID: String? = nil,
        limit: Int = 100
    ) {
        self.principalKind = principalKind
        self.principalID = principalID
        self.taskID = taskID
        self.sessionID = sessionID
        self.limit = limit
    }
}
