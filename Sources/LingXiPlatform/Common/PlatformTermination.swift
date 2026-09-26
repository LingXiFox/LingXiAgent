import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
#endif

/// "The operator asked this process to stop", as one API over three mechanisms.
///
/// The terminal request is delivered once; a second request ends the process immediately,
/// because a teardown that is stuck must still be escapable. Business code (the serve CLI)
/// asks for a stop and never inspects the operating system.
public enum PlatformTermination {
    private static let lock = NSLock()
    private static var onRequest: (() -> Void)?
    nonisolated(unsafe) private static var hits = 0

    public static func installHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        onRequest = handler
        lock.unlock()
        #if os(Windows)
        SetConsoleCtrlHandler(consoleCtrlHandler, true)
        #else
        installSignalSources()
        #endif
    }

    /// Called by the platform mechanism, on whatever thread the OS chose.
    static func requestTermination() {
        lock.lock()
        hits += 1
        let count = hits
        let handler = onRequest
        lock.unlock()
        guard count == 1 else {
            FileHandle.standardError.write(Data("\nForcing exit.\n".utf8))
            _exit(130)
        }
        handler?()
    }
}

#if !os(Windows)
private var retainedSignalSources: [DispatchSourceSignal] = []

private func installSignalSources() {
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { PlatformTermination.requestTermination() }
        source.resume()
        retainedSignalSources.append(source)
    }
}
#endif

#if os(Windows)
/// Win32 has no POSIX signal delivery: a console Ctrl-C, a window close and a logoff all come
/// through one handler, and returning `true` means "cleanup started, stay alive for it".
private func consoleCtrlHandler(_ controlType: DWORD) -> Bool {
    switch controlType {
    case DWORD(CTRL_C_EVENT), DWORD(CTRL_BREAK_EVENT),
         DWORD(CTRL_CLOSE_EVENT), DWORD(CTRL_LOGOFF_EVENT), DWORD(CTRL_SHUTDOWN_EVENT):
        PlatformTermination.requestTermination()
        return true
    default:
        return false
    }
}
#endif
