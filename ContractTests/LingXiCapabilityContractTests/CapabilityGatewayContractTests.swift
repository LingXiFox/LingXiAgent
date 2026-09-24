import Foundation
import Testing
import LingXiProtocol
import LingXiPlatform

struct CapabilityGatewayContractTests {

    @Test("table-driven GrantPolicy evaluation handles exact, wildcard, and prefix matching")
    func tableDrivenGrantPolicyEvaluation() {
        let principal = CapabilityPrincipal(kind: .session, id: "session-123")
        let otherPrincipal = CapabilityPrincipal(kind: .subagent, id: "subagent-456")

        let grants = [
            CapabilityGrant(
                grantID: "grant-exact",
                principalKind: .session,
                principalID: "session-123",
                capabilityKind: "tool.read",
                resourcePattern: "/workspace/file.txt",
                state: .active
            ),
            CapabilityGrant(
                grantID: "grant-wildcard",
                principalKind: .session,
                principalID: "session-123",
                capabilityKind: "tool.*",
                resourcePattern: "/workspace/src/*",
                state: .active
            ),
            CapabilityGrant(
                grantID: "grant-revoked",
                principalKind: .session,
                principalID: "session-123",
                capabilityKind: "tool.execute",
                resourcePattern: "*",
                state: .revoked
            ),
            CapabilityGrant(
                grantID: "grant-expired",
                principalKind: .session,
                principalID: "session-123",
                capabilityKind: "tool.network",
                resourcePattern: "*",
                expiresAt: Date().addingTimeInterval(-3600),
                state: .active
            )
        ]

        // 1. Exact match
        let d1 = GrantPolicy.evaluate(principal: principal, capability: "tool.read", resource: "/workspace/file.txt", activeGrants: grants)
        #expect(d1 == .allowed(grantID: "grant-exact"))

        // 2. Prefix wildcard match
        let d2 = GrantPolicy.evaluate(principal: principal, capability: "tool.write", resource: "/workspace/src/main.swift", activeGrants: grants)
        #expect(d2 == .allowed(grantID: "grant-wildcard"))

        // 3. Capability mismatch for path
        let d3 = GrantPolicy.evaluate(principal: principal, capability: "other.tool", resource: "/workspace/src/main.swift", activeGrants: grants)
        #expect(!d3.isAllowed)

        // 4. Resource mismatch for tool.read
        let d4 = GrantPolicy.evaluate(principal: principal, capability: "tool.read", resource: "/other/secret.txt", activeGrants: grants)
        #expect(!d4.isAllowed)

        // 5. Revoked grant rejected
        let d5 = GrantPolicy.evaluate(principal: principal, capability: "tool.execute", resource: "/any/path", activeGrants: grants)
        #expect(!d5.isAllowed)

        // 6. Expired grant rejected
        let d6 = GrantPolicy.evaluate(principal: principal, capability: "tool.network", resource: "https://example.com", activeGrants: grants)
        #expect(!d6.isAllowed)

        // 7. Wrong principal rejected
        let d7 = GrantPolicy.evaluate(principal: otherPrincipal, capability: "tool.read", resource: "/workspace/file.txt", activeGrants: grants)
        #expect(!d7.isAllowed)
    }

    @Test("Subagent monotonic narrowing enforces child ⊆ parent constraint")
    func subagentMonotonicNarrowing() {
        let parentGrants = [
            CapabilityGrant(
                grantID: "parent-grant-1",
                principalKind: .session,
                principalID: "parent-session",
                capabilityKind: "tool.*",
                resourcePattern: "/workspace/src/*",
                state: .active
            ),
            CapabilityGrant(
                grantID: "parent-grant-2",
                principalKind: .session,
                principalID: "parent-session",
                capabilityKind: "mcp.call",
                resourcePattern: "server-a/*",
                state: .active
            )
        ]

        // Case A: child requests subset of parent's tool and narrower resource pattern -> Valid
        let childValid = CapabilityGrant(
            grantID: "child-valid",
            principalKind: .subagent,
            principalID: "child-1",
            capabilityKind: "tool.read",
            resourcePattern: "/workspace/src/submodule/*",
            state: .active
        )
        #expect(GrantPolicy.isMonotonicNarrowing(parentGrants: parentGrants, childGrant: childValid))

        // Case B: child requests capability outside parent's allowed capabilities -> Violates narrowing
        let childExceedsCapability = CapabilityGrant(
            grantID: "child-bad-cap",
            principalKind: .subagent,
            principalID: "child-1",
            capabilityKind: "network.connect",
            resourcePattern: "/workspace/src/*",
            state: .active
        )
        #expect(!GrantPolicy.isMonotonicNarrowing(parentGrants: parentGrants, childGrant: childExceedsCapability))

        // Case C: child requests broader resource pattern than parent -> Violates narrowing
        let childExceedsResource = CapabilityGrant(
            grantID: "child-bad-res",
            principalKind: .subagent,
            principalID: "child-1",
            capabilityKind: "tool.read",
            resourcePattern: "*", // Parent only allows /workspace/src/*
            state: .active
        )
        #expect(!GrantPolicy.isMonotonicNarrowing(parentGrants: parentGrants, childGrant: childExceedsResource))
    }

    @Test("CapabilityAuditEntry hard invariant: credentialHandedOver remains 0")
    func credentialHandedOverInvariant() {
        let audit = CapabilityAuditEntry(
            principalKind: .subagent,
            principalID: "child-run-42",
            taskID: "task-001",
            sessionID: "session-root",
            runID: "run-99",
            capabilityKind: "tool.fileRead",
            resource: "/path/to/source.swift",
            outcome: "used",
            decisionReason: "Authorized via subagent grant"
        )
        #expect(audit.credentialHandedOver == 0)
    }
}
