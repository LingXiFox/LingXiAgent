import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import LingXiProtocol

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 独立运行轨迹存储 (TraceStore)
/// 专用于管理 traces.sqlite，与 catalog.sqlite 解耦，保障轨迹分析与回溯性能。
public actor TraceStore {
    public static let schemaVersion = 1

    private nonisolated(unsafe) let db: OpaquePointer
    public let databaseURL: URL

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        let dir = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard status == SQLITE_OK, let dbHandle = handle else {
            let msg = handle != nil ? String(cString: sqlite3_errmsg(handle)) : "sqlite open failed"
            if let handle { sqlite3_close(handle) }
            throw CoreError(code: .persistence, message: "Failed to open traces db: \(msg)")
        }
        self.db = dbHandle

        try Self.configure(dbHandle)
        try Self.initSchema(dbHandle)
    }

    deinit {
        sqlite3_close(db)
    }

    private static func configure(_ db: OpaquePointer) throws {
        _ = sqlite3_busy_timeout(db, 5000)
        try execute(db, "PRAGMA journal_mode = WAL")
        try execute(db, "PRAGMA synchronous = NORMAL")
    }

    private static func initSchema(_ db: OpaquePointer) throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS trace_events (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            trace_id TEXT NOT NULL,
            ts_us INTEGER NOT NULL,
            kind TEXT NOT NULL,
            event TEXT NOT NULL,
            schema_version INTEGER NOT NULL DEFAULT 1,
            session_id TEXT,
            run_id TEXT,
            root_run_id TEXT,
            parent_run_id TEXT,
            task_id TEXT,
            workflow_task_id TEXT,
            workflow_id TEXT,
            tool_call_id TEXT,
            execution_id TEXT,
            provider_request_id TEXT,
            span_id TEXT,
            parent_span_id TEXT,
            duration_us INTEGER,
            error_code TEXT,
            tokens_in INTEGER,
            tokens_out INTEGER,
            tokens_cache_read INTEGER,
            attributes_json TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_trace_events_task ON trace_events(task_id, ts_us);
        CREATE INDEX IF NOT EXISTS idx_trace_events_session ON trace_events(session_id, ts_us);
        CREATE INDEX IF NOT EXISTS idx_trace_events_kind ON trace_events(kind, ts_us);
        CREATE INDEX IF NOT EXISTS idx_trace_events_error ON trace_events(error_code) WHERE error_code IS NOT NULL;

        PRAGMA user_version = 1;
        """
        try execute(db, sql)
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err != nil ? String(cString: err!) : "sqlite execute error"
            sqlite3_free(err)
            throw CoreError(code: .persistence, message: msg)
        }
    }

    public func insert(event: RuntimeTraceEvent) throws {
        let sql = """
        INSERT INTO trace_events (
            trace_id, ts_us, kind, event, schema_version,
            session_id, run_id, root_run_id, parent_run_id,
            task_id, workflow_task_id, workflow_id, tool_call_id,
            execution_id, provider_request_id, span_id, parent_span_id,
            duration_us, error_code, tokens_in, tokens_out, tokens_cache_read,
            attributes_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw CoreError(code: .persistence, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let tsUs = Int64(event.timestamp.timeIntervalSince1970 * 1_000_000)
        let attrData = event.attributes != nil ? try? JSONEncoder().encode(event.attributes!) : nil
        let attrJson = attrData != nil ? String(data: attrData!, encoding: .utf8) : nil

        sqlite3_bind_text(stmt, 1, event.traceID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, tsUs)
        sqlite3_bind_text(stmt, 3, event.kind.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, event.event, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 5, Int32(event.traceSchemaVersion))

        bindText(stmt, 6, event.sessionID?.rawValue)
        bindText(stmt, 7, event.runID?.rawValue)
        bindText(stmt, 8, event.rootRunID?.rawValue)
        bindText(stmt, 9, event.parentRunID?.rawValue)
        bindText(stmt, 10, event.taskID?.rawValue)
        bindText(stmt, 11, event.workflowTaskID?.rawValue)
        bindText(stmt, 12, event.workflowID?.rawValue)
        bindText(stmt, 13, event.toolCallID?.rawValue)
        bindText(stmt, 14, event.executionID)
        bindText(stmt, 15, event.providerRequestID)
        bindText(stmt, 16, event.spanID)
        bindText(stmt, 17, event.parentSpanID)

        if let dur = event.durationMicroseconds {
            sqlite3_bind_int64(stmt, 18, dur)
        } else {
            sqlite3_bind_null(stmt, 18)
        }

        bindText(stmt, 19, event.errorCode)

        if let inTok = event.tokens?.inputTokens {
            sqlite3_bind_int(stmt, 20, Int32(inTok))
        } else {
            sqlite3_bind_null(stmt, 20)
        }

        if let outTok = event.tokens?.outputTokens {
            sqlite3_bind_int(stmt, 21, Int32(outTok))
        } else {
            sqlite3_bind_null(stmt, 21)
        }

        if let crTok = event.tokens?.cacheReadTokens {
            sqlite3_bind_int(stmt, 22, Int32(crTok))
        } else {
            sqlite3_bind_null(stmt, 22)
        }

        bindText(stmt, 23, attrJson)

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw CoreError(code: .persistence, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    public func query(request: TraceQueryRequest) throws -> [RuntimeTraceEvent] {
        var clauses: [String] = []
        var bindings: [(Int32, Any)] = []
        var bindIndex: Int32 = 1

        if let taskID = request.taskID {
            clauses.append("task_id = ?")
            bindings.append((bindIndex, taskID.rawValue))
            bindIndex += 1
        }
        if let sessionID = request.sessionID {
            clauses.append("session_id = ?")
            bindings.append((bindIndex, sessionID.rawValue))
            bindIndex += 1
        }
        if let kind = request.kind {
            clauses.append("kind = ?")
            bindings.append((bindIndex, kind.rawValue))
            bindIndex += 1
        }
        if let from = request.fromTimestamp {
            clauses.append("ts_us >= ?")
            bindings.append((bindIndex, Int64(from.timeIntervalSince1970 * 1_000_000)))
            bindIndex += 1
        }
        if let to = request.toTimestamp {
            clauses.append("ts_us <= ?")
            bindings.append((bindIndex, Int64(to.timeIntervalSince1970 * 1_000_000)))
            bindIndex += 1
        }

        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let limitVal = request.limit ?? 100
        let sql = "SELECT * FROM trace_events \(whereClause) ORDER BY ts_us ASC, seq ASC LIMIT \(limitVal);"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw CoreError(code: .persistence, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for (idx, val) in bindings {
            if let s = val as? String {
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            } else if let i = val as? Int64 {
                sqlite3_bind_int64(stmt, idx, i)
            }
        }

        var results: [RuntimeTraceEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let evt = decodeRow(stmt) {
                results.append(evt)
            }
        }
        return results
    }

    public func tail(limit: Int = 100) throws -> [RuntimeTraceEvent] {
        let sql = "SELECT * FROM (SELECT * FROM trace_events ORDER BY seq DESC LIMIT \(limit)) ORDER BY seq ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw CoreError(code: .persistence, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var results: [RuntimeTraceEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let evt = decodeRow(stmt) {
                results.append(evt)
            }
        }
        return results
    }

    public func prune(retentionDays: Int = 7, maxRows: Int = 200_000) throws -> Int {
        let cutoffUs = Int64(Date.now.addingTimeInterval(Double(-retentionDays * 86400)).timeIntervalSince1970 * 1_000_000)
        let deleteOldSql = "DELETE FROM trace_events WHERE ts_us < \(cutoffUs);"
        try Self.execute(db, deleteOldSql)

        // Check total rows and trim excess if needed
        let countSql = "SELECT COUNT(*) FROM trace_events;"
        var stmt: OpaquePointer?
        var totalRows = 0
        if sqlite3_prepare_v2(db, countSql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            if sqlite3_step(stmt) == SQLITE_ROW {
                totalRows = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }

        if totalRows > maxRows {
            let excess = totalRows - maxRows
            let trimSql = "DELETE FROM trace_events WHERE seq IN (SELECT seq FROM trace_events ORDER BY seq ASC LIMIT \(excess));"
            try Self.execute(db, trimSql)
            return excess
        }
        return 0
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let val = value {
            sqlite3_bind_text(stmt, index, val, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func decodeRow(_ stmt: OpaquePointer) -> RuntimeTraceEvent? {
        guard let traceIdPtr = sqlite3_column_text(stmt, 1),
              let kindPtr = sqlite3_column_text(stmt, 3),
              let eventPtr = sqlite3_column_text(stmt, 4) else { return nil }

        let traceID = String(cString: traceIdPtr)
        let tsUs = sqlite3_column_int64(stmt, 2)
        let timestamp = Date(timeIntervalSince1970: Double(tsUs) / 1_000_000.0)
        let kindStr = String(cString: kindPtr)
        let kind = RuntimeTraceKind(rawValue: kindStr) ?? .unknown
        let event = String(cString: eventPtr)
        let schemaVer = Int(sqlite3_column_int(stmt, 5))

        let sessionID = getText(stmt, 6).map { SessionID($0) }
        let runID = getText(stmt, 7).map { AgentRunID($0) }
        let rootRunID = getText(stmt, 8).map { AgentRunID($0) }
        let parentRunID = getText(stmt, 9).map { AgentRunID($0) }
        let taskID = getText(stmt, 10).map { TaskID($0) }
        let wfTaskID = getText(stmt, 11).map { WorkflowTaskID($0) }
        let wfID = getText(stmt, 12).map { WorkflowID($0) }
        let toolCallID = getText(stmt, 13).map { ToolCallID($0) }
        let executionID = getText(stmt, 14)
        let provReqID = getText(stmt, 15)
        let spanID = getText(stmt, 16)
        let parentSpanID = getText(stmt, 17)

        let durationUs = sqlite3_column_type(stmt, 18) != SQLITE_NULL ? sqlite3_column_int64(stmt, 18) : nil
        let errorCode = getText(stmt, 19)

        let inTok = sqlite3_column_type(stmt, 20) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 20)) : nil
        let outTok = sqlite3_column_type(stmt, 21) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 21)) : nil
        let crTok = sqlite3_column_type(stmt, 22) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 22)) : nil
        let tokens: TraceTokenUsage? = (inTok != nil || outTok != nil || crTok != nil)
            ? TraceTokenUsage(inputTokens: inTok, outputTokens: outTok, cacheReadTokens: crTok)
            : nil

        var attributes: [String: TraceAttributeValue]? = nil
        if let attrJson = getText(stmt, 23), let data = attrJson.data(using: .utf8) {
            attributes = try? JSONDecoder().decode([String: TraceAttributeValue].self, from: data)
        }

        return RuntimeTraceEvent(
            traceID: traceID,
            timestamp: timestamp,
            kind: kind,
            event: event,
            sessionID: sessionID,
            runID: runID,
            rootRunID: rootRunID,
            parentRunID: parentRunID,
            workflowID: wfID,
            workflowTaskID: wfTaskID,
            taskID: taskID,
            traceSchemaVersion: schemaVer,
            spanID: spanID,
            parentSpanID: parentSpanID,
            durationMicroseconds: durationUs,
            tokens: tokens,
            attributes: attributes,
            executionID: executionID,
            providerRequestID: provReqID,
            toolCallID: toolCallID,
            metadata: [:],
            errorCode: errorCode
        )
    }

    private func getText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }
}
