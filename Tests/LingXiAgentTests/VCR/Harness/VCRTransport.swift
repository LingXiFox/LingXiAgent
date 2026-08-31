import Foundation
@testable import LingXiCore

struct VCRProviderTransport: ProviderHTTPTransport {
    let mode: VCRMode
    let timing: VCRReplayTiming
    let cassette: VCRCassetteStore
    let upstream: (any ProviderHTTPTransport)?

    init(mode: VCRMode, timing: VCRReplayTiming = .instant, cassette: VCRCassetteStore, upstream: (any ProviderHTTPTransport)? = nil) {
        self.mode = mode
        self.timing = timing
        self.cassette = cassette
        self.upstream = upstream
    }

    func send(_ request: URLRequest, context: ProviderHTTPRequestContext) async throws -> ProviderHTTPResponse {
        switch mode {
        case .record:
            guard let upstream else { throw CassetteMismatch(message: "record transport is missing upstream") }
            let prepared = try await cassette.prepareRecording(request, context: context)
            let response = try await upstream.send(request, context: context)
            return ProviderHTTPResponse(statusCode: response.statusCode, headers: response.headers, body: recordingBody(response.body, prepared: prepared, context: context, status: response.statusCode, headers: response.headers))
        case .replay:
            let exchange = try await cassette.replay(request, context: context)
            return ProviderHTTPResponse(statusCode: exchange.status, headers: exchange.responseHeaders, body: replayBody(exchange))
        }
    }

    private func recordingBody(
        _ source: AsyncThrowingStream<Data, Error>,
        prepared: VCRPreparedRequest,
        context: ProviderHTTPRequestContext,
        status: Int,
        headers: [String: String]
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let clock = ContinuousClock()
                let started = clock.now
                var framer = VCRResponseFramer(contentType: headers.first { $0.key.caseInsensitiveCompare("content-type") == .orderedSame }?.value ?? "application/json")
                var recorded: [VCRWireChunk] = []
                var failure: Error?
                var cancelled = false
                do {
                    for try await chunk in source {
                        for frame in framer.feed(chunk) {
                            let offset = Self.milliseconds(started.duration(to: clock.now))
                            let normalized = try await cassette.normalizeRecordingChunk(frame, responseHeaders: headers)
                            recorded.append(VCRWireChunk(index: recorded.count, offsetMilliseconds: offset, data: normalized))
                            if Self.isDefinitiveTerminal(frame, wire: context.wireProtocol) {
                                try await cassette.record(prepared: prepared, context: context, status: status, responseHeaders: headers, chunks: recorded, terminalOffsetMilliseconds: offset, termination: .completed)
                                continuation.yield(frame)
                                continuation.finish()
                                return
                            }
                            continuation.yield(frame)
                        }
                    }
                } catch {
                    if error is CancellationError { cancelled = true } else { failure = error }
                }
                if let tail = framer.finish() {
                    do {
                        let normalized = try await cassette.normalizeRecordingChunk(tail, responseHeaders: headers)
                        recorded.append(VCRWireChunk(index: recorded.count, offsetMilliseconds: Self.milliseconds(started.duration(to: clock.now)), data: normalized))
                        continuation.yield(tail)
                    } catch {
                        failure = error
                    }
                }
                do {
                    if cancelled || Task.isCancelled { throw CassetteMismatch(message: "cancelled Provider stream cannot become a cassette") }
                    let termination: VCRStreamTermination = failure != nil ? .failed : .completed
                    try await cassette.record(prepared: prepared, context: context, status: status, responseHeaders: headers, chunks: recorded, terminalOffsetMilliseconds: Self.milliseconds(started.duration(to: clock.now)), termination: termination)
                    if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func replayBody(_ exchange: VCRWireExchange) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(0)) { continuation in
            let task = Task {
                var previous = 0
                for chunk in exchange.chunks {
                    if timing == .timed, chunk.offsetMilliseconds > previous {
                        try? await Task.sleep(for: .milliseconds(chunk.offsetMilliseconds - previous))
                    }
                    guard !Task.isCancelled else {
                        await cassette.cancelReplay(sequence: exchange.sequence)
                        return
                    }
                    let data = await cassette.replayChunk(chunk.data)
                    guard await Self.yieldWhenRequested(data, to: continuation) else {
                        await cassette.cancelReplay(sequence: exchange.sequence)
                        return
                    }
                    if Self.isDefinitiveTerminal(data, wire: exchange.wire) { await cassette.finishReplay(sequence: exchange.sequence) }
                    previous = chunk.offsetMilliseconds
                }
                if timing == .timed, exchange.terminalOffsetMilliseconds > previous {
                    try? await Task.sleep(for: .milliseconds(exchange.terminalOffsetMilliseconds - previous))
                }
                guard !Task.isCancelled else {
                    await cassette.cancelReplay(sequence: exchange.sequence)
                    return
                }
                await cassette.finishReplay(sequence: exchange.sequence)
                if exchange.termination == .failed { continuation.finish(throwing: URLError(.networkConnectionLost)) }
                else { continuation.finish() }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private static func yieldWhenRequested(_ data: Data, to continuation: AsyncThrowingStream<Data, Error>.Continuation) async -> Bool {
        while !Task.isCancelled {
            switch continuation.yield(data) {
            case .enqueued: return true
            case .dropped: try? await Task.sleep(for: .milliseconds(1))
            case .terminated: return false
            @unknown default: return false
            }
        }
        return false
    }

    private static func isDefinitiveTerminal(_ chunk: Data, wire: ModelWireProtocol) -> Bool {
        let lines = String(decoding: chunk, as: UTF8.self).split(separator: "\n")
        for line in lines {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("data:") else { continue }
            let payload = String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if wire == .chatCompletions, payload == "[DONE]" { return true }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }
            if wire == .responses, ["response.completed", "response.incomplete", "response.failed", "error"].contains(type) { return true }
            if wire == .anthropicMessages, ["message_stop", "error"].contains(type) { return true }
        }
        return false
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000) + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}

private struct VCRResponseFramer {
    private var buffer = Data()
    private let isSSE: Bool

    init(contentType: String) {
        isSSE = contentType.lowercased().contains("text/event-stream")
    }

    mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        guard isSSE else { return [] }
        var result: [Data] = []
        while let range = buffer.range(of: Data("\n\n".utf8)) ?? buffer.range(of: Data("\r\n\r\n".utf8)) {
            let end = range.upperBound
            result.append(buffer[..<end])
            buffer.removeSubrange(..<end)
        }
        return result
    }

    mutating func finish() -> Data? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return buffer
    }
}
