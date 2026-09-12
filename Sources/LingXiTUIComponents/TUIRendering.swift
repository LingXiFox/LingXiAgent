import Foundation
import LingXiProtocol

public struct TUISize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct TUIPoint: Equatable, Sendable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public struct TUIRect: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(from p1: TUIPoint, to p2: TUIPoint) {
        let minX = min(p1.x, p2.x)
        let minY = min(p1.y, p2.y)
        let w = abs(p1.x - p2.x) + 1
        let h = abs(p1.y - p2.y) + 1
        self.init(x: minX, y: minY, width: w, height: h)
    }
}

public struct TUILayout: Equatable, Sendable {
    public let header: TUIRect
    public let transcript: TUIRect
    public let sidebar: TUIRect?
    public let divider: TUIRect?
    public let bottomPane: TUIRect
    public let status: TUIRect

    public init(size: TUISize, headerHeight: Int, bottomHeight: Int, hasSidebar: Bool = false) {
        let safeHeader = min(max(0, headerHeight), size.height)
        let safeStatus = size.height > 0 ? 1 : 0
        let safeBottom = min(max(0, bottomHeight), max(0, size.height - safeHeader - safeStatus))
        let mainHeight = max(0, size.height - safeHeader - safeBottom - safeStatus)
        header = TUIRect(x: 0, y: 0, width: size.width, height: safeHeader)
        status = TUIRect(x: 0, y: max(0, size.height - safeStatus), width: size.width, height: safeStatus)
        bottomPane = TUIRect(x: 0, y: safeHeader + mainHeight, width: size.width, height: safeBottom)

        if hasSidebar && size.width >= 80 {
            let sidebarWidth = min(36, max(26, size.width / 4))
            let transcriptWidth = max(20, size.width - sidebarWidth - 1)
            transcript = TUIRect(x: 0, y: safeHeader, width: transcriptWidth, height: mainHeight)
            divider = TUIRect(x: transcriptWidth, y: safeHeader, width: 1, height: mainHeight)
            sidebar = TUIRect(x: transcriptWidth + 1, y: safeHeader, width: sidebarWidth, height: mainHeight)
        } else {
            transcript = TUIRect(x: 0, y: safeHeader, width: size.width, height: mainHeight)
            divider = nil
            sidebar = nil
        }
    }
}

public enum TUIStyle: Equatable, Sendable {
    case normal
    case dim
    case accent
    case inverse
    case composer
    case composerText
    case composerPlaceholder
    case overlay
    case overlayTitle
    case overlayItem
    case overlayItemDim
    case overlayHighlight
    case warning
    case error
    case modalTitle
    case modalGroup
    case modalHighlight
    case modalActiveDot
    case modalItem
    case modalItemDim
    case modalBackground
    case modalBorder
    case modalSearchPlaceholder
    case selected
    case heroLogo
    case heroBoxBorder
    case heroBoxBg
    case heroBoxPlaceholder
    case heroBoxText
    case heroBoxMeta
    case heroMode
    case heroTip
    case sidebarHeader
    case sidebarLabel
    case sidebarProgressFill
    case sidebarProgressTrack
    case sidebarTaskPending
    case sidebarTaskInProgress
    case sidebarTaskCompleted
    case sidebarTaskFailed
    case sidebarMcpReady
    case sidebarMcpAuth
    case sidebarMcpError
    case toolDotSuccess
    case toolDotActive
    case toolDotError
    case toolAction
    case toolCommand
    case toolArg
    case toolTree
    case toolSubtext
    case toolDiffAdd
    case toolDiffRemove
    case toolDiffLine
    case thinkingHeader
    case thinkingBody
    case assistantText
    case badgeYolo
    case badgeAsk
    case mascotBody
    case mascotEar
    case mascotSpark
    case mascotTag
}

public struct TUIRGB: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

public struct TUIStyleCell: Equatable, Sendable {
    public var character: Character
    public var style: TUIStyle
    public var continuation: Bool
    public var customForeground: TUIRGB?
    public var customBackground: TUIRGB?

    public init(
        character: Character = " ",
        style: TUIStyle = .normal,
        continuation: Bool = false,
        customForeground: TUIRGB? = nil,
        customBackground: TUIRGB? = nil
    ) {
        self.character = character
        self.style = style
        self.continuation = continuation
        self.customForeground = customForeground
        self.customBackground = customBackground
    }
}

public struct TUIFrame: Sendable {
    public let size: TUISize
    public var cells: [TUIStyleCell]
    public var cursor: TUIPoint?

    public init(size: TUISize) {
        self.size = size
        cells = Array(repeating: TUIStyleCell(), count: max(0, size.width * size.height))
    }

    public mutating func clear(style: TUIStyle = .normal) {
        cells = Array(repeating: TUIStyleCell(style: style), count: cells.count)
        cursor = nil
    }

    public mutating func drawBitmap(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        pixels: [(top: TUIRGB, bottom: TUIRGB)]
    ) {
        for row in 0..<height {
            for col in 0..<width {
                let cellX = x + col
                let cellY = y + row
                guard cellX >= 0, cellX < size.width, cellY >= 0, cellY < size.height else { continue }
                let idx = row * width + col
                guard idx < pixels.count else { continue }
                let pair = pixels[idx]
                let cellIdx = cellY * size.width + cellX
                cells[cellIdx] = TUIStyleCell(
                    character: "▀",
                    style: .normal,
                    continuation: false,
                    customForeground: pair.top,
                    customBackground: pair.bottom
                )
            }
        }
    }

    public mutating func fill(_ rect: TUIRect, style: TUIStyle) {
        let left = max(0, rect.x)
        let top = max(0, rect.y)
        let right = min(size.width, rect.x + rect.width)
        let bottom = min(size.height, rect.y + rect.height)
        guard left < right, top < bottom else { return }
        for y in top..<bottom {
            for x in left..<right { put(" ", at: TUIPoint(x: x, y: y), style: style) }
        }
    }

    public mutating func stroke(_ rect: TUIRect, style: TUIStyle) {
        strokeBox(rect, style: style, rounded: true)
    }

    public mutating func strokeBox(_ rect: TUIRect, style: TUIStyle, rounded: Bool = true) {
        guard rect.width > 1, rect.height > 1 else { return }
        let right = rect.x + rect.width - 1
        let bottom = rect.y + rect.height - 1
        let topLeft: Character = rounded ? "╭" : "┌"
        let topRight: Character = rounded ? "╮" : "┐"
        let bottomLeft: Character = rounded ? "╰" : "└"
        let bottomRight: Character = rounded ? "╯" : "┘"

        put(topLeft, at: TUIPoint(x: rect.x, y: rect.y), style: style)
        put(topRight, at: TUIPoint(x: right, y: rect.y), style: style)
        put(bottomLeft, at: TUIPoint(x: rect.x, y: bottom), style: style)
        put(bottomRight, at: TUIPoint(x: right, y: bottom), style: style)

        if right > rect.x + 1 {
            for x in (rect.x + 1)..<right {
                put("─", at: TUIPoint(x: x, y: rect.y), style: style)
                put("─", at: TUIPoint(x: x, y: bottom), style: style)
            }
        }
        if bottom > rect.y + 1 {
            for y in (rect.y + 1)..<bottom {
                put("│", at: TUIPoint(x: rect.x, y: y), style: style)
                put("│", at: TUIPoint(x: right, y: y), style: style)
            }
        }
    }

    public mutating func put(_ character: Character, at point: TUIPoint, style: TUIStyle = .normal) {
        guard point.x >= 0, point.x < size.width, point.y >= 0, point.y < size.height else { return }
        let index = point.y * size.width + point.x
        cells[index] = TUIStyleCell(character: character, style: style)
    }

    public mutating func write(_ text: String, at point: TUIPoint, maxWidth: Int? = nil, style: TUIStyle = .normal) {
        var x = point.x
        let limit = maxWidth.map { point.x + max(0, $0) } ?? size.width
        for character in text {
            let width = TUIDisplayWidth.width(of: character)
            guard width > 0 else { continue }
            guard x < limit, x < size.width, point.y >= 0, point.y < size.height else { break }
            if width == 2, x + 1 >= limit || x + 1 >= size.width { break }
            put(character, at: TUIPoint(x: x, y: point.y), style: style)
            if width == 2 {
                put(" ", at: TUIPoint(x: x + 1, y: point.y), style: style)
                cells[point.y * size.width + x + 1].continuation = true
            }
            x += width
        }
    }

    public mutating func writeLines(_ lines: [TUIStyledLine], at point: TUIPoint, maxWidth: Int? = nil, maxHeight: Int? = nil) {
        for (offset, line) in lines.enumerated() {
            if let maxHeight, offset >= maxHeight { break }
            let y = point.y + offset
            guard y >= 0, y < size.height else { continue }
            if let spans = line.spans, !spans.isEmpty {
                var curX = point.x
                let limit = maxWidth.map { point.x + max(0, $0) } ?? size.width
                for span in spans {
                    guard curX < limit else { break }
                    let spanLimit = limit - curX
                    write(span.text, at: TUIPoint(x: curX, y: y), maxWidth: spanLimit, style: span.style)
                    curX += TUIDisplayWidth.width(of: span.text)
                }
            } else {
                write(line.text, at: TUIPoint(x: point.x, y: y), maxWidth: maxWidth, style: line.style)
            }
        }
    }

    public mutating func highlightSelection(_ rect: TUIRect) {
        let minY = max(0, rect.y)
        let maxY = min(size.height - 1, rect.y + rect.height - 1)
        let minX = max(0, rect.x)
        let maxX = min(size.width - 1, rect.x + rect.width - 1)
        guard minY <= maxY, minX <= maxX else { return }
        for y in minY...maxY {
            for x in minX...maxX {
                let idx = y * size.width + x
                cells[idx].style = .selected
            }
        }
    }

    public func text(in rect: TUIRect) -> String {
        let minY = max(0, rect.y)
        let maxY = min(size.height - 1, rect.y + rect.height - 1)
        let minX = max(0, rect.x)
        let maxX = min(size.width - 1, rect.x + rect.width - 1)
        guard minY <= maxY, minX <= maxX else { return "" }
        var rows: [String] = []
        for y in minY...maxY {
            var rowChars: [Character] = []
            for x in minX...maxX {
                let cell = cells[y * size.width + x]
                if !cell.continuation {
                    rowChars.append(cell.character)
                }
            }
            let line = String(rowChars).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            rows.append(line)
        }
        while let last = rows.last, last.isEmpty {
            rows.removeLast()
        }
        return rows.joined(separator: "\n")
    }
}

public struct TUIStyledSpan: Sendable, Equatable {
    public let text: String
    public let style: TUIStyle

    public init(_ text: String, style: TUIStyle = .normal) {
        self.text = text
        self.style = style
    }
}

public struct TUIStyledLine: Sendable, Equatable {
    public let text: String
    public let style: TUIStyle
    public let spans: [TUIStyledSpan]?

    public init(_ text: String, style: TUIStyle = .normal, spans: [TUIStyledSpan]? = nil) {
        self.text = text
        self.style = style
        self.spans = spans
    }
}

public enum TUIDisplayWidth {
    public static func width(of character: Character) -> Int {
        character.unicodeScalars.reduce(0) { result, scalar in
            result + width(of: scalar)
        }
    }

    public static func width(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value == 0 || value < 0x20 || (0x7F...0x9F).contains(value) ||
            (0x0300...0x036F).contains(value) || (0x1AB0...0x1AFF).contains(value) ||
            (0x1DC0...0x1DFF).contains(value) || (0x20D0...0x20FF).contains(value) ||
            (0xFE00...0xFE0F).contains(value) || (0xE0100...0xE01EF).contains(value) {
            return 0
        }
        if (0x1100...0x115F).contains(value) || (0x2329...0x232A).contains(value) ||
            (0x2E80...0xA4CF).contains(value) || (0xAC00...0xD7A3).contains(value) ||
            (0xF900...0xFAFF).contains(value) || (0xFE10...0xFE19).contains(value) ||
            (0xFE30...0xFE6F).contains(value) || (0xFF00...0xFF60).contains(value) ||
            (0xFFE0...0xFFE6).contains(value) || (0x1F300...0x1FAFF).contains(value) {
            return 2
        }
        return 1
    }

    public static func width(of text: String) -> Int {
        text.reduce(0) { $0 + width(of: $1) }
    }
}

public struct TUIWrappedLine: Sendable {
    public let text: String
    public let cursorColumn: Int?
    public let startIndex: Int
    public let endIndex: Int

    public init(text: String, cursorColumn: Int? = nil, startIndex: Int = 0, endIndex: Int = 0) {
        self.text = text
        self.cursorColumn = cursorColumn
        self.startIndex = startIndex
        self.endIndex = endIndex
    }
}

public enum TUIWrapping {
    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        let val = scalar.value
        return (0x4E00...0x9FFF).contains(val)
            || (0x3400...0x4DBF).contains(val)
            || (0x20000...0x2A6DF).contains(val)
            || (0xF900...0xFAFF).contains(val)
            || (0x3000...0x303F).contains(val)
            || (0xFF00...0xFFEF).contains(val)
    }

    public static func lines(_ text: String, width: Int, cursor: Int? = nil) -> [TUIWrappedLine] {
        let limit = max(1, width)
        let characters = Array(text)
        var result: [TUIWrappedLine] = []
        var current: [Character] = []
        var currentWidth = 0
        var cursorLine: Int?
        var cursorColumn: Int?
        var cursorIndex = 0
        var lineStartIndex = 0
        var lastSpaceInCurrent: Int? = nil
        var lastSpaceOrigIndex: Int? = nil

        func flush(lineEndIndex: Int) {
            result.append(TUIWrappedLine(text: String(current), cursorColumn: nil, startIndex: lineStartIndex, endIndex: lineEndIndex))
            current.removeAll(keepingCapacity: true)
            currentWidth = 0
            lineStartIndex = lineEndIndex
            lastSpaceInCurrent = nil
            lastSpaceOrigIndex = nil
        }

        for (index, character) in characters.enumerated() {
            if character == "\n" {
                if cursor == index { cursorLine = result.count; cursorColumn = currentWidth }
                flush(lineEndIndex: index)
                cursorIndex = index + 1
                lineStartIndex = index + 1
                continue
            }
            let characterWidth = max(1, TUIDisplayWidth.width(of: character))
            if currentWidth + characterWidth > limit, !current.isEmpty {
                // 只有当当前待加入字符为西文字符，且前面有西文单词边界时，才进行单词级回溯折行
                let shouldWordWrap: Bool = {
                    guard !isCJK(character), character != " " else { return false }
                    guard let spacePos = lastSpaceInCurrent, spacePos > 0, spacePos < current.count else { return false }
                    let wordChars = current[(spacePos + 1)...]
                    return !wordChars.isEmpty && wordChars.allSatisfy { !isCJK($0) && $0 != " " }
                }()

                if shouldWordWrap, let spacePos = lastSpaceInCurrent {
                    let wrappedCount = spacePos
                    let carriedChars = Array(current[(spacePos + 1)...])
                    let spaceEndIndex = lastSpaceOrigIndex ?? index

                    current = Array(current[0..<wrappedCount])
                    if let cursor, cursor >= cursorIndex, cursor <= spaceEndIndex {
                        cursorLine = result.count
                        var col = 0
                        for i in 0..<(cursor - cursorIndex) {
                            if i < current.count { col += max(1, TUIDisplayWidth.width(of: current[i])) }
                        }
                        cursorColumn = col
                    }
                    flush(lineEndIndex: spaceEndIndex + 1)
                    cursorIndex = spaceEndIndex + 1
                    lineStartIndex = spaceEndIndex + 1

                    current = carriedChars
                    currentWidth = carriedChars.reduce(0) { $0 + max(1, TUIDisplayWidth.width(of: $1)) }
                    lastSpaceInCurrent = nil
                    lastSpaceOrigIndex = nil
                } else {
                    if let cursor, cursor >= cursorIndex, cursor <= index { cursorLine = result.count; cursorColumn = currentWidth }
                    flush(lineEndIndex: index)
                    cursorIndex = index
                }
            }
            if character == " " {
                lastSpaceInCurrent = current.count
                lastSpaceOrigIndex = index
            }
            current.append(character)
            currentWidth += characterWidth
        }
        if let cursor, cursor >= cursorIndex { cursorLine = result.count; cursorColumn = currentWidth }
        result.append(TUIWrappedLine(text: String(current), cursorColumn: nil, startIndex: lineStartIndex, endIndex: characters.count))
        if let cursorLine, let cursorColumn, result.indices.contains(cursorLine) {
            let existing = result[cursorLine]
            result[cursorLine] = TUIWrappedLine(text: existing.text, cursorColumn: cursorColumn, startIndex: existing.startIndex, endIndex: existing.endIndex)
        }
        return result
    }
}

