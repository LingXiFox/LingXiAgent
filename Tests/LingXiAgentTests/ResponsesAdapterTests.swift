import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

struct ResponsesAdapterTests {
    private func tool() -> ToolDefinition {
        ToolDefinition(
            id: ToolID("read_file"),
            description: "Read a file",
            inputSchema: ToolInputSchema(properties: ["path": ToolInputProperty(type: .string, description: "Path")], required: ["path"]),
            capability: ToolCapability(readOnly: true)
        )
    }

    @Test func requestCodecCarriesInstructionsHistoryToolsAndReasoning() throws {
        let call = ToolCall(callID: ToolCallID("call-1"), toolID: ToolID("read_file"), arguments: #"{"path":"README.md"}"#)
        let result = ToolResult(callID: call.callID, success: true, content: "LingXiAgent")
        let data = try OpenAIResponsesProvider.makeRequestBody(ModelRequest(
            model: ModelID("gpt"), system: "system instruction", messages: [
                ModelMessage(role: .system, content: "developer instruction"),
                ModelMessage(role: .user, content: "read it"),
                ModelMessage(role: .assistant, parts: [.toolCall(call)]),
                ModelMessage(role: .tool, parts: [.toolResult(result)]),
            ], tools: [tool()], reasoning: "medium"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["instructions"] as? String == "system instruction")
        #expect(json["store"] as? Bool == false)
        #expect(json["reasoning"] as? [String: String] == ["effort": "medium"])
        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == [nil, nil, "function_call", "function_call_output"])
        #expect(input[2]["call_id"] as? String == "call-1")
        #expect(input[3]["output"] as? String == "LingXiAgent")
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools[0]["name"] as? String == "read_file")
    }

    @Test func parallelCallsMapToTheSameDomainEventsAsChatCompletions() throws {
        let requestID = ModelRequestID("responses-parallel")
        var responses = ResponsesSSEDecoder(requestID: requestID)
        let payloads = [
            #"{"type":"response.output_item.added","item":{"type":"function_call","id":"provider-item-a","call_id":"call-a","name":"read_file","arguments":""}}"#,
            #"{"type":"response.output_item.added","item":{"type":"function_call","id":"provider-item-b","call_id":"call-b","name":"read_file","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"provider-item-a","delta":"{\"path\":\"A.md\"}"}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"provider-item-b","delta":"{\"path\":\"B.md\"}"}"#,
            #"{"type":"response.function_call_arguments.done","item_id":"provider-item-a","arguments":"{\"path\":\"A.md\"}"}"#,
            #"{"type":"response.function_call_arguments.done","item_id":"provider-item-b","arguments":"{\"path\":\"B.md\"}"}"#,
        ]
        let events = try payloads.flatMap { try responses.consume($0) }
        let calls = events.compactMap { event -> ToolCall? in if case let .toolCallCompleted(call) = event { call } else { nil } }
        #expect(calls == [
            ToolCall(callID: ToolCallID("lingxi:responses-parallel:0"), toolID: ToolID("read_file"), arguments: #"{"path":"A.md"}"#),
            ToolCall(callID: ToolCallID("lingxi:responses-parallel:1"), toolID: ToolID("read_file"), arguments: #"{"path":"B.md"}"#),
        ])
        #expect(responses.references.map(\.externalCallID) == ["call-a", "call-b"])
        #expect(!events.description.contains("provider-item"))
    }

    @Test func completedArgumentsReplaceDifferentlyOrderedDeltas() throws {
        var decoder = ResponsesSSEDecoder(requestID: ModelRequestID("ordered-arguments"))
        let payloads = [
            #"{"type":"response.output_item.added","item":{"type":"function_call","id":"item","call_id":"call","name":"question","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"item","delta":"{\"question\":\"Continue?\",\"multiple\":false}"}"#,
            #"{"type":"response.function_call_arguments.done","item_id":"item","arguments":"{\"multiple\":false,\"question\":\"Continue?\"}"}"#,
        ]
        let call = try #require(try payloads.flatMap { try decoder.consume($0) }.compactMap { if case let .toolCallCompleted(call) = $0 { call } else { nil } }.first)
        #expect(call.arguments == #"{"multiple":false,"question":"Continue?"}"#)
    }

    @Test func responsesURLDoesNotAppendTwice() throws {
        let base = try #require(URL(string: "https://api.example.com/v1/responses"))
        let config = ProviderConfig(baseURL: base, apiKey: nil, model: "m", wireProtocol: .responses)
        #expect(config.responsesURL == base)
    }

