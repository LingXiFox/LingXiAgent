#if os(Windows)
import Foundation
import WinSDK

public final class WindowsTerminalAdapter: PlatformTerminalProtocol, @unchecked Sendable {
    public init() {}

    public func getTerminalDimensions() -> (columns: Int, rows: Int)? {
        let handle = GetStdHandle(STD_OUTPUT_HANDLE)
        guard handle != INVALID_HANDLE_VALUE else { return nil }
        var info = CONSOLE_SCREEN_BUFFER_INFO()
        guard GetConsoleScreenBufferInfo(handle, &info) else { return nil }
        let cols = Int(info.srWindow.Right - info.srWindow.Left + 1)
        let rows = Int(info.srWindow.Bottom - info.srWindow.Top + 1)
        return (columns: max(40, cols), rows: max(12, rows))
    }

    public func enableRawMode() throws -> Any? {
        let inHandle = GetStdHandle(STD_INPUT_HANDLE)
        let outHandle = GetStdHandle(STD_OUTPUT_HANDLE)
        guard inHandle != INVALID_HANDLE_VALUE, outHandle != INVALID_HANDLE_VALUE else { return nil }

        var inMode: DWORD = 0
        var outMode: DWORD = 0
        GetConsoleMode(inHandle, &inMode)
        GetConsoleMode(outHandle, &outMode)

        let original = (inMode: inMode, outMode: outMode)

        // 开启输出 VT 处理 (0x0004)
        SetConsoleMode(outHandle, outMode | 0x0004)

        // 开启输入 VT (0x0200)，关闭行缓冲与回显 (ENABLE_LINE_INPUT 0x0002, ENABLE_ECHO_INPUT 0x0004)
        let rawInMode = (inMode & ~DWORD(0x0002 | 0x0004)) | 0x0200
        SetConsoleMode(inHandle, rawInMode)

        return original
    }

    public func restoreTerminalMode(token: Any?) {
        guard let (inMode, outMode) = token as? (inMode: DWORD, outMode: DWORD) else { return }
        let inHandle = GetStdHandle(STD_INPUT_HANDLE)
        let outHandle = GetStdHandle(STD_OUTPUT_HANDLE)
        if inHandle != INVALID_HANDLE_VALUE { SetConsoleMode(inHandle, inMode) }
        if outHandle != INVALID_HANDLE_VALUE { SetConsoleMode(outHandle, outMode) }
    }

    public func readByte(timeoutMilliseconds: Int32) -> UInt8? {
        // Windows 管道/输入流读取
        let handle = FileHandle.standardInput
        guard let byte = handle.availableData.first else { return nil }
        return byte
    }
}
#endif
