import CryptoKit
import Foundation
import LingXiProtocol

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
            result[key] = value
        }
        // The allow-list above intentionally excludes every LINGXI_* value, including test sentinels.
        return result
    }
}

func sha256Hex(_ content: String) -> String {
    SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
}

public enum ShellSandboxBackend: Sendable {
    case sandboxExec
    case unavailable

    public static func workspace() -> Self {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") ? .sandboxExec : .unavailable
    }

    func invocation(executable: String, arguments: [String], workspace: URL) throws -> ToolProcessInvocation {
        guard self == .sandboxExec else {
            throw CoreError(code: .sandboxUnavailable, message: "workspace shell 需要 macOS /usr/bin/sandbox-exec")
        }
        let roots = Set([
            workspace.path,
            workspace.resolvingSymlinksInPath().path,
            workspace.path.replacingOccurrences(of: "/private/var/", with: "/var/"),
            workspace.path.replacingOccurrences(of: "/var/", with: "/private/var/")
        ]).sorted().map { root in
            let path = sandboxString(root)
            return "(allow file-read* (subpath \"\(path)\"))\n(allow file-write* (subpath \"\(path)\"))"
        }.joined(separator: "\n")
        let profile = """
        (version 1)
        (deny default)
        (import \"system.sb\")
        (allow process-exec)
        (allow process-fork)
        (allow signal (target self))
        (allow file-read-metadata (subpath \"/\"))
        \(roots)
        (allow file-read* (literal \"\(sandboxString(executable))\"))
        (allow file-read* (literal \"/bin/sh\"))
        (allow file-read* (literal \"/private/var/select/sh\"))
        (allow file-read* (subpath \"/usr/lib\"))
        (allow file-read* (subpath \"/System/Library\"))
        (allow file-read* (subpath \"/Applications/Xcode.app\"))
        (allow file-read* (subpath \"/Library/Developer\"))
        """
        return ToolProcessInvocation(executable: "/usr/bin/sandbox-exec", arguments: ["-p", profile, executable] + arguments)
    }
}

private func sandboxString(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
}

struct ToolProcessInvocation: Sendable {
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
    private let lock = NSLock()
    private var didFinish = false
    private var didTimeOut = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(invocation: ToolProcessInvocation, cwd: URL, environment: [String: String]) {
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        output.fileHandleForReading.readabilityHandler = { [stdout] handle in stdout.append(handle.availableData) }
        error.fileHandleForReading.readabilityHandler = { [stderr] handle in stderr.append(handle.availableData) }
        process.terminationHandler = { [weak self] _ in self?.finish() }
    }

    func launch() throws {
        try process.run()
        try output.fileHandleForWriting.close()
        try error.fileHandleForWriting.close()
    }

    func terminate(timedOut: Bool = false) {
        lock.lock()
        didTimeOut = didTimeOut || timedOut
        let running = process.isRunning
        lock.unlock()
        if running { process.terminate() }
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
        CommandResult(exitCode: process.terminationStatus, stderr: stderr.value(after: nil).text, stdout: stdout.value(after: nil).text)
    }

    func snapshot(id: String, stdoutCursor: Int?, stderrCursor: Int?) -> ProcessStatus {
        ProcessStatus(
            id: id,
            running: process.isRunning,
            exitCode: process.isRunning ? nil : process.terminationStatus,
            stdout: stdout.value(after: stdoutCursor),
            stderr: stderr.value(after: stderrCursor)
        )
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeOut
    }

    private func finish() {
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        stdout.append(output.fileHandleForReading.readDataToEndOfFile())
        stderr.append(error.fileHandleForReading.readDataToEndOfFile())
        lock.lock()
        didFinish = true
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume()
    }
}

func runToolProcess(
    invocation: ToolProcessInvocation,
    cwd: URL,
    environment: [String: String],
    timeoutMilliseconds: Int?,
    standardInput: String? = nil
) async throws -> CommandResult {
    let managed = ManagedToolProcess(invocation: invocation, cwd: cwd, environment: environment)
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
        if managed.timedOut { throw CoreError(code: .commandTimedOut, message: "命令超过 \(timeoutMilliseconds ?? 0)ms 限制") }
        return managed.commandResult()
    }, onCancel: {
        managed.terminate()
    })
}
