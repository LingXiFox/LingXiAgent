import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

private actor ScriptedProviderTransport: ProviderHTTPTransport {
    private var responses: [ProviderHTTPResponse]
    private var requests: [URLRequest] = []

    init(_ payloads: [[String]]) {
        responses = payloads.map { payload in
            ProviderHTTPResponse(statusCode: 200, body: AsyncThrowingStream { continuation in
                continuation.yield(StubURLProtocol.sseBody(payload))
                continuation.finish()
            })
        }
    }

    func send(_ request: URLRequest, context: ProviderHTTPRequestContext) async throws -> ProviderHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw CoreError(code: .provider, message: "Fixture response missing") }
        return responses.removeFirst()
    }

    func bodies() -> [Data] { requests.compactMap(\.httpBody) }
}

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
                #"{"type":"response.failed","response":{"error":{"code":"invalid_function_output","message":"Tool result rejected: SENTINEL_PROVIDER_SECRET","param":"input[3].call_id"}}}"#,
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
        #expect(error.message.contains("code=invalid_function_output"))
        #expect(error.message.contains("param=input[3].call_id"))
        #expect(error.message.contains("Tool result rejected"))
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
            requestID: ModelRequestID("chat-tool"), model: ModelID("stub-model"), messages: [ModelMessage(role: .user, content: "hi")]
        )))
        let callID = ToolCallID("lingxi:chat-tool:0")
        #expect(events == [
            .started,
            .toolCallStarted(callID: callID, toolID: ToolID("read_file")),
            .toolCallDelta(callID: callID, arguments: #"{"path":"REA"#),
            .toolCallDelta(callID: callID, arguments: #"DME.md"}"#),
            .toolCallCompleted(ToolCall(callID: callID, toolID: ToolID("read_file"), arguments: #"{"path":"README.md"}"#)),
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
            requestID: ModelRequestID("chat-parallel"), model: ModelID("stub-model"), messages: [ModelMessage(role: .user, content: "hi")]
        )))
        let completed = events.compactMap { event -> ToolCall? in
            guard case let .toolCallCompleted(call) = event else { return nil }
            return call
        }
        #expect(completed.map(\.callID.rawValue) == ["lingxi:chat-parallel:0", "lingxi:chat-parallel:1"])
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
        #expect(snapshot.messages[1].parts.compactMap { if case let .toolCall(call) = $0 { call.callID.rawValue } else { nil } }.allSatisfy { $0.hasPrefix("lingxi:") })
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

    @Test func chatWireRoundTripRestoresExternalCallID() async throws {
        let transport = ScriptedProviderTransport([
            [
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"chat-external","function":{"name":"read_file","arguments":"{\"path\":\"A.md\"}"}}]},"finish_reason":"tool_calls"}]}"#,
                "[DONE]",
            ],
            [#"{"choices":[{"delta":{"content":"read"},"finish_reason":"stop"}]}"#, "[DONE]"],
        ])
        let provider = OpenAICompatibleProvider(config: ProviderConfig(baseURL: URL(string: "https://fixture.test/v1")!, apiKey: nil, model: "stub"), transport: transport)
        let snapshot = try await runCapturedToolLoop(provider: provider)
        let domainID = try #require(snapshot.messages[1].parts.compactMap { if case let .toolCall(call) = $0 { call.callID } else { nil } }.first)
        #expect(domainID.rawValue != "chat-external")

        let bodies = await transport.bodies()
        let second = try #require(JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        let messages = try #require(second["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        let toolCalls = try #require(assistant["tool_calls"] as? [[String: Any]])
        let result = try #require(messages.first { $0["role"] as? String == "tool" })
        #expect(toolCalls[0]["id"] as? String == "chat-external")
        #expect(result["tool_call_id"] as? String == "chat-external")
    }

    @Test func responsesStatelessRoundTripRestoresOpaqueReasoningAndExternalCallID() async throws {
        let transport = ScriptedProviderTransport([
            [
                #"{"type":"response.output_item.added","item":{"type":"reasoning","id":"reasoning-item","encrypted_content":"opaque-state"}}"#,
                #"{"type":"response.output_item.done","item":{"type":"reasoning","id":"reasoning-item","encrypted_content":"opaque-state"}}"#,
                #"{"type":"response.output_item.added","item":{"type":"function_call","id":"function-item","call_id":"responses-external","name":"read_file","arguments":""}}"#,
                #"{"type":"response.function_call_arguments.done","item_id":"function-item","arguments":"{\"path\":\"A.md\"}"}"#,
                #"{"type":"response.completed","response":{"id":"response-1","status":"completed"}}"#,
            ],
            [
                #"{"type":"response.output_text.delta","delta":"read"}"#,
                #"{"type":"response.completed","response":{"id":"response-2","status":"completed"}}"#,
            ],
        ])
        let provider = OpenAIResponsesProvider(config: ProviderConfig(baseURL: URL(string: "https://fixture.test/v1")!, apiKey: nil, model: "stub", wireProtocol: .responses), transport: transport)
        let snapshot = try await runCapturedToolLoop(provider: provider, reasoning: "medium")
        let domainID = try #require(snapshot.messages[1].parts.compactMap { if case let .toolCall(call) = $0 { call.callID } else { nil } }.first)
        #expect(domainID.rawValue != "responses-external")
        #expect(!snapshot.messages.description.contains("opaque-state"))

        let bodies = await transport.bodies()
        let second = try #require(JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        #expect(second["store"] as? Bool == false)
        #expect(second["previous_response_id"] == nil)
        let input = try #require(second["input"] as? [[String: Any]])
        let reasoningIndex = try #require(input.firstIndex { $0["type"] as? String == "reasoning" })
        let callIndex = try #require(input.firstIndex { $0["type"] as? String == "function_call" })
        let outputIndex = try #require(input.firstIndex { $0["type"] as? String == "function_call_output" })
        #expect(reasoningIndex < callIndex && callIndex < outputIndex)
        #expect(input[reasoningIndex]["encrypted_content"] as? String == "opaque-state")
        #expect(input[callIndex]["call_id"] as? String == "responses-external")
        #expect(input[outputIndex]["call_id"] as? String == "responses-external")
    }

    @Test func responsesContinuationSurvivesProviderStoreRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ProviderConfig(baseURL: URL(string: "https://fixture.test/v1")!, apiKey: nil, model: "stub", wireProtocol: .responses)
        let firstTransport = ScriptedProviderTransport([[
            #"{"type":"response.output_item.done","item":{"type":"reasoning","id":"reasoning-item","encrypted_content":"opaque-state"}}"#,
            #"{"type":"response.output_item.added","item":{"type":"function_call","id":"function-item","call_id":"provider-call","name":"read_file","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.done","item_id":"function-item","arguments":"{\"path\":\"A.md\"}"}"#,
            #"{"type":"response.completed","response":{"status":"completed"}}"#,
        ]])
        let firstRequestID = ModelRequestID("before-restart")
        let first = OpenAIResponsesProvider(config: config, transport: firstTransport, provenance: ProviderProvenanceStore(directory: directory))
        let events = try await collect(first.stream(ModelRequest(requestID: firstRequestID, model: ModelID("stub"), executionID: AgentRunID("run"), messages: [ModelMessage(role: .user, content: "Read A.md")], reasoning: "medium")))
        let call = try #require(events.compactMap { if case let .toolCallCompleted(call) = $0 { call } else { nil } }.first)
        #expect(call.callID.rawValue != "provider-call")

        let secondTransport = ScriptedProviderTransport([[
            #"{"type":"response.output_text.delta","delta":"read"}"#,
            #"{"type":"response.completed","response":{"status":"completed"}}"#,
        ]])
        let second = OpenAIResponsesProvider(config: config, transport: secondTransport, provenance: ProviderProvenanceStore(directory: directory))
        _ = try await collect(second.stream(ModelRequest(
            continuationOf: firstRequestID,
            model: ModelID("stub"),
            executionID: AgentRunID("run"),
            messages: [
                ModelMessage(role: .user, content: "Read A.md"),
                ModelMessage(role: .assistant, parts: [.toolCall(call)]),
                ModelMessage(role: .tool, parts: [.toolResult(ToolResult(callID: call.callID, success: true, content: "A"))]),
            ],
            reasoning: "medium"
        )))
        let body = try #require(await secondTransport.bodies().first)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.first { $0["type"] as? String == "reasoning" }?["encrypted_content"] as? String == "opaque-state")
        #expect(input.first { $0["type"] as? String == "function_call" }?["call_id"] as? String == "provider-call")
        #expect(input.first { $0["type"] as? String == "function_call_output" }?["call_id"] as? String == "provider-call")
    }

    @Test func anthropicWireRoundTripRestoresExternalIDForToolError() async throws {
        let transport = ScriptedProviderTransport([
            [
                #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"anthropic-external","name":"read_file","input":{}}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"missing.md\"}"}}"#,
                #"{"type":"content_block_stop","index":0}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
                #"{"type":"message_stop"}"#,
            ],
            [
                #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"handled"}}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
                #"{"type":"message_stop"}"#,
            ],
        ])
        let provider = AnthropicMessagesProvider(config: ProviderConfig(baseURL: URL(string: "https://fixture.test/v1")!, apiKey: nil, model: "stub", wireProtocol: .anthropicMessages), transport: transport)
        _ = try await runCapturedToolLoop(provider: provider)
        let bodies = await transport.bodies()
        let second = try #require(JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        let messages = try #require(second["messages"] as? [[String: Any]])
        let toolResults = messages.compactMap { $0["content"] as? [[String: Any]] }.flatMap { $0 }.filter { $0["type"] as? String == "tool_result" }
        let result = try #require(toolResults.first)
        #expect(result["tool_use_id"] as? String == "anthropic-external")
        #expect(result["is_error"] as? Bool == true)
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

    private func runCapturedToolLoop(provider: any ModelProvider, reasoning: String? = nil) async throws -> SessionSnapshot {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "A".write(to: root.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        let selection = ModelSelection(providerID: "default", modelID: "stub", reasoning: reasoning)
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("stub")), defaultModelSelection: selection, workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "Read A.md")
        for try await _ in stream {}
        return try await client.session(sessionID)
    }
}
