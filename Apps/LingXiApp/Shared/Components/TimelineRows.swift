import Foundation
import SwiftUI

/// 时间线的表现层行模型。
///
/// `TimelineItemPresentation` 是 Core 事件的 1:1 投影，直接渲染会得到一屏卡片墙。
/// 这里把连续同类条目折叠成单行，是纯函数、只在视图层发生，不改动协议模型。
/// 折叠策略对齐 opencode 的 `CONTEXT_GROUP_TOOLS` 与 ChatGPT 的 activity header。
enum TimelineRow: Identifiable, Equatable {
    case user(TimelineItemPresentation)
    case assistant(TimelineItemPresentation)
    case thinking(TimelineItemPresentation)
    case tool(TimelineItemPresentation)
    case contextGroup(ContextGroup)
    case diffSummary(DiffSummary)
    case diff(TimelineItemPresentation)
    case interaction(TimelineItemPresentation)
    case subagent(TimelineItemPresentation)
    case notice(TimelineItemPresentation)
    case terminal(TimelineItemPresentation)

    var id: String {
        switch self {
        case .user(let i), .assistant(let i), .thinking(let i), .tool(let i),
             .diff(let i), .interaction(let i), .subagent(let i), .notice(let i), .terminal(let i):
            return i.id
        case .contextGroup(let g): return g.id
        case .diffSummary(let d): return d.id
        }
    }

    var timestamp: Date {
        switch self {
        case .user(let i), .assistant(let i), .thinking(let i), .tool(let i),
             .diff(let i), .interaction(let i), .subagent(let i), .notice(let i), .terminal(let i):
            return i.timestamp
        case .contextGroup(let g): return g.firstTimestamp
        case .diffSummary(let d): return d.firstTimestamp
        }
    }

    /// A user message opens a new turn and gets extra leading space.
    var isTurnBoundary: Bool {
        if case .user = self { return true }
        return false
    }

    struct ContextGroup: Equatable {
        let id: String
        let items: [TimelineItemPresentation]
        let fileReads: Int
        let searches: Int
        let firstTimestamp: Date
        let lastTimestamp: Date

        var elapsed: TimeInterval { max(0, lastTimestamp.timeIntervalSince(firstTimestamp)) }

        /// 计数部分，例如「7 个文件 · 3 次检索」
        var countsSummary: String {
            var parts: [String] = []
            if fileReads > 0 { parts.append("\(fileReads) 个文件") }
            if searches > 0 { parts.append("\(searches) 次检索") }
            return parts.joined(separator: " · ")
        }

        /// 一行摘要，例如「收集上下文 · 7 个文件 · 3 次检索」
        var summary: String {
            countsSummary.isEmpty ? "查看上下文" : "收集上下文 · " + countsSummary
        }
    }

    struct DiffSummary: Equatable {
        let id: String
        let files: [String]
        let additions: Int
        let deletions: Int
        let items: [TimelineItemPresentation]
        let firstTimestamp: Date
    }
}

extension Array where Element == TimelineItemPresentation {

    /// 只读探查类工具：合并成一行，不各占一卡。
    private static let contextToolNames: Set<String> = [
        "read", "read_file", "glob", "grep", "list_directory",
        "context_search", "context_recall", "retrieval_search", "search_tools",
        "codebase_graph", "code_intelligence", "symbol_lookup", "find_references",
        "dependency_query", "web_search", "web_fetch"
    ]

    /// 有专属面板、不在时间线里重复出现的工具。
    private static let suppressedToolNames: Set<String> = ["todo"]

