import Foundation
import LingXiTUIComponents
import LingXiPlatform

protocol TerminalBackend: AnyObject, Sendable {
    var size: TUISize { get }
    func start() throws
    func stop()
    func nextInput() -> TUIInputEvent?
    func render(_ frame: TUIFrame)
}

final class POSIXTerminalBackend: TerminalBackend, @unchecked Sendable {
    private var rawToken: Any?
    private var openTUI: OpenTUIRenderer?
    private(set) var size = TUISize(width: 80, height: 24)
    private var lastSize = TUISize(width: 80, height: 24)
    private var renderCount = 0
    private let noAltScreen: Bool

    init(noAltScreen: Bool = false) {
        self.noAltScreen = noAltScreen
    }

    func start() throws {
        debug("start.begin")
        rawToken = try LingXiPlatform.terminal.enableRawMode()
        debug("start.rawMode.done")
        updateSize()
        debug("start.size width=\(size.width) height=\(size.height)")
        debug("start.renderer.create.begin")
        openTUI = try? OpenTUIRenderer(width: size.width, height: size.height)
        debug("start.renderer.create.end (available: \(openTUI != nil))")
        if let bufferSize = openTUI?.nextBufferSize() {
            debug("start.buffer size=\(bufferSize.width)x\(bufferSize.height)")
        }
        if !noAltScreen {
            debug("start.terminal.setup.begin")
            if let openTUI {
                openTUI.setupTerminal()
            } else {
                FileHandle.standardOutput.write(Data("\u{1B}[?1049h\u{1B}[2J\u{1B}[H".utf8))
            }
            debug("start.terminal.setup.end")
        }
        debug("start.mouse.enable.begin")
        openTUI?.enableMouse()
        debug("start.mouse.enable.end")
        // 启用扩展鼠标坐标与点击/滚轮（1000h+1006h），启用 1002h 拖拽追踪以支持划选复制，明确关闭 1003h 全量移动避免 hover 时的事件洪泛
        FileHandle.standardOutput.write(Data("\u{1B}[?1003l\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?7l".utf8))
    }

    func stop() {
        debug("stop.begin")
        // 恢复终端鼠标模式与自动换行
        FileHandle.standardOutput.write(Data("\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?7h".utf8))
        openTUI?.disableMouse()
        if !noAltScreen {
            if let openTUI {
                openTUI.restoreTerminalModes()
            } else {
                FileHandle.standardOutput.write(Data("\u{1B}[?25h\u{1B}[?1049l".utf8))
            }
        }
        openTUI = nil
        if let token = rawToken {
            LingXiPlatform.terminal.restoreTerminalMode(token: token)
            rawToken = nil
        }
        debug("stop.end")
    }

    func nextInput() -> TUIInputEvent? {
        updateSize()
        if size != lastSize {
            lastSize = size
            return .resize(size)
        }
        guard let byte = readByte(after: 20) else { return nil }
        switch byte {
        case 3: return .interrupt
        case 4: return .quit
        case 20: return .cycleReasoningEffort
        case 23: return .deleteWordBackward
        case 8, 127: return .backspace
        case 9: return .tab
        case 16: return .commandPalette
        case 10, 13: return .enter
        case 27: return readEscapeSequence()
        default: return readUTF8Character(firstByte: byte).map(TUIInputEvent.character)
        }
    }

    private var previousFrame: TUIFrame?

    private struct CompiledRun {
        let text: String
        let startX: Int
        let fg: OpenTUIColorValue
        let bg: OpenTUIColorValue
    }
    private var rowRunsCache: [Int: [CompiledRun]] = [:]

    private func isRowEqual(_ row: Int, frameA: TUIFrame, frameB: TUIFrame) -> Bool {
        let width = frameA.size.width
        let startIdx = row * width
        let endIdx = startIdx + width
        guard startIdx >= 0, endIdx <= frameA.cells.count, endIdx <= frameB.cells.count else {
            return false
        }
        for col in 0..<width {
            if frameA.cells[startIdx + col] != frameB.cells[startIdx + col] {
                return false
            }
        }
        return true
    }

    private func compileRowRuns(row: Int, frame: TUIFrame) -> [CompiledRun] {
        var runs: [CompiledRun] = []
        var currentRun = ""
        var runStartX = 0
        var currentFg: OpenTUIColorValue?
        var currentBg: OpenTUIColorValue?

        func flushRun() {
            guard !currentRun.isEmpty, let fg = currentFg, let bg = currentBg else {
                currentRun.removeAll(keepingCapacity: true)
                return
            }
            runs.append(CompiledRun(text: currentRun, startX: runStartX, fg: fg, bg: bg))
            currentRun.removeAll(keepingCapacity: true)
        }

        let width = frame.size.width
        let rowStart = row * width
        for column in 0..<width {
            let cell = frame.cells[rowStart + column]
            if cell.continuation { continue }

            let style = color(for: cell.style)
            let fg = cell.customForeground.map { OpenTUIColorValue(red: UInt16($0.r) * 257, green: UInt16($0.g) * 257, blue: UInt16($0.b) * 257) } ?? style.foreground
            let bg = cell.customBackground.map { OpenTUIColorValue(red: UInt16($0.r) * 257, green: UInt16($0.g) * 257, blue: UInt16($0.b) * 257) } ?? style.background

            if fg == currentFg && bg == currentBg {
                currentRun.append(cell.character)
            } else {
                flushRun()
                currentFg = fg
                currentBg = bg
                runStartX = column
                currentRun.append(cell.character)
            }
        }
        flushRun()
        return runs
    }

