import Foundation

/// 跨平台纯 ANSI 软渲染终端（在任何未编译/未提供 OpenTUI 共享库的最小化环境下的健壮兜底）
public final class ANSIFallbackTerminal: Sendable {
    public init() {}

    /// 隐藏光标
    public func hideCursor() {
        FileHandle.standardOutput.write(Data("\u{1B}[?25l".utf8))
    }

    /// 显示光标
    public func showCursor() {
        FileHandle.standardOutput.write(Data("\u{1B}[?25h".utf8))
    }

    /// 清屏
    public func clearScreen() {
        FileHandle.standardOutput.write(Data("\u{1B}[2J\u{1B}[H".utf8))
    }

    /// 设置光标坐标 (1-indexed)
    public func setCursor(column: Int, row: Int) {
        FileHandle.standardOutput.write(Data("\u{1B}[\(row);\(column)H".utf8))
    }

    /// 输出带颜色的文字
    public func writeStyled(text: String, red: UInt8, green: UInt8, blue: UInt8) {
        let seq = "\u{1B}[38;2;\(red);\(green);\(blue)m\(text)\u{1B}[0m"
        FileHandle.standardOutput.write(Data(seq.utf8))
    }
}
