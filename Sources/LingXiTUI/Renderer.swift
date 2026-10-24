import Foundation
import LingXiSettingsProtocol

struct RGB: Equatable, Hashable {
    let r: Int, g: Int, b: Int
    init(_ r: Int, _ g: Int, _ b: Int) { self.r = r; self.g = g; self.b = b }
    var fg: String { "\u{1B}[38;2;\(r);\(g);\(b)m" }
    var bg: String { "\u{1B}[48;2;\(r);\(g);\(b)m" }
}

enum Theme {
    static let charcoal = RGB(22, 24, 28)
    static let charcoalRaised = RGB(32, 35, 41)
    static let overlay = RGB(40, 44, 52)
    static let selection = RGB(58, 52, 48)
    static let cream = RGB(230, 232, 237)
    static let fox = RGB(239, 177, 123)
    static let dim = RGB(150, 157, 168)
    static let muted = RGB(88, 95, 106)
    static let error = RGB(255, 139, 149)
    static let success = RGB(152, 199, 140)
    static let link = RGB(130, 178, 232)
    static let string = RGB(166, 207, 140)
    static let number = RGB(214, 160, 220)
    static let type = RGB(126, 200, 212)
    // Reset text attributes without falling back to the terminal profile's background.
    static let reset = "\u{1B}[0m" + charcoal.bg + cream.fg
}

struct Style: Equatable {
    var fg: RGB = Theme.cream
    /// nil keeps whatever background the cell already has (row fills, panels).
    var bg: RGB? = nil
    var bold = false
    var italic = false
    var underline = false
    var strike = false

    static let plain = Style()
    static func color(_ fg: RGB, bold: Bool = false) -> Style { Style(fg: fg, bold: bold) }

    func sgr(background: RGB) -> String {
        var codes = "\u{1B}[0m"
        if bold { codes += "\u{1B}[1m" }
        if italic { codes += "\u{1B}[3m" }
        if underline { codes += "\u{1B}[4m" }
        if strike { codes += "\u{1B}[9m" }
        return codes + fg.fg + background.bg
    }
}

struct Span {
    var text: String
    var style: Style
    init(_ text: String, _ style: Style = .plain) { self.text = text; self.style = style }
}

/// One laid-out row of content. `fill` paints the whole content width (code blocks, user turns).
struct Line {
    var spans: [Span]
    var fill: RGB? = nil
    static let blank = Line(spans: [])
}

enum Role: Equatable { case user, assistant, reasoning, tool, toolResult, system, error }
struct Message {
    var role: Role
    var text: String
    var streaming: Bool = false
    /// Dim footer under an assistant reply: duration, token usage.
    var meta: String? = nil
    /// Compact run diagnostic under the meta line. Numbers only, never request or response text.
    var diagnostics: String? = nil
}

struct MenuItem {
    let title: String
    let detail: String
    let command: String
    /// Set for toggle lists (plugins): Space flips it, Enter saves the whole list.
    var checked: Bool? = nil
}

struct Picker {
    let title: String
    var items: [MenuItem]
    var query = ""
    var selected = 0
    var isToggleList: Bool { items.contains { $0.checked != nil } }
    var filtered: [MenuItem] {
        guard !query.isEmpty else { return items }
        return items.filter { ($0.title + " " + $0.detail + " " + $0.command).localizedCaseInsensitiveContains(query) }
    }
}

struct AuthPrompt {
    let label: String
    let characterCount: Int
}

struct StatusLine {
    var left: [Span]
    var right: String
}

/// Everything one frame needs. The renderer never sees a secret: the auth panel gets a count only.
struct ViewState {
    var messages: [Message] = []
    var scroll = 0
    var input: [Character] = []
    var cursor = 0
    var model: String?
    /// Live protocol family of the current model, from the Core's provider state.
    var modelProtocol: String?
    /// Plugin-declared thinking level of the current model, when one was declared.
    var modelThinking: String?
    /// True when that level is a temporary frontend selection instead of the plugin's own setting.
    var modelThinkingTemporary = false
    var sessionTitle = ""
    var workspace = ""
    var status = StatusLine(left: [], right: "")
    var feedback: Message?
    var picker: Picker?
    var completion: Picker?
    var settings: SettingsSnapshot?
    var settingsBusy = false
    var settingsError: String?
    var confirmation: Confirmation?
    /// Host-owned "unsaved changes" prompt; drawn above the settings panel.
    var exitDialog: ExitDialog?
    var auth: AuthPrompt?
    var showThinking = false
    var running = false
}

/// One clickable region of the last drawn frame, in 1-based screen cells — the same coordinates a
/// terminal mouse report carries. The renderer owns layout, so it is the only place that can produce
/// these without duplicating geometry in the event loop.
struct HitRegion: Equatable {
    enum Kind: Equatable {
        /// One row of a picker or plugin list, by index into its *filtered* items. A toggle row
        /// reports two regions: its checkbox cells, and the rest of the row.
        case pickerRow(index: Int, checkbox: Bool)
        /// One row of the slash-command completion list.
        case completionRow(index: Int)
        /// One host-owned dialog button, by drawing order.
        case dialogButton(index: Int)
        /// The plugin-owned cell area inside the settings frame. Row 0 / column 0 of this region is
        /// the origin the plugin's own mouse coordinates count from.
        case settingsFrame
    }

    var kind: Kind
    var row: Int
    var rows = 1
    var column: Int
    var columns: Int

    func contains(row target: Int, column targetColumn: Int) -> Bool {
        (row..<(row + rows)).contains(target) && (column..<(column + columns)).contains(targetColumn)
    }
}

struct FrameInfo {
    var bodyLines = 0
    var bodyHeight = 0
    /// Clickable regions produced by this draw. Empty when nothing on screen is interactive.
    var hits: [HitRegion] = []
}

/// Where a modal panel ended up, in 0-based canvas cells. Callers use it to map body rows back to
/// the items they drew without repeating the layout arithmetic.
private struct PanelGeometry {
    var top: Int
    var left: Int
    var inner: Int
    var bodyRows: Int
}

/// Lays out messages once per (content, width) and reuses the result while other parts redraw.
final class LineCache {
    private var store: [Int: (key: Int, lines: [Line])] = [:]

    func lines(index: Int, message: Message, width: Int, showThinking: Bool, build: () -> [Line]) -> [Line] {
        var hasher = Hasher()
        hasher.combine(message.text)
        hasher.combine(message.streaming)
        hasher.combine(message.meta)
        hasher.combine(message.diagnostics)
        hasher.combine(width)
        hasher.combine(showThinking)
        hasher.combine("\(message.role)")
        let key = hasher.finalize()
        if let hit = store[index], hit.key == key { return hit.lines }
        let lines = build()
        store[index] = (key, lines)
        return lines
    }

    func trim(to count: Int) {
        store = store.filter { $0.key < count }
    }
}

// MARK: - canvas

private struct Cell {
    var text: String = " "
    var style: Style = .plain
    var bg: RGB = Theme.charcoal
    /// Right half of a wide grapheme; never emitted.
    var continuation = false
}

