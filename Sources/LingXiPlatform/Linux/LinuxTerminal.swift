#if os(Linux) || canImport(Glibc)
#if canImport(Glibc)
import Glibc
#endif
import Foundation

public final class LinuxTerminalAdapter: PlatformTerminalProtocol, @unchecked Sendable {
    public init() {}

    public func getTerminalDimensions() -> (columns: Int, rows: Int)? {
        var window = winsize()
        #if canImport(Glibc)
        let res = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &window)
        guard res == 0 else { return nil }
        #else
        return nil
        #endif
        return (columns: max(40, Int(window.ws_col)), rows: max(12, Int(window.ws_row)))
    }

    public func enableRawMode() throws -> Any? {
        var state = termios()
        guard tcgetattr(STDIN_FILENO, &state) == 0 else { throw POSIXError(.EIO) }
        let original = state
        cfmakeraw(&state)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &state) == 0 else { throw POSIXError(.EIO) }
        return original
    }

    public func restoreTerminalMode(token: Any?) {
        guard var original = token as? termios else { return }
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
    }

    public func readByte(timeoutMilliseconds: Int32) -> UInt8? {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, timeoutMilliseconds)
        guard result > 0, descriptor.revents & Int16(POLLIN) != 0 else { return nil }
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
        return byte
    }
}
#endif
