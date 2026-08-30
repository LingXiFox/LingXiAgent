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
            ], tools: [tool()], reasoning: "medium"), model: "gpt")
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["instructions"] as? String == "system instruction")
        #expect(json["reasoning"] as? [String: String] == ["effort": "medium"])
        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == [nil, nil, "function_call", "function_call_output"])
        #expect(input[2]["call_id"] as? String == "call-1")
        #expect(input[3]["output"] as? String == "LingXiAgent")
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools[0]["name"] as? String == "read_file")
    }

    @Test func parallelCallsMapToTheSameDomainEventsAsChatCompletions() throws {
        var responses = ResponsesSSEDecoder()
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
            ToolCall(callID: ToolCallID("call-a"), toolID: ToolID("read_file"), arguments: #"{"path":"A.md"}"#),
            ToolCall(callID: ToolCallID("call-b"), toolID: ToolID("read_file"), arguments: #"{"path":"B.md"}"#),
        ])
        #expect(!events.description.contains("provider-item"))
    }

    @Test func responsesURLDoesNotAppendTwice() throws {
        let base = try #require(URL(string: "https://api.example.com/v1/responses"))
        let config = ProviderConfig(baseURL: base, apiKey: nil, model: "m", wireProtocol: .responses)
        #expect(config.responsesURL == base)
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

        let provenance = ResponsesProvenanceStore()
        await provenance.record(responseID: "response-1", callIDs: decoder.completedCallIDs)
        #expect(await provenance.responseID(for: ["call-1"]) == "response-1")

        let provider = OpenAIResponsesProvider(
            config: ProviderConfig(baseURL: URL(string: "https://api.example.com/v1")!, apiKey: nil, model: "m", wireProtocol: .responses),
            provenance: provenance
        )
        let result = ToolResult(callID: ToolCallID("call-1"), success: true, content: "A")
        let request = try provider.makeURLRequest(
            ModelRequest(model: ModelID("m"), messages: [
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
}