/// A cell frame buffer. Every row is emitted with its own cursor address and erase, so a shorter
/// input or a closed panel cannot leave text from the previous frame on screen.
private struct Canvas {
    let width: Int
    let height: Int
    var cells: [[Cell]]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        cells = Array(repeating: Array(repeating: Cell(), count: width), count: height)
    }

    mutating func fill(row: Int, col: Int, count: Int, bg: RGB) {
        guard (0..<height).contains(row) else { return }
        for x in max(0, col)..<min(width, col + count) {
            cells[row][x] = Cell(bg: bg)
        }
        repair(row: row, col: col)
    }

    /// Draws spans left to right, clipped at `limit` cells. Returns the number of cells used.
    @discardableResult
    mutating func draw(_ spans: [Span], row: Int, col: Int, limit: Int) -> Int {
        guard (0..<height).contains(row), col < width else { return 0 }
        let end = min(width, col + max(0, limit))
        var x = max(0, col)
        repair(row: row, col: x)
        for span in spans {
            for raw in Renderer.clean(span.text) {
                // A raw LF inside a cell-addressed row would scroll the screen.
                let character: Character = raw.isNewline ? " " : raw
                let cells = TextWidth.width(String(character))
                if cells == 0 {
                    if x > col, x - 1 < width { self.cells[row][x - 1].text.append(character) }
                    continue
                }
                guard x + cells <= end else { return x - col }
                let bg = span.style.bg ?? self.cells[row][x].bg
                self.cells[row][x] = Cell(text: String(character), style: span.style, bg: bg)
                if cells == 2 {
                    self.cells[row][x + 1] = Cell(text: "", style: span.style, bg: bg, continuation: true)
                }
                x += cells
            }
        }
        if x < width, cells[row][x].continuation { cells[row][x].text = " "; cells[row][x].continuation = false }
        return x - col
    }

    /// Writing over half of a wide grapheme must blank the other half.
    private mutating func repair(row: Int, col: Int) {
        guard col > 0, col < width, cells[row][col].continuation else { return }
        cells[row][col - 1].text = " "
        cells[row][col].continuation = false
    }

    func emit() -> String {
        var frame = ""
        for (index, row) in cells.enumerated() {
            frame += "\u{1B}[\(index + 1);1H" + Theme.reset + "\u{1B}[2K"
            var last = ""
            for cell in row where !cell.continuation {
                let sgr = cell.style.sgr(background: cell.bg)
                if sgr != last { frame += sgr; last = sgr }
                frame += cell.text
            }
        }
        return frame
    }
}

// MARK: - renderer

struct Renderer {
    let columns: Int
    let rows: Int
    private var width: Int { max(1, columns) }
    private var height: Int { max(1, rows) }
    private var contentWidth: Int { max(1, min(100, width - 6)) }

    func frame(_ view: ViewState, cache: LineCache) -> (text: String, info: FrameInfo) {
        var canvas = Canvas(width: width, height: height)
        var info = FrameInfo()
        var cursor: (row: Int, col: Int)?
        let home = view.messages.isEmpty
        let left = max(0, (width - contentWidth) / 2)

        drawTopBar(view, home: home, into: &canvas)
        if height > 2 { drawStatus(view.status, into: &canvas) }

        let panelWidth = home ? min(76, contentWidth) : contentWidth
        let composerLeft = max(0, (width - panelWidth) / 2)
        let editor = layoutInput(view.input, cursor: view.cursor, limit: max(1, panelWidth - 4))
        let maxLines = max(1, min(8, (height - 8) / 2))
        let firstLine = max(0, min(editor.cursorRow - maxLines + 1, editor.lines.count - maxLines))
        let visibleLines = view.input.isEmpty ? 1 : min(maxLines, editor.lines.count)
        let composerHeight = visibleLines + 3
        let composerRow = home
            ? max(1, min(height - composerHeight - 4, height / 2 - 1))
            : max(1, height - 2 - composerHeight)

        if home {
            if height >= 16, composerRow >= 6 {
                let logoRow = max(2, composerRow - 4)
                center([Span("泠溪", .color(Theme.fox, bold: true))], row: logoRow, into: &canvas)
                center([Span("泠溪 · 2.0", .color(Theme.dim))], row: logoRow + 2, into: &canvas)
            }
            var below = composerRow + composerHeight + 1
            if below < height - 2, view.completion == nil {
                let tips: [Span] = [
                    Span("/auth", .color(Theme.fox)), Span(" 连接模型    ", .color(Theme.dim)),
                    Span("/models", .color(Theme.fox)), Span(" 切换模型    ", .color(Theme.dim)),
                    Span("Ctrl-P", .color(Theme.fox)), Span(" 全部命令", .color(Theme.dim)),
                ]
                if spanWidth(tips) <= panelWidth { center(tips, row: below, into: &canvas); below += 2 }
            }
            if let feedback = view.feedback {
                let color = feedback.role == .error ? Theme.error : Theme.dim
                let lines = TextWidth.wrap(Renderer.clean(feedback.text), width: panelWidth)
                for (offset, line) in lines.prefix(max(0, height - 1 - below)).enumerated() {
                    canvas.draw([Span(line, .color(color))], row: below + offset, col: composerLeft, limit: panelWidth)
                }
            }
        } else {
            var feedbackLines: [String] = []
            if let feedback = view.feedback {
                feedbackLines = Array(TextWidth.wrap(Renderer.clean(feedback.text), width: contentWidth - 2).prefix(3))
            }
            let bodyTop = 2
            let bodyBottom = composerRow - 1 - (feedbackLines.isEmpty ? 0 : feedbackLines.count + 1)
            let available = max(0, bodyBottom - bodyTop)
            var body: [Line] = []
            for (index, message) in view.messages.enumerated() {
                if !body.isEmpty { body.append(.blank) }
                body += cache.lines(index: index, message: message, width: contentWidth, showThinking: view.showThinking) {
                    messageLines(message, width: contentWidth, showThinking: view.showThinking)
                }
            }
            cache.trim(to: view.messages.count)
            info = FrameInfo(bodyLines: body.count, bodyHeight: available)
            let scroll = min(max(0, view.scroll), max(0, body.count - available))
            let end = body.count - scroll
            let start = max(0, end - available)
            for (offset, line) in body[start..<end].enumerated() {
                let row = bodyTop + offset
                if let fill = line.fill { canvas.fill(row: row, col: left, count: contentWidth, bg: fill) }
                canvas.draw(line.spans, row: row, col: left, limit: contentWidth)
            }
            if body.count > available, available > 2, left + contentWidth + 1 < width {
                drawScrollbar(total: body.count, visible: available, scroll: scroll, top: bodyTop,
                              col: left + contentWidth + 1, into: &canvas)
            }
            for (offset, line) in feedbackLines.enumerated() {
                let error = view.feedback?.role == .error
                canvas.draw([Span(error ? "✕ " : "› ", .color(error ? Theme.error : Theme.fox)),
                             Span(line, .color(error ? Theme.error : Theme.dim))],
                            row: bodyBottom + 1 + offset, col: left, limit: contentWidth)
            }
        }

        // Composer: a raised panel with a focus rail. The footer carries model and editor state.
        if view.auth == nil {
            let rail = Span("▌", .color(view.running ? Theme.muted : Theme.fox))
            for offset in 0..<composerHeight {
                canvas.fill(row: composerRow + offset, col: composerLeft, count: panelWidth, bg: Theme.charcoalRaised)
                canvas.draw([rail], row: composerRow + offset, col: composerLeft, limit: 1)
            }
            if view.input.isEmpty {
                let placeholder = view.running ? "生成中…可以继续写下一条草稿" : "输入消息，或按 / 选择命令"
                canvas.draw([Span(placeholder, .color(Theme.muted))], row: composerRow + 1, col: composerLeft + 3, limit: panelWidth - 4)
                cursor = (composerRow + 1, composerLeft + 3)
            } else {
                for (offset, line) in editor.lines.dropFirst(firstLine).prefix(maxLines).enumerated() {
                    canvas.draw([Span(line)], row: composerRow + 1 + offset, col: composerLeft + 3, limit: panelWidth - 4)
                }
                cursor = (composerRow + 1 + editor.cursorRow - firstLine, composerLeft + 3 + editor.cursorCol)
            }
            // The footer is the model area: which model answers, which wire protocol it uses, and the
            // thinking mode the Core reports as effective. A temporary selection is marked so it is
            // never mistaken for the plugin's own configuration.
            var footer: [Span] = [Span(view.model ?? "无模型", .color(view.model == nil ? Theme.error : Theme.fox))]
            if let protocolKind = view.modelProtocol {
                footer.append(Span("  ·  协议 \(protocolKind)", .color(Theme.dim)))
            }
            if let thinking = view.modelThinking {
                footer.append(Span("  ·  思考 \(thinking)", .color(Theme.dim)))
                if view.modelThinkingTemporary { footer.append(Span("·临时", .color(Theme.fox))) }
            }
            if editor.lines.count > 1 { footer.append(Span("  ·  \(editor.lines.count) 行", .color(Theme.dim))) }
            let footerRow = composerRow + composerHeight - 1
            canvas.draw(footer, row: footerRow, col: composerLeft + 3, limit: panelWidth - 4)
            let hint = [Span("Shift-Enter 换行", .color(Theme.muted))]
            if spanWidth(footer) + spanWidth(hint) + 6 < panelWidth {
                canvas.draw(hint, row: footerRow, col: composerLeft + panelWidth - spanWidth(hint) - 2, limit: spanWidth(hint))
            }
            if let completion = view.completion {
                info.hits += drawCompletion(completion, left: composerLeft, width: panelWidth,
                                            anchorTop: composerRow, anchorBottom: composerRow + composerHeight,
                                            below: home, into: &canvas)
            }
        }

        if let auth = view.auth {
            cursor = nil
            drawAuth(auth, feedback: view.feedback, into: &canvas)
        } else if let settings = view.settings {
            cursor = nil
            info.hits += drawSettings(settings, busy: view.settingsBusy, error: view.settingsError, into: &canvas)
            if let confirmation = view.confirmation {
                info.hits += drawConfirmation(confirmation, into: &canvas)
            }
            if let exitDialog = view.exitDialog {
                info.hits += drawExitDialog(exitDialog, into: &canvas)
            }
        } else if let picker = view.picker {
            cursor = nil
            info.hits += drawPicker(picker, into: &canvas)
        }

        var text = "\u{1B}[?2026h" + canvas.emit()
        if let cursor, (0..<height).contains(cursor.row), cursor.col < width {
            // The real cursor sits in the editor so IME composition appears where the user types.
            text += "\u{1B}[\(cursor.row + 1);\(cursor.col + 1)H" + "\u{1B}[?25h"
        } else {
            text += "\u{1B}[?25l"
        }
        return (text + "\u{1B}[?2026l", info)
    }

