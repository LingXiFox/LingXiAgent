import Foundation
import LingXiProtocol
import LingXiApplication
import LingXiPlatform
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
#endif

/// `lingxiagent serve`: boots the real Core through the shared composition root and
/// hands its FrontendRuntime to an HTTP + SSE bridge, then blocks until stopped so the
/// usual teardown (`.disconnect` -> CoreHost process tree reaped) still runs.
public enum ServeCLI {
    public static func run(options: WebUIServeOptions) async throws {
        if !options.isLoopbackHost && !options.allowRemote {
            throw CoreError(
                code: .permissionDenied,
                message: """
                Refusing to bind \(options.host): an agent controller that can run commands and edit \
                files must not be exposed off-loopback by accident. \
                Re-run with --allow-remote (a per-session token will then be required).
                """
            )
        }

        let terminal = WebUITerminal()
        installSignalHandlers(terminal: terminal)
        try await AppCompositionRoot(configuration: options.applicationConfiguration())
            .launch(with: WebUIFrontend(options: options, terminal: terminal))
    }

    /// Ctrl-C must tear the web server down rather than kill the process mid-flight,
    /// otherwise the CoreHost child would be left behind.
    private static func installSignalHandlers(terminal: WebUITerminal) {
        let signals: [Int32] = [SIGINT, SIGTERM]
        var hits = 0
        let counter = NSLock()
        for signalNumber in signals {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                counter.lock()
                hits += 1
                let count = hits
                counter.unlock()
                if count == 1 {
                    terminal.stop(reason: "signal \(signalNumber)")
                } else {
                    FileHandle.standardError.write(Data("\nForcing exit.\n".utf8))
                    _exit(130)
                }
            }
            source.resume()
            retainedSources.append(source)
        }
    }

    private static var retainedSources: [DispatchSourceSignal] = []

    static func openDefaultBrowser(url: String) {
        let process = Process()
        #if canImport(Darwin)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        #elseif os(Windows)
        process.executableURL = URL(fileURLWithPath: "cmd.exe")
        process.arguments = ["/c", "start", "", url]
        #else
        // `xdg-open` has to be resolved the way every other executable is, through the
        // platform adapter: the finder is a static API, and PATH plus the known system
        // locations differ per platform.
        guard let opener = LingXiPlatform.process.resolveExecutable(named: "xdg-open", customSearchPaths: nil) else {
            return
        }
        process.executableURL = URL(fileURLWithPath: opener)
        process.arguments = [url]
        #endif
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// The WebUI as a first-class Frontend: identical contract to the TUI and the GUI.
final class WebUIFrontend: Frontend, @unchecked Sendable {
    private let options: WebUIServeOptions
    private let terminal: WebUITerminal
    private var server: WebUIServer?

    init(options: WebUIServeOptions, terminal: WebUITerminal) {
        self.options = options
        self.terminal = terminal
    }

    @MainActor
    func run(with runtime: any FrontendRuntime) async throws {
        let server = try WebUIServer(runtime: runtime, options: options)
        self.server = server
        do {
            try await server.start(terminal: terminal)
        } catch {
            server.stop()
            throw error
        }
        renderBanner(options: options, server: server)

        if options.openBrowser {
            ServeCLI.openDefaultBrowser(url: server.baseURL)
        }

        await terminal.waitUntilStopped()
        server.stop()
        if let reason = terminal.reason {
            FileHandle.standardError.write(Data("🦊 [serve] stopped (\(reason))\n".utf8))
        }
    }

    private func renderBanner(options: WebUIServeOptions, server: WebUIServer) {
        var lines: [String] = []
        lines.append("🦊 LingXiAgent WebUI")
        lines.append("   URL      \(server.baseURL)")
        lines.append("   Bind     \(options.host):\(server.port)"
            + (options.isLoopbackHost ? "  (loopback only)" : "  (REMOTE — token required)"))
        lines.append("   Core     stdio CoreHost · workspace \(FileManager.default.currentDirectoryPath)")
        if !options.isLoopbackHost {
            lines.append("   Token    \(server.token)")
        }
        lines.append("   Stop     Ctrl-C")
        // FileHandle, not print(): stdout is block-buffered when piped, and an operator
        // reading the address through `tee` or a service manager must see it immediately.
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
