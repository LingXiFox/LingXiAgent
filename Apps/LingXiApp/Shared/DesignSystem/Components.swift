import SwiftUI
import AppKit

// MARK: - Components
//
// The shared component set. Colour discipline lives here so no page can invent
// a second accent: state is icon + text, colour lands on the icon or dot only.

// MARK: Badge

/// 20 tall, radius-sm, micro. Neutral for categories, accent for the active
/// mode or goal, outline for static metadata. Never expresses success/failure.
public struct LXBadge: View {
    public enum Kind: Sendable { case neutral, accent, outline }

    let text: String
    let kind: Kind
    let systemImage: String?

    public init(_ text: String, kind: Kind = .neutral, systemImage: String? = nil) {
        self.text = text
        self.kind = kind
        self.systemImage = systemImage
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: LingXiMetrics.Radius.sm, style: .continuous)
        HStack(spacing: LingXiMetrics.Space.xs) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 11))
            }
            Text(text)
        }
        .font(LXType.micro)
        .lineLimit(1)
        .foregroundStyle(kind == .accent ? AnyShapeStyle(LXColor.accentText) : AnyShapeStyle(.primary))
        .padding(.horizontal, LingXiMetrics.Space.sm)
        .frame(height: LXControl.badge)
        .background(kind == .neutral ? LXColor.fillQuinary : kind == .accent ? LXColor.accentSoft : .clear, in: shape)
        .overlay { if kind == .outline { shape.strokeBorder(LXColor.separator, lineWidth: 1) } }
        .fixedSize()
    }
}

// MARK: Status

/// 6pt dot. No glow, no pulse. Always paired with a text label somewhere.
public struct LXActivityDot: View {
    public enum Tone: Sendable { case running, thinking, accent, warning, danger }

    let tone: Tone
    let label: String

    public init(tone: Tone = .running, accessibilityLabel: String = "执行中") {
        self.tone = tone
        self.label = accessibilityLabel
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: LXControl.dot, height: LXControl.dot)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch tone {
        case .running: return LXStatus.running
        case .thinking: return LXStatus.thinking
        case .accent: return LXStatus.actionRequired
        case .warning: return LXStatus.warning
        case .danger: return LXStatus.error
        }
    }
}

/// Native small ring progress tinted running (Teal) or thinking (Indigo).
public struct LXSpinner: View {
    public enum Tone: Sendable { case running, thinking }
    let tone: Tone

    public init(tone: Tone = .running) { self.tone = tone }

    public var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.mini)
            .tint(tone == .thinking ? LXStatus.thinking : LXStatus.running)
            .frame(width: LXControl.spinner, height: LXControl.spinner)
    }
}

/// Status line: tinted icon, label stays text-primary (or secondary when muted).
public struct LXStatusText: View {
    public enum Tone: Sendable { case neutral, success, warning, danger, muted }

    let text: String
    let systemImage: String
    let tone: Tone

    public init(_ text: String, systemImage: String, tone: Tone = .neutral) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
    }

    public var body: some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            Image(systemName: systemImage)
                .font(.system(size: LXIcon.small, weight: .medium))
                .foregroundStyle(iconColor)
            Text(text)
                .font(LXType.meta)
                .foregroundStyle(tone == .muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .accessibilityElement(children: .combine)
    }

    private var iconColor: Color {
        switch tone {
        case .neutral, .muted: return .secondary
        case .success: return LXStatus.success
        case .warning: return LXStatus.warning
        case .danger: return LXStatus.error
        }
    }
}

/// Task state: protocol string → Chinese label + SF Symbol.
public struct LXTaskStatusBadge: View {
    let rawState: String

    public init(state: String) { self.rawState = state }

    public var body: some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            switch Self.normalize(rawState) {
            case .running:
                LXActivityDot(tone: .running, accessibilityLabel: label)
            case let state:
                Image(systemName: Self.symbol(state))
                    .font(.system(size: LXIcon.status))
                    .foregroundStyle(Self.tint(state))
            }
            Text(label)
                .font(LXType.meta)
                .foregroundStyle(isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("任务状态 \(label)")
    }

    enum State { case queued, running, paused, waiting, completed, failed, cancelled }