public final class ChatComposer {
    public private(set) var text = ""
    public private(set) var cursor = 0
    public private(set) var history: [String] = []
    private var historyIndex: Int?
    public var placeholder = "Message LingXiAgent"
    public var focused = true
    public var maxHeight = 6
    public var masksInput = false
    public private(set) var scrollLine = 0
    public var lastRenderWidth: Int = 78

    public var isEmpty: Bool { text.isEmpty }

    public func setText(_ value: String) {
        text = value
        cursor = Array(value).count
        historyIndex = nil
        normalize()
    }

    public func clear() {
        text.removeAll()
        cursor = 0
        historyIndex = nil
        scrollLine = 0
    }

    public func replaceRange(start: Int, end: Int, with value: String) {
        let characters = Array(text)
        let lower = min(max(0, start), characters.count)
        let upper = min(max(lower, end), characters.count)
        text = String(characters[..<lower]) + value + String(characters[upper...])
        cursor = lower + Array(value).count
        historyIndex = nil
        normalize()
    }

    public func handle(_ event: TUIInputEvent) -> ChatComposerAction {
        switch event {
        case let .character(character): insert(String(character)); return .changed
        case let .paste(value): insert(value); return .changed
        case .enter: return .submit
        case .shiftEnter: insert("\n"); return .changed
        case .backspace: deleteBackward(); return .changed
        case .delete: deleteForward(); return .changed
        case .left: moveLeft(); return .changed
        case .right: moveRight(); return .changed
        case .up:
            let contentWidth = max(10, lastRenderWidth - 4)
            let wrapped = TUIWrapping.lines(text, width: contentWidth, cursor: cursor)
            let currentLine = wrapped.firstIndex(where: { $0.cursorColumn != nil }) ?? 0
            if currentLine == 0 {
                if navigateHistory(direction: -1) { return .changed }
            }
            moveVertical(-1)
            return .changed
        case .down:
            let contentWidth = max(10, lastRenderWidth - 4)
            let wrapped = TUIWrapping.lines(text, width: contentWidth, cursor: cursor)
            let currentLine = wrapped.firstIndex(where: { $0.cursorColumn != nil }) ?? 0
            if currentLine >= max(0, wrapped.count - 1) {
                if navigateHistory(direction: 1) { return .changed }
            }
            moveVertical(1)
            return .changed
        case .home: moveHome(); return .changed
        case .end: moveEnd(); return .changed
        case .pageUp:
            scrollLine = max(0, scrollLine - maxHeight)
            return .changed
        case .pageDown:
            let contentWidth = max(10, lastRenderWidth - 4)
            let wrappedCount = TUIWrapping.lines(text, width: contentWidth).count
            let maxScroll = max(0, wrappedCount - maxHeight)
            scrollLine = min(maxScroll, scrollLine + maxHeight)
            return .changed
        case .scrollUp:
            scrollLine = max(0, scrollLine - 1)
            return .changed
        case .scrollDown:
            let contentWidth = max(10, lastRenderWidth - 4)
            let wrappedCount = TUIWrapping.lines(text, width: contentWidth).count
            let maxScroll = max(0, wrappedCount - maxHeight)
            scrollLine = min(maxScroll, scrollLine + 1)
            return .changed
        case .mouseClick, .mouseDown, .mouseDrag, .mouseUp, .escape, .interrupt, .quit, .resize, .tick, .tab, .shiftTab, .commandPalette, .cycleReasoningEffort: return .ignored
        case .deleteWordBackward: deleteWordBackward(); return .changed
        }
    }

    public func commitHistory() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if history.last != text { history.append(text) }
        historyIndex = nil
    }

    public func render(width: Int) -> (lines: [TUIStyledLine], cursor: TUIPoint?) {
        lastRenderWidth = width
        let prefix = text.first == "/" ? "> " : "  "
        let contentWidth = max(1, width - TUIDisplayWidth.width(of: prefix))
        let displayText = text.isEmpty && focused ? placeholder : (masksInput ? String(repeating: "•", count: text.count) : text)
        let cursorOffset = text.isEmpty ? 0 : cursor
        let wrapped = TUIWrapping.lines(displayText, width: contentWidth, cursor: text.isEmpty ? 0 : cursorOffset)
        let visibleHeight = min(maxHeight, max(1, wrapped.count))
        let maxScroll = max(0, wrapped.count - visibleHeight)

        if let absoluteLine = wrapped.firstIndex(where: { $0.cursorColumn != nil }) {
            if absoluteLine < scrollLine {
                scrollLine = absoluteLine
            } else if absoluteLine >= scrollLine + visibleHeight {
                scrollLine = absoluteLine - visibleHeight + 1
            }
        }
        scrollLine = max(0, min(scrollLine, maxScroll))

        let visible = Array(wrapped.dropFirst(scrollLine).prefix(visibleHeight))
        if text.isEmpty {
            return ([TUIStyledLine(prefix + displayText, style: .composerPlaceholder)], TUIPoint(x: TUIDisplayWidth.width(of: prefix), y: 0))
        }
        var lines = visible.map { TUIStyledLine(prefix + $0.text, style: .composerText) }
        var cursorPoint: TUIPoint?
        if let absoluteLine = wrapped.firstIndex(where: { $0.cursorColumn != nil }), let column = wrapped[absoluteLine].cursorColumn {
            let visibleLine = absoluteLine - scrollLine
            if visibleLine >= 0, visibleLine < lines.count { cursorPoint = TUIPoint(x: TUIDisplayWidth.width(of: prefix) + column, y: visibleLine) }
        }
        if lines.isEmpty { lines = [TUIStyledLine(prefix)] }
        return (lines, cursorPoint)
    }

    private func insert(_ value: String) {
        let characters = Array(text)
        let head = String(characters.prefix(cursor))
        let tail = String(characters.dropFirst(cursor))
        text = head + value + tail
        cursor += Array(value).count
        historyIndex = nil
        normalize()
    }

    private func navigateHistory(direction: Int) -> Bool {
        guard !history.isEmpty, !text.contains("\n") else { return false }
        if (direction < 0 && (cursor == 0 || historyIndex != nil)) || (direction > 0 && (cursor == Array(text).count || historyIndex != nil)) {
            let nextIndex: Int
            if let historyIndex {
                nextIndex = min(max(0, historyIndex + direction), history.count)
            } else {
                nextIndex = direction < 0 ? history.count - 1 : history.count
            }
            historyIndex = nextIndex
            text = nextIndex < history.count ? history[nextIndex] : ""
            cursor = Array(text).count
            normalize()
            return true
        }
        return false
    }

    private func deleteBackward() {
        guard cursor > 0 else { return }
        var characters = Array(text)
        characters.remove(at: cursor - 1)
        text = String(characters)
        cursor -= 1
        normalize()
    }

    private func deleteForward() {
        var characters = Array(text)
        guard cursor < characters.count else { return }
        characters.remove(at: cursor)
        text = String(characters)
        normalize()
    }

    private func deleteWordBackward() {
        var characters = Array(text)
        var index = cursor
        while index > 0, characters[index - 1].isWhitespace { index -= 1 }
        while index > 0, !characters[index - 1].isWhitespace { index -= 1 }
        characters.removeSubrange(index..<cursor)
        text = String(characters)
        cursor = index
        normalize()
    }

    private func moveLeft() { cursor = max(0, cursor - 1) }
    private func moveRight() { cursor = min(Array(text).count, cursor + 1) }
    private func moveHome() { cursor = lineStart() }
    private func moveEnd() { cursor = lineEnd() }

    private func moveVertical(_ direction: Int) {
        let characters = Array(text)
        guard !characters.isEmpty else { return }
        let contentWidth = max(10, lastRenderWidth - 4)
        let wrapped = TUIWrapping.lines(text, width: contentWidth, cursor: cursor)
        guard let currentLineIndex = wrapped.firstIndex(where: { $0.cursorColumn != nil }) else { return }
        let currentLine = wrapped[currentLineIndex]
        let currentColumn = cursor - currentLine.startIndex

        if direction < 0 {
            guard currentLineIndex > 0 else { return }
            let targetLine = wrapped[currentLineIndex - 1]
            cursor = min(targetLine.startIndex + currentColumn, targetLine.endIndex)
        } else if direction > 0 {
            guard currentLineIndex < wrapped.count - 1 else { return }
            let targetLine = wrapped[currentLineIndex + 1]
            cursor = min(targetLine.startIndex + currentColumn, targetLine.endIndex)
        }
        normalize()
    }

    private func lineStart() -> Int {
        let characters = Array(text)
        return characters[..<min(cursor, characters.count)].lastIndex(of: "\n").map { $0 + 1 } ?? 0
    }

    private func lineEnd() -> Int {
        let characters = Array(text)
        return characters[cursor...].firstIndex(of: "\n") ?? characters.count
    }

    private func normalize() {
        cursor = min(max(0, cursor), Array(text).count)
        let contentWidth = 78
        let wrapped = TUIWrapping.lines(text, width: contentWidth, cursor: cursor)
        let maxScroll = max(0, wrapped.count - maxHeight)
        if let absoluteLine = wrapped.firstIndex(where: { $0.cursorColumn != nil }) {
            if absoluteLine < scrollLine {
                scrollLine = absoluteLine
            } else if absoluteLine >= scrollLine + maxHeight {
                scrollLine = absoluteLine - maxHeight + 1
            }
        }
        scrollLine = max(0, min(scrollLine, maxScroll))
    }
}

public enum ChatComposerAction: Sendable, Equatable {
    case changed
    case submit
    case ignored
}

public struct TUICommandItem: Sendable, Equatable {
    public let name: String
    public let description: String
    public let enabled: Bool

    public init(name: String, description: String, enabled: Bool = true) {
        self.name = name
        self.description = description
        self.enabled = enabled
    }
}

public final class SlashCompletionView {
    public private(set) var items: [TUICommandItem] = []
    public private(set) var selectedIndex = 0

    public init() {}

    public func update(items: [TUICommandItem], selectedIndex: Int = 0) {
        self.items = items
        self.selectedIndex = min(max(0, selectedIndex), max(0, items.count - 1))
    }

    public func handle(_ event: TUIInputEvent) {
        guard !items.isEmpty else { return }
        switch event {
        case .up: selectedIndex = max(0, selectedIndex - 1)
        case .down: selectedIndex = min(items.count - 1, selectedIndex + 1)
        default: break
        }
    }

    public func render(width: Int, maxCount: Int = 7) -> [TUIStyledLine] {
        let safeSelected = items.isEmpty ? 0 : min(max(0, selectedIndex), items.count - 1)
        let scrollOffset = max(0, min(safeSelected - maxCount / 2, max(0, items.count - maxCount)))
        let visible = items.enumerated().dropFirst(scrollOffset).prefix(maxCount)
        let rows = visible.map { index, item in
            let isSelected = index == safeSelected
            return TUIStyledLine("\(isSelected ? "›" : " ") /\(item.name)  \(item.description)", style: isSelected ? .overlayHighlight : .overlayItem)
        }
        return [TUIStyledLine("", style: .overlayItemDim), TUIStyledLine("Commands", style: .overlayTitle)] + rows + [TUIStyledLine("↑↓ navigate   Enter select   Esc cancel", style: .overlayItemDim)]
    }

    public func render(width: Int) -> [TUIStyledLine] {
        render(width: width, maxCount: 7)
    }
}

public enum TUICompletionKind: String, Sendable, Equatable {
    case command
    case reference
}

public struct TUICompletionItem: Sendable, Equatable {
    public let value: String
    public let label: String
    public let detail: String
    public let kind: TUICompletionKind
    public let enabled: Bool

    public init(value: String, label: String, detail: String = "", kind: TUICompletionKind, enabled: Bool = true) {
        self.value = value
        self.label = label
        self.detail = detail
        self.kind = kind
        self.enabled = enabled
    }
}

public final class CompletionView {
    public private(set) var items: [TUICompletionItem] = []
    public private(set) var selectedIndex = 0
    public private(set) var query = ""

    public init() {}

    public func update(items: [TUICompletionItem], query: String = "", selectedIndex: Int = 0) {
        self.items = items
        self.query = query
        self.selectedIndex = min(max(0, selectedIndex), max(0, items.count - 1))
    }

    public func handle(_ event: TUIInputEvent) {
        guard !items.isEmpty else { return }
        switch event {
        case .up: selectedIndex = max(0, selectedIndex - 1)
        case .down: selectedIndex = min(items.count - 1, selectedIndex + 1)
        case .pageUp: selectedIndex = max(0, selectedIndex - 5)
        case .pageDown: selectedIndex = min(items.count - 1, selectedIndex + 5)
        default: break
        }
    }

    public func handlePageUp() {
        selectedIndex = max(0, selectedIndex - 5)
    }

    public func handlePageDown() {
        selectedIndex = min(max(0, items.count - 1), selectedIndex + 5)
    }

    public var selectedItem: TUICompletionItem? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    public func render(maxCount: Int = 7) -> [TUIStyledLine] {
        guard !items.isEmpty else { return [TUIStyledLine("No matches", style: .overlayItemDim)] }
        let safeSelected = min(max(0, selectedIndex), items.count - 1)
        let scrollOffset = max(0, min(safeSelected - maxCount / 2, max(0, items.count - maxCount)))
        let visible = items.enumerated().dropFirst(scrollOffset).prefix(maxCount)
        return visible.map { index, item in
            let isSelected = index == safeSelected
            let marker = isSelected ? "›" : " "
            let suffix = item.detail.isEmpty ? "" : "  \(item.detail)"
            return TUIStyledLine("\(marker) \(item.label)\(suffix)", style: isSelected ? .overlayHighlight : .overlayItem)
        }
    }

    public func render() -> [TUIStyledLine] {
        render(maxCount: 7)
    }
}

public enum TUIFocus: Sendable {
    case global
    case chat
    case transcript
    case composer
    case picker
    case permission
    case overlay
    case completion
}

