#if canImport(SwiftUI)
import SwiftUI

// MARK: - Timeline views
//
// Content is never decorated: messages and events carry no card, border or
// shadow. The user bubble is the one filled shape; assistant prose sits
// directly on the reading column. Event rows are a three-column grid
// (18 glyph | title | trail), 36pt minimum; colour lands on the glyph only and
// a successful call stays silent.

struct RuntimeFrontendKey: EnvironmentKey {
    static let defaultValue: RuntimeFrontend? = nil
}

extension EnvironmentValues {
    var runtimeFrontend: RuntimeFrontend? {
        get { self[RuntimeFrontendKey.self] }
        set { self[RuntimeFrontendKey.self] = newValue }
    }
}

/// Dispatches one folded row to its view.
struct TimelineRowView: View {
    let row: TimelineRow
    @Environment(\.timelineDisclosureDefaults) private var defaults

    var body: some View {
        switch row {
        case .user(let item):
            if case .user(let content, let attachments, _, _, _) = item.kind {
                UserBubble(content: content, attachments: attachments)
            }
        case .assistant(let item):
            if case .assistant(let content, _) = item.kind {
                AssistantMessage(content: content)
            }
        case .thinking(let item):
            if case .thinking(let content, let isStreaming, let duration, let tokens) = item.kind {
                ThinkingRow(content: content, duration: duration, tokens: tokens,
                            isStreaming: isStreaming, expandByDefault: defaults.expandThinking)
            }
        case .tool(let item):
            if case .tool(let call) = item.kind {
                ToolEventRow(call: call, expandByDefault: defaults.expandTools)
            }
        case .contextGroup(let group):
            ContextGroupRow(group: group)
        case .diffSummary(let summary):
            DiffSummaryRow(summary: summary)
        case .diff(let item):
            if case .diff(let path, let patch) = item.kind {
                FileDiffRow(path: path, patch: patch, initiallyOpen: true)
            }
        case .interaction(let item):
            if case .interaction(let card) = item.kind, card.status != .pending {
                InteractionRecordRow(card: card)
            }
        case .subagent(let item):
            if case .subagent(let event) = item.kind { SubagentEventRow(event: event) }
        case .notice(let item):
            if case .notice(let notice) = item.kind { NoticeRow(notice: notice) }
        case .terminal(let item):
            if case .terminal(let title, let isSuccess, let message) = item.kind {
                CompletionRow(title: title, isSuccess: isSuccess, message: message)
            }
        }
    }
}

// MARK: - Messages

/// Right-aligned, max bubble-max, fill-bubble, radius-bubble, 10 × 16, message 16/26.
private struct UserBubble: View {
    let content: String
    let attachments: [AttachmentPresentation]
    @State private var isHovered = false
    @Environment(\.runtimeFrontend) private var runtime

    var body: some View {
        VStack(alignment: .trailing, spacing: LingXiMetrics.Space.xs) {
            if !attachments.isEmpty { AttachmentStrip(attachments: attachments) }
            Text(content)
                .font(LXType.message)
                .lineSpacing(LXType.Leading.message)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, LingXiMetrics.Space.lg)
                .padding(.vertical, 10)
                .background(LXColor.fillBubble,
                            in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.bubble, style: .continuous))
                .frame(maxWidth: LingXiMetrics.Column.bubble, alignment: .trailing)
                .contextMenu { CopyMenu(text: content) }
            HStack(spacing: LingXiMetrics.Space.xs) {
                LXCopyButton(content, label: "复制")
                if let runtime {
                    Button("编辑") { runtime.editMessage(content: content) }
                        .buttonStyle(.lxSmall)
                    Button("撤回上一轮") { runtime.undoLastTurn() }
                        .buttonStyle(.lxSmall)
                }
            }
            .opacity(isHovered ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("你：\(content)")
    }
}

