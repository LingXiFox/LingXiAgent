import CryptoKit
import Foundation
import LingXiProtocol
#if os(macOS)
import Darwin
#endif

/// 子进程只继承运行命令所需的环境，避免把宿主机凭据传给工具。
public enum EnvironmentSanitizer {
    public static func sanitized(from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = [
            "PATH": environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": environment["HOME"] ?? NSHomeDirectory(),
            "LANG": environment["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path,
        ]
        for (key, value) in environment where key.hasPrefix("LC_") || ["DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS"].contains(key) {
            if key != "DEVELOPER_DIR" || FileManager.default.fileExists(atPath: value) {
                result[key] = value
            }
        }
        // The allow-list above intentionally excludes every LINGXI_* value, including test sentinels.
        return result
    }
}

func sha256Hex(_ content: String) -> String {
    SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
}

public enum SandboxFilesystemAccess: Sendable, Equatable {
    case workspaceReadWrite
    case workspaceReadOnly
}

public enum SandboxNetworkAccess: Sendable, Equatable {
    case deny
    /// 当前 macOS backend 不能可靠表达 host allow-list，必须 fail closed。
    case allowHosts([String])
}

public struct SandboxPolicy: Sendable, Equatable {
    public let workspace: URL
    public let readOnlyPaths: [URL]
    public let filesystem: SandboxFilesystemAccess
    public let network: SandboxNetworkAccess
    public let allowSubprocesses: Bool

    public init(workspace: URL, readOnlyPaths: [URL] = [], filesystem: SandboxFilesystemAccess = .workspaceReadWrite, network: SandboxNetworkAccess = .deny, allowSubprocesses: Bool = true) {
        self.workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        self.readOnlyPaths = readOnlyPaths.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.filesystem = filesystem
        self.network = network
        self.allowSubprocesses = allowSubprocesses
    }
}

public struct SandboxCapabilities: Sendable, Equatable {
    public let filesystemEnforced: Bool
    public let networkEnforced: Bool
    public let processIsolationEnforced: Bool

    public init(filesystemEnforced: Bool, networkEnforced: Bool, processIsolationEnforced: Bool) {
        self.filesystemEnforced = filesystemEnforced
        self.networkEnforced = networkEnforced
        self.processIsolationEnforced = processIsolationEnforced
    }
}

public protocol SandboxExecutor: Sendable {
    var capabilities: SandboxCapabilities { get }
    func invocation(executable: String, arguments: [String], policy: SandboxPolicy) throws -> ToolProcessInvocation
}

/// macOS sandbox-exec backend。不能满足 policy 时绝不回退到未隔离 shell。
public enum ShellSandboxBackend: Sendable, SandboxExecutor {
    case sandboxExec
    case unavailable

    public static func workspace() -> Self {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") ? .sandboxExec : .unavailable
    }

    public var capabilities: SandboxCapabilities {
        switch self {
        case .sandboxExec: return SandboxCapabilities(filesystemEnforced: true, networkEnforced: true, processIsolationEnforced: false)
        case .unavailable: return SandboxCapabilities(filesystemEnforced: false, networkEnforced: false, processIsolationEnforced: false)
        }
    }

    public func invocation(executable: String, arguments: [String], policy: SandboxPolicy) throws -> ToolProcessInvocation {
        guard self == .sandboxExec else {
            throw CoreError(code: .sandboxUnavailable, message: "workspace shell 需要 macOS /usr/bin/sandbox-exec")
        }
        guard case .deny = policy.network else {
            throw CoreError(code: .sandboxUnavailable, message: "当前 sandbox backend 不支持可靠的 host allow-list")
        }
        let workspace = policy.workspace
        let roots = Set([
            workspace.path,
            workspace.resolvingSymlinksInPath().path,
            workspace.path.replacingOccurrences(of: "/private/var/", with: "/var/"),
            workspace.path.replacingOccurrences(of: "/var/", with: "/private/var/")
        ]).sorted().map { root in
            let path = sandboxString(root)
            let read = "(allow file-read* (subpath \"\(path)\"))"
            return policy.filesystem == .workspaceReadWrite ? read + "\n(allow file-write* (subpath \"\(path)\"))" : read
        }.joined(separator: "\n")
        let readOnlyRoots = Set(policy.readOnlyPaths.map(\.path)).sorted().map { root in
            "(allow file-read* (subpath \"\(sandboxString(root))\"))"
        }.joined(separator: "\n")
        let processRules = policy.allowSubprocesses ? "(allow process-exec)\n(allow process-fork)" : ""
        let trustedRoots = ["/usr/lib", "/System/Library", "/Applications/Xcode.app", "/Applications/Xcode-beta.app", "/Library/Developer", "/opt/homebrew"]
            .map { "(allow file-read* (subpath \"\(sandboxString($0))\"))" }
            .joined(separator: "\n")
        let profile = """
        (version 1)
        (deny default)
        (import \"system.sb\")
        (deny network*)
        \(processRules)
        (allow signal (target self))
        (allow file-read-metadata (subpath \"/\"))
        \(roots)
        \(readOnlyRoots)
        (allow file-read* (literal \"\(sandboxString(executable))\"))
        (allow file-read* (literal \"/bin/sh\"))
        (allow file-read* (literal \"/private/var/select/sh\"))
        \(trustedRoots)
        """
        return ToolProcessInvocation(executable: "/usr/bin/sandbox-exec", arguments: ["-p", profile, executable] + arguments)
    }

