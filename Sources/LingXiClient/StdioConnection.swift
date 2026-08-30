import Foundation
import LingXiProtocol

/// stdio 子进程连接：spawn LingXiCoreHost，通过 JSON-lines 通信。
/// 控制面 request/response 与数据面 chunk 在读循环按 plane 分发，
/// chunk 不经过控制面等待链路。
public actor StdioConnection: LingXiConnection {
    private enum PendingRequest {
        case command(CheckedContinuation<CoreResponse, Error>)
        case stream(
            chunks: AsyncThrowingStream<StreamChunk, Error>.Continuation,
            open: CheckedContinuation<StreamID, Error>
        )
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

    public init(corePath: String, interactive: Bool = false) throws {
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

    init(input: FileHandle) {
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
            pending[id] = .stream(chunks: continuation, open: open)
            do {
                try write(.request(id: id, command: command))
            } catch {
                failConnection(CoreError(code: .transport, message: "Core 请求写入失败: \(error.localizedDescription)"))
            }
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
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = .command(continuation)
            do {
                try write(.request(id: id, command: command))
            } catch {
                failConnection(CoreError(code: .transport, message: "Core 请求写入失败: \(error.localizedDescription)"))
            }
        }
    }

    private func write(_ message: WireMessage) throws {
        let data = try encoder.encode(message)
        try input.write(contentsOf: data + Data("\n".utf8))
    }

    private func readLoop(pipe: Pipe) async {
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                handle(line: line)
            }
        } catch {
            failConnection(CoreError(code: .transport, message: "Core 连接读取失败: \(error.localizedDescription)"))
            return
        }
        failConnection(CoreError(code: .transport, message: "Core 连接已关闭"))
    }

    func handle(line: String) {
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
            case let .command(continuation):
                continuation.resume(returning: response)
            case let .stream(chunks, open):
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
            case let .command(continuation):
                continuation.resume(throwing: error)
            case let .stream(chunks, open):
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
