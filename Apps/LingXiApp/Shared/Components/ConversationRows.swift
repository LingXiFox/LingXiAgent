#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Row dispatch
//
// Hierarchy is carried by typography, not containers:
// user bubble > assistant body > runtime events (callout, secondary) > metadata (tertiary).

struct TimelineRowView: View {
    let row: TimelineRow
    @Environment(\.timelineDisclosureDefaults) private var defaults

    var body: some View {
        switch row {
        case .user(let item):
            if case .user(let content, let attachments) = item.kind {
                UserMessageRow(content: content, attachments: attachments)
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
            // Pending requests surface above the composer; the timeline keeps the resolved record.
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

    var body: some View {
        ReadingColumn {
            VStack(alignment: .trailing, spacing: LingXiMetrics.Space.xs) {
                Text(content)
                    .font(.lxBody)
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
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.bottom, LingXiMetrics.Space.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("用户：\(content)")
    }
}

private struct AssistantMessageRow: View {
    let content: String

    var body: some View {
        ReadingColumn {
            Text(content)
                .font(.lxBody)
                .lineSpacing(LingXiMetrics.Space.xs / 2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, LingXiMetrics.Space.sm)
                .contextMenu { MessageContextMenu(copyText: content, asMarkdown: true) }
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

/// 赛博心电波动图（零 GPU 压力，纯矢量 Path 硬件加速绘制）
struct CyberSparkline: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            guard w > 10, h > 4 else { return }

            let points: [CGFloat] = [0.4, 0.45, 0.65, 0.25, 0.85, 0.30, 0.70, 0.15, 0.90, 0.40, 0.50, 0.48]
            var path = Path()
            let step = w / CGFloat(points.count - 1)
            let startY = h * (1.0 - points[0])
            path.move(to: CGPoint(x: 0, y: startY))

            for i in 1..<points.count {
                let x = CGFloat(i) * step
                let y = h * (1.0 - points[i])
                path.addLine(to: CGPoint(x: x, y: y))
            }

            var fillPath = path
            fillPath.addLine(to: CGPoint(x: w, y: h))
            fillPath.addLine(to: CGPoint(x: 0, y: h))
            fillPath.closeSubpath()

            let fillGrad = Gradient(colors: [color.opacity(0.22), color.opacity(0.0)])
            context.fill(fillPath, with: .linearGradient(fillGrad, startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }
        .frame(height: 18)
        .allowsHitTesting(false)
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
                HStack(spacing: LingXiMetrics.Space.sm) {
                    // Purple-gold thinking emblem
                    ZStack {
                        Circle()
                            .fill(LingXiTheme.electricPurple.opacity(0.2))
                            .frame(width: 22, height: 22)
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LingXiTheme.electricPurple)
                    }

                    HStack(spacing: 6) {
                        Text("思考链")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(LingXiTheme.electricPurple.opacity(0.18), in: Capsule())
                            .overlay(Capsule().strokeBorder(LingXiTheme.electricPurple.opacity(0.4), lineWidth: 0.5))
                            .foregroundStyle(LingXiTheme.electricPurple)

                        if duration > 0 || tokens > 0 {
                            Text("\(String(format: "%.1f", duration))s · \(tokens) tok")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("思考中…")
                                .font(.caption)
                                .foregroundStyle(LingXiTheme.electricCyan)
                        }
                    }

                    Spacer(minLength: LingXiMetrics.Space.sm)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, LingXiMetrics.Space.md)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(LingXiTheme.electricPurple.opacity(0.3), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    CyberSparkline(color: LingXiTheme.electricPurple)
                    Text(content)
                        .font(.lxCallout)
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .padding(.horizontal, LingXiMetrics.Space.md)
                        .padding(.vertical, LingXiMetrics.Space.xs)
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
                    CyberSparkline(color: state == .failed ? LingXiTheme.neonCoral : category.themeColor)
                        .padding(.vertical, 2)

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
        ScrollView {
            rendered
                .font(.lxMono)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LingXiMetrics.Space.sm)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: LingXiMetrics.outputMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .lxInsetBlock()
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