    func render(_ frame: TUIFrame) {
        renderCount += 1
        let isSizeChanged = (previousFrame?.size != frame.size)
        let isFirstRender = (previousFrame == nil)
        let prev = previousFrame

        if isSizeChanged {
            openTUI?.resize(width: frame.size.width, height: frame.size.height)
            rowRunsCache.removeAll(keepingCapacity: true)
        }

        // 计算 Changed Rows
        var changedRows: [Int] = []
        changedRows.reserveCapacity(frame.size.height)

        if isFirstRender || isSizeChanged {
            changedRows = Array(0..<frame.size.height)
        } else if let prevFrame = prev {
            for row in 0..<frame.size.height {
                if !isRowEqual(row, frameA: frame, frameB: prevFrame) {
                    changedRows.append(row)
                }
            }
        }

        // 若整屏完全无可视变化且光标未移动，直接 skip
        if !isFirstRender && !isSizeChanged && changedRows.isEmpty && frame.cursor == prev?.cursor {
            TUIPerformanceMetrics.shared.recordSkippedFrame()
            return
        }

        // 记录指标
        TUIPerformanceMetrics.shared.recordFramePresent(
            changedRows: changedRows.count,
            changedCells: changedRows.count * frame.size.width
        )

        guard let renderer = openTUI else {
            // ANSI Fallback: Render row runs directly using standard TrueColor ANSI escape sequences
            var outputData = Data()
            for row in changedRows {
                rowRunsCache[row] = compileRowRuns(row: row, frame: frame)
                if let runs = rowRunsCache[row] {
                    let moveCursor = "\u{1B}[\(row + 1);1H"
                    outputData.append(Data(moveCursor.utf8))
                    for run in runs {
                        let fgR = UInt8(min(255, run.fg.red / 257))
                        let fgG = UInt8(min(255, run.fg.green / 257))
                        let fgB = UInt8(min(255, run.fg.blue / 257))
                        let bgR = UInt8(min(255, run.bg.red / 257))
                        let bgG = UInt8(min(255, run.bg.green / 257))
                        let bgB = UInt8(min(255, run.bg.blue / 257))
                        let seq = "\u{1B}[38;2;\(fgR);\(fgG);\(fgB)m\u{1B}[48;2;\(bgR);\(bgG);\(bgB)m\(run.text)\u{1B}[0m"
                        outputData.append(Data(seq.utf8))
                    }
                }
            }
            if let cursor = frame.cursor {
                let cursorSeq = "\u{1B}[\(cursor.y + 1);\(cursor.x + 1)H\u{1B}[?25h"
                outputData.append(Data(cursorSeq.utf8))
            } else {
                let hideSeq = "\u{1B}[?25l"
                outputData.append(Data(hideSeq.utf8))
            }
            if !outputData.isEmpty {
                FileHandle.standardOutput.write(outputData)
            }
            previousFrame = frame
            return
        }

        // 仅对发生变化的行重新编译 runs
        for row in changedRows {
            rowRunsCache[row] = compileRowRuns(row: row, frame: frame)
        }

        renderer.clear()

        // 提交所有行的 Runs 到 buffer（未改变的行直接复用编译好的 runs）
        for row in 0..<frame.size.height {
            if let runs = rowRunsCache[row] {
                for run in runs {
                    let isPureBlank = (run.bg.red == 0 && run.bg.green == 0 && run.bg.blue == 0) && run.text.allSatisfy { $0 == " " }
                    if !isPureBlank {
                        renderer.draw(run.text, x: run.startX, y: row, foreground: run.fg, background: run.bg)
                    }
                }
            }
        }

        renderer.setCursor(frame.cursor)
        let result = renderer.render(force: isFirstRender || isSizeChanged)
        previousFrame = frame
        if renderCount <= 3 {
            debug("render.end count=\(renderCount) changedRows=\(changedRows.count) nativeResult=\(result)")
        }
    }

    private func updateSize() {
        if let dims = LingXiPlatform.terminal.getTerminalDimensions() {
            size = TUISize(width: dims.columns, height: dims.rows)
        }
    }

