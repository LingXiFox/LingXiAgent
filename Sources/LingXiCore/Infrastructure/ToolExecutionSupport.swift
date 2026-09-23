import Foundation
import LingXiProtocol
@_exported import LingXiPlatform



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
        #if !os(macOS)
        // Linux and Windows share a reader path because Foundation's dispatch-source
        // `readabilityHandler` is unreliable on both:
        //   * Linux drops already-delivered events (see AsyncLineReader.swift:96-98)
        //     so bytes sit in the kernel pipe buffer until termination closes the
        //     fd, which loses the child's final writes;
        //   * Windows uses overlapped I/O and the handler path leaves the read fd
        //     in a state where `CancelIoEx` cannot unblock a wedged drain.
        // `AsyncLineReader.dataChunks` starts a dedicated Thread+poll reader on
        // Linux and a cancellable Task on Windows, both of which observe EOF
        // honestly and hand it back via `markEOF`.
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
        // An empty read means "nothing readable this instant" at least as often as it means end of
        // stream, and a child that writes and exits can still have its last line in flight. Unbinding
        // there loses that output, and the run then reports exit 0 with an empty payload -- the shape
        // `echo hello-lingxi` took on a macOS runner. EOF is only accepted once the child is gone;
        // until then the handler stays bound and reads whatever arrives next.
        if process.isRunning { return }
        handle.readabilityHandler = nil
        markEOF(phase: phase)
    }

    private func handleTermination(status: Int32) {
        let pid = process.processIdentifier
        #if os(macOS)
        // macOS still runs the readabilityHandler path. Unbind before Foundation
        // tears the fd down (a handler firing against a closed handle dies with no
        // Swift error to read), then do a bounded final drain and force-mark EOF.
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
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
        #else
        // Linux/Windows run a dedicated reader task that reports EOF on its own.
        // Force-marking it here would let finish() resume waiters while the reader
        // is still mid-`read` on the same fd, which is the exact shape that lost
        // the child's final bytes on Linux Foundation's dropped-event handler.
        // Record the exit and let markEOF trigger finish; a bounded fallback grabs
        // anything the reader misses (a wedged grandchild holding the write end).
        lock.lock()
        processDidExit = true
        exitStatus = status
        let alreadyAtEOF = stdoutDidReachEOF && stderrDidReachEOF
        lock.unlock()
        if alreadyAtEOF { finish() }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.readerFallback()
        }
        #endif
    }

    #if !os(macOS)
    /// Safety net for the Linux/Windows reader path: if the reader has not reported
    /// EOF within a short grace window after the child exits, drain once more and
    /// force-mark so `waitForExit` cannot hang on a wedged stream.
    private func readerFallback() {
        let pid = process.processIdentifier
        lock.lock()
        if didFinish { lock.unlock(); return }
        let needStdoutEOF = !stdoutDidReachEOF
        stdoutDidReachEOF = true
        let needStderrEOF = !stderrDidReachEOF
        stderrDidReachEOF = true
        let status = exitStatus ?? process.terminationStatus
        lock.unlock()
        nonblockingDrain(handle: output.fileHandleForReading, into: stdout)
        nonblockingDrain(handle: error.fileHandleForReading, into: stderr)
        if needStdoutEOF { lifecycleTrace?.record(.stdoutEOF, processPID: pid, exitCode: status) }
        if needStderrEOF { lifecycleTrace?.record(.stderrEOF, processPID: pid, exitCode: status) }
        finish()
    }
    #endif

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
