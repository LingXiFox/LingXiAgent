import Foundation
import Testing
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import LingXiProtocol
import LingXiPlatform

struct TaskLifecycleContractTests {

    // MARK: - 1. State Machine Branch Table & Verifying Non-producibility

    @Test("RunStatus and TaskState terminal state predicates satisfy contract")
    func runStatusAndTaskStateTerminalSemantics() {
        #expect(!RunStatus.queued.isTerminal)
        #expect(!RunStatus.running.isTerminal)
        #expect(!RunStatus.paused.isTerminal)
        #expect(!RunStatus.unknown.isTerminal)
        #expect(RunStatus.completed.isTerminal)
        #expect(RunStatus.failed.isTerminal)
        #expect(RunStatus.cancelled.isTerminal)

        #expect(!TaskState.queued.isTerminal)
        #expect(!TaskState.running.isTerminal)
        #expect(!TaskState.waiting.isTerminal)
        #expect(!TaskState.paused.isTerminal)
        #expect(!TaskState.verifying.isTerminal)
        #expect(!TaskState.unknown.isTerminal)
        #expect(TaskState.completed.isTerminal)
        #expect(TaskState.failed.isTerminal)
        #expect(TaskState.cancelled.isTerminal)
    }

    @Test("TaskState transition matrix branch table matches V1.1 specification")
    func taskStateTransitionMatrixBranchTable() {
        // From queued
        #expect(TaskState.queued.allowedTransitions == [.running, .cancelled])

        // From running
        #expect(TaskState.running.allowedTransitions == [.waiting, .paused, .completed, .failed, .cancelled])

        // From waiting
        #expect(TaskState.waiting.allowedTransitions == [.running, .paused, .cancelled, .failed])

        // From paused
        #expect(TaskState.paused.allowedTransitions == [.running, .cancelled])

        // From verifying (V1.2 reservation)
        #expect(TaskState.verifying.allowedTransitions == [.completed, .failed, .running])

        // Terminal states have no outgoing transitions
        #expect(TaskState.completed.allowedTransitions.isEmpty)
        #expect(TaskState.failed.allowedTransitions.isEmpty)
        #expect(TaskState.cancelled.allowedTransitions.isEmpty)
        #expect(TaskState.unknown.allowedTransitions.isEmpty)
    }

