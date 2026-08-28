import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

/// URLProtocol stub：离线验证 Provider HTTP 层（200 SSE 流 / 非 2xx / 中途失败）。
/// handler 是进程级静态，套件必须串行执行避免互相覆盖。
@Suite(.serialized)
final class StubURLProtocol: URLProtocol {
    struct StubResponse {
        let status: Int
        let body: Data
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> StubResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = handler(request)
        let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func sseBody(_ payloads: [String]) -> Data {
        Data(payloads.map { "data: \($0)\n\n" }.joined().utf8)
    }
}

@Suite(.serialized)
struct ProviderHTTPTests {
    private func makeProvider() -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            config: ProviderConfig(
                baseURL: URL(string: "https://stub.test/v1")!,
                apiKey: nil,
                model: "stub-model"
            ),
            session: StubURLProtocol.makeSession()
        )
    }

    private func collect(_ stream: AsyncThrowingStream<ModelEvent, Error>) async throws -> [ModelEvent] {
        var events: [ModelEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    @Test func streamingEventsInOrder() async throws {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(
                status: 200,
                body: StubURLProtocol.sseBody([
                    #"{"choices":[{"delta":{"content":"Hello"}}]}"#,
                    #"{"choices":[{"delta":{"content":" "}}]}"#,
                    #"{"choices":[{"delta":{"content":"DMA"}}]}"#,
                    #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
                ]) + Data("data: [DONE]\n\n".utf8)
            )
        }
        defer { StubURLProtocol.handler = nil }

        let provider = makeProvider()
        let events = try await collect(provider.stream(ModelRequest(
            model: ModelID("stub-model"),
            messages: [ModelMessage(role: .user, content: "hi")]
        )))

        #expect(events == [
            .started,
            .textDelta("Hello"),
            .textDelta(" "),
            .textDelta("DMA"),
            .completed(.stop),
        ])
    }

    @Test func non2xxBecomesProviderError() async {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(
                status: 401,
                body: Data(#"{"error":{"message":"invalid key"}}"#.utf8)
            )
        }
        defer { StubURLProtocol.handler = nil }

        let provider = makeProvider()
        do {
            _ = try await provider.stream(ModelRequest(
                model: ModelID("stub-model"),
                messages: [ModelMessage(role: .user, content: "hi")]
            ))
            Issue.record("非 2xx 应抛 ProviderError")
        } catch let error as CoreError {
            #expect(error.code == .provider)
            #expect(error.message.contains("401"))
            #expect(!error.message.contains("test-key"))
        } catch {
            Issue.record("错误类型应为 CoreError: \(error)")
        }
    }

    @Test func malformedSSEMidStreamFailsWithoutCrash() async throws {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(
                status: 200,
                body: StubURLProtocol.sseBody([
                    #"{"choices":[{"delta":{"content":"ok"}}]}"#,
                    "definitely-not-json",
                ])
            )
        }
        defer { StubURLProtocol.handler = nil }

        let provider = makeProvider()
        let events = try await collect(provider.stream(ModelRequest(
            model: ModelID("stub-model"),
            messages: [ModelMessage(role: .user, content: "hi")]
        )))

        guard case let .failed(error) = events.last else {
            Issue.record("应以 failed 事件结束: \(events)")
            return
        }
        #expect(error.code == .modelStream)
        // malformed 之前的 delta 必须已经交付。
        #expect(events.contains(.textDelta("ok")))
        // 失败后不允许再出现 completed。
        #expect(!events.contains { if case .completed = $0 { return true }; return false })
    }
}
