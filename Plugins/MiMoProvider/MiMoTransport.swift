import Foundation
import LingXiPluginABI

struct MiMoCassetteExchange: Codable {
    let requestDigest: String
    /// Normalized exchange format used by the original Chat recordings.
    let events: [ProviderWireEvent]?
    /// Raw SSE lines for synthetic/recorded Responses fixtures. Lines are fed through the same
    /// normalizer as the live transport, so fixture tests exercise production parsing rather than
    /// a hand-written event list.
    let sse: [String]?

    init(requestDigest: String, events: [ProviderWireEvent]? = nil, sse: [String]? = nil) {
        self.requestDigest = requestDigest
        self.events = events
        self.sse = sse
    }
}

struct MiMoCassette: Codable {
    let version: Int
    let provider: String
    var exchanges: [MiMoCassetteExchange]
}

/// Kept local to this plugin: each provider owns its fixtures, and there is no shared compatibility
/// layer to get out of sync. Sequential replay, digest checked when present.
final class MiMoCassetteStore: @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [MiMoCassetteExchange] = []
    private var next = 0

    init(replayPath: String?) {
        guard let replayPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: replayPath)),
              let cassette = try? JSONDecoder().decode(MiMoCassette.self, from: data) else { return }
        exchanges = cassette.exchanges
    }

    /// `legacyDigest` is only supplied for the exact default Chat configuration, so a pre-settings
    /// recording remains replayable without making distinct settings alias each other.
    func take(digest: String, legacyDigest: String? = nil) -> MiMoCassetteExchange? {
        lock.lock()
        defer { lock.unlock() }
        guard next < exchanges.count else { return nil }
        let exchange = exchanges[next]
        guard exchange.requestDigest.isEmpty
                || exchange.requestDigest == digest
                || (legacyDigest != nil && exchange.requestDigest == legacyDigest) else { return nil }
        next += 1
        return exchange
    }

    func append(digest: String, events: [ProviderWireEvent], to path: String) {
        lock.lock()
        exchanges.append(MiMoCassetteExchange(requestDigest: digest, events: events))
        let cassette = MiMoCassette(version: 1, provider: MiMoWire.providerID, exchanges: exchanges)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(cassette) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        lock.unlock()
    }
}

enum MiMoTransport {
    enum TransportError: Error, CustomStringConvertible {
        case httpStatus(Int)
        case missingCredential
        case streamEndedWithoutTerminal

        var description: String {
            switch self {
            case .httpStatus(let code): "HTTP \(code): upstream refused the request"
            case .missingCredential: "no credential was granted for this invocation"
            case .streamEndedWithoutTerminal: "the provider stream ended without a terminal event"
            }
        }
    }

    static func stream(
        request: ProviderWireRequest,
        requestID: String,
        config: MiMoConfig,
        endpoint: URL? = nil,
        emit: @escaping @Sendable (ProviderWireEvent) -> Void
    ) async throws {
        guard let credential = request.credential, !credential.isEmpty else {
            throw TransportError.missingCredential
        }
        var urlRequest = URLRequest(url: endpoint ?? MiMoWire.endpoint(for: config))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        switch config.protocolKind {
        case .chatCompletions:
            urlRequest.httpBody = Data(try MiMoWire.body(for: request, config: config))
        case .responses:
            urlRequest.httpBody = Data(try MiMoWire.responsesBody(for: request, config: config))
        }
        urlRequest.timeoutInterval = 300

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw TransportError.httpStatus(http.statusCode)
            }
            switch config.protocolKind {
            case .chatCompletions:
                try await consumeChat(bytes: bytes, emit: emit)
            case .responses:
                try await consumeResponses(bytes: bytes, emit: emit)
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    private static func consumeChat(
        bytes: URLSession.AsyncBytes,
        emit: @escaping @Sendable (ProviderWireEvent) -> Void
    ) async throws {
        var normalizer = MiMoWire.Normalizer()
        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            guard line.hasPrefix("data:") else { continue }
            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            for event in normalizer.consume(data: data) {
                if Task.isCancelled { throw CancellationError() }
                emit(event)
            }
            if data == "[DONE]" { break }
        }
        for event in normalizer.finalize() {
            if Task.isCancelled { throw CancellationError() }
            emit(event)
        }
        guard normalizer.hasTerminal else { throw TransportError.streamEndedWithoutTerminal }
    }