    static func normalize(_ raw: String) -> State {
        switch raw.lowercased() {
        case "in_progress", "running", "active": return .running
        case "paused": return .paused
        case "waiting", "blocked", "needs_answer", "waitingforuser", "waitingforquestion",
             "waitingforpermission", "waitingfordecision", "recoveryrequired": return .waiting
        case "completed", "done", "success": return .completed
        case "failed", "error", "providerfailure", "runtimefailure", "deadlineexceeded",
             "maxstepsreached", "emptycompletion": return .failed
        case "cancelled", "canceled", "usercancelled": return .cancelled
        default: return .queued
        }
    }

    private var label: String {
        switch Self.normalize(rawState) {
        case .queued: return "排队中"
        case .running: return "执行中"
        case .paused: return "已暂停"
        case .waiting: return "待回答"
        case .completed: return "已完成"
        case .failed: return "已失败"
        case .cancelled: return "已取消"
        }
    }

    private var isMuted: Bool {
        let state = Self.normalize(rawState)
        return state == .queued || state == .cancelled
    }

    private static func symbol(_ state: State) -> String {
        switch state {
        case .queued: return "circle.dotted"
        case .running: return "circle"
        case .paused: return "pause.circle"
        case .waiting: return "clock"
        case .completed: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .cancelled: return "slash.circle"
        }
    }

    private static func tint(_ state: State) -> Color {
        switch state {
        case .queued, .running, .cancelled: return .secondary
        case .paused, .waiting: return LXStatus.warning
        case .completed: return LXStatus.success
        case .failed: return LXStatus.error
        }
    }
}

/// Trailing state of one timeline event. Completed / idle draws nothing.
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
            row("运行中") { LXSpinner(tone: .running) }
        case .waiting:
            row("等待") { LXActivityDot(tone: .warning, accessibilityLabel: "等待") }
        case .failed:
            row("失败") { LXActivityDot(tone: .danger, accessibilityLabel: "失败") }
        case .cancelled:
            LXStatusText("已取消", systemImage: "slash.circle", tone: .muted)
        }
    }

    private func row<Mark: View>(_ label: String, @ViewBuilder _ mark: () -> Mark) -> some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            mark()
            Text(label).font(LXType.meta).foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Copy

/// 22 tall copy button. Copied state swaps the icon to a success-tinted check
/// for 1.5s; the label never turns green.
public struct LXCopyButton: View {
    let payload: String
    let label: String?
    @State private var copied = false

    public init(_ payload: String, label: String? = nil) {
        self.payload = payload
        self.label = label
    }

    public var body: some View {
        Button(action: copy) {
            HStack(spacing: LingXiMetrics.Space.xs) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copied ? AnyShapeStyle(LXStatus.success) : AnyShapeStyle(.primary))
                if let label {
                    Text(copied ? "已复制" : label).font(LXType.micro.weight(.medium))
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, LingXiMetrics.Space.sm)
            .frame(height: LXControl.small)
            .background(LXColor.fillControl,
                        in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label ?? "复制")
        .accessibilityLabel(label ?? "复制")
    }

    private func copy() {
        LXPasteboard.copy(payload)
        withAnimation(LXMotion.disclosure) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(LXMotion.disclosure) { copied = false }
        }
    }
}

enum LXPasteboard {
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

// MARK: Meter

/// Determinate progress: 6pt pill, fill-control track, accent fill.
public struct LXMeter: View {
    let fraction: Double
    let label: String

    public init(fraction: Double, label: String) {
        self.fraction = min(max(fraction, 0), 1)
        self.label = label
    }

    public var body: some View {
        Capsule()
            .fill(LXColor.fillControl)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(LXColor.accent).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: LXControl.dot)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(fraction * 100))%")
    }
}

// MARK: Sections

/// Key–value row: key text-secondary, value text-primary, meta, 20pt line.
public struct LXKVRow: View {
    let key: String
    let value: AnyView

    public init(_ key: String, value: some View) {
        self.key = key
        self.value = AnyView(value)
    }

    public init(_ key: String, value: String) {
        self.init(key, value: Text(value))
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LingXiMetrics.Space.md) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: LingXiMetrics.Space.sm)
            value
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(LXType.meta)
        .frame(minHeight: 20)
    }
}

/// Section head: 12.5 semibold text-secondary, right value back to regular.
public struct LXSectionHead<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    public init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LingXiMetrics.Space.sm) {
            Text(title)
                .font(LXType.sectionHead)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: LingXiMetrics.Space.sm)
            accessory
                .font(LXType.meta)
                .foregroundStyle(.secondary)
        }
    }
}

public extension LXSectionHead where Accessory == Text {
    init(_ title: String, detail: String) {
        self.init(title) { Text(detail) }
    }
}

