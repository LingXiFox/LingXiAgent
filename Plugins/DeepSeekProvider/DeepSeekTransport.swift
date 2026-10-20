import Foundation
import LingXiPluginABI

struct CassetteExchange: Codable {
    let requestDigest: String
    let events: [ProviderWireEvent]
}

struct Cassette: Codable {
    let version: Int
    let provider: String
    var exchanges: [CassetteExchange]
}

/// Cassette state is shared between the blocking invoke and its async task; a lock keeps both views
/// consistent. In replay mode an unmatched request fails loudly, never falls back to the network.
final class CassetteStore: @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [CassetteExchange] = []
    private var next = 0
    let path: String?

    init(replayPath: String?) {
        path = replayPath
        if let replayPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: replayPath)),
           let cassette = try? JSONDecoder().decode(Cassette.self, from: data) {
            exchanges = cassette.exchanges
        }
    }

    /// Sequential replay: one response per request, in the order they were recorded. A recorded
    /// digest, when present, must match; fixtures leave it empty because they are hand-built.
    func take(digest: String) -> [ProviderWireEvent]? {
        lock.lock()
        defer { lock.unlock() }
        guard next < exchanges.count else { return nil }
        let exchange = exchanges[next]
        guard exchange.requestDigest.isEmpty || exchange.requestDigest == digest else { return nil }
        next += 1
        return exchange.events
    }

    func append(digest: String, events: [ProviderWireEvent], to path: String) {
        lock.lock()
        exchanges.append(CassetteExchange(requestDigest: digest, events: events))
        let cassette = Cassette(version: 1, provider: DeepSeekWire.providerID, exchanges: exchanges)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(cassette) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        lock.unlock()
    }
}

/// The real request path: URLSession streaming SSE, emitting normalized events as they arrive, with
/// the credential in the Authorization header only.
enum DeepSeekTransport {
    enum TransportError: Error, CustomStringConvertible {
        case httpStatus(Int, String)
        case missingCredential
        case streamEndedWithoutTerminal

        var description: String {
            switch self {
            case .httpStatus(let code, let body): "HTTP \(code): \(body.prefix(300))"
            case .missingCredential: "no credential was granted for this invocation"
            case .streamEndedWithoutTerminal: "the provider stream ended without a terminal event"
            }
        }
    }

    static func stream(
        request: ProviderWireRequest,
        requestID: String,
        emit: @escaping @Sendable (ProviderWireEvent) -> Void
    ) async throws {
        guard let credential = request.credential, !credential.isEmpty else {
            throw TransportError.missingCredential
        }
        var urlRequest = URLRequest(url: DeepSeekWire.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = Data(try DeepSeekWire.body(for: request))
        urlRequest.timeoutInterval = 300

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 1024 { break } }
            throw TransportError.httpStatus(http.statusCode, body)
        }

        var normalizer = DeepSeekWire.Normalizer()
        var eventName: String?
        var dataLines: [String] = []

        func flush() {
            guard !dataLines.isEmpty else { return }
            let data = dataLines.joined(separator: "\n")
            dataLines.removeAll()
            for event in normalizer.consume(event: eventName, data: data) {
                emit(event)
            }
            eventName = nil
        }

        for try await line in bytes.lines {
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("event:") {
                eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        flush()
        guard normalizer.emitted.contains(where: { $0.type == "completed" || $0.type == "failed" }) else {
            throw TransportError.streamEndedWithoutTerminal
        }
    }

    /// Replays a recorded exchange one event at a time, yielding between events so the consumer sees
    /// a stream rather than one blob.
    static func replay(
        events: [ProviderWireEvent],
        slow: Bool,
        emit: @Sendable (ProviderWireEvent) -> Void
    ) async throws {
        for event in events {
            if slow {
                // Test-only fault injection: gives a caller a window to cancel mid-stream.
                try await Task.sleep(for: .milliseconds(50))
            } else {
                await Task.yield()
            }
            emit(event)
        }
    }
}
