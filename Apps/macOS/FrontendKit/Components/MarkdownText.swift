#if canImport(SwiftUI)
import SwiftUI

// MARK: - Markdown text
//
// Assistant prose used to go through `AttributedString(markdown:)` with
// `.inlineOnlyPreservingWhitespace`. That flag is the whole problem it was named for: it
// parses emphasis and inline code and nothing else, so every heading, list item, quote,
// table and `---` a model emitted arrived at the screen as its own source text. Bold worked,
// structure did not, and a model answer that is mostly structure — which is what a coding
// agent produces — read as a wall of punctuation.
//
// So blocks are parsed here and each one becomes a real view. This is deliberately a
// line-oriented subset rather than a CommonMark implementation: it handles exactly what
// models emit (fences, headings, lists including task lists, quotes, tables, breaks,
// paragraphs) and inline emphasis is still delegated to Foundation per block. Adding
// swift-markdown would mean a new dependency to render a subset this file already covers.

/// One block of a Markdown document.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, body: String)
    case bullets(items: [MarkdownListItem])
    case ordered(items: [MarkdownListItem])
    case quote(lines: [String])
    case table(header: [String], alignment: [MarkdownColumnAlignment], rows: [[String]])
    case thematicBreak

    /// A list item with its inline text and how deep it was indented. Nesting is rendered as
    /// indentation, not as a recursive view: the models here rarely go past two levels and a
    /// flat list keeps the row spacing uniform.
    struct MarkdownListItem: Equatable {
        let indent: Int
        let checked: Bool?
        let text: String
    }
}

enum MarkdownColumnAlignment: Equatable {
    case leading, center, trailing
}

enum Markdown {
    private static let fenceMarkers = ["```", "~~~"]