    @Test func wireBodyUsesRequestModelInsteadOfProviderConfigModel() throws {
        let provider = OpenAIResponsesProvider(config: ProviderConfig(
            baseURL: try #require(URL(string: "https://api.example.com/v1")),
            apiKey: nil,
            model: "config-A",
            wireProtocol: .responses
        ))
        let request = try provider.makeURLRequest(ModelRequest(
            model: ModelID("request-B"),
            messages: [ModelMessage(role: .user, content: "hello")]
        ))
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "request-B")
    }

    @Test func reasoningToolSequenceKeepsProviderLineageAdapterLocal() async throws {
        var decoder = ResponsesSSEDecoder()
        let payloads = [
            #"{"type":"response.output_item.added","item":{"type":"reasoning","id":"reasoning-item","encrypted_content":"opaque"}}"#,
            #"{"type":"response.output_item.done","item":{"type":"reasoning","id":"reasoning-item","encrypted_content":"opaque"}}"#,
            #"{"type":"response.output_item.added","item":{"type":"function_call","id":"function-item","call_id":"call-1","name":"read_file","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"function-item","delta":"{\"path\":\"A.md\"}"}"#,
            #"{"type":"response.function_call_arguments.done","item_id":"function-item","arguments":"{\"path\":\"A.md\"}"}"#,
            #"{"type":"response.completed","response":{"id":"response-1","status":"completed"}}"#,
        ]
        _ = try payloads.flatMap { try decoder.consume($0) }
        #expect(decoder.completedCallIDs == ["call-1"])

        let provenance = ProviderProvenanceStore()
        let executionID = AgentRunID("run-1")
        let requestID = ModelRequestID("request-1")
        try await provenance.record(ProviderContinuation(requestID: requestID, executionID: executionID, wire: .responses, responseID: "response-1", references: decoder.references, orderedItems: decoder.orderedItems))
        #expect(try await provenance.continuation(for: requestID, wire: .responses)?.responseID == "response-1")

        let provider = OpenAIResponsesProvider(
            config: ProviderConfig(baseURL: URL(string: "https://api.example.com/v1")!, apiKey: nil, model: "m", wireProtocol: .responses, remoteStateEnabled: true),
            provenance: provenance
        )
        let result = ToolResult(callID: ToolCallID("call-1"), success: true, content: "A")
        let request = try provider.makeURLRequest(
            ModelRequest(model: ModelID("m"), executionID: executionID, messages: [
                ModelMessage(role: .user, content: "read"),
                ModelMessage(role: .tool, parts: [.toolResult(result)]),
                ModelMessage(role: .system, content: "project context"),
            ]),
            previousResponseID: "response-1"
        )
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["previous_response_id"] as? String == "response-1")
        #expect(json["store"] as? Bool == true)
        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["type"] as? String == "function_call_output")
        #expect(input[0]["call_id"] as? String == "call-1")
        #expect(!String(decoding: body, as: UTF8.self).contains("opaque"))
    }

    @Test func incompleteIsTerminalMaxTokens() throws {
        var decoder = ResponsesSSEDecoder()
        #expect(try decoder.consume(#"{"type":"response.incomplete","response":{"status":"incomplete"}}"#) == [.completed(.maxTokens)])
    }

    @Test func provenanceIsIsolatedByExecutionAndDisabledWithoutIdentity() async throws {
        let provenance = ProviderProvenanceStore()
        let first = AgentRunID("run-a")
        let second = AgentRunID("run-b")
        let firstRequest = ModelRequestID("request-a")
        let secondRequest = ModelRequestID("request-b")
        try await provenance.record(ProviderContinuation(requestID: firstRequest, executionID: first, wire: .responses, responseID: "response-a", references: []))
        try await provenance.record(ProviderContinuation(requestID: secondRequest, executionID: second, wire: .responses, responseID: "response-b", references: []))

        #expect(try await provenance.continuation(for: firstRequest, wire: .responses)?.responseID == "response-a")
        #expect(try await provenance.continuation(for: secondRequest, wire: .responses)?.responseID == "response-b")
        #expect(try await provenance.continuation(for: firstRequest, wire: .chatCompletions) == nil)
        await provenance.remove(first)
        #expect(try await provenance.continuation(for: firstRequest, wire: .responses) == nil)
    }

    @Test func provenanceSurvivesStoreRestartWithoutEnteringDomainIDs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requestID = ModelRequestID("durable-request")
        let domainID = ToolCallID("lingxi:durable-request:0")
        let value = ProviderContinuation(requestID: requestID, executionID: AgentRunID("run"), wire: .responses, references: [ProviderToolCallReference(wire: .responses, domainCallID: domainID, externalCallID: "provider-call")], orderedItems: [.toolCall(domainID), .opaque(Data(#"{"type":"reasoning","encrypted_content":"opaque"}"#.utf8))])
        try await ProviderProvenanceStore(directory: directory).record(value)
        #expect(try await ProviderProvenanceStore(directory: directory).continuation(for: requestID, wire: .responses) == value)
    }

    @Test func failedPayloadUsesSafeStableError() throws {
        let sentinel = "actual-key-123"
        var decoder = ResponsesSSEDecoder(sensitiveValues: [sentinel])
        let events = try decoder.consume(#"{"type":"response.failed","response":{"error":{"code":"invalid_function_output","message":"Function output was rejected for actual-key-123","param":"input[3].call_id"}}}"#)
        let error = try #require(events.compactMap { if case let .failed(error) = $0 { error } else { nil } }.first)
        #expect(error.code == .modelStream)
        #expect(error.message.contains("code=invalid_function_output"))
        #expect(error.message.contains("param=input[3].call_id"))
        #expect(error.message.contains("Function output was rejected"))
        #expect(!error.message.contains(sentinel))
        #expect(!String(decoding: try JSONEncoder().encode(error), as: UTF8.self).contains(sentinel))
    }

    @Test func topLevelErrorPreservesSanitizedDetails() throws {
        var decoder = ResponsesSSEDecoder()
        let events = try decoder.consume(#"{"type":"error","code":"rate_limit_exceeded","message":"Please retry later","param":"requests"}"#)
        let error = try #require(events.compactMap { if case let .failed(error) = $0 { error } else { nil } }.first)
        #expect(error.message.contains("event=error"))
        #expect(error.message.contains("code=rate_limit_exceeded"))
        #expect(error.message.contains("param=requests"))
        #expect(error.message.contains("Please retry later"))
    }
}