public enum TUITimelineState: String, Sendable, Equatable {
    case requested
    case running
    case completed
    case failed
    case cancelled
    case denied
    case timedOut
    case warning
}

public enum TUITimelineKind: String, Sendable, Equatable {
    case user = "User"
    case assistant = "Assistant"
    case thinking = "Thinking"
    case read = "Read"
    case search = "Search"
    case edit = "Edit"
    case patch = "Patch"
    case write = "Write"
    case shell = "Shell"
    case git = "Git"
    case mcp = "MCP"
    case tool = "Tool"
    case toolResult = "ToolResult"
    case subagent = "Subagent"
    case question = "Question"
    case permission = "Permission"
    case decision = "Decision"
    case error = "Error"
    case result = "Result"
}

public struct TimelineSequence: Sendable, Equatable, Comparable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct TUITimelineItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let sequence: TimelineSequence
    public let kind: TUITimelineKind
    public var title: String
    public var summary: String
    public var details: [String]
    public var state: TUITimelineState
    public var collapsed: Bool
    public var parentID: String?

    public init(id: String, sequence: TimelineSequence = TimelineSequence(rawValue: 0), kind: TUITimelineKind, title: String, summary: String = "", details: [String] = [], state: TUITimelineState = .completed, collapsed: Bool = false, parentID: String? = nil) {
        self.id = id
        self.sequence = sequence
        self.kind = kind
        self.title = title
        self.summary = summary
        self.details = details
        self.state = state
        self.collapsed = collapsed
        self.parentID = parentID
    }
}

public struct TUITransientView: Sendable, Equatable {
    public let id: String
    public let title: String
    public let lines: [TUIStyledLine]
    public let focus: TUIFocus
    public let selectedIndex: Int

    public init(id: String, title: String, lines: [TUIStyledLine], focus: TUIFocus = .overlay, selectedIndex: Int = 0) {
        self.id = id
        self.title = title
        self.lines = lines
        self.focus = focus
        self.selectedIndex = selectedIndex
    }
}

public final class TUIViewStack {
    public private(set) var views: [TUITransientView] = []

    public init() {}

    public var top: TUITransientView? { views.last }
    public func push(_ view: TUITransientView) { views.append(view) }
    @discardableResult public func pop() -> TUITransientView? { views.popLast() }
    public func replace(_ view: TUITransientView) { if views.isEmpty { views.append(view) } else { views[views.count - 1] = view } }
    public func removeAll() { views.removeAll() }
}

// MARK: - Markdown Renderer for Assistant Output
public enum TUIMarkdownRenderer {
    public static func render(_ text: String, width: Int, defaultStyle: TUIStyle = .assistantText) -> [TUIStyledLine] {
        let maxTextWidth = max(10, width - 4)
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [TUIStyledLine] = []
        var inCodeBlock = false
        var codeBlockLang = ""
        var codeBlockLines: [String] = []
        var isFirstAssistantLine = true

        func flushCodeBlock() {
            guard inCodeBlock else { return }
            inCodeBlock = false
            let boxWidth = min(maxTextWidth, max(24, maxTextWidth))
            let innerWidth = max(10, boxWidth - 4)
            let langTag = codeBlockLang.trimmingCharacters(in: .whitespaces)
            let tag = langTag.isEmpty ? " Code " : " \(langTag) "
            let tagLen = TUIDisplayWidth.width(of: tag)
            let rightDashes = max(2, boxWidth - 2 - 2 - tagLen)
            let topBorder = "  ┌─\(tag)\(String(repeating: "─", count: rightDashes))┐"
            let bottomBorder = "  └\(String(repeating: "─", count: boxWidth - 2))┘"

            result.append(TUIStyledLine(topBorder, style: .toolCommand))
            for cline in codeBlockLines {
                let wrapped = TUIWrapping.lines(cline, width: innerWidth)
                for w in wrapped {
                    let pad = String(repeating: " ", count: max(0, innerWidth - TUIDisplayWidth.width(of: w.text)))
                    result.append(TUIStyledLine("  │ \(w.text)\(pad) │", style: .composerText))
                }
            }
            result.append(TUIStyledLine(bottomBorder, style: .toolTree))
            codeBlockLines.removeAll()
            codeBlockLang = ""
        }

        func parseOrderedList(_ s: String) -> (marker: String, remainder: String)? {
            guard let dotIdx = s.firstIndex(of: ".") else { return nil }
            let numStr = String(s[..<dotIdx])
            guard Int(numStr) != nil else { return nil }
            let afterDot = s[s.index(after: dotIdx)...]
            guard afterDot.hasPrefix(" ") else { return nil }
            let marker = numStr + ". "
            let remainder = String(afterDot.dropFirst()).trimmingCharacters(in: .whitespaces)
            return (marker, remainder)
        }

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // 1. 代码块起始 / 结束标记 ```
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    flushCodeBlock()
                } else {
                    inCodeBlock = true
                    codeBlockLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeBlockLines.removeAll()
                }
                continue
            }

            if inCodeBlock {
                codeBlockLines.append(rawLine)
                continue
            }

            // 2. 遥测信息行 ⚡️（原样输出，靠左带缩进）
            if rawLine.contains("⚡️") {
                result.append(TUIStyledLine("  " + trimmed, style: .dim))
                continue
            }

            // 3. 空行
            if trimmed.isEmpty {
                result.append(TUIStyledLine("", style: defaultStyle))
                continue
            }

            // 4. 标题 Heading (#, ##, ###)
            if trimmed.hasPrefix("# ") {
                let title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                let wrapped = TUIWrapping.lines(title, width: max(10, maxTextWidth - 4))
                for (idx, w) in wrapped.enumerated() {
                    let prefix = idx == 0 ? "◈ " : "  "
                    result.append(TUIStyledLine(prefix + w.text, style: .modalHighlight))
                }
                isFirstAssistantLine = false
                continue
            } else if trimmed.hasPrefix("## ") {
                let title = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let wrapped = TUIWrapping.lines(title, width: max(10, maxTextWidth - 4))
                for (idx, w) in wrapped.enumerated() {
                    let prefix = idx == 0 ? "◆ " : "  "
                    result.append(TUIStyledLine(prefix + w.text, style: .toolCommand))
                }
                isFirstAssistantLine = false
                continue
            } else if trimmed.hasPrefix("### ") {
                let title = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                let wrapped = TUIWrapping.lines(title, width: max(10, maxTextWidth - 4))
                for (idx, w) in wrapped.enumerated() {
                    let prefix = idx == 0 ? "◇ " : "  "
                    result.append(TUIStyledLine(prefix + w.text, style: .toolArg))
                }
                isFirstAssistantLine = false
                continue
            }

            // 5. 引用块 Blockquote (> )
            if trimmed.hasPrefix("> ") {
                let quoteText = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                let wrapped = TUIWrapping.lines(quoteText, width: max(10, maxTextWidth - 4))
                for w in wrapped {
                    result.append(TUIStyledLine("  ▎ " + w.text, style: .thinkingHeader))
                }
                isFirstAssistantLine = false
                continue
            }

            // 6. 列表项 List Items (- item, * item, 1. item)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let itemText = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                let itemAvail = max(10, maxTextWidth - 4)
                let wrapped = TUIWrapping.lines(itemText, width: itemAvail)
                for (idx, w) in wrapped.enumerated() {
                    let prefix = idx == 0 ? "  • " : "    "
                    result.append(TUIStyledLine(prefix + w.text, style: defaultStyle))
                }
                isFirstAssistantLine = false
                continue
            } else if let ordered = parseOrderedList(trimmed) {
                let prefixMarker = ordered.marker
                let pLen = TUIDisplayWidth.width(of: prefixMarker)
                let indentSpaces = String(repeating: " ", count: pLen + 2)
                let itemAvail = max(10, maxTextWidth - pLen - 2)
                let wrapped = TUIWrapping.lines(ordered.remainder, width: itemAvail)
                for (idx, w) in wrapped.enumerated() {
                    let p = idx == 0 ? "  \(prefixMarker)" : indentSpaces
                    result.append(TUIStyledLine(p + w.text, style: defaultStyle))
                }
                isFirstAssistantLine = false
                continue
            }

            // 7. 分割线 (--- or ***)
            if trimmed == "---" || trimmed == "***" || trimmed == "------" {
                let ruleWidth = min(maxTextWidth - 4, 40)
                result.append(TUIStyledLine("  " + String(repeating: "┈", count: ruleWidth), style: .dim))
                continue
            }

            // 8. 普通段落与文本
            let prefixStr = isFirstAssistantLine ? "✦ " : "  "
            let pWidth = TUIDisplayWidth.width(of: prefixStr)
            let bodyAvail = max(10, maxTextWidth - pWidth)
            let wrapped = TUIWrapping.lines(trimmed, width: bodyAvail)
            for (idx, w) in wrapped.enumerated() {
                let p = (isFirstAssistantLine && idx == 0) ? prefixStr : "  "
                result.append(TUIStyledLine(p + w.text, style: defaultStyle))
            }
            isFirstAssistantLine = false
        }

        if inCodeBlock {
            flushCodeBlock()
        }

        return result
    }
}

public final class TranscriptViewport {
    public var entries: [TUITranscriptEntry] = []
    public private(set) var scrollOffset = 0
    public private(set) var followsBottom = true
    public private(set) var collapseState: [String: Bool] = [:]
    public private(set) var timelineItems: [TUITimelineItem] = []
    public private(set) var selectedIndex: Int = -1

    public var showsBackToCurrent: Bool { !followsBottom && scrollOffset > 0 }
    public var autoFollow: Bool { followsBottom }
    public var isAtBottom: Bool { followsBottom && scrollOffset == 0 }

    public var selectedItemID: String? {
        if timelineItems.indices.contains(selectedIndex) {
            return timelineItems[selectedIndex].id
        }
        if entries.indices.contains(selectedIndex) {
            return entries[selectedIndex].id
        }
        return nil
    }

    public func selectNext() {
        let count = !timelineItems.isEmpty ? timelineItems.count : entries.count
        guard count > 0 else { selectedIndex = -1; return }
        if selectedIndex < count - 1 {
            selectedIndex += 1
        }
        if !timelineItems.isEmpty {
            replace(projectedTimeline(timelineItems))
        }
    }

    public func selectPrevious() {
        let count = !timelineItems.isEmpty ? timelineItems.count : entries.count
        guard count > 0 else { selectedIndex = -1; return }
        if selectedIndex > 0 {
            selectedIndex -= 1
        } else if selectedIndex == -1 {
            selectedIndex = count - 1
        }
        if !timelineItems.isEmpty {
            replace(projectedTimeline(timelineItems))
        }
    }

    public func clearSelection() {
        selectedIndex = -1
        if !timelineItems.isEmpty {
            replace(projectedTimeline(timelineItems))
        }
    }

    public func replace(_ entries: [TUITranscriptEntry]) {
        self.entries = entries
        if followsBottom { scrollOffset = 0 }
    }

    public func scrollToBottom() {
        scrollOffset = 0
        followsBottom = true
    }

    public func replaceTimeline(_ items: [TUITimelineItem]) {
        timelineItems = items
        replace(projectedTimeline(items))
    }

    public func defaultCollapsed(for item: TUITimelineItem) -> Bool {
        switch item.kind {
        case .thinking:
            return item.state == .completed
        case .tool, .toolResult, .shell, .mcp, .read, .search, .git, .write, .patch:
            if item.state == .running || item.state == .requested || item.state == .failed {
                return false
            }
            return !TUITimelineProjector.isShortResult(item.details)
        case .edit:
            return false // Diff expanded if recent
        case .subagent:
            return true // Subagent compact by default
        case .error:
            return false // Error expanded
        case .user, .assistant, .question, .permission, .decision, .result:
            return false
        }
    }

    public func isCollapsed(id: String) -> Bool {
        if let state = collapseState[id] { return state }
        if let item = timelineItems.first(where: { $0.id == id }) {
            return defaultCollapsed(for: item)
        }
        if let entry = entries.first(where: { $0.id == id }) {
            return entry.collapsed
        }
        return false
    }

