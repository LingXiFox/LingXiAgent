import Foundation
import LingXiProtocol
import CSQLite

/// High-integrity audit logger for capability evaluations and access requests.
///
/// Invariant: `credential_handed_over` is permanently 0.
public actor CapabilityAuditLog {
    private let dbPath: URL?
    private var inMemoryLog: [CapabilityAuditEntry] = []

    public init(dbPath: URL? = nil) {
        self.dbPath = dbPath
    }

    /// Records an audit event for capability usage, evaluation, grant or revocation.
    public func record(
        grantID: String? = nil,
        principalKind: PrincipalKind,
        principalID: String,
        taskID: String? = nil,
        sessionID: String? = nil,
        runID: String? = nil,
        capabilityKind: String,
        resource: String,
        outcome: String,
        decisionReason: String? = nil
    ) {
        // Enforce hard architectural invariant
        let credentialHandedOver = 0

        let entry = CapabilityAuditEntry(
            auditID: Int64(inMemoryLog.count + 1),
            timestamp: Date(),
            grantID: grantID,
            principalKind: principalKind,
            principalID: principalID,
            taskID: taskID,
            sessionID: sessionID,
            runID: runID,
            capabilityKind: capabilityKind,
            resource: resource,
            outcome: outcome,
            decisionReason: decisionReason,
            credentialHandedOver: credentialHandedOver
        )
        inMemoryLog.append(entry)

        if let dbPath {
            persistToDB(entry: entry, at: dbPath)
        }
    }

    /// Queries audit entries according to filter parameters.
    public func query(request: QueryCapabilityAuditRequest) -> [CapabilityAuditEntry] {
        var filtered = inMemoryLog

        if let kind = request.principalKind {
            filtered = filtered.filter { $0.principalKind == kind }
        }
        if let pid = request.principalID {
            filtered = filtered.filter { $0.principalID == pid }
        }
        if let tid = request.taskID {
            filtered = filtered.filter { $0.taskID == tid }
        }
        if let sid = request.sessionID {
            filtered = filtered.filter { $0.sessionID == sid }
        }

        if filtered.count > request.limit {
            return Array(filtered.suffix(request.limit))
        }
        return filtered
    }

    /// Returns count of any credential ever handed over. Must always be 0.
    public func totalCredentialsHandedOver() -> Int {
        inMemoryLog.reduce(0) { $0 + $1.credentialHandedOver }
    }

    private func persistToDB(entry: CapabilityAuditEntry, at url: URL) {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO capability_audit (
            timestamp, grant_id, principal_kind, principal_id, task_id, session_id, run_id,
            capability_kind, resource, outcome, decision_reason, credential_handed_over
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0);
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            let df = ISO8601DateFormatter()
            let tsStr = df.string(from: entry.timestamp)
            sqlite3_bind_text(stmt, 1, tsStr, -1, SQLITE_TRANSIENT)
            if let gid = entry.grantID {
                sqlite3_bind_text(stmt, 2, gid, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_text(stmt, 3, entry.principalKind.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, entry.principalID, -1, SQLITE_TRANSIENT)
            if let tid = entry.taskID { sqlite3_bind_text(stmt, 5, tid, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 5) }
            if let sid = entry.sessionID { sqlite3_bind_text(stmt, 6, sid, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 6) }
            if let rid = entry.runID { sqlite3_bind_text(stmt, 7, rid, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 7) }
            sqlite3_bind_text(stmt, 8, entry.capabilityKind, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 9, entry.resource, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 10, entry.outcome, -1, SQLITE_TRANSIENT)
            if let reason = entry.decisionReason { sqlite3_bind_text(stmt, 11, reason, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 11) }

            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