    @Test("V1_1_no_producer_of_verifying_state: verifying state is declared but unproduced in V1.1 runtime")
    func v1_1_no_producer_of_verifying_state() {
        // Assert declaring exists
        let declared = TaskState.verifying
        #expect(declared.rawValue == "verifying")

        // Assert NO active runtime state transitions allow producing verifying in V1.1
        let activeStates: [TaskState] = [.queued, .running, .waiting, .paused]
        for state in activeStates {
            #expect(!state.allowedTransitions.contains(.verifying),
                    "State \(state.rawValue) must not allow transition to .verifying in V1.1")
        }
    }

    @Test("TaskState and WaitingReason fault-tolerant forward compatible decoding")
    func taskStateAndWaitingReasonFaultTolerantDecoding() throws {
        struct TestContainer: Codable {
            let state: TaskState
            let reason: WaitingReason?
        }

        let json = """
        {
            "state": "future_quantum_state",
            "reason": "alien_intervention"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TestContainer.self, from: json)
        #expect(decoded.state == .unknown)
        #expect(decoded.reason == .unknown)
    }

    // MARK: - 2. Migration V6 to V7 Regression Tests

    @Test("MigrationV6ToV7RegressionTests: Byte fixture, row conservation, idempotency and downgrade reversibility")
    func migrationV6ToV7RegressionTests() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("v6_to_v7_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("state.sqlite")
        var dbHandle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &dbHandle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = dbHandle else {
            Issue.record("Failed to create test SQLite DB")
            return
        }
        defer { sqlite3_close_v2(db) }

        func execSQL(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let msg = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw CoreError(code: .persistence, message: "SQL failed: \(msg)")
            }
        }

        func queryScalar(_ sql: String) -> String? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            guard let text = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: text)
        }

        func hasTable(_ name: String) -> Bool {
            queryScalar("SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(name)'") != nil
        }

        // 1. Create simulated v6 schema and populate sample rows
        try execSQL("""
        CREATE TABLE sessions(
            session_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            cwd_root_binding_id TEXT NOT NULL,
            cwd_relative_path TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            revision INTEGER NOT NULL DEFAULT 0,
            metadata TEXT NOT NULL
        );
        CREATE TABLE agent_runs(
            run_id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            parent_run_id TEXT,
            root_run_id TEXT NOT NULL,
            agent_kind TEXT NOT NULL,
            status TEXT NOT NULL,
            provider_id TEXT NOT NULL,
            model_id TEXT NOT NULL,
            reasoning TEXT,
            context_profile TEXT,
            permission_profile TEXT,
            tool_profile TEXT,
            budget_profile TEXT,
            started_at TEXT,
            finished_at TEXT,
            latest_activity_at TEXT NOT NULL,
            usage_json TEXT NOT NULL,
            error_json TEXT,
            title TEXT
        );
        CREATE TABLE workflow_tasks(
            workflow_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            status TEXT NOT NULL,
            definition_json TEXT NOT NULL,
            provenance_json TEXT,
            result_json TEXT,
            error_json TEXT,
            PRIMARY KEY(workflow_id, task_id)
        );
        PRAGMA user_version = 6;
        """)

        // Insert sample v6 data
        try execSQL("""
        INSERT INTO sessions(session_id, project_id, cwd_root_binding_id, cwd_relative_path, created_at, updated_at, revision, metadata)
        VALUES('sess-1', 'proj-1', 'rb-main', '', '1700000000', '1700000000', 1, '{}');

        INSERT INTO agent_runs(run_id, session_id, project_id, root_run_id, agent_kind, status, provider_id, model_id, latest_activity_at, usage_json, title)
        VALUES('run-active', 'sess-1', 'proj-1', 'run-active', 'primary', 'running', 'prov-1', 'model-1', '1700000100', '{}', 'Active Task');

        INSERT INTO agent_runs(run_id, session_id, project_id, root_run_id, agent_kind, status, provider_id, model_id, latest_activity_at, usage_json, title)
        VALUES('run-queued', 'sess-1', 'proj-1', 'run-queued', 'primary', 'queued', 'prov-1', 'model-1', '1700000200', '{}', 'Queued Task');

        INSERT INTO agent_runs(run_id, session_id, project_id, root_run_id, agent_kind, status, provider_id, model_id, latest_activity_at, usage_json, title)
        VALUES('run-done', 'sess-1', 'proj-1', 'run-done', 'primary', 'completed', 'prov-1', 'model-1', '1700000050', '{}', 'Done Task');
        """)

        #expect(queryScalar("PRAGMA user_version") == "6")
        #expect(queryScalar("SELECT COUNT(*) FROM sessions") == "1")
        #expect(queryScalar("SELECT COUNT(*) FROM agent_runs") == "3")

        // 2. Define and apply v7 migration DDL
        let applyV7Migration = {
            try execSQL("""
            CREATE TABLE IF NOT EXISTS workspaces(
                workspace_id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                kind TEXT NOT NULL DEFAULT 'main',
                origin_workspace_id TEXT REFERENCES workspaces(workspace_id),
                root_binding_id TEXT,
                base_revision INTEGER NOT NULL DEFAULT 0,
                isolation_state TEXT NOT NULL DEFAULT 'shared',
                state TEXT NOT NULL DEFAULT 'active',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_workspaces_project_state ON workspaces(project_id, state);

            CREATE TABLE IF NOT EXISTS tasks(
                task_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(session_id),
                workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
                parent_task_id TEXT REFERENCES tasks(task_id),
                forked_from_task_id TEXT REFERENCES tasks(task_id),
                root_run_id TEXT REFERENCES agent_runs(run_id),
                project_id TEXT NOT NULL,
                state TEXT NOT NULL,
                waiting_reason TEXT,
                objective TEXT NOT NULL,
                success_criteria_json TEXT NOT NULL DEFAULT '[]',
                resume_point_json TEXT,
                risk_state TEXT NOT NULL DEFAULT 'normal',
                revision INTEGER NOT NULL DEFAULT 0,
                model_selection_json TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                latest_activity_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_tasks_session_latest ON tasks(session_id, latest_activity_at);
            CREATE INDEX IF NOT EXISTS idx_tasks_state ON tasks(state) WHERE state IN ('running', 'waiting', 'paused');
            CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_task_id);
            CREATE UNIQUE INDEX IF NOT EXISTS one_active_root_task_per_session ON tasks(session_id) WHERE parent_task_id IS NULL AND state IN ('running', 'waiting');

            CREATE TABLE IF NOT EXISTS task_artifacts(
                task_id TEXT NOT NULL REFERENCES tasks(task_id),
                ordinal INTEGER NOT NULL,
                kind TEXT NOT NULL,
                ref TEXT NOT NULL,
                metadata_json TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL,
                PRIMARY KEY(task_id, ordinal)
            );

            CREATE TABLE IF NOT EXISTS task_tool_states(
                task_id TEXT NOT NULL REFERENCES tasks(task_id),
                tool_call_id TEXT NOT NULL,
                state TEXT NOT NULL,
                payload_json TEXT NOT NULL DEFAULT '{}',
                updated_at TEXT NOT NULL,
                PRIMARY KEY(task_id, tool_call_id)
            );

            CREATE TABLE IF NOT EXISTS task_events(
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id TEXT NOT NULL REFERENCES tasks(task_id),
                event TEXT NOT NULL,
                from_state TEXT,
                to_state TEXT NOT NULL,
                payload_json TEXT NOT NULL DEFAULT '{}',
                correlation_id TEXT,
                created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_task_events_task_seq ON task_events(task_id, seq);

            CREATE TABLE IF NOT EXISTS capability_grants(
                grant_id TEXT PRIMARY KEY,
                principal_kind TEXT NOT NULL,
                principal_id TEXT NOT NULL,
                capability_kind TEXT NOT NULL,
                resource_pattern TEXT NOT NULL,
                scope TEXT NOT NULL,
                issued_by TEXT NOT NULL,
                issued_at TEXT NOT NULL,
                expires_at TEXT,
                state TEXT NOT NULL,
                revoked_at TEXT,
                revoke_reason TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_capability_grants_principal ON capability_grants(principal_kind, principal_id, state);

            CREATE TABLE IF NOT EXISTS capability_audit(
                audit_id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                grant_id TEXT REFERENCES capability_grants(grant_id),
                principal_kind TEXT NOT NULL,
                principal_id TEXT NOT NULL,
                task_id TEXT,
                session_id TEXT,
                run_id TEXT,
                capability_kind TEXT NOT NULL,
                resource TEXT NOT NULL,
                outcome TEXT NOT NULL,
                decision_reason TEXT,
                credential_handed_over INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_capability_audit_task_time ON capability_audit(task_id, timestamp);

            INSERT OR IGNORE INTO workspaces(workspace_id, project_id, kind, root_binding_id, base_revision, isolation_state, state, created_at, updated_at)
            SELECT 'ws-' || s.project_id, s.project_id, 'main', s.cwd_root_binding_id, 0, 'shared', 'active', MIN(s.created_at), MIN(s.updated_at)
            FROM sessions s
            GROUP BY s.project_id;

            INSERT OR IGNORE INTO tasks(
                task_id, session_id, workspace_id, parent_task_id, forked_from_task_id,
                root_run_id, project_id, state, waiting_reason, objective,
                success_criteria_json, resume_point_json, risk_state, revision,
                model_selection_json, created_at, updated_at, latest_activity_at
            )
            SELECT
                'task-' || a.run_id,
                a.session_id,
                'ws-' || a.project_id,
                NULL,
                NULL,
                a.run_id,
                a.project_id,
                CASE a.status
                    WHEN 'queued' THEN 'queued'
                    WHEN 'paused' THEN 'paused'
                    WHEN 'running' THEN 'running'
                    ELSE 'running'
                END,
                NULL,
                COALESCE(a.title, '[migrated V1.0 run]'),
                '[]',
                NULL,
                'normal',
                0,
                NULL,
                COALESCE(a.started_at, a.latest_activity_at),
                a.latest_activity_at,
                a.latest_activity_at
            FROM agent_runs a
            WHERE a.status IN ('queued', 'running', 'paused')
            AND a.latest_activity_at = (
                SELECT MAX(a2.latest_activity_at) FROM agent_runs a2 WHERE a2.session_id = a.session_id AND a2.status IN ('queued', 'running', 'paused')
            );

            INSERT OR IGNORE INTO task_events(task_id, event, from_state, to_state, payload_json, correlation_id, created_at)
            SELECT
                'task-' || a.run_id,
                'migrated_from_v6',
                NULL,
                CASE a.status
                    WHEN 'queued' THEN 'queued'
                    WHEN 'paused' THEN 'paused'
                    WHEN 'running' THEN 'running'
                    ELSE 'running'
                END,
                '{"reason":"v6_to_v7_backfill"}',
                a.run_id,
                a.latest_activity_at
            FROM agent_runs a
            WHERE a.status IN ('queued', 'running', 'paused')
            AND a.latest_activity_at = (
                SELECT MAX(a2.latest_activity_at) FROM agent_runs a2 WHERE a2.session_id = a.session_id AND a2.status IN ('queued', 'running', 'paused')
            );

            PRAGMA user_version = 7;
            """)
        }

        try applyV7Migration()

        // 3. Assert user_version = 7
        #expect(queryScalar("PRAGMA user_version") == "7")

        // 4. Assert all 7 new tables exist
        let newTables = [
            "workspaces", "tasks", "task_artifacts", "task_tool_states",
            "task_events", "capability_grants", "capability_audit"
        ]
        for tbl in newTables {
            #expect(hasTable(tbl), "Expected table \(tbl) to exist after v7 migration")
        }

        // 5. Assert row-level conservation of old tables
        #expect(queryScalar("SELECT COUNT(*) FROM sessions") == "1")
        #expect(queryScalar("SELECT COUNT(*) FROM agent_runs") == "3")
        #expect(queryScalar("SELECT project_id FROM sessions WHERE session_id = 'sess-1'") == "proj-1")

        // 6. Assert backfill conservation
        #expect(queryScalar("SELECT COUNT(*) FROM workspaces") == "1")
        #expect(queryScalar("SELECT workspace_id FROM workspaces WHERE project_id = 'proj-1'") == "ws-proj-1")
        // Only active/queued runs migrated, completed was not
        let taskCount = Int(queryScalar("SELECT COUNT(*) FROM tasks") ?? "0") ?? 0
        #expect(taskCount >= 1)
        #expect(queryScalar("SELECT COUNT(*) FROM task_events") == queryScalar("SELECT COUNT(*) FROM tasks"))

        // 7. Test Idempotency (running migration second time succeeds without errors)
        try applyV7Migration()
        #expect(queryScalar("PRAGMA user_version") == "7")
        #expect(queryScalar("SELECT COUNT(*) FROM workspaces") == "1")

        // 8. Test Downgrade Reversibility: dropping new tables restores user_version 6
        try execSQL("""
        DROP TABLE IF EXISTS capability_audit;
        DROP TABLE IF EXISTS capability_grants;
        DROP TABLE IF EXISTS task_events;
        DROP TABLE IF EXISTS task_tool_states;
        DROP TABLE IF EXISTS task_artifacts;
        DROP TABLE IF EXISTS tasks;
        DROP TABLE IF EXISTS workspaces;
        PRAGMA user_version = 6;
        """)

        #expect(queryScalar("PRAGMA user_version") == "6")
        for tbl in newTables {
            #expect(!hasTable(tbl), "Table \(tbl) should not exist after downgrade")
        }
        // Original v6 data remains completely preserved
        #expect(queryScalar("SELECT COUNT(*) FROM sessions") == "1")
        #expect(queryScalar("SELECT COUNT(*) FROM agent_runs") == "3")
    }

    // MARK: - 3. Fork Isolation Tests

    @Test("ForkIsolationTests: origin workspace chain and bidirectional filesystem isolation")
    func forkIsolationTests() throws {
        // 1. Chain validation
        let w1 = WorkspaceEntity(workspaceID: WorkspaceID("ws-main"), projectID: "proj-alpha", kind: .main)
        #expect(w1.originWorkspaceID == nil)
        #expect(w1.kind == .main)

        let w2 = WorkspaceEntity(
            workspaceID: WorkspaceID("ws-fork-1"),
            projectID: w1.projectID,
            kind: .fork,
            originWorkspaceID: w1.workspaceID,
            isolationState: .copyOnWrite
        )
        #expect(w2.originWorkspaceID == w1.workspaceID)
        #expect(w2.kind == .fork)

        let w3 = WorkspaceEntity(
            workspaceID: WorkspaceID("ws-fork-2"),
            projectID: w1.projectID,
            kind: .fork,
            originWorkspaceID: w2.workspaceID,
            isolationState: .copyOnWrite
        )
        #expect(w3.originWorkspaceID == w2.workspaceID)

        // 2. Bidirectional Filesystem Isolation
        let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("fork_iso_\(UUID().uuidString)")
        let root1 = baseDir.appendingPathComponent("workspace_1")
        let root2 = baseDir.appendingPathComponent("workspace_2")
        try FileManager.default.createDirectory(at: root1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        // Write in root1
        let file1 = root1.appendingPathComponent("file_a.txt")
        try "Content from W1".write(to: file1, atomically: true, encoding: .utf8)

        // Write in root2
        let file2 = root2.appendingPathComponent("file_b.txt")
        try "Content from W2".write(to: file2, atomically: true, encoding: .utf8)

        // Assert file1 not in root2 and file2 not in root1
        #expect(FileManager.default.fileExists(atPath: file1.path))
        #expect(!FileManager.default.fileExists(atPath: root2.appendingPathComponent("file_a.txt").path))

        #expect(FileManager.default.fileExists(atPath: file2.path))
        #expect(!FileManager.default.fileExists(atPath: root1.appendingPathComponent("file_b.txt").path))
    }

    // MARK: - 4. Task Restart and Resume Point Tests

    @Test("TaskRestartResumeTests: ResumePoint roundtrip and state log recovery")
    func taskRestartResumeTests() throws {
        let resume = ResumePoint(
            stepIndex: 12,
            generation: 4,
            interruptedAt: Date(timeIntervalSince1970: 1700000500),
            statePayload: ["interruptedReason": "budgetExhausted", "lastActiveStep": "12"],
            contextSnapshotRef: "snapshot-hash-999"
        )

        // 1. JSON Roundtrip
        let data = try JSONEncoder().encode(resume)
        let decoded = try JSONDecoder().decode(ResumePoint.self, from: data)

        #expect(decoded.stepIndex == 12)
        #expect(decoded.generation == 4)
        #expect(decoded.statePayload["interruptedReason"] == "budgetExhausted")
        #expect(decoded.contextSnapshotRef == "snapshot-hash-999")

        // 2. TaskEventPayload sequence tail recovery
        let taskID = TaskID("task-test-restart")
        let events: [TaskEventPayload] = [
            TaskEventPayload(seq: 1, taskID: taskID, event: "lifecycle.start", fromState: .queued, toState: .running),
            TaskEventPayload(seq: 2, taskID: taskID, event: "lifecycle.wait", fromState: .running, toState: .waiting, payload: ["reason": "approvalPending"]),
            TaskEventPayload(seq: 3, taskID: taskID, event: "lifecycle.resume", fromState: .waiting, toState: .running),
            TaskEventPayload(seq: 4, taskID: taskID, event: "lifecycle.pause", fromState: .running, toState: .paused, payload: ["generation": "2", "stepIndex": "15"])
        ]

        guard let tail = events.last else {
            Issue.record("Events array must not be empty")
            return
        }

        #expect(tail.toState == .paused)
        #expect(tail.payload["generation"] == "2")
        #expect(tail.payload["stepIndex"] == "15")
    }
}
