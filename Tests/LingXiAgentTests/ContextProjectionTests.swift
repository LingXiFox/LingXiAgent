import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

@Suite struct ContextProjectionTests {

    @Test func fullSendCountMaintainsFullContentForFirstTwoTurns() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            observationProjectionEnabled: true,
            objectizationThreshold: 10_240, // 10KB
            fullSendCount: 2
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let projection = ContextProjection(configuration: config)

        let sID = SessionID("proj-session-1")
        let toolCallID = ToolCallID("call_full_send")
        let largeContent = String(repeating: "Row data content 1234567890\n", count: 400) // ~11KB

        let toolResult = ToolResult(
            callID: toolCallID,
            success: true,
            content: largeContent,
            toolName: "shell"
        )
        let toolMsg = Message(
            id: MessageID("msg_tool_1"),
            role: .tool,
            parts: [.toolResult(toolResult)],
            createdAt: .now
        )
        let entry = ContextEntry(
            messageID: toolMsg.id,
            role: .tool,
            source: .toolResult,
            part: .toolResult(toolResult)
        )

        // Turn 1: 0 assistant messages after toolMsg
        let session1 = Session(id: sID, createdAt: .now, messages: [toolMsg])
        let projected1 = await projection.project(entries: [entry], session: session1, ecoreStore: store)
        try #require(projected1.count == 1)
        if case let .toolResult(res1) = projected1[0].part {
            #expect(res1.content == largeContent) // Full content!
            #expect(res1.content.contains("Row data content") == true)
        } else {
            Issue.record("Expected toolResult part")
        }

        // Turn 2: 1 assistant message after toolMsg
        let asstMsg1 = Message(id: MessageID("msg_asst_1"), role: .assistant, parts: [.text("First step done")], createdAt: .now)
        let session2 = Session(id: sID, createdAt: .now, messages: [toolMsg, asstMsg1])
        let projected2 = await projection.project(entries: [entry], session: session2, ecoreStore: store)
        if case let .toolResult(res2) = projected2[0].part {
            #expect(res2.content == largeContent) // Still full content!
        } else {
            Issue.record("Expected toolResult part")
        }

        // Turn 3: 2 assistant messages after toolMsg -> Transition to Placeholder!
        let asstMsg2 = Message(id: MessageID("msg_asst_2"), role: .assistant, parts: [.text("Second step done")], createdAt: .now)
        let session3 = Session(id: sID, createdAt: .now, messages: [toolMsg, asstMsg1, asstMsg2])
        let projected3 = await projection.project(entries: [entry], session: session3, ecoreStore: store)
        if case let .toolResult(res3) = projected3[0].part {
            #expect(res3.content != largeContent)
            #expect(res3.content.contains("[Context Object:") == true)
            #expect(res3.content.contains("To retrieve additional lines or full content, use `context_recall") == true)
            #expect(res3.content.count < 1500) // ~1KB placeholder
        } else {
            Issue.record("Expected toolResult part")
        }
    }

    @Test func contextRecallToolExecution() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            objectizationThreshold: 1024
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sID = SessionID("s-recall-tool")

        // 存储一个大对象
        var lines: [String] = []
        for i in 1...100 {
            lines.append("Item #\(i): Important log entry details")
        }
        let fullText = lines.joined(separator: "\n") + "\n"

        let meta = await store.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_log"),
            toolName: "shell",
            content: fullText,
            force: true
        )
        guard let objectID = meta?.objectID else {
            Issue.record("Failed to save object")
            return
        }

        let recallTool = ContextRecallTool(ecoreStore: store)

        // 1. 成功召回切片
        let callArgs = "{\"id\":\"\(objectID.rawValue)\",\"offset\":0,\"limit_bytes\":1000,\"limit_lines\":20}"
        let output = try await ToolExecutionContext.$sessionID.withValue(sID) {
            try await recallTool.execute(arguments: callArgs, profile: .workspace)
        }

        #expect(output.contains("[Context Object Slice: \(objectID.rawValue)]"))
        #expect(output.contains("Lines: 1 - 20 of 100"))
        #expect(output.contains("Has More: true"))
        #expect(output.contains("Item #1:"))
        #expect(output.contains("Item #20:"))

        // 2. 召回不存在的对象 -> 友好提示
        let notFoundArgs = "{\"id\":\"obj_unknown_call999_00000000\"}"
        let notFoundOut = try await ToolExecutionContext.$sessionID.withValue(sID) {
            try await recallTool.execute(arguments: notFoundArgs, profile: .workspace)
        }
        #expect(notFoundOut.contains("not found"))

        // 3. 非法字符 ID -> 错误提示
        let invalidArgs = "{\"id\":\"../evil_path\"}"
        let invalidOut = try await ToolExecutionContext.$sessionID.withValue(sID) {
            try await recallTool.execute(arguments: invalidArgs, profile: .workspace)
        }
        #expect(invalidOut.contains("Invalid ContextObjectID format"))
    }

    @Test func observationProjectionFeatureFlagDisabled() async {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            observationProjectionEnabled: false, // OFF
            objectizationThreshold: 10_240,
            fullSendCount: 2
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let projection = ContextProjection(configuration: config)

        let sID = SessionID("proj-session-off")
        let toolCallID = ToolCallID("call_off")
        let largeContent = String(repeating: "Row data content\n", count: 800) // ~13KB

        let toolResult = ToolResult(
            callID: toolCallID,
            success: true,
            content: largeContent,
            toolName: "shell"
        )
        let toolMsg = Message(id: MessageID("msg_tool_off"), role: .tool, parts: [.toolResult(toolResult)], createdAt: .now)
        let asst1 = Message(id: MessageID("msg_asst_1"), role: .assistant, parts: [.text("1")], createdAt: .now)
        let asst2 = Message(id: MessageID("msg_asst_2"), role: .assistant, parts: [.text("2")], createdAt: .now)
        let asst3 = Message(id: MessageID("msg_asst_3"), role: .assistant, parts: [.text("3")], createdAt: .now)
        let session = Session(id: sID, createdAt: .now, messages: [toolMsg, asst1, asst2, asst3])

        let entry = ContextEntry(messageID: toolMsg.id, role: .tool, source: .toolResult, part: .toolResult(toolResult))
        let projected = await projection.project(entries: [entry], session: session, ecoreStore: store)

        // Feature flag is off, so full content must always be returned
        if case let .toolResult(res) = projected[0].part {
            #expect(res.content == largeContent)
        } else {
            Issue.record("Expected toolResult")
        }
    }
}
