#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct RuntimeActionEnvironmentKey: EnvironmentKey {
    static let defaultValue: RuntimeFrontend? = nil
}

extension EnvironmentValues {
    var runtimeFrontend: RuntimeFrontend? {
        get { self[RuntimeActionEnvironmentKey.self] }
        set { self[RuntimeActionEnvironmentKey.self] = newValue }
    }
}

/// 通用赛博复制按钮（常驻或 hover 显示，点击后显示 1.5s “已复制 ✓” 反馈）
public struct CyberCopyButton: View {
    public let text: String
    public var label: String? = nil
    @State private var copied = false

    public init(text: String, label: String? = nil) {
        self.text = text
        self.label = label
    }

    public var body: some View {
        Button {
            #if os(macOS)
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
            #endif
            withAnimation(.easeInOut(duration: 0.15)) {
                copied = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                withAnimation(.easeInOut(duration: 0.15)) {
                    copied = false
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                if let label {
                    Text(copied ? "已复制 ✓" : label)
                        .font(.system(size: 11.5, weight: .medium))
                } else if copied {
                    Text("已复制 ✓")
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .foregroundStyle(copied ? LingXiTheme.auroraMint : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row dispatch

struct TimelineRowView: View {
    let row: TimelineRow
    @Environment(\.timelineDisclosureDefaults) private var defaults

    var body: some View {
        switch row {
        case .user(let item):
            if case .user(let content, let attachments, let messageID, let turnID, let sessionID) = item.kind {
                UserMessageRow(content: content, attachments: attachments, messageID: messageID, turnID: turnID, sessionID: sessionID)
            }
        case .assistant(let item):
            if case .assistant(let content, _) = item.kind {
                AssistantMessageRow(content: content)
            }
        case .thinking(let item):
            if case .thinking(let content, let expanded, let duration, let tokens) = item.kind {
                ReadingColumn {
                    CyberThinkingRow(
                        content: content,
                        duration: duration,
                        tokens: tokens,
                        isExpanded: expanded || defaults.expandThinking
                    )
                }
            }
        case .tool(let item):
            if case .tool(let call) = item.kind {
                ReadingColumn {
                    ToolEventRow(call: call, expandByDefault: defaults.expandTools)
                }
            }
        case .contextGroup(let group):
            ReadingColumn {
                ContextGroupRow(group: group)
            }
        case .diffSummary(let summary):
            ReadingColumn {
                DiffSummaryRow(summary: summary)
            }
        case .diff(let item):
            if case .diff(let path, let patch) = item.kind {
                ReadingColumn {
                    FileDiffRow(path: path, patch: patch, initiallyOpen: true)
                }
            }
        case .interaction(let item):
            if case .interaction(let card) = item.kind, card.status != .pending {
                ReadingColumn { InteractionRecordRow(card: card) }
            }
        case .subagent(let item):
            if case .subagent(let event) = item.kind {
                ReadingColumn { SubagentEventRow(event: event) }
            }
        case .notice(let item):
            if case .notice(let notice) = item.kind {
                ReadingColumn { NoticeRow(notice: notice) }
            }
        case .terminal(let item):
            if case .terminal(let title, let isSuccess, let message) = item.kind {
                ReadingColumn {
                    CompletionRow(title: title, isSuccess: isSuccess, message: message)
                }
            }
        }
    }
}

// MARK: - Messages

private struct UserMessageRow: View {
    let content: String
    let attachments: [AttachmentPresentation]
    var messageID: String? = nil
    var turnID: String? = nil
    var sessionID: String? = nil

    @State private var isHovered = false
    @Environment(\.runtimeFrontend) private var runtime

    var body: some View {
        ReadingColumn {
            VStack(alignment: .trailing, spacing: LingXiMetrics.Space.xs) {
                Text(content)
                    .font(.lxBody)
                    .lineSpacing(4.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LingXiMetrics.Space.md)
                    .padding(.vertical, LingXiMetrics.Space.sm)
                    .background(Color.lxUserBubble,
                                in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.bubble, style: .continuous))
                    .frame(maxWidth: LingXiMetrics.Column.userBubble, alignment: .trailing)
                    .contextMenu { MessageContextMenu(copyText: content) }

                if !attachments.isEmpty {
                    AttachmentStrip(attachments: attachments)
                }

                // Hover Action Bar: 复制、编辑、撤回上一轮
                HStack(spacing: 6) {
                    CyberCopyButton(text: content, label: "复制")

                    if let runtime {
                        Button {
                            runtime.editMessage(content: content)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11, weight: .medium))
                                Text("编辑")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundStyle(Color.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            runtime.undoLastTurn()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 11, weight: .medium))
                                Text("撤回上一轮")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundStyle(LingXiTheme.foxfireAmber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .opacity(isHovered ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        }
        .padding(.bottom, LingXiMetrics.Space.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("用户：\(content)")
    }
}

private struct AssistantMessageRow: View {
    let content: String
    @State private var isHovered = false

    var body: some View {
        ReadingColumn {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                Text(content)
                    .font(.lxBody)
                    .lineSpacing(4.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, LingXiMetrics.Space.sm)
                    .contextMenu { MessageContextMenu(copyText: content, asMarkdown: true) }

                // Hover Action Bar: 复制、复制为 Markdown
                HStack(spacing: 6) {
                    CyberCopyButton(text: content, label: "复制")
                    CyberCopyButton(text: content, label: "复制为 Markdown")
                }
                .opacity(isHovered ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Runtime events

/// One timeline event: glyph, title, quiet metadata, optional status and an
/// optional disclosure. Every runtime event shares this shape so they read as
/// a single activity stream rather than a wall of differently styled cards.
struct EventRow<Detail: View>: View {
    let symbol: String
    var symbolStyle: Color? = nil
    let title: Text
    var metadata: String? = nil
    var status: EventStatus = .none
    var hasDetail = true
    @ViewBuilder var detail: Detail

    @State private var isOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(symbol: String,
         symbolStyle: Color? = nil,
         title: Text,
         metadata: String? = nil,
         status: EventStatus = .none,
         hasDetail: Bool = true,
         initiallyOpen: Bool = false,
         @ViewBuilder detail: () -> Detail) {
        self.symbol = symbol
        self.symbolStyle = symbolStyle
        self.title = title
        self.metadata = metadata
        self.status = status
        self.hasDetail = hasDetail
        self.detail = detail()
        self._isOpen = State(initialValue: initiallyOpen && hasDetail)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
            Button {
                guard hasDetail else { return }
                withAnimation(LXMotion.animation(LXMotion.disclosure, reduceMotion: reduceMotion)) {
                    isOpen.toggle()
                }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityValue(hasDetail ? (isOpen ? "已展开" : "已折叠") : "")

            if isOpen {
                detail
                    .padding(.leading, LingXiMetrics.Column.eventGlyph + LingXiMetrics.Space.sm)
                    .padding(.bottom, LingXiMetrics.Space.xs)
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            Image(systemName: symbol)
                .font(.lxCallout)
                .foregroundStyle(symbolStyle.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
                .frame(width: LingXiMetrics.Column.eventGlyph)
                .accessibilityHidden(true)
            title
                .font(.lxCallout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let metadata, !metadata.isEmpty {
                Text(metadata)
                    .font(.lxMeta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: LingXiMetrics.Space.sm)
            EventStatusGlyph(status: status)
            if hasDetail {
                Image(systemName: "chevron.right")
                    .font(.lxMicro.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: LingXiMetrics.Row.event)
        .contentShape(Rectangle())
    }
}

extension EventRow where Detail == EmptyView {
    init(symbol: String, symbolStyle: Color? = nil, title: Text,
         metadata: String? = nil, status: EventStatus = .none) {
        self.init(symbol: symbol, symbolStyle: symbolStyle, title: title,
                  metadata: metadata, status: status, hasDetail: false) { EmptyView() }
    }
}

/// Tool status reduced to what needs attention: success is silent, running
/// spins, waiting and failure are labelled.
enum EventStatus: Equatable {
    case none, running, waiting, failed, cancelled

    init(_ raw: String) {
        let s = raw.lowercased()
        if s.contains("fail") || s.contains("error") { self = .failed }
        else if s.contains("cancel") { self = .cancelled }
        else if s.contains("run") || s.contains("progress") || s.contains("schedul") || s.contains("request") { self = .running }
        else if s.contains("pend") || s.contains("wait") { self = .waiting }
        else { self = .none }
    }
}

struct EventStatusGlyph: View {
    let status: EventStatus

    var body: some View {
        switch status {
        case .none:
            EmptyView()
        case .running:
            HStack(spacing: 4) {
                Circle()
                    .fill(LingXiTheme.neonTeal)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(LingXiTheme.neonTeal.opacity(0.4), lineWidth: 2))
                    .lxNeonGlow(color: LingXiTheme.neonTeal, radius: 4)
                Text("运行中")
                    .font(.lxMicro.weight(.semibold))
                    .foregroundStyle(LingXiTheme.neonTeal)
            }
        case .waiting:
            HStack(spacing: 4) {
                Circle()
                    .fill(LingXiTheme.solarGold)
                    .frame(width: 6, height: 6)
                    .lxNeonGlow(color: LingXiTheme.solarGold, radius: 4)
                Text("等待")
                    .font(.lxMicro.weight(.semibold))
                    .foregroundStyle(LingXiTheme.solarGold)
            }
        case .failed:
            HStack(spacing: 4) {
                Circle()
                    .fill(LingXiTheme.neonCoral)
                    .frame(width: 6, height: 6)
                    .lxNeonGlow(color: LingXiTheme.neonCoral, radius: 4)
                Text("失败")
                    .font(.lxMicro.weight(.semibold))
                    .foregroundStyle(LingXiTheme.neonCoral)
            }
        case .cancelled:
            Label("已取消", systemImage: "slash.circle")
                .font(.lxMeta)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Cyber Thinking Row

struct CyberThinkingRow: View {
    let content: String
    let duration: Double
    let tokens: Int
    let isExpanded: Bool
    @State private var isOpen: Bool

    init(content: String, duration: Double, tokens: Int, isExpanded: Bool) {
        self.content = content
        self.duration = duration
        self.tokens = tokens
        self.isExpanded = isExpanded
        self._isOpen = State(initialValue: isExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
            Button {
                withAnimation(LXMotion.disclosure) {
                    isOpen.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LingXiTheme.electricPurple)

                    Text("思考链")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(LingXiTheme.electricPurple)

                    if duration > 0 || tokens > 0 {
                        Text("· \(String(format: "%.1f", duration))s (\(tokens) tok)")
                            .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("· 思考中…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(LingXiTheme.electricCyan)
                    }

                    Spacer(minLength: LingXiMetrics.Space.sm)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(height: 28)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.35))
                        .overlay(Capsule().strokeBorder(LingXiTheme.electricPurple.opacity(0.3), lineWidth: 0.8))
                )
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                    HStack {
                        Spacer()
                        CyberCopyButton(text: content, label: "复制思考")
                    }
                    Text(content)
                        .font(.lxCallout)
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .padding(LingXiMetrics.Space.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lxInsetBlock()
                }
                .padding(.leading, 8)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Tool Event Row & Categorization

private enum CyberToolCategory {
    case mcp(server: String)
    case skill(name: String)
    case branchPrediction
    case standardTool

    var badgeText: String {
        switch self {
        case .mcp(let s): return "MCP · \(s)"
        case .skill(let s): return "SKILL · \(s)"
        case .branchPrediction: return "BRANCH PREDICT"
        case .standardTool: return "TOOL CALL"
        }
    }

    var themeColor: Color {
        switch self {
        case .mcp: return LingXiTheme.electricCyan
        case .skill: return LingXiTheme.foxfireAmber
        case .branchPrediction: return LingXiTheme.auroraMint
        case .standardTool: return LingXiTheme.solarGold
        }
    }

    var icon: String {
        switch self {
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .skill: return "bolt.shield"
        case .branchPrediction: return "arrow.triangle.branch"
        case .standardTool: return "terminal"
        }
    }

    static func detect(name: String) -> CyberToolCategory {
        let l = name.lowercased()
        if l.contains("branch") || l.contains("predict") || l.contains("speculative") {
            return .branchPrediction
        }
        if l.hasPrefix("mcp_") || l.contains("call_mcp") || l.contains("supermemory") || l.contains("trivy") || l.contains("openapi") || l.contains("context7") || l.contains("codebase-memory") {
            let server: String
            if l.hasPrefix("mcp_") {
                let parts = name.split(separator: "_")
                server = parts.count > 1 ? String(parts[1]) : "Core"
            } else if l.contains("supermemory") {
                server = "Supermemory"
            } else if l.contains("openapi") {
                server = "OpenAPI"
            } else if l.contains("trivy") {
                server = "Trivy"
            } else {
                server = "Remote"
            }
            return .mcp(server: server)
        }
        if l.contains("skill") || l.contains("load_skill") || l.contains("hatch-pet") || l.contains("ponytail") || l.contains("cloudflare") {
            return .skill(name: name.replacingOccurrences(of: "skill_", with: ""))
        }
        return .standardTool
    }
}

struct ToolEventRow: View {
    let call: ToolCallPresentation
    let expandByDefault: Bool
    @State private var isOpen: Bool

    init(call: ToolCallPresentation, expandByDefault: Bool) {
        self.call = call
        self.expandByDefault = expandByDefault
        let autoOpen = expandByDefault || TimelineDisclosure.tool(name: call.toolName, status: call.status, hasOutput: call.output != nil)
        self._isOpen = State(initialValue: autoOpen)
    }

    var body: some View {
        let state = EventStatus(call.status)
        let category = CyberToolCategory.detect(name: call.toolName)

        VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
            Button {
                if hasDetail {
                    withAnimation(LXMotion.disclosure) {
                        isOpen.toggle()
                    }
                }
            } label: {
                HStack(spacing: LingXiMetrics.Space.sm) {
                    // Category icon
                    Image(systemName: category.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(category.themeColor)
                        .frame(width: 20)

                    // Category Pill
                    Text(category.badgeText)
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(category.themeColor.opacity(0.18), in: Capsule())
                        .overlay(Capsule().strokeBorder(category.themeColor.opacity(0.4), lineWidth: 0.5))
                        .foregroundStyle(category.themeColor)

                    // Command summary / tool name
                    Text(call.summary)
                        .font(ToolGlyph.isCommand(call.toolName) ? .system(size: 13, design: .monospaced) : .system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)

                    if let ms = call.durationMs {
                        Text(DurationText.format(milliseconds: ms))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: LingXiMetrics.Space.sm)

                    // State Glyph
                    EventStatusGlyph(status: state)

                    if hasDetail {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                }
                .padding(.horizontal, LingXiMetrics.Space.md)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.65))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(category.themeColor.opacity(0.3), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)

            if isOpen && hasDetail {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                    if let cwd = call.workingDirectory {
                        Label(cwd, systemImage: "folder")
                            .font(.lxMeta)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if let output = call.output, !output.isEmpty { OutputBlock(text: output) }
                    if let stderr = call.stderr, !stderr.isEmpty {
                        Text("stderr").font(.lxMeta).foregroundStyle(LingXiTheme.neonCoral)
                        OutputBlock(text: stderr)
                    }
                }
                .padding(.leading, LingXiMetrics.Space.md)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
    }

    private var hasDetail: Bool {
        !(call.output ?? "").isEmpty || !(call.stderr ?? "").isEmpty || call.workingDirectory != nil
    }
}

private struct ContextGroupRow: View {
    let group: TimelineRow.ContextGroup

    var body: some View {
        EventRow(symbol: "doc.text.magnifyingglass",
                 title: Text("上下文"),
                 metadata: group.countsSummary) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.items) { item in
                    if case .tool(let call) = item.kind {
                        HStack(spacing: LingXiMetrics.Space.sm) {
                            Text(call.summary)
                                .font(.lxCallout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(call.toolName)
                                .font(.lxMeta)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                            EventStatusGlyph(status: EventStatus(call.status))
                        }
                        .frame(minHeight: LingXiMetrics.Row.list)
                    }
                }
            }
        }
    }
}

private struct DiffSummaryRow: View {
    let summary: TimelineRow.DiffSummary

    var body: some View {
        EventRow(symbol: "plus.forwardslash.minus",
                 title: Text("改动 \(summary.files.count) 个文件  ")
                    + Text("+\(summary.additions)").foregroundColor(.green).monospacedDigit()
                    + Text(" −\(summary.deletions)").foregroundColor(.red).monospacedDigit()) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(summary.items) { item in
                    if case .diff(let path, let patch) = item.kind {
                        FileDiffRow(path: path, patch: patch, initiallyOpen: false)
                    }
                }
            }
        }
        .accessibilityLabel("改动 \(summary.files.count) 个文件，新增 \(summary.additions) 行，删除 \(summary.deletions) 行")
    }
}

private struct FileDiffRow: View {
    let path: String
    let patch: String
    let initiallyOpen: Bool

    var body: some View {
        EventRow(symbol: "doc.text",
                 title: Text(path).font(.lxMono),
                 initiallyOpen: initiallyOpen) {
            OutputBlock(text: patch, isDiff: true)
        }
    }
}

/// Completion / failure marker closing a turn: glyph + one line of text,
/// then a hairline that runs to the edge of the column.
private struct CompletionRow: View {
    let title: String
    let isSuccess: Bool
    let message: String

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            Image(systemName: isSuccess ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .font(.lxCallout)
                .foregroundStyle(isSuccess ? Color.green : Color.red)
                .frame(width: LingXiMetrics.Column.eventGlyph)
            Text(title)
                .font(.lxCallout.weight(.medium))
                .foregroundStyle(isSuccess ? Color.secondary : Color.red)
            Text(message)
                .font(.lxMeta)
                .foregroundStyle(isSuccess ? .tertiary : .secondary)
                .lineLimit(isSuccess ? 1 : nil)
                .fixedSize(horizontal: false, vertical: true)
            VStack { Divider() }
        }
        .frame(minHeight: LingXiMetrics.Row.event)
        .padding(.vertical, LingXiMetrics.Space.xs)
        .accessibilityElement(children: .combine)
    }
}

/// Resolved permission / question kept in the timeline as a one-line record.
private struct InteractionRecordRow: View {
    let card: InteractionCardPresentation

    var body: some View {
        EventRow(symbol: card.kind == .permission ? "lock.shield" : "questionmark.bubble",
                 symbolStyle: card.status == .rejected ? .orange : nil,
                 title: Text(title),
                 metadata: card.kind == .permission ? card.toolName : nil)
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
        EventRow(symbol: "person.2",
                 symbolStyle: EventStatus(event.status) == .failed ? .red : nil,
                 title: Text("子 Agent \(event.runID.suffix(8))"),
                 metadata: [event.status, event.terminalReason].compactMap { $0 }.joined(separator: " · "),
                 status: EventStatus(event.status))
    }
}

/// Runtime condition affecting the task. Errors keep full weight; info stays quiet.
private struct NoticeRow: View {
    let notice: NoticePresentation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LingXiMetrics.Space.sm) {
            Image(systemName: symbol)
                .font(.lxCallout)
                .foregroundStyle(tint)
                .frame(width: LingXiMetrics.Column.eventGlyph)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.lxCallout.weight(notice.level == .error ? .medium : .regular))
                    .foregroundStyle(notice.level == .info ? Color.secondary : tint)
                if !notice.message.isEmpty {
                    Text(notice.message)
                        .font(.lxMeta)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, LingXiMetrics.Space.xs)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch notice.level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch notice.level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

enum DurationText {
    static func format(milliseconds ms: Double) -> String {
        if ms < 1000 { return String(format: "%.0f ms", ms) }
        let seconds = ms / 1000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return String(format: "%.0fm %02.0fs", (seconds / 60).rounded(.down), seconds.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: - Shared content blocks

/// Read-only monospaced output, capped in height and scrolled internally.
/// Diffs colour added / removed lines with system semantic colours.
struct OutputBlock: View {
    let text: String
    var isDiff = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                rendered
                    .font(.lxMono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LingXiMetrics.Space.sm)
                    .padding(.top, 14)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: LingXiMetrics.outputMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .lxInsetBlock()

            CyberCopyButton(text: text)
                .padding(6)
        }
    }

    private var rendered: Text {
        guard isDiff else { return Text(text) }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .reduce(Text("")) { acc, pair in
                let line = String(pair.element)
                let piece = Text(pair.offset == 0 ? line : "\n" + line)
                if line.hasPrefix("+"), !line.hasPrefix("+++") { return acc + piece.foregroundColor(.green) }
                if line.hasPrefix("-"), !line.hasPrefix("---") { return acc + piece.foregroundColor(.red) }
                if line.hasPrefix("@@") { return acc + piece.foregroundColor(.secondary) }
                return acc + piece
            }
    }
}

/// Message context menu. Fork / revert need task-side RPCs that are still stubs,
/// so only copy actions that can actually be honoured are offered.
struct MessageContextMenu: View {
    let copyText: String
    var asMarkdown = false

    var body: some View {
        Button("复制") { copy(copyText) }
        if asMarkdown {
            Button("复制为 Markdown") { copy(copyText) }
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        #endif
    }
}

struct AttachmentStrip: View {
    let attachments: [AttachmentPresentation]

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.md) {
            ForEach(attachments) { att in
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Image(systemName: att.thumbnailSymbol)
                        .foregroundStyle(.secondary)
                    Text(att.filename)
                        .font(.lxCallout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(att.formattedSize)
                        .font(.lxMeta)
                        .foregroundStyle(.tertiary)
                    if !att.isUploaded {
                        ProgressView().controlSize(.mini)
                    }
                }
                .frame(maxWidth: 220, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - SF Symbols per tool

enum ToolGlyph {
    static func symbol(for name: String) -> String {
        switch name {
        case "shell", "process", "run_background_command", "manage_background_command": return "terminal"
        case "read", "read_file": return "doc.text"
        case "edit_file", "write_file", "apply_patch", "format_file": return "pencil.line"
        case "glob", "grep", "list_directory": return "magnifyingglass"
        case "web_fetch", "web_search": return "globe"
        case "codebase_graph": return "point.3.connected.trianglepath.dotted"
        case "mcp", "load_tool", "search_tools", "extension-management": return "puzzlepiece.extension"
        case "code_intelligence", "symbol_lookup", "find_references", "dependency_query": return "curlybraces"
        case "browser_act", "browser_navigate", "computer_batch": return "safari"
        case "subagent": return "person.2"
        case "git": return "arrow.triangle.branch"
        case "question": return "questionmark.bubble"
        case "todo": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }

    static func isCommand(_ name: String) -> Bool {
        ["shell", "process", "run_background_command", "manage_background_command"].contains(name)
    }

    /// Tools whose approval can change the machine; used to raise the
    /// permission surface's visual weight.
    static func isElevated(_ name: String) -> Bool {
        switch name {
        case "shell", "process", "run_background_command", "write_file", "edit_file",
             "apply_patch", "git", "computer_batch", "browser_act":
            return true
        default:
            return false
        }
    }
}

#endif
