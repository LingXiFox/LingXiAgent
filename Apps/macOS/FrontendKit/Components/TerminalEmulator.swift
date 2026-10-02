import Foundation

// MARK: - Terminal emulator
//
// The terminal pane used to strip every escape sequence out of the PTY's output and append
// what was left to a string, with a one-line text field underneath: a transcript of a shell,
// one bubble per command, where `vim`, `top`, a progress bar or a coloured `ls` could not work.
//
// This is the screen model a real terminal keeps: a grid of cells with attributes, a cursor,
// a scroll region, scrollback and the alternate screen, driven by the subset of the xterm
// control set that shells and full-screen programs actually emit. It holds no view and no I/O;
// replies a program asks for (cursor position, device attributes) go out through `respond`.

/// 16-colour palette index, 256-colour index, or 24-bit RGB.
enum TerminalColor: Equatable, Hashable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

struct TerminalAttributes: Equatable, Hashable {
    var foreground: TerminalColor = .default
    var background: TerminalColor = .default
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var inverse = false
}

struct TerminalCell: Equatable {
    /// One grapheme, or "" for the right half of a wide character.
    var character: String = " "
    var attributes = TerminalAttributes()

    static let blank = TerminalCell()
}

final class TerminalEmulator {
    private(set) var columns: Int
    private(set) var rows: Int
    private(set) var grid: [[TerminalCell]]
    private(set) var scrollback: [[TerminalCell]] = []
    private(set) var cursorX = 0
    private(set) var cursorY = 0
    private(set) var cursorVisible = true
    /// DECCKM: arrows send `ESC O x` instead of `ESC [ x`.
    private(set) var applicationCursorKeys = false
    private(set) var bracketedPaste = false
    private(set) var usingAlternateScreen = false
    /// Bumped on every change, so a view redraws only when there is something new.
    private(set) var generation = 0

    var respond: ((String) -> Void)?

    static let scrollbackLimit = 5_000

    private var attributes = TerminalAttributes()
    private var scrollTop = 0
    private var scrollBottom: Int
    private var pendingWrap = false
    private var savedCursor: (x: Int, y: Int, attributes: TerminalAttributes) = (0, 0, TerminalAttributes())
    private var primary: (grid: [[TerminalCell]], cursorX: Int, cursorY: Int)?
    private var originMode = false
    private var autoWrap = true

    private enum State { case ground, escape, escapeIntermediate, csi, osc, oscEscape }
    private var state = State.ground
    private var parameters = ""
    private var intermediates = ""
    /// Bytes of a UTF-8 sequence split across two reads.
    private var utf8Carry: [UInt8] = []

    init(columns: Int = 80, rows: Int = 24) {
        self.columns = max(2, columns)
        self.rows = max(2, rows)
        grid = Array(repeating: Array(repeating: .blank, count: max(2, columns)), count: max(2, rows))
        scrollBottom = max(2, rows) - 1
    }

    // MARK: Input

    func feed(_ bytes: Data) {
        var buffer = utf8Carry + [UInt8](bytes)
        utf8Carry = []
        // Hold back an incomplete trailing UTF-8 sequence for the next read.
        var cut = buffer.count
        var back = 0
        while back < min(4, buffer.count) {
            let byte = buffer[buffer.count - 1 - back]
            if byte & 0xC0 == 0x80 { back += 1; continue }
            if byte & 0x80 != 0 {
                let need = byte & 0xE0 == 0xC0 ? 2 : (byte & 0xF0 == 0xE0 ? 3 : 4)
                if back + 1 < need { cut = buffer.count - 1 - back }
            }
            break
        }
        if cut < buffer.count {
            utf8Carry = Array(buffer[cut...])
            buffer.removeSubrange(cut...)
        }
        feed(String(decoding: buffer, as: UTF8.self))
    }

    func feed(_ text: String) {
        for scalar in text.unicodeScalars { consume(scalar) }
        generation &+= 1
    }

    private func consume(_ scalar: Unicode.Scalar) {
        let value = scalar.value
        switch state {
        case .ground:
            if value == 0x1B { state = .escape; return }
            if value < 0x20 || value == 0x7F { control(value); return }
            print(scalar)
        case .escape:
            escape(scalar)
        case .escapeIntermediate:
            // Charset designation (ESC ( B) and friends: the final byte is consumed, nothing changes.
            if value >= 0x30 { state = .ground }
        case .csi:
            if value == 0x1B { state = .escape; return }
            if value < 0x20 { control(value); return }
            if (0x30...0x3F).contains(value) { parameters.unicodeScalars.append(scalar); return }
            if (0x20...0x2F).contains(value) { intermediates.unicodeScalars.append(scalar); return }
            state = .ground
            csi(Character(scalar))
        case .osc:
            if value == 0x07 { state = .ground; return }
            if value == 0x1B { state = .oscEscape; return }
            // Window titles and hyperlinks are not drawn; the text is discarded.
        case .oscEscape:
            state = value == 0x5C ? .ground : .osc
        }
    }

