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
/// Win32 has no POSIX signal delivery: Ctrl-C, Ctrl-Break, closing the console, logging off and
/// shutting down all arrive through one callback. Returning true says "teardown started, do not
/// run the default ExitProcess underneath it"; a second event force-exits from inside
/// `requestTermination`. Typed as the SDK's own alias so the C calling convention is inferred
/// rather than spelled -- a plain Swift function is not a C function pointer.
private let consoleCtrlHandler: PHANDLER_ROUTINE? = { controlType in
    // 0 CTRL_C, 1 CTRL_BREAK, 2 CTRL_CLOSE, 5 CTRL_LOGOFF, 6 CTRL_SHUTDOWN.
    switch controlType {
    case 0, 1, 2, 5, 6:
        PlatformTermination.requestTermination()
        return true
    default:
        return false
    }
}
#endif
