import Darwin
import Foundation
import LingXiKernel
import LingXiPluginABI

/// One Plugin Host process and the single duplex pipe to it. Requests route by id, notifications
/// carry none, and every wait is a silence-bound deadline rather than a fixed sleep: the clock starts
/// at the last frame that actually arrived (IPC-004, LOOP-023).
public final class PluginProcess: @unchecked Sendable {
    public struct Termination: Sendable, Equatable {
        public let exitCode: Int32
        public let signal: Int32?
        public let stderrTail: String
    }

    public enum PluginProcessError: Error, Equatable {
        case notStarted
        case exited(Termination)
        case noReplyWithinDeadline(method: String, id: Int, stderrTail: String)
        case frameTooLarge
        case streamOverflow(requestID: String)
    }

    private let process = Process()
    private let toHost = Pipe()
    private let fromHost = Pipe()
    private let hostErr = Pipe()
    private let lock = NSLock()

    private var replies: [Int: HostReply] = [:]
    private var notices: [String] = []
    private var streams: [String: PluginProcess.Subscription] = [:]
    private var terminated: Termination?
    private var started = false
    private var stderrRing: [UInt8] = []
    private var nextID = 1

    public let executableURL: URL
    /// Called exactly once when the host exits, for any reason.
    public var onTermination: (@Sendable (Termination) -> Void)?
    private let clock: any MonotonicClock

    public init(executableURL: URL, clock: any MonotonicClock = SystemMonotonicClock()) {
        self.executableURL = executableURL
        self.clock = clock
    }

    deinit {
        terminate()
    }