    private func control(_ value: UInt32) {
        switch value {
        case 0x07: break
        case 0x08:
            pendingWrap = false
            cursorX = max(0, cursorX - 1)
        case 0x09:
            pendingWrap = false
            cursorX = min(columns - 1, (cursorX / 8 + 1) * 8)
        case 0x0A, 0x0B, 0x0C:
            lineFeed()
        case 0x0D:
            pendingWrap = false
            cursorX = 0
        default: break
        }
    }

    private func escape(_ scalar: Unicode.Scalar) {
        state = .ground
        switch scalar {
        case "[": state = .csi; parameters = ""; intermediates = ""
        case "]": state = .osc
        case "(", ")", "*", "+", "#", "%": state = .escapeIntermediate
        case "7": savedCursor = (cursorX, cursorY, attributes)
        case "8": restoreCursor()
        case "D": lineFeed()
        case "E": cursorX = 0; lineFeed()
        case "M": reverseIndex()
        case "c": reset()
        default: break   // ESC = / ESC > (keypad modes) and the rest change nothing drawn.
        }
    }

    // MARK: Printing

    private func print(_ scalar: Unicode.Scalar) {
        // Combining marks join the previous cell instead of taking one.
        if scalar.properties.generalCategory == .nonspacingMark
            || scalar.properties.generalCategory == .enclosingMark
            || scalar.value == 0x200D || (0xFE00...0xFE0F).contains(scalar.value) {
            let x = pendingWrap ? cursorX : max(0, cursorX - 1)
            if grid[cursorY][x].character.isEmpty, x > 0 {
                grid[cursorY][x - 1].character.unicodeScalars.append(scalar)
            } else {
                grid[cursorY][x].character.unicodeScalars.append(scalar)
            }
            return
        }
        let width = Self.width(of: scalar)
        if pendingWrap {
            if autoWrap { cursorX = 0; lineFeed() }
            pendingWrap = false
        }
        if width == 2 && cursorX == columns - 1 {
            grid[cursorY][cursorX] = TerminalCell(character: " ", attributes: attributes)
            if autoWrap { cursorX = 0; lineFeed() }
        }
        grid[cursorY][cursorX] = TerminalCell(character: String(scalar), attributes: attributes)
        if width == 2, cursorX + 1 < columns {
            grid[cursorY][cursorX + 1] = TerminalCell(character: "", attributes: attributes)
        }
        let next = cursorX + width
        if next >= columns {
            cursorX = columns - 1
            pendingWrap = true
        } else {
            cursorX = next
        }
    }

