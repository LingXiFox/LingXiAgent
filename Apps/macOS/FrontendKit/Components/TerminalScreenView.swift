#if canImport(SwiftUI)
import SwiftUI
import AppKit

// MARK: - Terminal screen
//
// Draws a `TerminalEmulator` and turns keystrokes into the bytes a terminal sends. The pane
// owns nothing about the process: input goes out through `onInput`, the visible size through
// `onResize`, and Core's PTY does the rest.

struct TerminalScreen: NSViewRepresentable {
    let emulator: TerminalEmulator
    /// Changes whenever the emulator does; it is what makes SwiftUI call `updateNSView`.
    let generation: Int
    let isEnabled: Bool
    let onInput: (String) -> Void
    let onResize: (Int, Int) -> Void

    func makeNSView(context: Context) -> TerminalScreenView {
        let view = TerminalScreenView(emulator: emulator)
        view.onInput = onInput
        view.onResize = onResize
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ view: TerminalScreenView, context: Context) {
        view.onInput = onInput
        view.onResize = onResize
        view.isEnabled = isEnabled
        if view.emulator !== emulator {
            view.emulator = emulator
            view.scrollOffset = 0
            view.selection = nil
            view.reportSize()
        }
        view.needsDisplay = true
    }
}

final class TerminalScreenView: NSView {
    var emulator: TerminalEmulator
    var onInput: ((String) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var isEnabled = true
    /// Lines scrolled back from the live screen; 0 follows the output.
    var scrollOffset = 0
    /// Selection in absolute line coordinates (scrollback + screen).
    var selection: (start: (line: Int, column: Int), end: (line: Int, column: Int))?

    private static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let cellWidth: CGFloat = ("M" as NSString).size(withAttributes: [.font: font]).width
    static let cellHeight: CGFloat = ceil(font.ascender - font.descender + font.leading) + 3
    static let inset: CGFloat = 8

    /// Columns × rows that fit a size. Also used before a shell exists, so it starts at the
    /// width it will be drawn at instead of 80 columns and a wrapped first prompt.
    static func gridSize(for size: CGSize) -> (columns: Int, rows: Int) {
        (max(20, Int((size.width - inset * 2) / cellWidth)), max(4, Int((size.height - inset * 2) / cellHeight)))
    }

    /// Powerline separators and Nerd Font icons live in the Private Use Area, which SF Mono
    /// has no glyphs for — prompts drew as boxes. When a Nerd Font is installed (the font the
    /// user's prompt theme was built for), those code points are drawn with it.
    private static let symbolFont: NSFont? = {
        let manager = NSFontManager.shared
        let family = manager.availableFontFamilies.first { name in
            name.contains("Nerd Font Mono") || name.contains(" NF") && name.contains("Mono")
        } ?? manager.availableFontFamilies.first { $0.contains("Nerd Font") || $0.hasSuffix(" NF") }
        guard let family,
              let member = manager.availableMembers(ofFontFamily: family)?.first,
              let postScript = member.first as? String else { return nil }
        return NSFont(name: postScript, size: 12.5)
    }()

    private static func isPrivateUse(_ character: String) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0xE000...0xF8FF).contains(value) || value >= 0xF0000
    }

    private let font = TerminalScreenView.font
    private lazy var boldFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    private var cellWidth: CGFloat { Self.cellWidth }
    private var cellHeight: CGFloat { Self.cellHeight }
    private var inset: CGFloat { Self.inset }
    var cellWidthForIME: CGFloat { cellWidth }
    var cellHeightForIME: CGFloat { cellHeight }
    private var lastReported: (Int, Int)?
    private var wheelRemainder: CGFloat = 0

    init(emulator: TerminalEmulator) {
        self.emulator = emulator
        super.init(frame: .zero)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("终端")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportSize()
    }

    func reportSize() {
        // A view is laid out at zero size before its real frame arrives. Treating that as a
        // 20×4 terminal made the first prompt wrap at 20 columns and leave zsh's `%` behind.
        guard bounds.width >= Self.inset * 2 + Self.cellWidth * 20,
              bounds.height >= Self.inset * 2 + Self.cellHeight * 4 else { return }
        let (columns, rows) = Self.gridSize(for: bounds.size)
        guard lastReported.map({ $0 != (columns, rows) }) ?? true else { return }
        lastReported = (columns, rows)
        emulator.resize(columns: columns, rows: rows)
        onResize?(columns, rows)
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let lines = emulator.allLines
        let screenStart = emulator.scrollback.count
        let offset = min(scrollOffset, emulator.scrollback.count)
        let firstLine = screenStart - offset
        let focused = window?.firstResponder === self && window?.isKeyWindow == true

        for row in 0..<emulator.rows {
            let lineIndex = firstLine + row
            guard lineIndex < lines.count else { break }
            let y = inset + CGFloat(row) * cellHeight
            drawLine(lines[lineIndex], at: y, lineIndex: lineIndex)
        }

        if offset == 0, emulator.cursorVisible, isEnabled {
            let rect = NSRect(x: inset + CGFloat(emulator.cursorX) * cellWidth,
                              y: inset + CGFloat(emulator.cursorY) * cellHeight,
                              width: cellWidth, height: cellHeight)
            let cursor = NSColor.white.withAlphaComponent(focused ? 0.78 : 0.45)
            if focused {
                cursor.setFill()
                rect.fill()
                let cell = emulator.grid[emulator.cursorY][emulator.cursorX]
                if !cell.character.trimmingCharacters(in: .whitespaces).isEmpty {
                    (cell.character as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY + 1),
                                                     withAttributes: [.font: font, .foregroundColor: NSColor.black])
                }
            } else {
                cursor.setStroke()
                let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    private func drawLine(_ line: [TerminalCell], at y: CGFloat, lineIndex: Int) {
        var column = 0
        while column < line.count {
            let cell = line[column]
            // Runs of identical attributes are drawn as one string: one text layout per run
            // rather than per cell, and ligature-free mono keeps every glyph on its column.
            var end = column + 1
            while end < line.count, line[end].attributes == cell.attributes { end += 1 }
            let run = line[column..<end]
            let x = inset + CGFloat(column) * cellWidth
            let width = CGFloat(end - column) * cellWidth
            var foreground = color(cell.attributes.foreground, isForeground: true)
            var background = cell.attributes.background == .default ? nil : color(cell.attributes.background, isForeground: false)
            if cell.attributes.inverse {
                let swapped = background ?? NSColor(white: 0.10, alpha: 1)
                background = foreground
                foreground = swapped
            }
            if cell.attributes.dim { foreground = foreground.withAlphaComponent(0.6) }
            if let background {
                background.setFill()
                NSRect(x: x, y: y, width: width, height: cellHeight).fill()
            }
            for (offset, item) in run.enumerated() where !item.character.isEmpty && item.character != " " {
                let glyphFont = Self.isPrivateUse(item.character) ? (Self.symbolFont ?? font)
                    : (cell.attributes.bold ? boldFont : font)
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: glyphFont,
                    .foregroundColor: foreground
                ]
                if cell.attributes.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if cell.attributes.italic { attributes[.obliqueness] = 0.18 }
                (item.character as NSString).draw(at: NSPoint(x: x + CGFloat(offset) * cellWidth, y: y + 1),
                                                  withAttributes: attributes)
            }
            column = end
        }
        if let range = selectedColumns(onLine: lineIndex, length: line.count) {
            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45).setFill()
            NSRect(x: inset + CGFloat(range.lowerBound) * cellWidth, y: y,
                   width: CGFloat(range.count) * cellWidth, height: cellHeight).fill()
        }
    }

    /// The xterm palette, with the default foreground pulled to the app's white-on-glass text.
    private func color(_ value: TerminalColor, isForeground: Bool) -> NSColor {
        switch value {
        case .default:
            return isForeground ? NSColor.white.withAlphaComponent(0.92) : .clear
        case let .rgb(r, g, b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case let .indexed(index):
            return Self.palette(Int(index))
        }
    }

    private static let base16: [UInt32] = [
        0x1E1E1E, 0xE5534B, 0x57AB5A, 0xC69026, 0x539BF5, 0xB083F0, 0x39C5CF, 0xD0D0D0,
        0x6E7681, 0xFF7B72, 0x7EE787, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xFFFFFF
    ]

    static func palette(_ index: Int) -> NSColor {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        if index < 16 { return rgb(base16[index]) }
        if index < 232 {
            let n = index - 16
            let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return NSColor(srgbRed: steps[n / 36] / 255, green: steps[(n / 6) % 6] / 255,
                           blue: steps[n % 6] / 255, alpha: 1)
        }
        let level = CGFloat(8 + (index - 232) * 10) / 255
        return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        if let bytes = Self.bytes(for: event, applicationCursor: emulator.applicationCursorKeys) {
            send(bytes)
        } else {
            interpretKeyEvents([event])
        }
    }

    override func doCommand(by selector: Selector) {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "c": copy(nil); return true
            case "v": paste(nil); return true
            case "k":
                emulator.feed("\u{1B}[3J")
                scrollOffset = 0
                needsDisplay = true
                return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard isEnabled, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        send(emulator.bracketedPaste ? "\u{1B}[200~\(normalized)\u{1B}[201~" : normalized)
    }

    fileprivate func send(_ text: String) {
        scrollOffset = 0
        selection = nil
        onInput?(text)
    }

    /// The bytes xterm sends for keys that are not plain text.
    static func bytes(for event: NSEvent, applicationCursor: Bool) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let arrow = applicationCursor ? "\u{1B}O" : "\u{1B}["
        switch Int(event.keyCode) {
        case 126: return arrow + "A"
        case 125: return arrow + "B"
        case 124: return flags.contains(.option) ? "\u{1B}f" : arrow + "C"
        case 123: return flags.contains(.option) ? "\u{1B}b" : arrow + "D"
        case 115: return "\u{1B}[H"
        case 119: return "\u{1B}[F"
        case 116: return "\u{1B}[5~"
        case 121: return "\u{1B}[6~"
        case 117: return "\u{1B}[3~"
        case 51: return flags.contains(.option) ? "\u{1B}\u{7F}" : "\u{7F}"
        case 36, 76: return "\r"
        case 48: return flags.contains(.shift) ? "\u{1B}[Z" : "\t"
        case 53: return "\u{1B}"
        default: break
        }
        if flags.contains(.control), let scalar = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first {
            let value = scalar.value
            if (0x61...0x7A).contains(value) { return String(UnicodeScalar(value - 0x60)!) }
            switch scalar {
            case "[", "3": return "\u{1B}"
            case "\\", "4": return "\u{1C}"
            case "]", "5": return "\u{1D}"
            case "6": return "\u{1E}"
            case "/", "-", "7": return "\u{1F}"
            case " ", "2", "@": return "\u{00}"
            default: break
            }
        }
        if flags.contains(.option), !flags.contains(.command),
           let base = event.charactersIgnoringModifiers, base.count == 1, base.unicodeScalars.first!.isASCII,
           base.unicodeScalars.first!.properties.isAlphabetic {
            // Option as Meta for readline word motions (⌥B / ⌥F / ⌥D), like Terminal's setting.
            return "\u{1B}" + base
        }
        return nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = position(of: event)
        selection = (point, point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = selection?.start else { return }
        selection = (start, position(of: event))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let selection, selection.start == selection.end { self.selection = nil }
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        wheelRemainder += event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? cellHeight : 1)
        let lines = Int(wheelRemainder)
        guard lines != 0 else { return }
        wheelRemainder -= CGFloat(lines)
        scrollOffset = min(max(0, scrollOffset + lines), emulator.scrollback.count)
        needsDisplay = true
    }

    private func position(of event: NSEvent) -> (line: Int, column: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let row = max(0, min(emulator.rows - 1, Int((point.y - inset) / cellHeight)))
        let column = max(0, min(emulator.columns, Int(((point.x - inset) / cellWidth).rounded())))
        let firstLine = emulator.scrollback.count - min(scrollOffset, emulator.scrollback.count)
        return (firstLine + row, column)
    }

    private func ordered() -> (start: (line: Int, column: Int), end: (line: Int, column: Int))? {
        guard let selection else { return nil }
        let a = selection.start, b = selection.end
        return (a.line, a.column) <= (b.line, b.column) ? (a, b) : (b, a)
    }

    private func selectedColumns(onLine line: Int, length: Int) -> Range<Int>? {
        guard let range = ordered(), (range.start.line...range.end.line).contains(line) else { return nil }
        let from = line == range.start.line ? range.start.column : 0
        let to = line == range.end.line ? range.end.column : length
        return from < to ? from..<min(to, length) : nil
    }

    private func selectedText() -> String? {
        guard let range = ordered() else { return nil }
        let lines = emulator.allLines
        var parts: [String] = []
        for index in range.start.line...range.end.line where index < lines.count {
            guard let columns = selectedColumns(onLine: index, length: lines[index].count) else {
                parts.append("")
                continue
            }
            parts.append(TerminalEmulator.text(of: Array(lines[index][columns])))
        }
        return parts.joined(separator: "\n")
    }
}

/// Input methods (Pinyin, Kana…) compose in their own candidate window and commit through
/// `insertText(_:replacementRange:)`; a shell has no notion of marked text, so none is kept.
extension TerminalScreenView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard isEnabled else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if !text.isEmpty { send(text) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Where the candidate window goes: under the cursor cell.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let local = NSRect(x: 8 + CGFloat(emulator.cursorX) * cellWidthForIME,
                           y: 8 + CGFloat(emulator.cursorY + 1) * cellHeightForIME, width: 1, height: cellHeightForIME)
        guard let window else { return .zero }
        return window.convertToScreen(convert(local, to: nil))
    }
}
#endif
