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

    public init(corePath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: corePath)
        process.arguments = []
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
                message: "openTestStream 属于数据面，请使用 openTestStream()"
            ))
        }
        return try await dispatch(command)
    }

    // MARK: - LingXiConnection（数据面）

    public func openTestStream() async throws -> AsyncThrowingStream<StreamChunk, Error> {
        var continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation!
        let stream = AsyncThrowingStream { continuation = $0 }
        // 先注册再发请求，保证 streamOpened 到达前 chunk 有归属。
        nextRequestID += 1
        let id = String(nextRequestID)
        _ = try await withCheckedThrowingContinuation { (open: CheckedContinuation<StreamID, Error>) in
            pending[id] = .stream(chunks: continuation, open: open)
            write(.request(id: id, command: .openTestStream))
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

    public func close() async {
        guard process.isRunning else { return }
        process.terminate()
    }

    // MARK: - Private

    private func dispatch(_ command: ClientCommand) async throws -> CoreResponse {
        nextRequestID += 1
        let id = String(nextRequestID)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = .command(continuation)
            write(.request(id: id, command: command))
        }
    }

    private func write(_ message: WireMessage) {
        guard let data = try? encoder.encode(message) else { return }
        try? input.write(contentsOf: data + Data("\n".utf8))
    }

    private func readLoop(pipe: Pipe) async {
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                handle(line: line)
            }
        } catch {
            // 进程退出或管道断开。
        }
        finishAll(CoreError(code: .transport, message: "Core 连接已关闭"))
    }

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? decoder.decode(WireMessage.self, from: data)
        else { return }
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
                    open.resume(throwing: error)
                default:
                    open.resume(throwing: CoreError(code: .transport, message: "stream 请求收到非预期响应"))
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
        case let .streamEnd(streamID):
            streams.removeValue(forKey: streamID)?.finish()
        case .request:
            break
        }
    }

    private func removeEventContinuation(_ key: UUID) {
        eventContinuations.removeValue(forKey: key)
    }

    private func finishAll(_ error: CoreError) {
        for request in pending.values {
            switch request {
            case let .command(continuation):
                continuation.resume(throwing: error)
            case let .stream(_, open):
                open.resume(throwing: error)
            }
        }
        pending.removeAll()
        for continuation in streams.values {
            continuation.finish()
        }
        streams.removeAll()
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }
}