    // MARK: chrome

    private func drawConfirmation(_ confirmation: Confirmation, into canvas: inout Canvas) -> [HitRegion] {
        let boxWidth = min(width - 4, max(40, min(72, width - 8)))
        let boxHeight = 8
        let left = max(0, (width - boxWidth) / 2)
        let top = max(1, (height - boxHeight) / 2)
        for row in top..<(top + boxHeight) {
            canvas.fill(row: row, col: left, count: boxWidth, bg: Theme.overlay)
        }
        canvas.draw([Span("┌" + String(repeating: "─", count: boxWidth - 2) + "┐", .color(Theme.error))], row: top, col: left, limit: boxWidth)
        canvas.draw([Span("└" + String(repeating: "─", count: boxWidth - 2) + "┘", .color(Theme.error))], row: top + boxHeight - 1, col: left, limit: boxWidth)
        for row in (top + 1)..<(top + boxHeight - 1) {
            canvas.draw([Span("│", .color(Theme.error))], row: row, col: left, limit: 1)
            canvas.draw([Span("│", .color(Theme.error))], row: row, col: left + boxWidth - 1, limit: 1)
        }
        canvas.draw([Span(" " + confirmation.title + " ", .color(Theme.error, bold: true))], row: top, col: left + 2, limit: boxWidth - 4)
        canvas.draw([Span(confirmation.message, .color(Theme.cream))], row: top + 2, col: left + 2, limit: boxWidth - 4)
        let buttons = drawButtons(["确认", "取消"], selected: confirmation.selected,
                                  row: top + 4, left: left + 2, limit: boxWidth - 4, into: &canvas)
        canvas.draw([Span("←→ 选择 · Enter 确认 · Esc 取消", .color(Theme.muted))],
                    row: top + 6, col: left + 2, limit: boxWidth - 4)
        return buttons
    }

    /// The host-owned prompt shown when Escape would throw away a dirty settings draft. It exists
    /// only because the plugin cannot be trusted to ask: the host owns the window.
    private func drawExitDialog(_ dialog: ExitDialog, into canvas: inout Canvas) -> [HitRegion] {
        let boxWidth = min(width - 4, max(40, min(64, width - 8)))
        let boxHeight = 9
        let left = max(0, (width - boxWidth) / 2)
        let top = max(1, (height - boxHeight) / 2)
        for row in top..<(top + boxHeight) {
            canvas.fill(row: row, col: left, count: boxWidth, bg: Theme.overlay)
        }
        let border = Style.color(Theme.fox)
        canvas.draw([Span("┌" + String(repeating: "─", count: boxWidth - 2) + "┐", border)], row: top, col: left, limit: boxWidth)
        canvas.draw([Span("└" + String(repeating: "─", count: boxWidth - 2) + "┘", border)], row: top + boxHeight - 1, col: left, limit: boxWidth)
        for row in (top + 1)..<(top + boxHeight - 1) {
            canvas.draw([Span("│", border)], row: row, col: left, limit: 1)
            canvas.draw([Span("│", border)], row: row, col: left + boxWidth - 1, limit: 1)
        }
        canvas.draw([Span(" 未保存的修改 ", .color(Theme.fox, bold: true))], row: top, col: left + 2, limit: boxWidth - 4)
        canvas.draw([Span("插件设置还有未保存的改动。", .color(Theme.cream))], row: top + 2, col: left + 2, limit: boxWidth - 4)
        canvas.draw([Span("要保存后再关闭吗？", .color(Theme.dim))], row: top + 3, col: left + 2, limit: boxWidth - 4)
        let buttons = drawButtons(ExitDialog.buttons, selected: dialog.selected,
                                  row: top + 5, left: left + 2, limit: boxWidth - 4, into: &canvas)
        canvas.draw([Span("←→ 选择 · Enter 确认 · Esc 继续编辑", .color(Theme.muted))],
                    row: top + 7, col: left + 2, limit: boxWidth - 4)
        return buttons
    }