    public func toggleCollapse(id: String) {
        let current = isCollapsed(id: id)
        collapseState[id] = !current
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].collapsed = !current
        }
        if !timelineItems.isEmpty {
            replace(projectedTimeline(timelineItems))
        }
    }

    public func setCollapse(id: String, collapsed: Bool) {
        collapseState[id] = collapsed
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].collapsed = collapsed
        }
        if !timelineItems.isEmpty {
            replace(projectedTimeline(timelineItems))
        }
    }

    public func toggleLastCollapse() {
        guard let item = timelineItems.last else { return }
        toggleCollapse(id: item.id)
    }

    public func toggleSelectedCollapse() {
        if let id = selectedItemID {
            toggleCollapse(id: id)
        } else {
            toggleLastCollapse()
        }
    }

    public func collapseSelected() {
        guard let id = selectedItemID else { return }
        setCollapse(id: id, collapsed: true)
    }

    public func expandSelected() {
        guard let id = selectedItemID else { return }
        setCollapse(id: id, collapsed: false)
    }

    private func projectedTimeline(_ items: [TUITimelineItem]) -> [TUITranscriptEntry] {
        items.enumerated().map { index, item in
            let style: TUIStyle = switch item.state {
            case .failed, .timedOut: .error
            case .warning, .denied: .warning
            case .requested, .running: .accent
            case .cancelled: .dim
            case .completed: item.kind == .thinking ? .dim : .normal
            }
            let collapsed = isCollapsed(id: item.id)
            let isSelected = (index == selectedIndex)
            let selectIndicator = isSelected ? "› " : ""
            let glyph = stateGlyph(item.state)
            let detailsToShow = item.details.filter { $0 != item.summary }

            let text: String
            switch item.kind {
            case .user:
                text = item.summary.isEmpty ? detailsToShow.joined(separator: "\n") : item.summary
            case .assistant:
                text = detailsToShow.isEmpty ? item.summary : detailsToShow.joined(separator: "\n")
            case .thinking:
                if collapsed {
                    let duration = item.summary.isEmpty ? "" : "  \(item.summary)"
                    text = "\(selectIndicator)▶ \(item.title)\(duration)"
                } else {
                    let content = (detailsToShow.isEmpty ? item.summary : detailsToShow.joined(separator: "\n"))
                    let indented = content.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n")
                    text = "\(selectIndicator)▼ \(item.title)\n" + indented
                }
            case .read, .search, .patch, .write, .shell, .git, .mcp, .tool:
                if item.state == .cancelled {
                    text = "\(selectIndicator)○ \(item.title)"
                } else {
                    let summaryText = item.summary.isEmpty ? "" : " · \(item.summary)"
                    if collapsed {
                        let preview = item.details.first(where: { $0.hasPrefix("Showing") })
                        let previewLine = preview.map { "\n  \($0)" } ?? ""
                        text = "\(selectIndicator)▶ \(item.title)\(summaryText)\(previewLine)"
                    } else {
                        let body = detailsToShow.isEmpty ? item.summary : detailsToShow.joined(separator: "\n")
                        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
                        let isListingTool = ["list_directory", "listdirectory", "glob", "grep"].contains(where: { item.title.lowercased().contains($0) })
                        let maxPreview = isListingTool ? 10 : 5
                        let hidden = max(0, lines.count - maxPreview)
                        let unit = isListingTool ? "entries" : "lines"
                        let indented = lines.prefix(maxPreview).map { "  \($0)" }.joined(separator: "\n") + (hidden == 0 ? "" : "\n  … \(hidden) \(unit) collapsed")
                        text = "\(selectIndicator)▼ \(item.title)\(summaryText)\(indented.isEmpty ? "" : "\n" + indented)"
                    }
                }
            case .edit:
                if collapsed {
                    let summaryText = item.summary.isEmpty ? "" : " · \(item.summary)"
                    text = "\(selectIndicator)▶ \(item.title)\(summaryText)"
                } else {
                    let summaryHeader = item.summary.isEmpty ? "" : " · \(item.summary)"
                    let diffContent = detailsToShow.joined(separator: "\n")
                    text = "\(selectIndicator)▼ \(item.title)\(summaryHeader)\(diffContent.isEmpty ? "" : "\n" + diffContent)"
                }
            case .subagent:
                if collapsed {
                    let summaryText = item.summary.isEmpty ? "" : " · \(item.summary)"
                    text = "\(selectIndicator)▶ \(item.title)\(summaryText)"
                } else {
                    let treeLines = detailsToShow.isEmpty ? item.summary : detailsToShow.joined(separator: "\n")
                    text = "\(selectIndicator)▼ \(item.title)\n" + treeLines
                }
            case .error:
                if collapsed {
                    let summaryText = item.summary.isEmpty ? "" : " · \(item.summary)"
                    text = "\(selectIndicator)▶ ✕ \(item.title)\(summaryText)"
                } else {
                    let body = detailsToShow.isEmpty ? item.summary : detailsToShow.joined(separator: "\n")
                    let indented = body.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n")
                    text = "\(selectIndicator)▼ ✕ \(item.title)\(indented.isEmpty ? "" : "\n" + indented)"
                }
            default:
                let prefix = "\(selectIndicator)\(glyph) \(item.title)"
                let body = item.summary.isEmpty ? detailsToShow.joined(separator: "\n") : item.summary
                text = [prefix, body].filter { !$0.isEmpty }.joined(separator: "\n")
            }

            return TUITranscriptEntry(
                id: item.id,
                kind: item.kind.transcriptKind,
                text: text,
                style: style,
                collapsed: collapsed,
                parentID: item.parentID
            )
        }
    }

    public func append(_ entry: TUITranscriptEntry) {
        entries.append(entry)
        if followsBottom { scrollOffset = 0 }
    }

    public func updateLast(_ text: String) {
        guard !entries.isEmpty else { return }
        entries[entries.count - 1].text = text
    }

    public func update(id: String, text: String? = nil, style: TUIStyle? = nil, collapsed: Bool? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if let text { entries[index].text = text }
        if let collapsed { entries[index].collapsed = collapsed; collapseState[id] = collapsed }
        if let style { entries[index] = TUITranscriptEntry(id: entries[index].id, kind: entries[index].kind, text: entries[index].text, style: style, collapsed: entries[index].collapsed, parentID: entries[index].parentID) }
    }

    public func handle(_ event: TUIInputEvent, viewportHeight: Int) {
        switch event {
        case .up, .pageUp, .scrollUp:
            let step = (event == .pageUp ? max(1, viewportHeight - 2) : (event == .scrollUp ? 3 : 1))
            scrollOffset += step
            followsBottom = false
        case .down, .pageDown, .scrollDown:
            let step = (event == .pageDown ? max(1, viewportHeight - 2) : (event == .scrollDown ? 3 : 1))
            scrollOffset = max(0, scrollOffset - step)
            if scrollOffset == 0 { followsBottom = true }
        case .home: scrollOffset = max(0, renderedLines().count - max(1, viewportHeight)); followsBottom = false
        case .end: scrollOffset = 0; followsBottom = true
        default: break
        }
    }

    public func entryID(atRow row: Int, viewportHeight: Int, width: Int) -> String? {
        var entryLineRanges: [(id: String, count: Int)] = []
        entryLineRanges.reserveCapacity(entries.count)
        var totalLines = 0
        for entry in entries {
            let lines = renderEntryLines(entry, width: width)
            entryLineRanges.append((id: entry.id, count: lines.count))
            totalLines += lines.count
        }
        let count = max(1, viewportHeight)
        let effectiveScrollOffset = min(scrollOffset, max(0, totalLines - count))
        let end = max(0, totalLines - effectiveScrollOffset)
        let start = max(0, end - count)
        let targetLineIndex = start + row
        guard targetLineIndex >= 0 && targetLineIndex < totalLines else { return nil }

        var currentLine = 0
        for item in entryLineRanges {
            if targetLineIndex >= currentLine && targetLineIndex < currentLine + item.count {
                return item.id
            }
            currentLine += item.count
        }
        return nil
    }

    public func render(viewportHeight: Int, width: Int) -> [TUIStyledLine] {
        let allLines = renderedLines(width: width)
        let count = max(1, viewportHeight)
        scrollOffset = min(scrollOffset, max(0, allLines.count - count))
        let end = max(0, allLines.count - scrollOffset)
        let start = max(0, end - count)
        return Array(allLines[start..<end])
    }

    private struct EntryCacheKey: Hashable {
        let id: String
        let textHash: Int
        let textCount: Int
        let width: Int
        let style: TUIStyle
        let kind: TUITranscriptKind
        let collapsed: Bool
    }
    private var entryCache: [EntryCacheKey: [TUIStyledLine]] = [:]

    private struct IncrementalLayoutState {
        var id: String
        var width: Int
        var style: TUIStyle
        var kind: TUITranscriptKind
        var rawText: String
        var prefix: String
        var availableWidth: Int
        var committedLines: [TUIStyledLine]
        var trailingLine: String
    }
    private var activeIncrementalLayout: IncrementalLayoutState?

    private func renderedLines(width: Int = 80) -> [TUIStyledLine] {
        entries.flatMap { entry in
            renderEntryLines(entry, width: width)
        }
    }

    private func renderEntryLines(_ entry: TUITranscriptEntry, width: Int) -> [TUIStyledLine] {
        let key = EntryCacheKey(
            id: entry.id,
            textHash: entry.text.hashValue,
            textCount: entry.text.count,
            width: width,
            style: entry.style,
            kind: entry.kind,
            collapsed: entry.collapsed
        )

        if let cached = entryCache[key] {
            return cached
        }

        // 尝试增量 Text Append & Layout (针对流式中且未折叠的最后一个 active entry)
        if !entry.collapsed,
           entry.kind != .user,
           var layout = activeIncrementalLayout,
           layout.id == entry.id,
           layout.width == width,
           layout.style == entry.style,
           layout.kind == entry.kind,
           entry.text.hasPrefix(layout.rawText) {

            let newChars = String(entry.text.dropFirst(layout.rawText.count))
            let combined = layout.trailingLine + newChars
            let wrapped = TUIWrapping.lines(combined, width: layout.availableWidth)

            if wrapped.count > 1 {
                // 前面的行已成为确定换行的不可变行
                let completedCount = wrapped.count - 1
                for i in 0..<completedCount {
                    let isFirst = layout.committedLines.isEmpty && i == 0
                    let p = isFirst ? layout.prefix : String(repeating: " ", count: TUIDisplayWidth.width(of: layout.prefix))
                    let rendered = p + wrapped[i].text
                    let lineStyle = (isFirst || entry.style == .accent) ? entry.style : diffStyle(for: wrapped[i].text, fallback: entry.style)
                    layout.committedLines.append(TUIStyledLine(rendered, style: lineStyle))
                }
                layout.trailingLine = wrapped.last?.text ?? ""
                layout.rawText = entry.text
                activeIncrementalLayout = layout
            } else {
                layout.trailingLine = combined
                layout.rawText = entry.text
                activeIncrementalLayout = layout
            }

            var result = layout.committedLines
            if !layout.trailingLine.isEmpty || result.isEmpty {
                let isFirst = result.isEmpty
                let p = isFirst ? layout.prefix : String(repeating: " ", count: TUIDisplayWidth.width(of: layout.prefix))
                let rendered = p + layout.trailingLine
                let lineStyle = (isFirst || entry.style == .accent) ? entry.style : diffStyle(for: layout.trailingLine, fallback: entry.style)
                result.append(TUIStyledLine(rendered, style: lineStyle))
            }

            // 对已确定的结果写缓存
            if entryCache.count > 300 { entryCache.removeAll(keepingCapacity: true) }
            entryCache[key] = result
            return result
        }

        // 全量渲染单个 entry
        let result: [TUIStyledLine]
        if entry.kind == .user, width >= 4 {
            let boxWidth = max(4, width)
            let contentWidth = max(1, boxWidth - 4)
            let bodyLines = TUIWrapping.lines(entry.text, width: contentWidth)
            let topBorder = "╭\(String(repeating: "─", count: max(0, boxWidth - 2)))╮"
            let bottomBorder = "╰\(String(repeating: "─", count: max(0, boxWidth - 2)))╯"
            result = [TUIStyledLine(topBorder, style: .accent)]
                + bodyLines.map { line in
                    let padding = String(repeating: " ", count: max(0, contentWidth - TUIDisplayWidth.width(of: line.text)))
                    return TUIStyledLine("│ \(line.text)\(padding) │", style: .composerText)
                }
                + [TUIStyledLine(bottomBorder, style: .accent)]
        } else if entry.kind == .toolCall {
            let rawLines = entry.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let safeWidth = max(10, width - 4)
            let wrapLine: (String) -> [String] = { lineStr in
                let lineWidth = TUIDisplayWidth.width(of: lineStr)
                guard lineWidth > safeWidth, safeWidth > 12 else { return [lineStr] }
                let wrapped = TUIWrapping.lines(lineStr, width: safeWidth)
                guard wrapped.count > 1 else { return [lineStr] }
                var res: [String] = [wrapped[0].text]
                let indent = "      "
                let subWidth = max(10, safeWidth - 6)
                for sub in wrapped.dropFirst() {
                    let subLines = TUIWrapping.lines(sub.text.trimmingCharacters(in: .whitespaces), width: subWidth)
                    for sl in subLines {
                        res.append(indent + sl.text)
                    }
                }
                return res
            }
            if entry.collapsed {
                let maxLinesToShow = min(2, rawLines.count)
                var shownLines: [String] = []
                for i in 0..<maxLinesToShow {
                    shownLines.append(contentsOf: wrapLine(rawLines[i]))
                }
                let hiddenCount = rawLines.count - maxLinesToShow
                if hiddenCount > 0 {
                    shownLines.append("  ... \(hiddenCount) lines collapsed (ctrl + t to view transcript)")
                }
                result = shownLines.map { parseToolCallLineSpans($0, defaultStyle: entry.style) }
            } else {
                var wrappedLines: [String] = []
                for line in rawLines {
                    wrappedLines.append(contentsOf: wrapLine(line))
                }
                result = wrappedLines.map { parseToolCallLineSpans($0, defaultStyle: entry.style) }
            }
        } else if entry.kind == .thinking {
            let rawLines = entry.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let firstLine = rawLines.first ?? "Thinking"
            let safeWidth = max(10, width - 4)
            if entry.collapsed {
                let summaryRaw = rawLines.count > 1 ? rawLines[1].trimmingCharacters(in: .whitespaces) : "Thinking process"
                let maxSummaryWidth = max(10, safeWidth - 6)
                let wrappedSummary = TUIWrapping.lines(summaryRaw, width: maxSummaryWidth)
                let summaryText = wrappedSummary.first?.text ?? summaryRaw
                let summaryLine = "  └ ▶ " + summaryText
                result = [
                    TUIStyledLine(firstLine, style: .thinkingHeader),
                    TUIStyledLine(summaryLine, style: .thinkingBody)
                ]
            } else {
                let wrappedFirst = TUIWrapping.lines(firstLine, width: safeWidth)
                var lines: [TUIStyledLine] = wrappedFirst.map { TUIStyledLine($0.text, style: .thinkingHeader) }
                let contentWidth = max(10, safeWidth - 2)
                for line in rawLines.dropFirst() {
                    let wrapped = TUIWrapping.lines(line, width: contentWidth)
                    for w in wrapped {
                        lines.append(TUIStyledLine("  " + w.text, style: .thinkingBody))
                    }
                }
                result = lines
            }
        } else {
            // Assistant 文本及其他消息：优雅 Markdown 结构化解析（代码块、标题、列表、引用）
            let style: TUIStyle = entry.kind == .assistant ? .assistantText : entry.style
            let mdLines = TUIMarkdownRenderer.render(entry.text, width: width, defaultStyle: style)
            result = mdLines

            // 初始化增量 Layout 状态（针对正在运行/流式的条目）
            if entry.style == .accent {
                let available = max(10, width - 5)
                let completed = result.count > 1 ? Array(result.dropLast()) : []
                let trailing = result.last?.text ?? ""
                activeIncrementalLayout = IncrementalLayoutState(
                    id: entry.id,
                    width: width,
                    style: entry.style,
                    kind: entry.kind,
                    rawText: entry.text,
                    prefix: "✦ ",
                    availableWidth: available,
                    committedLines: completed,
                    trailingLine: trailing
                )
            }
        }

        if entryCache.count > 300 { entryCache.removeAll(keepingCapacity: true) }
        entryCache[key] = result
        return result
    }

    private func parseToolCallLineSpans(_ rawLine: String, defaultStyle: TUIStyle) -> TUIStyledLine {
        var spans: [TUIStyledSpan] = []
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

        if rawLine.hasPrefix("• ") || rawLine.hasPrefix("⠋ ") || rawLine.hasPrefix("▶ ") {
            let isSpinner = rawLine.hasPrefix("⠋ ")
            let dotMarker = String(rawLine.prefix(2))
            let remainder = String(rawLine.dropFirst(2))

            let dotStyle: TUIStyle
            if isSpinner {
                dotStyle = .toolDotActive
            } else if rawLine.localizedCaseInsensitiveContains("fail") || rawLine.localizedCaseInsensitiveContains("error") || defaultStyle == .error {
                dotStyle = .toolDotError
            } else {
                dotStyle = .toolDotSuccess
            }
            spans.append(TUIStyledSpan(dotMarker, style: dotStyle))

            let words = remainder.split(separator: " ", omittingEmptySubsequences: false)
            for (idx, wordSubstring) in words.enumerated() {
                let word = String(wordSubstring)
                let sep = (idx == words.count - 1) ? "" : " "
                if idx == 0 {
                    spans.append(TUIStyledSpan(word + sep, style: .toolAction))
                } else if idx == 1 {
                    spans.append(TUIStyledSpan(word + sep, style: .toolCommand))
                } else if word.hasPrefix("-") {
                    spans.append(TUIStyledSpan(word + sep, style: .toolArg))
                } else {
                    spans.append(TUIStyledSpan(word + sep, style: .normal))
                }
            }
            return TUIStyledLine(rawLine, style: defaultStyle, spans: spans)
        }

        if rawLine.contains("└ ") {
            if let range = rawLine.range(of: "└ ") {
                let prefix = String(rawLine[..<range.upperBound])
                let after = String(rawLine[range.upperBound...])
                spans.append(TUIStyledSpan(prefix, style: .toolTree))

                let tokens = after.split(separator: " ", omittingEmptySubsequences: false)
                for (idx, tokenSubstring) in tokens.enumerated() {
                    let token = String(tokenSubstring)
                    let sep = (idx == tokens.count - 1) ? "" : " "
                    if idx == 0 && (token == "Read" || token == "Search" || token == "Find" || token == "Edit" || token == "Call" || token.contains("(")) {
                        spans.append(TUIStyledSpan(token + sep, style: .toolCommand))
                    } else if token.contains("=") || token.hasPrefix("--") || token.hasPrefix("-") {
                        spans.append(TUIStyledSpan(token + sep, style: .toolArg))
                    } else if token.hasPrefix("+") {
                        spans.append(TUIStyledSpan(token + sep, style: .toolDiffAdd))
                    } else if token.hasPrefix("-") {
                        spans.append(TUIStyledSpan(token + sep, style: .toolDiffRemove))
                    } else if token == "(no" || token == "output)" {
                        spans.append(TUIStyledSpan(token + sep, style: .toolSubtext))
                    } else {
                        spans.append(TUIStyledSpan(token + sep, style: .normal))
                    }
                }
                return TUIStyledLine(rawLine, style: defaultStyle, spans: spans)
            }
        }

        if trimmed.hasPrefix("+") && !trimmed.hasPrefix("+++") {
            return TUIStyledLine(rawLine, style: .accent, spans: [TUIStyledSpan(rawLine, style: .toolDiffAdd)])
        }
        if trimmed.hasPrefix("- ") && (trimmed.contains("[running]") || trimmed.contains("args:") || defaultStyle == .accent) {
            return TUIStyledLine(rawLine, style: defaultStyle)
        }
        if trimmed.hasPrefix("-") && !trimmed.hasPrefix("---") {
            return TUIStyledLine(rawLine, style: .error, spans: [TUIStyledSpan(rawLine, style: .toolDiffRemove)])
        }
        if trimmed.hasPrefix("...") || trimmed.contains("collapsed") || trimmed.contains("(ctrl + t") || trimmed.contains("more lines") {
            return TUIStyledLine(rawLine, style: .dim, spans: [TUIStyledSpan(rawLine, style: .toolSubtext)])
        }

        return TUIStyledLine(rawLine, style: defaultStyle)
    }

    private func diffStyle(for line: String, fallback: TUIStyle) -> TUIStyle {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .accent }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .error }
        return fallback
    }

    private func stateGlyph(_ state: TUITimelineState) -> String {
        switch state {
        case .requested, .running: "●"
        case .completed: "✓"
        case .failed, .timedOut: "✕"
        case .cancelled: "○"
        case .denied: "!"
        case .warning: "!"
        }
    }
}