    func invocation(executable: String, arguments: [String], workspace: URL) throws -> ToolProcessInvocation {
        try invocation(executable: executable, arguments: arguments, policy: SandboxPolicy(workspace: workspace))
    }
}

private func sandboxString(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
}

public struct ToolProcessInvocation: Sendable {
    let executable: String
    let arguments: [String]
}

struct CommandResult: Codable, Sendable {
    let exitCode: Int32
    let stderr: String
    let stdout: String
}


struct PipeCursor: Codable, Sendable {
    let cursor: Int
    let text: String
    let truncated: Bool
}

struct ProcessStatus: Codable, Sendable {
    let id: String
    let pid: Int32?
    let running: Bool
    let exitCode: Int32?
    let stdout: PipeCursor
    let stderr: PipeCursor
}

private final class ByteRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var data = Data()
    private var startCursor = 0
    private var endCursor = 0

    init(capacity: Int) { self.capacity = capacity }

    func append(_ additional: Data) {
        guard !additional.isEmpty else { return }
        lock.lock()
        data.append(additional)
        endCursor += additional.count
        if data.count > capacity {
            let excess = data.count - capacity
            data.removeFirst(excess)
            startCursor += excess
        }
        lock.unlock()
    }

    func value(after cursor: Int?) -> PipeCursor {
        lock.lock()
        let requested = cursor ?? startCursor
        let offset = min(max(requested, startCursor), endCursor) - startCursor
        let output = Data(data.dropFirst(offset))
        let result = PipeCursor(cursor: endCursor, text: String(decoding: output, as: UTF8.self), truncated: cursor == nil ? startCursor > 0 : requested < startCursor)
        lock.unlock()
        return result
    }
}

