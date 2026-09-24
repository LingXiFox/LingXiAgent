import Foundation
import LingXiProtocol
import CSQLite

/// Central actor governing security principals, capability grants, audit logging,
/// and scoped access to privileged operations and provider credentials.
public actor CapabilityGateway {
    private var grants: [String: CapabilityGrant] = [:]
    private let auditLog: CapabilityAuditLog
    private let broker: CredentialBroker
    private let dbPath: URL?

    public init(
        broker: CredentialBroker,
        auditLog: CapabilityAuditLog = CapabilityAuditLog(),
        dbPath: URL? = nil
    ) {
        self.broker = broker
        self.auditLog = auditLog
        self.dbPath = dbPath
        if let dbPath {
            self.grants = Self.loadGrantsFromDB(at: dbPath)
        } else {
            self.grants = [:]
        }
    }

    // MARK: - Grant Management

    /// Issues a new capability grant from a request.
    @discardableResult
    public func grant(request: GrantCapabilityRequest, parentPrincipal: CapabilityPrincipal? = nil) async throws -> CapabilityGrant {
        try await grant(
            principalKind: request.principalKind,
            principalID: request.principalID,
            capabilityKind: request.capabilityKind,
            resourcePattern: request.resourcePattern,
            scope: request.scope,
            expiresAt: request.expiresAt,
            parentPrincipal: parentPrincipal
        )
    }

    /// Issues a new capability grant for a specified principal.
    @discardableResult
    public func grant(
        principalKind: PrincipalKind,
        principalID: String,
        capabilityKind: String,
        resourcePattern: String,
        scope: String = "*",
        issuedBy: String = "system",
        expiresAt: Date? = nil,
        parentPrincipal: CapabilityPrincipal? = nil
    ) async throws -> CapabilityGrant {
        let newGrant = CapabilityGrant(
            principalKind: principalKind,
            principalID: principalID,
            capabilityKind: capabilityKind,
            resourcePattern: resourcePattern,
            scope: scope,
            issuedBy: issuedBy,
            issuedAt: Date(),
            expiresAt: expiresAt,
            state: .active
        )

        // If parentPrincipal is specified (e.g. SubAgent), verify monotonic narrowing: child ⊆ parent
        if let parent = parentPrincipal {
            let parentGrants = grants.values.filter {
                $0.principalKind == parent.kind && $0.principalID == parent.id && $0.state == .active
            }
            guard GrantPolicy.isMonotonicNarrowing(parentGrants: Array(parentGrants), childGrant: newGrant) else {
                await auditLog.record(
                    grantID: newGrant.grantID,
                    principalKind: principalKind,
                    principalID: principalID,
                    capabilityKind: capabilityKind,
                    resource: resourcePattern,
                    outcome: "denied",
                    decisionReason: "Subagent grant violates monotonic narrowing: child grant exceeds parent capability scope"
                )
                throw CoreError(code: .permissionDenied, message: "Subagent grant violates monotonic narrowing: child ⊆ parent constraint violated")
            }
        }

        grants[newGrant.grantID] = newGrant
        if let dbPath {
            persistGrant(newGrant, at: dbPath)
        }

        await auditLog.record(
            grantID: newGrant.grantID,
            principalKind: principalKind,
            principalID: principalID,
            capabilityKind: capabilityKind,
            resource: resourcePattern,
            outcome: "granted",
            decisionReason: "Issued by \(issuedBy)"
        )

        return newGrant
    }

    /// Revokes an existing grant via request object.
    @discardableResult
    public func revoke(request: RevokeCapabilityRequest) async throws -> CapabilityGrant {
        try await revoke(grantID: request.grantID, reason: request.reason)
    }

    /// Revokes an existing grant.
    @discardableResult
    public func revoke(grantID: String, reason: String) async throws -> CapabilityGrant {
        guard var grant = grants[grantID] else {
            throw CoreError(code: .resourceNotFound, message: "Capability grant \(grantID) not found")
        }

        grant = CapabilityGrant(
            grantID: grant.grantID,
            principalKind: grant.principalKind,
            principalID: grant.principalID,
            capabilityKind: grant.capabilityKind,
            resourcePattern: grant.resourcePattern,
            scope: grant.scope,
            issuedBy: grant.issuedBy,
            issuedAt: grant.issuedAt,
            expiresAt: grant.expiresAt,
            state: .revoked,
            revokedAt: Date(),
            revokeReason: reason
        )
        grants[grantID] = grant

        if let dbPath {
            persistGrant(grant, at: dbPath)
        }

        await auditLog.record(
            grantID: grant.grantID,
            principalKind: grant.principalKind,
            principalID: grant.principalID,
            capabilityKind: grant.capabilityKind,
            resource: grant.resourcePattern,
            outcome: "revoked",
            decisionReason: reason
        )

        return grant
    }

    /// Lists active and optionally historical grants matching the request criteria.
    public func listGrants(request: ListCapabilityGrantsRequest) -> [CapabilityGrant] {
        listGrants(
            principalKind: request.principalKind,
            principalID: request.principalID,
            activeOnly: request.activeOnly
        )
    }

    /// Lists active and optionally historical grants matching the criteria.
    public func listGrants(
        principalKind: PrincipalKind? = nil,
        principalID: String? = nil,
        activeOnly: Bool = true
    ) -> [CapabilityGrant] {
        var result = Array(grants.values)
        if activeOnly {
            result = result.filter { $0.state == .active && ($0.expiresAt == nil || $0.expiresAt! > Date()) }
        }
        if let kind = principalKind {
            result = result.filter { $0.principalKind == kind }
        }
        if let pid = principalID {
            result = result.filter { $0.principalID == pid }
        }
        return result
    }

    // MARK: - Evaluation

    /// Evaluates if a principal is authorized to perform an action on a resource.
    public func evaluate(
        principal: CapabilityPrincipal,
        capability: String,
        resource: String,
        taskID: String? = nil,
        sessionID: String? = nil,
        runID: String? = nil
    ) async -> GrantDecision {
        let activeGrants = grants.values.filter {
            $0.principalKind == principal.kind &&
            $0.principalID == principal.id &&
            $0.state == .active &&
            ($0.expiresAt == nil || $0.expiresAt! > Date())
        }

        let decision = GrantPolicy.evaluate(
            principal: principal,
            capability: capability,
            resource: resource,
            activeGrants: Array(activeGrants)
        )

        switch decision {
        case let .allowed(grantID):
            await auditLog.record(
                grantID: grantID,
                principalKind: principal.kind,
                principalID: principal.id,
                taskID: taskID,
                sessionID: sessionID,
                runID: runID,
                capabilityKind: capability,
                resource: resource,
                outcome: "used",
                decisionReason: "Authorized by grant \(grantID)"
            )
        case let .denied(reason):
            await auditLog.record(
                grantID: nil,
                principalKind: principal.kind,
                principalID: principal.id,
                taskID: taskID,
                sessionID: sessionID,
                runID: runID,
                capabilityKind: capability,
                resource: resource,
                outcome: "denied",
                decisionReason: reason
            )
        }

        return decision
    }

    // MARK: - Token Issuance for Child Processes

    /// Issues a verifiable `LINGXI_GATEWAY_TOKEN` for child processes (e.g. MCP stdio transport, plugins).
    public func issueGatewayToken(for principal: CapabilityPrincipal) throws -> String {
        let activeGrants = grants.values.filter {
            $0.principalKind == principal.kind && $0.principalID == principal.id && $0.state == .active
        }
        let grantIDs = activeGrants.map(\.grantID)

        let payload = GatewayTokenPayload(
            principal: principal,
            grantIDs: grantIDs,
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(86400 * 7) // 7 days token validity
        )
        return try IssuedToken.issue(payload: payload)
    }

    /// Verifies and evaluates a gateway token presented by a child process.
    public func verifyGatewayToken(_ token: String) -> GatewayTokenPayload? {
        IssuedToken.verify(token)
    }

    // MARK: - Auditing

    public func queryAudit(request: QueryCapabilityAuditRequest) async -> [CapabilityAuditEntry] {
        await auditLog.query(request: request)
    }

    public func auditSummary() async -> (totalAudits: Int, credentialsHandedOver: Int) {
        let entries = await auditLog.query(request: QueryCapabilityAuditRequest(limit: 10000))
        let handedOver = await auditLog.totalCredentialsHandedOver()
        return (entries.count, handedOver)
    }

    // MARK: - Database Persistence Helpers

    private func persistGrant(_ grant: CapabilityGrant, at url: URL) {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO capability_grants (
            grant_id, principal_kind, principal_id, capability_kind, resource_pattern,
            scope, issued_by, issued_at, expires_at, state, revoked_at, revoke_reason
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(grant_id) DO UPDATE SET
            state = excluded.state,
            revoked_at = excluded.revoked_at,
            revoke_reason = excluded.revoke_reason;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            let df = ISO8601DateFormatter()
            sqlite3_bind_text(stmt, 1, grant.grantID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, grant.principalKind.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, grant.principalID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, grant.capabilityKind, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, grant.resourcePattern, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, grant.scope, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, grant.issuedBy, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, df.string(from: grant.issuedAt), -1, SQLITE_TRANSIENT)
            if let exp = grant.expiresAt { sqlite3_bind_text(stmt, 9, df.string(from: exp), -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 9) }
            sqlite3_bind_text(stmt, 10, grant.state.rawValue, -1, SQLITE_TRANSIENT)
            if let rev = grant.revokedAt { sqlite3_bind_text(stmt, 11, df.string(from: rev), -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 11) }
            if let reason = grant.revokeReason { sqlite3_bind_text(stmt, 12, reason, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 12) }

            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    private static func loadGrantsFromDB(at url: URL) -> [String: CapabilityGrant] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [:] }
        defer { sqlite3_close(db) }

        var loadedGrants: [String: CapabilityGrant] = [:]
        let sql = "SELECT grant_id, principal_kind, principal_id, capability_kind, resource_pattern, scope, issued_by, issued_at, expires_at, state, revoked_at, revoke_reason FROM capability_grants;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            let df = ISO8601DateFormatter()
            while sqlite3_step(stmt) == SQLITE_ROW {
                let gid = String(cString: sqlite3_column_text(stmt, 0))
                let pkindStr = String(cString: sqlite3_column_text(stmt, 1))
                let pid = String(cString: sqlite3_column_text(stmt, 2))
                let ckind = String(cString: sqlite3_column_text(stmt, 3))
                let rpat = String(cString: sqlite3_column_text(stmt, 4))
                let scope = String(cString: sqlite3_column_text(stmt, 5))
                let issuedBy = String(cString: sqlite3_column_text(stmt, 6))
                let issuedAtStr = String(cString: sqlite3_column_text(stmt, 7))
                let expiresAtStr = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
                let stateStr = String(cString: sqlite3_column_text(stmt, 9))
                let revokedAtStr = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
                let revokeReason = sqlite3_column_text(stmt, 11).map { String(cString: $0) }

                guard let pkind = PrincipalKind(rawValue: pkindStr),
                      let state = CapabilityGrantState(rawValue: stateStr),
                      let issuedAt = df.date(from: issuedAtStr) else {
                    continue
                }

                let grant = CapabilityGrant(
                    grantID: gid,
                    principalKind: pkind,
                    principalID: pid,
                    capabilityKind: ckind,
                    resourcePattern: rpat,
                    scope: scope,
                    issuedBy: issuedBy,
                    issuedAt: issuedAt,
                    expiresAt: expiresAtStr.flatMap { df.date(from: $0) },
                    state: state,
                    revokedAt: revokedAtStr.flatMap { df.date(from: $0) },
                    revokeReason: revokeReason
                )
                loadedGrants[gid] = grant
            }
            sqlite3_finalize(stmt)
        }
        return loadedGrants
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
