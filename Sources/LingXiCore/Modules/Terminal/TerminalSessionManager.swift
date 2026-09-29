import Foundation
import LingXiPlatform
import LingXiProtocol

/// Owns the terminal sessions a front end may show: the Agent's live processes
/// and the user's own interactive shells.
///
/// A session ends when its process ends, the user closes it, the workspace
/// closes, or Core exits. Collapsing a panel, switching rails or rebuilding a
/// view is none of those, which is why this lives in Core and not in a view.
public actor TerminalSessionManager {

    private struct UserShell {
        let id: String
        let handle: any PtyHandle
        let program: String
        let cwd: URL
        let startedAt: Date
    }

    /// Output kept per read so a slow front end cannot grow memory without bound.
    private static let maxOutputCharacters = 120_000

    private let background: BackgroundCommandManager
    private let workspaceRoot: URL?
    private let pty: any PlatformPtyProtocol
    private var shells: [String: UserShell] = [:]
    private var shellOrder: [String] = []
    private var agentCursors: [String: (stdout: Int, stderr: Int)] = [:]

    public init(background: BackgroundCommandManager, workspaceRoot: URL?,
                pty: any PlatformPtyProtocol = LingXiPlatform.pty) {
        self.background = background
        self.workspaceRoot = workspaceRoot
        self.pty = pty
    }

    // MARK: - Listing

    public func sessions() async -> [TerminalSessionInfo] {
        var result: [TerminalSessionInfo] = []
        for snapshot in await background.list() {
            let owner = await background.taskOwner(id: snapshot.id)
            result.append(TerminalSessionInfo(
                id: snapshot.id,
                kind: .agent,
                title: snapshot.description ?? snapshot.command,
                cwd: snapshot.cwd,
                state: Self.state(of: snapshot.status),
                pid: snapshot.pid.map(Int.init),
                exitCode: snapshot.exitCode.map(Int.init),
                ownerSessionID: owner?.sessionID?.rawValue,
                ownerRunID: owner?.runID?.rawValue,
                startedAt: snapshot.startedAt,
                // A running pipe process accepts stdin; a finished one does not.
                supportsInput: snapshot.status == .running,
                // Nothing is attached to a terminal, so there is no Ctrl-C to raise.
                supportsInterrupt: false))
        }
        for id in shellOrder {
            guard let shell = shells[id] else { continue }
            let closed = shell.handle.isClosed()
            result.append(TerminalSessionInfo(
                id: shell.id,
                kind: .user,
                title: shell.program,
                cwd: shell.cwd.path,
                state: closed ? .exited : .running,
                pid: Int(shell.handle.pid),
                exitCode: closed ? shell.handle.exitCode().map(Int.init) : nil,
                startedAt: shell.startedAt,
                supportsInput: !closed,
                supportsInterrupt: !closed))
        }
        return result
    }

    // MARK: - User shells

    public func spawnShell(cwd: String?, columns: Int?, rows: Int?) async throws -> TerminalSessionInfo {
        let root = Self.resolve(cwd: cwd, fallback: workspaceRoot)
        let program = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var environment = EnvironmentSanitizer.sanitized()
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        environment["SHELL"] = program
        let handle = try pty.spawn(command: Self.arguments(forShell: program), cwd: root,
                                   environment: environment,
                                   columns: columns ?? 80, rows: rows ?? 24)
        let shell = UserShell(id: "shell-\(String(UUID().uuidString.prefix(8)).lowercased())",
                              handle: handle, program: program, cwd: root, startedAt: Date())
        shells[shell.id] = shell
        shellOrder.append(shell.id)
        return TerminalSessionInfo(id: shell.id, kind: .user, title: program, cwd: root.path,
                                   state: .running, pid: Int(handle.pid), startedAt: shell.startedAt,
                                   supportsInput: true, supportsInterrupt: true)
    }

    /// Interactive, but without job control: the session has no controlling
    /// terminal, and monitor mode would only produce warnings the user cannot act on.
    private static func arguments(forShell program: String) -> [String] {
        switch (program as NSString).lastPathComponent {
        case "zsh", "ksh", "ash", "dash": [program, "-i", "+m"]
        default: [program, "-i"]
        }
    }

    private static func resolve(cwd: String?, fallback: URL?) -> URL {
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            return URL(fileURLWithPath: cwd)
        }
        return fallback ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    // MARK: - Reading and writing

    public func read(sessionID: String, columns: Int?, rows: Int?) async throws -> TerminalSessionOutput {
        if let shell = shells[sessionID] {
            if let columns, let rows { shell.handle.resize(columns: columns, rows: rows) }
            let incoming = shell.handle.drain()
            let finished = shell.handle.isClosed()
            if finished { shell.handle.close() }
            let text = String(decoding: incoming ?? Data(), as: UTF8.self)
            return TerminalSessionOutput(sessionID: sessionID, text: Self.bounded(text),
                                         state: finished ? .exited : .running,
                                         exitCode: finished ? shell.handle.exitCode().map(Int.init) : nil)
        }
        let cursors = agentCursors[sessionID] ?? (stdout: 0, stderr: 0)
        let snapshot = try await background.poll(id: sessionID, stdoutCursor: cursors.stdout,
                                                 stderrCursor: cursors.stderr)
        agentCursors[sessionID] = (snapshot.stdoutCursor, snapshot.stderrCursor)
        let text = snapshot.stdout + (snapshot.stderr.isEmpty ? "" : snapshot.stderr)
        return TerminalSessionOutput(sessionID: sessionID, text: Self.bounded(text),
                                     state: Self.state(of: snapshot.status), exitCode: snapshot.exitCode.map(Int.init))
    }

    public func write(sessionID: String, text: String) async throws {
        if let shell = shells[sessionID] {
            guard !shell.handle.isClosed() else {
                throw CoreError(code: .processNotRunning, message: "这个 shell 会话已经退出")
            }
            shell.handle.write(Data(text.utf8))
            return
        }
        _ = try await background.input(id: sessionID, text: text)
    }

    public func interrupt(sessionID: String) async throws {
        guard let shell = shells[sessionID] else {
            throw CoreError(code: .processNotRunning,
                            message: "Agent 进程没有连接终端，无法发送中断；可以终止它")
        }
        guard !shell.handle.isClosed() else {
            throw CoreError(code: .processNotRunning, message: "这个 shell 会话已经退出")
        }
        shell.handle.interrupt()
    }

    /// Ends a session permanently. Panel visibility is not this.
    public func close(sessionID: String) async throws {
        if let shell = shells[sessionID] {
            shell.handle.terminate()
            shell.handle.close()
            shells[sessionID] = nil
            shellOrder.removeAll { $0 == sessionID }
            return
        }
        _ = try await background.terminate(id: sessionID)
        agentCursors[sessionID] = nil
    }

    public func closeAll() async {
        for shell in shells.values {
            shell.handle.terminate()
            shell.handle.close()
        }
        shells.removeAll()
        shellOrder.removeAll()
        agentCursors.removeAll()
    }

    public func shellCount() -> Int { shells.count }

    private static func state(of status: BackgroundTaskStatus) -> TerminalSessionState {
        switch status {
        case .running: .running
        case .exited: .exited
        case .timedOut: .timedOut
        case .terminated: .terminated
        }
    }

    private static func bounded(_ text: String) -> String {
        text.count > maxOutputCharacters ? String(text.suffix(maxOutputCharacters)) : text
    }
}
