import Foundation

public enum GrantDecision: Sendable, Equatable {
    case allowed(grantID: String)
    case denied(reason: String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

/// Pure evaluation function without any I/O side-effects.
/// Fully testable via table-driven ContractTests.
public enum GrantPolicy {

    /// Evaluates if a given principal has authorization for a specific capability kind and resource pattern.
    public static func evaluate(
        principal: CapabilityPrincipal,
        capability: String,
        resource: String,
        activeGrants: [CapabilityGrant],
        context: [String: String] = [:]
    ) -> GrantDecision {
        let matchingGrants = activeGrants.filter { grant in
            guard grant.state == .active else { return false }
            if let exp = grant.expiresAt, exp < Date() { return false }
            guard grant.principalKind == principal.kind && grant.principalID == principal.id else { return false }
            guard matchesCapability(grant: grant.capabilityKind, requested: capability) else { return false }
            guard matchesPattern(pattern: grant.resourcePattern, target: resource) else { return false }
            return true
        }

        if let first = matchingGrants.first {
            return .allowed(grantID: first.grantID)
        }

        return .denied(reason: "No active grant matches principal=\(principal.kind.rawValue):\(principal.id), capability=\(capability), resource=\(resource)")
    }

    /// Evaluates monotonic narrowing for SubAgents: `child ⊆ parent`.
    /// The child grant MUST NOT grant any capability or resource not granted to the parent.
    public static func isMonotonicNarrowing(
        parentGrants: [CapabilityGrant],
        childGrant: CapabilityGrant
    ) -> Bool {
        let activeParents = parentGrants.filter { grant in
            guard grant.state == .active else { return false }
            if let exp = grant.expiresAt, exp < Date() { return false }
            return true
        }

        for parent in activeParents {
            let capabilitySubsumed = matchesCapability(grant: parent.capabilityKind, requested: childGrant.capabilityKind)
            let resourceSubsumed = isPatternSubsumed(parentPattern: parent.resourcePattern, childPattern: childGrant.resourcePattern)

            if capabilitySubsumed && resourceSubsumed {
                return true
            }
        }

        return false
    }

    // MARK: - Pattern Matching Helpers

    public static func matchesCapability(grant: String, requested: String) -> Bool {
        if grant == "*" || grant == requested { return true }
        if grant.hasSuffix(".*") {
            let prefix = String(grant.dropLast(2))
            return requested == prefix || requested.hasPrefix(prefix + ".")
        }
        return false
    }

    public static func matchesPattern(pattern: String, target: String) -> Bool {
        if pattern == "*" || pattern == target { return true }
        if pattern.hasSuffix("/*") {
            let prefix = String(pattern.dropLast(2))
            return target == prefix || target.hasPrefix(prefix + "/")
        }
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast(1))
            return target.hasPrefix(prefix)
        }
        return false
    }

    public static func isPatternSubsumed(parentPattern: String, childPattern: String) -> Bool {
        if parentPattern == "*" { return true }
        if childPattern == "*" { return parentPattern == "*" }
        if parentPattern == childPattern { return true }

        if parentPattern.hasSuffix("/*") {
            let parentPrefix = String(parentPattern.dropLast(2))
            if childPattern.hasPrefix(parentPrefix + "/") || childPattern == parentPrefix {
                return true
            }
        }
        return false
    }
}