/// Assistant prose: no bubble, no card. Inline Markdown, fenced code as an
/// inset mono block.
private struct AssistantMessage: View {
    let content: String
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            ForEach(Array(MessageBlock.parse(content).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let text):
                    Text(MessageBlock.inline(text))
                        .font(LXType.message)
                        .lineSpacing(LXType.Leading.message)
                        .foregroundStyle(.primary)
                        .tint(LXColor.accentText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let code):
                    OutputBlock(text: code)
                }
            }
            HStack(spacing: LingXiMetrics.Space.xs) {
                LXCopyButton(content, label: "复制")
            }
            .opacity(isHovered ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu { CopyMenu(text: content, markdown: true) }
    }
}

enum MessageBlock {
    case prose(String)
    case code(String)

    /// Splits on ``` fences; everything else stays prose.
    static func parse(_ text: String) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code = []
                } else {
                    let chunk = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    if !chunk.isEmpty { blocks.append(.prose(chunk)) }
                    prose = []
                }
                inCode.toggle()
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode, !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        let tail = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
        if !tail.isEmpty { blocks.append(.prose(tail)) }
        return blocks
    }

    /// Inline Markdown (bold, italics, `code`, links) keeping line breaks.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(size: 14, design: .monospaced)
            attributed[run.range].backgroundColor = LXColor.fillQuinary
        }
        return attributed
    }
}

private struct CopyMenu: View {
    let text: String
    var markdown = false

    var body: some View {
        Button("复制") { LXPasteboard.copy(text) }
        if markdown { Button("复制为 Markdown") { LXPasteboard.copy(text) } }
    }
}

struct AttachmentStrip: View {
    let attachments: [AttachmentPresentation]

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            ForEach(attachments) { attachment in
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Image(systemName: attachment.thumbnailSymbol).foregroundStyle(.secondary)
                    Text(attachment.filename).lineLimit(1).truncationMode(.middle)
                    Text(attachment.formattedSize).foregroundStyle(.secondary)
                    if !attachment.isUploaded { ProgressView().controlSize(.small) }
                }
                .font(LXType.meta)
                .padding(.horizontal, LingXiMetrics.Space.sm)
                .frame(height: LXControl.small)
                .background(LXColor.fillQuinary,
                            in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.sm, style: .continuous))
                .frame(maxWidth: 220)
            }
        }
    }
}

// MARK: - Event row

/// Three columns: 18pt glyph · title · trail (duration, status, chevron).
/// A disclosure only exists when there is detail to show.
struct EventRow<Title: View, Detail: View>: View {
    let symbol: String
    var tint: Color?
    let title: Title
    var trailing: String?
    var status: EventStatus = .none
    var hasDetail: Bool
    let detail: Detail
    @State private var isOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(symbol: String, tint: Color? = nil, trailing: String? = nil, status: EventStatus = .none,
         hasDetail: Bool = true, initiallyOpen: Bool = false,
         @ViewBuilder title: () -> Title, @ViewBuilder detail: () -> Detail) {
        self.symbol = symbol
        self.tint = tint
        self.trailing = trailing
        self.status = status
        self.hasDetail = hasDetail
        self.title = title()
        self.detail = detail()
        self._isOpen = State(initialValue: initiallyOpen && hasDetail)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasDetail else { return }
                withAnimation(LXMotion.animation(LXMotion.disclosure, reduceMotion: reduceMotion)) { isOpen.toggle() }
            } label: {
                HStack(spacing: LingXiMetrics.Space.sm) {
                    Image(systemName: symbol)
                        .font(.system(size: LXIcon.event))
                        .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                        .frame(width: LingXiMetrics.Size.glyphColumn)
                    title
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: LingXiMetrics.Space.sm) {
                        if let trailing, !trailing.isEmpty {
                            Text(trailing).font(LXType.meta).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                        }
                        EventStatusGlyph(status: status)
                        if hasDetail {
                            Image(systemName: "chevron.right")
                                .font(.system(size: LXIcon.small, weight: .medium))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                        }
                    }
                }
                .frame(minHeight: LingXiMetrics.Size.rowEvent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(hasDetail ? (isOpen ? "已展开" : "已折叠") : "")

            if isOpen {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) { detail }
                    .padding(.leading, LingXiMetrics.detailIndent)
                    .padding(.bottom, LingXiMetrics.Space.sm)
                    .transition(.opacity)
            }
        }
    }
}