    /// Draws a row of `[ label ]` buttons and returns their clickable cells. The selected button is
    /// inverted so the keyboard focus is obvious without extra chrome.
    private func drawButtons(
        _ titles: [String], selected: Int, row: Int, left: Int, limit: Int, into canvas: inout Canvas
    ) -> [HitRegion] {
        var regions: [HitRegion] = []
        var column = left
        for (index, title) in titles.enumerated() {
            let text = "[ " + title + " ]"
            let cells = TextWidth.width(text)
            guard column + cells <= left + limit else { break }
            let active = index == selected
            let style = active
                ? Style(fg: Theme.charcoal, bg: Theme.fox, bold: true)
                : Style(fg: Theme.dim)
            canvas.draw([Span(text, style)], row: row, col: column, limit: cells)
            regions.append(HitRegion(
                kind: .dialogButton(index: index), row: row + 1, column: column + 1, columns: cells
            ))
            column += cells + 2
        }
        return regions
    }

    /// The host owns the frame: title, identity, footer. Everything between the borders is the
    /// plugin's validated cell frame, so a plugin can design freely without touching the terminal.
    /// Returns the plugin-owned area so mouse coordinates can be converted to its own origin.
    private func drawSettings(
        _ settings: SettingsSnapshot, busy: Bool, error: String?, into canvas: inout Canvas
    ) -> [HitRegion] {
        let boxWidth = min(width - 2, max(24, settings.viewport.width + 4))
        let boxHeight = min(height - 2, max(8, settings.viewport.height + 6))
        let left = max(0, (width - boxWidth) / 2)
        let top = max(1, (height - boxHeight) / 2)
        canvas.fill(row: top, col: left, count: boxWidth, bg: Theme.charcoalRaised)
        for row in top..<(top + boxHeight) {
            canvas.fill(row: row, col: left, count: boxWidth, bg: Theme.charcoalRaised)
        }
        let border = Style.color(Theme.muted)
        canvas.draw([Span("┌" + String(repeating: "─", count: max(0, boxWidth - 2)) + "┐", border)], row: top, col: left, limit: boxWidth)
        canvas.draw([Span("└" + String(repeating: "─", count: max(0, boxWidth - 2)) + "┘", border)], row: top + boxHeight - 1, col: left, limit: boxWidth)
        for row in (top + 1)..<(top + boxHeight - 1) {
            canvas.draw([Span("│", border)], row: row, col: left, limit: 1)
            canvas.draw([Span("│", border)], row: row, col: left + boxWidth - 1, limit: 1)
        }
        let titleWidth = max(0, boxWidth - 4)
        canvas.draw([Span(" " + settings.title + " ", .color(Theme.fox, bold: true))], row: top, col: left + 2, limit: titleWidth)
        let identity = " \(settings.bundleID) · v\(settings.version) "
        let identityWidth = TextWidth.width(identity)
        if identityWidth < boxWidth - 6 {
            canvas.draw([Span(identity, .color(Theme.dim))], row: top, col: left + boxWidth - identityWidth - 2, limit: identityWidth)
        }
        for (offset, row) in settings.frame.rows.enumerated() {
            guard top + 2 + offset < top + boxHeight - 2 else { break }
            var spans: [Span] = []
            for span in row.spans {
                spans.append(Span(span.text, style(for: span)))
            }
            canvas.draw(spans, row: top + 2 + offset, col: left + 2, limit: max(0, boxWidth - 4))
        }
        let footerRow = top + boxHeight - 2
        let hint = busy ? "处理中…" : "Ctrl-S 保存 · Esc 关闭"
        canvas.draw([Span(hint, .color(Theme.muted))], row: footerRow, col: left + 2, limit: max(0, boxWidth - 4))
        if let error, !busy {
            let message = Renderer.oneLine(error)
            canvas.draw([Span(message, .color(Theme.error))], row: footerRow, col: left + 2,
                        limit: max(0, boxWidth - 4))
        } else if let status = settings.status, !busy {
            let statusWidth = min(TextWidth.width(status), max(0, boxWidth - 4 - TextWidth.width(hint) - 2))
            if statusWidth > 0 {
                let clipped = SettingsFrameValidator.displayWidth(status) > statusWidth
                    ? String(status.prefix(max(0, statusWidth - 1))) + "…" : status
                canvas.draw([Span(clipped, .color(Theme.dim))], row: footerRow,
                            col: left + boxWidth - TextWidth.width(clipped) - 2, limit: statusWidth)
            }
        }
        // Only the cells the plugin actually draws are its input surface: title, border and footer
        // hints stay host chrome, so a click there can never reach the plugin.
        let frameRows = min(settings.viewport.height, max(0, boxHeight - 4))
        let frameColumns = min(settings.viewport.width, max(0, boxWidth - 4))
        guard frameRows > 0, frameColumns > 0 else { return [] }
        return [HitRegion(
            kind: .settingsFrame, row: top + 3, rows: frameRows,
            column: left + 3, columns: frameColumns
        )]
    }

    private func style(for span: SettingsSpan) -> Style {
        var style = Style()
        style.fg = color(span.fg) ?? Theme.cream
        style.bg = color(span.bg)
        style.bold = span.bold ?? false
        style.italic = span.italic ?? false
        style.underline = span.underline ?? false
        return style
    }

    private func color(_ value: String?) -> RGB? {
        guard let value else { return nil }
        if value.hasPrefix("#"), value.count == 7 {
            let hex = value.dropFirst()
            let number = Int(hex, radix: 16) ?? 0
            return RGB((number >> 16) & 0xFF, (number >> 8) & 0xFF, number & 0xFF)
        }
        switch value {
        case "charcoal": return Theme.charcoal
        case "charcoalRaised": return Theme.charcoalRaised
        case "overlay": return Theme.overlay
        case "selection": return Theme.selection
        case "cream": return Theme.cream
        case "fox": return Theme.fox
        case "dim": return Theme.dim
        case "muted": return Theme.muted
        case "error": return Theme.error
        case "success": return Theme.success
        case "link": return Theme.link
        case "string": return Theme.string
        case "number": return Theme.number
        case "type": return Theme.type
        default: return nil
        }
    }

    private func drawTopBar(_ view: ViewState, home: Bool, into canvas: inout Canvas) {
        canvas.fill(row: 0, col: 0, count: width, bg: Theme.charcoalRaised)
        var spans: [Span] = [Span(" ◆ ", .color(Theme.fox)), Span("LingXi", .color(Theme.fox, bold: true))]
        if !home {
            spans += [Span("  │  ", .color(Theme.muted)), Span(Renderer.oneLine(view.sessionTitle))]
        }
        let location = Renderer.oneLine(URL(fileURLWithPath: view.workspace).lastPathComponent)
        let right = [Span(location + " ", .color(Theme.dim))]
        let rightWidth = spanWidth(right)
        let used = canvas.draw(spans, row: 0, col: 0, limit: max(0, width - rightWidth - 2))
        if used + rightWidth + 2 <= width {
            canvas.draw(right, row: 0, col: width - rightWidth, limit: rightWidth)
        }
    }

    private func drawStatus(_ status: StatusLine, into canvas: inout Canvas) {
        let row = height - 1
        let used = canvas.draw([Span(" ")] + status.left, row: row, col: 0, limit: width)
        let right = Renderer.oneLine(status.right)
        let rightWidth = TextWidth.width(right)
        if used + rightWidth + 4 <= width {
            canvas.draw([Span(right, .color(Theme.muted))], row: row, col: width - rightWidth - 1, limit: rightWidth)
        }
    }

