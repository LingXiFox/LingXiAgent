import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

@Suite struct ResponsesGoldenReplayTests {
    private func fixtureURL() -> URL {
        let currentFile = URL(fileURLWithPath: #filePath)
        let root = currentFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("Docs/responses-record-20260907-225411")
    }

    @Test func replayFullFourStepToolCycleFromGoldenFixture() throws {
        let fixtureDir = fixtureURL()
        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            Issue.record("Golden fixture directory not found: \(fixtureDir.path)")
            return
        }

        // ==========================================
        // Step 1: User requests prime number generator
        // Provider emits shell tool call to create primes.cpp
        // ==========================================
        let step1SSE = try String(contentsOf: fixtureDir.appendingPathComponent("step-01.sse"), encoding: .utf8)
        var step1Decoder = ResponsesSSEDecoder(requestID: ModelRequestID("req-step-1"))
        let step1Events = try step1Decoder.feedSSEText(step1SSE)

        // 验证 Step 1 状态机与事件：
        // 1. toolCallStarted
        // 2. toolCallDelta
        // 3. toolCallCompleted (shell: cat > primes.cpp)
        // 4. usage (input: 451, output: 821, reasoning: 818)
        // 5. completed(.toolCalls)
        let step1Calls = step1Events.compactMap { if case let .toolCallCompleted(call) = $0 { call } else { nil } }
        #expect(step1Calls.count == 1)
        let step1Call = try #require(step1Calls.first)
        #expect(step1Call.toolID.rawValue == "shell")
        #expect(step1Call.arguments.contains("primes.cpp"))

        let step1Usage = step1Events.compactMap { if case let .usage(u) = $0 { u } else { nil } }
        #expect(step1Usage.count == 1)
        #expect(step1Usage.first?.reasoningTokens == 818)
        #expect(step1Usage.first?.inputTokens == 451)

        let step1Completed = step1Events.compactMap { if case let .completed(r) = $0 { r } else { nil } }
        #expect(step1Completed == [.toolCalls])

        // 验证：尽管消耗了 818 reasoning tokens，但因为 wire 没有 reasoning delta，绝不伪造 reasoning delta
        let step1ReasoningDeltas = step1Events.compactMap { if case let .reasoningDelta(t) = $0 { t } else { nil } }
        #expect(step1ReasoningDeltas.isEmpty)

        // ==========================================
        // Continuation from Step 1 to Step 2:
        // Tool executed -> Build ModelRequest for Step 2
        // Verify Stateless continuation body
        // ==========================================
        let step1ResultJSON = try Data(contentsOf: fixtureDir.appendingPathComponent("tool-01-01.result.json"))
        let step1ResultString = String(decoding: step1ResultJSON, as: UTF8.self)
        let step1ToolResult = ToolResult(callID: step1Call.callID, success: true, content: step1ResultString)

        let shellTool = ToolDefinition(
            id: ToolID("shell"),
            description: "Execute a shell command",
            inputSchema: ToolInputSchema(
                properties: ["command": ToolInputProperty(type: .string, description: "Shell command")],
                required: ["command"]
            ),
            capability: ToolCapability(readOnly: false)
        )

        let step2Request = ModelRequest(
            requestID: ModelRequestID("req-step-2"),
            model: ModelID("grok-composer-2.5-fast"),
            system: "You are an autonomous coding agent running on macOS.",
            messages: [
                ModelMessage(role: .user, content: "请在我的桌面创建一个 C++ 程序，输出 0 到 10000 之间的所有质数。"),
                ModelMessage(role: .assistant, parts: [.toolCall(step1Call)]),
                ModelMessage(role: .tool, parts: [.toolResult(step1ToolResult)]),
            ],
            tools: [shellTool],
            reasoning: "high"
        )

        let step2BodyData = try OpenAIResponsesProvider.makeRequestBody(step2Request)
        let step2BodyJSON = try #require(JSONSerialization.jsonObject(with: step2BodyData) as? [String: Any])
        #expect(step2BodyJSON["store"] as? Bool == false)
        #expect(step2BodyJSON["previous_response_id"] == nil)

        let step2Input = try #require(step2BodyJSON["input"] as? [[String: Any]])
        #expect(step2Input.count == 3) // user message, function_call, function_call_output
        #expect(step2Input[0]["role"] as? String == "user")
        #expect(step2Input[1]["type"] as? String == "function_call")
        #expect(step2Input[1]["name"] as? String == "shell")
        #expect(step2Input[2]["type"] as? String == "function_call_output")

        // ==========================================
        // Step 2: Replay step-02.sse (compile command)
        // ==========================================
        let step2SSE = try String(contentsOf: fixtureDir.appendingPathComponent("step-02.sse"), encoding: .utf8)
        var step2Decoder = ResponsesSSEDecoder(requestID: ModelRequestID("req-step-2"))
        let step2Events = try step2Decoder.feedSSEText(step2SSE)

        let step2Calls = step2Events.compactMap { if case let .toolCallCompleted(call) = $0 { call } else { nil } }
        #expect(step2Calls.count == 1)
        let step2Call = try #require(step2Calls.first)
        #expect(step2Call.toolID.rawValue == "shell")
        #expect(step2Call.arguments.contains("clang++") || step2Call.arguments.contains("primes"))

        let step2Completed = step2Events.compactMap { if case let .completed(r) = $0 { r } else { nil } }
        #expect(step2Completed == [.toolCalls])

        // ==========================================
        // Step 3: Replay step-03.sse (run binary)
        // ==========================================
        let step3SSE = try String(contentsOf: fixtureDir.appendingPathComponent("step-03.sse"), encoding: .utf8)
        var step3Decoder = ResponsesSSEDecoder(requestID: ModelRequestID("req-step-3"))
        let step3Events = try step3Decoder.feedSSEText(step3SSE)

        let step3Calls = step3Events.compactMap { if case let .toolCallCompleted(call) = $0 { call } else { nil } }
        #expect(step3Calls.count == 1)
        let step3Call = try #require(step3Calls.first)
        #expect(step3Call.toolID.rawValue == "shell")

        let step3Completed = step3Events.compactMap { if case let .completed(r) = $0 { r } else { nil } }
        #expect(step3Completed == [.toolCalls])

        // ==========================================
        // Step 4: Replay step-04.sse (final assistant response stream)
        // ==========================================
        let step4SSE = try String(contentsOf: fixtureDir.appendingPathComponent("step-04.sse"), encoding: .utf8)
        var step4Decoder = ResponsesSSEDecoder(requestID: ModelRequestID("req-step-4"))
        let step4Events = try step4Decoder.feedSSEText(step4SSE)

        let textDeltas = step4Events.compactMap { if case let .textDelta(t) = $0 { t } else { nil } }
        #expect(!textDeltas.isEmpty)
        let fullEmittedText = textDeltas.joined()
        #expect(fullEmittedText.contains("完成") || fullEmittedText.contains("质数") || fullEmittedText.contains("文件"))

        let step4Completed = step4Events.compactMap { if case let .completed(r) = $0 { r } else { nil } }
        #expect(step4Completed == [.stop])

        let step4Usage = step4Events.compactMap { if case let .usage(u) = $0 { u } else { nil } }
        #expect(!step4Usage.isEmpty)
    }
}
