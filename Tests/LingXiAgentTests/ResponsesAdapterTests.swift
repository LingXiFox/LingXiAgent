import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import LingXiProtocol
@testable import LingXiCore

struct ResponsesAdapterTests {
    @Test func assembledInstructionFragmentsUseOnlyTheAuthoritativeInstructionsField() async throws {
        let engine = PCoreContextEngine()
        let session = Session(id: SessionID("native-prefix"), createdAt: .now, messages: [
            Message(id: MessageID("u"), role: .user, content: "Repair the failing test", createdAt: .now),
            Message(id: MessageID("a"), role: .assistant, content: "Checking the failure", createdAt: .now),
        ])
        let system = "Environment facts:\nworkspace: /tmp/isolated-native-probe\n\nStable instruction block one.\n\nStable instruction block two."
        var entries = await engine.entries(for: session, systemContext: system, systemContextAtBeginning: false)
        entries.append(.init(messageID: MessageID("project-data"), role: .system, source: .projectPage,
            part: .text("[Project context] Retrieved source code")))
        entries.append(.init(messageID: ContextCompactor.eCoreIndexMessageID, role: .system, source: .derivedPage,
            part: .text("[E-Core index]\nreference=ref_native_prefix"), segment: .eCoreRetrievalProjection))
        let snapshot = await engine.snapshot(for: session, activeEntries: entries, systemContext: system)
        let messages = snapshot.modelMessages()
        #expect(messages.filter { $0.role == .system }.count > 1)
        let plan = CanonicalCachePlan(epochIdentity: .init(epoch: 1), immutableBase: .init(systemPrompt: system),
            appendOnlyContext: .init(messages: messages), structuralHealth: .init(stablePrefixHash: "fixed"))
        let request = ModelRequest(model: ModelID("runtime-instance"), messages: messages, cachePlan: plan)
        let body = try OpenAIResponsesProvider.makeRequestBody(request)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["instructions"] as? String == system)
        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.compactMap { $0["role"] as? String } == ["user", "assistant", "user", "user"])
        #expect(input[2]["content"] as? String == "[Project context] Retrieved source code")
        #expect(input.last?["content"] as? String == "[E-Core index]\nreference=ref_native_prefix")
        #expect(String(decoding: body, as: UTF8.self).components(separatedBy: "Stable instruction block one.").count == 2)
        #expect(request.messages == messages && request.cachePlan == plan)
    }

    @Test func pEContextSegmentsRemainDataWithoutLateSystemMessages() throws {
        let call = ToolCall(callID: ToolCallID("failed-test"), toolID: ToolID("shell"), arguments: "{}")
        let result = ToolResult(callID: call.callID, success: false,
            content: "NameError: name 'select' is not defined", toolName: "shell", exitCode: 1)
        let messages: [ModelMessage] = [
            .init(role: .user, content: "Repair the failing test"),
            .init(role: .assistant, parts: [.toolCall(call)], segment: .recalledOccurrence),
            .init(role: .tool, parts: [.toolResult(result)], segment: .recalledOccurrence),
            .init(role: .system, content: "[Restored session context]\nNameError: archived evidence", segment: .recalledOccurrence),
            .init(role: .system, content: "[E-Core index]\nreference=ref_archived_failure", segment: .eCoreRetrievalProjection),
        ]
        let plan = CanonicalCachePlan(epochIdentity: .init(epoch: 1),
            immutableBase: .init(systemPrompt: "Stable instructions"),
            appendOnlyContext: .init(messages: messages), structuralHealth: .init(stablePrefixHash: "fixed"))
        let request = ModelRequest(model: ModelID("runtime-instance"), messages: messages, cachePlan: plan)
        let provider = OpenAIResponsesProvider(config: ProviderConfig(baseURL: URL(string: "https://example.invalid/v1")!,
            apiKey: nil, model: "runtime-instance", wireProtocol: .responses, remoteStateEnabled: true))
        let data = try #require(provider.makeURLRequest(request, previousResponseID: "old-history").httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try #require(json["input"] as? [[String: Any]])
        #expect(json["instructions"] as? String == "Stable instructions")
        #expect(json["previous_response_id"] == nil)
        #expect(input.compactMap { $0["role"] as? String } == ["user", "user", "user"])
        #expect(input[1]["type"] as? String == "function_call")
        #expect(input[2]["type"] as? String == "function_call_output")
        #expect((input[2]["output"] as? String)?.contains("NameError: name 'select' is not defined") == true)
        #expect(input[3]["content"] as? String == messages[3].content)
        #expect(input[4]["content"] as? String == messages[4].content)
        #expect(request.messages == messages)
        #expect(request.cachePlan == plan)
    }

    @Test func reasoningTogglesUseResponsesEffortValuesWithoutChangingDomainRequest() throws {
        for (domain, expected) in [("off", "none"), ("auto", nil), ("high", "high")] as [(String, String?)] {
            let request = ModelRequest(model: ModelID("local-instance"), messages: [], reasoning: domain)
            let json = try #require(JSONSerialization.jsonObject(with: OpenAIResponsesProvider.makeRequestBody(request)) as? [String: Any])
            #expect((json["reasoning"] as? [String: String])?["effort"] == expected)
            #expect(request.reasoning == domain)
        }
    }

    @Test func lmStudioReasoningAndCachedUsageAreDecodedFromCompletedSSE() throws {
        var decoder = ResponsesSSEDecoder()
        #expect(try decoder.consume(#"{"type":"response.reasoning_text.delta","delta":"Checking"}"#) == [.reasoningDelta("Checking")])
        let events = try decoder.consume(#"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1474,"output_tokens":128,"total_tokens":1602,"input_tokens_details":{"cached_tokens":1470},"output_tokens_details":{"reasoning_tokens":128}}}}"#)
        #expect(events.contains(.usage(ModelUsage(inputTokens: 1474, outputTokens: 128, reasoningTokens: 128, cacheReadTokens: 1470))))
        var missing = ResponsesSSEDecoder()
        let noCache = try missing.consume(#"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1474,"output_tokens":1}}}"#)
        #expect(noCache.contains(.usage(ModelUsage(inputTokens: 1474, outputTokens: 1))))
    }

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

    @Test func userImagesAreEncodedByEveryWireAdapter() throws {
        let image = Data([1, 2, 3])
        let request = ModelRequest(model: ModelID("m"), messages: [
            ModelMessage(role: .user, parts: [.text("看图"), .image(mediaType: "image/png", data: image)])
        ])
        let base64 = image.base64EncodedString()

        let responses = try #require(JSONSerialization.jsonObject(
            with: OpenAIResponsesProvider.makeRequestBody(request)) as? [String: Any])
        let input = try #require((responses["input"] as? [[String: Any]])?.first)
        let parts = try #require(input["content"] as? [[String: String]])
        #expect(parts == [["type": "input_text", "text": "看图"],
                          ["type": "input_image", "image_url": "data:image/png;base64,\(base64)"]])

        let chat = try #require(JSONSerialization.jsonObject(
            with: OpenAICompatibleProvider.makeRequestBody(request)) as? [String: Any])
        let chatContent = try #require((chat["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        #expect(chatContent.first?["type"] as? String == "text")
        #expect((chatContent.last?["image_url"] as? [String: String])?["url"] == "data:image/png;base64,\(base64)")

        let anthropic = try #require(JSONSerialization.jsonObject(
            with: AnthropicMessagesProvider.makeRequestBody(request)) as? [String: Any])
        let block = try #require(((anthropic["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.last)
        #expect(block["type"] as? String == "image")
        #expect(block["source"] as? [String: String] == ["type": "base64", "media_type": "image/png", "data": base64])
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

    @Test func codexBackendForcesStoreFalse() throws {
        let config = ProviderConfig(
            baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!,
            apiKey: "mock-token",
            model: "gpt-5.6-luna",
            wireProtocol: .responses,
            remoteStateEnabled: true // Even if mistakenly set to true, codex backend must force store to false
        )
        let provider = OpenAIResponsesProvider(config: config)
        let request = ModelRequest(
            model: ModelID("gpt-5.6-luna"),
            messages: [ModelMessage(role: .user, content: "Hello")]
        )
        let urlRequest = try provider.makeURLRequest(request)
        let bodyData = try #require(urlRequest.httpBody)
        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(json?["store"] as? Bool == false)
    }
}