    private func drawScrollbar(total: Int, visible: Int, scroll: Int, top: Int, col: Int, into canvas: inout Canvas) {
        let thumb = max(1, visible * visible / max(1, total))
        let range = max(1, total - visible)
        let position = (visible - thumb) * (range - scroll) / range
        for offset in 0..<visible {
            let active = (position..<(position + thumb)).contains(offset)
            canvas.draw([Span(active ? "┃" : "│", .color(active ? Theme.dim : Theme.charcoalRaised))],
                        row: top + offset, col: col, limit: 1)
        }
    }

    private func drawCompletion(_ picker: Picker, left: Int, width panelWidth: Int, anchorTop: Int, anchorBottom: Int,
                                below: Bool, into canvas: inout Canvas) -> [HitRegion] {
        let items = picker.items
        let count = min(items.count, 8, below ? max(1, height - anchorBottom - 2) : max(1, anchorTop - 2))
        guard count > 0 else { return [] }
        let selected = min(max(0, picker.selected), items.count - 1)
        let start = max(0, min(selected - count / 2, items.count - count))
        let top = below ? anchorBottom : anchorTop - count
        let commandWidth = min(14, (items.map { TextWidth.width($0.command) }.max() ?? 0) + 2)
        var hits: [HitRegion] = []
        for (offset, item) in items.dropFirst(start).prefix(count).enumerated() {
            let row = top + offset
            let active = start + offset == selected
            canvas.fill(row: row, col: left, count: panelWidth, bg: active ? Theme.selection : Theme.overlay)
            canvas.draw([Span(active ? "▌" : " ", .color(Theme.fox))], row: row, col: left, limit: 1)
            canvas.draw([Span(item.command, .color(active ? Theme.fox : Theme.cream, bold: active))],
                        row: row, col: left + 2, limit: commandWidth)
            canvas.draw([Span(item.title, .color(active ? Theme.cream : Theme.dim))],
                        row: row, col: left + 2 + commandWidth, limit: panelWidth - commandWidth - 3)
            hits.append(HitRegion(
                kind: .completionRow(index: start + offset), row: row + 1,
                column: left + 1, columns: max(0, panelWidth)
            ))
        }
        return hits
    }

    /// A centered modal panel: title row, body rows, footer. Returns its geometry so callers can map
    /// body rows back to the items they drew.
    @discardableResult
    private func drawPanel(title: [Span], titleRight: String, body: [[Span]], highlight: Int?, footer: [Span],
                           footerRight: String, width panelWidth: Int, into canvas: inout Canvas) -> PanelGeometry {
        let inner = panelWidth - 4
        let rowsNeeded = body.count + 6
        let total = min(rowsNeeded, max(3, height - 2))
        let top = max(1, (height - total) / 2)
        let left = max(0, (width - panelWidth) / 2)
        for offset in 0..<total { canvas.fill(row: top + offset, col: left, count: panelWidth, bg: Theme.overlay) }
        canvas.draw(title, row: top + 1, col: left + 2, limit: inner)
        let rightWidth = TextWidth.width(titleRight)
        if spanWidth(title) + rightWidth + 2 <= inner {
            canvas.draw([Span(titleRight, .color(Theme.muted))], row: top + 1, col: left + 2 + inner - rightWidth, limit: rightWidth)
        }
        let bodyRows = max(0, total - 6)
        for (offset, spans) in body.prefix(bodyRows).enumerated() {
            let row = top + 3 + offset
            if offset == highlight {
                canvas.fill(row: row, col: left + 1, count: panelWidth - 2, bg: Theme.selection)
                canvas.draw([Span("▌", .color(Theme.fox))], row: row, col: left + 1, limit: 1)
            }
            canvas.draw(spans, row: row, col: left + 2, limit: inner)
        }
        if total >= 5 {
            let row = top + total - 2
            canvas.draw(footer, row: row, col: left + 2, limit: inner)
            let width = TextWidth.width(footerRight)
            if spanWidth(footer) + width + 2 <= inner {
                canvas.draw([Span(footerRight, .color(Theme.muted))], row: row, col: left + 2 + inner - width, limit: width)
            }
        }
        return PanelGeometry(top: top, left: left, inner: inner, bodyRows: bodyRows)
    }

    private func drawPicker(_ picker: Picker, into canvas: inout Canvas) -> [HitRegion] {
        let panelWidth = max(10, min(72, width - 4))
        let inner = panelWidth - 4
        let visible = max(1, min(10, height - 12))
        let items = picker.filtered
        let selected = min(max(0, picker.selected), max(0, items.count - 1))
        let start = max(0, min(selected - visible / 2, items.count - visible))
        var body: [[Span]] = [[Span("› ", .color(Theme.fox)), Span(Renderer.oneLine(picker.query) + "▏")], [Span(String(repeating: "─", count: inner), .color(Theme.muted))]]
        var highlight: Int?
        if items.isEmpty { body.append([Span("没有匹配项", .color(Theme.dim))]) }
        for (offset, item) in items.dropFirst(start).prefix(visible).enumerated() {
            let active = start + offset == selected
            let detail = Renderer.oneLine(item.detail)
            let detailWidth = min(TextWidth.width(detail), inner / 2)
            let titleSpan = Span(Renderer.oneLine(item.title), .color(active ? Theme.fox : Theme.cream, bold: active))
            var row: [Span] = []
            if let checked = item.checked {
                row.append(Span(checked ? "[✓] " : "[ ] ", .color(checked ? Theme.success : Theme.muted)))
            }
            let titleWidth = inner - detailWidth - 2 - spanWidth(row)
            row.append(Span(Renderer.truncate(titleSpan.text, to: titleWidth), titleSpan.style))
            let gap = max(1, inner - spanWidth(row) - detailWidth)
            row.append(Span(String(repeating: " ", count: gap) + Renderer.truncate(detail, to: detailWidth),
                            .color(active ? Theme.dim : Theme.muted)))
            if active { highlight = body.count }
            body.append(row)
        }
        let position = items.isEmpty ? "0/0" : "\(selected + 1)/\(items.count)"
        let geometry = drawPanel(title: [Span(Renderer.oneLine(picker.title), .color(Theme.fox, bold: true))], titleRight: "esc 关闭",
                                 body: body, highlight: highlight,
                                 footer: [Span(picker.isToggleList ? "Space 切换   Enter 保存   Esc 取消" : "↑↓ 选择   Enter 确认   Esc 返回",
                                               .color(Theme.dim))], footerRight: position,
                                 width: panelWidth, into: &canvas)
        // Body row 0 is the query line and row 1 is its rule; item rows follow. Two regions per
        // toggle row keep the checkbox and the rest of the row distinguishable for a click.
        var hits: [HitRegion] = []
        for (offset, item) in items.dropFirst(start).prefix(visible).enumerated() {
            let bodyIndex = 2 + offset
            guard bodyIndex < geometry.bodyRows else { break }
            let row = geometry.top + 3 + bodyIndex + 1
            let column = geometry.left + 3
            if item.checked != nil {
                // The row first, the checkbox second: hit-testing prefers the later (topmost) region.
                hits.append(HitRegion(kind: .pickerRow(index: start + offset, checkbox: false),
                                      row: row, column: column + 4, columns: max(0, inner - 4)))
                hits.append(HitRegion(kind: .pickerRow(index: start + offset, checkbox: true),
                                      row: row, column: column, columns: 4))
            } else {
                hits.append(HitRegion(kind: .pickerRow(index: start + offset, checkbox: false),
                                      row: row, column: column, columns: inner))
            }
        }
        return hits
    }

