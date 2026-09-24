import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
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
    public static let databaseSchemaVersion = 7
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
        try Self.migrate(catalogDB, create: { try Self.createCatalogSchema(catalogDB) }, upgrade: { try Self.execute(catalogDB, "PRAGMA user_version = 2", []) }, upgradeV3: { try Self.execute(catalogDB, "PRAGMA user_version = 3", []) }, upgradeV4: { try Self.execute(catalogDB, "PRAGMA user_version = 4", []) }, upgradeV5: { try Self.execute(catalogDB, "PRAGMA user_version = 5", []) }, upgradeV6: { try Self.execute(catalogDB, "PRAGMA user_version = 6", []) }, upgradeV7: { try Self.execute(catalogDB, "PRAGMA user_version = 7", []) })
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
        try Self.migrate(stateDB, create: { try Self.createStateSchema(stateDB) }, upgrade: { try Self.upgradeStateSchemaV2(stateDB) }, upgradeV3: { try Self.upgradeStateSchemaV3(stateDB) }, upgradeV4: { try Self.upgradeStateSchemaV4(stateDB) }, upgradeV5: { try Self.upgradeStateSchemaV5(stateDB) }, upgradeV6: { try Self.upgradeStateSchemaV6(stateDB) }, upgradeV7: { try Self.upgradeStateSchemaV7(stateDB) })
        _ = try? Self.script(stateDB, "ALTER TABLE sessions ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
        Self.ensureAllExistingProjectsHaveSessionRevision(dataRoot: dataRoot)
        try Self.execute(stateDB, "CREATE TABLE IF NOT EXISTS persistence_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)", [])
        try Self.execute(stateDB, "CREATE TABLE IF NOT EXISTS file_mutation_journal(id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, turn_id TEXT NOT NULL, revision INTEGER NOT NULL, tool_call_id TEXT NOT NULL, path TEXT NOT NULL, before_hash TEXT, before_content TEXT, after_hash TEXT, after_content TEXT, created_at REAL NOT NULL)", [])
        try Self.execute(stateDB, "CREATE INDEX IF NOT EXISTS idx_fmj_session ON file_mutation_journal(session_id)", [])
        blobs = try FileBlobStore(directory: projectDirectory.appendingPathComponent("blobs", isDirectory: true))
        try Self.transaction(catalogDB) {
            try Self.execute(catalogDB, "INSERT OR IGNORE INTO projects(project_id, created_at, updated_at) VALUES(?, ?, ?)", [self.projectID.rawValue, Self.now, Self.now])
            let count = try Self.scalar(catalogDB, "SELECT COUNT(*) FROM root_bindings WHERE project_id = ? AND kind = 'main' AND lifecycle_state = 'active'", [self.projectID.rawValue]).flatMap(Int.init) ?? 0
            if count == 0 {
                try Self.execute(catalogDB, "INSERT INTO root_bindings(binding_id, project_id, kind, absolute_root, parent_binding_id, binding_revision, lifecycle_state, time_created, time_updated, time_last_seen) VALUES(?, ?, 'main', ?, NULL, 1, 'active', ?, ?, ?)", ["RB-" + UUID().uuidString, self.projectID.rawValue, canonicalRoot.path, Self.now, Self.now, Self.now])
            }
        }
        let mainWorkspaceID = WorkspaceID("ws-" + self.projectID.rawValue)
        let mainRootID = try? Self.scalar(catalogDB, "SELECT binding_id FROM root_bindings WHERE project_id = ? AND kind = 'main' LIMIT 1", [self.projectID.rawValue])
        _ = try? Self.execute(stateDB, "INSERT OR IGNORE INTO workspaces(workspace_id, project_id, kind, root_binding_id, base_revision, isolation_state, state, created_at, updated_at) VALUES(?, ?, 'main', ?, 0, 'shared', 'active', ?, ?)", [mainWorkspaceID.rawValue, self.projectID.rawValue, mainRootID ?? NSNull(), Self.now, Self.now])
    }

    deinit { sqlite3_close_v2(catalog); sqlite3_close_v2(state) }

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

    public func appendMessage(sessionID: SessionID, message: Message, expectedRevision: UInt64? = nil) throws {
        try Self.transaction(state) {
            if let expected = expectedRevision {
                let actual = try Self.scalar(state, "SELECT revision FROM sessions WHERE session_id = ?", [sessionID.rawValue]).flatMap(UInt64.init) ?? 0
                guard actual == expected else {
                    throw StaleRunError(sessionID: sessionID, expected: actual, actual: expected)
                }
            }
            let ordinal = try Self.scalar(state, "SELECT COALESCE(MAX(ordinal), -1) + 1 FROM messages WHERE session_id = ?", [sessionID.rawValue]).flatMap(Int.init) ?? 0
            try Self.insertMessage(state, sessionID: sessionID, message: message, ordinal: ordinal)
        }
    }

    public func appendAssistantMessageAndBatch(sessionID: SessionID, message: Message, batch: ToolExchangeBatch, expectedRevision: UInt64? = nil) throws {
        let ordinal = try Self.nextMessageOrdinal(state, sessionID)
        try Self.transaction(state) {
            if let expected = expectedRevision {
                let actual = try Self.scalar(state, "SELECT revision FROM sessions WHERE session_id = ?", [sessionID.rawValue]).flatMap(UInt64.init) ?? 0
                guard actual == expected else {
                    throw StaleRunError(sessionID: sessionID, expected: actual, actual: expected)
                }
            }
            try Self.insertMessage(state, sessionID: sessionID, message: message, ordinal: ordinal)
            try Self.writeBatch(state, batch)
        }
    }

    public func appendToolResultMessageAndSettle(sessionID: SessionID, message: Message, batch: ToolExchangeBatch, expectedRevision: UInt64? = nil) throws {
        let ordinal = try Self.nextMessageOrdinal(state, sessionID)
        try Self.transaction(state) {
            if let expected = expectedRevision {
                let actual = try Self.scalar(state, "SELECT revision FROM sessions WHERE session_id = ?", [sessionID.rawValue]).flatMap(UInt64.init) ?? 0
                guard actual == expected else {
                    throw StaleRunError(sessionID: sessionID, expected: actual, actual: expected)
                }
            }
            try Self.insertMessage(state, sessionID: sessionID, message: message, ordinal: ordinal)
            try Self.writeBatch(state, batch)
        }
    }

    public func bumpRevision(sessionID: SessionID) throws -> UInt64 {
        try Self.transaction(state) {
            try Self.execute(state, "UPDATE sessions SET revision = revision + 1, updated_at = ? WHERE session_id = ?", [Self.now, sessionID.rawValue])
        }
        return try currentRevision(sessionID: sessionID)
    }

    public func currentRevision(sessionID: SessionID) throws -> UInt64 {
        try Self.scalar(state, "SELECT revision FROM sessions WHERE session_id = ?", [sessionID.rawValue]).flatMap(UInt64.init) ?? 0
    }

    public func revertLastTurn(sessionID: SessionID, bumpRevision: Bool = true) throws -> (revertedPrompt: String?, removedCount: Int) {
        let rows = try Self.rows(state, "SELECT message_id, ordinal, role FROM messages WHERE session_id = ? ORDER BY ordinal DESC", [sessionID.rawValue])
        guard let lastUserRow = rows.first(where: { $0[2] == MessageRole.user.rawValue }),
              let userOrdinal = Int(lastUserRow[1]) else {
            return (nil, 0)
        }
        let userMessageID = lastUserRow[0]
        let partRows = try Self.rows(state, "SELECT payload FROM message_parts WHERE message_id = ? ORDER BY ordinal LIMIT 1", [userMessageID])
        var revertedPrompt: String?
        if let partJSON = partRows.first?.first,
           let part = try? JSONDecoder().decode(SessionMessagePart.self, from: Data(partJSON.utf8)),
           case let .text(text) = part {
            revertedPrompt = text
        }

        let toDelete = rows.filter { (Int($0[1]) ?? -1) >= userOrdinal }.map { $0[0] }
        try Self.transaction(state) {
            for mID in toDelete {
                try Self.execute(state, "DELETE FROM message_parts WHERE message_id = ?", [mID])
                try Self.execute(state, "DELETE FROM tool_exchange_batches WHERE assistant_message_id = ? OR result_message_id = ?", [mID, mID])
                try Self.execute(state, "DELETE FROM messages WHERE message_id = ?", [mID])
            }
            try Self.execute(state, "DELETE FROM compaction_state WHERE session_id = ?", [sessionID.rawValue])
            try Self.execute(state, "DELETE FROM derived_context WHERE session_id = ?", [sessionID.rawValue])
            try Self.execute(state, "DELETE FROM file_mutation_journal WHERE session_id = ?", [sessionID.rawValue])
            if bumpRevision {
                try Self.execute(state, "UPDATE sessions SET revision = revision + 1, updated_at = ? WHERE session_id = ?", [Self.now, sessionID.rawValue])
            } else {
                try Self.execute(state, "UPDATE sessions SET updated_at = ? WHERE session_id = ?", [Self.now, sessionID.rawValue])
            }
        }
        return (revertedPrompt, toDelete.count)
    }

    public func deleteMessage(messageID: MessageID) throws {
        try Self.transaction(state) {
            try Self.execute(state, "DELETE FROM message_parts WHERE message_id = ?", [messageID.rawValue])
            try Self.execute(state, "DELETE FROM messages WHERE message_id = ?", [messageID.rawValue])
        }
    }

    public func clearCompactionAndDerived(sessionID: SessionID) throws {
        try Self.transaction(state) {
            try Self.execute(state, "DELETE FROM compaction_state WHERE session_id = ?", [sessionID.rawValue])
            try Self.execute(state, "DELETE FROM derived_context WHERE session_id = ?", [sessionID.rawValue])
        }
    }

    public func recordFileMutation(_ mutation: FileMutation) throws {
        let beforeB64 = mutation.beforeContent?.base64EncodedString() ?? ""
        let afterB64 = mutation.afterContent?.base64EncodedString() ?? ""
        try Self.execute(
            state,
            "INSERT INTO file_mutation_journal(session_id, turn_id, revision, tool_call_id, path, before_hash, before_content, after_hash, after_content, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                mutation.sessionID.rawValue,
                mutation.turnID.rawValue,
                mutation.revision,
                mutation.toolCallID.rawValue,
                mutation.path,
                mutation.beforeHash ?? "",
                beforeB64,
                mutation.afterHash ?? "",
                afterB64,
                mutation.createdAt.timeIntervalSince1970
            ]
        )
    }

    public func loadFileMutations(sessionID: SessionID) throws -> [FileMutation] {
        let rows = try Self.rows(
            state,
            "SELECT session_id, turn_id, revision, tool_call_id, path, before_hash, before_content, after_hash, after_content, created_at FROM file_mutation_journal WHERE session_id = ? ORDER BY id ASC",
            [sessionID.rawValue]
        )
        return rows.compactMap { row in
            guard row.count >= 10 else { return nil }
            let sID = SessionID(row[0])
            let tID = TurnID(row[1])
            let rev = UInt64(row[2]) ?? 0
            let cID = ToolCallID(row[3])
            let path = row[4]
            let beforeHash = row[5].isEmpty ? nil : row[5]
            let beforeContent = row[6].isEmpty ? nil : Data(base64Encoded: row[6])
            let afterHash = row[7].isEmpty ? nil : row[7]
            let afterContent = row[8].isEmpty ? nil : Data(base64Encoded: row[8])
            let created = Double(row[9]).map { Date(timeIntervalSince1970: $0) } ?? Date()
            return FileMutation(
                sessionID: sID,
                turnID: tID,
                revision: rev,
                toolCallID: cID,
                path: path,
                beforeHash: beforeHash,
                beforeContent: beforeContent,
                afterHash: afterHash,
                afterContent: afterContent,
                createdAt: created
            )
        }
    }

    public func deleteFileMutations(sessionID: SessionID) throws {
        try Self.execute(state, "DELETE FROM file_mutation_journal WHERE session_id = ?", [sessionID.rawValue])
    }

    public func loadSessions() throws -> [Session] {
        let sessions = try Self.rows(state, "SELECT session_id, project_id, kind, parent_session_id, root_session_id, spawned_by_run_id, spawned_by_tool_call_id, title, cwd_root_binding_id, cwd_relative_path, created_at, updated_at, revision FROM sessions WHERE project_id = ? ORDER BY created_at", [projectID.rawValue])
        return try sessions.map { row in
            let id = SessionID(row[0]); let messages = try loadMessages(sessionID: id)
            let rev = row.count >= 13 ? (UInt64(row[12]) ?? 0) : 0
            return Session(id: id, createdAt: Self.parseDate(row[10]), kind: SessionKind(rawValue: row[2]) ?? .primary, parentSessionID: row[3].isEmpty ? nil : SessionID(row[3]), rootSessionID: SessionID(row[4]), spawnedByRunID: row[5].isEmpty ? nil : AgentRunID(row[5]), spawnedByToolCallID: row[6].isEmpty ? nil : ToolCallID(row[6]), title: row[7].isEmpty ? nil : row[7], projectID: ProjectID(row[1]), cwdRootBindingID: RootBindingID(row[8]), cwdRelativePath: ProjectRelativePath(rawValue: row[9]), updatedAt: Self.parseDate(row[11]), revision: rev, messages: messages)
        }
    }

    public func loadSession(_ id: SessionID) throws -> Session? {
        let rows = try Self.rows(state, "SELECT session_id, project_id, kind, parent_session_id, root_session_id, spawned_by_run_id, spawned_by_tool_call_id, title, cwd_root_binding_id, cwd_relative_path, created_at, updated_at, revision FROM sessions WHERE session_id = ? AND project_id = ? LIMIT 1", [id.rawValue, projectID.rawValue])
        guard let row = rows.first else { return nil }
        let messages = try loadMessages(sessionID: id)
        let rev = row.count >= 13 ? (UInt64(row[12]) ?? 0) : 0
        return Session(id: id, createdAt: Self.parseDate(row[10]), kind: SessionKind(rawValue: row[2]) ?? .primary, parentSessionID: row[3].isEmpty ? nil : SessionID(row[3]), rootSessionID: SessionID(row[4]), spawnedByRunID: row[5].isEmpty ? nil : AgentRunID(row[5]), spawnedByToolCallID: row[6].isEmpty ? nil : ToolCallID(row[6]), title: row[7].isEmpty ? nil : row[7], projectID: ProjectID(row[1]), cwdRootBindingID: RootBindingID(row[8]), cwdRelativePath: ProjectRelativePath(rawValue: row[9]), updatedAt: Self.parseDate(row[11]), revision: rev, messages: messages)
    }

    public func loadAllGlobalSessions() throws -> [SessionSummary] {
        try Self.loadAllGlobalSessions(dataRoot: dataRoot)
    }

    public static func loadAllGlobalSessions(dataRoot: URL) throws -> [SessionSummary] {
        let catalogPath = dataRoot.appendingPathComponent("catalog.sqlite")
        guard FileManager.default.fileExists(atPath: catalogPath.path) else { return [] }
        guard let catalogDB = Self.openReadOnly(catalogPath) else { return [] }
        defer { sqlite3_close_v2(catalogDB) }

        let roots = try rows(catalogDB, "SELECT project_id, absolute_root FROM root_bindings WHERE kind = 'main' AND lifecycle_state = 'active'", [])
        var summaries: [SessionSummary] = []

        for row in roots {
            guard row.count >= 2 else { continue }
            let pID = row[0]
            let absRoot = row[1]
            let stateURL = dataRoot.appendingPathComponent("projects/\(pID)/state.sqlite")
            guard FileManager.default.fileExists(atPath: stateURL.path) else { continue }
            guard let stateDB = Self.openReadOnly(stateURL) else { continue }
            defer { sqlite3_close_v2(stateDB) }

            let query = """
            SELECT 
                s.session_id, 
                s.title, 
                s.created_at, 
                s.updated_at,
                COALESCE(m.msg_count, 0)
            FROM sessions s
            LEFT JOIN (
                SELECT session_id, COUNT(*) AS msg_count 
                FROM messages 
                GROUP BY session_id
            ) m ON s.session_id = m.session_id
            ORDER BY s.updated_at DESC
            """
            let sessionRows = (try? rows(stateDB, query, [])) ?? []
            for sRow in sessionRows {
                guard sRow.count >= 5 else { continue }
                let sID = sRow[0]
                var title = sRow[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let cDate = parseDate(sRow[2])
                let uDate = parseDate(sRow[3])
                let msgCount = Int(sRow[4]) ?? 0

                if title.isEmpty {
                    let firstUserPayload = try? scalar(stateDB, "SELECT payload FROM message_parts WHERE message_id IN (SELECT message_id FROM messages WHERE session_id = ? AND role = 'user' ORDER BY ordinal LIMIT 1) LIMIT 1", [sID])
                    if let firstUserPayload,
                       let data = firstUserPayload.data(using: .utf8),
                       let part = try? JSONDecoder().decode(SessionMessagePart.self, from: data) {
                        switch part {
                        case let .text(txt):
                            let clean = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                                .replacingOccurrences(of: "\n", with: " ")
                            title = clean.count > 50 ? String(clean.prefix(50)) + "..." : clean
                        default:
                            break
                        }
                    }
                }
                if title.isEmpty {
                    title = "未命名会话"
                }

                summaries.append(
                    SessionSummary(
                        sessionID: SessionID(sID),
                        title: title,
                        createdAt: cDate,
                        updatedAt: uDate,
                        turnCount: msgCount,
                        mode: .build,
                        reasoningEffort: .auto,
                        workingDirectory: absRoot,
                        messageCount: msgCount
                    )
                )
            }
        }
        summaries.sort(by: { $0.updatedAt > $1.updatedAt })
        return summaries
    }

    public static func findProjectDirectory(for sessionID: SessionID, dataRoot: URL) throws -> (projectID: ProjectID, absoluteRoot: String)? {
        let catalogPath = dataRoot.appendingPathComponent("catalog.sqlite")
        guard FileManager.default.fileExists(atPath: catalogPath.path) else { return nil }
        guard let catalogDB = Self.openReadOnly(catalogPath) else { return nil }
        defer { sqlite3_close_v2(catalogDB) }

        let roots = try rows(catalogDB, "SELECT project_id, absolute_root FROM root_bindings WHERE kind = 'main' AND lifecycle_state = 'active'", [])
        for row in roots {
            guard row.count >= 2 else { continue }
            let pID = row[0]
            let absRoot = row[1]
            let stateURL = dataRoot.appendingPathComponent("projects/\(pID)/state.sqlite")
            guard FileManager.default.fileExists(atPath: stateURL.path) else { continue }
            guard let stateDB = Self.openReadOnly(stateURL) else { continue }
            defer { sqlite3_close_v2(stateDB) }
            let exists = (try? scalar(stateDB, "SELECT 1 FROM sessions WHERE session_id = ? LIMIT 1", [sessionID.rawValue])) != nil
            if exists {
                return (ProjectID(pID), absRoot)
            }
        }
        return nil
    }

    public func loadGlobalSession(_ id: SessionID) throws -> Session? {
        if let local = try loadSessions().first(where: { $0.id == id }) {
            return local
        }
        guard let info = try Self.findProjectDirectory(for: id, dataRoot: dataRoot) else {
            return nil
        }
        let otherStateURL = dataRoot.appendingPathComponent("projects/\(info.projectID.rawValue)/state.sqlite")
        guard let otherDB = Self.openReadOnly(otherStateURL) else { return nil }
        defer { sqlite3_close_v2(otherDB) }

        let rows = try Self.rows(otherDB, "SELECT session_id, project_id, kind, parent_session_id, root_session_id, spawned_by_run_id, spawned_by_tool_call_id, title, cwd_root_binding_id, cwd_relative_path, created_at, updated_at FROM sessions WHERE session_id = ? LIMIT 1", [id.rawValue])
        guard let row = rows.first, row.count >= 12 else { return nil }
        let messages = try Self.rows(otherDB, "SELECT message_id, role, created_at FROM messages WHERE session_id = ? ORDER BY ordinal", [id.rawValue]).map { mRow -> Message in
            let parts = try Self.rows(otherDB, "SELECT payload FROM message_parts WHERE message_id = ? ORDER BY ordinal", [mRow[0]]).map { try JSONDecoder().decode(SessionMessagePart.self, from: Data($0[0].utf8)) }
            guard let role = MessageRole(rawValue: mRow[1]) else { throw PersistenceError.sqlite("invalid message role") }
            return Message(id: MessageID(mRow[0]), role: role, parts: parts, createdAt: Self.parseDate(mRow[2]))
        }
        return Session(
            id: id,
            createdAt: Self.parseDate(row[10]),
            kind: SessionKind(rawValue: row[2]) ?? .primary,
            parentSessionID: row[3].isEmpty ? nil : SessionID(row[3]),
            rootSessionID: SessionID(row[4]),
            spawnedByRunID: row[5].isEmpty ? nil : AgentRunID(row[5]),
            spawnedByToolCallID: row[6].isEmpty ? nil : ToolCallID(row[6]),
            title: row[7].isEmpty ? nil : row[7],
            projectID: ProjectID(row[1]),
            cwdRootBindingID: RootBindingID(row[8]),
            cwdRelativePath: ProjectRelativePath(rawValue: row[9]),
            updatedAt: Self.parseDate(row[11]),
            messages: messages
        )
    }

    public func loadMessages(sessionID: SessionID) throws -> [Message] {
        try Self.rows(state, "SELECT message_id, role, created_at FROM messages WHERE session_id = ? ORDER BY ordinal", [sessionID.rawValue]).map { row in
            let parts = (try? Self.rows(state, "SELECT payload FROM message_parts WHERE message_id = ? ORDER BY ordinal", [row[0]]))?.compactMap { partRow -> SessionMessagePart? in
                guard let rawStr = partRow.first, !rawStr.isEmpty else { return nil }
                if let decoded = try? JSONDecoder().decode(SessionMessagePart.self, from: Data(rawStr.utf8)) {
                    return decoded
                }
                return .text(rawStr)
            } ?? []
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

    public func loadAgentRun(_ runID: AgentRunID) throws -> AgentRunInfo? {
        let query = "SELECT run_id, session_id, project_id, parent_run_id, root_run_id, agent_kind, status, provider_id, account_id, profile_id, model_id, reasoning, context_profile, started_at, finished_at, latest_activity_at, usage_json, error_json, title FROM agent_runs WHERE run_id = ? LIMIT 1"
        return try Self.rows(state, query, [runID.rawValue]).compactMap { row in
            guard let kind = SessionKind(rawValue: row[5]), let status = AgentRunStatus(rawValue: row[6]) else { return nil }
            return AgentRunInfo(runID: AgentRunID(row[0]), sessionID: SessionID(row[1]), projectID: ProjectID(row[2]), parentRunID: row[3].isEmpty ? nil : AgentRunID(row[3]), rootRunID: AgentRunID(row[4]), agentKind: kind, status: status, modelSelection: ModelSelection(providerID: row[7], accountID: row[8].isEmpty ? nil : row[8], profileID: row[9].isEmpty ? nil : row[9], modelID: row[10], reasoning: row[11].isEmpty ? nil : row[11], contextProfile: row[12].isEmpty ? nil : row[12]), startedAt: row[13].isEmpty ? nil : Self.parseDate(row[13]), finishedAt: row[14].isEmpty ? nil : Self.parseDate(row[14]), latestActivityAt: Self.parseDate(row[15]), error: row[17].isEmpty ? nil : try? JSONDecoder().decode(CoreError.self, from: Data(row[17].utf8)), usage: (try? JSONDecoder().decode(AgentRunUsage.self, from: Data(row[16].utf8))) ?? AgentRunUsage(), title: row[18].isEmpty ? nil : row[18])
        }.first
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
        try Self.execute(state, "INSERT INTO sessions(session_id, project_id, kind, parent_session_id, root_session_id, spawned_by_run_id, spawned_by_tool_call_id, title, cwd_root_binding_id, cwd_relative_path, created_at, updated_at, revision, metadata) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '{}')", [session.id.rawValue, projectID.rawValue, session.kind.rawValue, session.parentSessionID?.rawValue ?? NSNull(), session.rootSessionID.rawValue, session.spawnedByRunID?.rawValue ?? NSNull(), session.spawnedByToolCallID?.rawValue ?? NSNull(), session.title ?? NSNull(), root.rawValue, session.cwdRelativePath.rawValue, Self.date(session.createdAt), Self.date(session.createdAt), String(session.revision)])
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
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            throw PersistenceError.sqlite("open \(url.lastPathComponent)")
        }
        sqlite3_busy_timeout(db, 10_000)
        return db
    }
    private static func configure(_ db: OpaquePointer) throws { try script(db, "PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA busy_timeout = 10000") }
    /// Read-only opens never run `configure()`, so without an explicit busy timeout a
    /// concurrent WAL checkpoint surfaces immediately as "database is locked".
    private static func openReadOnly(_ url: URL) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close_v2(handle) }
            return nil
        }
        sqlite3_busy_timeout(db, 10_000)
        return db
    }
    private static func migrate(_ db: OpaquePointer, create: () throws -> Void, upgrade: () throws -> Void, upgradeV3: () throws -> Void, upgradeV4: () throws -> Void, upgradeV5: () throws -> Void, upgradeV6: () throws -> Void, upgradeV7: () throws -> Void) throws {
        let version = Int(try scalar(db, "PRAGMA user_version", []) ?? "0") ?? 0
        try transaction(db) { try MigrationRunner.migrate(from: version, applyV0ToV1: create, applyV1ToV2: upgrade, applyV2ToV3: upgradeV3, applyV3ToV4: upgradeV4, applyV4ToV5: upgradeV5, applyV5ToV6: upgradeV6, applyV6ToV7: upgradeV7) }
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
    private static func upgradeStateSchemaV7(_ db: OpaquePointer) throws {
        try script(db, """
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
        """)

        let columns = (try? rows(db, "PRAGMA table_info(workflow_tasks)", [])) ?? []
        if !columns.contains(where: { $0.count > 1 && $0[1] == "task_id" }) {
            _ = try? script(db, "ALTER TABLE workflow_tasks ADD COLUMN task_id TEXT REFERENCES tasks(task_id)")
        }

        _ = try? script(db, """
        INSERT OR IGNORE INTO workspaces(workspace_id, project_id, kind, root_binding_id, base_revision, isolation_state, state, created_at, updated_at)
        SELECT 'ws-' || s.project_id, s.project_id, 'main', s.cwd_root_binding_id, 0, 'shared', 'active', MIN(s.created_at), MIN(s.updated_at)
        FROM sessions s
        GROUP BY s.project_id;
        """)

        _ = try? script(db, """
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
        """)

        try script(db, "PRAGMA user_version = 7")
    }

    public static func downgradeStateSchemaV7ToV6(_ db: OpaquePointer) throws {
        try script(db, """
        DROP TABLE IF EXISTS capability_audit;
        DROP TABLE IF EXISTS capability_grants;
        DROP TABLE IF EXISTS task_events;
        DROP TABLE IF EXISTS task_tool_states;
        DROP TABLE IF EXISTS task_artifacts;
        DROP TABLE IF EXISTS tasks;
        DROP TABLE IF EXISTS workspaces;
        PRAGMA user_version = 6;
        """)
    }
    private static func createStateSchema(_ db: OpaquePointer) throws {
        try script(db, "CREATE TABLE IF NOT EXISTS sessions(session_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, cwd_root_binding_id TEXT NOT NULL, cwd_relative_path TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0, metadata TEXT NOT NULL); CREATE TABLE IF NOT EXISTS messages(message_id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(session_id), ordinal INTEGER NOT NULL, role TEXT NOT NULL, created_at TEXT NOT NULL, UNIQUE(session_id, ordinal)); CREATE TABLE IF NOT EXISTS message_parts(message_id TEXT NOT NULL REFERENCES messages(message_id), ordinal INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(message_id, ordinal)); CREATE TABLE IF NOT EXISTS tool_exchange_batches(batch_id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(session_id), assistant_message_id TEXT NOT NULL, result_message_id TEXT, provider_step INTEGER NOT NULL, state TEXT NOT NULL, estimated_tokens INTEGER NOT NULL, tool_calls_json TEXT NOT NULL, tool_results_json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS derived_context(derived_page_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, session_id TEXT NOT NULL REFERENCES sessions(session_id), source_kind TEXT NOT NULL, content_hash TEXT NOT NULL, inline_content TEXT, blob_ref TEXT, message_id TEXT, token_estimate INTEGER NOT NULL, created_at TEXT NOT NULL, version INTEGER NOT NULL, provenance_json TEXT NOT NULL, metadata_json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS compaction_state(session_id TEXT PRIMARY KEY REFERENCES sessions(session_id), generation INTEGER NOT NULL, residency_json TEXT NOT NULL, updated_at TEXT NOT NULL); CREATE TABLE IF NOT EXISTS project_files(file_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, root_binding_id TEXT NOT NULL, relative_path TEXT NOT NULL, content_hash TEXT NOT NULL, version TEXT NOT NULL, state TEXT NOT NULL, time_created TEXT NOT NULL, time_updated TEXT NOT NULL, time_last_seen TEXT, UNIQUE(root_binding_id, relative_path)); CREATE TABLE IF NOT EXISTS project_pages(page_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, file_id TEXT NOT NULL, start_line INTEGER NOT NULL, end_line INTEGER NOT NULL, content_hash TEXT NOT NULL, version TEXT NOT NULL, source_type TEXT NOT NULL, characters INTEGER NOT NULL, metadata TEXT NOT NULL); CREATE TABLE IF NOT EXISTS cached_symbols(symbol_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, file_id TEXT NOT NULL, name TEXT NOT NULL, qualified_name TEXT NOT NULL, kind TEXT NOT NULL, line INTEGER NOT NULL, page_id TEXT NOT NULL); CREATE TABLE IF NOT EXISTS cached_references(reference_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, source_file_id TEXT NOT NULL, target_file_id TEXT, source_line INTEGER NOT NULL, target_name TEXT NOT NULL, kind TEXT NOT NULL, resolution TEXT NOT NULL); CREATE TABLE IF NOT EXISTS cached_dependencies(project_id TEXT NOT NULL, source_file_id TEXT NOT NULL, target_file_id TEXT, kind TEXT NOT NULL, evidence_id TEXT NOT NULL, PRIMARY KEY(project_id, source_file_id, evidence_id)); CREATE TABLE IF NOT EXISTS project_l2(page_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, score REAL NOT NULL, use_count INTEGER NOT NULL, last_used INTEGER NOT NULL, version TEXT NOT NULL); CREATE TABLE IF NOT EXISTS session_l2(derived_page_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, use_count INTEGER NOT NULL, last_used INTEGER NOT NULL, version INTEGER NOT NULL); PRAGMA user_version = 1")
        _ = try? script(db, "ALTER TABLE sessions ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
    }
    private static func decodeRoot(_ row: [String]) -> RootBinding? { guard row.count == 10, let kind = RootBindingKind(rawValue: row[2]), let state = RootBindingLifecycleState(rawValue: row[6]) else { return nil }; return RootBinding(id: RootBindingID(row[0]), projectID: ProjectID(row[1]), kind: kind, absoluteRoot: URL(fileURLWithPath: row[3]), parentBindingID: row[4].isEmpty ? nil : RootBindingID(row[4]), bindingRevision: Int(row[5]) ?? 0, lifecycleState: state, createdAt: parseDate(row[7]), updatedAt: parseDate(row[8]), lastSeenAt: row[9].isEmpty ? nil : parseDate(row[9])) }
    private static func decodeFile(_ row: [String]) -> ProjectFileBinding? { guard row.count == 10 else { return nil }; return ProjectFileBinding(id: ProjectFileID(row[0]), projectID: ProjectID(row[1]), rootBindingID: RootBindingID(row[2]), relativePath: ProjectRelativePath(rawValue: row[3]), contentHash: row[4], version: row[5], state: row[6], createdAt: parseDate(row[7]), updatedAt: parseDate(row[8]), lastSeenAt: row[9].isEmpty ? nil : parseDate(row[9])) }
    private static func ensureAllExistingProjectsHaveSessionRevision(dataRoot: URL) {
        let projectsDir = dataRoot.appendingPathComponent("projects", isDirectory: true)
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for dir in projectDirs {
            let stateURL = dir.appendingPathComponent("state.sqlite")
            guard FileManager.default.fileExists(atPath: stateURL.path) else { continue }
            if let db = try? open(stateURL) {
                _ = try? script(db, "ALTER TABLE sessions ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
                sqlite3_close_v2(db)
            }
        }
    }

    public func saveWorkspace(workspaceID: WorkspaceID, projectID: String, kind: String = "main", originWorkspaceID: WorkspaceID? = nil, rootBindingID: String? = nil, baseRevision: Int = 0, isolationState: String = "shared", state: String = "active") throws {
        try Self.execute(self.state, """
        INSERT OR REPLACE INTO workspaces(workspace_id, project_id, kind, origin_workspace_id, root_binding_id, base_revision, isolation_state, state, created_at, updated_at)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            workspaceID.rawValue,
            projectID,
            kind,
            originWorkspaceID?.rawValue ?? NSNull(),
            rootBindingID ?? NSNull(),
            String(baseRevision),
            isolationState,
            state,
            Self.now,
            Self.now
        ])
    }

    public func workspace(workspaceID: WorkspaceID) throws -> (workspaceID: WorkspaceID, projectID: String, kind: String, originWorkspaceID: WorkspaceID?, rootBindingID: String?, baseRevision: Int, isolationState: String, state: String)? {
        let rows = try Self.rows(self.state, "SELECT workspace_id, project_id, kind, origin_workspace_id, root_binding_id, base_revision, isolation_state, state FROM workspaces WHERE workspace_id = ?", [workspaceID.rawValue])
        guard let row = rows.first, row.count >= 8 else { return nil }
        return (
            workspaceID: WorkspaceID(row[0]),
            projectID: row[1],
            kind: row[2],
            originWorkspaceID: row[3].isEmpty ? nil : WorkspaceID(row[3]),
            rootBindingID: row[4].isEmpty ? nil : row[4],
            baseRevision: Int(row[5]) ?? 0,
            isolationState: row[6],
            state: row[7]
        )
    }

    public func workspaces(projectID: String? = nil) throws -> [(workspaceID: WorkspaceID, projectID: String, kind: String, originWorkspaceID: WorkspaceID?, rootBindingID: String?, baseRevision: Int, isolationState: String, state: String)] {
        let sql: String
        let params: [Any]
        if let projectID = projectID {
            sql = "SELECT workspace_id, project_id, kind, origin_workspace_id, root_binding_id, base_revision, isolation_state, state FROM workspaces WHERE project_id = ? ORDER BY created_at ASC"
            params = [projectID]
        } else {
            sql = "SELECT workspace_id, project_id, kind, origin_workspace_id, root_binding_id, base_revision, isolation_state, state FROM workspaces ORDER BY created_at ASC"
            params = []
        }
        return try Self.rows(self.state, sql, params).compactMap { row in
            guard row.count >= 8 else { return nil }
            return (
                workspaceID: WorkspaceID(row[0]),
                projectID: row[1],
                kind: row[2],
                originWorkspaceID: row[3].isEmpty ? nil : WorkspaceID(row[3]),
                rootBindingID: row[4].isEmpty ? nil : row[4],
                baseRevision: Int(row[5]) ?? 0,
                isolationState: row[6],
                state: row[7]
            )
        }
    }
}

extension SQLitePersistenceStore: TaskPersistence {
    public func saveCapsule(_ capsule: TaskCapsule) throws {
        try Self.transaction(state) {
            try Self.execute(state, "INSERT OR IGNORE INTO workspaces(workspace_id, project_id, kind, root_binding_id, base_revision, isolation_state, state, created_at, updated_at) VALUES(?, ?, 'main', NULL, 0, 'shared', 'active', ?, ?)", [capsule.workspaceID.rawValue, capsule.projectID, Self.date(capsule.createdAt), Self.date(capsule.updatedAt)])

            try Self.execute(state, "INSERT OR IGNORE INTO sessions(session_id, project_id, cwd_root_binding_id, cwd_relative_path, created_at, updated_at, revision, metadata) VALUES(?, ?, 'main', '', ?, ?, 0, '{}')", [capsule.sessionID.rawValue, capsule.projectID, Self.date(capsule.createdAt), Self.date(capsule.updatedAt)])

            let criteriaJSON = String(decoding: (try? JSONEncoder().encode(capsule.successCriteria)) ?? Data("[]".utf8), as: UTF8.self)
            let resumeJSON: Any = capsule.resumePoint.flatMap { pt in
                (try? JSONEncoder().encode(pt)).flatMap { String(decoding: $0, as: UTF8.self) }
            } ?? NSNull()
            let modelJSON: Any = (try? JSONEncoder().encode(capsule.modelSelection)).flatMap { String(decoding: $0, as: UTF8.self) } ?? NSNull()

            try Self.execute(state, """
            INSERT OR REPLACE INTO tasks(
                task_id, session_id, workspace_id, parent_task_id, forked_from_task_id,
                root_run_id, project_id, state, waiting_reason, objective,
                success_criteria_json, resume_point_json, risk_state, revision,
                model_selection_json, created_at, updated_at, latest_activity_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                capsule.taskID.rawValue,
                capsule.sessionID.rawValue,
                capsule.workspaceID.rawValue,
                capsule.parentTaskID?.rawValue ?? NSNull(),
                capsule.forkedFromTaskID?.rawValue ?? NSNull(),
                capsule.rootRunID?.rawValue ?? NSNull(),
                capsule.projectID,
                capsule.state.rawValue,
                capsule.waitingReason?.rawValue ?? NSNull(),
                capsule.objective,
                criteriaJSON,
                resumeJSON,
                capsule.riskState.level,
                String(capsule.revision),
                modelJSON,
                Self.date(capsule.createdAt),
                Self.date(capsule.updatedAt),
                Self.date(capsule.updatedAt)
            ])

            try Self.execute(state, "DELETE FROM task_artifacts WHERE task_id = ?", [capsule.taskID.rawValue])
            for artifact in capsule.artifacts {
                let metaJSON = String(decoding: (try? JSONEncoder().encode(artifact.metadata)) ?? Data("{}".utf8), as: UTF8.self)
                try Self.execute(state, "INSERT INTO task_artifacts(task_id, ordinal, kind, ref, metadata_json, created_at) VALUES(?, ?, ?, ?, ?, ?)", [capsule.taskID.rawValue, String(artifact.ordinal), artifact.kind, artifact.ref, metaJSON, Self.date(artifact.createdAt)])
            }

            try Self.execute(state, "DELETE FROM task_tool_states WHERE task_id = ?", [capsule.taskID.rawValue])
            for toolState in capsule.toolStates {
                let payloadJSON = String(decoding: (try? JSONEncoder().encode(toolState.payload)) ?? Data("{}".utf8), as: UTF8.self)
                try Self.execute(state, "INSERT INTO task_tool_states(task_id, tool_call_id, state, payload_json, updated_at) VALUES(?, ?, ?, ?, ?)", [capsule.taskID.rawValue, toolState.toolCallID, toolState.state, payloadJSON, Self.date(toolState.updatedAt)])
            }
        }
    }

    public func loadCapsule(taskID: TaskID) throws -> TaskCapsule? {
        let rows = try Self.rows(state, """
        SELECT task_id, session_id, workspace_id, parent_task_id, forked_from_task_id,
               root_run_id, project_id, state, waiting_reason, objective,
               success_criteria_json, resume_point_json, risk_state, revision,
               model_selection_json, created_at, updated_at, latest_activity_at
        FROM tasks WHERE task_id = ?
        """, [taskID.rawValue])
        guard let row = rows.first, row.count >= 17 else { return nil }
        return try decodeCapsule(row: row)
    }

    public func listCapsules(sessionID: SessionID? = nil) throws -> [TaskCapsule] {
        let sql: String
        let params: [Any]
        if let sessionID = sessionID {
            sql = """
            SELECT task_id, session_id, workspace_id, parent_task_id, forked_from_task_id,
                   root_run_id, project_id, state, waiting_reason, objective,
                   success_criteria_json, resume_point_json, risk_state, revision,
                   model_selection_json, created_at, updated_at, latest_activity_at
            FROM tasks WHERE session_id = ? ORDER BY created_at ASC
            """
            params = [sessionID.rawValue]
        } else {
            sql = """
            SELECT task_id, session_id, workspace_id, parent_task_id, forked_from_task_id,
                   root_run_id, project_id, state, waiting_reason, objective,
                   success_criteria_json, resume_point_json, risk_state, revision,
                   model_selection_json, created_at, updated_at, latest_activity_at
            FROM tasks ORDER BY created_at ASC
            """
            params = []
        }
        return try Self.rows(state, sql, params).compactMap { try? decodeCapsule(row: $0) }
    }

    public func recordEvent(taskID: TaskID, event: String, fromState: TaskState?, toState: TaskState, payload: [String: String]) throws {
        let payloadJSON = String(decoding: (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8), as: UTF8.self)
        try Self.execute(state, """
        INSERT INTO task_events(task_id, event, from_state, to_state, payload_json, correlation_id, created_at)
        VALUES(?, ?, ?, ?, ?, NULL, ?)
        """, [
            taskID.rawValue,
            event,
            fromState?.rawValue ?? NSNull(),
            toState.rawValue,
            payloadJSON,
            Self.now
        ])
    }

    public func loadEvents(taskID: TaskID) throws -> [TaskEventPayload] {
        let rows = try Self.rows(state, "SELECT seq, task_id, event, from_state, to_state, payload_json, correlation_id, created_at FROM task_events WHERE task_id = ? ORDER BY seq ASC", [taskID.rawValue])
        return rows.compactMap { row in
            guard row.count >= 8 else { return nil }
            let seq = Int64(row[0])
            let taskID = TaskID(row[1])
            let event = row[2]
            let fromState = row[3].isEmpty ? nil : TaskState(rawValue: row[3])
            let toState = TaskState(rawValue: row[4]) ?? .unknown
            let payload = (try? JSONDecoder().decode([String: String].self, from: Data(row[5].utf8))) ?? [:]
            let correlationID = row[6].isEmpty ? nil : row[6]
            let createdAt = Self.parseDate(row[7])
            return TaskEventPayload(seq: seq, taskID: taskID, event: event, fromState: fromState, toState: toState, payload: payload, correlationID: correlationID, createdAt: createdAt)
        }
    }

    private func decodeCapsule(row: [String]) throws -> TaskCapsule {
        let taskID = TaskID(row[0])
        let sessionID = SessionID(row[1])
        let workspaceID = WorkspaceID(row[2])
        let parentTaskID = row[3].isEmpty ? nil : TaskID(row[3])
        let forkedFromTaskID = row[4].isEmpty ? nil : TaskID(row[4])
        let rootRunID = row[5].isEmpty ? nil : AgentRunID(row[5])
        let projectID = row[6]
        let taskState = TaskState(rawValue: row[7]) ?? .unknown
        let waitingReason = row[8].isEmpty ? nil : WaitingReason(rawValue: row[8])
        let objective = row[9]
        let criteria = (try? JSONDecoder().decode([SuccessCriterion].self, from: Data(row[10].utf8))) ?? []
        let resumePoint = row[11].isEmpty ? nil : (try? JSONDecoder().decode(ResumePoint.self, from: Data(row[11].utf8)))
        let riskState = RiskState(level: row[12].isEmpty ? "low" : row[12])
        let revision = Int(row[13]) ?? 0
        let modelSelection = row[14].isEmpty ? [:] : ((try? JSONDecoder().decode([String: String].self, from: Data(row[14].utf8))) ?? [:])
        let createdAt = Self.parseDate(row[15])
        let updatedAt = Self.parseDate(row[16])

        let artRows = try Self.rows(self.state, "SELECT ordinal, kind, ref, metadata_json, created_at FROM task_artifacts WHERE task_id = ? ORDER BY ordinal ASC", [taskID.rawValue])
        let artifacts = artRows.compactMap { aRow -> TaskArtifact? in
            guard aRow.count >= 5 else { return nil }
            let ordinal = Int(aRow[0]) ?? 0
            let kind = aRow[1]
            let meta = (try? JSONDecoder().decode([String: String].self, from: Data(aRow[3].utf8))) ?? [:]
            return TaskArtifact(ordinal: ordinal, kind: kind, ref: aRow[2], metadata: meta, createdAt: Self.parseDate(aRow[4]))
        }

        let tsRows = try Self.rows(self.state, "SELECT tool_call_id, state, payload_json, updated_at FROM task_tool_states WHERE task_id = ?", [taskID.rawValue])
        let toolStates = tsRows.compactMap { tRow -> ToolExecutionState? in
            guard tRow.count >= 4 else { return nil }
            let payload = (try? JSONDecoder().decode([String: String].self, from: Data(tRow[2].utf8))) ?? [:]
            return ToolExecutionState(toolCallID: tRow[0], state: tRow[1], payload: payload, updatedAt: Self.parseDate(tRow[3]))
        }

        return TaskCapsule(
            taskID: taskID,
            parentTaskID: parentTaskID,
            forkedFromTaskID: forkedFromTaskID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            rootRunID: rootRunID,
            projectID: projectID,
            objective: objective,
            successCriteria: criteria,
            state: taskState,
            waitingReason: waitingReason,
            resumePoint: resumePoint,
            toolStates: toolStates,
            artifacts: artifacts,
            riskState: riskState,
            revision: revision,
            modelSelection: modelSelection,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
