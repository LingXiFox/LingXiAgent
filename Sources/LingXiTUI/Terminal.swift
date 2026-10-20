import Darwin
import Foundation

struct TerminalSize: Sendable {
    var columns: Int
    var rows: Int
}

enum Terminal {
    static func size() -> TerminalSize {
        var window = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0, window.ws_col > 0, window.ws_row > 0 {
            return TerminalSize(columns: Int(window.ws_col), rows: Int(window.ws_row))
        }
        return TerminalSize(columns: 80, rows: 24)
    }

    /// Raw input, still with output post-processing so "\n" is enough. Signals are disabled: the
    /// TUI handles Ctrl-C itself so it can cancel a run instead of dying.
    static func enableRawMode() -> termios? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        raw.c_cc.16 = 1 // VMIN
        raw.c_cc.17 = 0 // VTIME
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return nil }
        return original
    }

    static func restore(_ original: termios) {
        var value = original
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &value)
    }
}

enum Key: Equatable {
    case character(Character)
    case enter, backspace, delete, tab
    case left, right, up, down
    case pageUp, pageDown, home, end
    case escape, interrupt, endOfInput, clearLine
    case unknown, pasteStart, pasteEnd, commandPalette, newline, toggleThinking
    case lineStart, lineEnd, wordLeft, wordRight, deleteWordBack, killToEnd, redraw
    case scrollUp, scrollDown
}

/// Decodes terminal input bytes into keys, including multi-byte UTF-8 (Chinese IME output) and the
/// common CSI sequences. A lone ESC is a key; arrow sequences arrive together in practice.
final class KeyParser {
    private var pending: [UInt8] = []

    func feed(_ bytes: [UInt8]) -> [Key] {
        pending.append(contentsOf: bytes)
        var keys: [Key] = []
        var index = 0
        while index < pending.count {
            let byte = pending[index]
            switch byte {
            case 0x1B:
                if index + 1 >= pending.count {
                    keys.append(.escape)
                    index += 1
                } else if pending[index + 1] == UInt8(ascii: "[") {
                    var end = index + 2
                    while end < pending.count, !(0x40...0x7E).contains(pending[end]) { end += 1 }
                    guard end < pending.count else {
                        // Incomplete sequence: keep it for the next read.
                        pending = Array(pending[index...])
                        return keys
                    }
                    let suffix = String(decoding: pending[(index + 2)...end], as: UTF8.self)
                    keys.append(Self.csi(suffix))
                    index = end + 1
                } else if pending[index + 1] == UInt8(ascii: "O") {
                    // SS3: application-mode cursor keys, sent by some terminals for arrows and Home/End.
                    guard index + 2 < pending.count else {
                        pending = Array(pending[index...])
                        return keys
                    }
                    keys.append(Self.csi(String(UnicodeScalar(pending[index + 2]))))
                    index += 3
                } else if pending[index + 1] == 0x0D {
                    keys.append(.newline)
                    index += 2
                } else if pending[index + 1] == 0x7F || pending[index + 1] == 0x08 {
                    keys.append(.deleteWordBack)
                    index += 2
                } else if pending[index + 1] == UInt8(ascii: "b") {
                    keys.append(.wordLeft)
                    index += 2
                } else if pending[index + 1] == UInt8(ascii: "f") {
                    keys.append(.wordRight)
                    index += 2
                } else {
                    keys.append(.escape)
                    index += 1
                }
            case 0x00...0x1F, 0x7F:
                keys.append(Self.control(byte)); index += 1
            default:
                let length: Int
                switch byte {
                case 0x00...0x7F: length = 1
                case 0xC0...0xDF: length = 2
                case 0xE0...0xEF: length = 3
                case 0xF0...0xF7: length = 4
                default: keys.append(.unknown); index += 1; continue
                }
                guard index + length <= pending.count else {
                    pending = Array(pending[index...])
                    return keys
                }
                let slice = pending[index..<(index + length)]
                if let scalar = String(decoding: slice, as: UTF8.self).first {
                    keys.append(.character(scalar))
                } else {
                    keys.append(.unknown)
                }
                index += length
            }
        }
        pending.removeAll(keepingCapacity: true)
        return keys
    }

    private static func control(_ byte: UInt8) -> Key {
        switch byte {
        case 0x01: .lineStart
        case 0x03: .interrupt
        case 0x04: .endOfInput
        case 0x05: .lineEnd
        case 0x09: .tab
        case 0x0A: .newline
        case 0x0B: .killToEnd
        case 0x0C: .redraw
        case 0x0D: .enter
        case 0x10: .commandPalette
        case 0x14: .toggleThinking
        case 0x15: .clearLine
        case 0x17: .deleteWordBack
        case 0x7F, 0x08: .backspace
        default: .unknown
        }
    }

