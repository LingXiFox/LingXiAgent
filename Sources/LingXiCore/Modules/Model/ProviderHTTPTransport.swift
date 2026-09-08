import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiProtocol

public struct ProviderHTTPRequestContext: Sendable, Equatable {
    public let wireProtocol: ModelWireProtocol
    public let model: String
    public let requestID: ModelRequestID
    public let executionID: AgentRunID?
    public let step: Int

    public init(wireProtocol: ModelWireProtocol, model: String, requestID: ModelRequestID = ModelRequestID(), executionID: AgentRunID?, step: Int) {
        self.wireProtocol = wireProtocol
        self.model = model
        self.requestID = requestID
        self.executionID = executionID
        self.step = step
    }
}

public struct ProviderHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: AsyncThrowingStream<Data, Error>

    public init(statusCode: Int, headers: [String: String] = [:], body: AsyncThrowingStream<Data, Error>) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol ProviderHTTPTransport: Sendable {
    func send(_ request: URLRequest, context: ProviderHTTPRequestContext) async throws -> ProviderHTTPResponse
}

public struct URLSessionProviderHTTPTransport: ProviderHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest, context: ProviderHTTPRequestContext) async throws -> ProviderHTTPResponse {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw CoreError(code: .commandTimedOut, message: "Provider request timed out")
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let detail = (error as? URLError)?.localizedDescription ?? error.localizedDescription
            throw CoreError(code: .transportLost, message: "Provider transport failed: \(detail)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw CoreError(code: .provider, message: "Provider 返回非 HTTP 响应")
        }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let pump = Task {
                do {
                    var chunk = Data()
                    for try await byte in bytes {
                        if Task.isCancelled { throw CancellationError() }
                        chunk.append(byte)
                        if byte == 0x0A || chunk.count >= 4_096 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                pump.cancel()
                bytes.task.cancel()
            }
        }
        return ProviderHTTPResponse(
            statusCode: http.statusCode,
            headers: Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value in
                guard let key = key as? String else { return nil }
                return (key, String(describing: value))
            }),
            body: body
        )
    }
}
