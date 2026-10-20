import Foundation

struct RGB {
    let r: Int, g: Int, b: Int
    var fg: String { "\u{1B}[38;2;\(r);\(g);\(b)m" }
    var bg: String { "\u{1B}[48;2;\(r);\(g);\(b)m" }
}

enum Theme {
    static let charcoal = RGB(r: 22, g: 24, b: 28)
    static let charcoalRaised = RGB(r: 34, g: 38, b: 44)
    static let cream = RGB(r: 230, g: 232, b: 237)
    static let fox = RGB(r: 239, g: 177, b: 123)
    static let dim = RGB(r: 160, g: 167, b: 178)
    static let error = RGB(r: 255, g: 139, b: 149)
    // Reset text attributes without falling back to the terminal profile's background.
    static let reset = "\u{1B}[0m" + charcoal.bg + cream.fg
}

enum Role: Equatable { case user, assistant, tool, system, error }
struct Message {
    var role: Role
    var text: String
    var streaming: Bool = false
}

struct MenuItem {
    let title: String
    let detail: String
    let command: String
}

struct Picker {
    let title: String
    let items: [MenuItem]
    var query = ""
    var selected = 0
    var filtered: [MenuItem] {
        guard !query.isEmpty else { return items }
        return items.filter { ($0.title + " " + $0.detail + " " + $0.command).localizedCaseInsensitiveContains(query) }
    }
}

struct AuthPrompt {
    let label: String
    let characterCount: Int
}

/// Cell-bounded full frames. Each row has its own cursor address and erase operation, so shorter
/// input and a hidden credential prompt cannot leave text from the previous frame on screen.
struct Renderer {
    let columns: Int
    let rows: Int
    private var width: Int { max(1, columns) }
    private var height: Int { max(1, rows) }
    private var contentWidth: Int { max(1, min(96, width - 8)) }

    func frame(messages: [Message], scrollFromBottom: Int, input: [Character], cursor: Int,
               header: String, status: String, workspace: String, feedback: Message?,
               picker: Picker?, auth: AuthPrompt?) -> String {
        var screen = [String](repeating: "", count: height)
        let home = messages.isEmpty
        let left = max(0, (width - contentWidth) / 2)
        screen[0] = "  " + Theme.fox.fg + "lingxi" + Theme.reset + "  " + Theme.dim.fg + clean(workspace)
        if height > 2 {
            screen[height - 1] = "  " + Theme.dim.fg + fit("\(status)", limit: width - 4)
        }

        if let auth {
            let panelWidth = max(1, min(64, width - 6))
            let mask = auth.characterCount == 0 ? "▏" : "••••••••  已输入 \(auth.characterCount) 个字符"
            var panel = [
                Theme.fox.fg + "连接模型" + Theme.reset + "  /  " + clean(auth.label),
                "",
                Theme.dim.fg + "密钥加密保存在此 Mac 的 Keychain。",
                Theme.dim.fg + "不会进入对话或命令历史。",
                "",
                Theme.cream.fg + "│  " + mask,
                "",
                Theme.fox.fg + "Enter 保存" + Theme.dim.fg + "    Esc 取消  ·  隐藏输入中",
            ]
            if let feedback, feedback.role == .error {
                panel += ["", Theme.error.fg + fit(clean(feedback.text), limit: panelWidth)]
            }
            placePanel(panel, width: panelWidth, into: &screen)
        } else {
            let composerRow = home ? max(3, min(height - 8, height / 2)) : max(1, height - 7)
            if home, height >= 16 {
                let logoRow = max(2, composerRow - 5)
                screen[logoRow] = centered(Theme.cream.fg + "L I N G X I", cells: 11)
                screen[logoRow + 2] = centered(Theme.dim.fg + "灵犀 · 2.0", cells: 11)
            } else if !home {
                var body: [String] = []
                for message in messages {
                    if !body.isEmpty { body.append("") }
                    body += render(message)
                }
                let available = max(0, composerRow - 3)
                let end = max(0, body.count - min(max(0, scrollFromBottom), max(0, body.count - available)))
                let start = max(0, end - available)
                for (offset, line) in body[start..<end].enumerated() {
                    screen[2 + offset] = String(repeating: " ", count: left) + line
                }
            }
            let panelWidth = home ? min(76, contentWidth) : contentWidth
            let composerLeft = max(0, (width - panelWidth) / 2)
            let rail = Theme.fox.fg + "┃" + Theme.charcoalRaised.bg + Theme.cream.fg
            let entry = input.isEmpty
                ? Theme.dim.fg + "输入消息，或按 / 选择命令"
                : renderInput(input, cursor: cursor, limit: max(1, panelWidth - 5))
            let panel = [
                rail + String(repeating: " ", count: max(0, panelWidth - 1)),
                rail + "  " + fit(entry, limit: panelWidth - 4),
                rail,
                rail + "  " + Theme.dim.fg + fit(clean(header), limit: panelWidth - 4),
            ]
            for (offset, line) in panel.enumerated() where composerRow + offset < height - 1 {
                screen[composerRow + offset] = String(repeating: " ", count: composerLeft) + paddedPanel(line, cells: panelWidth)
            }
            if let feedback {
                let available = max(0, height - composerRow - 6)
                for (offset, line) in TextWidth.wrap(clean(feedback.text), width: panelWidth).prefix(available).enumerated() {
                    screen[composerRow + 5 + offset] = String(repeating: " ", count: composerLeft)
                        + (feedback.role == .error ? Theme.error.fg : Theme.dim.fg) + line
                }
            }
            if let picker { drawPicker(picker, into: &screen) }
        }

        var frame = "\u{1B}[?2026h"
        for (row, line) in screen.enumerated() {
            frame += "\u{1B}[\(row + 1);1H" + Theme.reset + "\u{1B}[2K" + fit(line, limit: width)
        }
        return frame + "\u{1B}[?2026l"
    }

