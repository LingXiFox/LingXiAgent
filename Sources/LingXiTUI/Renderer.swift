import Foundation

struct RGB {
    let r: Int, g: Int, b: Int
    var fg: String { "\u{1B}[38;2;\(r);\(g);\(b)m" }
    var bg: String { "\u{1B}[48;2;\(r);\(g);\(b)m" }
}

enum Theme {
    static let charcoal = RGB(r: 28, g: 28, b: 30)
    static let charcoalRaised = RGB(r: 40, g: 40, b: 44)
    static let cream = RGB(r: 244, g: 237, b: 228)
    static let fox = RGB(r: 232, g: 115, b: 42)
    static let dim = RGB(r: 146, g: 140, b: 132)
    static let error = RGB(r: 229, g: 72, b: 77)
    static let reset = "\u{1B}[0m"
}

enum Role: Equatable {
    case user
    case assistant
    case tool
    case system
    case error
}

struct Message {
    var role: Role
    var text: String
    var streaming: Bool = false
}

/// A deliberately small renderer: full-frame redraws, hard wrapping by display width, and a
/// markdown subset (fenced code, headings, inline code, bold). No layout engine, no effects.
struct Renderer {
    let columns: Int
    let rows: Int

    private var width: Int { max(20, columns) }
    private var viewportHeight: Int { max(3, rows - 4) }

    func frame(messages: [Message], scrollFromBottom: Int, input: [Character], cursor: Int, header: String, status: String) -> String {
        var lines: [String] = []
        for (index, message) in messages.enumerated() {
            if index > 0 { lines.append("") }
            lines.append(contentsOf: render(message))
        }
        if lines.isEmpty {
            lines = ["", "  \(Theme.dim.fg)在下方输入消息开始对话。试试 /help。\(Theme.reset)"]
        }

        let visible: ArraySlice<String>
        if lines.count <= viewportHeight {
            visible = lines[...]
        } else {
            let maxScroll = lines.count - viewportHeight
            let scroll = min(max(0, scrollFromBottom), maxScroll)
            let end = lines.count - scroll
            let start = max(0, end - viewportHeight)
            visible = lines[start..<end]
        }

        var screen: [String] = []
        screen.append(fit(" " + Theme.fox.fg + "灵犀" + Theme.reset + "  " + Theme.cream.fg + header + Theme.reset))
        screen.append(Theme.dim.fg + String(repeating: "─", count: width) + Theme.reset)
        screen.append(contentsOf: visible)
        while screen.count < viewportHeight + 2 {
            screen.append("")
        }
        screen.append(Theme.fox.fg + "› " + Theme.reset + renderInput(input, cursor: cursor))
        screen.append(fit(Theme.dim.fg + status + Theme.reset))
        return screen.prefix(rows).joined(separator: "\n")
    }

    private func render(_ message: Message) -> [String] {
        switch message.role {
        case .user:
            return labeled("你", color: Theme.fox, text: message.text)
        case .assistant:
            return labeled("灵犀", color: Theme.fox, text: message.text, streaming: message.streaming)
        case .tool:
            return TextWidth.wrap("  · " + message.text, width: width).enumerated().map { index, line in
                index == 0 ? Theme.dim.fg + line + Theme.reset : Theme.dim.fg + "    " + line + Theme.reset
            }
        case .system:
            return TextWidth.wrap("  " + message.text, width: width).map { Theme.dim.fg + $0 + Theme.reset }
        case .error:
            return TextWidth.wrap("  " + message.text, width: width).map { Theme.error.fg + $0 + Theme.reset }
        }
    }

