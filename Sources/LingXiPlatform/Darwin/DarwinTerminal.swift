#if canImport(Darwin)
import Darwin
import Foundation

public final class DarwinTerminalAdapter: PlatformTerminalProtocol, @unchecked Sendable {
    public init() {}

    public func getTerminalDimensions() -> (columns: Int, rows: Int)? {
        var window = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0 else { return nil }
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
        let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
        guard result > 0, descriptor.revents & Int16(POLLIN) != 0 else { return nil }
        var byte: UInt8 = 0
        guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
        return byte
    }

    public func isInteractive() -> Bool {
        isatty(STDIN_FILENO) == 1
    }

    public func installSignalHandlers() {
        signal(SIGINT) { _ in
            var term = termios()
            if tcgetattr(STDIN_FILENO, &term) == 0 {
                term.c_lflag |= tcflag_t(ECHO | ICANON | ISIG)
                _ = tcsetattr(STDIN_FILENO, TCSANOW, &term)
            }
            FileHandle.standardError.write(Data("\n".utf8))
            _exit(130)
        }
        signal(SIGTERM) { _ in
            exit(143)
        }
    }

    public func readSecretLine(prompt: String) -> String? {
        FileHandle.standardError.write(Data(prompt.utf8))
        if isatty(STDIN_FILENO) == 1 {
            var original = termios()
            if tcgetattr(STDIN_FILENO, &original) == 0 {
                var raw = original
                raw.c_lflag &= ~tcflag_t(ECHO)
                raw.c_lflag |= tcflag_t(ISIG)
                _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
                defer {
                    var restore = original
                    _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
                    FileHandle.standardError.write(Data("\n".utf8))
                }
                return readLine(strippingNewline: true)
            }
        }
        return readLine(strippingNewline: true)
    }
}
#endif