    /// 折叠为表现层行序列。
    func foldedIntoRows() -> [TimelineRow] {
        var rows: [TimelineRow] = []
        rows.reserveCapacity(count)

        var contextRun: [TimelineItemPresentation] = []
        var diffRun: [TimelineItemPresentation] = []

        func flushContext() {
            defer { contextRun = [] }
            // 单条不折叠，避免为一行造一个 disclosure
            guard let firstItem = contextRun.first, let lastItem = contextRun.last, contextRun.count > 1 else {
                if let only = contextRun.first { rows.append(.tool(only)) }
                return
            }
            let items = contextRun
            var reads = 0, searches = 0
            for item in items {
                guard case .tool(let call) = item.kind else { continue }
                switch call.toolName {
                case "grep", "glob", "context_search", "retrieval_search",
                     "search_tools", "web_search", "codebase_graph", "context_recall",
                     "symbol_lookup", "find_references", "dependency_query", "code_intelligence":
                    searches += 1
                default:
                    reads += 1
                }
            }
            rows.append(.contextGroup(TimelineRow.ContextGroup(
                id: "ctx-" + firstItem.id,
                items: items,
                fileReads: reads,
                searches: searches,
                firstTimestamp: firstItem.timestamp,
                lastTimestamp: lastItem.timestamp
            )))
        }

        func flushDiff() {
            defer { diffRun = [] }
            guard let firstDiff = diffRun.first, diffRun.count > 1 else {
                if let only = diffRun.first { rows.append(.diff(only)) }
                return
            }
            var additions = 0, deletions = 0
            var files: [String] = []
            for item in diffRun {
                guard case .diff(let path, let body) = item.kind else { continue }
                files.append(path)
                for line in body.split(whereSeparator: \.isNewline) {
                    if line.hasPrefix("+") && !line.hasPrefix("+++") { additions += 1 }
                    else if line.hasPrefix("-") && !line.hasPrefix("---") { deletions += 1 }
                }
            }
            rows.append(.diffSummary(TimelineRow.DiffSummary(
                id: "diffsum-" + firstDiff.id,
                files: files,
                additions: additions,
                deletions: deletions,
                items: diffRun,
                firstTimestamp: firstDiff.timestamp
            )))
        }

        for item in self {
            let isContextTool: Bool
            if case .tool(let call) = item.kind {
                if Self.suppressedToolNames.contains(call.toolName) { continue }
                // Only settled read-only calls fold; a running or failed one stays visible on its own.
                isContextTool = Self.contextToolNames.contains(call.toolName)
                    && EventStatus(call.status) == .none
            } else {
                isContextTool = false
            }
            let isDiff: Bool
            if case .diff = item.kind { isDiff = true } else { isDiff = false }

            if isContextTool {
                flushDiff()
                contextRun.append(item)
                continue
            }
            if isDiff {
                flushContext()
                diffRun.append(item)
                continue
            }

            flushContext()
            flushDiff()
            rows.append(Self.row(for: item))
        }

        flushContext()
        flushDiff()
        return rows
    }

    private static func row(for item: TimelineItemPresentation) -> TimelineRow {
        switch item.kind {
        case .user: return .user(item)
        case .assistant: return .assistant(item)
        case .thinking: return .thinking(item)
        case .tool: return .tool(item)
        case .interaction: return .interaction(item)
        case .subagent: return .subagent(item)
        case .notice: return .notice(item)
        case .terminal: return .terminal(item)
        case .diff: return .diff(item)
        }
    }
}

/// 用户在设置中选择的默认展开偏好（与 TUI 共用 preferences.json）。
public struct TimelineDisclosureDefaults: Equatable, Sendable {
    public var expandThinking: Bool
    public var expandTools: Bool

    public init(expandThinking: Bool = false, expandTools: Bool = false) {
        self.expandThinking = expandThinking
        self.expandTools = expandTools
    }
}

private struct TimelineDisclosureDefaultsKey: EnvironmentKey {
    static let defaultValue = TimelineDisclosureDefaults()
}

public extension EnvironmentValues {
    var timelineDisclosureDefaults: TimelineDisclosureDefaults {
        get { self[TimelineDisclosureDefaultsKey.self] }
        set { self[TimelineDisclosureDefaultsKey.self] = newValue }
    }
}

/// 默认展开策略：按语义决定初值，而非一律折叠或一律展开。
enum TimelineDisclosure {

    /// 思考块：短思考直接看，长思考折叠以免挤掉正文。
    static func thinking(isExpanded modelValue: Bool, tokenCount: Int) -> Bool {
        modelValue || tokenCount <= 120
    }

    /// 工具输出：失败与写操作默认展开，只读探查默认折叠。
    static func tool(name: String, status: String, hasOutput: Bool) -> Bool {
        if status.lowercased().contains("fail") || status.lowercased().contains("error") { return true }
        switch name {
        case "edit_file", "write_file", "apply_patch":
            return true
        default:
            return false
        }
    }
}
