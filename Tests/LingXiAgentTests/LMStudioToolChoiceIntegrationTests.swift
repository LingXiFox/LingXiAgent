import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

/// Opt-in real HTTP/SSE integration; no fake transport and no file tool execution.
/// LINGXI_LMSTUDIO_BASE_URL=http://host:port/v1 LINGXI_LMSTUDIO_MODEL=loaded-instance swift test --filter LMStudioToolChoiceIntegrationTests
@Suite("Live LM Studio tool choice", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["LINGXI_LMSTUDIO_BASE_URL"] != nil))
struct LMStudioToolChoiceIntegrationTests {
    @Test func autoAllowsTextRequiredParsesWriteFile() async throws {
        let env = ProcessInfo.processInfo.environment
        let baseURL = try #require(env["LINGXI_LMSTUDIO_BASE_URL"].flatMap(URL.init(string:)))
        let model = try #require(env["LINGXI_LMSTUDIO_MODEL"], "Provide a currently loaded model instance")
        let provider = OpenAICompatibleProvider(config: ProviderConfig(baseURL: baseURL, apiKey: nil, model: model),
            wireExtension: LMStudioChatExtension(reasoningToggle: true, reasoningDefaultOn: true,
                                                externalDraftModel: nil, mtpConfigured: false, sink: { _ in }))
        let tool = ToolDefinition(id: ToolID("write_file"), description: "Write UTF-8 text to a file at path.",
                                  inputSchema: ToolInputSchema(properties: [
                                    "path": ToolInputProperty(type: .string, description: "File path"),
                                    "content": ToolInputProperty(type: .string, description: "File content")
                                  ], required: ["path", "content"]), capability: ToolCapability(readOnly: false))
        func events(choice: ToolChoice, prompt: String) async throws -> [ModelEvent] {
            let request = ModelRequest(model: ModelID(model),
                system: "You are a file assistant. Use write_file when asked to create a file. Never claim a file exists before a tool result.",
                messages: [ModelMessage(role: .user, content: prompt)], tools: [tool], toolChoice: choice,
                reasoning: "off", overallTimeoutSeconds: 120, idleTimeoutSeconds: 30)
            var events: [ModelEvent] = []
            for try await event in try await provider.stream(request) { events.append(event) }
            return events
        }
        let auto = try await events(choice: .auto, prompt: "Explain in one short sentence what a text file is. Do not create any files.")
        #expect(auto.contains { if case let .textDelta(text) = $0 { return !text.isEmpty }; return false }, "Auto must allow a normal text answer")
        #expect(!auto.contains { if case .toolCallCompleted = $0 { return true }; return false })
        #expect(auto.contains(.completed(.stop)))

        let actionPrompt = "Create /tmp/lingxi-tool-choice-probe.txt with the exact content hello. Call write_file now."
        let autoAction = try await events(choice: .auto, prompt: actionPrompt)
        #expect(autoAction.contains { event in
            if case let .textDelta(text) = event { return !text.isEmpty }
            if case .toolCallCompleted = event { return true }
            return false
        }, "Auto may return text or tools for the action prompt")
        let required = try await events(choice: .required, prompt: actionPrompt)
        let calls = required.compactMap { event -> ToolCall? in
            if case let .toolCallCompleted(call) = event { return call }; return nil
        }
        let call = try #require(calls.first { $0.toolID == tool.id }, "Required must produce a parsed write_file ToolCall; text alone fails")
        #expect(!call.callID.rawValue.isEmpty)
        let args = try #require(JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: String])
        #expect(args["path"] == "/tmp/lingxi-tool-choice-probe.txt")
        #expect(args["content"] == "hello")
        #expect(required.contains(.completed(.toolCalls)))
    }
}
