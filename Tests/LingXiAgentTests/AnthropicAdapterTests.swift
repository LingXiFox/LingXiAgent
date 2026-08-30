import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

struct AnthropicAdapterTests {
    @Test func requestUsesNativeMessagesToolBlocksAndHeaders() throws {
        let call = ToolCall(callID: ToolCallID("tool-use-1"), toolID: ToolID("read_file"), arguments: #"{"path":"README.md"}"#)
        let result = ToolResult(callID: call.callID, success: true, content: "LingXi")
        let provider = AnthropicMessagesProvider(config: ProviderConfig(
            baseURL: try #require(URL(string: "https://api.anthropic.com")),
            authentication: .header(name: "x-api-key", value: "sentinel"),
            model: "claude-test",
            wireProtocol: .anthropicMessages,
            maxOutputTokens: 2_048
        ))
        let request = try provider.makeURLRequest(ModelRequest(
            model: ModelID("claude-request"),
            system: "system",
            messages: [
                ModelMessage(role: .user, content: "read"),
                ModelMessage(role: .assistant, parts: [.toolCall(call)]),
                ModelMessage(role: .tool, parts: [.toolResult(result)]),
            ],
            tools: [tool()]
        ))
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let assistant = try #require(messages[1]["content"] as? [[String: Any]])
        let toolResult = try #require(messages[2]["content"] as? [[String: Any]])

        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sentinel")
        #expect(json["model"] as? String == "claude-request")
        #expect(json["max_tokens"] as? Int == 2_048)
        #expect(json["system"] as? String == "system")
        #expect(assistant[0]["type"] as? String == "tool_use")
        #expect(assistant[0]["id"] as? String == "tool-use-1")
        #expect(toolResult[0]["type"] as? String == "tool_result")
        #expect(toolResult[0]["tool_use_id"] as? String == "tool-use-1")
    }

    @Test func streamDecoderCorrelatesToolUseAndMapsTerminalEvents() throws {
        var decoder = AnthropicSSEDecoder()
        let payloads = [
            #"{"type":"message_start","message":{"usage":{"input_tokens":12,"cache_read_input_tokens":3}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool-use-1","name":"read_file","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"README.md\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}"#,
            #"{"type":"message_stop"}"#,
        ]
        let events = try payloads.flatMap { try decoder.consume($0) }

        #expect(events.contains(.textDelta("hello")))
        #expect(events.contains(.toolCallStarted(callID: ToolCallID("tool-use-1"), toolID: ToolID("read_file"))))
        #expect(events.contains(.toolCallCompleted(ToolCall(callID: ToolCallID("tool-use-1"), toolID: ToolID("read_file"), arguments: #"{"path":"README.md"}"#))))
        #expect(events.contains(.usage(ModelUsage(inputTokens: 12, outputTokens: nil, reasoningTokens: nil, cacheReadTokens: 3, cacheWriteTokens: nil))))
        #expect(events.contains(.completed(.toolCalls)))
    }

    private func tool() -> ToolDefinition {
        ToolDefinition(
            id: ToolID("read_file"),
            description: "Read a file",
            inputSchema: ToolInputSchema(properties: ["path": ToolInputProperty(type: .string, description: "Path")], required: ["path"]),
            capability: ToolCapability(readOnly: true)
        )
    }
}
