import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol
import LingXiPlatform

private let sandboxProfile: ExecutionProfile =
    LingXiPlatform.sandbox.capabilities.filesystemEnforced ? .workspace : .fullAccess

private func temporaryWorkspace() throws -> (URL, WorkspaceRoot) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-term-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (dir, try WorkspaceRoot(path: dir.path))
}

/// A PTY that answers on a schedule, so the manager's own decisions can be
/// judged without depending on a real shell's start-up files.
private final class ScriptedPty: PtyHandle, @unchecked Sendable {
    let pid: Int32 = 42_424
    private var output = Data("ready\n".utf8)
    private(set) var written: [String] = []
    private(set) var interrupts = 0
    private(set) var terminated = false
    private(set) var closedDescriptor = false

    func drain() -> Data? {
        if closedDescriptor { return nil }
        let ready = output
        output = Data()
        return ready
    }

    func write(_ data: Data) { written.append(String(decoding: data, as: UTF8.self)) }
    func resize(columns: Int, rows: Int) {}
    func interrupt() { interrupts += 1 }
    func terminate() { terminated = true }
    func isClosed() -> Bool { terminated || closedDescriptor }
    func exitCode() -> Int32? { terminated ? 0 : nil }
    func close() { closedDescriptor = true }
}

private struct ScriptedAdapter: PlatformPtyProtocol {
    let handle: ScriptedPty
    init(_ handle: ScriptedPty) { self.handle = handle }
    func spawn(command: [String], cwd: URL, environment: [String: String],
               columns: Int, rows: Int) throws -> any PtyHandle { handle }
}

@Suite("Terminal sessions are owned by Core", .serialized)
struct TerminalSessionTests {

    #if canImport(Darwin) || canImport(Glibc)
    @Test("A real pty carries bytes both ways and reports when the child exits")
    func ptyRoundTrip() async throws {
        let (root, _) = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let handle = try PosixPtyAdapter().spawn(command: ["/bin/cat"], cwd: root,
                                                 environment: ["PATH": "/usr/bin:/bin", "TERM": "dumb"],
                                                 columns: 80, rows: 24)
        defer { handle.close() }
        #expect(handle.pid > 0)

        handle.write(Data("lingxi-pty-echo\n".utf8))
        var seen = ""
        for _ in 0..<40 {
            seen += String(decoding: handle.drain() ?? Data(), as: UTF8.self)
            if seen.contains("lingxi-pty-echo") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        // The child echoes what it was given: the pipe is real, not simulated.
        #expect(seen.contains("lingxi-pty-echo"), "没有从伪终端读回内容: \(seen)")

        handle.terminate()
        #expect(handle.isClosed())
        #expect(handle.exitCode() != nil)
    }

    @Test("The requested size and working directory reach the shell, and the pty is its controlling terminal")
    func ptySizeCwdAndControllingTerminal() async throws {
        let (root, _) = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let handle = try PosixPtyAdapter().spawn(
            command: ["/bin/sh", "-c", "stty size; pwd -P; sleep 5; echo NOT-INTERRUPTED"], cwd: root,
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"], columns: 52, rows: 17)
        defer { handle.close() }
        var seen = ""
        for _ in 0..<40 {
            seen += String(decoding: handle.drain() ?? Data(), as: UTF8.self)
            if seen.contains(root.resolvingSymlinksInPath().lastPathComponent) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(seen.contains("17 52"), "shell 没拿到请求的窗口尺寸: \(seen)")
        #expect(seen.contains(root.resolvingSymlinksInPath().lastPathComponent), "cwd 没有生效: \(seen)")

        // ^C through the line discipline only signals anything when the pty is the
        // session's controlling terminal.
        handle.interrupt()
        for _ in 0..<40 where !handle.isClosed() {
            _ = handle.drain()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(handle.isClosed(), "^C 没有中断前台进程")
        #expect(handle.exitCode() == 130)
    }
    #endif

    @Test("An Agent process is projected as a session, without a fake interrupt")
    func agentSessionProjection() async throws {
        let (root, workspace) = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let background = BackgroundCommandManager()
        let manager = TerminalSessionManager(background: background, workspaceRoot: root)
        #expect(await manager.sessions().isEmpty)

        let runTool = RunBackgroundCommandTool(workspace: workspace, manager: background)
        _ = try await runTool.execute(
            arguments: #"{"command": "printf 'term-agent-line\\n'", "timeout_seconds": 30, "task_id": "term-agent-1"}"#,
            profile: sandboxProfile)

        let sessions = await manager.sessions()
        let agent = try #require(sessions.first { $0.id == "term-agent-1" })
        #expect(agent.kind == .agent)
        // Nothing is attached to a terminal, so there is no Ctrl-C to raise.
        #expect(agent.supportsInterrupt == false)
        #expect(agent.supportsInput == true)
        #expect(agent.cwd == root.path)

        // A pipe process accepts input but cannot be interrupted.
        await #expect(throws: (any Error).self) { try await manager.interrupt(sessionID: "term-agent-1") }

        var text = ""
        for _ in 0..<40 {
            let output = try await manager.read(sessionID: "term-agent-1", columns: nil, rows: nil)
            text += output.text
            if text.contains("term-agent-line") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(text.contains("term-agent-line"))

        _ = try await manager.close(sessionID: "term-agent-1")
        await background.terminateAll()
    }

    @Test("Reading a session never ends it; only an explicit close does")
    func userShellSurvivesEveryReadUntilClosed() async throws {
        let (root, _) = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let pty = ScriptedPty()
        let manager = TerminalSessionManager(background: BackgroundCommandManager(),
                                             workspaceRoot: root, pty: ScriptedAdapter(pty))
        let shell = try await manager.spawnShell(cwd: nil, columns: 80, rows: 24)
        #expect(shell.kind == .user)
        #expect(shell.supportsInterrupt == true)

        let first = try await manager.read(sessionID: shell.id, columns: nil, rows: nil)
        #expect(first.text.contains("ready"))
        #expect(first.state == .running)

        // Repeated polls — what a collapsed-and-reopened panel does — change nothing.
        for _ in 0..<3 {
            let again = try await manager.read(sessionID: shell.id, columns: 120, rows: 30)
            #expect(again.state == .running)
        }
        #expect(await manager.shellCount() == 1)

        try await manager.write(sessionID: shell.id, text: "echo hi\n")
        #expect(pty.written.contains("echo hi\n"))
        try await manager.interrupt(sessionID: shell.id)
        #expect(pty.interrupts == 1)

        try await manager.close(sessionID: shell.id)
        #expect(pty.terminated)
        #expect(await manager.sessions().isEmpty)
    }

    @Test("closeAll ends every shell, the way workspace teardown must")
    func closeAllEndsShells() async throws {
        let (root, _) = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TerminalSessionManager(background: BackgroundCommandManager(),
                                             workspaceRoot: root, pty: ScriptedAdapter(ScriptedPty()))
        _ = try await manager.spawnShell(cwd: nil, columns: nil, rows: nil)
        #expect(await manager.shellCount() == 1)
        await manager.closeAll()
        #expect(await manager.shellCount() == 0)
    }
}
