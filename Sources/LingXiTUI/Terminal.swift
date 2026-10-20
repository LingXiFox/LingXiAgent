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
    case unknown, pasteStart, pasteEnd, commandPalette
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
                    switch suffix {
                    case "200~": keys.append(.pasteStart)
                    case "201~": keys.append(.pasteEnd)
                    case "A": keys.append(.up)
                    case "B": keys.append(.down)
                    case "C": keys.append(.right)
                    case "D": keys.append(.left)
                    case "H": keys.append(.home)
                    case "F": keys.append(.end)
                    case "3~": keys.append(.delete)
                    case "5~": keys.append(.pageUp)
                    case "6~": keys.append(.pageDown)
                    default: keys.append(.unknown)
                    }
                    index = end + 1
                } else {
                    keys.append(.escape)
                    index += 1
                }
            case 0x03: keys.append(.interrupt); index += 1
            case 0x04: keys.append(.endOfInput); index += 1
            case 0x10: keys.append(.commandPalette); index += 1
            case 0x15: keys.append(.clearLine); index += 1
            case 0x0D, 0x0A: keys.append(.enter); index += 1
            case 0x7F, 0x08: keys.append(.backspace); index += 1
            case 0x09: keys.append(.tab); index += 1
            case 0x00...0x1F:
                keys.append(.unknown); index += 1
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

    /// Hard-wraps by display width, preserving existing newlines. Combining marks are counted as
    /// zero width is not attempted; text arrives pre-composed from the IME.
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
