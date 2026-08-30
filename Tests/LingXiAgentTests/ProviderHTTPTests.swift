import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

/// URLProtocol stub：离线验证 Provider HTTP 层（200 SSE 流 / 非 2xx / 中途失败）。
/// handler 是进程级静态，套件必须串行执行避免互相覆盖。
@Suite(.serialized)
final class StubURLProtocol: URLProtocol {
    struct StubResponse {
        let status: Int
        let body: Data
        let headers: [String: String]

        init(status: Int, body: Data, headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> StubResponse)?
    nonisolated(unsafe) static var queuedResponses: [StubResponse] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response: StubResponse
        if let handler = Self.handler { response = handler(request) }
        else if !Self.queuedResponses.isEmpty { response = Self.queuedResponses.removeFirst() }
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"].merging(response.headers) { _, new in new }
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

    @Test func non2xxBecomesProviderError() async throws {
        let sentinel = "SENTINEL_PROVIDER_SECRET"
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(
                status: 401,
                body: Data(#"{"error":{"message":"SENTINEL_PROVIDER_SECRET"}}"#.utf8),
                headers: ["x-request-id": "request-123"]
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
            #expect(error.message.contains("request-123"))
            #expect(!error.message.contains(sentinel))
            #expect(!String(decoding: try JSONEncoder().encode(error), as: UTF8.self).contains(sentinel))
        } catch {
            Issue.record("错误类型应为 CoreError: \(error)")
        }
    }

    @Test func chatUnexpectedEOFFailsWithoutCompleted() async throws {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(status: 200, body: StubURLProtocol.sseBody([
                #"{"choices":[{"delta":{"content":"partial"}}]}"#,
            ]))
        }
        defer { StubURLProtocol.handler = nil }

        let events = try await collect(makeProvider().stream(ModelRequest(
            model: ModelID("stub-model"), messages: [ModelMessage(role: .user, content: "hi")]
        )))
        #expect(events.contains { if case .failed = $0 { true } else { false } })
        #expect(!events.contains { if case .completed = $0 { true } else { false } })
    }

    @Test func responsesFailedIsTerminalAndSanitized() async throws {
        let sentinel = "SENTINEL_PROVIDER_SECRET"
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(status: 200, body: StubURLProtocol.sseBody([
                #"{"type":"response.failed","error":{"message":"SENTINEL_PROVIDER_SECRET"}}"#,
                #"{"type":"response.completed","response":{"status":"completed"}}"#,
            ]))
        }
        defer { StubURLProtocol.handler = nil }
        let provider = OpenAIResponsesProvider(
            config: ProviderConfig(baseURL: URL(string: "https://stub.test/v1")!, apiKey: nil, model: "stub", wireProtocol: .responses),
            session: StubURLProtocol.makeSession()
        )

        let events = try await collect(provider.stream(ModelRequest(
            model: ModelID("stub"), messages: [ModelMessage(role: .user, content: "hi")]
        )))
        let error = try #require(events.compactMap { if case let .failed(error) = $0 { error } else { nil } }.first)
        #expect(!events.contains { if case .completed = $0 { true } else { false } })
        #expect(!error.message.contains(sentinel))
        #expect(!String(decoding: try JSONEncoder().encode(error), as: UTF8.self).contains(sentinel))
    }

    @Test func responsesUnexpectedEOFFailsWithoutCompleted() async throws {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(status: 200, body: StubURLProtocol.sseBody([
                #"{"type":"response.output_text.delta","delta":"partial"}"#,
            ]))
        }
        defer { StubURLProtocol.handler = nil }
        let provider = OpenAIResponsesProvider(
            config: ProviderConfig(baseURL: URL(string: "https://stub.test/v1")!, apiKey: nil, model: "stub", wireProtocol: .responses),
            session: StubURLProtocol.makeSession()
        )

