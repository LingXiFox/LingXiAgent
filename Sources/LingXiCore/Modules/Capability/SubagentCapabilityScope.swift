import Foundation
import LingXiProtocol

/// Enforces monotonic narrowing for SubAgents: child capabilities must be a subset of parent capabilities (`child ⊆ parent`).
public struct SubagentCapabilityScope: Sendable {
    public let parentRunID: AgentRunID
    public let allowedTools: Set<String>?
    public let allowedPermissions: Set<String>?

    public init(
        parentRunID: AgentRunID,
        allowedTools: Set<String>? = nil,
        allowedPermissions: Set<String>? = nil
    ) {
        self.parentRunID = parentRunID
        self.allowedTools = allowedTools
        self.allowedPermissions = allowedPermissions
    }

    /// Validates that requested child tools and permissions do not exceed the parent's capability scope.
    public func validateChildScope(requestedTools: [String]?, requestedPermission: String?) throws {
        if let allowed = allowedTools, let requested = requestedTools {
            let forbidden = Set(requested).subtracting(allowed)
            if !forbidden.isEmpty {
                throw CoreError(
                    code: .permissionDenied,
                    message: "Subagent capability monotonic narrowing violation: requested tools \(forbidden.sorted()) exceed parent capability scope"
                )
            }
        }
        if let allowedPerms = allowedPermissions, let requestedPerm = requestedPermission {
            if !allowedPerms.contains(requestedPerm) {
                throw CoreError(
                    code: .permissionDenied,
                    message: "Subagent capability monotonic narrowing violation: requested permission '\(requestedPerm)' exceeds parent capability scope"
                )
            }
        }
    }
}