    /// Splits a document into blocks. Blank lines end a paragraph; anything that is not
    /// recognised as block syntax is paragraph text, which is also what makes unmarked
    /// model output survive untouched.
    static func blocks(_ source: String) -> [MarkdownBlock] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if fenceMarkers.contains(where: { trimmed.hasPrefix($0) }) {
                flushParagraph()
                let marker = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(marker),
                       candidate.trimmingCharacters(in: .whitespaces).count == marker.count {
                        index += 1
                        break
                    }
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language,
                                    body: body.joined(separator: "\n")))
                continue
            }

            if let level = headingLevel(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: level, text: headingBody(trimmed, level: level)))
                index += 1
                continue
            }

            if isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var body = String(candidate.dropFirst())
                    if body.hasPrefix(" ") { body.removeFirst() }
                    quoted.append(body)
                    index += 1
                }
                blocks.append(.quote(lines: quoted))
                continue
            }

            if looksLikeTable(lines, at: index) {
                flushParagraph()
                let parsed = parseTable(lines, from: index)
                blocks.append(parsed.block)
                index = parsed.nextIndex
                continue
            }

            if listMarker(of: trimmed) != nil {
                flushParagraph()
                let ordered = trimmed.first?.isNumber ?? false
                var items: [MarkdownBlock.MarkdownListItem] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.isEmpty { break }
                    guard listMarker(of: candidate) != nil else {
                        // A continuation line belongs to the previous item.
                        if var last = items.popLast() {
                            last = .init(indent: last.indent, checked: last.checked,
                                         text: last.text + " " + candidate)
                            items.append(last)
                        }
                        index += 1
                        continue
                    }
                    items.append(listItem(raw: candidate, indentOf: lines[index]))
                    index += 1
                }
                blocks.append(ordered ? .ordered(items: items) : .bullets(items: items))
                continue
            }

            paragraph.append(raw)
            index += 1
        }
        flushParagraph()
        // An unterminated fence is what a streamed answer looks like mid-token; keep showing
        // what arrived as code rather than dumping its backticks into the prose.
        return blocks
    }

    /// Inline Markdown (bold, italics, `code`, links) with whitespace preserved.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        // Strip the escapes Markdown uses for characters a model means literally.
        guard var attributed = try? AttributedString(markdown: clean(text), options: options) else {
            return AttributedString(clean(text))
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(size: 14, design: .monospaced)
            attributed[run.range].backgroundColor = LXColor.fillQuinary
        }
        return attributed
    }

    /// Collapses the two hard-break spellings so `Text` wraps them as one paragraph.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: Line tests

    private static func headingLevel(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard hashes <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes)
        return rest.isEmpty || rest.hasPrefix(" ") ? hashes : nil
    }

    private static func headingBody(_ trimmed: String, level: Int) -> String {
        var body = String(trimmed.dropFirst(level))
        while body.hasPrefix(" ") { body.removeFirst() }
        while body.hasSuffix("#") { body.removeLast() }
        return body.trimmingCharacters(in: .whitespaces)
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return Set(stripped).count == 1 && ["-", "*", "_"].contains(String(stripped.first!))
    }

    /// `true` for `1. x`, `false` for `- x`, `nil` when the line is not a list item. The
    /// marker must be followed by a space, or `--foo` and `2024.plan` become lists.
    private static func listMarker(of trimmed: String) -> Bool? {
        if let first = trimmed.first, "-*+".contains(first) {
            return trimmed.count > 1 && trimmed.dropFirst().first == " " ? false : nil
        }
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, trimmed.count > digits.count else { return nil }
        let after = trimmed[digits.endIndex...]
        guard after.first == "." || after.first == ")" else { return nil }
        return after.dropFirst().first == " " ? true : nil
    }

    private static func listItem(raw trimmed: String, indentOf line: String) -> MarkdownBlock.MarkdownListItem {
        let indent = line.prefix(while: { $0 == " " }).count / 2
        var body = trimmed
        if let first = body.first, "-*+".contains(first) {
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else {
            body = String(body.drop(while: { $0.isNumber }))
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        var checked: Bool?
        if body.hasPrefix("[ ]") { checked = false; body = String(body.dropFirst(3)) }
        else if body.hasPrefix("[x]") || body.hasPrefix("[X]") { checked = true; body = String(body.dropFirst(3)) }
        return .init(indent: min(indent, 3), checked: checked,
                     text: body.trimmingCharacters(in: .whitespaces))
    }

    private static func looksLikeTable(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|") else { return false }
        let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard separator.contains("-"), separator.contains("|") else { return false }
        return separator.replacingOccurrences(of: " ", with: "")
            .allSatisfy { "-|: ".contains($0) }
    }

    private static func parseTable(_ lines: [String], from index: Int)
        -> (block: MarkdownBlock, nextIndex: Int) {
        func cells(_ line: String) -> [String] {
            var parts = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|")
            parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }
            return parts
        }
        let header = cells(lines[index])
        let alignment = cells(lines[index + 1]).map { cell -> MarkdownColumnAlignment in
            if cell.hasPrefix(":") && cell.hasSuffix(":") { return .center }
            if cell.hasSuffix(":") { return .trailing }
            return .leading
        }
        var rows: [[String]] = []
        var next = index + 2
        while next < lines.count {
            let candidate = lines[next].trimmingCharacters(in: .whitespaces)
            guard candidate.contains("|"), !candidate.isEmpty else { break }
            rows.append(cells(candidate))
            next += 1
        }
        return (.table(header: header, alignment: alignment, rows: rows), next)
    }
}

// MARK: View

/// Renders a Markdown document as blocks.
struct MarkdownText: View {
    let source: String
    /// Type ramp for prose. Messages use `message`; denser surfaces pass `callout`.
    var prose: Font = LXType.message
    var leading: CGFloat = LXType.Leading.message
    /// Non-nil to pull the prose off primary — reasoning bodies read as secondary text.
    var tone: Color? = nil

    var body: some View {
        MarkdownBlocksView(blocks: Markdown.blocks(source), base: prose, leading: leading, tone: tone)
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let base: Font
    let leading: CGFloat
    let tone: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, base: base, leading: leading, tone: tone)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let base: Font
    let leading: CGFloat
    let tone: Color?