        let events = try await collect(provider.stream(ModelRequest(
            model: ModelID("stub"), messages: [ModelMessage(role: .user, content: "hi")]
        )))
        #expect(events.contains { if case .failed = $0 { true } else { false } })
        #expect(!events.contains { if case .completed = $0 { true } else { false } })
    }

    @Test func malformedResponsesSSEFailsWithoutCompletedOrPayloadLeak() async throws {
        let sentinel = "SENTINEL_PROVIDER_SECRET"
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(status: 200, body: StubURLProtocol.sseBody([sentinel]))
        }
        defer { StubURLProtocol.handler = nil }
        let provider = OpenAIResponsesProvider(
            config: ProviderConfig(baseURL: URL(string: "https://stub.test/v1")!, apiKey: nil, model: "stub", wireProtocol: .responses),
            session: StubURLProtocol.makeSession()
        )

        let events = try await collect(provider.stream(ModelRequest(
            model: ModelID("stub"), messages: [ModelMessage(role: .user, content: "hi")]
        )))
        let error = try #require(events.compactMap { if case let .failed(error) = $0 { error } else { nil } }.first)
        #expect(!events.contains { if case .completed = $0 { true } else { false } })
        #expect(!error.message.contains(sentinel))
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

    @Test func toolCallArgumentsAreAggregatedAcrossSSEChunks() async throws {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(
                status: 200,
                body: StubURLProtocol.sseBody([
                    #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"read_file","arguments":"{\"path\":\"REA"}}]}}]}"#,
                    #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"DME.md\"}"}}]}}]}"#,
                    #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
                ]) + Data("data: [DONE]\n\n".utf8)
            )
        }
        defer { StubURLProtocol.handler = nil }

        let events = try await collect(makeProvider().stream(ModelRequest(
            model: ModelID("stub-model"), messages: [ModelMessage(role: .user, content: "hi")]
        )))
        #expect(events == [
            .started,
            .toolCallStarted(callID: ToolCallID("call-1"), toolID: ToolID("read_file")),
            .toolCallDelta(callID: ToolCallID("call-1"), arguments: #"{"path":"REA"#),
            .toolCallDelta(callID: ToolCallID("call-1"), arguments: #"DME.md"}"#),
            .toolCallCompleted(ToolCall(callID: ToolCallID("call-1"), toolID: ToolID("read_file"), arguments: #"{"path":"README.md"}"#)),
            .completed(.toolCalls),
        ])
    }

    @Test func malformedToolArgumentsBecomeModelStreamFailure() async throws {
        let sentinel = "SENTINEL_PROVIDER_SECRET"
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(
                status: 200,
                body: StubURLProtocol.sseBody([
                    #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"SENTINEL_PROVIDER_SECRET","arguments":"not-json"}}]}}]}"#,
                ]) + Data("data: [DONE]\n\n".utf8)
            )
        }
        defer { StubURLProtocol.handler = nil }

        let events = try await collect(makeProvider().stream(ModelRequest(
            model: ModelID("stub-model"), messages: [ModelMessage(role: .user, content: "hi")]
        )))
        guard case let .failed(error) = events.last else {
            Issue.record("非法 Tool arguments 应结束为 failed: \(events)")
            return
        }
        #expect(error.code == .modelStream)
        #expect(!error.message.contains(sentinel))
        #expect(!String(decoding: try JSONEncoder().encode(error), as: UTF8.self).contains(sentinel))
    }

    @Test func multipleToolCallsCompleteInIndexOrder() async throws {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.StubResponse(
                status: 200,
                body: StubURLProtocol.sseBody([
                    #"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call-b","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}},{"index":0,"id":"call-a","function":{"name":"read_file","arguments":"{\"path\":\"README.md\"}"}}]}}]}"#,
                ]) + Data("data: [DONE]\n\n".utf8)
            )
        }
        defer { StubURLProtocol.handler = nil }
        let events = try await collect(makeProvider().stream(ModelRequest(
            model: ModelID("stub-model"), messages: [ModelMessage(role: .user, content: "hi")]
        )))
        let completed = events.compactMap { event -> ToolCall? in
            guard case let .toolCallCompleted(call) = event else { return nil }
            return call
        }
        #expect(completed.map(\.callID.rawValue) == ["call-a", "call-b"])
    }

    @Test func responsesProviderRunsParallelToolLoopThroughDomainRuntime() async throws {
        StubURLProtocol.queuedResponses = [
            StubURLProtocol.StubResponse(status: 200, body: StubURLProtocol.sseBody([
                #"{"type":"response.output_item.added","item":{"type":"function_call","id":"provider-a","call_id":"call-a","name":"read_file","arguments":""}}"#,
                #"{"type":"response.output_item.added","item":{"type":"function_call","id":"provider-b","call_id":"call-b","name":"read_file","arguments":""}}"#,
                #"{"type":"response.function_call_arguments.done","call_id":"call-a","name":"read_file","arguments":"{\"path\":\"A.md\"}"}"#,
                #"{"type":"response.function_call_arguments.done","call_id":"call-b","name":"read_file","arguments":"{\"path\":\"B.md\"}"}"#,
                #"{"type":"response.completed","response":{"status":"completed"}}"#,
            ])),
            StubURLProtocol.StubResponse(status: 200, body: StubURLProtocol.sseBody([
                #"{"type":"response.output_text.delta","delta":"A and B read."}"#,
                #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":3}}}"#,
            ])),
        ]
        defer { StubURLProtocol.queuedResponses = [] }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "A".write(to: root.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try "B".write(to: root.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
        let provider = OpenAIResponsesProvider(config: ProviderConfig(baseURL: URL(string: "https://stub.test/v1")!, apiKey: nil, model: "stub", wireProtocol: .responses), session: StubURLProtocol.makeSession())
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("stub")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "Read both files")
        var text = ""
        for try await chunk in stream where chunk.kind == .text { text += chunk.text }
        let snapshot = try await client.session(sessionID)
        #expect(text == "A and B read.")
        #expect(snapshot.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(snapshot.messages[1].parts.compactMap { if case let .toolCall(call) = $0 { call.callID.rawValue } else { nil } } == ["call-a", "call-b"])
        #expect(snapshot.messages[2].parts.count == 2)
    }

    @Test func dualWireProvidersPreserveToolLoopSessionSemantics() async throws {
        let chat = OpenAICompatibleProvider(config: ProviderConfig(baseURL: URL(string: "https://stub.test/v1")!, apiKey: nil, model: "stub"), session: StubURLProtocol.makeSession())
        let responses = OpenAIResponsesProvider(config: ProviderConfig(baseURL: URL(string: "https://stub.test/v1")!, apiKey: nil, model: "stub", wireProtocol: .responses), session: StubURLProtocol.makeSession())
        let chatResult = try await runToolLoop(provider: chat, responses: [
            StubURLProtocol.StubResponse(status: 200, body: StubURLProtocol.sseBody([
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-a","function":{"name":"read_file","arguments":"{\"path\":\"A.md\"}"}},{"index":1,"id":"call-b","function":{"name":"read_file","arguments":"{\"path\":\"B.md\"}"}}]},"finish_reason":"tool_calls"}]}"#,
                "[DONE]",
            ])),
            StubURLProtocol.StubResponse(status: 200, body: StubURLProtocol.sseBody([
                #"{"choices":[{"delta":{"content":"A and B read."},"finish_reason":"stop"}]}"#,
                "[DONE]",
            ])),
        ])
        let responsesResult = try await runToolLoop(provider: responses, responses: [
            StubURLProtocol.StubResponse(status: 200, body: StubURLProtocol.sseBody([
                #"{"type":"response.output_item.added","item":{"type":"function_call","call_id":"call-a","name":"read_file","arguments":""}}"#,
                #"{"type":"response.output_item.added","item":{"type":"function_call","call_id":"call-b","name":"read_file","arguments":""}}"#,
                #"{"type":"response.function_call_arguments.done","call_id":"call-a","name":"read_file","arguments":"{\"path\":\"A.md\"}"}"#,
                #"{"type":"response.function_call_arguments.done","call_id":"call-b","name":"read_file","arguments":"{\"path\":\"B.md\"}"}"#,
                #"{"type":"response.completed","response":{"status":"completed"}}"#,
            ])),
            StubURLProtocol.StubResponse(status: 200, body: StubURLProtocol.sseBody([
                #"{"type":"response.output_text.delta","delta":"A and B read."}"#,
                #"{"type":"response.completed","response":{"status":"completed"}}"#,
            ])),
        ])
        #expect(chatResult == responsesResult)
    }

    private func runToolLoop(provider: any ModelProvider, responses: [StubURLProtocol.StubResponse]) async throws -> ([SessionMessageRole], String) {
        StubURLProtocol.handler = nil
        StubURLProtocol.queuedResponses = responses
        defer { StubURLProtocol.queuedResponses = [] }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "A".write(to: root.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try "B".write(to: root.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("stub")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "Read both files")
        var text = ""
        for try await chunk in stream where chunk.kind == .text { text += chunk.text }
        return (try await client.session(sessionID).messages.map(\.role), text)
    }
}
