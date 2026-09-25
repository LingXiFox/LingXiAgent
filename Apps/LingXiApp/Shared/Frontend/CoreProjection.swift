#if canImport(SwiftUI)
import Foundation
import LingXiApplication
import LingXiProtocol

// MARK: - Permission presets

/// The four frozen permission configurations Core defines, named by approval
/// policy and access scope so the composer never hides which scope is active.
public enum PermissionPreset: String, CaseIterable, Identifiable, Sendable {
    case askWorkspace, autoWorkspace, askFullAccess, yoloFullAccess
    public var id: String { rawValue }

    public var configuration: PermissionConfiguration {
        switch self {
        case .askWorkspace: return .askWorkspace
        case .autoWorkspace: return .autoWorkspace
        case .askFullAccess: return .askFullAccess
        case .yoloFullAccess: return .yoloFullAccess
        }
    }

    public var label: String {
        switch self {
        case .askWorkspace: return "Ask · 工作区"
        case .autoWorkspace: return "Auto · 工作区"
        case .askFullAccess: return "Ask · 完全访问"
        case .yoloFullAccess: return "YOLO · 完全访问"
        }
    }

    public var shortLabel: String {
        switch self {
        case .askWorkspace: return "Ask"
        case .autoWorkspace: return "Auto"
        case .askFullAccess: return "Ask·Full"
        case .yoloFullAccess: return "YOLO"
        }
    }

    /// Full access widens the blast radius beyond the workspace; the UI tints it.
    public var isElevated: Bool { self == .askFullAccess || self == .yoloFullAccess }

    public init?(_ configuration: PermissionConfiguration) {
        guard let match = Self.allCases.first(where: { $0.configuration == configuration }) else { return nil }
        self = match
    }
}

// MARK: - Projection

/// Pure mapping from the Application layer's authoritative state to the GUI's
/// presentation values. No I/O except `gitBranch(at:)`, no invented data: a
/// value Core does not provide stays nil and the view says so.
enum CoreProjection {

    // MARK: Timeline

    static func timeline(_ session: SessionViewState?) -> [TimelineItemPresentation] {
        guard let session else { return [] }
        return session.timelineNodes.compactMap { node in
            guard let kind = kind(for: node, in: session) else { return nil }
            return TimelineItemPresentation(id: node.id.rawValue, timestamp: node.timestamp, kind: kind)
        }
    }

    private static func kind(for node: TimelineNode, in session: SessionViewState) -> TimelineItemKind? {
        switch node.kind {
        case .message(let message):
            switch message.role {
            case .user:
                let matchedTurnID = session.turns.first(where: { $0.value.userMessage.messageID == message.messageID })?.key.rawValue
                return .user(content: message.content, attachments: [], messageID: message.messageID.rawValue, turnID: matchedTurnID, sessionID: session.sessionID.rawValue)
            case .assistant:
                guard !message.content.isEmpty || message.isStreaming else { return nil }
                return .assistant(content: message.content, isStreaming: message.isStreaming)
            }
        case .thinking(let thinking):
            let seconds: Double
            if let duration = thinking.duration {
                seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            } else if let start = thinking.startedAt, let end = thinking.completedAt {
                seconds = end.timeIntervalSince(start)
            } else {
                seconds = 0
            }
            let tokens = thinking.isComplete ? (thinking.outputMetadata?.totalTokens ?? 0) : 0
            return .thinking(content: thinking.content, isExpanded: thinking.isStreaming,
                             durationSeconds: thinking.isComplete ? max(seconds, 0.1) : 0, tokenCount: tokens)
        case .tool(let tool):
            return .tool(toolCall(tool))
        case .interaction(let interaction):
            return .interaction(card: card(interaction))
        case .subagent(let sub):
            return .subagent(SubagentEventPresentation(runID: sub.runID.rawValue, parentRunID: sub.parentRunID.rawValue,
                                                       status: sub.status, terminalReason: sub.terminalReason?.rawValue))
        case .runTerminal(let terminal):
            return .terminal(title: terminalTitle(terminal.terminalReason),
                             isSuccess: terminal.terminalReason == .completed,
                             message: runSummary(terminal.runID, in: session))
        case .error(let error):
            return .notice(NoticePresentation(level: .error, title: errorTitle(error.code), message: error.message))
        }
    }