extension EventRow where Detail == EmptyView {
    init(symbol: String, tint: Color? = nil, trailing: String? = nil, status: EventStatus = .none,
         @ViewBuilder title: () -> Title) {
        self.init(symbol: symbol, tint: tint, trailing: trailing, status: status, hasDetail: false,
                  title: title) { EmptyView() }
    }
}

/// Event title in callout, with an optional secondary caption after it.
private func eventTitle(_ text: String, caption: String? = nil, mono: Bool = false) -> Text {
    let head = Text(text).font(mono ? LXType.mono : LXType.callout).foregroundColor(.primary)
    guard let caption, !caption.isEmpty else { return head }
    return head + Text("  " + caption).font(LXType.meta).foregroundColor(.secondary)
}

// MARK: - Thinking

/// Collapsed by default. Streaming: 「思考中…」 + Indigo ring, not expandable.
/// The sparkles glyph is Indigo in every state — the only place thinking colour lands.
struct ThinkingRow: View {
    let content: String
    let duration: Double
    let tokens: Int
    let isStreaming: Bool
    let expandByDefault: Bool

    private var streaming: Bool { isStreaming || (duration <= 0 && tokens <= 0) }

    var body: some View {
        if streaming {
            EventRow(symbol: "sparkles", tint: LXStatus.thinking) {
                HStack(spacing: LingXiMetrics.Space.sm) {
                    Text("思考中…").font(LXType.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    LXSpinner(tone: .thinking).accessibilityLabel("思考中")
                }
            }
        } else {
            EventRow(symbol: "sparkles", tint: LXStatus.thinking, hasDetail: !content.isEmpty,
                     initiallyOpen: expandByDefault) {
                eventTitle("思考", caption: metrics)
            } detail: {
                HStack {
                    Spacer(minLength: 0)
                    LXCopyButton(content, label: "复制思考")
                }
                Text(content)
                    .font(LXType.thinkingBody)
                    .lineSpacing(LXType.Leading.thinking)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lxInsetBlock()
            }
        }
    }

    private var metrics: String {
        var parts: [String] = []
        if duration > 0 { parts.append(String(format: "%.1fs", duration)) }
        if tokens > 0 { parts.append("\(tokens) tok") }
        return parts.isEmpty ? "" : "· " + parts.joined(separator: " · ")
    }
}

// MARK: - Tool

/// Category badge text: TOOL / MCP · server / SKILL · name.
private func toolBadge(_ name: String) -> String {
    let lower = name.lowercased()
    if lower.hasPrefix("mcp_") || lower.hasPrefix("mcp.") || lower.hasPrefix("mcp:") {
        let server = name.dropFirst(4).split(whereSeparator: { "_.:".contains($0) }).first.map(String.init)
        return server.map { "MCP · \($0)" } ?? "MCP"
    }
    if lower.hasPrefix("skill") || lower.contains("load_skill") {
        let skill = name.replacingOccurrences(of: "load_skill", with: "")
            .replacingOccurrences(of: "skill_", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_:. "))
        return skill.isEmpty ? "SKILL" : "SKILL · \(skill)"
    }
    return "TOOL"
}

/// Chinese verb for common tools, so the row reads「编辑 Tokens.swift」.
private func toolVerb(_ name: String) -> String? {
    switch name {
    case "read", "read_file": return "读取"
    case "edit_file", "apply_patch": return "编辑"
    case "write_file": return "写入"
    case "format_file": return "格式化"
    case "grep", "context_search", "retrieval_search": return "搜索"
    case "glob": return "匹配"
    case "list_directory": return "列出"
    case "web_fetch": return "抓取"
    case "web_search": return "联网搜索"
    case "codebase_graph": return "代码图谱"
    case "symbol_lookup", "find_references", "code_intelligence": return "代码智能"
    default: return nil
    }
}

/// Paths read best as the file name; the full path goes to the tooltip.
private func displayTarget(_ summary: String) -> String {
    guard summary.contains("/"), !summary.contains(" ") else { return summary }
    return URL(fileURLWithPath: summary).lastPathComponent
}

struct ToolEventRow: View {
    let call: ToolCallPresentation
    let expandByDefault: Bool

    var body: some View {
        EventRow(symbol: LXToolGlyph.symbol(for: call.toolName),
                 trailing: call.durationMs.map { DurationText.format(milliseconds: $0) },
                 status: EventStatus(call.status),
                 hasDetail: hasDetail,
                 initiallyOpen: expandByDefault || TimelineDisclosure.tool(name: call.toolName, status: call.status,
                                                                           hasOutput: call.output != nil)) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                LXBadge(toolBadge(call.toolName))
                titleText.truncationMode(.middle)
            }
            .help(call.summary)
        } detail: {
            if let cwd = call.workingDirectory {
                Label(cwd, systemImage: "folder")
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let output = call.output, !output.isEmpty { OutputBlock(text: output) }
            if let stderr = call.stderr, !stderr.isEmpty {
                Label("stderr", systemImage: "exclamationmark.triangle")
                    .font(LXType.meta)
                    .foregroundStyle(LXStatus.error)
                OutputBlock(text: stderr)
            }
        }
    }

    private var titleText: Text {
        if LXToolGlyph.isCommand(call.toolName) { return Text(call.summary).font(LXType.mono).foregroundColor(.primary) }
        if call.summary.isEmpty || call.summary == call.toolName {
            return Text(call.toolName).font(LXType.callout).foregroundColor(.primary)
        }
        let verb = toolVerb(call.toolName) ?? call.toolName
        return Text(verb + " ").font(LXType.callout).foregroundColor(.primary)
            + Text(displayTarget(call.summary)).font(LXType.callout).foregroundColor(.primary)
    }

    private var hasDetail: Bool {
        !(call.output ?? "").isEmpty || !(call.stderr ?? "").isEmpty || call.workingDirectory != nil
    }
}

// MARK: - Folded rows

/// Settled read-only calls fold into「上下文 · 读取 N 个文件」.
private struct ContextGroupRow: View {
    let group: TimelineRow.ContextGroup

