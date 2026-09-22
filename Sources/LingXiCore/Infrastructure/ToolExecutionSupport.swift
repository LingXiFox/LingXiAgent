import Foundation
import LingXiProtocol
@_exported import LingXiPlatform

/// 子进程只继承运行命令所需的环境，避免把宿主机凭据传给工具。
public enum EnvironmentSanitizer {
    public static func sanitized(from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let envPath = environment["PATH"] ?? environment["Path"] ?? environment["path"]
        #if os(Windows)
        let defaultPath = "C:\\Windows\\System32;C:\\Windows;C:\\Windows\\System32\\Wbem;C:\\Windows\\System32\\WindowsPowerShell\\v1.0"
        #else
        let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
        #endif
        var result = [
            "PATH": envPath ?? defaultPath,
            "HOME": environment["HOME"] ?? environment["USERPROFILE"] ?? NSHomeDirectory(),
            "LANG": environment["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": environment["TMPDIR"] ?? environment["TEMP"] ?? environment["TMP"] ?? FileManager.default.temporaryDirectory.path,
        ]
        for (key, value) in environment where key.hasPrefix("LC_") || ["DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS"].contains(key) || key.hasPrefix("ALIBABA_CLOUD_") || key.hasPrefix("ALICLOUD_") {
            if key != "DEVELOPER_DIR" || FileManager.default.fileExists(atPath: value) {
                result[key] = value
            }
        }
        // The allow-list above intentionally excludes every LINGXI_* value, including test sentinels.
        for key in osBootstrapKeys {
            if let entry = environment.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                result[key] = entry.value
            }
        }
        return result
    }

    /// A child process on Windows cannot boot without knowing where the OS lives: .NET and
    /// PowerShell fail to load their providers without SystemRoot, and nothing resolves an
    /// executable or a scratch directory without PATHEXT, COMSPEC and TEMP. None of these carry
    /// credentials, so they join the minimal environment rather than being stripped with it.
    /// They are absent on POSIX, which keeps that side of the sanitizer unchanged.
    public static let osBootstrapKeys = [
        "SystemRoot", "windir", "SystemDrive", "ProgramFiles", "ProgramFiles(x86)",
        "ProgramData", "CommonProgramFiles", "CommonProgramFiles(x86)",
        "USERPROFILE", "COMSPEC", "PATHEXT", "TEMP", "TMP", "LOCALAPPDATA", "APPDATA", "PSModulePath"
    ]
}

func sha256Hex(_ content: String) -> String {
    LingXiPlatform.crypto.sha256Hex(content)
}

/// Builds the invocation for a command the workspace profile asked to run, by asking the
/// platform adapter. Whether the policy can be honoured is the adapter's decision: platforms
/// with an enforcement mechanism throw when they cannot use it, which keeps the workspace
/// profile fail-closed there, while Windows has no mechanism at all and hands back a plain
/// invocation, so refusing it would make the profile unusable on a shipped platform.
func workspaceInvocation(executable: String, arguments: [String], policy: SandboxPolicy) throws -> ToolProcessInvocation {
    try LingXiPlatform.sandbox.invocation(executable: executable, arguments: arguments, policy: policy)
}

private func sandboxString(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
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
        defer { lock.unlock() }
        let requested = cursor ?? startCursor
        let offset = min(max(requested, startCursor), endCursor) - startCursor
        let slice = data.dropFirst(offset)
        let text = String(decoding: slice, as: UTF8.self)
        return PipeCursor(cursor: endCursor, text: text, truncated: cursor == nil ? startCursor > 0 : requested < startCursor)
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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    deinit {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    init(invocation: ToolProcessInvocation, cwd: URL, environment: [String: String], lifecycleTrace: ToolLifecycleTrace? = nil) {
        self.lifecycleTrace = lifecycleTrace
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        #if os(Windows)
        let outHandle = output.fileHandleForReading
        let errHandle = error.fileHandleForReading
        Task { [weak self, stdout] in
            do {
                for try await chunk in LingXiPlatform.lineReader.dataChunks(from: outHandle) {
                    stdout.append(chunk)
                }
            } catch {}
            self?.markEOF(phase: .stdoutEOF)
        }
        Task { [weak self, stderr] in
            do {
                for try await chunk in LingXiPlatform.lineReader.dataChunks(from: errHandle) {
                    stderr.append(chunk)
                }
            } catch {}
            self?.markEOF(phase: .stderrEOF)
        }
        #else
        output.fileHandleForReading.readabilityHandler = { [weak self, stdout] handle in self?.read(handle, into: stdout, phase: .stdoutEOF) }
        error.fileHandleForReading.readabilityHandler = { [weak self, stderr] handle in self?.read(handle, into: stderr, phase: .stderrEOF) }
        #endif
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
        LingXiPlatform.process.terminateProcessTree(pid: process.processIdentifier, force: true)
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
                waiters.append(continuation)
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
        let drained = LingXiPlatform.process.nonblockingDrain(handle: handle, chunkSize: 64 * 1024)
        if !drained.isEmpty {
            buffer.append(drained)
        }
    }

    private func markEOF(phase: ToolLifecyclePhase) {
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

    private func read(_ handle: FileHandle, into buffer: ByteRingBuffer, phase: ToolLifecyclePhase) {
        let data = LingXiPlatform.process.readAvailable(handle: handle)
        if !data.isEmpty {
            buffer.append(data)
            return
        }
        handle.readabilityHandler = nil
        markEOF(phase: phase)
    }

    private func handleTermination(status: Int32) {
        let pid = process.processIdentifier
        
        #if !os(Windows)
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        #endif

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
        let pending = waiters
        waiters.removeAll()
        lock.unlock()

        lifecycleTrace?.record(.processExited, processPID: pid, exitCode: status)
        pending.forEach { $0.resume() }
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let output = try encoder.encode(managed.commandResult())
            throw CoreError(code: .commandTimedOut, message: String(decoding: output, as: UTF8.self))
        }
        return managed.commandResult()
    }, onCancel: {
        managed.terminate()
    })
}