    private func drawAuth(_ auth: AuthPrompt, feedback: Message?, into canvas: inout Canvas) {
        let panelWidth = max(10, min(64, width - 4))
        let mask = auth.characterCount == 0
            ? [Span("▏", .color(Theme.fox))]
            : [Span("••••••••", .color(Theme.cream)), Span("  已输入 \(auth.characterCount) 个字符", .color(Theme.dim))]
        var body: [[Span]] = [
            [Span("密钥加密保存在此 Mac 的 Keychain。", .color(Theme.dim))],
            [Span("不会进入对话或命令历史。", .color(Theme.dim))],
            [],
            [Span("▌ ", .color(Theme.fox))] + mask,
        ]
        if let feedback, feedback.role == .error {
            body += [[], [Span(Renderer.oneLine(feedback.text), .color(Theme.error))]]
        }
        drawPanel(title: [Span("连接模型", .color(Theme.fox, bold: true)), Span("  /  " + Renderer.oneLine(auth.label), .color(Theme.cream))],
                  titleRight: "隐藏输入中", body: body, highlight: nil,
                  footer: [Span("Enter 保存", .color(Theme.fox)), Span("    Esc 取消", .color(Theme.dim))], footerRight: "",
                  width: panelWidth, into: &canvas)
    }

    private func center(_ spans: [Span], row: Int, into canvas: inout Canvas) {
        let cells = spanWidth(spans)
        canvas.draw(spans, row: row, col: max(0, (width - cells) / 2), limit: width)
    }

    // MARK: messages

    func messageLines(_ message: Message, width: Int, showThinking: Bool) -> [Line] {
        let text = Renderer.clean(message.text)
        switch message.role {
        case .user:
            return text.split(separator: "\n", omittingEmptySubsequences: false).flatMap {
                Markdown.wrap([Span(String($0))], width: max(1, width - 3), breakAnywhere: false)
            }.map { Line(spans: [Span("▌ ", .color(Theme.fox))] + $0, fill: Theme.charcoalRaised) }
        case .assistant:
            var lines = [Line(spans: [Span("◆ ", .color(Theme.fox)), Span("泠溪", .color(Theme.fox, bold: true))])]
            lines += Markdown(width: width).render(text)
            if message.streaming {
                if lines.count == 1 { lines.append(Line(spans: [])) }
                lines[lines.count - 1].spans.append(Span("▍", .color(Theme.fox)))
            }
            if let meta = message.meta {
                lines.append(Line(spans: [Span(meta, .color(Theme.muted))]))
            }
            if let diagnostics = message.diagnostics {
                lines.append(Line(spans: [Span(diagnostics, .color(Theme.muted))]))
            }
            return lines
        case .reasoning:
            let count = text.filter { !$0.isWhitespace }.count
            let label = message.streaming ? "思考中…" : "思考"
            let style = Style(fg: Theme.dim, italic: true)
            var lines = [Line(spans: [Span((showThinking ? "▾ " : "▸ ") + label, .color(Theme.dim)),
                                      Span("  ·  \(count) 字  ·  Ctrl-T " + (showThinking ? "收起" : "展开"), .color(Theme.muted))])]
            if showThinking {
                lines += text.split(separator: "\n", omittingEmptySubsequences: false).flatMap {
                    Markdown.wrap([Span(String($0), style)], width: max(1, width - 2), breakAnywhere: false)
                }.map { Line(spans: [Span("│ ", .color(Theme.muted))] + $0) }
            }
            return lines
        case .tool:
            return Markdown.wrap([Span(text, .color(Theme.dim))], width: max(1, width - 2), breakAnywhere: true)
                .enumerated().map { Line(spans: [Span($0.offset == 0 ? "◇ " : "  ", .color(Theme.fox))] + $0.element) }
        case .toolResult:
            let all = text.split(separator: "\n", omittingEmptySubsequences: false).flatMap {
                Markdown.wrap([Span(String($0), .color(Theme.muted))], width: max(1, width - 4), breakAnywhere: true)
            }
            var lines = all.prefix(4).enumerated().map {
                Line(spans: [Span($0.offset == 0 ? "  ↳ " : "    ", .color(Theme.muted))] + $0.element)
            }
            if all.count > 4 { lines.append(Line(spans: [Span("    … 另有 \(all.count - 4) 行", .color(Theme.muted))])) }
            return lines
        case .system, .error:
            let color = message.role == .error ? Theme.error : Theme.dim
            return Markdown.wrap([Span(text, .color(color))], width: width, breakAnywhere: false).map { Line(spans: $0) }
        }
    }

    // MARK: editor

    /// Wraps the draft by cell width and reports where the cursor lands, in cells.
    private func layoutInput(_ input: [Character], cursor: Int, limit: Int) -> (lines: [String], cursorRow: Int, cursorCol: Int) {
        let index = min(max(0, cursor), input.count)
        var lines = [""]
        var cells = 0
        var cursorRow = 0
        var cursorCol = 0
        for position in 0...input.count {
            if position == index {
                if cells >= limit { lines.append(""); cells = 0 }
                cursorRow = lines.count - 1
                cursorCol = cells
            }
            guard position < input.count else { break }
            let character = input[position]
            if character == "\n" { lines.append(""); cells = 0; continue }
            let printable = character == "\t" ? "  " : Renderer.clean(String(character))
            let cell = TextWidth.width(printable)
            if cells + cell > limit, cells > 0 { lines.append(""); cells = 0 }
            lines[lines.count - 1] += printable
            cells += cell
        }
        return (lines, cursorRow, cursorCol)
    }

    // MARK: helpers

    static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.properties.generalCategory != .control || $0 == "\n" || $0 == "\t" })
            .replacingOccurrences(of: "\t", with: "    ")
    }

    /// Single-row regions never receive a newline: it would break absolute row addressing.
    static func oneLine(_ text: String) -> String {
        clean(text).replacingOccurrences(of: "\n", with: " ")
    }

    static func truncate(_ text: String, to cells: Int) -> String {
        guard TextWidth.width(text) > cells else { return text }
        guard cells > 1 else { return cells == 1 ? "…" : "" }
        var output = ""
        var used = 0
        for character in text {
            let width = TextWidth.width(String(character))
            if used + width > cells - 1 { break }
            output.append(character)
            used += width
        }
        return output + "…"
    }
}

func spanWidth(_ spans: [Span]) -> Int {
    spans.reduce(0) { $0 + TextWidth.width($1.text) }
}

// MARK: - markdown

/// Block Markdown for terminal output: headings, lists, task lists, quotes, rules, fenced code with
/// light highlighting, and tables. Inline: code, bold, italic, strike, links. Partial input (a
/// streaming reply with an unclosed fence) renders as far as it goes.
struct Markdown {
    let width: Int