    var body: some View {
        EventRow(symbol: "doc.text.magnifyingglass",
                 trailing: group.elapsed > 0 ? DurationText.format(milliseconds: group.elapsed * 1000) : nil) {
            eventTitle(title)
        } detail: {
            ForEach(group.items) { item in
                if case .tool(let call) = item.kind {
                    HStack(spacing: LingXiMetrics.Space.sm) {
                        Text(call.summary)
                            .font(LXType.monoSmall)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(toolVerb(call.toolName) ?? call.toolName)
                            .font(LXType.meta)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 24)
                }
            }
        }
    }

    private var title: String {
        var parts: [String] = []
        if group.fileReads > 0 { parts.append("读取 \(group.fileReads) 个文件") }
        if group.searches > 0 { parts.append("检索 \(group.searches) 次") }
        return "上下文 · " + (parts.isEmpty ? "\(group.items.count) 项" : parts.joined(separator: "，"))
    }
}

/// 「改动 N 个文件 +a −d」, expanding into one row per file.
private struct DiffSummaryRow: View {
    let summary: TimelineRow.DiffSummary

    var body: some View {
        EventRow(symbol: "doc.badge.gearshape") {
            HStack(spacing: LingXiMetrics.Space.md) {
                Text("改动 \(summary.files.count) 个文件").font(LXType.callout)
                LXDiffCount(additions: summary.additions, deletions: summary.deletions).font(LXType.callout)
            }
        } detail: {
            ForEach(summary.items) { item in
                if case .diff(let path, let patch) = item.kind {
                    FileDiffRow(path: path, patch: patch, initiallyOpen: false)
                }
            }
        }
    }
}

private struct FileDiffRow: View {
    let path: String
    let patch: String
    let initiallyOpen: Bool

