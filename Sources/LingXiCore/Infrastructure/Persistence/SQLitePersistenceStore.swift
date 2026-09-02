import Foundation
import SQLite3
import LingXiProtocol

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum PersistenceError: Error, Sendable, Equatable {
    case sqlite(String)
    case migration(Int)
    case missingMainRoot(ProjectID)
}

public enum PersistenceFailpoint: Sendable, Equatable {
    case beforeCompactionCommit
    case beforeSaveAgentRun(SessionKind? = nil)
}

public struct StructuredPathAuditViolation: Sendable, Equatable {
    public let location: String
    public let value: String
}

/// 单 actor 持有两个 SQLite handle；所有写入均经过此序列化事务边界。
public actor SQLitePersistenceStore {
    public static let databaseSchemaVersion = 6
    public static let contextFormatVersion = 1
    public static let indexFormatVersion = 1

    public let dataRoot: URL
    public nonisolated let projectID: ProjectID
    private nonisolated(unsafe) let catalog: OpaquePointer
    private nonisolated(unsafe) let state: OpaquePointer
    private let blobs: FileBlobStore
    private var failpoint: PersistenceFailpoint?

    public init(dataRoot: URL, mainRoot: URL, projectID: ProjectID? = nil) throws {
        self.dataRoot = dataRoot.standardizedFileURL
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let catalogDB = try Self.open(dataRoot.appendingPathComponent("catalog.sqlite"))
        catalog = catalogDB
        try Self.configure(catalogDB)
        try Self.migrate(catalogDB, create: { try Self.createCatalogSchema(catalogDB) }, upgrade: { try Self.execute(catalogDB, "PRAGMA user_version = 2", []) }, upgradeV3: { try Self.execute(catalogDB, "PRAGMA user_version = 3", []) }, upgradeV4: { try Self.execute(catalogDB, "PRAGMA user_version = 4", []) }, upgradeV5: { try Self.execute(catalogDB, "PRAGMA user_version = 5", []) }, upgradeV6: { try Self.execute(catalogDB, "PRAGMA user_version = 6", []) })
        let canonicalRoot = mainRoot.standardizedFileURL.resolvingSymlinksInPath()
        if let projectID {
            self.projectID = projectID
        } else if let existing = try Self.scalar(catalogDB, "SELECT project_id FROM root_bindings WHERE absolute_root = ? AND kind = 'main' AND lifecycle_state = 'active' LIMIT 1", [canonicalRoot.path]) {
            self.projectID = ProjectID(existing)
        } else {
            self.projectID = ProjectID(UUID().uuidString)
        }
        let projectDirectory = dataRoot.appendingPathComponent("projects", isDirectory: true).appendingPathComponent(self.projectID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let stateDB = try Self.open(projectDirectory.appendingPathComponent("state.sqlite"))
        state = stateDB
        try Self.configure(stateDB)
        try Self.migrate(stateDB, create: { try Self.createStateSchema(stateDB) }, upgrade: { try Self.upgradeStateSchemaV2(stateDB) }, upgradeV3: { try Self.upgradeStateSchemaV3(stateDB) }, upgradeV4: { try Self.upgradeStateSchemaV4(stateDB) }, upgradeV5: { try Self.upgradeStateSchemaV5(stateDB) }, upgradeV6: { try Self.upgradeStateSchemaV6(stateDB) })
        try Self.execute(stateDB, "CREATE TABLE IF NOT EXISTS persistence_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)", [])
        blobs = try FileBlobStore(directory: projectDirectory.appendingPathComponent("blobs", isDirectory: true))
        try Self.transaction(catalogDB) {
            try Self.execute(catalogDB, "INSERT OR IGNORE INTO projects(project_id, created_at, updated_at) VALUES(?, ?, ?)", [self.projectID.rawValue, Self.now, Self.now])
            let count = try Self.scalar(catalogDB, "SELECT COUNT(*) FROM root_bindings WHERE project_id = ? AND kind = 'main' AND lifecycle_state = 'active'", [self.projectID.rawValue]).flatMap(Int.init) ?? 0
            if count == 0 {
                try Self.execute(catalogDB, "INSERT INTO root_bindings(binding_id, project_id, kind, absolute_root, parent_binding_id, binding_revision, lifecycle_state, time_created, time_updated, time_last_seen) VALUES(?, ?, 'main', ?, NULL, 1, 'active', ?, ?, ?)", ["RB-" + UUID().uuidString, self.projectID.rawValue, canonicalRoot.path, Self.now, Self.now, Self.now])
            }
        }
    }

    deinit { sqlite3_close(catalog); sqlite3_close(state) }

    public func mainRootBinding() throws -> RootBinding {
        guard let binding = try rootBindings(projectID: projectID).first(where: { $0.kind == .main && $0.lifecycleState == .active }) else { throw PersistenceError.missingMainRoot(projectID) }
        return binding
    }

    public func rootBindings(projectID: ProjectID? = nil) throws -> [RootBinding] {
        let id = (projectID ?? self.projectID).rawValue
        return try Self.rows(catalog, "SELECT binding_id, project_id, kind, absolute_root, parent_binding_id, binding_revision, lifecycle_state, time_created, time_updated, time_last_seen FROM root_bindings WHERE project_id = ? ORDER BY kind, binding_id", [id]).compactMap(Self.decodeRoot)
    }

    public func rootBinding(_ id: RootBindingID) throws -> RootBinding? {
        try Self.rows(catalog, "SELECT binding_id, project_id, kind, absolute_root, parent_binding_id, binding_revision, lifecycle_state, time_created, time_updated, time_last_seen FROM root_bindings WHERE binding_id = ?", [id.rawValue]).compactMap(Self.decodeRoot).first
    }

    @discardableResult
    public func addChildRoot(kind: RootBindingKind, absoluteRoot: URL) throws -> RootBinding {
        precondition(kind != .main)
        let main = try mainRootBinding()
        let id = RootBindingID("RB-" + UUID().uuidString)
        let root = absoluteRoot.standardizedFileURL.resolvingSymlinksInPath().path
        try Self.transaction(catalog) {
            try Self.execute(catalog, "INSERT INTO root_bindings(binding_id, project_id, kind, absolute_root, parent_binding_id, binding_revision, lifecycle_state, time_created, time_updated, time_last_seen) VALUES(?, ?, ?, ?, ?, 1, 'active', ?, ?, ?)", [id.rawValue, projectID.rawValue, kind.rawValue, root, main.id.rawValue, Self.now, Self.now, Self.now])
        }
        return try rootBinding(id)!
    }

    /// 根迁移只更新 catalog 中的一行，绝不遍历 project state。
    public func rebindRoot(projectID: ProjectID, rootBindingID: RootBindingID, newAbsoluteRoot: URL) throws {
        let canonical = newAbsoluteRoot.standardizedFileURL.resolvingSymlinksInPath().path
        try Self.transaction(catalog) {
            try Self.execute(catalog, "UPDATE root_bindings SET absolute_root = ?, binding_revision = binding_revision + 1, lifecycle_state = 'active', time_updated = ?, time_last_seen = ? WHERE binding_id = ? AND project_id = ?", [canonical, Self.now, Self.now, rootBindingID.rawValue, projectID.rawValue])
        }
    }

    public func markRootMissing(_ id: RootBindingID) throws {
        try Self.execute(catalog, "UPDATE root_bindings SET lifecycle_state = 'missing', time_updated = ? WHERE binding_id = ?", [Self.now, id.rawValue])
    }

    public func upsertFile(rootBindingID: RootBindingID, relativePath: ProjectRelativePath, contentHash: String, version: String, state fileState: String = "active") throws -> ProjectFileBinding {
        if let existing = try file(rootBindingID: rootBindingID, relativePath: relativePath) {
            try Self.execute(state, "UPDATE project_files SET content_hash = ?, version = ?, state = ?, time_updated = ?, time_last_seen = ? WHERE file_id = ?", [contentHash, version, fileState, Self.now, Self.now, existing.id.rawValue])
            return try file(existing.id)!
        }
        let id = ProjectFileID("F-" + UUID().uuidString)
        try Self.execute(state, "INSERT INTO project_files(file_id, project_id, root_binding_id, relative_path, content_hash, version, state, time_created, time_updated, time_last_seen) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [id.rawValue, projectID.rawValue, rootBindingID.rawValue, relativePath.rawValue, contentHash, version, fileState, Self.now, Self.now, Self.now])
        return try file(id)!
    }

    public func file(_ id: ProjectFileID) throws -> ProjectFileBinding? {
        try Self.rows(state, "SELECT file_id, project_id, root_binding_id, relative_path, content_hash, version, state, time_created, time_updated, time_last_seen FROM project_files WHERE file_id = ?", [id.rawValue]).compactMap(Self.decodeFile).first
    }

    public func file(rootBindingID: RootBindingID, relativePath: ProjectRelativePath) throws -> ProjectFileBinding? {
        try Self.rows(state, "SELECT file_id, project_id, root_binding_id, relative_path, content_hash, version, state, time_created, time_updated, time_last_seen FROM project_files WHERE root_binding_id = ? AND relative_path = ?", [rootBindingID.rawValue, relativePath.rawValue]).compactMap(Self.decodeFile).first
    }

    public func files() throws -> [ProjectFileBinding] {
        try Self.rows(state, "SELECT file_id, project_id, root_binding_id, relative_path, content_hash, version, state, time_created, time_updated, time_last_seen FROM project_files WHERE project_id = ?", [projectID.rawValue]).compactMap(Self.decodeFile)
    }

    public func relocateFile(_ id: ProjectFileID, rootBindingID: RootBindingID, relativePath: ProjectRelativePath) throws {
        try Self.execute(state, "UPDATE project_files SET root_binding_id = ?, relative_path = ?, time_updated = ?, time_last_seen = ? WHERE file_id = ?", [rootBindingID.rawValue, relativePath.rawValue, Self.now, Self.now, id.rawValue])
    }

    public func markFileMissing(_ id: ProjectFileID) throws {
        try Self.execute(state, "UPDATE project_files SET state = 'missing', time_updated = ? WHERE file_id = ?", [Self.now, id.rawValue])
    }

    public func createSession(_ session: Session) throws {
        try writeSession(session)
    }

    public func appendMessage(sessionID: SessionID, message: Message) throws {
        let ordinal = try Self.scalar(state, "SELECT COALESCE(MAX(ordinal), -1) + 1 FROM messages WHERE session_id = ?", [sessionID.rawValue]).flatMap(Int.init) ?? 0
        try Self.transaction(state) {
            try Self.insertMessage(state, sessionID: sessionID, message: message, ordinal: ordinal)
        }
    }

    public func appendAssistantMessageAndBatch(sessionID: SessionID, message: Message, batch: ToolExchangeBatch) throws {
        let ordinal = try Self.nextMessageOrdinal(state, sessionID)
        try Self.transaction(state) {
            try Self.insertMessage(state, sessionID: sessionID, message: message, ordinal: ordinal)
            try Self.writeBatch(state, batch)
        }
    }

    public func appendToolResultMessageAndSettle(sessionID: SessionID, message: Message, batch: ToolExchangeBatch) throws {
        let ordinal = try Self.nextMessageOrdinal(state, sessionID)
        try Self.transaction(state) {
            try Self.insertMessage(state, sessionID: sessionID, message: message, ordinal: ordinal)
            try Self.writeBatch(state, batch)
        }
    }

    public func loadSessions() throws -> [Session] {
        let sessions = try Self.rows(state, "SELECT session_id, project_id, kind, parent_session_id, root_session_id, spawned_by_run_id, spawned_by_tool_call_id, title, cwd_root_binding_id, cwd_relative_path, created_at, updated_at FROM sessions WHERE project_id = ? ORDER BY created_at", [projectID.rawValue])
        return try sessions.map { row in
            let id = SessionID(row[0]); let messages = try loadMessages(sessionID: id)
            return Session(id: id, createdAt: Self.parseDate(row[10]), kind: SessionKind(rawValue: row[2]) ?? .primary, parentSessionID: row[3].isEmpty ? nil : SessionID(row[3]), rootSessionID: SessionID(row[4]), spawnedByRunID: row[5].isEmpty ? nil : AgentRunID(row[5]), spawnedByToolCallID: row[6].isEmpty ? nil : ToolCallID(row[6]), title: row[7].isEmpty ? nil : row[7], projectID: ProjectID(row[1]), cwdRootBindingID: RootBindingID(row[8]), cwdRelativePath: ProjectRelativePath(rawValue: row[9]), updatedAt: Self.parseDate(row[11]), messages: messages)
        }
    }

    public func loadMessages(sessionID: SessionID) throws -> [Message] {
        try Self.rows(state, "SELECT message_id, role, created_at FROM messages WHERE session_id = ? ORDER BY ordinal", [sessionID.rawValue]).map { row in
            let parts = try Self.rows(state, "SELECT payload FROM message_parts WHERE message_id = ? ORDER BY ordinal", [row[0]]).map { try JSONDecoder().decode(SessionMessagePart.self, from: Data($0[0].utf8)) }
            guard let role = MessageRole(rawValue: row[1]) else { throw PersistenceError.sqlite("invalid message role") }
            return Message(id: MessageID(row[0]), role: role, parts: parts, createdAt: Self.parseDate(row[2]))
        }
    }

    public func deleteSession(_ id: SessionID) throws {
        try Self.transaction(state) {
            try Self.execute(state, "DELETE FROM agent_run_results WHERE run_id IN (SELECT run_id FROM agent_runs WHERE session_id = ?)", [id.rawValue])
            try Self.execute(state, "DELETE FROM agent_runs WHERE session_id = ?", [id.rawValue])
            try Self.execute(state, "DELETE FROM compaction_state WHERE session_id = ?", [id.rawValue])
            try Self.execute(state, "DELETE FROM derived_context WHERE session_id = ?", [id.rawValue])
            try Self.execute(state, "DELETE FROM session_l2 WHERE session_id = ?", [id.rawValue])
            try Self.execute(state, "DELETE FROM tool_exchange_batches WHERE session_id = ?", [id.rawValue])
            try Self.execute(state, "DELETE FROM message_parts WHERE message_id IN (SELECT message_id FROM messages WHERE session_id = ?)", [id.rawValue])
            try Self.execute(state, "DELETE FROM messages WHERE session_id = ?", [id.rawValue])
            try Self.execute(state, "DELETE FROM sessions WHERE session_id = ?", [id.rawValue])
        }
    }

    public func updateSessionTitle(_ id: SessionID, title: String?) throws {
        try Self.execute(state, "UPDATE sessions SET title = ?, updated_at = ? WHERE session_id = ?", [title ?? NSNull(), Self.date(.now), id.rawValue])
    }

    public func deleteAgentRun(_ id: AgentRunID) throws {
        try Self.transaction(state) {
            try Self.execute(state, "DELETE FROM agent_run_results WHERE run_id = ?", [id.rawValue])
            try Self.execute(state, "DELETE FROM agent_runs WHERE run_id = ?", [id.rawValue])
        }
    }

    public func saveAgentRun(_ run: AgentRunInfo, profile: SubagentExecutionProfile? = nil) throws {
        try consumeAgentRunFailpoint(run)
        try writeAgentRun(run, profile: profile)
    }

    /// A persistent child is visible only once its first AgentRun is durable too.
    public func createChildSessionAndRun(_ session: Session, run: AgentRunInfo, profile: SubagentExecutionProfile? = nil) throws {
        guard session.kind == .subagent, run.sessionID == session.id, run.agentKind == .subagent else {
            throw PersistenceError.sqlite("child session and AgentRun must agree")
        }
        try consumeAgentRunFailpoint(run)
        try Self.transaction(state) {
            try writeSession(session)
            try writeAgentRun(run, profile: profile)
        }
    }

    public func loadAgentRuns(sessionID: SessionID? = nil) throws -> [AgentRunInfo] {
        let query = sessionID == nil ? "SELECT run_id, session_id, project_id, parent_run_id, root_run_id, agent_kind, status, provider_id, account_id, profile_id, model_id, reasoning, context_profile, started_at, finished_at, latest_activity_at, usage_json, error_json, title FROM agent_runs ORDER BY latest_activity_at" : "SELECT run_id, session_id, project_id, parent_run_id, root_run_id, agent_kind, status, provider_id, account_id, profile_id, model_id, reasoning, context_profile, started_at, finished_at, latest_activity_at, usage_json, error_json, title FROM agent_runs WHERE session_id = ? ORDER BY latest_activity_at"
        return try Self.rows(state, query, sessionID.map { [$0.rawValue] } ?? []).compactMap { row in
            guard let kind = SessionKind(rawValue: row[5]), let status = AgentRunStatus(rawValue: row[6]) else { return nil }
            return AgentRunInfo(runID: AgentRunID(row[0]), sessionID: SessionID(row[1]), projectID: ProjectID(row[2]), parentRunID: row[3].isEmpty ? nil : AgentRunID(row[3]), rootRunID: AgentRunID(row[4]), agentKind: kind, status: status, modelSelection: ModelSelection(providerID: row[7], accountID: row[8].isEmpty ? nil : row[8], profileID: row[9].isEmpty ? nil : row[9], modelID: row[10], reasoning: row[11].isEmpty ? nil : row[11], contextProfile: row[12].isEmpty ? nil : row[12]), startedAt: row[13].isEmpty ? nil : Self.parseDate(row[13]), finishedAt: row[14].isEmpty ? nil : Self.parseDate(row[14]), latestActivityAt: Self.parseDate(row[15]), error: row[17].isEmpty ? nil : try? JSONDecoder().decode(CoreError.self, from: Data(row[17].utf8)), usage: (try? JSONDecoder().decode(AgentRunUsage.self, from: Data(row[16].utf8))) ?? AgentRunUsage(), title: row[18].isEmpty ? nil : row[18])
        }
    }

    public func agentRunProfile(_ runID: AgentRunID) throws -> SubagentExecutionProfile? {
        guard let row = try Self.rows(state, "SELECT permission_profile, tool_profile, budget_profile, context_profile, profile_json FROM agent_runs WHERE run_id = ?", [runID.rawValue]).first else { return nil }
        if !row[4].isEmpty { return try JSONDecoder().decode(SubagentExecutionProfile.self, from: Data(row[4].utf8)) }
        let tools = row[1].isEmpty ? nil : try? JSONDecoder().decode([String].self, from: Data(row[1].utf8))
        guard !row[0].isEmpty || tools != nil || !row[2].isEmpty || !row[3].isEmpty else { return nil }
        return SubagentExecutionProfile(permissionProfile: row[0].isEmpty ? nil : row[0], toolProfile: tools, budgetProfile: row[2].isEmpty ? nil : row[2], contextProfile: row[3].isEmpty ? nil : row[3])
    }

    public func saveAgentRunResult(_ result: SubagentResult) throws {
        try writeAgentRunResult(result)
    }

    /// Terminal state and its result form one durable fact; callers must not publish either first.
    public func saveTerminalAgentRun(_ run: AgentRunInfo, result: SubagentResult, profile: SubagentExecutionProfile? = nil) throws {
        guard run.status.isTerminal, result.runID == run.runID, result.status == run.status else {
            throw PersistenceError.sqlite("terminal AgentRun and result must agree")
        }
        try consumeAgentRunFailpoint(run)
        try Self.transaction(state) {
            try writeAgentRun(run, profile: profile)
            try writeAgentRunResult(result)
        }
    }

    private func writeSession(_ session: Session) throws {
        guard let root = session.cwdRootBindingID else { throw PersistenceError.missingMainRoot(projectID) }
        try Self.execute(state, "INSERT INTO sessions(session_id, project_id, kind, parent_session_id, root_session_id, spawned_by_run_id, spawned_by_tool_call_id, title, cwd_root_binding_id, cwd_relative_path, created_at, updated_at, metadata) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '{}')", [session.id.rawValue, projectID.rawValue, session.kind.rawValue, session.parentSessionID?.rawValue ?? NSNull(), session.rootSessionID.rawValue, session.spawnedByRunID?.rawValue ?? NSNull(), session.spawnedByToolCallID?.rawValue ?? NSNull(), session.title ?? NSNull(), root.rawValue, session.cwdRelativePath.rawValue, Self.date(session.createdAt), Self.date(session.createdAt)])
    }

    private func consumeAgentRunFailpoint(_ run: AgentRunInfo) throws {
        if case let .beforeSaveAgentRun(targetKind) = failpoint, targetKind == nil || targetKind == run.agentKind {
            failpoint = nil
            throw PersistenceError.sqlite("injected saveAgentRun failure")
        }
    }

    private func writeAgentRun(_ run: AgentRunInfo, profile: SubagentExecutionProfile?) throws {
        let selection = run.modelSelection
        let usage = String(decoding: try JSONEncoder().encode(run.usage), as: UTF8.self)
        let error = try run.error.map { try String(decoding: JSONEncoder().encode($0), as: UTF8.self) }
        let tools = try profile?.toolProfile.map { try String(decoding: JSONEncoder().encode($0), as: UTF8.self) }
        let profileJSON = try profile.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try Self.execute(state, "INSERT OR REPLACE INTO agent_runs(run_id, session_id, project_id, parent_run_id, root_run_id, agent_kind, status, provider_id, account_id, profile_id, model_id, reasoning, context_profile, permission_profile, tool_profile, budget_profile, profile_json, started_at, finished_at, latest_activity_at, usage_json, error_json, title) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [run.runID.rawValue, run.sessionID.rawValue, run.projectID?.rawValue ?? projectID.rawValue, run.parentRunID?.rawValue ?? NSNull(), run.rootRunID.rawValue, run.agentKind.rawValue, run.status.rawValue, selection.providerID, selection.accountID ?? NSNull(), selection.profileID ?? NSNull(), selection.modelID, selection.reasoning ?? NSNull(), selection.contextProfile ?? NSNull(), profile?.permissionProfile ?? NSNull(), tools ?? NSNull(), profile?.budgetProfile ?? NSNull(), profileJSON ?? NSNull(), run.startedAt.map(Self.date) ?? NSNull(), run.finishedAt.map(Self.date) ?? NSNull(), Self.date(run.latestActivityAt), usage, error ?? NSNull(), run.title ?? NSNull()])
    }

    private func writeAgentRunResult(_ result: SubagentResult) throws {
        let error = try result.error.map { try String(decoding: JSONEncoder().encode($0), as: UTF8.self) }
        try Self.execute(state, "INSERT OR REPLACE INTO agent_run_results(run_id, status, final_text, touched_resources_json, artifact_refs_json, usage_json, error_json, timestamp) VALUES(?, ?, ?, ?, ?, ?, ?, ?)", [result.runID.rawValue, result.status.rawValue, result.finalText ?? NSNull(), String(decoding: try JSONEncoder().encode(result.touchedResources), as: UTF8.self), String(decoding: try JSONEncoder().encode(result.artifactReferences), as: UTF8.self), String(decoding: try JSONEncoder().encode(result.usage), as: UTF8.self), error ?? NSNull(), Self.date(result.timestamp)])
    }

    public func agentRunResult(_ runID: AgentRunID) throws -> SubagentResult? {
        guard let row = try Self.rows(state, "SELECT r.session_id, x.status, x.final_text, x.touched_resources_json, x.artifact_refs_json, x.usage_json, x.error_json, x.timestamp FROM agent_runs r JOIN agent_run_results x ON x.run_id = r.run_id WHERE r.run_id = ?", [runID.rawValue]).first, let status = AgentRunStatus(rawValue: row[1]) else { return nil }
        return SubagentResult(childSessionID: SessionID(row[0]), runID: runID, status: status, finalText: row[2].isEmpty ? nil : row[2], touchedResources: (try? JSONDecoder().decode([ToolTouchedResource].self, from: Data(row[3].utf8))) ?? [], artifactReferences: (try? JSONDecoder().decode([String].self, from: Data(row[4].utf8))) ?? [], usage: (try? JSONDecoder().decode(AgentRunUsage.self, from: Data(row[5].utf8))) ?? AgentRunUsage(), error: row[6].isEmpty ? nil : try? JSONDecoder().decode(CoreError.self, from: Data(row[6].utf8)), timestamp: Self.parseDate(row[7]))
    }

    /// Snapshot and normalized task rows are committed together; recovery reads the snapshot only.
    public func saveWorkflow(_ workflow: WorkflowSnapshot) throws {
        let encoder = JSONEncoder()
        let snapshot = String(decoding: try encoder.encode(workflow), as: UTF8.self)
        try Self.transaction(state) {
            try Self.execute(state, "INSERT OR REPLACE INTO workflows(workflow_id, project_id, root_session_id, root_run_id, status, checkpoint_json, snapshot_json, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)", [workflow.id.rawValue, projectID.rawValue, workflow.rootSessionID.rawValue, workflow.rootRunID.rawValue, workflow.status.rawValue, String(decoding: try encoder.encode(workflow.checkpoint), as: UTF8.self), snapshot, Self.date(workflow.createdAt), Self.date(workflow.updatedAt)])
            try Self.execute(state, "DELETE FROM workflow_pending_inputs WHERE workflow_id = ?", [workflow.id.rawValue])
            try Self.execute(state, "DELETE FROM workflow_dependencies WHERE workflow_id = ?", [workflow.id.rawValue])
            try Self.execute(state, "DELETE FROM workflow_tasks WHERE workflow_id = ?", [workflow.id.rawValue])
            for task in workflow.tasks {
                let definition = String(decoding: try encoder.encode(task.definition), as: UTF8.self)
                let provenance = try task.provenance.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
                let result = try task.result.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
                let error = try task.error.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
                try Self.execute(state, "INSERT INTO workflow_tasks(workflow_id, task_id, status, definition_json, provenance_json, result_json, error_json) VALUES(?, ?, ?, ?, ?, ?, ?)", [workflow.id.rawValue, task.definition.id.rawValue, task.status.rawValue, definition, provenance ?? NSNull(), result ?? NSNull(), error ?? NSNull()])
                for dependency in task.definition.dependencies {
                    try Self.execute(state, "INSERT INTO workflow_dependencies(workflow_id, task_id, dependency_task_id) VALUES(?, ?, ?)", [workflow.id.rawValue, task.definition.id.rawValue, dependency.rawValue])
                }
                if let pending = task.pendingInput {
                    let kind: String
                    switch pending { case .question: kind = "question"; case .permission: kind = "permission"; case .decision: kind = "decision" }
                    try Self.execute(state, "INSERT INTO workflow_pending_inputs(workflow_id, task_id, kind, payload_json) VALUES(?, ?, ?, ?)", [workflow.id.rawValue, task.definition.id.rawValue, kind, String(decoding: try encoder.encode(pending), as: UTF8.self)])
                }
            }
        }
    }

    public func loadWorkflows() throws -> [WorkflowSnapshot] {
        try Self.rows(state, "SELECT snapshot_json FROM workflows WHERE project_id = ? ORDER BY created_at", [projectID.rawValue]).compactMap { row in
            try? JSONDecoder().decode(WorkflowSnapshot.self, from: Data(row[0].utf8))
        }
    }

    public func saveDerived(_ page: DerivedContextPage) throws {
        try writeDerived(page)
    }

    public func loadDerived() throws -> [DerivedContextPage] {
        try Self.rows(state, "SELECT derived_page_id, session_id, source_kind, inline_content, blob_ref, message_id, token_estimate, created_at, version, provenance_json, metadata_json FROM derived_context WHERE project_id = ? ORDER BY created_at", [projectID.rawValue]).compactMap { row in
            guard let kind = DerivedContextSourceKind(rawValue: row[2]) else { return nil }
            let content = row[3].isEmpty ? ((try? blobs.get(row[4])).flatMap { String(data: $0, encoding: .utf8) } ?? "") : row[3]
            return DerivedContextPage(id: row[0], sessionID: SessionID(row[1]), sourceKind: kind, content: content, messageID: row[5].isEmpty ? nil : MessageID(row[5]), tokenEstimate: Int(row[6]) ?? 0, provenanceIDs: (try? JSONDecoder().decode([String].self, from: Data(row[9].utf8))) ?? [], metadata: (try? JSONDecoder().decode([String: String].self, from: Data(row[10].utf8))) ?? [:], createdAt: Self.parseDate(row[7]), version: Int(row[8]) ?? 1)
        }
    }

    public func saveCompaction(sessionID: SessionID, generation: Int, residencies: [ContextUnitDebugSnapshot], derivedPages: [DerivedContextPage] = []) throws {
        let fail = failpoint == .beforeCompactionCommit
        failpoint = nil
        try Self.transaction(state) {
            for page in derivedPages { try writeDerived(page, database: state) }
            if fail { throw PersistenceError.sqlite("injected compaction failure") }
            try Self.execute(state, "INSERT OR REPLACE INTO compaction_state(session_id, generation, residency_json, updated_at) VALUES(?, ?, ?, ?)", [sessionID.rawValue, String(generation), String(decoding: try JSONEncoder().encode(residencies), as: UTF8.self), Self.now])
        }
    }

    public func armFailpoint(_ value: PersistenceFailpoint) { failpoint = value }

    public func compaction(sessionID: SessionID) throws -> (generation: Int, residencies: [ContextUnitDebugSnapshot])? {
        guard let row = try Self.rows(state, "SELECT generation, residency_json FROM compaction_state WHERE session_id = ?", [sessionID.rawValue]).first else { return nil }
        return (Int(row[0]) ?? 0, (try? JSONDecoder().decode([ContextUnitDebugSnapshot].self, from: Data(row[1].utf8))) ?? [])
    }

    public func saveToolBatch(_ batch: ToolExchangeBatch) throws {
        try Self.writeBatch(state, batch)
    }

    public func saveToolBatches(_ batches: [ToolExchangeBatch]) throws {
        guard !batches.isEmpty else { return }
        try Self.transaction(state) {
            for batch in batches { try Self.writeBatch(state, batch) }
        }
    }

    public func storeToolOutput(_ output: String) throws -> String {
        try blobs.put(Data(output.utf8))
    }

    /// Rebuildable project cache. Bodies remain in the filesystem (or blob store), never here.
    public func replaceProjectCache(pages: [ContextPage], symbols: [Symbol], references: [ProjectReference], dependencies: [DependencyEdge]) throws {
        try Self.transaction(state) {
            for table in ["project_pages", "cached_symbols", "cached_references", "cached_dependencies"] {
                try Self.execute(state, "DELETE FROM \(table) WHERE project_id = ?", [projectID.rawValue])
            }
            for page in pages {
                guard let fileID = page.fileID else { continue }
                try Self.execute(state, "INSERT INTO project_pages(page_id, project_id, file_id, start_line, end_line, content_hash, version, source_type, characters, metadata) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [page.id, projectID.rawValue, fileID.rawValue, String(page.startLine), String(page.endLine), page.hash, page.version, page.sourceType.rawValue, String(page.characterCount), page.metadata.heading ?? ""])
            }
            for symbol in symbols {
                guard let fileID = symbol.fileID else { continue }
                try Self.execute(state, "INSERT INTO cached_symbols(symbol_id, project_id, file_id, name, qualified_name, kind, line, page_id) VALUES(?, ?, ?, ?, ?, ?, ?, ?)", [symbol.id.rawValue, projectID.rawValue, fileID.rawValue, symbol.name, symbol.qualifiedName, symbol.kind.rawValue, String(symbol.line), symbol.pageID])
            }
            for reference in references {
                guard let fileID = reference.sourceFileID else { continue }
                try Self.execute(state, "INSERT INTO cached_references(reference_id, project_id, source_file_id, target_file_id, source_line, target_name, kind, resolution) VALUES(?, ?, ?, ?, ?, ?, ?, ?)", [reference.id.rawValue, projectID.rawValue, fileID.rawValue, reference.targetFileID?.rawValue ?? NSNull(), String(reference.sourceLine), reference.targetName, reference.kind.rawValue, reference.resolutionQuality.rawValue])
            }
            for dependency in dependencies {
                guard let source = dependency.sourceFileID else { continue }
                try Self.execute(state, "INSERT INTO cached_dependencies(project_id, source_file_id, target_file_id, kind, evidence_id) VALUES(?, ?, ?, ?, ?)", [projectID.rawValue, source.rawValue, dependency.targetFileID?.rawValue ?? NSNull(), dependency.kind.rawValue, dependency.evidence.rawValue])
            }
            try Self.execute(state, "INSERT OR REPLACE INTO persistence_metadata(key, value) VALUES('index_format_version', ?)", [String(Self.indexFormatVersion)])
        }
    }

    /// 索引是可重建缓存；版本变化时只清缓存，绝不触碰 Session、Derived 或 File identity。
    @discardableResult
    public func invalidateCachesIfFormatMismatch() throws -> Bool {
        let current = Int(try Self.scalar(state, "SELECT value FROM persistence_metadata WHERE key = 'index_format_version'", []) ?? "0") ?? 0
        guard current != Self.indexFormatVersion else { return false }
        try Self.transaction(state) {
            for table in ["project_pages", "cached_symbols", "cached_references", "cached_dependencies"] {
                try Self.execute(state, "DELETE FROM \(table) WHERE project_id = ?", [projectID.rawValue])
            }
            try Self.execute(state, "INSERT OR REPLACE INTO persistence_metadata(key, value) VALUES('index_format_version', ?)", [String(Self.indexFormatVersion)])
        }
        return true
    }

    public func setCacheFormatVersionForTesting(_ version: Int) throws {
        try Self.execute(state, "INSERT OR REPLACE INTO persistence_metadata(key, value) VALUES('index_format_version', ?)", [String(version)])
    }

    public func cacheCounts() throws -> (pages: Int, symbols: Int, references: Int, dependencies: Int) {
        func count(_ table: String) throws -> Int { try Self.scalar(state, "SELECT COUNT(*) FROM \(table) WHERE project_id = ?", [projectID.rawValue]).flatMap(Int.init) ?? 0 }
        return (try count("project_pages"), try count("cached_symbols"), try count("cached_references"), try count("cached_dependencies"))
    }

    public func toolBatches(sessionID: SessionID) throws -> [ToolExchangeBatch] {
        try Self.rows(state, "SELECT batch_id, assistant_message_id, result_message_id, provider_step, state, estimated_tokens, tool_calls_json, tool_results_json, continuation_request_id, tool_call_states_json FROM tool_exchange_batches WHERE session_id = ? ORDER BY provider_step", [sessionID.rawValue]).compactMap { row -> ToolExchangeBatch? in
            guard let persisted = ToolExchangeBatchState(rawValue: row[4]) else { return nil }
            let calls = (try? JSONDecoder().decode([ToolCall].self, from: Data(row[6].utf8))) ?? []
            let results = (try? JSONDecoder().decode([ToolResult].self, from: Data(row[7].utf8))) ?? []
            let states = try? JSONDecoder().decode([DurableToolCall].self, from: Data(row[9].utf8))
            let recoveredStates = ((states?.isEmpty == false ? states : nil) ?? calls.map { call in
                let result = results.first { $0.callID == call.callID }
                return DurableToolCall(call: call, state: result == nil ? .recoveryRequired : .completed, provenance: ToolCallProvenance(batchID: row[0], sessionID: sessionID, agentRunID: nil, providerRequestID: row[8].isEmpty ? nil : ModelRequestID(row[8]), providerStep: Int(row[3]) ?? 0), result: result)
            }).map(Self.recoverToolCall)
            let recovered: ToolExchangeBatchState = recoveredStates.contains(where: { $0.state == .recoveryRequired }) ? .recoveryRequired : persisted
            return ToolExchangeBatch(batchID: row[0], sessionID: sessionID, assistantMessageID: MessageID(row[1]), resultMessageID: row[2].isEmpty ? nil : MessageID(row[2]), toolCalls: calls, toolResults: results, toolCallStates: recoveredStates, continuationRequestID: row[8].isEmpty ? nil : ModelRequestID(row[8]), providerStep: Int(row[3]) ?? 0, state: recovered, estimatedTokens: Int(row[5]) ?? 0)
        }
    }

    public func statistics() throws -> (stateBytes: Int64, walBytes: Int64, blobBytes: Int64, sessions: Int, messages: Int, derived: Int, files: Int) {
        let stateURL = dataRoot.appendingPathComponent("projects").appendingPathComponent(projectID.rawValue).appendingPathComponent("state.sqlite")
        let size = Int64((try? stateURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let wal = Int64((try? URL(fileURLWithPath: stateURL.path + "-wal").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        func count(_ table: String) throws -> Int { try Self.scalar(state, "SELECT COUNT(*) FROM \(table)", []).flatMap(Int.init) ?? 0 }
        return (size, wal, try blobs.byteCount(), try count("sessions"), try count("messages"), try count("derived_context"), try count("project_files"))
    }

    public func integrityCheck() throws -> Bool {
        try Self.scalar(catalog, "PRAGMA quick_check", []) == "ok" && Self.scalar(catalog, "PRAGMA foreign_key_check", []) == nil && Self.scalar(state, "PRAGMA quick_check", []) == "ok" && Self.scalar(state, "PRAGMA foreign_key_check", []) == nil
    }

    /// 只检查 durable locator 列；正文、JSON payload 与 Tool 输出均不是路径事实。
    public func structuredAbsolutePathViolations(containing prefixes: [String]) throws -> [StructuredPathAuditViolation] {
        let checks = [
            ("sessions", "cwd_relative_path"),
            ("project_files", "relative_path"),
            ("project_files", "root_binding_id"),
            ("tool_exchange_batches", "assistant_message_id"),
            ("tool_exchange_batches", "result_message_id"),
            ("derived_context", "message_id"),
            ("derived_context", "blob_ref")
        ]
        var violations: [StructuredPathAuditViolation] = []
        for (table, column) in checks {
            for row in try Self.rows(state, "SELECT \(column) FROM \(table)", []) {
                guard let value = row.first, prefixes.contains(where: { value.contains($0) }) else { continue }
                violations.append(StructuredPathAuditViolation(location: "state.\(table).\(column)", value: value))
            }
        }
        // catalog 中唯一允许的 absolute filesystem locator 是 root_bindings.absolute_root。
        return violations
    }

    private static var now: String { date(.now) }
    private static func date(_ value: Date) -> String { String(value.timeIntervalSince1970) }
    private static func parseDate(_ value: String) -> Date { Date(timeIntervalSince1970: Double(value) ?? 0) }
    private static func open(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?; guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else { throw PersistenceError.sqlite("open \(url.lastPathComponent)") }; return db
    }
    private static func configure(_ db: OpaquePointer) throws { try script(db, "PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA busy_timeout = 5000") }
    private static func migrate(_ db: OpaquePointer, create: () throws -> Void, upgrade: () throws -> Void, upgradeV3: () throws -> Void, upgradeV4: () throws -> Void, upgradeV5: () throws -> Void, upgradeV6: () throws -> Void) throws {
        let version = Int(try scalar(db, "PRAGMA user_version", []) ?? "0") ?? 0
        try transaction(db) { try MigrationRunner.migrate(from: version, applyV0ToV1: create, applyV1ToV2: upgrade, applyV2ToV3: upgradeV3, applyV3ToV4: upgradeV4, applyV4ToV5: upgradeV5, applyV5ToV6: upgradeV6) }
    }
    private static func transaction(_ db: OpaquePointer, _ body: () throws -> Void) throws { try execute(db, "BEGIN IMMEDIATE", []); do { try body(); try execute(db, "COMMIT", []) } catch { try? execute(db, "ROLLBACK", []); throw error } }
    private static func nextMessageOrdinal(_ db: OpaquePointer, _ sessionID: SessionID) throws -> Int { try scalar(db, "SELECT COALESCE(MAX(ordinal), -1) + 1 FROM messages WHERE session_id = ?", [sessionID.rawValue]).flatMap(Int.init) ?? 0 }
    private static func insertMessage(_ db: OpaquePointer, sessionID: SessionID, message: Message, ordinal: Int) throws {
        try execute(db, "INSERT INTO messages(message_id, session_id, ordinal, role, created_at) VALUES(?, ?, ?, ?, ?)", [message.id.rawValue, sessionID.rawValue, String(ordinal), message.role.rawValue, date(message.createdAt)])
        for (partOrdinal, part) in message.parts.enumerated() { try execute(db, "INSERT INTO message_parts(message_id, ordinal, payload) VALUES(?, ?, ?)", [message.id.rawValue, String(partOrdinal), String(decoding: try JSONEncoder().encode(part), as: UTF8.self)]) }
        try execute(db, "UPDATE sessions SET updated_at = ? WHERE session_id = ?", [date(message.createdAt), sessionID.rawValue])
    }
    private static func writeBatch(_ db: OpaquePointer, _ batch: ToolExchangeBatch) throws {
        try execute(db, "INSERT OR REPLACE INTO tool_exchange_batches(batch_id, session_id, assistant_message_id, result_message_id, provider_step, state, estimated_tokens, tool_calls_json, tool_results_json, continuation_request_id, tool_call_states_json) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [batch.batchID, batch.sessionID.rawValue, batch.assistantMessageID.rawValue, batch.resultMessageID?.rawValue ?? NSNull(), String(batch.providerStep), batch.state.rawValue, String(batch.estimatedTokens), String(decoding: try JSONEncoder().encode(batch.toolCalls), as: UTF8.self), String(decoding: try JSONEncoder().encode(batch.toolResults), as: UTF8.self), batch.continuationRequestID?.rawValue ?? NSNull(), String(decoding: try JSONEncoder().encode(batch.toolCallStates), as: UTF8.self)])
    }
    private static func recoverToolCall(_ call: DurableToolCall) -> DurableToolCall {
        switch call.state {
        case .completed, .waitingForHuman, .requested, .recoveryRequired:
            return call
        case .executing:
            return call.executionClaim?.mutatesProject == true ? call.with(state: .recoveryRequired) : call.with(state: .requested)
        }
    }
    private func writeDerived(_ page: DerivedContextPage, database: OpaquePointer? = nil) throws {
        let contentRef: String?
        let inline: String?
        if page.content.utf8.count > 8 * 1024 {
            contentRef = try blobs.put(Data(page.content.utf8))
            inline = nil
        } else {
            contentRef = nil
            inline = page.content
        }
        try Self.execute(database ?? state, "INSERT OR REPLACE INTO derived_context(derived_page_id, project_id, session_id, source_kind, content_hash, inline_content, blob_ref, message_id, token_estimate, created_at, version, provenance_json, metadata_json) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [page.id, projectID.rawValue, page.sessionID.rawValue, page.sourceKind.rawValue, page.contentHash, inline ?? NSNull(), contentRef ?? NSNull(), page.messageID?.rawValue ?? NSNull(), String(page.tokenEstimate), Self.date(page.createdAt), String(page.version), String(decoding: try JSONEncoder().encode(page.provenanceIDs), as: UTF8.self), String(decoding: try JSONEncoder().encode(page.metadata), as: UTF8.self)])
    }
    private static func execute(_ db: OpaquePointer, _ sql: String, _ values: [Any]) throws { var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw PersistenceError.sqlite(String(cString: sqlite3_errmsg(db))) }; defer { sqlite3_finalize(statement) }; try bind(statement, values); guard sqlite3_step(statement) == SQLITE_DONE else { throw PersistenceError.sqlite(String(cString: sqlite3_errmsg(db))) } }
    private static func script(_ db: OpaquePointer, _ sql: String) throws { var error: UnsafeMutablePointer<CChar>?; guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else { defer { sqlite3_free(error) }; throw PersistenceError.sqlite(error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))) } }
    private static func scalar(_ db: OpaquePointer, _ sql: String, _ values: [Any]) throws -> String? { try rows(db, sql, values).first?.first }
    private static func rows(_ db: OpaquePointer, _ sql: String, _ values: [Any]) throws -> [[String]] { var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw PersistenceError.sqlite(String(cString: sqlite3_errmsg(db))) }; defer { sqlite3_finalize(statement) }; try bind(statement, values); var result: [[String]] = []; while sqlite3_step(statement) == SQLITE_ROW { result.append((0..<Int(sqlite3_column_count(statement))).map { sqlite3_column_text(statement, Int32($0)).map { String(cString: $0) } ?? "" }) }; return result }
    private static func bind(_ statement: OpaquePointer, _ values: [Any]) throws { for (index, value) in values.enumerated() { let i = Int32(index + 1); let rc: Int32; if value is NSNull { rc = sqlite3_bind_null(statement, i) } else { rc = sqlite3_bind_text(statement, i, String(describing: value), -1, SQLITE_TRANSIENT) }; guard rc == SQLITE_OK else { throw PersistenceError.sqlite("bind") } } }
    private static func createCatalogSchema(_ db: OpaquePointer) throws { try script(db, "CREATE TABLE IF NOT EXISTS projects(project_id TEXT PRIMARY KEY, created_at TEXT NOT NULL, updated_at TEXT NOT NULL); CREATE TABLE IF NOT EXISTS root_bindings(binding_id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(project_id), kind TEXT NOT NULL, absolute_root TEXT NOT NULL, parent_binding_id TEXT REFERENCES root_bindings(binding_id), binding_revision INTEGER NOT NULL, lifecycle_state TEXT NOT NULL, time_created TEXT NOT NULL, time_updated TEXT NOT NULL, time_last_seen TEXT); CREATE UNIQUE INDEX IF NOT EXISTS one_active_main_root ON root_bindings(project_id) WHERE kind = 'main' AND lifecycle_state = 'active'; PRAGMA user_version = 1") }
    private static func upgradeStateSchemaV2(_ db: OpaquePointer) throws {
        try script(db, "ALTER TABLE sessions ADD COLUMN kind TEXT NOT NULL DEFAULT 'primary'; ALTER TABLE sessions ADD COLUMN parent_session_id TEXT; ALTER TABLE sessions ADD COLUMN root_session_id TEXT; ALTER TABLE sessions ADD COLUMN spawned_by_run_id TEXT; ALTER TABLE sessions ADD COLUMN spawned_by_tool_call_id TEXT; ALTER TABLE sessions ADD COLUMN title TEXT; UPDATE sessions SET root_session_id = session_id WHERE root_session_id IS NULL; CREATE INDEX IF NOT EXISTS sessions_parent_idx ON sessions(parent_session_id); CREATE TABLE IF NOT EXISTS agent_runs(run_id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(session_id), project_id TEXT NOT NULL, parent_run_id TEXT, root_run_id TEXT NOT NULL, agent_kind TEXT NOT NULL, status TEXT NOT NULL, provider_id TEXT NOT NULL, model_id TEXT NOT NULL, reasoning TEXT, context_profile TEXT, permission_profile TEXT, tool_profile TEXT, budget_profile TEXT, started_at TEXT, finished_at TEXT, latest_activity_at TEXT NOT NULL, usage_json TEXT NOT NULL, error_json TEXT, title TEXT); CREATE INDEX IF NOT EXISTS agent_runs_session_idx ON agent_runs(session_id, latest_activity_at); CREATE TABLE IF NOT EXISTS agent_run_results(run_id TEXT PRIMARY KEY REFERENCES agent_runs(run_id), status TEXT NOT NULL, final_text TEXT, touched_resources_json TEXT NOT NULL, artifact_refs_json TEXT NOT NULL, usage_json TEXT NOT NULL, error_json TEXT, timestamp TEXT NOT NULL); PRAGMA user_version = 2")
    }
    private static func upgradeStateSchemaV3(_ db: OpaquePointer) throws {
        try script(db, "ALTER TABLE agent_runs ADD COLUMN account_id TEXT; ALTER TABLE agent_runs ADD COLUMN profile_id TEXT; PRAGMA user_version = 3")
    }
    private static func upgradeStateSchemaV4(_ db: OpaquePointer) throws { try script(db, "ALTER TABLE agent_runs ADD COLUMN profile_json TEXT; ALTER TABLE tool_exchange_batches ADD COLUMN continuation_request_id TEXT; PRAGMA user_version = 4") }
    private static func upgradeStateSchemaV5(_ db: OpaquePointer) throws { try script(db, "CREATE TABLE IF NOT EXISTS workflows(workflow_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, root_session_id TEXT NOT NULL REFERENCES sessions(session_id), root_run_id TEXT NOT NULL REFERENCES agent_runs(run_id), status TEXT NOT NULL, checkpoint_json TEXT NOT NULL, snapshot_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL); CREATE TABLE IF NOT EXISTS workflow_tasks(workflow_id TEXT NOT NULL REFERENCES workflows(workflow_id), task_id TEXT NOT NULL, status TEXT NOT NULL, definition_json TEXT NOT NULL, provenance_json TEXT, result_json TEXT, error_json TEXT, PRIMARY KEY(workflow_id, task_id)); CREATE TABLE IF NOT EXISTS workflow_dependencies(workflow_id TEXT NOT NULL REFERENCES workflows(workflow_id), task_id TEXT NOT NULL, dependency_task_id TEXT NOT NULL, PRIMARY KEY(workflow_id, task_id, dependency_task_id)); CREATE TABLE IF NOT EXISTS workflow_pending_inputs(workflow_id TEXT NOT NULL REFERENCES workflows(workflow_id), task_id TEXT NOT NULL, kind TEXT NOT NULL, payload_json TEXT NOT NULL, PRIMARY KEY(workflow_id, task_id)); CREATE INDEX IF NOT EXISTS workflow_status_idx ON workflows(project_id, status); PRAGMA user_version = 5") }
    private static func upgradeStateSchemaV6(_ db: OpaquePointer) throws { try script(db, "ALTER TABLE tool_exchange_batches ADD COLUMN tool_call_states_json TEXT NOT NULL DEFAULT '[]'; PRAGMA user_version = 6") }
    private static func createStateSchema(_ db: OpaquePointer) throws { try script(db, "CREATE TABLE IF NOT EXISTS sessions(session_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, cwd_root_binding_id TEXT NOT NULL, cwd_relative_path TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, metadata TEXT NOT NULL); CREATE TABLE IF NOT EXISTS messages(message_id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(session_id), ordinal INTEGER NOT NULL, role TEXT NOT NULL, created_at TEXT NOT NULL, UNIQUE(session_id, ordinal)); CREATE TABLE IF NOT EXISTS message_parts(message_id TEXT NOT NULL REFERENCES messages(message_id), ordinal INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(message_id, ordinal)); CREATE TABLE IF NOT EXISTS tool_exchange_batches(batch_id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(session_id), assistant_message_id TEXT NOT NULL, result_message_id TEXT, provider_step INTEGER NOT NULL, state TEXT NOT NULL, estimated_tokens INTEGER NOT NULL, tool_calls_json TEXT NOT NULL, tool_results_json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS derived_context(derived_page_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, session_id TEXT NOT NULL REFERENCES sessions(session_id), source_kind TEXT NOT NULL, content_hash TEXT NOT NULL, inline_content TEXT, blob_ref TEXT, message_id TEXT, token_estimate INTEGER NOT NULL, created_at TEXT NOT NULL, version INTEGER NOT NULL, provenance_json TEXT NOT NULL, metadata_json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS compaction_state(session_id TEXT PRIMARY KEY REFERENCES sessions(session_id), generation INTEGER NOT NULL, residency_json TEXT NOT NULL, updated_at TEXT NOT NULL); CREATE TABLE IF NOT EXISTS project_files(file_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, root_binding_id TEXT NOT NULL, relative_path TEXT NOT NULL, content_hash TEXT NOT NULL, version TEXT NOT NULL, state TEXT NOT NULL, time_created TEXT NOT NULL, time_updated TEXT NOT NULL, time_last_seen TEXT, UNIQUE(root_binding_id, relative_path)); CREATE TABLE IF NOT EXISTS project_pages(page_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, file_id TEXT NOT NULL, start_line INTEGER NOT NULL, end_line INTEGER NOT NULL, content_hash TEXT NOT NULL, version TEXT NOT NULL, source_type TEXT NOT NULL, characters INTEGER NOT NULL, metadata TEXT NOT NULL); CREATE TABLE IF NOT EXISTS cached_symbols(symbol_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, file_id TEXT NOT NULL, name TEXT NOT NULL, qualified_name TEXT NOT NULL, kind TEXT NOT NULL, line INTEGER NOT NULL, page_id TEXT NOT NULL); CREATE TABLE IF NOT EXISTS cached_references(reference_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, source_file_id TEXT NOT NULL, target_file_id TEXT, source_line INTEGER NOT NULL, target_name TEXT NOT NULL, kind TEXT NOT NULL, resolution TEXT NOT NULL); CREATE TABLE IF NOT EXISTS cached_dependencies(project_id TEXT NOT NULL, source_file_id TEXT NOT NULL, target_file_id TEXT, kind TEXT NOT NULL, evidence_id TEXT NOT NULL, PRIMARY KEY(project_id, source_file_id, evidence_id)); CREATE TABLE IF NOT EXISTS project_l2(page_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, score REAL NOT NULL, use_count INTEGER NOT NULL, last_used INTEGER NOT NULL, version TEXT NOT NULL); CREATE TABLE IF NOT EXISTS session_l2(derived_page_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, use_count INTEGER NOT NULL, last_used INTEGER NOT NULL, version INTEGER NOT NULL); PRAGMA user_version = 1") }
    private static func decodeRoot(_ row: [String]) -> RootBinding? { guard row.count == 10, let kind = RootBindingKind(rawValue: row[2]), let state = RootBindingLifecycleState(rawValue: row[6]) else { return nil }; return RootBinding(id: RootBindingID(row[0]), projectID: ProjectID(row[1]), kind: kind, absoluteRoot: URL(fileURLWithPath: row[3]), parentBindingID: row[4].isEmpty ? nil : RootBindingID(row[4]), bindingRevision: Int(row[5]) ?? 0, lifecycleState: state, createdAt: parseDate(row[7]), updatedAt: parseDate(row[8]), lastSeenAt: row[9].isEmpty ? nil : parseDate(row[9])) }
    private static func decodeFile(_ row: [String]) -> ProjectFileBinding? { guard row.count == 10 else { return nil }; return ProjectFileBinding(id: ProjectFileID(row[0]), projectID: ProjectID(row[1]), rootBindingID: RootBindingID(row[2]), relativePath: ProjectRelativePath(rawValue: row[3]), contentHash: row[4], version: row[5], state: row[6], createdAt: parseDate(row[7]), updatedAt: parseDate(row[8]), lastSeenAt: row[9].isEmpty ? nil : parseDate(row[9])) }
}