    func render(_ text: String) -> [Line] {
        var output: [Line] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index]); index += 1
                }
                index += 1
                output += codeBlock(code, language: language)
                continue
            }
            if trimmed.hasPrefix("|"), trimmed.count > 1 {
                var rows: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(lines[index].trimmingCharacters(in: .whitespaces)); index += 1
                }
                output += table(rows)
                continue
            }
            output += block(line)
            index += 1
        }
        return output
    }

    private func block(_ line: String) -> [Line] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return [.blank] }
        if trimmed.hasPrefix("#") {
            let level = trimmed.prefix { $0 == "#" }.count
            let heading = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
            if level <= 6, trimmed.dropFirst(level).first == " " {
                let style = Style(fg: level <= 2 ? Theme.fox : Theme.cream, bold: true)
                return Markdown.wrap(Markdown.inline(heading, base: style), width: width, breakAnywhere: false)
                    .map { Line(spans: $0) }
            }
        }
        if trimmed.count >= 3, Set(trimmed.filter { $0 != " " }).count == 1, let mark = trimmed.first, "-*_".contains(mark) {
            return [Line(spans: [Span(String(repeating: "─", count: width), .color(Theme.muted))])]
        }
        if trimmed.hasPrefix(">") {
            let quote = trimmed.drop { $0 == ">" || $0 == " " }
            let style = Style(fg: Theme.dim, italic: true)
            return Markdown.wrap(Markdown.inline(String(quote), base: style), width: max(1, width - 2), breakAnywhere: false)
                .map { Line(spans: [Span("▎ ", .color(Theme.muted))] + $0) }
        }
        if let item = listItem(line) {
            let indent = String(repeating: " ", count: item.level * 2)
            let markerWidth = TextWidth.width(item.marker)
            let available = max(1, width - indent.count - markerWidth)
            let wrapped = Markdown.wrap(Markdown.inline(item.text, base: .plain), width: available, breakAnywhere: false)
            return wrapped.enumerated().map { offset, spans in
                let lead = offset == 0
                    ? [Span(indent), Span(item.marker, .color(item.ordered ? Theme.dim : Theme.fox))]
                    : [Span(indent + String(repeating: " ", count: markerWidth))]
                return Line(spans: lead + spans)
            }
        }
        return Markdown.wrap(Markdown.inline(trimmed, base: .plain), width: width, breakAnywhere: false).map { Line(spans: $0) }
    }

    private func listItem(_ line: String) -> (level: Int, marker: String, text: String, ordered: Bool)? {
        let spaces = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(spaces)
        let level = min(3, spaces / 2)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            var text = String(rest.dropFirst(2))
            if text.hasPrefix("[ ] ") { text.removeFirst(4); return (level, "☐ ", text, false) }
            if text.lowercased().hasPrefix("[x] ") { text.removeFirst(4); return (level, "☑ ", text, false) }
            return (level, ["• ", "◦ ", "▪ ", "▫ "][level], text, false)
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " {
                return (level, digits + ". ", String(after.dropFirst(2)), true)
            }
        }
        return nil
    }

    private func codeBlock(_ code: [String], language: String) -> [Line] {
        let inner = max(1, width - 4)
        var lines = [Line(spans: [Span("  " + (language.isEmpty ? "code" : language), Style(fg: Theme.muted, italic: true))],
                          fill: Theme.charcoalRaised)]
        for raw in code {
            let spans = Markdown.highlight(raw, language: language.lowercased())
            for piece in Markdown.wrap(spans, width: inner, breakAnywhere: true, keepLeadingSpace: true) {
                lines.append(Line(spans: [Span("  ")] + piece, fill: Theme.charcoalRaised))
            }
        }
        lines.append(Line(spans: [], fill: Theme.charcoalRaised))
        return lines
    }

    private func table(_ rows: [String]) -> [Line] {
        func cells(_ row: String) -> [String] {
            var parts = row.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.first == "" { parts.removeFirst() }
            if parts.last == "" { parts.removeLast() }
            return parts
        }
        var parsed = rows.map(cells)
        let isSeparator: ([String]) -> Bool = { row in
            !row.isEmpty && row.allSatisfy { !$0.isEmpty && $0.allSatisfy { ":- ".contains($0) } }
        }
        var header: [String]?
        var alignRight: [Bool] = []
        if parsed.count >= 2, isSeparator(parsed[1]) {
            header = parsed[0]
            alignRight = parsed[1].map { $0.hasSuffix(":") && !$0.hasPrefix(":") }
            parsed.removeFirst(2)
        } else if let separator = parsed.firstIndex(where: isSeparator) {
            parsed.remove(at: separator)
        }
        let columns = max(header?.count ?? 0, parsed.map(\.count).max() ?? 0)
        guard columns > 0 else { return [] }
        let all = (header.map { [$0] } ?? []) + parsed
        let rendered = all.map { row in (0..<columns).map { Markdown.inline($0 < row.count ? row[$0] : "", base: .plain) } }
        var widths = (0..<columns).map { column in max(1, rendered.map { spanWidth($0[column]) }.max() ?? 1) }
        // Shrink the widest column until the table fits; cells are truncated, never wrapped.
        while widths.reduce(0, +) + columns * 3 + 1 > width, let widest = widths.indices.max(by: { widths[$0] < widths[$1] }), widths[widest] > 3 {
            widths[widest] -= 1
        }
        let border = Style.color(Theme.muted)
        func rule(_ left: String, _ middle: String, _ right: String) -> Line {
            Line(spans: [Span(left + widths.map { String(repeating: "─", count: $0 + 2) }.joined(separator: middle) + right, border)])
        }
        func row(_ cells: [[Span]], bold: Bool) -> Line {
            var spans = [Span("│", border)]
            for (column, cell) in cells.enumerated() {
                var content = Markdown.truncate(cell, to: widths[column])
                if bold { content = content.map { var span = $0; span.style.bold = true; span.style.fg = Theme.fox; return span } }
                let padding = String(repeating: " ", count: max(0, widths[column] - spanWidth(content)))
                let right = column < alignRight.count && alignRight[column]
                spans += [Span(" ")] + (right ? [Span(padding)] + content : content + [Span(padding)]) + [Span(" "), Span("│", border)]
            }
            return Line(spans: spans)
        }
        var lines = [rule("┌", "┬", "┐")]
        if header != nil {
            lines.append(row(rendered[0], bold: true))
            lines.append(rule("├", "┼", "┤"))
        }
        for cells in rendered.dropFirst(header == nil ? 0 : 1) { lines.append(row(cells, bold: false)) }
        lines.append(rule("└", "┴", "┘"))
        return lines
    }

    // MARK: inline

    static func inline(_ text: String, base: Style) -> [Span] {
        let characters = Array(text)
        var spans: [Span] = []
        var buffer = ""
        func flush() { if !buffer.isEmpty { spans.append(Span(buffer, base)); buffer = "" } }
        func find(_ token: String, from start: Int) -> Int? {
            let pattern = Array(token)
            guard start <= characters.count - pattern.count else { return nil }
            for index in start...(characters.count - pattern.count) where Array(characters[index..<(index + pattern.count)]) == pattern {
                return index
            }
            return nil
        }
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "`", let close = find("`", from: index + 1), close > index + 1 {
                flush()
                var style = base
                style.fg = Theme.fox
                style.bg = Theme.charcoalRaised
                spans.append(Span(String(characters[(index + 1)..<close]), style))
                index = close + 1
                continue
            }
            if index + 1 < characters.count, characters[index + 1] == character, character == "*" || character == "~",
               let close = find(String(repeating: character, count: 2), from: index + 2), close > index + 2 {
                flush()
                var style = base
                if character == "*" { style.bold = true } else { style.strike = true }
                spans += inline(String(characters[(index + 2)..<close]), base: style)
                index = close + 2
                continue
            }
            if character == "*", index + 1 < characters.count, characters[index + 1] != " ", characters[index + 1] != "*",
               let close = find("*", from: index + 1), close > index + 1, characters[close - 1] != " " {
                flush()
                var style = base
                style.italic = true
                spans += inline(String(characters[(index + 1)..<close]), base: style)
                index = close + 1
                continue
            }
            if character == "[", let middle = find("](", from: index + 1), let close = find(")", from: middle + 2) {
                flush()
                let label = String(characters[(index + 1)..<middle])
                let url = String(characters[(middle + 2)..<close])
                var style = base
                style.fg = Theme.link
                style.underline = true
                spans.append(Span(label, style))
                if url != label, !url.isEmpty { spans.append(Span(" (" + url + ")", .color(Theme.muted))) }
                index = close + 1
                continue
            }
            buffer.append(character)
            index += 1
        }
        flush()
        return spans
    }

    static func truncate(_ spans: [Span], to cells: Int) -> [Span] {
        guard spanWidth(spans) > cells else { return spans }
        var output: [Span] = []
        var used = 0
        for span in spans {
            let room = cells - 1 - used
            guard room > 0 else { break }
            let piece = Renderer.truncate(span.text, to: room + 1)
            let clipped = piece.hasSuffix("…") && TextWidth.width(span.text) > room + 1 ? String(piece.dropLast()) : piece
            output.append(Span(clipped, span.style))
            used += TextWidth.width(clipped)
            if TextWidth.width(span.text) > room { break }
        }
        output.append(Span("…", spans.last?.style ?? .plain))
        return output
    }

    // MARK: wrapping

    /// Word-aware wrapping for styled spans. Latin words move to the next line whole unless they are
    /// longer than a line; CJK breaks between any two characters. Styles survive the break.
    static func wrap(_ spans: [Span], width: Int, breakAnywhere: Bool, keepLeadingSpace: Bool = false) -> [[Span]] {
        let width = max(1, width)
        struct Token { var text: String; var style: Style; var cells: Int; var space: Bool }
        var tokens: [Token] = []
        for span in spans {
            var current = ""
            var currentCells = 0
            func push() {
                if !current.isEmpty { tokens.append(Token(text: current, style: span.style, cells: currentCells, space: false)) }
                current = ""; currentCells = 0
            }
            for character in span.text {
                let cells = TextWidth.width(String(character))
                if character == " " {
                    push()
                    tokens.append(Token(text: " ", style: span.style, cells: 1, space: true))
                } else if breakAnywhere || cells == 2 {
                    push()
                    tokens.append(Token(text: String(character), style: span.style, cells: cells, space: false))
                } else {
                    current.append(character); currentCells += cells
                }
            }
            push()
        }
        var lines: [[Span]] = [[]]
        var used = 0
        func append(_ text: String, _ style: Style, _ cells: Int) {
            if let last = lines[lines.count - 1].last, last.style == style {
                lines[lines.count - 1][lines[lines.count - 1].count - 1].text += text
            } else {
                lines[lines.count - 1].append(Span(text, style))
            }
            used += cells
        }
        var leading = keepLeadingSpace
        for token in tokens {
            if token.space {
                if used == 0 && !leading && lines.count > 1 { continue }
                if used + 1 > width { lines.append([]); used = 0; continue }
                append(" ", token.style, 1)
                continue
            }
            leading = false
            if used + token.cells <= width {
                append(token.text, token.style, token.cells)
            } else if token.cells > width || breakAnywhere {
                for character in token.text {
                    let cells = TextWidth.width(String(character))
                    if used + cells > width, used > 0 { lines.append([]); used = 0 }
                    append(String(character), token.style, cells)
                }
            } else {
                // Drop trailing spaces before the break.
                if var last = lines[lines.count - 1].popLast() {
                    while last.text.hasSuffix(" ") { last.text.removeLast() }
                    if !last.text.isEmpty { lines[lines.count - 1].append(last) }
                }
                lines.append([]); used = 0
                append(token.text, token.style, token.cells)
            }
        }
        return lines
    }

    // MARK: highlighting

    private static let keywords: Set<String> = [
        "let", "var", "func", "fn", "def", "class", "struct", "enum", "protocol", "extension", "import", "return",
        "if", "else", "elif", "for", "while", "in", "guard", "switch", "case", "break", "continue", "true", "false",
        "nil", "null", "None", "True", "False", "self", "Self", "const", "static", "public", "private", "internal",
        "fileprivate", "async", "await", "throw", "throws", "try", "catch", "new", "this", "function", "interface",
        "type", "package", "go", "defer", "match", "impl", "pub", "use", "mod", "where", "yield", "lambda", "from",
        "as", "is", "not", "and", "or", "with", "export", "default", "do", "end", "then", "fi", "local", "echo",
        "mut", "override", "final", "init", "some", "any", "inout", "typealias", "actor", "nonisolated", "undefined",
    ]

    static func highlight(_ line: String, language: String) -> [Span] {
        let hashComment = ["python", "py", "sh", "bash", "zsh", "shell", "ruby", "rb", "yaml", "yml", "toml",
                           "perl", "r", "dockerfile", "make", "makefile", "conf", "ini", "console"].contains(language)
        let dashComment = ["sql", "lua", "haskell", "hs"].contains(language)
        let characters = Array(line)
        var spans: [Span] = []
        var index = 0
        func add(_ text: String, _ style: Style) {
            if let last = spans.last, last.style == style { spans[spans.count - 1].text += text } else { spans.append(Span(text, style)) }
        }
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if (hashComment && character == "#") || (!hashComment && character == "/" && next == "/")
                || (dashComment && character == "-" && next == "-") {
                add(String(characters[index...]), Style(fg: Theme.muted, italic: true))
                break
            }
            if character == "\"" || character == "'" || character == "`" {
                var end = index + 1
                while end < characters.count, characters[end] != character {
                    end += characters[end] == "\\" ? 2 : 1
                }
                end = min(end, characters.count - 1)
                add(String(characters[index...end]), .color(Theme.string))
                index = end + 1
                continue
            }
            if character.isNumber, index == 0 || !(characters[index - 1].isLetter || characters[index - 1] == "_") {
                var end = index
                while end < characters.count, characters[end].isHexDigit || characters[end] == "." || characters[end] == "x" || characters[end] == "_" { end += 1 }
                add(String(characters[index..<end]), .color(Theme.number))
                index = end
                continue
            }
            if character.isLetter || character == "_" || character == "@" {
                var end = index + 1
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" { end += 1 }
                let word = String(characters[index..<end])
                if keywords.contains(word) || character == "@" {
                    add(word, .color(Theme.fox))
                } else if character.isUppercase {
                    add(word, .color(Theme.type))
                } else {
                    add(word, .plain)
                }
                index = end
                continue
            }
            add(String(character), .plain)
            index += 1
        }
        return spans
    }
}