    private var foreground: AnyShapeStyle { tone.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary) }

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(Markdown.inline(text))
                .font(base)
                .lineSpacing(leading)
                .foregroundStyle(foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(Markdown.inline(text))
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code):
            MarkdownCodeBlock(language: language, code: code)
        case .bullets(let items):
            MarkdownListView(items: items, ordered: false, base: base, leading: leading, tone: tone)
        case .ordered(let items):
            MarkdownListView(items: items, ordered: true, base: base, leading: leading, tone: tone)
        case .quote(let lines):
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(Markdown.inline(line))
                        .font(base)
                        .lineSpacing(leading)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, LingXiMetrics.Space.md)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(LXColor.separator)
                    .frame(width: 3)
            }
        case .table(let header, let alignment, let rows):
            MarkdownTableView(header: header, alignment: alignment, rows: rows)
        case .thematicBreak:
            LXHairline()
                .padding(.vertical, LingXiMetrics.Space.xs)
        }
    }

    /// `#`..`###` all get visible weight and size steps; `####` and deeper stop growing and
    /// lose colour instead, so a model that heads everything still reads as an outline.
    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return LXType.title
        case 2: return Font.system(size: 18, weight: .semibold)
        case 3: return LXType.headline
        default: return LXType.callout
        }
    }
}

/// A fenced block with the language the fence named.
///
/// The info string used to be dropped on the floor, so `swift` and `json` produced identical
/// blocks and there was no way to tell a 40-line snippet from 40 lines of command output.
private struct MarkdownCodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                Text(language)
                    .font(LXType.micro)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, LingXiMetrics.Space.md)
                    .padding(.top, 6)
            }
            OutputBlock(text: code)
                .padding(0)
        }
    }
}

private struct MarkdownListView: View {
    let items: [MarkdownBlock.MarkdownListItem]
    let ordered: Bool
    let base: Font
    let leading: CGFloat
    let tone: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                HStack(alignment: .firstTextBaseline, spacing: LingXiMetrics.Space.xs) {
                    marker(item, at: position)
                        .frame(width: 18, alignment: .trailing)
                    Text(Markdown.inline(item.text))
                        .font(base)
                        .lineSpacing(leading)
                        .foregroundStyle(item.checked == true ? AnyShapeStyle(.secondary)
                                         : (tone.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary)))
                        .strikethrough(item.checked == true)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(item.indent) * LingXiMetrics.Space.lg)
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: MarkdownBlock.MarkdownListItem, at position: Int) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(checked ? AnyShapeStyle(LXColor.success) : AnyShapeStyle(.secondary))
                .accessibilityLabel(checked ? "已完成" : "未完成")
        } else if ordered {
            Text("\(position + 1).")
                .font(base)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            Image(systemName: "circle.fill")
                .font(.system(size: item.indent > 0 ? 4 : 5))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

private struct MarkdownTableView: View {
    let header: [String]
    let alignment: [MarkdownColumnAlignment]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading,
                 horizontalSpacing: LingXiMetrics.Space.md,
                 verticalSpacing: LingXiMetrics.Space.xs) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        Text(Markdown.inline(cell))
                            .font(LXType.callout)
                            .gridColumnAlignment(grid(column))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { column, _ in
                            Text(Markdown.inline(column < row.count ? row[column] : ""))
                                .font(LXType.meta)
                                .textSelection(.enabled)
                                .gridColumnAlignment(grid(column))
                        }
                    }
                }
            }
            .padding(LingXiMetrics.Space.md)
        }
        .background(LXColor.fillQuinary,
                    in: RoundedRectangle(cornerRadius: LingXiMetrics.Radius.inset, style: .continuous))
    }

    private func grid(_ column: Int) -> HorizontalAlignment {
        switch column < alignment.count ? alignment[column] : .leading {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
#endif
