import Foundation
import Testing
import LingXiProtocol
@testable import LingXiClient
@testable import LingXiCore

struct StdioConnectionTests {
    @Test func stdioInteractiveBootstrapIsExplicitAndOptIn() {
        #expect(CoreHost.stdioInteractive(environment: [:]) == false)
        #expect(CoreHost.stdioInteractive(environment: ["LINGXI_INTERACTIVE": "0"]) == false)
        #expect(CoreHost.stdioInteractive(environment: ["LINGXI_INTERACTIVE": "1"]) == true)
    }

    @Test func normalStreamFinishes() async throws {
        let result = try await runStream(endpoint: StdioEndpoint(error: nil))
        #expect(result.chunks.map(\.text) == ["ok"])
        #expect(result.messages.filter(\.isResponse).count == 1)
    }

    @Test func failedStreamThrowsTerminalCoreError() async throws {
        let expected = CoreError(code: .modelStream, message: "stream failed")
        do {
            _ = try await runStream(endpoint: StdioEndpoint(error: expected))
            #expect(Bool(false), "失败 stream 不应正常结束")
        } catch let error as StreamFixtureError {
            #expect(error.coreError == expected)
            #expect(error.messages.filter(\.isResponse).count == 1)
            #expect(error.messages.contains(.streamEnd(StreamID("stream-1"), error: expected)))
        } catch {
            #expect(Bool(false), "应保留 stream terminal 的 CoreError")
        }
    }

    @Test func malformedJSONFailsPendingRequestAndActiveStream() async throws {
        let fixture = try await openStream()
        let pending = Task { try await fixture.connection.send(.ping) }
        _ = try readMessage(from: fixture.requests.fileHandleForReading)
        await fixture.connection.handle(line: "not-json")

        await expectTransportError { _ = try await pending.value }
        await expectTransportError { for try await _ in fixture.stream {} }
    }

    @Test func eofFailsPendingRequestAndActiveStream() async throws {
        let fixture = try await openStream()
        let pending = Task { try await fixture.connection.send(.ping) }
        _ = try readMessage(from: fixture.requests.fileHandleForReading)
        await fixture.connection.inputDidClose()

        await expectTransportError { _ = try await pending.value }
        await expectTransportError { for try await _ in fixture.stream {} }
    }

    private func runStream(endpoint: StdioEndpoint) async throws -> (chunks: [StreamChunk], messages: [WireMessage]) {
        let requests = Pipe()
        let responses = Pipe()
        let connection = StdioConnection(input: requests.fileHandleForWriting)
        let opening = Task { try await connection.openTestStream() }
        let request = try readMessage(from: requests.fileHandleForReading)
        let server = StdioCoreServer(endpoint: endpoint, input: .nullDevice, output: responses.fileHandleForWriting)
        server.handleMessage(request)

        let messages = try readThroughStreamEnd(from: responses.fileHandleForReading)
        for message in messages { await connection.handle(message) }
        let stream = try await opening.value
        var chunks: [StreamChunk] = []
        do {
            for try await chunk in stream { chunks.append(chunk) }
            return (chunks, messages)
        } catch let error as CoreError {
            throw StreamFixtureError(coreError: error, messages: messages)
        }
    }

    private func openStream() async throws -> (connection: StdioConnection, requests: Pipe, stream: AsyncThrowingStream<StreamChunk, Error>) {
        let requests = Pipe()
        let connection = StdioConnection(input: requests.fileHandleForWriting)
        let opening = Task { try await connection.openTestStream() }
        guard case let .request(id, .openTestStream) = try readMessage(from: requests.fileHandleForReading) else {
            throw CoreError(code: .transport, message: "未收到 stream request")
        }
        await connection.handle(.response(id: id, response: .streamOpened(StreamID("stream-1"))))
        return (connection, requests, try await opening.value)
    }

    /// `FileHandle.availableData` blocks until a byte arrives or the pipe closes, so a write
    /// that never comes takes the whole test process down with it instead of failing one case.
    /// Under CI that never-write is observable on these pipes, so every fixture read is bounded
    /// and says so in the error.
    private static let fixtureReadTimeout: TimeInterval = 20

    private func availableData(from handle: FileHandle, timeout: TimeInterval) throws -> Data {
        let finished = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        DispatchQueue.global().async {
            box.data = handle.availableData
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            throw CoreError(code: .commandTimedOut, message: "fixture 管道在 \(timeout)s 内没有产出")
        }
        return box.data
    }

    private func readMessage(from handle: FileHandle) throws -> WireMessage {
        let data = try availableData(from: handle, timeout: Self.fixtureReadTimeout)
        guard !data.isEmpty else { throw CoreError(code: .transport, message: "fixture EOF") }
        return try JSONDecoder().decode(WireMessage.self, from: data.trimmingTrailingNewline())
    }

    private func readThroughStreamEnd(from handle: FileHandle) throws -> [WireMessage] {
        var messages: [WireMessage] = []
        let deadline = Date().addingTimeInterval(Self.fixtureReadTimeout)
        while !messages.contains(where: \.isStreamEnd) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw CoreError(code: .commandTimedOut, message: "已读到 \(messages.count) 条仍未见 stream end")
            }
            let data = try availableData(from: handle, timeout: remaining)
            guard !data.isEmpty else { throw CoreError(code: .transport, message: "fixture EOF") }
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                messages.append(try JSONDecoder().decode(WireMessage.self, from: Data(line)))
            }
        }
        return messages
    }

    private func expectTransportError(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            #expect(Bool(false), "连接失败不应正常完成")
        } catch let error as CoreError {
            #expect(error.code == .transport)
        } catch {
            #expect(Bool(false), "连接失败应抛出 CoreError")
        }
    }
}

private struct StreamFixtureError: Error {
    let coreError: CoreError
    let messages: [WireMessage]
}

private struct StdioEndpoint: CoreEndpoint {
    let error: CoreError?

    func handle(_ command: ClientCommand) async throws -> CoreResponse { .pong }

    func openDataStream(_ command: ClientCommand) async throws -> OpenedStream {
        let streamID = StreamID("stream-1")
        let stream = AsyncThrowingStream<StreamChunk, Error> { continuation in
            continuation.yield(StreamChunk(streamID: streamID, index: 0, text: "ok"))
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
        return OpenedStream(id: streamID, chunks: stream)
    }

    func toolOutputEvents() async -> AsyncStream<ToolOutputChunk> { AsyncStream { $0.finish() } }
    func events() async -> AsyncStream<CoreEvent> { AsyncStream { $0.finish() } }
}

private extension WireMessage {
    var isResponse: Bool {
        if case .response = self { true } else { false }
    }

    var isStreamEnd: Bool {
        if case .streamEnd = self { true } else { false }
    }
}

private extension Data {
    func trimmingTrailingNewline() -> Data {
        last == UInt8(ascii: "\n") ? dropLast() : self
    }
}