    private func readByte(after milliseconds: Int32 = 0) -> UInt8? {
        LingXiPlatform.terminal.readByte(timeoutMilliseconds: milliseconds)
    }

    private func readUTF8Character(firstByte: UInt8) -> Character? {
        let length: Int
        switch firstByte {
        case 0..<0x80: length = 1
        case 0xC0..<0xE0: length = 2
        case 0xE0..<0xF0: length = 3
        case 0xF0..<0xF8: length = 4
        default: return nil
        }
        var bytes = [firstByte]
        for _ in 1..<length {
            guard let byte = readByte(after: 40) else { return nil }
            bytes.append(byte)
        }
        return String(data: Data(bytes), encoding: .utf8).flatMap { $0.first }
    }

    private func readEscapeSequence() -> TUIInputEvent {
        guard let second = readByte(after: 40) else { return .escape }
        switch second {
        case 10, 13: return .shiftEnter // Alt+Enter / Option+Enter (\e\r or \e\n)
        case 91: break // CSI '['
        case 79: // SS3 'O' (macOS and application cursor mode: \eOA, \eOB, \eOC, \eOD, \eOH, \eOF)
            guard let third = readByte(after: 40) else { return .escape }
            switch third {
            case 65: return .up
            case 66: return .down
            case 67: return .right
            case 68: return .left
            case 72: return .home
            case 70: return .end
            default: return .tick
            }
        case 93: return readControlString(terminatesWithBell: true) // OSC
        case 80, 88, 94, 95: return readControlString(terminatesWithBell: false) // DCS/SOS/PM/APC
        default: return .escape
        }
        var sequence: [UInt8] = []
        while let byte = readByte(after: 40) {
            sequence.append(byte)
            if byte >= 0x40, byte <= 0x7E { break }
            if sequence.count > 32 { break }
        }
        guard let final = sequence.last else { return .escape }
        let body = String(decoding: sequence.dropLast(), as: UTF8.self)
        if body.first == "<" {
            let parts = body.dropFirst().split(separator: ";")
            if parts.count >= 3,
               let button = Int(parts[0]),
               let x = Int(parts[1]),
               let y = Int(parts[2]) {
                let col = max(0, x - 1)
                let row = max(0, y - 1)
                if final == 77 { // 'M': press or drag
                    if button == 0 {
                        return .mouseDown(x: col, y: row)
                    } else if button == 32 || (button & 32) != 0 {
                        return .mouseDrag(x: col, y: row)
                    } else if button == 64 {
                        return .scrollUp
                    } else if button == 65 {
                        return .scrollDown
                    }
                } else if final == 109 { // 'm': release
                    if (button & 3) == 0 || button == 32 || (button & 32) != 0 {
                        return .mouseUp(x: col, y: row)
                    }
                }
            } else if let button = Int(parts.first ?? "") {
                if final == 77 || final == 109 {
                    if button == 64 { return .scrollUp }
                    if button == 65 { return .scrollDown }
                }
            }
            return .tick
        }
        switch final {
        case 90: return .shiftTab
        case 65: return .up
        case 66: return .down
        case 67: return .right
        case 68: return .left
        case 72: return .home
        case 70: return .end
        case 126:
            switch body {
            case "1": return .home
            case "3": return .delete
            case "4": return .end
            case "5": return .pageUp
            case "6": return .pageDown
            case "200": return readPaste()
            default: return .tick
            }
        case 117 where body.contains("2") && body.contains("13"): return .shiftEnter
        default: return .tick
        }
    }

    private func readControlString(terminatesWithBell: Bool) -> TUIInputEvent {
        var previous: UInt8 = 0
        var count = 0
        while count < 4096, let byte = readByte(after: 40) {
            count += 1
            if terminatesWithBell && byte == 7 { return .tick }
            if previous == 27 && byte == 92 { return .tick }
            previous = byte
        }
        return .tick
    }

    private func readPaste() -> TUIInputEvent {
        var bytes: [UInt8] = []
        let terminator = Array("\u{1B}[201~".utf8)
        while let byte = readByte(after: 40) {
            bytes.append(byte)
            if bytes.count >= terminator.count, bytes.suffix(terminator.count).elementsEqual(terminator) {
                bytes.removeLast(terminator.count)
                break
            }
        }
        return .paste(String(decoding: bytes, as: UTF8.self))
    }

    private struct OpenTUIStyle {
        let foreground: OpenTUIColorValue
        let background: OpenTUIColorValue
    }

    private func color(for style: TUIStyle) -> OpenTUIStyle {
        let pair = ThemeManager.shared.currentTheme.styleColor(for: style)
        return OpenTUIStyle(foreground: pair.foreground, background: pair.background)
    }

    private func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["LINGXI_TUI_DEBUG"] == "1" else { return }
        let timestamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[\(timestamp)] [POSIXTerminalBackend] \(message)\n".utf8))
    }

}