    /// East Asian wide and emoji presentation take two cells; everything else one.
    static func width(of scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v < 0x1100 { return 1 }
        if (0x1100...0x115F).contains(v) || (0x2E80...0x303E).contains(v) || (0x3041...0x33FF).contains(v)
            || (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xA000...0xA4CF).contains(v)
            || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v)
            || (0xFF00...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v)
            || (0x1F300...0x1F64F).contains(v) || (0x1F900...0x1F9FF).contains(v)
            || (0x20000...0x3FFFD).contains(v) {
            return 2
        }
        return 1
    }

    // MARK: Movement and scrolling

    private func lineFeed() {
        pendingWrap = false
        if cursorY == scrollBottom {
            scrollUp(1)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
    }

    private func reverseIndex() {
        pendingWrap = false
        if cursorY == scrollTop { scrollDown(1) } else if cursorY > 0 { cursorY -= 1 }
    }

    private func blankLine() -> [TerminalCell] {
        Array(repeating: TerminalCell(character: " ", attributes: TerminalAttributes(background: attributes.background)),
              count: columns)
    }

    private func scrollUp(_ count: Int) {
        for _ in 0..<max(1, count) {
            let removed = grid.remove(at: scrollTop)
            // Only a full-screen scroll of the primary screen is history; a status line
            // redrawn in a region, or anything on the alternate screen, is not.
            if scrollTop == 0, !usingAlternateScreen {
                scrollback.append(removed)
                if scrollback.count > Self.scrollbackLimit { scrollback.removeFirst(scrollback.count - Self.scrollbackLimit) }
            }
            grid.insert(blankLine(), at: scrollBottom)
        }
    }

    private func scrollDown(_ count: Int) {
        for _ in 0..<max(1, count) {
            grid.remove(at: scrollBottom)
            grid.insert(blankLine(), at: scrollTop)
        }
    }

    private func restoreCursor() {
        cursorX = min(savedCursor.x, columns - 1)
        cursorY = min(savedCursor.y, rows - 1)
        attributes = savedCursor.attributes
        pendingWrap = false
    }

    private func reset() {
        attributes = TerminalAttributes()
        grid = Array(repeating: Array(repeating: .blank, count: columns), count: rows)
        cursorX = 0; cursorY = 0
        scrollTop = 0; scrollBottom = rows - 1
        cursorVisible = true
        applicationCursorKeys = false
        bracketedPaste = false
        originMode = false
        autoWrap = true
        pendingWrap = false
    }

    // MARK: CSI

    private func csi(_ final: Character) {
        let isPrivate = parameters.hasPrefix("?")
        let raw = isPrivate ? String(parameters.dropFirst()) : parameters
        let params = raw.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func p(_ index: Int, _ fallback: Int = 1) -> Int {
            index < params.count && params[index] != 0 ? params[index] : fallback
        }
        if final != "m" { pendingWrap = false }
        guard intermediates.isEmpty else { return }   // e.g. DECSCUSR `CSI 2 SP q`
        switch final {
        // Vertical moves stop at the scroll region's edge when they start inside it.
        case "A": cursorY = max(cursorY >= scrollTop ? scrollTop : 0, cursorY - p(0))
        case "B", "e": cursorY = min(cursorY <= scrollBottom ? scrollBottom : rows - 1, cursorY + p(0))
        case "C", "a": cursorX = min(columns - 1, cursorX + p(0))
        case "D": cursorX = max(0, cursorX - p(0))
        case "E": cursorX = 0; cursorY = min(rows - 1, cursorY + p(0))
        case "F": cursorX = 0; cursorY = max(0, cursorY - p(0))
        case "G", "`": cursorX = min(columns - 1, p(0) - 1)
        case "d": cursorY = min(rows - 1, (originMode ? scrollTop : 0) + p(0) - 1)
        case "H", "f":
            cursorY = min(rows - 1, (originMode ? scrollTop : 0) + p(0) - 1)
            cursorX = min(columns - 1, p(1) - 1)
        case "J": eraseDisplay(params.first ?? 0)
        case "K": eraseLine(params.first ?? 0)
        case "L":
            guard (scrollTop...scrollBottom).contains(cursorY) else { break }
            for _ in 0..<p(0) {
                grid.remove(at: scrollBottom)
                grid.insert(blankLine(), at: cursorY)
            }
        case "M":
            guard (scrollTop...scrollBottom).contains(cursorY) else { break }
            for _ in 0..<p(0) {
                grid.remove(at: cursorY)
                grid.insert(blankLine(), at: scrollBottom)
            }
        case "P":
            let count = min(p(0), columns - cursorX)
            grid[cursorY].removeSubrange(cursorX..<(cursorX + count))
            grid[cursorY].append(contentsOf: Array(repeating: TerminalCell.blank, count: count))
        case "@":
            let count = min(p(0), columns - cursorX)
            grid[cursorY].insert(contentsOf: Array(repeating: TerminalCell.blank, count: count), at: cursorX)
            grid[cursorY].removeLast(count)
        case "X":
            for x in cursorX..<min(columns, cursorX + p(0)) { grid[cursorY][x] = .blank }
        case "S": scrollUp(p(0))
        case "T": scrollDown(p(0))
        case "r":
            let top = p(0) - 1
            let bottom = (params.count > 1 && params[1] != 0 ? params[1] : rows) - 1
            if top < bottom, bottom < rows {
                scrollTop = top; scrollBottom = bottom
                cursorX = 0; cursorY = originMode ? top : 0
            }
        case "s": savedCursor = (cursorX, cursorY, attributes)
        case "u": restoreCursor()
        case "m": selectGraphicRendition(params)
        case "h", "l": setMode(params, isPrivate: isPrivate, on: final == "h")
        case "n":
            if params.first == 6 { respond?("\u{1B}[\(cursorY + 1);\(cursorX + 1)R") }
            else if params.first == 5 { respond?("\u{1B}[0n") }
        case "c":
            if !isPrivate { respond?("\u{1B}[?62;22c") }
        default: break
        }
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLine(0)
            for y in (cursorY + 1)..<rows { grid[y] = blankLine() }
        case 1:
            eraseLine(1)
            for y in 0..<cursorY { grid[y] = blankLine() }
        case 2:
            for y in 0..<rows { grid[y] = blankLine() }
        case 3:
            scrollback.removeAll()
        default: break
        }
    }

    private func eraseLine(_ mode: Int) {
        let blank = TerminalCell(character: " ", attributes: TerminalAttributes(background: attributes.background))
        let range: Range<Int>
        switch mode {
        case 0: range = cursorX..<columns
        case 1: range = 0..<min(columns, cursorX + 1)
        default: range = 0..<columns
        }
        for x in range { grid[cursorY][x] = blank }
    }

    private func setMode(_ params: [Int], isPrivate: Bool, on: Bool) {
        guard isPrivate else { return }
        for mode in params {
            switch mode {
            case 1: applicationCursorKeys = on
            case 6: originMode = on; cursorX = 0; cursorY = on ? scrollTop : 0
            case 7: autoWrap = on
            case 25: cursorVisible = on
            case 2004: bracketedPaste = on
            case 47, 1047, 1049: switchScreen(alternate: on, saveCursor: mode == 1049)
            default: break
            }
        }
    }

    private func switchScreen(alternate: Bool, saveCursor: Bool) {
        guard alternate != usingAlternateScreen else { return }
        if alternate {
            if saveCursor { savedCursor = (cursorX, cursorY, attributes) }
            primary = (grid, cursorX, cursorY)
            grid = Array(repeating: Array(repeating: .blank, count: columns), count: rows)
            usingAlternateScreen = true
        } else {
            if let primary, primary.grid.count == rows, primary.grid.first?.count == columns {
                grid = primary.grid
            }
            usingAlternateScreen = false
            primary = nil
            if saveCursor { restoreCursor() }
        }
        scrollTop = 0; scrollBottom = rows - 1
    }

    private func selectGraphicRendition(_ params: [Int]) {
        var index = 0
        let codes = params.isEmpty ? [0] : params
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: attributes = TerminalAttributes()
            case 1: attributes.bold = true
            case 2: attributes.dim = true
            case 3: attributes.italic = true
            case 4: attributes.underline = true
            case 7: attributes.inverse = true
            case 22: attributes.bold = false; attributes.dim = false
            case 23: attributes.italic = false
            case 24: attributes.underline = false
            case 27: attributes.inverse = false
            case 30...37: attributes.foreground = .indexed(UInt8(code - 30))
            case 39: attributes.foreground = .default
            case 40...47: attributes.background = .indexed(UInt8(code - 40))
            case 49: attributes.background = .default
            case 90...97: attributes.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: attributes.background = .indexed(UInt8(code - 100 + 8))
            case 38, 48:
                var color: TerminalColor?
                if index + 2 < codes.count, codes[index + 1] == 5 {
                    color = .indexed(UInt8(clamping: codes[index + 2])); index += 2
                } else if index + 4 < codes.count, codes[index + 1] == 2 {
                    color = .rgb(UInt8(clamping: codes[index + 2]), UInt8(clamping: codes[index + 3]),
                                 UInt8(clamping: codes[index + 4])); index += 4
                }
                if let color {
                    if code == 38 { attributes.foreground = color } else { attributes.background = color }
                }
            default: break
            }
            index += 1
        }
    }

    // MARK: Resize

    func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(2, newColumns), newRows = max(2, newRows)
        guard newColumns != columns || newRows != rows else { return }
        func fit(_ line: [TerminalCell]) -> [TerminalCell] {
            line.count >= newColumns ? Array(line.prefix(newColumns))
                : line + Array(repeating: .blank, count: newColumns - line.count)
        }
        grid = grid.map(fit)
        scrollback = scrollback.map(fit)
        if newRows < rows {
            // Keep the cursor's line on screen: what falls off the top becomes history.
            let overflow = max(0, cursorY - (newRows - 1))
            if overflow > 0 {
                if !usingAlternateScreen { scrollback.append(contentsOf: grid.prefix(overflow)) }
                grid.removeFirst(overflow)
                cursorY -= overflow
            }
            grid = Array(grid.prefix(newRows))
        } else if newRows > rows {
            grid += Array(repeating: Array(repeating: .blank, count: newColumns), count: newRows - rows)
        }
        columns = newColumns
        rows = newRows
        cursorX = min(cursorX, columns - 1)
        cursorY = min(cursorY, rows - 1)
        scrollTop = 0
        scrollBottom = rows - 1
        primary = nil
        pendingWrap = false
        generation &+= 1
    }

    // MARK: Reading back

    /// Scrollback plus screen, top to bottom.
    var allLines: [[TerminalCell]] { scrollback + grid }

    static func text(of line: [TerminalCell]) -> String {
        var text = line.map { $0.character }.joined()
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    /// The visible screen as plain text, for tests and accessibility.
    var screenText: String { grid.map(Self.text).joined(separator: "\n") }
}
