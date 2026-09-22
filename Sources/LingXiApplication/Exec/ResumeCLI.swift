import Foundation
import LingXiProtocol
import LingXiPlatform

/// 交互式会话恢复与历史检索 CLI (Round 3 Phase E：彻底解耦 SQLite，收拢至纯 DTO)
public enum ResumeCLI {

    public enum Action: Sendable, Equatable {
        case launch(sessionID: String, workingDirectory: String?)
        case output(String)
    }

    public struct StoredSessionInfo: Sendable, Equatable {
        public let id: String
        public let title: String
        public let updatedAt: Date
        public let workingDirectory: String
        public let messageCount: Int

        public init(
            id: String,
            title: String,
            updatedAt: Date,
            workingDirectory: String,
            messageCount: Int
        ) {
            self.id = id
            self.title = title
            self.updatedAt = updatedAt
            self.workingDirectory = workingDirectory
            self.messageCount = messageCount
        }

        public init(summary: SessionSummary) {
            self.id = summary.sessionID.rawValue
            self.title = (summary.title?.isEmpty ?? true) ? "未命名会话" : summary.title!
            self.updatedAt = summary.updatedAt
            self.workingDirectory = summary.workingDirectory ?? ""
            self.messageCount = summary.messageCount
        }
    }

    /// 纯函数会话恢复解析与命令行格式化渲染
    public static func run(
        arguments: [String],
        currentCwd: String = LingXiPlatform.process.currentWorkingDirectory(),
        sessions: [StoredSessionInfo]
    ) -> Action {
        var args = arguments
        if args.first == "resume" {
            args.removeFirst()
        }

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

    /// 便捷重载：接收 SessionSummary DTO 列表
    public static func run(
        arguments: [String],
        currentCwd: String = LingXiPlatform.process.currentWorkingDirectory(),
        summaries: [SessionSummary]
    ) -> Action {
        run(arguments: arguments, currentCwd: currentCwd, sessions: summaries.map(StoredSessionInfo.init))
    }

    /// 异步重载：接收异步 SessionSummary 数据源
    public static func run(
        arguments: [String],
        currentCwd: String = LingXiPlatform.process.currentWorkingDirectory(),
        provider: () async throws -> [SessionSummary]
    ) async throws -> Action {
        let summaries = try await provider()
        return run(arguments: arguments, currentCwd: currentCwd, summaries: summaries)
    }
}