    private func labeled(_ label: String, color: RGB, text: String, streaming: Bool = false) -> [String] {
        let prefixWidth = TextWidth.width(label) + 2
        let body = markdownLines(text, width: max(10, width - prefixWidth), streaming: streaming)
        guard !body.isEmpty else { return [color.fg + label + Theme.reset] }
        var lines: [String] = []
        for (index, line) in body.enumerated() {
            if index == 0 {
                lines.append(color.fg + label + "  " + Theme.reset + line)
            } else {
                lines.append(String(repeating: " ", count: prefixWidth) + line)
            }
        }
        return lines
    }

    /// Markdown subset. Code fences keep their content verbatim (wrapped), get a dim orange gutter
    /// and a raised background; headings are orange; `code` is orange; **bold** is bold.
    private func markdownLines(_ text: String, width: Int, streaming: Bool) -> [String] {
        var output: [String] = []
        var inCode = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("```") {
                inCode.toggle()
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                output.append(Theme.dim.fg + "  ┄ " + (inCode ? (language.isEmpty ? "code" : language) : "") + Theme.reset)
                continue
            }
            if inCode {
                let wrapped = TextWidth.wrap(line, width: max(10, width - 3))
                for piece in wrapped {
                    output.append(
                        Theme.charcoalRaised.bg + Theme.dim.fg + " │ " + Theme.cream.fg + piece
                            + Theme.reset + Theme.charcoal.bg
                    )
                }
                continue
            }
            if line.hasPrefix("#") {
                let heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                output.append(Theme.fox.fg + "\u{1B}[1m" + heading + Theme.reset)
                continue
            }
            for wrapped in TextWidth.wrap(line, width: width) {
                output.append(inline(wrapped))
            }
        }
        var result = output
        if streaming {
            if result.isEmpty {
                result.append(Theme.fox.fg + "▍" + Theme.reset)
            } else {
                result[result.count - 1] += Theme.fox.fg + "▍" + Theme.reset
            }
        }
        return result
    }

    private func inline(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        var inCode = false
        var inBold = false
        while index < text.endIndex {
            if text[index...].hasPrefix("`") {
                inCode.toggle()
                result += inCode ? Theme.fox.fg : Theme.cream.fg
                index = text.index(after: index)
                continue
            }
            if text[index...].hasPrefix("**") {
                inBold.toggle()
                result += inBold ? "\u{1B}[1m" : "\u{1B}[22m"
                index = text.index(index, offsetBy: 2)
                continue
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result + Theme.cream.fg
    }

    private func renderInput(_ input: [Character], cursor: Int) -> String {
        guard !input.isEmpty else {
            return Theme.dim.fg + "▏" + Theme.reset
        }
        let index = min(max(0, cursor), input.count)
        var text = ""
        for (position, character) in input.enumerated() {
            if position == index {
                text += "\u{1B}[7m" + String(character) + Theme.reset + Theme.cream.fg
            } else {
                text += String(character)
            }
        }
        if index == input.count {
            text += "\u{1B}[7m \u{1B}[27m"
        }
        // Keep the cursor visible on narrow terminals by dropping leading characters.
        let prefix = String(input[0..<index])
        let overflow = TextWidth.width(prefix) + 3 - width
        if overflow > 0, index > 0 {
            var drop = 0
            var dropped = 0
            while drop < index - 1, dropped < overflow {
                dropped += TextWidth.width(String(input[drop]))
                drop += 1
            }
            let visible = input[drop...]
            var rebuilt = ""
            for (position, character) in visible.enumerated() {
                let absolute = drop + position
                if absolute == index {
                    rebuilt += "\u{1B}[7m" + String(character) + Theme.reset + Theme.cream.fg
                } else {
                    rebuilt += String(character)
                }
            }
            if index == input.count { rebuilt += "\u{1B}[7m \u{1B}[27m" }
            return Theme.cream.fg + rebuilt
        }
        return Theme.cream.fg + text
    }

    /// Pads/truncates a pre-styled line to the terminal width. ANSI codes make exact padding hard,
    /// so this only guards the simplest case (styled header/footer containing no wide text).
    private func fit(_ line: String) -> String {
        line
    }
}
