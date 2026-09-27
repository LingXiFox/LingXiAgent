import Foundation
import LingXiProtocol
import LingXiPlatform

/// When the last frame arrived, readable from a timer thread.
///
/// The stdio deadlines bound *silence*, not duration: `compactSession` runs a model call that can
/// take minutes on a live connection, and a fixed cap would fail an operation that is working fine.
/// A plain `await` of actor state is not an option either -- the timer exists precisely because the
/// cooperative pool may be the thing that is stuck.
final class LastFrameClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Date()

    func mark() {
        lock.lock()
        seen = Date()
        lock.unlock()
    }

    var value: Date {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

/// stdio 子进程连接：spawn LingXiCoreHost，通过 JSON-lines 通信。
/// 控制面 request/response 与数据面 chunk 在读循环按 plane 分发，
/// chunk 不经过控制面等待链路。
public actor StdioConnection: LingXiConnection {
    private enum PendingRequest {
        case command(CheckedContinuation<CoreResponse, Error>, OneShot)
        case stream(
            chunks: AsyncThrowingStream<StreamChunk, Error>.Continuation,
            open: CheckedContinuation<StreamID, Error>,
            OneShot
        )
    }

    /// One winner per pending request. The answer, the connection failure and the deadline can all
    /// try to resume the same continuation, and a continuation resumed twice crashes the process.
    final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var available = true

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard available else { return false }
            available = false
            return true
        }
    }

    private let process: Process
    private let input: FileHandle
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var nextRequestID = 0
    private var pending: [String: PendingRequest] = [:]
    private var streams: [StreamID: AsyncThrowingStream<StreamChunk, Error>.Continuation] = [:]
    private var eventContinuations: [UUID: AsyncStream<CoreEvent>.Continuation] = [:]
    private var toolOutputContinuations: [UUID: AsyncStream<ToolOutputChunk>.Continuation] = [:]
    private var terminalError: CoreError?
    /// How long a request may go unanswered. Injectable so the deadline is testable at all;
    /// production uses `responseTimeoutSeconds`.
    private let timeoutSeconds: Int
    private let lastFrame = LastFrameClock()

    public init(corePath: String, interactive: Bool = false, timeoutSeconds: Int? = nil) throws {
        self.timeoutSeconds = timeoutSeconds ?? Self.responseTimeoutSeconds
        let process = Process()
        process.executableURL = URL(fileURLWithPath: corePath)
        process.arguments = []
        if interactive {
            process.environment = ProcessInfo.processInfo.environment.merging(["LINGXI_INTERACTIVE": "1"]) { _, new in new }
        }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // stderr 继承父进程，便于调试。
        self.process = process
        self.input = input.fileHandleForWriting
        try process.run()
        // 读循环独立运行，随管道 EOF 结束；进程生命周期即连接生命周期。
        Task { await self.readLoop(pipe: output) }
    }

    init(input: FileHandle, timeoutSeconds: Int? = nil) {
        self.timeoutSeconds = timeoutSeconds ?? Self.responseTimeoutSeconds
        self.process = Process()
        self.input = input
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - LingXiConnection（控制面）

    public func send(_ command: ClientCommand) async throws -> CoreResponse {
        guard !command.isDataPlane else {
            return .error(CoreError(
                code: .unsupportedCommand,
                message: "数据面命令请使用 openTestStream() / sendMessage()"
            ))
        }
        return try await dispatch(command)
    }

    // MARK: - LingXiConnection（数据面）

    public func openTestStream() async throws -> AsyncThrowingStream<StreamChunk, Error> {
        try await openDataStream(.openTestStream)
    }

    public func sendMessage(sessionID: SessionID, content: String) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        try await openDataStream(.sendMessage(sessionID: sessionID, content: content))
    }

    /// 先注册 chunk 归属再发请求，保证 streamOpened 到达前 chunk 不丢失。
    private func openDataStream(_ command: ClientCommand) async throws -> AsyncThrowingStream<StreamChunk, Error> {
        if let terminalError { throw terminalError }
        var continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation!
        let stream = AsyncThrowingStream { continuation = $0 }
        nextRequestID += 1
        let id = String(nextRequestID)
        _ = try await withCheckedThrowingContinuation { (open: CheckedContinuation<StreamID, Error>) in
            let request: PendingRequest = .stream(chunks: continuation, open: open, OneShot())
            pending[id] = request
            do {
                try write(.request(id: id, command: command))
            } catch {
                failConnection(CoreError(code: .transport, message: "Core 请求写入失败: \(error.localizedDescription)"))
            }
            armDeadline(for: request)
        } as StreamID
        return stream
    }

    // MARK: - LingXiConnection（事件）

    public func events() async -> AsyncStream<CoreEvent> {
        AsyncStream { continuation in
            let key = UUID()
            eventContinuations[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(key) }
            }
        }
    }

    public func toolOutputEvents() async -> AsyncStream<ToolOutputChunk> {
        AsyncStream { continuation in
            let key = UUID()
            toolOutputContinuations[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeToolOutputContinuation(key) }
            }
        }
    }

    public func close() async {
        failConnection(CoreError(code: .transport, message: "Core 连接已关闭"))
        try? input.close()
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Private

    private func dispatch(_ command: ClientCommand) async throws -> CoreResponse {
        if let terminalError { throw terminalError }
        nextRequestID += 1
        let id = String(nextRequestID)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CoreResponse, Error>) in
            let request: PendingRequest = .command(continuation, OneShot())
            pending[id] = request
            do {
                try write(.request(id: id, command: command))
            } catch {
                failConnection(CoreError(code: .transport, message: "Core 请求写入失败: \(error.localizedDescription)"))
            }
            armDeadline(for: request)
        }
    }

    /// A request that goes unanswered has to end, with a reason -- but only when the connection has
    /// gone *quiet*, which is what makes the wait bounded without capping how long work may take.
    ///
    /// `failConnection` already resumes everything pending once EOF is seen, so a request that stays
    /// unanswered means the read loop produced nothing at all -- reachable on Windows, where the stdio
    /// reader used to park a cooperative-pool worker inside a blocking read, and a pool with no free
    /// worker runs no task, including the one that would notice the silence. Which is why this timer is
    /// not a `Task` and does not await anything: a deadline that needed the same pool to fire could not
    /// bound the starvation it exists to escape. `OneShot` keeps the answer, the connection failure and
    /// this deadline from resuming one continuation twice.
    nonisolated private func armDeadline(for request: PendingRequest) {
        let seconds = timeoutSeconds
        let armedAt = Date()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
            guard let self else { return }
            // Frames arrived since this request was armed, so the peer is alive and simply busy: the
            // same silence window starts over. A long `compactSession` is answered minutes later, and
            // failing it would be a new defect dressed up as a timeout.
            if self.lastFrame.value >= armedAt {
                self.armDeadline(for: request)
                return
            }
            let error = CoreError(
                code: .transport,
                message: "Core 在 \(seconds)s 内没有任何回应：子进程可能未能启动或已退出，stdio 读取侧在这段时间没有产生任何帧"
            )
            switch request {
            case let .command(continuation, claim):
                guard claim.claim() else { return }
                continuation.resume(throwing: error)
            case let .stream(chunks, open, claim):
                guard claim.claim() else { return }
                chunks.finish(throwing: error)
                open.resume(throwing: error)
            }
            // Everything else on this connection is equally unreachable; each request arms its own
            // deadline anyway, so this cleanup is best effort and must not block the answer.
            Task { [weak self] in await self?.failConnection(error) }
        }
    }

    /// How long a request may go unanswered before the connection calls it dead.
    ///
    /// CI overrides it, because a chunk watchdog that fires *before* this deadline can only report
    /// "hung", while a deadline that fires first reports which side stopped talking. Lowering it for
    /// the test run buys a diagnosis; it does not relax an assertion, and the window is silence-bound,
    /// so a Core that is streaming keeps resetting it.
    static let responseTimeoutSeconds: Int = {
        let raw = ProcessInfo.processInfo.environment["LINGXI_CORE_RESPONSE_TIMEOUT_SECONDS"]
        if let raw, let seconds = Int(raw), seconds > 0 { return seconds }
        return 60
    }()

    private func write(_ message: WireMessage) throws {
        let data = try encoder.encode(message)
        try input.write(contentsOf: data + Data("\n".utf8))
    }

    private func readLoop(pipe: Pipe) async {
        do {
            for try await line in LingXiPlatform.lineReader.lines(from: pipe.fileHandleForReading) {
                handle(line: line)
            }
        } catch {
            failConnection(CoreError(code: .transport, message: "Core 连接读取失败: \(error.localizedDescription)"))
            return
        }
        failConnection(CoreError(code: .transport, message: "Core 连接已关闭"))
    }

    func handle(line: String) {
        lastFrame.mark()
        guard terminalError == nil else { return }
        let message: WireMessage
        do {
            message = try decoder.decode(WireMessage.self, from: Data(line.utf8))
        } catch {
            failConnection(CoreError(code: .transport, message: "Core 返回非法 JSON: \(error.localizedDescription)"))
            return
        }
        handle(message)
    }

    func handle(_ message: WireMessage) {
        guard terminalError == nil else { return }
        switch message {
        case let .response(id, response):
            switch pending.removeValue(forKey: id) {
            case let .command(continuation, claim):
                if claim.claim() { continuation.resume(returning: response) }
            case let .stream(chunks, open, claim):
                guard claim.claim() else { break }
                switch response {
                case let .streamOpened(streamID):
                    streams[streamID] = chunks
                    open.resume(returning: streamID)
                case let .error(error):
                    chunks.finish(throwing: error)
                    open.resume(throwing: error)
                default:
                    let error = CoreError(code: .transport, message: "stream 请求收到非预期响应")
                    chunks.finish(throwing: error)
                    open.resume(throwing: error)
                }
            case nil:
                break
            }
        case let .event(event):
            for continuation in eventContinuations.values {
                continuation.yield(event)
            }
        case let .chunk(chunk):
            streams[chunk.streamID]?.yield(chunk)
        case let .toolOutput(chunk):
            for continuation in toolOutputContinuations.values {
                continuation.yield(chunk)
            }
        case let .streamEnd(streamID, error):
            if let error {
                streams.removeValue(forKey: streamID)?.finish(throwing: error)
            } else {
                streams.removeValue(forKey: streamID)?.finish()
            }
        case .request:
            break
        }
    }

    func inputDidClose() {
        failConnection(CoreError(code: .transport, message: "Core 连接已关闭"))
    }

    private func removeEventContinuation(_ key: UUID) {
        eventContinuations.removeValue(forKey: key)
    }

    private func removeToolOutputContinuation(_ key: UUID) {
        toolOutputContinuations.removeValue(forKey: key)
    }

    private func failConnection(_ error: CoreError) {
        guard terminalError == nil else { return }
        terminalError = error
        for request in pending.values {
            switch request {
            case let .command(continuation, claim):
                if claim.claim() { continuation.resume(throwing: error) }
            case let .stream(chunks, open, claim):
                guard claim.claim() else { continue }
                chunks.finish(throwing: error)
                open.resume(throwing: error)
            }
        }
        pending.removeAll()
        for continuation in streams.values {
            continuation.finish(throwing: error)
        }
        streams.removeAll()
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
        for continuation in toolOutputContinuations.values {
            continuation.finish()
        }
        toolOutputContinuations.removeAll()
    }
}