/// Continuous-document section: head + content, `space-md` vertical padding,
/// a hairline above every section but the first. No card.
public struct LXSection<Accessory: View, Content: View>: View {
    let title: String
    let separated: Bool
    let accessory: Accessory
    let content: Content

    public init(_ title: String, separated: Bool = true,
                @ViewBuilder accessory: () -> Accessory = { EmptyView() },
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.separated = separated
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
            LXSectionHead(title) { accessory }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, LingXiMetrics.Space.md)
        .overlay(alignment: .top) { if separated { LXHairline() } }
    }
}

/// 1px separator.
public struct LXHairline: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(LXColor.separator).frame(height: 1).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// One complete sentence saying why a slot is empty. Never a fake row.
public struct PlaceholderLine: View {
    let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(LXType.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Footnote under a group: 12/17 text-secondary.
public struct LXFootnote: View {
    let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Tools

/// Tool name → fixed SF Symbol. Icons stay text-secondary, never per-category colour.
public enum LXToolGlyph {
    public static func symbol(for toolName: String) -> String {
        let name = toolName.lowercased()
        if name.hasPrefix("mcp") || name.contains("mcp_") || name.contains(".mcp.") { return "puzzlepiece.extension" }
        if name.contains("lsp") || name.contains("diagnostic") || name.contains("symbol")
            || name.contains("code_intelligence") || name.contains("references") { return "curlybraces" }
        if name.contains("browser") { return "safari" }
        if name.contains("computer") { return "cursorarrow.rays" }
        if name.contains("graph") || name.contains("codebase") || name.contains("dependency") {
            return "point.3.connected.trianglepath.dotted"
        }
        if name.contains("subagent") || name.hasPrefix("agent") { return "person.2" }
        if isCommand(name) || name.contains("terminal") || name.contains("bash") || name.contains("shell") { return "terminal" }
        if name.contains("edit") || name.contains("write") || name.contains("patch") || name.contains("format") { return "pencil" }
        if name.contains("http") || name.contains("fetch") || name.contains("web") || name.contains("network") { return "network" }
        if name.contains("grep") || name.contains("search") || name.contains("glob") { return "text.magnifyingglass" }
        if name.contains("read") || name.contains("list") || name.contains("file") { return "doc.text" }
        if name == "git" { return "arrow.triangle.branch" }
        return "wrench.and.screwdriver"
    }

    /// Tools whose summary is a shell command, shown in mono.
    public static func isCommand(_ name: String) -> Bool {
        ["shell", "process", "run_background_command", "manage_background_command", "bash"].contains(name.lowercased())
    }

    /// Tools whose approval can change the machine: the permission head turns warning.
    public static func isElevated(_ name: String) -> Bool {
        ["shell", "process", "run_background_command", "write_file", "edit_file",
         "apply_patch", "git", "computer_batch", "browser_act"].contains(name.lowercased())
    }
}

enum DurationText {
    /// <1s → ms, <60s → one decimal seconds, else m ss.
    static func format(milliseconds ms: Double) -> String {
        if ms < 1000 { return String(format: "%.0f ms", ms) }
        let seconds = ms / 1000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds / 60)
        return String(format: "%d 分 %02d 秒", minutes, Int(seconds) % 60)
    }
}

// MARK: Output block

/// Mono read-only output: fill-quinary, radius-inset, capped at output-max and
/// scrolling inside. Diffs tint the leading sign and the row wash only; the
/// text itself stays text-primary. A copy button appears on hover.
struct OutputBlock: View {
    let text: String
    var isDiff = false
    @State private var isHovered = false

    var body: some View {
        ScrollView {
            Group {
                if isDiff {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(DiffLine.lines(from: text).enumerated()), id: \.offset) { _, line in
                            diffRow(line)
                        }
                    }
                    .padding(.vertical, LingXiMetrics.Space.sm)
                } else {
                    Text(text)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(LingXiMetrics.Space.md)
                }
            }
            .font(LXType.monoSmall)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: LingXiMetrics.outputMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(LXColor.fillQuinary,
                    in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.inset, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isHovered {
                LXCopyButton(text).padding(6).transition(.opacity)
            }
        }
        .onHover { isHovered = $0 }
    }

    private func diffRow(_ line: DiffLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.sign)
                .fontWeight(.semibold)
                .foregroundStyle(line.signColor)
                .frame(width: 14, alignment: .leading)
            Text(line.body)
                .foregroundStyle(line.kind == .hunk ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LingXiMetrics.Space.md)
        .background(line.rowBackground)
        .accessibilityElement(children: .combine)
    }
}