    public func start() throws {
        guard !started else { return }
        process.executableURL = executableURL
        process.standardInput = toHost
        process.standardOutput = fromHost
        process.standardError = hostErr
        // A strict allow-list: nothing of the parent environment crosses into a plugin process
        // unless it is named here (PLG-008).
        process.environment = PluginProcess.sanitizedEnvironment()
        signal(SIGPIPE, SIG_IGN)

        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            let tail = self.takeStderrTail()
            let signal = finished.terminationReason == .uncaughtSignal ? finished.terminationStatus : nil
            self.markTerminated(Termination(
                exitCode: finished.terminationReason == .exit ? finished.terminationStatus : -1,
                signal: signal,
                stderrTail: tail
            ))
        }
        try process.run()
        started = true
        drainStderr()
        readFrames()
    }

    public var isRunning: Bool { started && process.isRunning && terminated == nil }

    public var processIdentifier: Int32? { started ? process.processIdentifier : nil }

    /// Bounded teardown. SIGTERM first, then SIGKILL if the process is still there; the caller never
    /// has to guess whether the previous plugin process is gone.
    public func waitForExit(upTo timeout: Duration) {
        guard started else { return }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            usleep(5_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    /// A live event stream for one in-flight request. The owner finishes it when the invoke reply
    /// arrives, which drains what was already buffered before ending.
    public final class Subscription: @unchecked Sendable {
        public let stream: AsyncThrowingStream<JSONValue, Error>
        private let continuation: AsyncThrowingStream<JSONValue, Error>.Continuation

        init(bufferSize: Int) {
            var captured: AsyncThrowingStream<JSONValue, Error>.Continuation?
            stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(bufferSize)) { captured = $0 }
            continuation = captured!
        }

        @discardableResult
        func yield(_ value: JSONValue) -> AsyncThrowingStream<JSONValue, Error>.Continuation.YieldResult {
            continuation.yield(value)
        }

        public func finish() { continuation.finish() }
        public func finish(throwing error: any Error) { continuation.finish(throwing: error) }
    }

    /// Subscribes to streamed events for one in-flight request. The buffer is bounded; an overflow
    /// fails the stream instead of silently dropping part of a model reply.
    public func subscribe(requestID: String, bufferSize: Int = 1024) -> Subscription {
        let subscription = Subscription(bufferSize: bufferSize)
        lock.lock()
        streams[requestID] = subscription
        lock.unlock()
        return subscription
    }

    private func stream(for requestID: String) -> Subscription? {
        lock.lock()
        defer { lock.unlock() }
        return streams[requestID]
    }

    public func unsubscribe(requestID: String) {
        lock.lock()
        streams.removeValue(forKey: requestID)
        lock.unlock()
    }

    /// Drains the bounded notification queue (plugin → host → core events).
    public func drainNotices() -> [String] {
        lock.lock()
        let drained = notices
        notices.removeAll()
        lock.unlock()
        return drained
    }

    public var currentTermination: Termination? {
        lock.lock(); defer { lock.unlock() }; return terminated
    }

    /// Silence-bound: the watchdog measures from the moment this request went out, and any frame
    /// that arrives cancels it. A wedged host becomes `noReplyWithinDeadline`, never a hung Run.
    public func send(_ base: HostRequest, timeout: Duration) async throws -> HostReply {
        guard started else { throw PluginProcessError.notStarted }
        let id = claimID()
        var request = base
        request.id = id

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HostReply, Error>) in
                // Registered before the write, so a fast reply cannot land in an empty mailbox slot.
                register(continuation, for: id)
                write(FrameCodec.encode(request))
                let clock = self.clock
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await clock.sleep(for: timeout)
                    } catch {
                        return
                    }
                    let tail = self.takeStderrTail()
                    self.takeWaiter(id)?.resume(
                        throwing: PluginProcessError.noReplyWithinDeadline(method: base.method.rawValue, id: id, stderrTail: tail)
                    )
                }
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(id: id)
        }
    }

    /// A cancelled caller must not leave a continuation parked, and the host must hear about it.
    private func cancelWaiter(id: Int) {
        takeWaiter(id)?.resume(throwing: PluginProcessError.noReplyWithinDeadline(method: "cancelled", id: id, stderrTail: takeStderrTail()))
    }

    private func register(_ continuation: CheckedContinuation<HostReply, Error>, for id: Int) {
        lock.lock()
        waiters[id] = continuation
        lock.unlock()
    }

    private func takeWaiter(_ id: Int) -> CheckedContinuation<HostReply, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return waiters.removeValue(forKey: id)
    }

    public func terminate() {
        guard started else { return }
        toHost.fileHandleForWriting.closeFile()
        if process.isRunning { process.terminationHandler = nil; process.terminate() }
    }

    // MARK: - plumbing

    private var waiters: [Int: CheckedContinuation<HostReply, Error>] = [:]

    private func claimID() -> Int {
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    private func write(_ data: Data) {
        toHost.fileHandleForWriting.write(data)
    }

    private func readFrames() {
        let handle = fromHost.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            var pending = Data()
            while true {
                // availableData returns as soon as any bytes arrive and yields empty at EOF.
                // readData(ofLength:) waits for the full count, which a live pipe never delivers.
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    self.failAllWaiters()
                    return
                }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = pending[pending.startIndex..<newline]
                    pending.removeSubrange(pending.startIndex...newline)
                    guard !line.isEmpty else { continue }
                    self.deliver(Data(line))
                }
            }
        }
    }

    private func deliver(_ line: Data) {
        guard line.count <= HostWire.maxFrameBytes else { return }
        if let reply = try? HostWire.decode(HostReply.self, from: line), let id = reply.id {
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.resume(returning: reply)
            return
        }
        guard let notification = try? HostWire.decode(HostNotification.self, from: line) else { return }
        // Streaming events route by request id; everything else is a bounded diagnostic notice.
        if let requestID = notification.payload?.object?["requestID"]?.string,
           let subscription = stream(for: requestID) {
            if case .dropped = subscription.yield(notification.payload ?? .null) {
                subscription.finish(throwing: PluginProcessError.streamOverflow(requestID: requestID))
                unsubscribe(requestID: requestID)
            }
            return
        }
        lock.lock()
        // Bounded, drop-oldest: a plugin that emits faster than the Core consumes must not grow the
        // parent without limit. The cap is the backpressure signal the provider path will surface.
        notices.append(String(decoding: line, as: UTF8.self))
        if notices.count > 256 { notices.removeFirst(notices.count - 256) }
        lock.unlock()
    }

    private func markTerminated(_ termination: Termination) {
        lock.lock()
        guard terminated == nil else { lock.unlock(); return }
        terminated = termination
        let outstanding = waiters
        waiters.removeAll()
        let handler = onTermination
        lock.unlock()
        for (_, waiter) in outstanding {
            waiter.resume(throwing: PluginProcessError.exited(termination))
        }
        handler?(termination)
    }

    private func failAllWaiters() {
        markTerminated(Termination(exitCode: -1, signal: nil, stderrTail: "the host closed its output pipe"))
    }

    private func drainStderr() {
        let handle = hostErr.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                self.appendStderr(Array(chunk))
            }
        }
    }

    /// Bounded at 256 KB, dropping the oldest bytes: a chatty plugin must never deadlock the pipe
    /// nor exhaust the parent (IPC-002).
    private func appendStderr(_ bytes: [UInt8]) {
        lock.lock()
        stderrRing.append(contentsOf: bytes)
        if stderrRing.count > 256 * 1024 {
            stderrRing.removeFirst(stderrRing.count - 256 * 1024)
        }
        lock.unlock()
    }

    private func takeStderrTail(_ count: Int = 4096) -> String {
        lock.lock()
        let tail = Array(stderrRing.suffix(count))
        lock.unlock()
        return String(decoding: tail, as: UTF8.self)
    }

    static func sanitizedEnvironment() -> [String: String] {
        let keep = ["PATH", "HOME", "TMPDIR", "LANG"]
        let parent = ProcessInfo.processInfo.environment
        var sanitized: [String: String] = [:]
        for key in keep { if let value = parent[key] { sanitized[key] = value } }
        return sanitized
    }
}

enum FrameCodec {
    static func encode(_ request: HostRequest) -> Data {
        var copy = request
        copy.id = request.id
        return ((try? JSONEncoder().encode(copy)) ?? Data()) + [UInt8(ascii: "\n")]
    }
}