    static func toolCall(_ tool: ToolNode) -> ToolCallPresentation {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(tool.argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let output = tool.result.flatMap { $0.preview ?? ($0.summary.isEmpty ? nil : $0.summary) }
            ?? (tool.stdout.isEmpty ? nil : tail(tool.stdout))
        let durationMs = tool.executionDuration.map {
            Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15
        }
        return ToolCallPresentation(
            callID: tool.callID.rawValue,
            toolName: tool.toolName,
            summary: argumentSummary(arguments) ?? tool.toolName,
            status: status(tool.phase),
            output: tool.error.map { $0.message } ?? output,
            stderr: tool.stderr.isEmpty ? nil : tail(tool.stderr),
            durationMs: durationMs,
            // ToolResultSnapshot carries no exit code; the result summary states it when relevant.
            exitCode: nil,
            workingDirectory: (arguments["cwd"] ?? arguments["workdir"] ?? arguments["working_directory"]) as? String
        )
    }

    static func status(_ phase: ToolExecutionPhase) -> String {
        switch phase {
        case .requested, .scheduled, .running: return "running"
        case .waitingPermission: return "waiting"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    /// The one argument a reader needs to recognise the call.
    static func argumentSummary(_ arguments: [String: Any]) -> String? {
        for key in ["command", "cmd", "path", "file_path", "filePath", "pattern", "query", "url", "name", "paths"] {
            if let value = arguments[key] as? String, !value.isEmpty { return oneLine(value) }
            if let values = arguments[key] as? [String], !values.isEmpty { return oneLine(values.joined(separator: ", ")) }
        }
        return arguments.values.lazy.compactMap { $0 as? String }.first.map(oneLine)
    }

    static func card(_ node: InteractionNode) -> InteractionCardPresentation {
        let status: InteractionStatus
        switch node.resolution {
        case .permission(.deny)?: status = .rejected
        case .question(let reply)? where reply.cancelled: status = .rejected
        case .some: status = .approved
        case nil: status = node.isResolved ? .approved : .pending
        }
        let runID = node.causal.runID?.rawValue ?? "main"
        switch node.kind {
        case .question:
            let q = node.questionRequest
            return InteractionCardPresentation(
                interactionID: node.interactionID.rawValue, agentRunID: runID, kind: .question,
                toolName: "", parametersSummary: q?.question ?? "",
                options: q?.options ?? [], allowsMultiple: q?.allowsMultiple ?? false,
                allowsFreeText: q?.allowsFreeText ?? true, status: status)
        case .decision:
            let d = node.decisionRequest
            return InteractionCardPresentation(
                interactionID: node.interactionID.rawValue, agentRunID: runID, kind: .decision,
                toolName: "", parametersSummary: d?.question ?? "", options: d?.options ?? [], status: status)
        case .permission, .unknown:
            let p = node.permissionRequest
            return InteractionCardPresentation(
                interactionID: node.interactionID.rawValue, agentRunID: runID, kind: .permission,
                toolName: p?.toolID.rawValue ?? "tool",
                parametersSummary: p?.description ?? "",
                resource: p?.resource ?? "",
                capabilities: (p?.capabilities).map { $0.map(\.rawValue).sorted() } ?? [],
                status: status)
        }
    }

    private static func terminalTitle(_ reason: TerminalReason) -> String {
        switch reason {
        case .completed: return "本轮完成"
        case .blocked: return "已阻塞"
        case .userCancelled: return "已停止"
        case .providerFailure: return "Provider 失败"
        case .deadlineExceeded: return "超时"
        case .maxStepsReached: return "达到步数上限"
        case .emptyCompletion: return "模型无输出"
        case .runtimeFailure: return "运行失败"
        }
    }

    private static func runSummary(_ runID: RunID, in session: SessionViewState) -> String {
        guard let run = session.runs[runID] else { return "" }
        var parts: [String] = []
        if let end = run.completedAt {
            parts.append("用时 " + DurationText.format(milliseconds: end.timeIntervalSince(run.createdAt) * 1000))
        }
        if !run.model.isEmpty { parts.append(run.model) }
        return parts.joined(separator: " · ")
    }

    private static func errorTitle(_ code: String) -> String {
        switch code {
        case let c where c.localizedCaseInsensitiveContains("rate"): return "触发限流"
        case let c where c.localizedCaseInsensitiveContains("provider"): return "Provider 错误"
        case let c where c.localizedCaseInsensitiveContains("context"): return "上下文错误"
        default: return "运行错误 · \(code)"
        }
    }

    /// Transient provider condition worth surfacing at the tail of the timeline.
    static func providerNotice(_ session: SessionViewState?) -> NoticePresentation? {
        guard let session, let state = session.activeProviderRequestState else { return nil }
        let detail = [session.activeProviderRequestDetail, session.activeProviderStatusCode.map { "HTTP \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
        switch state {
        case .rateLimited: return NoticePresentation(level: .warning, title: "Provider 限流，等待重试", message: detail)
        case .retryScheduled: return NoticePresentation(level: .warning, title: "请求失败，已安排重试", message: detail)
        case .waitingForRateBudget: return NoticePresentation(level: .info, title: "等待速率预算", message: detail)
        case .failed: return NoticePresentation(level: .error, title: "Provider 请求失败", message: detail)
        default: return nil
        }
    }

    // MARK: Sidebar

    static func sessionFolders(_ state: ApplicationState, workspaceName: String? = nil) -> [SessionFolderPresentation] {
        let runningID = state.activeSessionState?.activeTurnID == nil ? nil : state.activeSessionID
        let sessions = state.sessionCatalog.sorted { $0.updatedAt > $1.updatedAt }
        var order: [String] = []
        var grouped: [String: [SessionItemPresentation]] = [:]
        for summary in sessions {
            // Sessions without a recorded directory belong to the workspace this Core serves.
            let folder = summary.workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? workspaceName ?? "当前工作区"
            if grouped[folder] == nil { order.append(folder) }
            grouped[folder, default: []].append(SessionItemPresentation(
                id: summary.sessionID.rawValue,
                title: summary.title?.isEmpty == false ? summary.title! : "未命名会话",
                lastUpdated: summary.updatedAt,
                messageCount: summary.messageCount,
                mode: summary.mode.displayName,
                isActive: summary.sessionID == runningID))
        }
        return order.map { SessionFolderPresentation(folderName: $0, sessions: grouped[$0] ?? []) }
    }

    static func workspace(_ state: ApplicationState, root: URL?) -> WorkspaceSummaryPresentation {
        let path = state.currentWorkspace?.rootPath ?? root?.path
        return WorkspaceSummaryPresentation(
            name: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未打开工作区",
            rootBadge: "local",
            isRemote: false,
            gitBranch: path.flatMap { gitBranch(at: URL(fileURLWithPath: $0)) },
            indexingState: state.currentWorkspace?.indexingState ?? "ready")
    }

    /// Reads `.git/HEAD` directly (worktrees point `.git` at their gitdir) — no process spawn.
    static func gitBranch(at root: URL) -> String? {
        var gitDir = root.appendingPathComponent(".git")
        if let pointer = try? String(contentsOf: gitDir, encoding: .utf8), pointer.hasPrefix("gitdir:") {
            gitDir = URL(fileURLWithPath: pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines),
                         relativeTo: root)
        }
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") { return String(trimmed.dropFirst("ref: refs/heads/".count)) }
        return String(trimmed.prefix(8))
    }

    // MARK: Changes

    /// Parses a unified `git diff` into per-file Git-style entries.
    static func fileChanges(fromUnifiedDiff diff: String) -> [FileChangePresentation] {
        var files: [FileChangePresentation] = []
        var current: FileChangePresentation?
        var patch: [Substring] = []

        func flush() {
            guard var file = current else { return }
            file.patch = patch.joined(separator: "\n")
            files.append(file)
            current = nil
            patch = []
        }

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                flush()
                let path = line.split(separator: " ").last.map { String($0.dropFirst(2)) } ?? String(line)
                current = FileChangePresentation(path: path, change: .modified)
                patch = [line]
                continue
            }
            guard current != nil else { continue }
            patch.append(line)
            if line.hasPrefix("new file mode") { current?.change = .added }
            else if line.hasPrefix("deleted file mode") { current?.change = .deleted }
            else if line.hasPrefix("rename from ") { current?.change = .renamed; current?.oldPath = String(line.dropFirst("rename from ".count)) }
            else if line.hasPrefix("+"), !line.hasPrefix("+++") { current?.additions += 1 }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { current?.deletions += 1 }
        }
        flush()
        return files
    }

    // MARK: Helpers

    private static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }

    /// Last lines of a stream, so long output stays scannable.
    private static func tail(_ text: String, lines: Int = 40) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.count <= lines ? text : "…\n" + all.suffix(lines).joined(separator: "\n")
    }
}

/// One file in a Git-style change list.
public struct FileChangePresentation: Identifiable, Sendable, Equatable {
    public enum Change: String, Sendable, Equatable {
        case added = "A", modified = "M", deleted = "D", renamed = "R"
    }

    public var id: String { path }
    public let path: String
    public var change: Change
    public var oldPath: String?
    public var additions = 0
    public var deletions = 0
    public var patch = ""

    public init(path: String, change: Change) {
        self.path = path
        self.change = change
    }
}

#endif