public struct TUITranscriptEntry: Sendable {
    public let id: String
    public let kind: TUITranscriptKind
    public var text: String
    public let style: TUIStyle
    public var collapsed: Bool
    public let parentID: String?
    public var timestamp: Date

    public init(
        id: String = UUID().uuidString,
        kind: TUITranscriptKind,
        text: String,
        style: TUIStyle = .normal,
        collapsed: Bool = false,
        parentID: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.style = style
        self.collapsed = collapsed
        self.parentID = parentID
        self.timestamp = timestamp
    }
}

public enum TUITranscriptKind: String, Sendable {
    case user = "User"
    case assistant = "Assistant"
    case thinking = "Thinking"
    case toolCall = "ToolCall"
    case toolResult = "ToolResult"
    case subagent = "Subagent"
    case question = "Question"
    case permission = "Permission"
    case decision = "Decision"
    case error = "Error"
    case result = "Result"
}

private extension TUITimelineKind {
    var transcriptKind: TUITranscriptKind {
        switch self {
        case .user: .user
        case .assistant: .assistant
        case .thinking: .thinking
        case .read, .search, .edit, .patch, .write, .shell, .git, .mcp, .tool: .toolCall
        case .toolResult: .toolResult
        case .subagent: .subagent
        case .question: .question
        case .permission: .permission
        case .decision: .decision
        case .error: .error
        case .result: .result
        }
    }
}

public final class StatusLine {
    public var leftText: String = ""
    public var rightText: String = ""

    public var text: String {
        get {
            if rightText.isEmpty { return leftText }
            if leftText.isEmpty { return rightText }
            return "\(leftText) · \(rightText)"
        }
        set {
            leftText = newValue
            rightText = ""
        }
    }

    public init(leftText: String = "", rightText: String = "") {
        self.leftText = leftText
        self.rightText = rightText
    }

    public func setParts(left: String, right: String = "") {
        self.leftText = left
        self.rightText = right
    }

    public func render(width: Int) -> TUIStyledLine {
        let left = leftText.trimmingCharacters(in: .whitespaces)
        let right = rightText.trimmingCharacters(in: .whitespaces)

        if left.isEmpty && right.isEmpty {
            return TUIStyledLine("", style: .dim)
        }

        let pad = 2
        let leftWidth = TUIDisplayWidth.width(of: left)
        let rightWidth = TUIDisplayWidth.width(of: right)

        let minSeparation = 2
        if !left.isEmpty && !right.isEmpty {
            let available = max(0, width - (pad * 2))
            if leftWidth + rightWidth + minSeparation <= available {
                let spaceCount = available - leftWidth - rightWidth
                let spaces = String(repeating: " ", count: spaceCount)
                let indentation = String(repeating: " ", count: pad)
                return TUIStyledLine("\(indentation)\(left)\(spaces)\(right)", style: .dim)
            } else if leftWidth + rightWidth + 3 <= max(0, width - pad) {
                let indentation = String(repeating: " ", count: pad)
                return TUIStyledLine("\(indentation)\(left) · \(right)", style: .dim)
            } else {
                let indentation = width > leftWidth + pad ? String(repeating: " ", count: pad) : ""
                return TUIStyledLine("\(indentation)\(left)", style: .dim)
            }
        }

        let single = left.isEmpty ? right : left
        let singleWidth = left.isEmpty ? rightWidth : leftWidth
        let indentation = (width >= singleWidth + pad) ? String(repeating: " ", count: pad) : ""
        return TUIStyledLine("\(indentation)\(single)", style: .dim)
    }
}

public final class BottomPane {
    public let composer = ChatComposer()

    public init() {}

    public func requiredHeight(overlay: TUIOverlayModel?, width: Int, availableHeight: Int) -> Int {
        let composerHeight = composer.render(width: max(1, width - 4)).lines.count
        return min(max(3, composerHeight + 2), max(3, availableHeight))
    }

    public func render(_ overlay: TUIOverlayModel?, in frame: inout TUIFrame, top: Int, height: Int) -> TUIPoint? {
        let composerRect = TUIRect(x: 1, y: top, width: max(2, frame.size.width - 2), height: max(2, height))
        let composerLines = composer.render(width: max(1, composerRect.width - 2))
        frame.fill(composerRect, style: .composer)
        frame.strokeBox(composerRect, style: .accent, rounded: true)
        frame.writeLines(composerLines.lines, at: TUIPoint(x: composerRect.x + 1, y: composerRect.y + 1), maxWidth: max(1, composerRect.width - 2), maxHeight: max(1, composerRect.height - 2))
        if let overlay { render(overlay, in: &frame, composerRect: composerRect) }
        guard let cursor = composerLines.cursor else { return nil }
        return TUIPoint(x: composerRect.x + 1 + cursor.x, y: composerRect.y + 1 + cursor.y)
    }

    private func render(_ overlay: TUIOverlayModel, in frame: inout TUIFrame, composerRect: TUIRect) {
        var lines = overlay.lines
        while lines.first?.text.isEmpty == true { lines.removeFirst() }
        while lines.last?.text.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty, composerRect.y > 0 else { return }
        let contentWidth = lines.map { TUIDisplayWidth.width(of: $0.text) }.max() ?? 1
        let width = min(max(24, contentWidth + 2), max(2, frame.size.width - 2))
        let height = min(composerRect.y, lines.count + 2)
        let rect = TUIRect(x: 1, y: max(0, composerRect.y - height - 1), width: width, height: height)
        frame.fill(rect, style: .overlay)
        frame.stroke(rect, style: .accent)
        frame.writeLines(Array(lines.prefix(max(0, height - 2))), at: TUIPoint(x: rect.x + 1, y: rect.y + 1), maxWidth: max(1, rect.width - 2), maxHeight: max(1, rect.height - 2))
    }
}

public final class Header {
    public var title = "LingXiAgent"
    public var subtitle = ""

    public init() {}

    public func render(width: Int) -> [TUIStyledLine] {
        let titleLine = subtitle.isEmpty ? title : "\(title)  ·  \(subtitle)"
        return [TUIStyledLine(titleLine, style: .accent)]
    }
}

public enum TUIInputEvent: Equatable, Sendable {
    case character(Character)
    case paste(String)
    case enter
    case shiftEnter
    case backspace
    case delete
    case deleteWordBackward
    case escape
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case scrollUp
    case scrollDown
    case mouseClick(x: Int, y: Int)
    case mouseDown(x: Int, y: Int)
    case mouseDrag(x: Int, y: Int)
    case mouseUp(x: Int, y: Int)
    case interrupt
    case quit
    case resize(TUISize)
    case tick
    case tab
    case shiftTab
    case commandPalette
    case cycleReasoningEffort
}

public struct TUIHeroConfig: Sendable, Equatable {
    public var modeName: String
    public var modelName: String
    public var providerName: String
    public var reasoningEffort: String?
    public var tip: String
    public var permissionName: String

    public init(
        modeName: String = "Build",
        modelName: String = "DeepSeek V4 Flash",
        providerName: String = "DeepSeek",
        reasoningEffort: String? = nil,
        tip: String = "Press ctrl+p to see all available actions and commands",
        permissionName: String = "Ask/Workspace"
    ) {
        self.modeName = modeName
        self.modelName = modelName
        self.providerName = providerName
        self.reasoningEffort = reasoningEffort
        self.tip = tip
        self.permissionName = permissionName
    }
}

public struct TUISidebarModel: Sendable, Equatable {
    public struct CacheLayer: Sendable, Equatable {
        public let name: String
        public let usedTokens: Int
        public let capacityTokens: Int

        public init(name: String, usedTokens: Int, capacityTokens: Int) {
            self.name = name
            self.usedTokens = usedTokens
            self.capacityTokens = capacityTokens
        }

        public var ratio: Double {
            guard capacityTokens > 0 else { return 0 }
            return min(1.0, max(0.0, Double(usedTokens) / Double(capacityTokens)))
        }
    }

    public enum MCPStatus: Sendable, Equatable {
        case ready
        case empty
        case error(String?)
        case needsAuth
        case disabled

        public var label: String {
            switch self {
            case .ready: return "可用"
            case .empty: return "无工具"
            case let .error(msg):
                if let msg, msg == "不可用" || msg == "已禁用" {
                    return msg
                }
                return "错误"
            case .needsAuth: return "待认证"
            case .disabled: return "已禁用"
            }
        }
    }

    public struct MCPItem: Sendable, Equatable {
        public let id: String
        public let status: MCPStatus
        public init(id: String, status: MCPStatus) {
            self.id = id
            self.status = status
        }
    }

    public enum TaskStatus: Sendable, Equatable {
        case pending
        case inProgress
        case completed
        case failed

        public var icon: String {
            switch self {
            case .pending: return "•"
            case .inProgress: return "●"
            case .completed: return "✓"
            case .failed: return "✗"
            }
        }
    }

    public struct TaskItem: Sendable, Equatable {
        public let id: String
        public let title: String
        public let status: TaskStatus
        public init(id: String, title: String, status: TaskStatus) {
            self.id = id
            self.title = title
            self.status = status
        }
    }

    public struct SubagentItem: Sendable, Equatable {
        public let id: String
        public let role: String
        public let status: String
        public init(id: String, role: String, status: String) {
            self.id = id
            self.role = role
            self.status = status
        }
    }

    public struct PrefixCacheStats: Sendable, Equatable {
        public let cachedTokens: Int
        public let promptTokens: Int
        public let previousPromptTokens: Int?
        public let status: String // "active", "coldNewEpoch", "unavailable"
        public let cacheEpoch: Int?
        public let epochReason: String?
        public let clientHealthStatus: String?
        public let clientBustRate: Double?
        public let clientCausedBusts: Int?
        public let comparableRequests: Int?

        public var prefixReuseEfficiency: Double? {
            guard let prev = previousPromptTokens, prev > 0, status == "active" else { return nil }
            return min(1.0, max(0.0, Double(cachedTokens) / Double(prev)))
        }

        public var cachedInputShare: Double? {
            guard promptTokens > 0, status == "active" else { return nil }
            return min(1.0, max(0.0, Double(cachedTokens) / Double(promptTokens)))
        }

        public var ratio: Double {
            prefixReuseEfficiency ?? cachedInputShare ?? 0.0
        }

        public init(
            cachedTokens: Int,
            promptTokens: Int,
            previousPromptTokens: Int? = nil,
            status: String = "active",
            cacheEpoch: Int? = nil,
            epochReason: String? = nil,
            clientHealthStatus: String? = nil,
            clientBustRate: Double? = nil,
            clientCausedBusts: Int? = nil,
            comparableRequests: Int? = nil
        ) {
            self.cachedTokens = cachedTokens
            self.promptTokens = promptTokens
            self.previousPromptTokens = previousPromptTokens
            self.status = status
            self.cacheEpoch = cacheEpoch
            self.epochReason = epochReason
            self.clientHealthStatus = clientHealthStatus
            self.clientBustRate = clientBustRate
            self.clientCausedBusts = clientCausedBusts
            self.comparableRequests = comparableRequests
        }
    }

    public var summary: String
    public var cacheLayers: [CacheLayer]
    public var prefixCache: PrefixCacheStats?
    public var mcpItems: [MCPItem]
    public var tasks: [TaskItem]
    public var subagents: [SubagentItem]
    public var scrollOffset: Int
    public var mcpScrollOffset: Int
    public var taskScrollOffset: Int

    public init(
        summary: String,
        cacheLayers: [CacheLayer] = [],
        prefixCache: PrefixCacheStats? = nil,
        mcpItems: [MCPItem] = [],
        tasks: [TaskItem] = [],
        subagents: [SubagentItem] = [],
        scrollOffset: Int = 0,
        mcpScrollOffset: Int = 0,
        taskScrollOffset: Int = 0
    ) {
        self.summary = summary
        self.cacheLayers = cacheLayers
        self.prefixCache = prefixCache
        self.mcpItems = mcpItems
        self.tasks = tasks
        self.subagents = subagents
        self.scrollOffset = scrollOffset
        self.mcpScrollOffset = mcpScrollOffset
        self.taskScrollOffset = taskScrollOffset
    }
}

public enum ClipboardSupport {
    public static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        let base64 = Data(text.utf8).base64EncodedString()
        let osc52 = "\u{1B}]52;c;\(base64)\u{07}"
        FileHandle.standardOutput.write(Data(osc52.utf8))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let inPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            inPipe.fileHandleForWriting.write(Data(text.utf8))
            try inPipe.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {}
    }
}

public final class TUIApp {
    public let header = Header()
    public let transcript = TranscriptViewport()
    public let bottomPane = BottomPane()
    public let statusLine = StatusLine()
    public let viewStack = TUIViewStack()
    public private(set) var focus: TUIFocus = .composer
    public var heroConfig: TUIHeroConfig? = nil
    public var sidebarModel: TUISidebarModel? = nil