struct DiffLine {
    enum Kind { case add, remove, hunk, context }
    let kind: Kind
    let sign: String
    let body: String

    static func lines(from text: String) -> [DiffLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            if line.hasPrefix("+"), !line.hasPrefix("+++") { return DiffLine(kind: .add, sign: "+", body: pad(line.dropFirst())) }
            if line.hasPrefix("-"), !line.hasPrefix("---") { return DiffLine(kind: .remove, sign: "−", body: pad(line.dropFirst())) }
            if line.hasPrefix("@@") { return DiffLine(kind: .hunk, sign: "", body: line) }
            return DiffLine(kind: .context, sign: " ", body: pad(line.dropFirst()))
        }
    }

    private static func pad(_ s: Substring) -> String { s.isEmpty ? " " : String(s) }

    var signColor: Color {
        switch kind {
        case .add: return LXStatus.success
        case .remove: return LXStatus.error
        case .hunk, .context: return .secondary
        }
    }

    var rowBackground: Color {
        switch kind {
        case .add: return LXColor.diffAdd
        case .remove: return LXColor.diffRemove
        case .hunk, .context: return .clear
        }
    }
}

/// `+14` / `−3`: 6pt status dot + text-primary tabular digits.
struct LXDiffCount: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            count("+\(additions)", tint: LXStatus.success)
            count("−\(deletions)", tint: LXStatus.error)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("新增 \(additions) 行，删除 \(deletions) 行")
    }

    private func count(_ text: String, tint: Color) -> some View {
        HStack(spacing: LingXiMetrics.Space.xs) {
            Circle().fill(tint).frame(width: LXControl.dot, height: LXControl.dot)
            Text(text).monospacedDigit().foregroundStyle(.primary)
        }
        .fixedSize()
    }
}

// MARK: Brand mark

/// Stand-in mark until the real logo lands: 18-radius block (ink in light,
/// milk in dark), two concentric rings in bg-content, a 4pt accent dot.
public struct LXBrandMark: View {
    var side: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(side: CGFloat = 64) { self.side = side }

    public var body: some View {
        let unit = side / 64
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18 * unit, style: .continuous)
                .fill(colorScheme == .dark ? LXBrand.milk50 : LXBrand.ink900)
            RoundedRectangle(cornerRadius: 10 * unit, style: .continuous)
                .stroke(LXColor.content, lineWidth: 1.5)
                .frame(width: 44 * unit, height: 44 * unit)
                .offset(x: 10 * unit, y: 10 * unit)
            RoundedRectangle(cornerRadius: 4 * unit, style: .continuous)
                .stroke(LXColor.content, lineWidth: 1.5)
                .frame(width: 28 * unit, height: 28 * unit)
                .offset(x: 18 * unit, y: 18 * unit)
            Circle()
                .fill(LXColor.accent)
                .frame(width: 8 * unit, height: 8 * unit)
                .offset(x: 42 * unit, y: 14 * unit)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

// MARK: Sidebar row

/// Navigator row: 34 tall, 6pt outer margin, 0 × 8 inset, radius-inset.
/// Selection is neutral fill-control with the icon in accent-text — never the
/// system accent, never Indigo or Teal.
public struct LXSidebarRow<Trailing: View>: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    let trailing: Trailing
    @State private var isHovered = false

    public init(_ title: String, symbol: String, isSelected: Bool, action: @escaping () -> Void,
                @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.symbol = symbol
        self.isSelected = isSelected
        self.action = action
        self.trailing = trailing()
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: LingXiMetrics.Space.sm) {
                Image(systemName: symbol)
                    .font(.system(size: LXIcon.row))
                    .foregroundStyle(isSelected ? AnyShapeStyle(LXColor.accentText) : AnyShapeStyle(.secondary))
                    .frame(width: 18)
                Text(title)
                    .font(LXType.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, LingXiMetrics.Space.sm)
            .frame(height: LingXiMetrics.Size.rowList)
            .background(isSelected ? LXColor.fillControl : (isHovered ? LXColor.fillQuinary : .clear),
                        in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.inset, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Sidebar section head: 600 11.5/14 text-secondary.
public struct LXSidebarSectionHead: View {
    let title: String
    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title)
            .font(LXType.micro)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LingXiMetrics.Space.panelInset)
            .padding(.top, LingXiMetrics.Space.sm)
            .padding(.bottom, LingXiMetrics.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }
}
