import Foundation
import LingXiProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum ResumeCLI {

    public enum Action: Sendable, Equatable {
        case launch(sessionID: String, workingDirectory: String?)
        case output(String)
    }

    public static func run(
        arguments: [String],
        dataRoot: URL? = nil
    ) async throws -> Action {
        var args = arguments
        if args.first == "resume" {
            args.removeFirst()
        }

        let root: URL
        if let dataRoot {
            root = dataRoot
        } else if let envRoot = ProcessInfo.processInfo.environment["LINGXI_DATA_ROOT"], !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            root = URL(fileURLWithPath: envRoot, isDirectory: true).standardizedFileURL
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lingxiagent", isDirectory: true).standardizedFileURL
        }

        let currentCwd = FileManager.default.currentDirectoryPath
        let sessions = listStoredSessionsFromSQLite(dataRoot: root)

        if args.contains("--last") {
            // 优先选择当前工作目录的最新会话，若无则选全局最新会话
            let currentSessions = sessions.filter { $0.workingDirectory == currentCwd }
            guard let latest = currentSessions.first ?? sessions.first else {
                return .output("未找到可恢复的历史会话。")
            }
            return .launch(sessionID: latest.id, workingDirectory: latest.workingDirectory)
        }

        if let explicitID = args.first, !explicitID.hasPrefix("-") {
            // 支持完整 ID 或前缀匹配
            let normalized = explicitID.lowercased()
            let matched = sessions.first { $0.id.lowercased() == normalized } ?? sessions.first { $0.id.lowercased().hasPrefix(normalized) }
            guard let target = matched else {
                return .output("未找到匹配 ID 为「\(explicitID)」的历史会话。")
            }
            return .launch(sessionID: target.id, workingDirectory: target.workingDirectory)
        }

        if sessions.isEmpty {
            return .output("未找到任何历史会话记录。")
        }

        // 按工作目录分组：当前目录优先排在第一位，其它目录按组内最新会话时间倒序排列
        var groups: [String: [StoredSessionInfo]] = [:]
        for s in sessions {
            let dir = s.workingDirectory.isEmpty ? currentCwd : s.workingDirectory
            groups[dir, default: []].append(s)
        }

        let sortedDirs = groups.keys.sorted { d1, d2 in
            let isCurrent1 = (d1 == currentCwd)
            let isCurrent2 = (d2 == currentCwd)
            if isCurrent1 != isCurrent2 { return isCurrent1 }
            let latest1 = groups[d1]?.map(\.updatedAt).max() ?? Date.distantPast
            let latest2 = groups[d2]?.map(\.updatedAt).max() ?? Date.distantPast
            return latest1 > latest2
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var outputSections: [String] = []
        outputSections.append("历史交互会话列表 (按工作目录分类展示，共 \(sessions.count) 个会话):")

        for dir in sortedDirs {
            let dirSessions = (groups[dir] ?? []).sorted(by: { $0.updatedAt > $1.updatedAt })
            let isCurrent = (dir == currentCwd)
            let header = isCurrent ? "📂 [当前工作目录] \(dir)" : "📂 \(dir)"

            var rows: [[String]] = []
            for s in dirSessions.prefix(8) {
                let dateStr = dateFormatter.string(from: s.updatedAt)
                let shortID = String(s.id.prefix(8))
                rows.append([shortID, dateStr, "\(s.messageCount)", s.title])
            }

            let table = CLIFormatter.renderTable(
                headers: ["SESSION ID", "UPDATED AT", "MSGS", "TITLE / SUMMARY"],
                rows: rows
            )
            outputSections.append("\n\(header)\n\(table)")
        }

        outputSections.append("""

        恢复会话方式:
          lingxiagent resume <session-id>    恢复指定会话 (支持前8位短ID，若为非当前目录会自动切换文件夹)
          lingxiagent resume --last          恢复上一次最近的会话
        """)

        return .output(outputSections.joined(separator: "\n"))
    }

    public struct StoredSessionInfo: Sendable {
        public let id: String
        public let title: String
        public let updatedAt: Date
        public let workingDirectory: String
        public let messageCount: Int
    }

    private static func listStoredSessionsFromSQLite(dataRoot: URL) -> [StoredSessionInfo] {
        let catalogPath = dataRoot.appendingPathComponent("catalog.sqlite")
        guard FileManager.default.fileExists(atPath: catalogPath.path) else { return [] }
        var catalogDB: OpaquePointer?
        guard sqlite3_open_v2(catalogPath.path, &catalogDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let catalogDB else { return [] }
        defer { sqlite3_close(catalogDB) }

        var roots: [(projectID: String, absRoot: String)] = []
        var stmt: OpaquePointer?
        let sql = "SELECT project_id, absolute_root FROM root_bindings WHERE kind = 'main' AND lifecycle_state = 'active'"
        if sqlite3_prepare_v2(catalogDB, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pID = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let root = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                if !pID.isEmpty && !root.isEmpty {
                    roots.append((pID, root))
                }
            }
            sqlite3_finalize(stmt)
        }

        var results: [StoredSessionInfo] = []
        for r in roots {
            let stateURL = dataRoot.appendingPathComponent("projects/\(r.projectID)/state.sqlite")
            guard FileManager.default.fileExists(atPath: stateURL.path) else { continue }
            var stateDB: OpaquePointer?
            guard sqlite3_open_v2(stateURL.path, &stateDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let stateDB else { continue }
            defer { sqlite3_close(stateDB) }

            let sQuery = "SELECT session_id, title, updated_at FROM sessions ORDER BY updated_at DESC"
            var sStmt: OpaquePointer?
            if sqlite3_prepare_v2(stateDB, sQuery, -1, &sStmt, nil) == SQLITE_OK {
                while sqlite3_step(sStmt) == SQLITE_ROW {
                    let sID = sqlite3_column_text(sStmt, 0).map { String(cString: $0) } ?? ""
                    var title = sqlite3_column_text(sStmt, 1).map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let uTimeStr = sqlite3_column_text(sStmt, 2).map { String(cString: $0) } ?? "0"
                    let uDate = Date(timeIntervalSince1970: Double(uTimeStr) ?? 0)

                    // 统计消息数
                    var msgCount = 0
                    var countStmt: OpaquePointer?
                    if sqlite3_prepare_v2(stateDB, "SELECT COUNT(*) FROM messages WHERE session_id = ?", -1, &countStmt, nil) == SQLITE_OK {
                        sqlite3_bind_text(countStmt, 1, sID, -1, SQLITE_TRANSIENT)
                        if sqlite3_step(countStmt) == SQLITE_ROW {
                            msgCount = Int(sqlite3_column_int(countStmt, 0))
                        }
                        sqlite3_finalize(countStmt)
                    }

                    if title.isEmpty {
                        var partStmt: OpaquePointer?
                        let partSql = "SELECT payload FROM message_parts WHERE message_id IN (SELECT message_id FROM messages WHERE session_id = ? AND role = 'user' ORDER BY ordinal LIMIT 1) LIMIT 1"
                        if sqlite3_prepare_v2(stateDB, partSql, -1, &partStmt, nil) == SQLITE_OK {
                            sqlite3_bind_text(partStmt, 1, sID, -1, SQLITE_TRANSIENT)
                            if sqlite3_step(partStmt) == SQLITE_ROW {
                                if let cStr = sqlite3_column_text(partStmt, 0) {
                                    let payloadStr = String(cString: cStr)
                                    if let data = payloadStr.data(using: .utf8),
                                       let part = try? JSONDecoder().decode(SessionMessagePart.self, from: data) {
                                        switch part {
                                        case let .text(t):
                                            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                                            title = clean.count > 50 ? String(clean.prefix(50)) + "..." : clean
                                        default:
                                            break
                                        }
                                    }
                                }
                            }
                            sqlite3_finalize(partStmt)
                        }
                    }
                    if title.isEmpty { title = "未命名会话" }

                    results.append(StoredSessionInfo(
                        id: sID,
                        title: title,
                        updatedAt: uDate,
                        workingDirectory: r.absRoot,
                        messageCount: msgCount
                    ))
                }
                sqlite3_finalize(sStmt)
            }
        }

        return results.sorted { $0.updatedAt > $1.updatedAt }
    }
}
