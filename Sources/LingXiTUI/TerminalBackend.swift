import Darwin
import Foundation
import LingXiTUIComponents

protocol TerminalBackend: AnyObject, Sendable {
    var size: TUISize { get }
    func start() throws
    func stop()
    func nextInput() -> TUIInputEvent?
    func render(_ frame: TUIFrame)
}

final class POSIXTerminalBackend: TerminalBackend, @unchecked Sendable {
    private var original: termios?
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
        var state = termios()
        guard tcgetattr(STDIN_FILENO, &state) == 0 else { throw POSIXError(.EIO) }
        debug("start.tcgetattr.done")
        original = state
        cfmakeraw(&state)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &state) == 0 else { throw POSIXError(.EIO) }
        updateSize()
        debug("start.size width=\(size.width) height=\(size.height)")
        debug("start.renderer.create.begin")
        openTUI = try OpenTUIRenderer(width: size.width, height: size.height)
        debug("start.renderer.create.end")
        if let bufferSize = openTUI?.nextBufferSize() {
            debug("start.buffer size=\(bufferSize.width)x\(bufferSize.height)")
        }
        if !noAltScreen {
            debug("start.terminal.setup.begin")
            openTUI?.setupTerminal()
            debug("start.terminal.setup.end")
        }
        debug("start.mouse.enable.begin")
        openTUI?.enableMouse()
        debug("start.mouse.enable.end")
        // 启用扩展鼠标坐标与拖拽追踪（1000h+1002h+1006h），禁用自动换行（7l）
        FileHandle.standardOutput.write(Data("\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?7l".utf8))
    }

    func stop() {
        debug("stop.begin")
        // 恢复终端鼠标模式与自动换行
        FileHandle.standardOutput.write(Data("\u{1B}[?1002l\u{1B}[?1000l\u{1B}[?1006l\u{1B}[?7h".utf8))
        openTUI?.disableMouse()
        if !noAltScreen {
            openTUI?.restoreTerminalModes()
        }
        openTUI = nil
        if let original {
            var state = original
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &state)
        }
        debug("stop.end")
    }

    func nextInput() -> TUIInputEvent? {
        // OpenTUI 0.5.10 exposes terminal output/rendering, but no stdin event
        // decoder. Keep the POSIX parser as the source of TUIInputEvent.
        updateSize()
        if size != lastSize {
            lastSize = size
            return .resize(size)
        }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let result = Darwin.poll(&descriptor, 1, 20)
        if result == 0 { return nil }
        guard result > 0, descriptor.revents & Int16(POLLIN) != 0 else { return nil }
        guard let byte = readByte() else { return nil }
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

    func render(_ frame: TUIFrame) {
        guard let renderer = openTUI else { return }
        renderCount += 1
        if renderCount <= 3 {
            debug("render.begin count=\(renderCount) size=\(frame.size.width)x\(frame.size.height) cells=\(frame.cells.count)")
        }
        renderer.resize(width: frame.size.width, height: frame.size.height)
        renderer.clear()
        for row in 0..<frame.size.height {
            for column in 0..<frame.size.width {
                let cell = frame.cells[row * frame.size.width + column]
                if cell.continuation { continue }
                let style = color(for: cell.style)
                let fg = cell.customForeground.map { OpenTUIColorValue(red: UInt16($0.r) * 257, green: UInt16($0.g) * 257, blue: UInt16($0.b) * 257) } ?? style.foreground
                let bg = cell.customBackground.map { OpenTUIColorValue(red: UInt16($0.r) * 257, green: UInt16($0.g) * 257, blue: UInt16($0.b) * 257) } ?? style.background
                renderer.draw(String(cell.character), x: column, y: row,
                              foreground: fg, background: bg)
            }
        }
        renderer.setCursor(frame.cursor)
        let result = renderer.render(force: renderCount == 1)
        if renderCount <= 3 {
            debug("render.end count=\(renderCount) nativeResult=\(result)")
        }
    }

    private func updateSize() {
        var window = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0 else { return }
        size = TUISize(width: max(40, Int(window.ws_col)), height: max(12, Int(window.ws_row)))
    }

    private func readByte() -> UInt8? {
        var byte: UInt8 = 0
        guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
        return byte
    }

    private func readByte(after milliseconds: Int32) -> UInt8? {
        guard waitForInput(milliseconds: milliseconds) else { return nil }
        return readByte()
    }

    private func waitForInput(milliseconds: Int32) -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return Darwin.poll(&descriptor, 1, milliseconds) > 0 && descriptor.revents & Int16(POLLIN) != 0
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
        guard waitForInput(milliseconds: 40), let second = readByte() else { return .escape }
        switch second {
        case 91: break // CSI '['
        case 79: // SS3 'O' (macOS and application cursor mode: \eOA, \eOB, \eOC, \eOD, \eOH, \eOF)
            guard waitForInput(milliseconds: 40), let third = readByte() else { return .escape }
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
        while waitForInput(milliseconds: 40), let byte = readByte() {
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
        while waitForInput(milliseconds: 40), let byte = readByte() {
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
        func rgb(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> OpenTUIColorValue {
            OpenTUIColorValue(red: red * 257, green: green * 257, blue: blue * 257)
        }

        // 赛博极光星夜狐美学调色板 (基于 泠溪 (LingXi Fox) 原画提炼：曜石暗夜、极光薄荷青、梦幻樱落紫、软萌樱粉)
        let pageBg = rgb(19, 17, 28)              // #13111C 深邃纯净曜石暗夜底板 (彻底消灭灰泥浑浊感，通透高级)
        let cardBg = rgb(30, 27, 41)              // #1E1B29 晶体曜紫卡片底板 (与底板拉开清晰对比)
        let textWarm = rgb(248, 250, 252)         // #F8FAFC 珍珠雪夜白文字 (银白紫发灵感，极高清晰度与对比度)
        let textDim = rgb(148, 144, 166)          // #9490A6 暮霭星云紫灰 (副文本层次分明不刺眼)
        let auroraCyan = rgb(78, 236, 210)        // #4EECD2 极光薄荷青 (机能服荧光标、YOLO闪电、构建模式、成功状态)
        let dreamLavender = rgb(192, 132, 252)    // #C084FC 梦幻樱落紫 (淡紫发梢与蓬松狐尾主色，Logo，思考徽章)
        let sakuraPink = rgb(244, 114, 182)       // #F472B6 狐耳软萌粉 (狐狸耳朵内侧软粉、爱心高光、活跃圆点)
        let cyberBlue = rgb(56, 189, 248)         // #38BDF8 赛博电光天蓝 (命令调用、工具高亮、进行中任务)
        let amberGold = rgb(251, 191, 36)         // #FBBF24 温暖琥珀金 (Tip提示、授权分组)
        let coralRed = rgb(248, 113, 113)         // #F87171 珊瑚赤红 (错误警报、拒绝状态)
        let cardBorder = rgb(59, 53, 77)          // #3B354D 优雅紫晶微光边框
        let selectedBg = rgb(49, 43, 66)          // #312B42 选中高亮底色

        switch style {
        case .normal: return OpenTUIStyle(foreground: textWarm, background: pageBg)
        case .dim: return OpenTUIStyle(foreground: textDim, background: pageBg)
        case .accent: return OpenTUIStyle(foreground: dreamLavender, background: pageBg)
        case .inverse: return OpenTUIStyle(foreground: pageBg, background: textWarm)
        case .composer: return OpenTUIStyle(foreground: textWarm, background: cardBg)
        case .composerText: return OpenTUIStyle(foreground: textWarm, background: cardBg)
        case .composerPlaceholder: return OpenTUIStyle(foreground: textDim, background: cardBg)
        case .overlay: return OpenTUIStyle(foreground: textWarm, background: cardBg)
        case .overlayTitle: return OpenTUIStyle(foreground: dreamLavender, background: cardBg)
        case .overlayItem: return OpenTUIStyle(foreground: textWarm, background: cardBg)
        case .overlayItemDim: return OpenTUIStyle(foreground: textDim, background: cardBg)
        case .overlayHighlight: return OpenTUIStyle(foreground: rgb(19, 17, 28), background: sakuraPink)
        case .warning: return OpenTUIStyle(foreground: amberGold, background: pageBg)
        case .error: return OpenTUIStyle(foreground: coralRed, background: pageBg)
        case .modalTitle: return OpenTUIStyle(foreground: textWarm, background: cardBg)
        case .modalGroup: return OpenTUIStyle(foreground: amberGold, background: cardBg)
        case .modalHighlight: return OpenTUIStyle(foreground: rgb(19, 17, 28), background: sakuraPink)
        case .modalActiveDot: return OpenTUIStyle(foreground: sakuraPink, background: cardBg)
        case .modalItem: return OpenTUIStyle(foreground: textWarm, background: cardBg)
        case .modalItemDim: return OpenTUIStyle(foreground: textDim, background: cardBg)
        case .modalBackground: return OpenTUIStyle(foreground: textWarm, background: cardBg)
        case .modalBorder: return OpenTUIStyle(foreground: cardBorder, background: cardBg)
        case .modalSearchPlaceholder: return OpenTUIStyle(foreground: textDim, background: cardBg)
        case .selected: return OpenTUIStyle(foreground: textWarm, background: selectedBg)
        case .heroLogo: return OpenTUIStyle(foreground: dreamLavender, background: pageBg)
        case .heroBoxBg: return OpenTUIStyle(foreground: textWarm, background: cardBg)
        case .heroBoxBorder: return OpenTUIStyle(foreground: auroraCyan, background: cardBg)
        case .heroBoxPlaceholder: return OpenTUIStyle(foreground: textDim, background: cardBg)
        case .heroBoxText: return OpenTUIStyle(foreground: textWarm, background: cardBg)
        case .heroBoxMeta: return OpenTUIStyle(foreground: textDim, background: cardBg)
        case .heroMode: return OpenTUIStyle(foreground: auroraCyan, background: cardBg)
        case .heroTip: return OpenTUIStyle(foreground: amberGold, background: pageBg)
        case .sidebarHeader: return OpenTUIStyle(foreground: dreamLavender, background: pageBg)
        case .sidebarLabel: return OpenTUIStyle(foreground: textDim, background: pageBg)
        case .sidebarProgressFill: return OpenTUIStyle(foreground: auroraCyan, background: pageBg)
        case .sidebarProgressTrack: return OpenTUIStyle(foreground: textDim, background: pageBg)
        case .sidebarTaskPending: return OpenTUIStyle(foreground: textDim, background: pageBg)
        case .sidebarTaskInProgress: return OpenTUIStyle(foreground: cyberBlue, background: pageBg)
        case .sidebarTaskCompleted: return OpenTUIStyle(foreground: auroraCyan, background: pageBg)
        case .sidebarTaskFailed: return OpenTUIStyle(foreground: coralRed, background: pageBg)
        case .sidebarMcpReady: return OpenTUIStyle(foreground: auroraCyan, background: pageBg)
        case .sidebarMcpAuth: return OpenTUIStyle(foreground: amberGold, background: pageBg)
        case .sidebarMcpError: return OpenTUIStyle(foreground: coralRed, background: pageBg)
        case .toolDotSuccess: return OpenTUIStyle(foreground: auroraCyan, background: pageBg)
        case .toolDotActive: return OpenTUIStyle(foreground: cyberBlue, background: pageBg)
        case .toolDotError: return OpenTUIStyle(foreground: coralRed, background: pageBg)
        case .toolAction: return OpenTUIStyle(foreground: textWarm, background: pageBg)
        case .toolCommand: return OpenTUIStyle(foreground: cyberBlue, background: pageBg)
        case .toolArg: return OpenTUIStyle(foreground: sakuraPink, background: pageBg)
        case .toolTree: return OpenTUIStyle(foreground: textDim, background: pageBg)
        case .toolSubtext: return OpenTUIStyle(foreground: textDim, background: pageBg)
        case .toolDiffAdd: return OpenTUIStyle(foreground: auroraCyan, background: pageBg)
        case .toolDiffRemove: return OpenTUIStyle(foreground: coralRed, background: pageBg)
        case .toolDiffLine: return OpenTUIStyle(foreground: textDim, background: pageBg)
        case .thinkingHeader: return OpenTUIStyle(foreground: dreamLavender, background: pageBg)
        case .thinkingBody: return OpenTUIStyle(foreground: textDim, background: pageBg)
        case .assistantText: return OpenTUIStyle(foreground: textWarm, background: pageBg)
        case .badgeYolo: return OpenTUIStyle(foreground: auroraCyan, background: cardBg)
        case .badgeAsk: return OpenTUIStyle(foreground: dreamLavender, background: cardBg)
        case .mascotBody: return OpenTUIStyle(foreground: textWarm, background: pageBg)
        case .mascotEar: return OpenTUIStyle(foreground: sakuraPink, background: pageBg)
        case .mascotSpark: return OpenTUIStyle(foreground: auroraCyan, background: pageBg)
        case .mascotTag: return OpenTUIStyle(foreground: dreamLavender, background: pageBg)
        }
    }

    private func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["LINGXI_TUI_DEBUG"] == "1" else { return }
        let timestamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[\(timestamp)] [POSIXTerminalBackend] \(message)\n".utf8))
    }

}
