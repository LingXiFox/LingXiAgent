import Foundation

/// 跨终端统一 CLI 排版与视觉美化工具。
/// 提供基于 Unicode 字符的现代表格、信息卡片、自适应对齐与 CJK/Emoji 宽字符支持。
public enum CLIFormatter {

    public enum Alignment: Sendable {
        case left
        case right
        case center
    }

    public enum BorderStyle: Sendable {
        case rounded
        case sharp
        case double

        var topLeft: String {
            switch self {
            case .rounded: return "╭"
            case .sharp: return "┌"
            case .double: return "╔"
            }
        }

        var topRight: String {
            switch self {
            case .rounded: return "╮"
            case .sharp: return "┐"
            case .double: return "╗"
            }
        }

        var bottomLeft: String {
            switch self {
            case .rounded: return "╰"
            case .sharp: return "└"
            case .double: return "╚"
            }
        }

        var bottomRight: String {
            switch self {
            case .rounded: return "╯"
            case .sharp: return "┘"
            case .double: return "╝"
            }
        }

        var horizontal: String {
            switch self {
            case .double: return "═"
            default: return "─"
            }
        }

        var vertical: String {
            switch self {
            case .double: return "║"
            default: return "│"
            }
        }

        var topTee: String {
            switch self {
            case .double: return "╦"
            default: return "┬"
            }
        }

        var bottomTee: String {
            switch self {
            case .double: return "╩"
            default: return "┴"
            }
        }

        var leftTee: String {
            switch self {
            case .double: return "╠"
            default: return "├"
            }
        }

        var rightTee: String {
            switch self {
            case .double: return "╣"
            default: return "┤"
            }
        }

        var cross: String {
            switch self {
            case .double: return "╬"
            default: return "┼"
            }
        }
    }

    // MARK: - Width & Padding

