import Foundation
import Testing
@testable import LingXiCore
import LingXiProtocol
import LingXiPlatform

@Suite("CapabilityGateway and CredentialBroker White-Box Tests")
struct CapabilityGatewayWhiteBoxTests {

    @Test("IssuedToken issues and verifies gateway token with HMAC verification")
    func issuedTokenLifecycle() throws {
        let principal = CapabilityPrincipal(kind: .mcpServer, id: "server-git")
        let payload = GatewayTokenPayload(
            tokenID: "tok-1",
            principal: principal,
            grantIDs: ["g-1", "g-2"],
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600)
        )

        let token = try IssuedToken.issue(payload: payload)
        #expect(token.hasPrefix("lxgt."))

        // Verify valid token
        let verified = IssuedToken.verify(token)
        #expect(verified != nil)
        #expect(verified?.principal.id == "server-git")
        #expect(verified?.grantIDs == ["g-1", "g-2"])

        // Tampered signature must fail
        let tampered = token + "corrupt"
        #expect(IssuedToken.verify(tampered) == nil)

        // Expired token must fail
        let expiredPayload = GatewayTokenPayload(
            tokenID: "tok-expired",
            principal: principal,
            grantIDs: ["g-1"],
            issuedAt: Date().addingTimeInterval(-7200),
            expiresAt: Date().addingTimeInterval(-3600)
        )
        let expiredToken = try IssuedToken.issue(payload: expiredPayload)
        #expect(IssuedToken.verify(expiredToken) == nil)
    }

    @Test("CredentialBroker scopes access and never leaks secrets")
    func credentialBrokerScoping() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try FileCredentialStore(dataRoot: tempDir, passphrase: "test-passphrase", iterations: 100_000)
        let broker = CredentialBroker(credentialStore: store)

        let ref = CredentialRef("test-provider-key")
        try await broker.storeSecret("sk-live-secret-payload-12345", for: ref)

        let exists = await broker.hasSecret(for: ref)
        #expect(exists)

        // Borrow secret through scoped closure
        let readSecret = try await broker.withProviderCredential(for: RunID("run-1"), reference: ref) { secret in
            #expect(secret == "sk-live-secret-payload-12345")
            return "ok"
        }
        #expect(readSecret == "ok")

        // Non-existent credential throws resourceNotFound
        let missingRef = CredentialRef("nonexistent-key")
        await #expect(throws: CoreError.self) {
            try await broker.withProviderCredential(for: RunID("run-1"), reference: missingRef) { _ in }
        }
    }

    @Test("CapabilityGateway end-to-end grant, revoke, evaluate, and audit logging")
    func capabilityGatewayLifecycle() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try FileCredentialStore(dataRoot: tempDir, passphrase: "test-passphrase", iterations: 100_000)
        let broker = CredentialBroker(credentialStore: store)
        let auditLog = CapabilityAuditLog()
        let gateway = CapabilityGateway(broker: broker, auditLog: auditLog)

        let principal = CapabilityPrincipal(kind: .session, id: "session-alpha")

        // 1. Issue grant
        let grant = try await gateway.grant(
            principalKind: .session,
            principalID: "session-alpha",
            capabilityKind: "tool.fileWrite",
            resourcePattern: "/workspace/*",
            scope: "readwrite",
            issuedBy: "admin"
        )
        #expect(grant.state == .active)

        // 2. Evaluate allowed
        let d1 = await gateway.evaluate(principal: principal, capability: "tool.fileWrite", resource: "/workspace/doc.md")
        #expect(d1 == .allowed(grantID: grant.grantID))

        // 3. Evaluate denied for different capability
        let d2 = await gateway.evaluate(principal: principal, capability: "tool.shell", resource: "/bin/sh")
        #expect(!d2.isAllowed)

        // 4. Revoke grant
        let revoked = try await gateway.revoke(grantID: grant.grantID, reason: "Security policy rotation")
        #expect(revoked.state == .revoked)

        // 5. Evaluate after revocation -> denied
        let d3 = await gateway.evaluate(principal: principal, capability: "tool.fileWrite", resource: "/workspace/doc.md")
        #expect(!d3.isAllowed)

        // 6. Audit summary: verify invariant credential_handed_over == 0
        let (totalAudits, handedOver) = await gateway.auditSummary()
        #expect(totalAudits >= 4)
        #expect(handedOver == 0)
    }
}
