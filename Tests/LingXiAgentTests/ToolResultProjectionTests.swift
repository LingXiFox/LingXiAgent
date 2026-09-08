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
        let error = try #require(JSONSerialization.jsonObject(with: Data(projected.content.utf8)) as? [String: Any])
        #expect((error["error"] as? [String: String]) == ["code": "commandFailed", "message": "Command failed"])
        #expect(error["errorKind"] as? String == "commandFailed")
        #expect(error["retryability"] as? String == "none")
        #expect(error["durationMilliseconds"] as? Int == 0)
        #expect(error["exitCode"] as? Int == 1)
        #expect(error["stderrSummary"] as? String == "internal stderr")
        #expect(error["permissionDenied"] as? Bool == false)
        #expect(error["scopeDenied"] as? Bool == false)
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

    @Test func globProjectionEnforcesBudgetWithSummaryAndPagination() throws {
        let matches = (1...426).map { "Sources/File\($0).swift" }
        let jsonMatches = String(decoding: try JSONEncoder().encode(matches), as: UTF8.self)
        let rawResult = ToolResult(
            callID: ToolCallID("glob-1"),
            success: true,
            content: jsonMatches,
            toolName: "glob"
        )

        let projected = ModelToolResultProjection.project(rawResult)
        #expect(projected.summary == "Glob · 426 matches · showing 30")
        #expect(projected.totalCount == 426)
        #expect(projected.shownCount == 30)
        #expect(projected.truncated == true)
        #expect(projected.page == 1)
        #expect(projected.items?.count == 30)

        // Wire representation does not resend entire repo paths
        let dict = try JSONSerialization.jsonObject(with: Data(projected.content.utf8)) as! [String: Any]
        #expect((dict["totalCount"] as? Int) == 426)
        #expect((dict["shownCount"] as? Int) == 30)
        #expect((dict["truncated"] as? Bool) == true)
        let projectedMatches = dict["matches"] as! [String]
        #expect(projectedMatches.count == 30)
        #expect(projectedMatches.first == "Sources/File1.swift")
        #expect(projectedMatches.last == "Sources/File30.swift")
    }

    @Test func listDirectoryProjectionEnforcesBudget() throws {
        let entries = (1...100).map { "file\($0).txt\tfile\t123" }.joined(separator: "\n")
        let rawResult = ToolResult(
            callID: ToolCallID("list-1"),
            success: true,
            content: entries,
            toolName: "list_directory"
        )

        let projected = ModelToolResultProjection.project(rawResult)
        #expect(projected.summary == "ListDirectory · 100 entries · showing 30")
        #expect(projected.totalCount == 100)
        #expect(projected.shownCount == 30)
        #expect(projected.truncated == true)
        #expect(projected.items?.count == 30)
    }

    @Test func smallGlobIsNotTruncated() throws {
        let matches = ["A.swift", "B.swift", "C.swift"]
        let jsonMatches = String(decoding: try JSONEncoder().encode(matches), as: UTF8.self)
        let rawResult = ToolResult(
            callID: ToolCallID("glob-small"),
            success: true,
            content: jsonMatches,
            toolName: "glob"
        )

        let projected = ModelToolResultProjection.project(rawResult)
        #expect(projected.summary == "Glob · 3 matches")
        #expect(projected.totalCount == 3)
        #expect(projected.shownCount == 3)
        #expect(projected.truncated == false)
    }

    @Test func largeReadFileProjectionEnforcesBudget() throws {
        let lines = (1...200).map { "line \($0): content" }.joined(separator: "\n")
        let rawResult = ToolResult(
            callID: ToolCallID("read-large"),
            success: true,
            content: lines,
            toolName: "read_file"
        )

        let projected = ModelToolResultProjection.project(rawResult)
        #expect(projected.summary == "ReadFile · 200 lines · showing 60")
        #expect(projected.totalCount == 200)
        #expect(projected.shownCount == 60)
        #expect(projected.truncated == true)
        #expect(projected.items?.count == 60)
    }

    @Test func smallReadFileIsNotTruncated() throws {
        let lines = "line 1\nline 2\nline 3"
        let rawResult = ToolResult(
            callID: ToolCallID("read-small"),
            success: true,
            content: lines,
            toolName: "read_file"
        )

        let projected = ModelToolResultProjection.project(rawResult)
        #expect(projected.summary == "")
        #expect(projected.totalCount == 3)
        #expect(projected.shownCount == 3)
        #expect(projected.truncated == false)
        #expect(projected.content == lines)
    }
}