    /// Kitty keyboard protocol, "disambiguate" level: `CSI code[:alt];mods[:event] u`. Modifier bits
    /// after subtracting one: 1 shift, 2 alt, 4 ctrl. Ctrl-letters map back to their legacy bytes.
    private static func csiU(_ body: Substring) -> Key {
        let fields = body.split(separator: ";", omittingEmptySubsequences: false)
        guard let code = fields.first?.split(separator: ":").first.flatMap({ Int($0) }) else { return .unknown }
        let mods = (fields.count > 1 ? fields[1].split(separator: ":").first.flatMap { Int($0) } : nil).map { $0 - 1 } ?? 0
        let shift = mods & 1 != 0, alt = mods & 2 != 0, ctrl = mods & 4 != 0
        switch code {
        case 13: return shift || alt || ctrl ? .newline : .enter
        case 27: return .escape
        case 9: return .tab
        case 127, 8: return alt || ctrl ? .deleteWordBack : .backspace
        default:
            guard let scalar = Unicode.Scalar(code) else { return .unknown }
            if ctrl, !alt, (0x61...0x7A).contains(code) || (0x41...0x5A).contains(code) {
                return control(UInt8(code & 0x1F))
            }
            if alt, !ctrl, code == 0x62 { return .wordLeft }
            if alt, !ctrl, code == 0x66 { return .wordRight }
            if !ctrl, !alt, !(0xE000...0xF8FF).contains(code) { return .character(Character(scalar)) }
            return .unknown
        }
    }

    private static func csi(_ suffix: String) -> Key {
        if suffix.hasSuffix("u"), let first = suffix.first, first.isNumber {
            return csiU(suffix.dropLast())
        }
        switch suffix {
        case "200~": return .pasteStart
        case "201~": return .pasteEnd
        case "A": return .up
        case "B": return .down
        case "C": return .right
        case "D": return .left
        case "H", "1~", "7~": return .home
        case "F", "4~", "8~": return .end
        case "3~": return .delete
        case "5~": return .pageUp
        case "6~": return .pageDown
        case "1;3C", "1;5C", "1;9C": return .wordRight
        case "1;3D", "1;5D", "1;9D": return .wordLeft
        case "27;2;13~", "27;3;13~", "27;5;13~": return .newline
        default:
            // SGR mouse report: only the wheel is used, and only while /mouse is on.
            if suffix.hasPrefix("<"), suffix.hasSuffix("M") {
                let button = suffix.dropFirst().split(separator: ";").first.flatMap { Int($0) }
                if button == 64 { return .scrollUp }
                if button == 65 { return .scrollDown }
            }
            return .unknown
        }
    }
}

enum TextWidth {
    /// East Asian wide/fullwidth characters occupy two terminal cells. This is a display estimate,
    /// not Unicode-perfect: it covers CJK, Hangul, fullwidth forms and emoji ranges.
    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF,
             0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    static func width(_ text: String) -> Int {
        text.reduce(0) { total, character in
            let cells = character.unicodeScalars.map { scalar -> Int in
                if [.nonspacingMark, .enclosingMark, .format].contains(scalar.properties.generalCategory) { return 0 }
                return isWide(scalar) || (0x1F1E6...0x1F1FF).contains(scalar.value) ? 2 : 1
            }.max() ?? 0
            return total + cells
        }
    }

    /// Hard-wraps by grapheme display width, preserving existing newlines.
    static func wrap(_ text: String, width: Int) -> [String] {
        guard width > 0 else { return [text] }
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var current = ""
            var currentWidth = 0
            for character in paragraph {
                let cell = Self.width(String(character))
                if currentWidth + cell > width, !current.isEmpty {
                    lines.append(current)
                    current = String(character)
                    currentWidth = cell
                } else {
                    current.append(character)
                    currentWidth += cell
                }
            }
            lines.append(current)
        }
        return lines
    }
}

/// A dedicated blocking reader: terminal input must not sit on a cooperative thread.
final class InputReader: @unchecked Sendable {
    private var thread: Thread?
    private let onBytes: @Sendable ([UInt8]) -> Void

    init(onBytes: @escaping @Sendable ([UInt8]) -> Void) {
        self.onBytes = onBytes
    }

    func start() {
        let thread = Thread { [onBytes] in
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count <= 0 { return }
                onBytes(Array(buffer[0..<count]))
            }
        }
        thread.name = "lingxi.tui.input"
        thread.start()
        self.thread = thread
    }
}