    public init() {}

    public var composer: ChatComposer { bottomPane.composer }

    public func layout(size: TUISize, overlay: TUIOverlayModel?) -> TUILayout {
        let availableBottom = max(3, size.height / 3)
        let bottomHeight = bottomPane.requiredHeight(overlay: nil, width: size.width, availableHeight: availableBottom)
        let hasSidebar = heroConfig == nil && sidebarModel != nil && size.width >= 80
        return TUILayout(size: size, headerHeight: header.render(width: size.width).count, bottomHeight: bottomHeight, hasSidebar: hasSidebar)
    }

    public func setFocus(_ focus: TUIFocus) { self.focus = focus }

    public func handleTranscriptInput(_ event: TUIInputEvent, viewportHeight: Int) {
        focus = .transcript
        if case .character(" ") = event {
            transcript.toggleLastCollapse()
        } else {
            transcript.handle(event, viewportHeight: viewportHeight)
        }
    }

    public func render(size: TUISize, overlay: TUIOverlayModel?) -> TUIFrame {
        if let overlay { focus = overlay.focus }
        if let overlay {
            viewStack.replace(TUITransientView(id: "active", title: "active", lines: overlay.lines, focus: focus))
        } else {
            viewStack.removeAll()
        }
        var frame = TUIFrame(size: size)
        frame.clear()

        // Hero Centered Mode (第一次启动或 /new 新建会话时输入框居中)
        if let hero = heroConfig {
            var y = 0
            for line in header.render(width: size.width) {
                frame.write(line.text, at: TUIPoint(x: 0, y: y), maxWidth: size.width, style: line.style)
                y += 1
            }

            let logoLines = [
                "█░░ █ █▄░█ █▀▀ ▀▄▀ █   ▄▀█ █▀▀ █▀▀ █▄░█ ▀█▀",
                "█▄▄ █ █░▀█ █▄█ █░█ █   █▀█ █▄█ ██▄ █░▀█ ░█░"
            ]
            let bannerWidth = 43
            let logoX = max(1, (size.width - bannerWidth) / 2)

            // 灵犀小狐狸像素吉祥物（萌萌长尖狐耳、灵犀灵动面容、捧着极光闪电、毛茸茸大狐尾）
            let logoY: Int
            if size.height >= 24, overlay == nil {
                let mascotY = max(y + 1, (size.height / 2) - 8)
                let earText = "  /\\___/\\  "
                let faceText = " (  • ᴥ • ) "
                let bodyText = "o(   ⚡   )o"
                let tailText = "  (_______) ~彡✦"
                let tag1 = "✦ LingXi Fox · 灵犀小狐狸 ✦"
                let tag2 = "「随时为主人效劳，代码与奇迹共生~」"

                let mascotBlockWidth = 48
                let mascotX = max(1, (size.width - mascotBlockWidth) / 2)

                frame.write(earText, at: TUIPoint(x: mascotX, y: mascotY), style: .mascotEar)
                frame.write(faceText, at: TUIPoint(x: mascotX, y: mascotY + 1), style: .mascotBody)
                frame.write("  " + tag1, at: TUIPoint(x: mascotX + 12, y: mascotY + 1), style: .mascotTag)

                frame.write(bodyText, at: TUIPoint(x: mascotX, y: mascotY + 2), style: .badgeYolo)
                frame.write("  " + tag2, at: TUIPoint(x: mascotX + 12, y: mascotY + 2), style: .dim)

                frame.write(tailText, at: TUIPoint(x: mascotX, y: mascotY + 3), style: .mascotSpark)
                logoY = mascotY + 5
            } else {
                let tag1 = "✦ LingXi Fox · 灵犀小狐狸 ✦"
                let tag1X = max(1, (size.width - TUIDisplayWidth.width(of: tag1)) / 2)
                let compactY = max(y + 1, (size.height / 2) - 6)
                frame.write(tag1, at: TUIPoint(x: tag1X, y: compactY), style: .mascotTag)
                logoY = compactY + 2
            }

            for (lIdx, lStr) in logoLines.enumerated() {
                frame.write(lStr, at: TUIPoint(x: logoX, y: logoY + lIdx), maxWidth: size.width, style: .heroLogo)
            }

            let boxWidth = min(max(64, size.width - 6), 88)
            let boxHeight = 5
            let boxX = max(1, (size.width - boxWidth) / 2)
            let boxY = logoY + logoLines.count + 1
            let boxRect = TUIRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
            frame.fill(boxRect, style: .heroBoxBg)
            frame.strokeBox(boxRect, style: .heroBoxBorder, rounded: true)

            if composer.isEmpty {
                frame.write("Ask anything... \"Fix a TODO in the codebase\"", at: TUIPoint(x: boxX + 2, y: boxY + 1), maxWidth: boxWidth - 4, style: .heroBoxPlaceholder)
                frame.cursor = TUIPoint(x: boxX + 2, y: boxY + 1)
            } else {
                composer.lastRenderWidth = boxWidth
                let innerWidth = boxWidth - 4
                let wrapped = TUIWrapping.lines(composer.text, width: innerWidth, cursor: composer.cursor)
                let visibleHeight = 2
                let cursorLineIdx = wrapped.firstIndex(where: { $0.cursorColumn != nil }) ?? 0
                let scrollOffset = max(0, min(cursorLineIdx - visibleHeight + 1, max(0, wrapped.count - visibleHeight)))
                let visibleLines = Array(wrapped.dropFirst(scrollOffset).prefix(visibleHeight))
                for (rIdx, rLine) in visibleLines.enumerated() {
                    frame.write(rLine.text, at: TUIPoint(x: boxX + 2, y: boxY + 1 + rIdx), maxWidth: innerWidth, style: .heroBoxText)
                    if let col = rLine.cursorColumn {
                        frame.cursor = TUIPoint(x: min(boxX + boxWidth - 2, boxX + 2 + col), y: boxY + 1 + rIdx)
                    }
                }
                if frame.cursor == nil {
                    frame.cursor = TUIPoint(x: boxX + 2, y: boxY + 1)
                }
            }

            var metaX = boxX + 2
            let metaY = boxY + boxHeight - 2

            // 1. Mode 名称
            frame.write(hero.modeName, at: TUIPoint(x: metaX, y: metaY), style: .heroMode)
            metaX += TUIDisplayWidth.width(of: hero.modeName)

            // 2. 分隔点
            frame.write(" · ", at: TUIPoint(x: metaX, y: metaY), style: .heroBoxMeta)
            metaX += 3

            // 3. Permission 徽标 (⚡ YOLO 或 Ask/Workspace)
            let isYolo = hero.permissionName.contains("YOLO")
            let permStyle: TUIStyle = isYolo ? .badgeYolo : .badgeAsk
            frame.write(hero.permissionName, at: TUIPoint(x: metaX, y: metaY), style: permStyle)
            metaX += TUIDisplayWidth.width(of: hero.permissionName)

            // 4. Model / Provider / Reasoning Effort
            let effortText = hero.reasoningEffort.map { " (\($0))" } ?? ""
            let displayModelText: String
            if hero.modelName.contains("/") {
                displayModelText = hero.modelName
            } else if !hero.providerName.isEmpty {
                displayModelText = "\(hero.providerName)/\(hero.modelName)"
            } else {
                displayModelText = hero.modelName
            }
            let metaText = " · \(displayModelText)\(effortText)"
            let remainingWidth = max(0, (boxX + boxWidth - 2) - metaX)
            if remainingWidth > 0 {
                frame.write(metaText, at: TUIPoint(x: metaX, y: metaY), maxWidth: remainingWidth, style: .heroBoxMeta)
            }

            if let overlay, !overlay.isModal {
                // 在居中输入框下方优雅展开命令补全或快捷浮层
                var lines = overlay.lines
                while lines.first?.text.isEmpty == true { lines.removeFirst() }
                while lines.last?.text.isEmpty == true { lines.removeLast() }
                if !lines.isEmpty {
                    let overlayWidth = boxWidth
                    let overlayX = boxX
                    let availableBelow = size.height - (boxY + boxHeight) - 2
                    let overlayHeight = min(min(lines.count + 2, 9), max(3, availableBelow))
                    let overlayY = boxY + boxHeight
                    let overlayRect = TUIRect(x: overlayX, y: overlayY, width: overlayWidth, height: overlayHeight)
                    frame.fill(overlayRect, style: .overlay)
                    frame.strokeBox(overlayRect, style: .accent, rounded: true)
                    frame.writeLines(Array(lines.prefix(max(0, overlayHeight - 2))), at: TUIPoint(x: overlayRect.x + 1, y: overlayRect.y + 1), maxWidth: max(1, overlayRect.width - 2), maxHeight: max(1, overlayRect.height - 2))
                }
            } else if overlay == nil {
                let shortcuts = "tab agents  ctrl+p commands"
                frame.write(shortcuts, at: TUIPoint(x: boxX + boxWidth - shortcuts.count, y: boxY + boxHeight), style: .dim)

                let tipLeft = "● Tip  "
                let fullTip = tipLeft + hero.tip
                let tipX = max(1, (size.width - fullTip.count) / 2)
                frame.put("●", at: TUIPoint(x: tipX, y: boxY + boxHeight + 2), style: .modalActiveDot)
                frame.write("Tip", at: TUIPoint(x: tipX + 2, y: boxY + boxHeight + 2), style: .heroTip)
                frame.write("  \(hero.tip)", at: TUIPoint(x: tipX + 5, y: boxY + boxHeight + 2), style: .dim)
            }

            let statusY = size.height - 1
            frame.write(statusLine.render(width: size.width).text, at: TUIPoint(x: 0, y: statusY), maxWidth: size.width, style: .dim)

            if let overlay, overlay.isModal {
                renderModalOverlay(overlay, in: &frame, size: size)
            }
            return frame
        }
        let regions = layout(size: size, overlay: overlay)
        var y = regions.header.y
        for line in header.render(width: size.width) {
            frame.write(line.text, at: TUIPoint(x: 0, y: y), maxWidth: size.width, style: line.style)
            y += 1
        }
        let transcriptWidth = regions.transcript.width
        let transcriptLines = transcript.render(viewportHeight: regions.transcript.height, width: transcriptWidth)
        frame.writeLines(transcriptLines, at: TUIPoint(x: regions.transcript.x, y: regions.transcript.y), maxWidth: transcriptWidth, maxHeight: regions.transcript.height)

        if let div = regions.divider {
            for dy in div.y..<(div.y + div.height) {
                frame.put("│", at: TUIPoint(x: div.x, y: dy), style: .heroBoxBorder)
            }
        }
        if let sb = regions.sidebar, let model = sidebarModel {
            renderSidebar(model, in: &frame, rect: sb)
        }

        let isModal = overlay?.isModal == true
        let bottomOverlay = isModal ? nil : overlay
        let bottomCursor = bottomPane.render(bottomOverlay, in: &frame, top: regions.bottomPane.y, height: regions.bottomPane.height)
        let statusY = regions.status.y
        frame.write(statusLine.render(width: size.width).text, at: TUIPoint(x: regions.status.x, y: statusY), maxWidth: regions.status.width, style: .dim)
        if let cursor = bottomCursor {
            frame.cursor = TUIPoint(x: min(size.width - 1, cursor.x), y: min(statusY - 1, cursor.y))
        }

        if let overlay, overlay.isModal {
            renderModalOverlay(overlay, in: &frame, size: size)
        }

        return frame
    }

    private struct SidebarLineItem {
        let xOffset: Int
        let text: String
        let style: TUIStyle
        let maxWidth: Int?
    }

    private struct SidebarRow {
        let items: [SidebarLineItem]
    }