    private static func consumeResponses(
        bytes: URLSession.AsyncBytes,
        emit: @escaping @Sendable (ProviderWireEvent) -> Void
    ) async throws {
        var normalizer = MiMoWire.ResponsesNormalizer()
        var eventName: String?
        var dataLines: [String] = []

        func flush() {
            guard !dataLines.isEmpty else { eventName = nil; return }
            let data = dataLines.joined(separator: "\n")
            dataLines.removeAll()
            defer { eventName = nil }
            for event in normalizer.consume(event: eventName, data: data) {
                if Task.isCancelled {
                    normalizer.cancel()
                    return
                }
                emit(event)
            }
        }

        for try await line in bytes.lines {
            if Task.isCancelled {
                normalizer.cancel()
                throw CancellationError()
            }
            if line.isEmpty {
                flush()
                if normalizer.hasTerminal { break }
            } else if line.hasPrefix("event:") {
                // AsyncLineSequence does not guarantee blank separator lines survive. A new event
                // name is therefore also an event boundary for the previous data block.
                if !dataLines.isEmpty { flush() }
                eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        if !normalizer.hasTerminal { flush() }
        guard normalizer.hasTerminal else { throw TransportError.streamEndedWithoutTerminal }
    }

    /// Replays a recorded exchange one event at a time. SSE exchanges run through the selected
    /// normalizer, so a fixture can prove parsing and deduplication, not just event forwarding.
    static func replay(
        exchange: MiMoCassetteExchange,
        config: MiMoConfig,
        slow: Bool,
        emit: @Sendable (ProviderWireEvent) -> Void
    ) async throws {
        if let lines = exchange.sse, !lines.isEmpty {
            try await replaySSE(lines: lines, config: config, slow: slow, emit: emit)
            return
        }
        try await replay(events: exchange.events ?? [], slow: slow, emit: emit)
    }

    static func replay(
        events: [ProviderWireEvent], slow: Bool,
        emit: @Sendable (ProviderWireEvent) -> Void
    ) async throws {
        for event in events {
            if slow {
                try await Task.sleep(for: .milliseconds(200))
            } else {
                await Task.yield()
            }
            if Task.isCancelled { throw CancellationError() }
            emit(event)
        }
    }

    private static func replaySSE(
        lines: [String],
        config: MiMoConfig,
        slow: Bool,
        emit: @Sendable (ProviderWireEvent) -> Void
    ) async throws {
        switch config.protocolKind {
        case .chatCompletions:
            var normalizer = MiMoWire.Normalizer()
            for line in lines {
                if slow {
                    try await Task.sleep(for: .milliseconds(50))
                } else {
                    await Task.yield()
                }
                if Task.isCancelled { throw CancellationError() }
                guard line.hasPrefix("data:") else { continue }
                let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                for event in normalizer.consume(data: data) {
                    if Task.isCancelled { throw CancellationError() }
                    emit(event)
                }
                if data == "[DONE]" { break }
            }
            for event in normalizer.finalize() {
                if Task.isCancelled { throw CancellationError() }
                emit(event)
            }
            guard normalizer.hasTerminal else { throw TransportError.streamEndedWithoutTerminal }

        case .responses:
            var normalizer = MiMoWire.ResponsesNormalizer()
            var eventName: String?
            var dataLines: [String] = []

            func flush() {
                guard !dataLines.isEmpty else { eventName = nil; return }
                let data = dataLines.joined(separator: "\n")
                dataLines.removeAll()
                defer { eventName = nil }
                for event in normalizer.consume(event: eventName, data: data) {
                    if Task.isCancelled {
                        normalizer.cancel()
                        return
                    }
                    emit(event)
                }
            }

            for line in lines {
                if slow {
                    try await Task.sleep(for: .milliseconds(50))
                } else {
                    await Task.yield()
                }
                if Task.isCancelled {
                    normalizer.cancel()
                    throw CancellationError()
                }
                if line.isEmpty {
                    flush()
                    if normalizer.hasTerminal { break }
                } else if line.hasPrefix("event:") {
                    eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                }
            }
            if !normalizer.hasTerminal { flush() }
            guard normalizer.hasTerminal else { throw TransportError.streamEndedWithoutTerminal }
        }
    }
}