final class ManagedToolProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private let stdout = ByteRingBuffer(capacity: 64 * 1_024)
    private let stderr = ByteRingBuffer(capacity: 64 * 1_024)
    private let lifecycleTrace: ToolLifecycleTrace?
    private let lock = NSLock()
    private var didFinish = false
    private var didTimeOut = false
    private var stdoutDidReachEOF = false
    private var stderrDidReachEOF = false
    private var processDidExit = false
    private var exitStatus: Int32?
    private var waiter: CheckedContinuation<Void, Never>?

    init(invocation: ToolProcessInvocation, cwd: URL, environment: [String: String], lifecycleTrace: ToolLifecycleTrace? = nil) {
        self.lifecycleTrace = lifecycleTrace
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        output.fileHandleForReading.readabilityHandler = { [weak self, stdout] handle in self?.read(handle, into: stdout, phase: .stdoutEOF) }
        error.fileHandleForReading.readabilityHandler = { [weak self, stderr] handle in self?.read(handle, into: stderr, phase: .stderrEOF) }
        process.terminationHandler = { [weak self] process in self?.handleTermination(status: process.terminationStatus) }
    }

    func launch() throws {
        try process.run()
        lifecycleTrace?.record(.processSpawned, processPID: process.processIdentifier)
        try output.fileHandleForWriting.close()
        try error.fileHandleForWriting.close()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3_600))
            self?.terminate(timedOut: true)
        }
    }

    func terminate(timedOut: Bool = false) {
        lock.lock()
        let running = process.isRunning
        didTimeOut = didTimeOut || (timedOut && running)
        lock.unlock()
        if running {
            process.terminate()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                self?.forceKillIfRunning()
            }
        }
    }

    private func forceKillIfRunning() {
        guard process.isRunning else { return }
        #if os(macOS)
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        #else
        process.terminate()
        #endif
    }

    func write(_ text: String) throws {
        guard process.isRunning else { throw CoreError(code: .processNotRunning, message: "进程未运行") }
        try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    }

    func closeInput() throws {
        try input.fileHandleForWriting.close()
    }

    func waitForExit() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didFinish {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func commandResult() -> CommandResult {
        let code = exitStatus ?? (process.isRunning ? 0 : process.terminationStatus)
        return CommandResult(exitCode: code, stderr: stderr.value(after: nil).text, stdout: stdout.value(after: nil).text)
    }

    func snapshot(id: String, stdoutCursor: Int?, stderrCursor: Int?) -> ProcessStatus {
        let running = !didFinish && process.isRunning
        let code = running ? nil : (exitStatus ?? process.terminationStatus)
        return ProcessStatus(
            id: id,
            pid: running ? process.processIdentifier : nil,
            running: running,
            exitCode: code,
            stdout: stdout.value(after: stdoutCursor),
            stderr: stderr.value(after: stderrCursor)
        )
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeOut
    }

    private func nonblockingDrain(handle: FileHandle, into buffer: ByteRingBuffer) {
        handle.readabilityHandler = nil
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return }
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            #if os(macOS)
            let bytesRead = Darwin.read(fd, &chunk, chunk.count)
            #else
            let bytesRead = Glibc.read(fd, &chunk, chunk.count)
            #endif
            if bytesRead > 0 {
                buffer.append(Data(chunk[0..<bytesRead]))
            } else {
                break
            }
        }
    }

    private func read(_ handle: FileHandle, into buffer: ByteRingBuffer, phase: ToolLifecyclePhase) {
        let data = handle.availableData
        if !data.isEmpty {
            buffer.append(data)
            return
        }
        handle.readabilityHandler = nil
        let shouldRecord: Bool
        let pid = process.processIdentifier
        let exitCode = exitStatus
        lock.lock()
        switch phase {
        case .stdoutEOF:
            shouldRecord = !stdoutDidReachEOF
            stdoutDidReachEOF = true
        case .stderrEOF:
            shouldRecord = !stderrDidReachEOF
            stderrDidReachEOF = true
        default:
            shouldRecord = false
        }
        let canFinish = processDidExit && stdoutDidReachEOF && stderrDidReachEOF
        lock.unlock()

        if shouldRecord { lifecycleTrace?.record(phase, processPID: pid, exitCode: exitCode) }
        if canFinish { finish() }
    }

    private func handleTermination(status: Int32) {
        let pid = process.processIdentifier
        
        // Concurrent bounded drain: immediately drain any remaining output non-blockingly.
        nonblockingDrain(handle: output.fileHandleForReading, into: stdout)
        nonblockingDrain(handle: error.fileHandleForReading, into: stderr)

        lock.lock()
        processDidExit = true
        exitStatus = status
        let needStdoutEOF = !stdoutDidReachEOF
        stdoutDidReachEOF = true
        let needStderrEOF = !stderrDidReachEOF
        stderrDidReachEOF = true
        lock.unlock()

        if needStdoutEOF { lifecycleTrace?.record(.stdoutEOF, processPID: pid, exitCode: status) }
        if needStderrEOF { lifecycleTrace?.record(.stderrEOF, processPID: pid, exitCode: status) }

        finish()
    }

    private func finish() {
        lock.lock()
        guard !didFinish else { lock.unlock(); return }
        guard processDidExit, stdoutDidReachEOF, stderrDidReachEOF else { lock.unlock(); return }
        didFinish = true
        let pid = process.processIdentifier
        let status = exitStatus ?? process.terminationStatus
        let continuation = waiter
        waiter = nil
        lock.unlock()

        lifecycleTrace?.record(.processExited, processPID: pid, exitCode: status)
        continuation?.resume()
    }
}

func runToolProcess(
    invocation: ToolProcessInvocation,
    cwd: URL,
    environment: [String: String],
    timeoutMilliseconds: Int?,
    standardInput: String? = nil,
    lifecycleTrace: ToolLifecycleTrace? = nil
) async throws -> CommandResult {
    let managed = ManagedToolProcess(invocation: invocation, cwd: cwd, environment: environment, lifecycleTrace: lifecycleTrace)
    try managed.launch()
    if let standardInput { try managed.write(standardInput) }
    try managed.closeInput()
    let watchdog = timeoutMilliseconds.map { milliseconds in
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + .milliseconds(milliseconds))
        timer.setEventHandler { [managed] in managed.terminate(timedOut: true) }
        timer.resume()
        return timer
    }
    defer { watchdog?.cancel() }
    return try await withTaskCancellationHandler(operation: {
        await managed.waitForExit()
        try Task.checkCancellation()
        if managed.timedOut {
            let output = try JSONEncoder().encode(managed.commandResult())
            throw CoreError(code: .commandTimedOut, message: String(decoding: output, as: UTF8.self))
        }
        return managed.commandResult()
    }, onCancel: {
        managed.terminate()
    })
}