    private func renderSidebar(_ model: TUISidebarModel, in frame: inout TUIFrame, rect: TUIRect) {
        guard rect.width >= 10, rect.height >= 5 else { return }
        let contentWidth = rect.width - 2
        let startX = rect.x + 1
        var currentY = rect.y
        let bottomY = rect.y + rect.height

        func writeLine(_ text: String, style: TUIStyle, maxWidth: Int = contentWidth, xOffset: Int = 0) {
            guard currentY < bottomY else { return }
            frame.write(text, at: TUIPoint(x: startX + xOffset, y: currentY), maxWidth: maxWidth, style: style)
            currentY += 1
        }

        func writeRow(items: [(text: String, style: TUIStyle, xOffset: Int, maxWidth: Int?)]) {
            guard currentY < bottomY else { return }
            for item in items {
                frame.write(item.text, at: TUIPoint(x: startX + item.xOffset, y: currentY), maxWidth: item.maxWidth ?? (contentWidth - item.xOffset), style: item.style)
            }
            currentY += 1
        }

        // 1. 会话摘要（固定顶栏，不随滚动滚动）
        writeLine("◈ 会话摘要", style: .sidebarHeader)
        let trimmedSummary = model.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryText = trimmedSummary.isEmpty ? "新会话" : trimmedSummary
        let summaryLines = TUIWrapping.lines(summaryText, width: contentWidth)
        for line in summaryLines.prefix(2) {
            writeLine(line.text, style: .composerText)
        }
        if currentY < bottomY { currentY += 1 } // 空行

        // 2. 缓存用量 (含 L1/L2/L3 及真实提供商 Prefix Cache 命中率)（固定常驻）
        if currentY < bottomY {
            writeLine("◈ 缓存用量", style: .sidebarHeader)
            if let prefix = model.prefixCache {
                let epochStr = prefix.cacheEpoch.map { " (Epoch \($0))" } ?? ""
                let bustRatioStr: String
                if let busts = prefix.clientCausedBusts, let total = prefix.comparableRequests, total > 0 {
                    bustRatioStr = " (\(busts)/\(total))"
                } else {
                    bustRatioStr = epochStr
                }
                if prefix.clientHealthStatus == "bustDetected" {
                    writeLine("结构前缀: 破坏 ⚠\(bustRatioStr)", style: .error)
                } else if prefix.clientHealthStatus == "stable" {
                    writeLine("结构前缀: 稳定 ✓\(bustRatioStr)", style: .sidebarLabel)
                }

                switch prefix.status {
                case "unavailable":
                    writeLine("前缀复用: 未提供 (Unavailable)", style: .dim)
                case "coldNewEpoch":
                    writeLine("前缀复用: 新代启始\(epochStr)", style: .sidebarLabel)
                    writeLine("[首轮建仓中 · 等待次轮复用]", style: .dim)
                default:
                    if let reuse = prefix.prefixReuseEfficiency {
                        let pct = String(format: "%.1f%%", reuse * 100.0)
                        let barTotalWidth = max(4, contentWidth)
                        let innerWidth = barTotalWidth - 2
                        let filledCount = min(innerWidth, max(0, Int(round(Double(innerWidth) * reuse))))
                        let emptyCount = innerWidth - filledCount
                        let barStr = "[" + String(repeating: "█", count: filledCount) + String(repeating: "░", count: emptyCount) + "]"
                        writeLine("前缀复用: \(pct)", style: .sidebarLabel)
                        writeLine(barStr, style: .sidebarProgressFill)

                        let prevStr = prefix.previousPromptTokens.map { TokenFormatter.format($0) } ?? "?"
                        let cachedStr = TokenFormatter.format(prefix.cachedTokens)
                        let inputSharePct = prefix.cachedInputShare.map { String(format: "%.1f%%", $0 * 100.0) } ?? "-"
                        let subDetail = "\(cachedStr)/\(prevStr) 可复用 · 输入占比 \(inputSharePct)"
                        writeLine(subDetail, style: .dim)
                    } else if let share = prefix.cachedInputShare {
                        let pct = String(format: "%.1f%%", share * 100.0)
                        let cacheText = "前缀命中: \(TokenFormatter.format(prefix.cachedTokens))/\(TokenFormatter.format(prefix.promptTokens)) (\(pct))"
                        writeLine(cacheText, style: .sidebarLabel)
                        let barTotalWidth = max(4, contentWidth)
                        let innerWidth = barTotalWidth - 2
                        let filledCount = min(innerWidth, max(0, Int(round(Double(innerWidth) * share))))
                        let emptyCount = innerWidth - filledCount
                        let barStr = "[" + String(repeating: "█", count: filledCount) + String(repeating: "░", count: emptyCount) + "]"
                        writeLine(barStr, style: .sidebarProgressFill)
                    }
                }
            }

            for layer in model.cacheLayers {
                let percent = String(format: "%.1f%%", layer.ratio * 100.0)
                let headerText = "\(layer.name): \(TokenFormatter.format(layer.usedTokens))/\(TokenFormatter.format(layer.capacityTokens)) (\(percent))"
                writeLine(headerText, style: .sidebarLabel)

                let barTotalWidth = max(4, contentWidth)
                let innerWidth = barTotalWidth - 2
                let filledCount = min(innerWidth, max(0, Int(round(Double(innerWidth) * layer.ratio))))
                let emptyCount = innerWidth - filledCount
                let barStr = "[" + String(repeating: "█", count: filledCount) + String(repeating: "░", count: emptyCount) + "]"
                writeLine(barStr, style: .sidebarProgressTrack)
            }
            if currentY < bottomY { currentY += 1 } // 空行
        }

        let remainingHeight = max(0, bottomY - currentY)
        guard remainingHeight >= 3 else { return }

        // 准备组件数据
        // 3. MCP 项
        var mcpRows: [[(text: String, style: TUIStyle, xOffset: Int, maxWidth: Int?)]] = []
        if model.mcpItems.isEmpty {
            mcpRows.append([("• 暂无激活 MCP", .dim, 0, contentWidth)])
        } else {
            for item in model.mcpItems {
                let (dotSymbol, dotStyle, labelStyle): (String, TUIStyle, TUIStyle) = {
                    switch item.status {
                    case .ready: return ("●", .sidebarMcpReady, .sidebarLabel)
                    case .empty: return ("○", .dim, .dim)
                    case .error: return ("✖", .sidebarMcpError, .error)
                    case .needsAuth: return ("?", .sidebarMcpAuth, .warning)
                    case .disabled: return ("○", .dim, .dim)
                    }
                }()
                let text = " \(item.id) (\(item.status.label))"
                mcpRows.append([
                    (dotSymbol, dotStyle, 0, 1),
                    (text, labelStyle, 1, contentWidth - 1)
                ])
            }
        }

        // 4. Tasks 项
        var taskRows: [[(text: String, style: TUIStyle, xOffset: Int, maxWidth: Int?)]] = []
        if model.tasks.isEmpty {
            taskRows.append([("• 暂无待办任务", .dim, 0, contentWidth)])
        } else {
            // 智能排序：优先展示进行中 (inProgress)，其次待办 (pending)，已完成与失败排在后方
            let sortedTasks = model.tasks.sorted { a, b in
                func rank(_ s: TUISidebarModel.TaskStatus) -> Int {
                    switch s {
                    case .inProgress: return 0
                    case .pending: return 1
                    case .failed: return 2
                    case .completed: return 3
                    }
                }
                return rank(a.status) < rank(b.status)
            }
            for task in sortedTasks {
                let (iconStyle, textStyle): (TUIStyle, TUIStyle) = {
                    switch task.status {
                    case .completed: return (.sidebarTaskCompleted, .dim)
                    case .inProgress: return (.sidebarTaskInProgress, .composerText)
                    case .pending: return (.sidebarTaskPending, .sidebarLabel)
                    case .failed: return (.sidebarTaskFailed, .error)
                    }
                }()
                let icon = task.status.icon
                let titleLines = TUIWrapping.lines(task.title, width: max(5, contentWidth - 3))
                let firstLine = titleLines.first?.text ?? task.title
                taskRows.append([
                    (icon, iconStyle, 0, 1),
                    (" \(firstLine)", textStyle, 1, contentWidth - 1)
                ])
                if titleLines.count > 1 {
                    let secondLine = titleLines[1].text
                    taskRows.append([
                        ("  \(secondLine)", textStyle, 0, contentWidth)
                    ])
                }
            }
        }

        let hasSubagents = !model.subagents.isEmpty
        let subagentReserve = hasSubagents ? min(3, max(1, remainingHeight / 4)) : 0
        let availableForMcpAndTasks = max(2, remainingHeight - subagentReserve)

        let mcpPreferred = min(mcpRows.count + 2, max(3, availableForMcpAndTasks / 2))
        let mcpAllocatedHeight = min(mcpPreferred, availableForMcpAndTasks - 2)

        // 渲染 MCP 组件（局部独立滚动）
        let mcpContentSlots = max(1, mcpAllocatedHeight - 1)
        let mcpTotalRows = mcpRows.count
        let mcpMaxScroll = max(0, mcpTotalRows - mcpContentSlots)
        let effectiveMcpScroll = max(0, min(model.mcpScrollOffset, mcpMaxScroll))
        let mcpScrollIndicator = mcpMaxScroll > 0 ? " [\(effectiveMcpScroll + 1)/\(mcpTotalRows)]" : ""
        writeLine("◈ MCP 工具 (\(model.mcpItems.count))\(mcpScrollIndicator)", style: .sidebarHeader)

        let visibleMcpRows = mcpRows.dropFirst(effectiveMcpScroll).prefix(mcpContentSlots)
        let mcpStartY = currentY
        for r in visibleMcpRows {
            writeRow(items: r)
        }
        // 局部微型滚动指示（仅在 MCP 区域内，绝不贯穿整个侧边栏）
        if mcpMaxScroll > 0 && mcpContentSlots >= 2 {
            let sbX = rect.x + rect.width - 1
            let thumb = min(mcpContentSlots - 1, max(0, Int(round(Double(effectiveMcpScroll) / Double(max(1, mcpMaxScroll)) * Double(mcpContentSlots - 1)))))
            for s in 0..<mcpContentSlots {
                frame.put(s == thumb ? "█" : "│", at: TUIPoint(x: sbX, y: mcpStartY + s), style: s == thumb ? .accent : .dim)
            }
        }

        if currentY < bottomY { currentY += 1 } // 空行

        // 渲染 Tasks 组件（局部独立滚动：默认限制最多显示 4 项保证排版呼吸感与美观，超出部分向下滚动）
        let taskRemainingAvailable = max(2, bottomY - currentY - subagentReserve)
        let maxVisibleTaskSlots = 4
        let taskContentSlots = min(maxVisibleTaskSlots, max(1, taskRemainingAvailable - 1))
        let taskTotalRows = taskRows.count
        let taskMaxScroll = max(0, taskTotalRows - taskContentSlots)
        let effectiveTaskScroll = max(0, min(model.taskScrollOffset > 0 ? model.taskScrollOffset : model.scrollOffset, taskMaxScroll))
        let taskScrollIndicator = taskMaxScroll > 0 ? " [\(effectiveTaskScroll + 1)/\(taskTotalRows)]" : ""
        writeLine("◈ 待办任务 (\(model.tasks.count))\(taskScrollIndicator)", style: .sidebarHeader)

        let visibleTaskRows = taskRows.dropFirst(effectiveTaskScroll).prefix(taskContentSlots)
        let taskStartY = currentY
        for r in visibleTaskRows {
            writeRow(items: r)
        }
        // 局部微型滚动指示（仅在 Tasks 区域内）
        if taskMaxScroll > 0 && taskContentSlots >= 2 {
            let sbX = rect.x + rect.width - 1
            let thumb = min(taskContentSlots - 1, max(0, Int(round(Double(effectiveTaskScroll) / Double(max(1, taskMaxScroll)) * Double(taskContentSlots - 1)))))
            for s in 0..<taskContentSlots {
                frame.put(s == thumb ? "█" : "│", at: TUIPoint(x: sbX, y: taskStartY + s), style: s == thumb ? .accent : .dim)
            }
        }

        // 渲染 Subagents（如果有空间且有活跃子代理）
        if hasSubagents && currentY + 1 < bottomY {
            currentY += 1
            writeLine("◈ 子代理 (\(model.subagents.count))", style: .sidebarHeader)
            for sub in model.subagents.prefix(bottomY - currentY) {
                let icon = sub.status.lowercased().contains("run") ? "⚡" : "•"
                let roleName = sub.role.isEmpty ? sub.id : sub.role
                let subText = "\(icon) \(roleName) (\(sub.status))"
                writeLine(subText, style: .sidebarLabel)
            }
        }
    }

    private func renderModalOverlay(_ overlay: TUIOverlayModel, in frame: inout TUIFrame, size: TUISize) {
        let modalWidth = min(size.width - 4, max(46, overlay.modalWidth ?? 64))
        let targetHeight = overlay.modalHeight ?? (overlay.lines.count + 2)
        let modalHeight = min(size.height - 4, max(8, targetHeight))
        let modalX = max(1, (size.width - modalWidth) / 2)
        let modalY = max(1, (size.height - modalHeight) / 3)
        let modalRect = TUIRect(x: modalX, y: modalY, width: modalWidth, height: modalHeight)

        frame.fill(modalRect, style: .modalBackground)
        frame.strokeBox(modalRect, style: .modalBorder, rounded: true)

        for (idx, line) in overlay.lines.prefix(max(0, modalHeight - 2)).enumerated() {
            let rowY = modalY + 1 + idx
            if line.style == .modalHighlight {
                for col in (modalX + 1)..<(modalX + modalWidth - 1) {
                    frame.put(" ", at: TUIPoint(x: col, y: rowY), style: .modalHighlight)
                }
            }
            frame.write(line.text, at: TUIPoint(x: modalX + 2, y: rowY), maxWidth: max(1, modalWidth - 4), style: line.style)
        }
        if let cursor = overlay.cursor {
            frame.cursor = TUIPoint(x: min(size.width - 1, modalX + 2 + cursor.x), y: min(size.height - 1, modalY + 1 + cursor.y))
        }
    }
}

public struct TUIOverlayModel: Sendable {
    public let lines: [TUIStyledLine]
    public let focus: TUIFocus
    public let isModal: Bool
    public let modalWidth: Int?
    public let modalHeight: Int?
    public let cursor: TUIPoint?

    public init(
        lines: [TUIStyledLine],
        focus: TUIFocus = .overlay,
        isModal: Bool = false,
        modalWidth: Int? = nil,
        modalHeight: Int? = nil,
        cursor: TUIPoint? = nil
    ) {
        self.lines = lines
        self.focus = focus
        self.isModal = isModal
        self.modalWidth = modalWidth
        self.modalHeight = modalHeight
        self.cursor = cursor
    }
}

public final class TUITimelineProjector: @unchecked Sendable {
    public private(set) var items: [TUITimelineItem] = []

    // Stable identity mappings
    private var streamItemIDs: [String: String] = [:]       // "streamID:kind" -> timelineItemID
    private var messageItemIDs: [MessageID: String] = [:]    // MessageID -> timelineItemID
    private var toolItemIDs: [ToolCallID: String] = [:]      // ToolCallID -> timelineItemID
    private var subagentItemIDs: [AgentRunID: String] = [:]  // AgentRunID -> timelineItemID
    private var activeThinkingItemID: String?
    private var activeAssistantItemID: String?
    private var thinkingStepCount: Int = 0
    private var activeErrorItemID: String?
    private var nextSequence: UInt64 = 0

    public init(items: [TUITimelineItem] = []) {
        self.items = items
    }

    public static func isShortResult(_ details: [String]) -> Bool {
        let lines = details.reduce(0) { $0 + $1.split(separator: "\n", omittingEmptySubsequences: false).count }
        let totalChars = details.reduce(0) { $0 + $1.count }
        return lines <= 6 && totalChars <= 400
    }

    public func reset() {
        items.removeAll()
        streamItemIDs.removeAll()
        messageItemIDs.removeAll()
        toolItemIDs.removeAll()
        subagentItemIDs.removeAll()
        activeThinkingItemID = nil
        activeAssistantItemID = nil
        thinkingStepCount = 0
        activeErrorItemID = nil
        nextSequence = 0
    }

    // MARK: - Streaming Chunks

    public func consume(chunk: StreamChunk) {
        switch chunk.kind {
        case .reasoning:
            if let activeID = activeThinkingItemID, let index = items.firstIndex(where: { $0.id == activeID }) {
                let existing = items[index].details.first ?? ""
                items[index].details = [existing + chunk.text]
            } else {
                thinkingStepCount += 1
                let id = "thinking-\(chunk.agentRunID?.rawValue ?? chunk.sessionID?.rawValue ?? "s")-step-\(thinkingStepCount)"
                activeThinkingItemID = id
                append(TUITimelineItem(
                    id: id,
                    kind: .thinking,
                    title: "Thinking #\(thinkingStepCount)",
                    summary: "",
                    details: [chunk.text],
                    state: .running,
                    collapsed: false,
                    parentID: chunk.agentRunID?.rawValue
                ))
            }

        case .text:
            // When assistant output starts, auto-complete & collapse the current thinking item
            if let activeThinkingID = activeThinkingItemID, let index = items.firstIndex(where: { $0.id == activeThinkingID }) {
                items[index].state = .completed
                items[index].collapsed = true
                activeThinkingItemID = nil
            }

            if let activeID = activeAssistantItemID, let index = items.firstIndex(where: { $0.id == activeID }) {
                items[index].summary += chunk.text
                items[index].details = [] // Never duplicate summary in details
            } else {
                let id = "assistant-\(chunk.agentRunID?.rawValue ?? chunk.sessionID?.rawValue ?? "s")-\(chunk.streamID.rawValue)"
                activeAssistantItemID = id
                append(TUITimelineItem(
                    id: id,
                    kind: .assistant,
                    title: "Assistant",
                    summary: chunk.text,
                    details: [],
                    state: .running,
                    collapsed: false,
                    parentID: chunk.agentRunID?.rawValue
                ))
            }
        }
    }

    // MARK: - Turn Events

    public func consume(turnCompleted result: TurnResult) {
        if let activeThinkingID = activeThinkingItemID, let index = items.firstIndex(where: { $0.id == activeThinkingID }) {
            items[index].state = .completed
            items[index].collapsed = true
            activeThinkingItemID = nil
        }

        if let activeAssistantID = activeAssistantItemID, let index = items.firstIndex(where: { $0.id == activeAssistantID }) {
            items[index].state = .completed
            messageItemIDs[result.assistantMessageID] = items[index].id
            activeAssistantItemID = nil
        }
        activeErrorItemID = nil
    }

    public func consume(turnFailed failure: TurnFailure) {
        if let activeThinkingID = activeThinkingItemID, let index = items.firstIndex(where: { $0.id == activeThinkingID }) {
            items[index].state = .failed
            activeThinkingItemID = nil
        }
        if let activeAssistantID = activeAssistantItemID, let index = items.firstIndex(where: { $0.id == activeAssistantID }) {
            items[index].state = .failed
            activeAssistantItemID = nil
        }
        recordError(message: failure.error.message, code: failure.error.code.rawValue)
    }