    /// 计算去除 ANSI 转义字符后，在终端中的实际显示宽度（支持 CJK 与 Emoji）
    public static func displayWidth(_ text: String) -> Int {
        let stripped = text.replacingOccurrences(of: #"\u{001B}\[[0-9;]*[a-zA-Z]"#, with: "", options: .regularExpression)
        var width = 0
        for scalar in stripped.unicodeScalars {
            let val = scalar.value
            if (0x0300...0x036F).contains(val) || (0x200B...0x200D).contains(val) || val == 0xFEFF {
                continue
            }
            if (0x1100...0x115F).contains(val) ||
               (0x2E80...0xA4CF).contains(val) ||
               (0xAC00...0xD7A3).contains(val) ||
               (0xF900...0xFAFF).contains(val) ||
               (0xFE10...0xFE19).contains(val) ||
               (0xFE30...0xFE6F).contains(val) ||
               (0xFF00...0xFF60).contains(val) ||
               (0xFFE0...0xFFE6).contains(val) ||
               (0x1F000...0x1FFFF).contains(val) ||
               (0x20000...0x2FA1F).contains(val) ||
               val == 0x26A1 || val == 0x26A0 || val == 0x2615 ||
               val == 0x267F || val == 0x26BD || val == 0x26BE ||
               val == 0x26C4 || val == 0x26C5 || val == 0x26D4 ||
               val == 0x2705 || val == 0x274C || val == 0x2728 ||
               val == 0x274E || val == 0x2753 || val == 0x2757 ||
               val == 0x2B50 || val == 0x2B55 {
                width += 2
            } else {
                width += 1
            }
        }
        return width
    }

    /// 根据终端视觉显示宽度进行对齐填充
    public static func pad(_ text: String, toWidth targetWidth: Int, alignment: Alignment = .left) -> String {
        let current = displayWidth(text)
        let diff = max(0, targetWidth - current)
        switch alignment {
        case .left:
            return text + String(repeating: " ", count: diff)
        case .right:
            return String(repeating: " ", count: diff) + text
        case .center:
            let leftPad = diff / 2
            let rightPad = diff - leftPad
            return String(repeating: " ", count: leftPad) + text + String(repeating: " ", count: rightPad)
        }
    }

    // MARK: - Table Rendering

    /// 渲染具有专业排版的 Unicode 终端表格
    public static func renderTable(
        headers: [String],
        rows: [[String]],
        minColumnWidths: [Int]? = nil,
        alignments: [Alignment]? = nil,
        borderStyle: BorderStyle = .sharp
    ) -> String {
        guard !headers.isEmpty else { return "" }
        let colCount = headers.count

        let widths = (0..<colCount).map { col in
            var w = displayWidth(headers[col])
            for row in rows where col < row.count {
                w = max(w, displayWidth(row[col]))
            }
            if let mins = minColumnWidths, col < mins.count {
                w = max(w, mins[col])
            }
            return w
        }

        let alignList = alignments ?? Array(repeating: .left, count: colCount)

        var lines: [String] = []
        let topBorder = borderStyle.topLeft + widths.map { String(repeating: borderStyle.horizontal, count: $0 + 2) }.joined(separator: borderStyle.topTee) + borderStyle.topRight
        lines.append(topBorder)

        let headerCells = (0..<colCount).map { col in
            " " + pad(headers[col], toWidth: widths[col], alignment: alignList[col]) + " "
        }
        lines.append(borderStyle.vertical + headerCells.joined(separator: borderStyle.vertical) + borderStyle.vertical)

        let midBorder = borderStyle.leftTee + widths.map { String(repeating: borderStyle.horizontal, count: $0 + 2) }.joined(separator: borderStyle.cross) + borderStyle.rightTee
        lines.append(midBorder)

        for row in rows {
            let cells = (0..<colCount).map { col in
                let cellText = col < row.count ? row[col] : ""
                return " " + pad(cellText, toWidth: widths[col], alignment: alignList[col]) + " "
            }
            lines.append(borderStyle.vertical + cells.joined(separator: borderStyle.vertical) + borderStyle.vertical)
        }

        let bottomBorder = borderStyle.bottomLeft + widths.map { String(repeating: borderStyle.horizontal, count: $0 + 2) }.joined(separator: borderStyle.bottomTee) + borderStyle.bottomRight
        lines.append(bottomBorder)

        return lines.joined(separator: "\n")
    }

    // MARK: - Card Rendering

    /// 渲染信息卡片（带标题、键值对及子区块列表）
    public static func renderCard(
        title: String,
        fields: [(label: String, value: String)] = [],
        sections: [(title: String, lines: [String])] = [],
        footer: String? = nil,
        borderStyle: BorderStyle = .rounded,
        minWidth: Int = 68
    ) -> String {
        var contentWidth = max(minWidth, displayWidth(title) + 6)
        for field in fields {
            let fieldWidth = displayWidth(field.label) + 2 + displayWidth(field.value) + 2
            contentWidth = max(contentWidth, fieldWidth)
        }
        for section in sections {
            contentWidth = max(contentWidth, displayWidth(section.title) + 6)
            for line in section.lines {
                contentWidth = max(contentWidth, displayWidth(line) + 4)
            }
        }
        if let footer {
            contentWidth = max(contentWidth, displayWidth(footer) + 4)
        }

        let innerWidth = contentWidth
        var lines: [String] = []

        let titleHead = borderStyle.horizontal + " " + title + " "
        let titleHeadWidth = displayWidth(titleHead)
        let remainTop = max(0, innerWidth + 2 - titleHeadWidth)
        lines.append(borderStyle.topLeft + titleHead + String(repeating: borderStyle.horizontal, count: remainTop) + borderStyle.topRight)

        if !fields.isEmpty {
            let maxLabelWidth = fields.map { displayWidth($0.label) }.max() ?? 0
            for field in fields {
                let paddedLabel = pad(field.label + ":", toWidth: maxLabelWidth + 2, alignment: .left)
                let rowContent = paddedLabel + field.value
                let paddedRow = pad(rowContent, toWidth: innerWidth, alignment: .left)
                lines.append(borderStyle.vertical + " " + paddedRow + " " + borderStyle.vertical)
            }
        }

        for section in sections {
            let sectionHead = borderStyle.horizontal + " " + section.title + " "
            let headWidth = displayWidth(sectionHead)
            let remain = max(0, innerWidth + 2 - headWidth)
            lines.append(borderStyle.leftTee + sectionHead + String(repeating: borderStyle.horizontal, count: remain) + borderStyle.rightTee)

            for item in section.lines {
                let paddedItem = pad(item, toWidth: innerWidth, alignment: .left)
                lines.append(borderStyle.vertical + " " + paddedItem + " " + borderStyle.vertical)
            }
        }

        if let footer {
            let div = borderStyle.leftTee + String(repeating: borderStyle.horizontal, count: innerWidth + 2) + borderStyle.rightTee
            lines.append(div)
            let paddedFooter = pad(footer, toWidth: innerWidth, alignment: .left)
            lines.append(borderStyle.vertical + " " + paddedFooter + " " + borderStyle.vertical)
        }

        lines.append(borderStyle.bottomLeft + String(repeating: borderStyle.horizontal, count: innerWidth + 2) + borderStyle.bottomRight)

        return lines.joined(separator: "\n")
    }

    // MARK: - Tree Node

    /// 渲染层次化树状输出（如操作成功状态）
    public static func renderTree(header: String, items: [(label: String, value: String)]) -> String {
        var lines: [String] = []
        lines.append(header)
        for (index, item) in items.enumerated() {
            let isLast = index == items.count - 1
            let branch = isLast ? "  └─ " : "  ├─ "
            let labelPad = pad(item.label + ":", toWidth: 12, alignment: .left)
            lines.append(branch + labelPad + item.value)
        }
        return lines.joined(separator: "\n")
    }
}
