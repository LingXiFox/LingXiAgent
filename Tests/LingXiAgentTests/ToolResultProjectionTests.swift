import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

struct ToolResultProjectionTests {
    private func rich(success: Bool = true) -> ToolResult {
        ToolResult(
            callID: ToolCallID("call-1"), success: success, content: success ? "done" : "internal failure detail",
            error: success ? nil : ToolError(code: "commandFailed", message: "Command failed"), toolName: "apply_patch",
            output: ToolOutputMetadata(truncated: true, totalCharacters: 1000, outputBlobRef: "blob://internal/output"),
            exitCode: success ? 0 : 1,
            diagnostics: ToolDiagnostics(command: "swift test", stdout: "", stderr: "internal stderr"),
            changedFiles: ["Sources/A.swift", "Tests/ATests.swift"], continuation: "blob://internal/output"
        )
    }

    @Test func richMetadataDoesNotChangeStableProjection() throws {
        let baseline = ToolResult(callID: ToolCallID("call-1"), success: true, content: "done", toolName: "apply_patch")
        #expect(ModelToolResultProjection.project(rich()) == ModelToolResultProjection.project(baseline))
        #expect(rich().changedFiles == ["Sources/A.swift", "Tests/ATests.swift"])
        #expect(rich().diagnostics?.stderr == "internal stderr")
        #expect(rich().continuation == "blob://internal/output")
    }

    @Test func failureProjectionUsesP14ErrorRepresentation() throws {
        let projected = ModelToolResultProjection.project(rich(success: false))
        #expect(projected.callID == ToolCallID("call-1"))
        #expect(projected.success == false)
        let error = try JSONSerialization.jsonObject(with: Data(projected.content.utf8)) as? [String: String]
        #expect(error == ["code": "commandFailed", "message": "Command failed"])
        #expect(!projected.content.contains("internal stderr"))
        #expect(!projected.content.contains("blob://"))
    }

    @Test func projectionKeepsAllProviderWiresStable() throws {
        let result = rich()
        let request = ModelRequest(model: ModelID("m"), messages: [
            ModelMessage(role: .assistant, parts: [.toolCall(ToolCall(callID: result.callID, toolID: ToolID("apply_patch"), arguments: "{}"))]),
            ModelMessage(role: .tool, parts: [.toolResult(result)]),
        ])
        let chat = try JSONSerialization.jsonObject(with: OpenAICompatibleProvider.makeRequestBody(request)) as! [String: Any]
        let responses = try JSONSerialization.jsonObject(with: OpenAIResponsesProvider.makeRequestBody(request)) as! [String: Any]
        let anthropic = try JSONSerialization.jsonObject(with: AnthropicMessagesProvider.makeRequestBody(request, maxOutputTokens: 64)) as! [String: Any]
        #expect((((chat["messages"] as! [[String: Any]])[1]["content"] as? String) == "done"))
        #expect((((responses["input"] as! [[String: Any]])[1]["output"] as? String) == "done"))
        let content = ((anthropic["messages"] as! [[String: Any]])[1]["content"] as! [[String: Any]])[0]
        #expect(content["tool_use_id"] as? String == "call-1")
        #expect(content["content"] as? String == "done")
    }

    @Test func legacyPersistedResultDecodesWithoutRichFields() throws {
        let legacy = #"{"callID":{"rawValue":"call-1"},"success":true,"content":"done","error":null,"toolName":"read_file","outcome":"success","summary":"","metadata":{},"provenance":null,"touchedResources":[],"timing":{"milliseconds":0},"output":{"truncated":false,"totalCharacters":4,"totalBytes":4,"visibleCharacters":4,"visibleBytes":4,"outputBlobRef":null},"exitCode":null}"#
        let decoded = try JSONDecoder().decode(ToolResult.self, from: Data(legacy.utf8))
        #expect(decoded.changedFiles.isEmpty)
        #expect(decoded.diagnostics == nil)
        #expect(decoded.continuation == nil)
        #expect(ModelToolResultProjection.project(decoded).content == "done")
    }
}