    public func consume(streamFailed message: String) {
        recordError(message: message, code: nil)
    }

    // MARK: - Tool Events

    public func consume(toolCall: ToolCall) {
        // A provider step ends at the tool boundary; finalize active thinking and assistant items
        if let activeThinkingID = activeThinkingItemID, let index = items.firstIndex(where: { $0.id == activeThinkingID }) {
            items[index].state = .completed
            items[index].collapsed = true
            activeThinkingItemID = nil
        }
        if let activeAssistantID = activeAssistantItemID, let index = items.firstIndex(where: { $0.id == activeAssistantID }) {
            items[index].state = .completed
            activeAssistantItemID = nil
        }
        for id in streamItemIDs.values {
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].state = .completed
                items[index].collapsed = true
            }
        }
        streamItemIDs.removeAll()
        let id = "tool-\(toolCall.callID.rawValue)"
        toolItemIDs[toolCall.callID] = id
        let title = formatToolCallTitle(toolCall)
        let kind = timelineKind(for: toolCall.toolID.rawValue)
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].state = .running
            items[index].title = title
            items[index].details = [toolCall.arguments]
            return
        }
        append(TUITimelineItem(
            id: id,
            kind: kind,
            title: title,
            summary: "Running...",
            details: [toolCall.arguments],
            state: .running,
            collapsed: false
        ))
    }

    public func consume(toolResult result: ToolResult) {
        let id = toolItemIDs[result.callID] ?? "tool-\(result.callID.rawValue)"
        let state: TUITimelineState = result.success ? .completed : .failed
        let summary = formatToolResultSummary(result)
        let details = makeToolDetails(result, existingArguments: items.first(where: { $0.id == id })?.details.first)
        let isShort = Self.isShortResult(details)
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].state = state
            items[index].summary = summary
            items[index].details = details
            items[index].collapsed = !isShort
            return
        }
        let kind = timelineKind(for: result.toolName ?? "tool")
        append(TUITimelineItem(
            id: id,
            kind: kind,
            title: formatToolTitle(result),
            summary: summary,
            details: details,
            state: state,
            collapsed: !isShort
        ))
    }

    public func consume(toolOutput: ToolOutputChunk) {
        let id = toolOutput.toolCallID.flatMap { toolItemIDs[$0] } ?? toolOutput.toolCallID.map { "tool-\($0.rawValue)" }
        guard let id, let index = items.firstIndex(where: { $0.id == id }) else { return }
        let prefix = toolOutput.stream == .stderr ? "stderr: " : ""
        items[index].details.append(prefix + toolOutput.payload)
        items[index].state = .running
    }

    // MARK: - Persisted Messages (Session loading / recovery)

    public func consume(persistedMessages messages: [SessionMessageSnapshot]) {
        for message in messages {
            if message.role == .assistant, let existingID = messageItemIDs[message.id], items.contains(where: { $0.id == existingID }) {
                // Already presented via streaming! Do not duplicate!
                continue
            }
            for (partIndex, part) in message.parts.enumerated() {
                switch part {
                case let .text(text):
                    let id = "message-\(message.id.rawValue)-text-\(partIndex)"
                    if message.role == .assistant { messageItemIDs[message.id] = id }
                    if !items.contains(where: { $0.id == id }) {
                        append(TUITimelineItem(
                            id: id,
                            kind: message.role == .user ? .user : .assistant,
                            title: message.role == .user ? "User" : "Assistant",
                            summary: text,
                            details: [],
                            state: .completed
                        ))
                    }
                case let .toolCall(call):
                    let id = "tool-\(call.callID.rawValue)"
                    toolItemIDs[call.callID] = id
                    if let index = items.firstIndex(where: { $0.id == id }) {
                        items[index].title = formatToolCallTitle(call)
                    } else {
                        append(TUITimelineItem(
                            id: id,
                            kind: timelineKind(for: call.toolID.rawValue),
                            title: formatToolCallTitle(call),
                            summary: "Running...",
                            details: [call.arguments],
                            state: .running,
                            collapsed: true
                        ))
                    }
                case let .toolResult(result):
                    let id = toolItemIDs[result.callID] ?? "tool-\(result.callID.rawValue)"
                    let state: TUITimelineState = result.success ? .completed : .failed
                    let summary = formatToolResultSummary(result)
                    let details = makeToolDetails(result, existingArguments: items.first(where: { $0.id == id })?.details.first)
                    let isShort = Self.isShortResult(details)
                    if let index = items.firstIndex(where: { $0.id == id }) {
                        items[index].state = state
                        items[index].summary = summary
                        items[index].details = details
                        items[index].collapsed = !isShort
                    } else {
                        append(TUITimelineItem(
                            id: id,
                            kind: timelineKind(for: result.toolName ?? "tool"),
                            title: formatToolTitle(result),
                            summary: summary,
                            details: details,
                            state: state,
                            collapsed: !isShort
                        ))
                    }
                }
            }
        }
    }

    // MARK: - User Input & General Appends

    public func appendUserMessage(_ text: String) {
        let id = "user-\(UUID().uuidString.prefix(8))"
        append(TUITimelineItem(
            id: id,
            kind: .user,
            title: "User",
            summary: text,
            details: [],
            state: .completed
        ))
    }

    public func appendItem(_ item: TUITimelineItem) {
        append(item)
    }

    // MARK: - Error Deduplication & Projection

    public func recordError(message: String, code: String? = nil) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let activeID = activeErrorItemID, let index = items.firstIndex(where: { $0.id == activeID }) {
            // Already showing an active error item for this turn; append diagnostics instead of creating duplicate error block
            if !items[index].details.contains(normalized) && items[index].summary != normalized {
                items[index].details.append(normalized)
            }
            return
        }
        if let last = items.last, last.kind == .error {
            // Last item is already an error item; merge into it
            if !last.details.contains(normalized) && last.summary != normalized {
                items[items.count - 1].details.append(normalized)
            }
            return
        }

        let userTitle: String
        let userSummary: String
        if let code, code == "mcpToolLeaseMissing" || normalized.contains("leaseMissing") {
            userTitle = "Tool failed"
            userSummary = "leaseMissing"
        } else if normalized.contains("status=400") {
            userTitle = "Provider failed"
            userSummary = "HTTP 400"
        } else if let code {
            userTitle = "Error: \(code)"
            userSummary = normalized.components(separatedBy: "\n").first ?? normalized
        } else {
            userTitle = "Error"
            userSummary = normalized.components(separatedBy: "\n").first ?? normalized
        }

        let details = normalized.components(separatedBy: "\n").filter { !$0.isEmpty }
        let id = "error-\(UUID().uuidString.prefix(8))"
        activeErrorItemID = id
        append(TUITimelineItem(
            id: id,
            kind: .error,
            title: userTitle,
            summary: userSummary,
            details: details,
            state: .failed,
            collapsed: true
        ))
    }

    // MARK: - Subagent Runs

    public func consume(agentRun: AgentRunInfo) {
        let id = "subagent-\(agentRun.runID.rawValue)"
        subagentItemIDs[agentRun.runID] = id
        let summary = "\(agentRun.title ?? agentRun.runID.rawValue) · \(agentRun.status.rawValue)"
        let details = ["parent: \(agentRun.parentRunID?.rawValue ?? "root")", "root: \(agentRun.rootRunID.rawValue)"]
        let state: TUITimelineState = switch agentRun.status {
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .waitingForUser, .waitingForTool: .warning
        default: .running
        }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].title = summary
            items[index].summary = summary
            items[index].details = details
            items[index].state = state
        } else {
            append(TUITimelineItem(
                id: id,
                kind: .subagent,
                title: summary,
                summary: summary,
                details: details,
                state: state,
                collapsed: true,
                parentID: agentRun.parentRunID?.rawValue
            ))
        }
    }

    // MARK: - Helpers

    private func timelineKind(for toolName: String) -> TUITimelineKind {
        switch toolName {
        case "read_file", "list_directory": .tool
        case "edit_file", "apply_patch": .edit
        case "write_file": .write
        case "shell", "process": .shell
        case "git": .git
        case "question": .question
        case "subagent": .subagent
        case "search_tools", "load_tool": .mcp
        default: .tool
        }
    }

    private func append(_ item: TUITimelineItem) {
        nextSequence += 1
        items.append(TUITimelineItem(id: item.id, sequence: TimelineSequence(rawValue: nextSequence), kind: item.kind, title: item.title, summary: item.summary, details: item.details, state: item.state, collapsed: item.collapsed, parentID: item.parentID))
    }

    private func formatToolCallTitle(_ call: ToolCall) -> String {
        let name = call.toolID.rawValue
        guard let data = call.arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return name
        }
        switch name {
        case "glob":
            if let pattern = dict["pattern"] as? String {
                let path = dict["path"] as? String
                return path != nil && path != "." ? "Glob \(path!)/\(pattern)" : "Glob \(pattern)"
            }
            return "Glob"
        case "read_file":
            if let path = dict["path"] as? String { return "Read \(path)" }
            return "Read"
        case "list_directory":
            if let path = dict["path"] as? String { return "ListDirectory \(path)" }
            return "ListDirectory"
        case "write_file":
            if let path = dict["path"] as? String { return "Write \(path)" }
            return "Write"
        case "edit_file":
            if let path = dict["path"] as? String { return "Edit \(path)" }
            return "Edit"
        case "apply_patch":
            if let path = dict["path"] as? String { return "Patch \(path)" }
            return "Patch"
        case "grep":
            if let pattern = dict["pattern"] as? String { return "Grep \"\(pattern)\"" }
            return "Grep"
        case "shell":
            if let command = dict["command"] as? String { return "Shell $ \(command)" }
            return "Shell"
        case "search_tools":
            if let query = dict["query"] as? String, !query.isEmpty { return "Search Tools \"\(query)\"" }
            return "Search Tools"
        case "load_tool":
            if let tool = (dict["tool_id"] as? String) ?? (dict["toolId"] as? String) { return "Load Tool \(tool)" }
            return "Load Tool"
        default:
            return name
        }
    }

    private func formatToolTitle(_ result: ToolResult) -> String {
        let name = result.toolName ?? "tool"
        switch name {
        case "glob": return "Glob"
        case "read_file": return "Read"
        case "list_directory": return "ListDirectory"
        case "write_file": return "Write"
        case "edit_file": return "Edit"
        case "apply_patch": return "Patch"
        case "grep": return "Grep"
        case "shell": return "Shell"
        case "search_tools": return "Search Tools"
        case "load_tool": return "Load Tool"
        default: return name
        }
    }

    private func formatToolResultSummary(_ result: ToolResult) -> String {
        guard result.success else {
            return result.error.map { "Failed: \($0.message)" } ?? "Failed"
        }
        let tool = (result.toolName ?? "").lowercased()
        if tool == "glob" || tool == "grep" {
            if let data = result.content.data(using: .utf8),
               let list = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                return "\(list.count) matches"
            }
            if let data = result.content.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let total = dict["totalCount"] as? Int {
                let shown = dict["shownCount"] as? Int ?? total
                return total > shown ? "\(total) matches · showing \(shown)" : "\(total) matches"
            }
            if tool == "glob" {
                let lines = result.content.split(separator: "\n", omittingEmptySubsequences: true).count
                return "\(lines) matches"
            }
            return "0 matches"
        }
        if tool == "list_directory" {
            if let data = result.content.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let total = dict["totalCount"] as? Int {
                let shown = dict["shownCount"] as? Int ?? total
                return total > shown ? "\(total) entries · showing \(shown)" : "\(total) entries"
            }
            let lines = result.content.split(separator: "\n", omittingEmptySubsequences: true).count
            return "\(lines) entries"
        }
        if tool == "read_file" || tool == "read" {
            if let data = result.content.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let total = dict["totalCount"] as? Int {
                let shown = dict["shownCount"] as? Int ?? total
                return total > shown ? "\(total) lines · showing \(shown)" : "\(total) lines"
            }
            let lines = result.content.split(separator: "\n", omittingEmptySubsequences: false).count
            return "\(lines) lines"
        }
        if tool == "write_file" || tool == "write" {
            let files = result.changedFiles.joined(separator: ", ")
            return files.isEmpty ? "file written" : "wrote \(files)"
        }
        if tool == "edit_file" || tool == "edit" {
            let files = result.changedFiles.joined(separator: ", ")
            return files.isEmpty ? "file updated" : "updated \(files)"
        }
        if tool == "apply_patch" || tool == "patch" {
            if !result.summary.isEmpty { return result.summary }
            let count = result.changedFiles.count
            return count > 0 ? "applied patch to \(count) file(s)" : "applied patch"
        }
        if tool == "shell" || tool == "process" {
            let code = result.exitCode.map { "exit \($0)" } ?? "exit 0"
            let elapsed = result.timing.executionMilliseconds > 0 ? result.timing.executionMilliseconds : result.timing.milliseconds
            if elapsed > 0 {
                return "\(code) · \(String(format: "%.1fs", elapsed / 1000))"
            }
            return code
        }
        if tool == "search_tools" {
            if let data = result.content.data(using: .utf8),
               let list = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                return "\(list.count) tools found"
            }
            return "tools search completed"
        }
        if tool == "load_tool" {
            if let data = result.content.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let toolName = (dict["tool"] as? String) ?? (dict["provider_name"] as? String) {
                return "leased \(toolName)"
            }
            return "tool leased"
        }
        if !result.summary.isEmpty && !result.summary.contains("file operation") {
            return result.summary
        }
        return "Completed"
    }

    private func makeToolDetails(_ result: ToolResult, existingArguments: String? = nil) -> [String] {
        var details: [String] = []
        if let existingArguments, !existingArguments.isEmpty { details.append("arguments: \(existingArguments)") }
        if let command = result.diagnostics?.command { details.append("$ \(command)") }
        if let exitCode = result.exitCode { details.append("exit \(exitCode)") }
        if result.timing.milliseconds > 0 { details.append(String(format: "duration %.1fs", result.timing.milliseconds / 1000)) }
        details.append(contentsOf: result.changedFiles.map { "file: \($0)" })
        let tool = (result.toolName ?? "").lowercased()
        if (tool == "list_directory" || tool == "glob" || tool == "grep") && !result.content.isEmpty {
            if let data = result.content.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let total = dict["totalCount"] as? Int {
                let shown = dict["shownCount"] as? Int ?? total
                details.append("Showing \(shown) of \(total)")
                if let lines = dict["lines"] as? [String] {
                    details.append(contentsOf: lines.prefix(10))
                } else if let items = dict["items"] as? [String] {
                    details.append(contentsOf: items.prefix(10))
                }
            } else {
                let lines = result.content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                if lines.count > 10 {
                    details.append("Showing 10 of \(lines.count)")
                    details.append(contentsOf: lines.prefix(10))
                } else {
                    details.append(contentsOf: lines)
                }
            }
        } else if !result.content.isEmpty {
            details.append(contentsOf: result.content.split(separator: "\n", omittingEmptySubsequences: false).prefix(20).map(String.init))
        }
        if let error = result.error { details.append("\(error.code): \(error.message)") }
        return details
    }
}
