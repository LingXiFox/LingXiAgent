import Foundation
import LingXiPluginABI

struct MiMoCassetteExchange: Codable {
    let requestDigest: String
    let events: [ProviderWireEvent]
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
        var urlRequest = URLRequest(url: MiMoWire.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = Data(try MiMoWire.body(for: request))
        urlRequest.timeoutInterval = 300

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 1024 { break } }
            throw TransportError.httpStatus(http.statusCode, body)
        }

        var normalizer = MiMoWire.Normalizer()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            for event in normalizer.consume(data: data) { emit(event) }
            if data == "[DONE]" { break }
        }
        // The terminal is emitted only after the loop, so a trailing usage chunk is delivered first.
        for event in normalizer.finalize() { emit(event) }
        guard normalizer.hasTerminal else { throw TransportError.streamEndedWithoutTerminal }
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
            emit(event)
        }
    }
}
