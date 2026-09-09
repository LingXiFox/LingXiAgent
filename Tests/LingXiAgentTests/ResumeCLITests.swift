import Foundation
import Testing
import SQLite3
@testable import LingXiApplication
@testable import LingXiProtocol

@Suite struct ResumeCLITests {

    private func createTestDatabase(at root: URL, projects: [(id: String, root: String, sessions: [(id: String, title: String?, date: Double, userPrompt: String?, msgCount: Int)])]) throws {
        let catalogURL = root.appendingPathComponent("catalog.sqlite")
        var catalogDB: OpaquePointer?
        guard sqlite3_open(catalogURL.path, &catalogDB) == SQLITE_OK, let catalogDB else {
            Issue.record("Failed to open catalog db")
            return
        }
        defer { sqlite3_close(catalogDB) }

        sqlite3_exec(catalogDB, """
        CREATE TABLE IF NOT EXISTS projects(project_id TEXT PRIMARY KEY, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS root_bindings(binding_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, kind TEXT NOT NULL, absolute_root TEXT NOT NULL, parent_binding_id TEXT, binding_revision INTEGER NOT NULL, lifecycle_state TEXT NOT NULL, time_created TEXT NOT NULL, time_updated TEXT NOT NULL, time_last_seen TEXT);
        """, nil, nil, nil)

        let projectsDir = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        for p in projects {
            let insertProj = "INSERT INTO projects VALUES ('\(p.id)', '0', '0')"
            sqlite3_exec(catalogDB, insertProj, nil, nil, nil)

            let insertRoot = "INSERT INTO root_bindings VALUES ('\(p.id)-bind', '\(p.id)', 'main', '\(p.root)', NULL, 1, 'active', '0', '0', NULL)"
            sqlite3_exec(catalogDB, insertRoot, nil, nil, nil)

            let pDir = projectsDir.appendingPathComponent(p.id, isDirectory: true)
            try FileManager.default.createDirectory(at: pDir, withIntermediateDirectories: true)
            let stateURL = pDir.appendingPathComponent("state.sqlite")

            var stateDB: OpaquePointer?
            guard sqlite3_open(stateURL.path, &stateDB) == SQLITE_OK, let stateDB else {
                Issue.record("Failed to open state db for \(p.id)")
                continue
            }
            defer { sqlite3_close(stateDB) }

            sqlite3_exec(stateDB, """
            CREATE TABLE IF NOT EXISTS sessions(session_id TEXT PRIMARY KEY, project_id TEXT, parent_session_id TEXT, root_session_id TEXT, kind TEXT, spawned_by_run_id TEXT, spawned_by_tool_call_id TEXT, title TEXT, created_at TEXT, updated_at TEXT);
            CREATE TABLE IF NOT EXISTS messages(message_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, ordinal INTEGER NOT NULL, role TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS message_parts(message_id TEXT NOT NULL, ordinal INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(message_id, ordinal));
            """, nil, nil, nil)

            for s in p.sessions {
                let titleVal = s.title != nil ? "'\(s.title!)'" : "NULL"
                let insertSession = "INSERT INTO sessions(session_id, project_id, title, created_at, updated_at) VALUES ('\(s.id)', '\(p.id)', \(titleVal), '\(s.date)', '\(s.date)')"
                sqlite3_exec(stateDB, insertSession, nil, nil, nil)

                for mIndex in 0..<s.msgCount {
                    let mID = "\(s.id)-msg-\(mIndex)"
                    let role = (mIndex == 0) ? "user" : "assistant"
                    let insertMsg = "INSERT INTO messages(message_id, session_id, ordinal, role, created_at) VALUES ('\(mID)', '\(s.id)', \(mIndex), '\(role)', '\(s.date)')"
                    sqlite3_exec(stateDB, insertMsg, nil, nil, nil)

                    if mIndex == 0, let prompt = s.userPrompt {
                        let part = SessionMessagePart.text(prompt)
                        let data = (try? JSONEncoder().encode(part)) ?? Data()
                        let payload = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "''")
                        let insertPart = "INSERT INTO message_parts(message_id, ordinal, payload) VALUES ('\(mID)', 0, '\(payload)')"
                        sqlite3_exec(stateDB, insertPart, nil, nil, nil)
                    }
                }
            }
        }
    }

    @Test func resumeWithNoSessionsReturnsEmptyMessage() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-resume-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let action = try await ResumeCLI.run(arguments: ["resume"], dataRoot: tempDir)
        #expect(action == .output("未找到任何历史会话记录。"))
    }

    @Test func resumeWithNotFoundExplicitIDReturnsError() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-resume-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let action = try await ResumeCLI.run(arguments: ["resume", "nonexistent"], dataRoot: tempDir)
        #expect(action == .output("未找到匹配 ID 为「nonexistent」的历史会话。"))
    }

    @Test func resumeWithMultipleWorkspacesGroupsCurrentDirectoryFirst() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-resume-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let currentCwd = FileManager.default.currentDirectoryPath
        let otherDir = "/Volumes/External/OtherProject"

        try createTestDatabase(at: tempDir, projects: [
            (
                id: "proj-other",
                root: otherDir,
                sessions: [
                    (id: "other-sess-12345678", title: "外部工程特定任务", date: 1725900000, userPrompt: nil, msgCount: 5)
                ]
            ),
            (
                id: "proj-current",
                root: currentCwd,
                sessions: [
                    (id: "curr-sess-abcdef12", title: nil, date: 1725800000, userPrompt: "请帮我重构网络服务模块", msgCount: 2)
                ]
            )
        ])

        let action = try await ResumeCLI.run(arguments: ["resume"], dataRoot: tempDir)
        guard case let .output(rendered) = action else {
            Issue.record("Expected output action")
            return
        }

        #expect(rendered.contains("历史交互会话列表 (按工作目录分类展示"))
        #expect(rendered.contains("📂 [当前工作目录] \(currentCwd)"))
        #expect(rendered.contains("📂 \(otherDir)"))
        #expect(rendered.contains("外部工程特定任务"))
        #expect(rendered.contains("请帮我重构网络服务模块"))

        // 验证当前工作目录排在外部工程之前
        let currentPos = rendered.range(of: "[当前工作目录]")?.lowerBound
        let otherPos = rendered.range(of: "📂 \(otherDir)")?.lowerBound
        #expect(currentPos != nil)
        #expect(otherPos != nil)
        if let cp = currentPos, let op = otherPos {
            #expect(cp < op)
        }
    }

    @Test func resumeWithPrefixMatchingReturnsLaunchWithDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-resume-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let otherDir = "/Volumes/External/OtherProject"
        try createTestDatabase(at: tempDir, projects: [
            (
                id: "proj-other",
                root: otherDir,
                sessions: [
                    (id: "other-sess-12345678", title: "外部工程特定任务", date: 1725900000, userPrompt: nil, msgCount: 5)
                ]
            )
        ])

        // 前缀匹配短 ID
        let action = try await ResumeCLI.run(arguments: ["resume", "other-sess"], dataRoot: tempDir)
        #expect(action == .launch(sessionID: "other-sess-12345678", workingDirectory: otherDir))
    }

    @Test func resumeWithLastPrioritizesCurrentDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-resume-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let currentCwd = FileManager.default.currentDirectoryPath
        let otherDir = "/Volumes/External/OtherProject"

        // 即使 otherDir 的日期更新，--last 依然优先选择当前目录
        try createTestDatabase(at: tempDir, projects: [
            (
                id: "proj-other",
                root: otherDir,
                sessions: [
                    (id: "other-newer-sess", title: "外部工程新会话", date: 1725999999, userPrompt: nil, msgCount: 1)
                ]
            ),
            (
                id: "proj-current",
                root: currentCwd,
                sessions: [
                    (id: "curr-sess-older", title: "当前工程会话", date: 1725888888, userPrompt: nil, msgCount: 3)
                ]
            )
        ])

        let action = try await ResumeCLI.run(arguments: ["resume", "--last"], dataRoot: tempDir)
        #expect(action == .launch(sessionID: "curr-sess-older", workingDirectory: currentCwd))
    }
}