    private func drawPicker(_ picker: Picker, into screen: inout [String]) {
        let panelWidth = max(1, min(68, width - 6))
        let count = max(1, min(7, height - 10))
        let items = picker.filtered
        let selected = min(max(0, picker.selected), max(0, items.count - 1))
        let start = max(0, min(selected - count / 2, items.count - count))
        var panel = [Theme.fox.fg + clean(picker.title) + Theme.dim.fg + "    esc 关闭", "",
                     Theme.cream.fg + "› " + clean(picker.query) + "▏", ""]
        if items.isEmpty { panel.append(Theme.dim.fg + "没有匹配项") }
        for (offset, item) in items.dropFirst(start).prefix(count).enumerated() {
            let active = start + offset == selected
            panel.append((active ? Theme.fox.fg + "› " : Theme.cream.fg + "  ")
                + fit(clean(item.title), limit: panelWidth - 4))
            if active, !item.detail.isEmpty {
                panel.append(Theme.dim.fg + "  " + fit(clean(item.detail), limit: panelWidth - 4))
            }
        }
        panel += ["", Theme.dim.fg + "↑↓ 选择    Enter 确认    Esc 返回"]
        placePanel(panel, width: panelWidth, into: &screen)
    }

    private func placePanel(_ lines: [String], width panelWidth: Int, into screen: inout [String]) {
        let left = max(0, (width - panelWidth - 4) / 2)
        let count = min(lines.count, max(1, height - 4))
        let start = max(1, (height - count - 2) / 2)
        let panel = [""] + Array(lines.prefix(count)) + [""]
        for (offset, line) in panel.enumerated() where start + offset < height - 1 {
            let styled = line.replacingOccurrences(of: Theme.reset, with: "\u{1B}[0m" + Theme.charcoalRaised.bg + Theme.cream.fg)
            screen[start + offset] = String(repeating: " ", count: left)
                + Theme.charcoalRaised.bg + "  " + fit(styled, limit: panelWidth)
                + String(repeating: " ", count: max(0, panelWidth - visibleWidth(line) + 2)) + Theme.reset
        }
    }

    private func centered(_ text: String, cells: Int) -> String {
        String(repeating: " ", count: max(0, (width - cells) / 2)) + text
    }

    private func paddedPanel(_ text: String, cells: Int) -> String {
        let clipped = fit(text, limit: cells)
        return clipped + Theme.charcoalRaised.bg + String(repeating: " ", count: max(0, cells - visibleWidth(clipped))) + Theme.reset
    }

    private func render(_ message: Message) -> [String] {
        let text = clean(message.text)
        switch message.role {
        case .user:
            return [Theme.dim.fg + "你"] + TextWidth.wrap(text, width: contentWidth).map { Theme.cream.fg + $0 }
        case .assistant:
            return [Theme.fox.fg + "灵犀"] + markdownLines(text, width: contentWidth, streaming: message.streaming)
        case .tool:
            return TextWidth.wrap("· " + text, width: contentWidth).map { Theme.dim.fg + $0 }
        case .system, .error:
            return TextWidth.wrap(text, width: contentWidth).map { (message.role == .error ? Theme.error.fg : Theme.dim.fg) + $0 }
        }
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

    private func renderInput(_ input: [Character], cursor: Int, limit: Int) -> String {
        let index = min(max(0, cursor), input.count)
        var start = 0
        while start < index, TextWidth.width(String(input[start..<index])) >= limit { start += 1 }
        var text = ""
        for position in start..<input.count {
            if position == index { text += "\u{1B}[7m" }
            text += String(input[position])
            if position == index { text += "\u{1B}[27m" }
        }
        if index == input.count { text += "\u{1B}[7m \u{1B}[27m" }
        return text
    }

    private func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.properties.generalCategory != .control || $0 == "\n" || $0 == "\t" })
            .replacingOccurrences(of: "\t", with: "  ")
    }

    private func visibleWidth(_ text: String) -> Int {
        TextWidth.width(text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression))
    }

    /// Only our SGR styling is preserved; cell width is measured by grapheme, never byte count.
    private func fit(_ text: String, limit: Int) -> String {
        var output = ""
        var cells = 0
        var escape = false
        for character in text {
            if character == "\u{1B}" { escape = true }
            if escape {
                output.append(character)
                if character == "m" { escape = false }
                continue
            }
            let count = TextWidth.width(String(character))
            guard cells + count <= max(0, limit) else { break }
            output.append(character)
            cells += count
        }
        return output
    }
}