    var body: some View {
        EventRow(symbol: "doc.text", initiallyOpen: initiallyOpen) {
            HStack(spacing: LingXiMetrics.Space.md) {
                Text(path).font(LXType.mono).truncationMode(.middle)
                LXDiffCount(additions: counts.0, deletions: counts.1).font(LXType.meta)
            }
        } detail: {
            OutputBlock(text: patch, isDiff: true)
        }
    }

    private var counts: (Int, Int) {
        var add = 0, remove = 0
        for line in patch.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("+") && !line.hasPrefix("+++") { add += 1 }
            else if line.hasPrefix("-") && !line.hasPrefix("---") { remove += 1 }
        }
        return (add, remove)
    }
}

/// End of a turn: status glyph + title, then a hairline to the column end.
private struct CompletionRow: View {
    let title: String
    let isSuccess: Bool
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                Image(systemName: isSuccess ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .font(.system(size: LXIcon.event))
                    .foregroundStyle(isSuccess ? LXStatus.success : LXStatus.error)
                    .frame(width: LingXiMetrics.Size.glyphColumn)
                eventTitle(title, caption: isSuccess ? message : nil)
                    .lineLimit(1)
                    .layoutPriority(1)
                LXHairline()
            }
            .frame(minHeight: LingXiMetrics.Size.rowEvent)
            if !isSuccess && !message.isEmpty {
                Text(message)
                    .font(LXType.meta)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, LingXiMetrics.detailIndent)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A resolved permission / question keeps one line in the timeline.
private struct InteractionRecordRow: View {
    let card: InteractionCardPresentation

    var body: some View {
        EventRow(symbol: card.kind == .permission ? "checkmark.shield" : "questionmark.bubble",
                 tint: card.status == .rejected ? LXStatus.error : nil) {
            eventTitle(title, caption: card.kind == .permission ? card.toolName : nil)
                .truncationMode(.middle)
        }
    }

    private var title: String {
        switch (card.kind, card.status) {
        case (.permission, .approved): return "已允许 · \(card.parametersSummary)"
        case (.permission, _): return "已拒绝 · \(card.parametersSummary)"
        case (_, .approved): return "已回答 · \(card.parametersSummary)"
        default: return "已取消 · \(card.parametersSummary)"
        }
    }
}

private struct SubagentEventRow: View {
    let event: SubagentEventPresentation

    var body: some View {
        EventRow(symbol: "person.2", status: EventStatus(event.status)) {
            eventTitle("子 Agent \(event.runID.suffix(8))", caption: event.terminalReason)
        }
    }
}

/// info stays quiet, warning / error tint the glyph; error titles go medium.
private struct NoticeRow: View {
    let notice: NoticePresentation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LingXiMetrics.Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: LXIcon.event))
                .foregroundStyle(tint)
                .frame(width: LingXiMetrics.Size.glyphColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(notice.level == .error ? LXType.callout : Font.system(size: 14))
                    .foregroundStyle(notice.level == .info ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if !notice.message.isEmpty {
                    Text(notice.message)
                        .font(LXType.meta)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, LingXiMetrics.Space.sm)
        .frame(minHeight: LingXiMetrics.Size.rowEvent)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch notice.level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private var tint: Color {
        switch notice.level {
        case .info: return LXStatus.info
        case .warning: return LXStatus.warning
        case .error: return LXStatus.error
        }
    }
}
#endif
