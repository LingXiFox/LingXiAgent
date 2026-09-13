import Foundation
import Testing
import LingXiProtocol
import LingXiClient
@testable import LingXiCore
@testable import LingXiApplication
@testable import LingXiTUI

struct OpenAIContractAndToolCallSanitizationTests {

    @Test func sanitizeMessagesForContract_prunesOrphanToolCallsAndPreservesMatchedOnes() {
        typealias Message = OpenAICompatibleProvider.ChatRequestBody.Message
        typealias ProviderToolCall = OpenAICompatibleProvider.ProviderToolCall

        let call1 = ProviderToolCall(id: "call_1", function: .init(name: "run_command", arguments: "{\"CommandLine\":\"ls\"}"))
        let call2 = ProviderToolCall(id: "call_2", function: .init(name: "view_file", arguments: "{\"AbsolutePath\":\"/tmp/test\"}"))

        let rawMessages: [Message] = [
            Message(role: "user", content: "hello"),
            // 孤儿 tool 结果（没有前置 assistant 声明）：应被剔除
            Message(role: "tool", content: "orphan output", toolCallID: "ghost_call"),
            // Assistant 声明了 call1 和 call2，但后续只提供了 call1 的回复（call2 被截断或 undo 丢失）
            Message(role: "assistant", content: nil, toolCalls: [call1, call2]),
            Message(role: "tool", content: "file1.txt", toolCallID: "call_1"),
            // 孤儿 tool 结果（前置并不匹配）：应被剔除
            Message(role: "tool", content: "orphan 2", toolCallID: "unmatched_call")
        ]

        let sanitized = OpenAICompatibleProvider.sanitizeMessagesForContract(rawMessages)

        #expect(sanitized.count == 3)
        #expect(sanitized[0].role == "user")
        #expect(sanitized[0].content == "hello")

        #expect(sanitized[1].role == "assistant")
        #expect(sanitized[1].toolCalls?.count == 1)
        #expect(sanitized[1].toolCalls?.first?.id == "call_1")

        #expect(sanitized[2].role == "tool")
        #expect(sanitized[2].toolCallID == "call_1")
        #expect(sanitized[2].content == "file1.txt")
    }

    @Test func sanitizeMessagesForContract_dropsEmptyAssistantWhenAllToolCallsPruned() {
        typealias Message = OpenAICompatibleProvider.ChatRequestBody.Message
        typealias ProviderToolCall = OpenAICompatibleProvider.ProviderToolCall

        let call = ProviderToolCall(id: "call_unanswered", function: .init(name: "run_command", arguments: "{}"))

        let rawMessages: [Message] = [
            Message(role: "user", content: "run something"),
            // 该 assistant 无文本内容，且其 tool_call 从未得到回复（例如被撤回或中断）
            Message(role: "assistant", content: "", toolCalls: [call]),
            Message(role: "user", content: "next prompt")
        ]

        let sanitized = OpenAICompatibleProvider.sanitizeMessagesForContract(rawMessages)

        // 空内容的 assistant 连同无回复的 tool_call 应被整体丢弃，防止 400 Bad Request
        #expect(sanitized.count == 2)
        #expect(sanitized[0].role == "user")
        #expect(sanitized[0].content == "run something")
        #expect(sanitized[1].role == "user")
        #expect(sanitized[1].content == "next prompt")
    }

    @Test func sanitizeMessagesForContract_preservesAssistantContentWhenToolCallsPruned() {
        typealias Message = OpenAICompatibleProvider.ChatRequestBody.Message
        typealias ProviderToolCall = OpenAICompatibleProvider.ProviderToolCall

        let call = ProviderToolCall(id: "call_unanswered", function: .init(name: "run_command", arguments: "{}"))

        let rawMessages: [Message] = [
            Message(role: "user", content: "do it"),
            // 该 assistant 有文本内容，但 tool_call 无回复
            Message(role: "assistant", content: "I will execute the command now.", toolCalls: [call])
        ]

        let sanitized = OpenAICompatibleProvider.sanitizeMessagesForContract(rawMessages)

        #expect(sanitized.count == 2)
        #expect(sanitized[1].role == "assistant")
        #expect(sanitized[1].content == "I will execute the command now.")
        #expect(sanitized[1].toolCalls == nil)
    }

    @Test func sessionReducer_healsGenericToolNodeNameWhenRealResultArrives() {
        var state = SessionViewState(sessionID: SessionID("s-1"), title: "Test")

        let callID = ToolCallID("call-123")
        let nodeID = TimelineNodeID.tool(callID)
        let placeholderTool = ToolNode(
            callID: callID,
            toolName: "Tool",
            argumentsJSON: "{\"CommandLine\":\"echo 1\"}",
            phase: .running
        )
        state.appendNode(TimelineNode(id: nodeID, timestamp: Date(), kind: .tool(placeholderTool)))

        // toolCompleted 事件到达，携带真实的 toolName
        let completedSnapshot = ToolResultSnapshot(
            callID: callID,
            toolName: "run_command",
            success: true,
            summary: "echo 1",
            preview: "{\"exit_code\": 0, \"command\": \"echo 1\"}"
        )
        let event = SessionEventEnvelope(
            cursor: EventCursor(generationID: EventLogGenerationID("gen"), sequence: 1),
            timestamp: Date(),
            causal: CausalContext(sessionID: SessionID("s-1"), turnID: TurnID("t-1")),
            payload: .toolCompleted(callID: callID, result: completedSnapshot, stdoutFinalIndex: nil, stderrFinalIndex: nil)
        )

        SessionReducer.reduce(state: &state, event: event, connectionState: ConnectionState(status: .connected))

        let finalNode = state.timelineNodes.first(where: { $0.id == nodeID })
        #expect(finalNode != nil)
        if case let .tool(finalTool) = finalNode?.kind {
            #expect(finalTool.toolName == "run_command", "The placeholder 'Tool' should be healed to 'run_command'")
            #expect(finalTool.phase == .completed)
        } else {
            Issue.record("Node kind should be .tool")
        }
    }

    @Test func toolCallBuffer_rejectsMalformedOrEmptyToolName() throws {
        var buffer = OpenAICompatibleProvider.ToolCallBuffer(
            requestID: ModelRequestID("req-test"),
            debugStep: nil,
            diagnosticsEnabled: false
        )

        // 模拟上游模型在混乱状态下吐出的畸形 tool name "Tool"
        let delta = OpenAICompatibleProvider.SSEToolCall(
            index: 0,
            id: "call_bad",
            function: .init(name: "Tool", arguments: "{}")
        )

        _ = try buffer.consume([delta])

        #expect(throws: CoreError.self) {
            _ = try buffer.complete()
        }
    }

    @MainActor
    @Test func tui_formatsGenericOrEmptyToolNodeWithoutMalformedCalledToolSyntax() {
        let tui = ApplicationTUI()
        let callID = ToolCallID("call_test_cmd")

        // 1. toolName 为 "Tool"，但参数中含有命令行 -> 推断为 Bash(git status -s)
        let cmdTool = ToolNode(
            callID: callID,
            toolName: "Tool",
            argumentsJSON: "{\"CommandLine\":\"git status -s\"}",
            phase: .completed,
            result: ToolResultSnapshot(callID: callID, success: true, summary: "Clean")
        )
        let entry1 = tui.formatModernToolCall(tool: cmdTool, id: "tool-1", active: false, timestamp: Date())
        #expect(entry1.text.contains("● Bash(git status -s)"))
        #expect(!entry1.text.contains("Called Tool"))
        #expect(!entry1.text.contains("Called Tool({})"))

        // 2. toolName 为空，但 preview 中有 command json -> 推断为 Bash(sed ...)
        let previewCmdTool = ToolNode(
            callID: callID,
            toolName: "",
            argumentsJSON: "{}",
            phase: .completed,
            result: ToolResultSnapshot(callID: callID, success: true, summary: "ok", preview: "{\"command\": \"sed -i '' 's/a/b/g' file.txt\", \"exit_code\": 0}")
        )
        let entry2 = tui.formatModernToolCall(tool: previewCmdTool, id: "tool-2", active: false, timestamp: Date())
        #expect(entry2.text.contains("● Bash(sed -i '' 's/a/b/g' file.txt)"))
        #expect(!entry2.text.contains("Called Tool({})"))

        // 3. 彻底未知的工具
        let unknownTool = ToolNode(
            callID: callID,
            toolName: "Tool",
            argumentsJSON: "{}",
            phase: .completed,
            result: ToolResultSnapshot(callID: callID, success: true, summary: "Done")
        )
        let entry3 = tui.formatModernToolCall(tool: unknownTool, id: "tool-3", active: false, timestamp: Date())
        #expect(entry3.text.contains("● Tool"))
        #expect(!entry3.text.contains("Called Tool({})"))

        // 4. Read / Edit / Search 规范化测试
        let readTool = ToolNode(
            callID: ToolCallID("call_read"),
            toolName: "view_file",
            argumentsJSON: "{\"AbsolutePath\":\"/path/to/SeriesRoadmapView.swift\",\"StartLine\":1,\"EndLine\":51}",
            phase: .completed
        )
        let readEntry = tui.formatModernToolCall(tool: readTool, id: "read-1", active: false, timestamp: Date())
        #expect(readEntry.text.contains("● Read(SeriesRoadmapView.swift)"))
        #expect(readEntry.text.contains("└  Read 51 lines"))

        let editTool = ToolNode(
            callID: ToolCallID("call_edit"),
            toolName: "replace_file_content",
            argumentsJSON: "{\"TargetFile\":\"Sources/Terminal.swift\",\"TargetContent\":\"foo\\nbar\",\"ReplacementContent\":\"foo\\nbar\\nbaz\"}",
            phase: .completed
        )
        let editEntry = tui.formatModernToolCall(tool: editTool, id: "edit-1", active: false, timestamp: Date())
        #expect(editEntry.text.contains("● Edit(Sources/Terminal.swift)"))
        #expect(editEntry.text.contains("└  +3 / -2 lines"))
    }

    @Test func snapshotResyncCancelsOrphanActiveToolsWhenSessionIsIdle() {
        let sessionID = SessionID("sess-resync-test")
        var state = SessionViewState(sessionID: sessionID)
        let orphanedToolCall = ToolInvocationSnapshot(
            callID: ToolCallID("call_orphan_running"),
            toolID: ToolID("run_command"),
            displayName: "run_command",
            argumentsSummary: "{\"command\": \"sleep 100\"}",
            state: .running
        )
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            info: SessionSummary(sessionID: sessionID),
            recentTurns: [],
            activeRootRun: nil,
            activeChildRuns: [],
            pendingInteractions: [],
            activeModelSteps: [],
            recentToolInvocations: [orphanedToolCall],
            contextState: ContextStateSnapshot(sessionID: sessionID),
            permissionConfiguration: .askWorkspace,
            agentMode: .build,
            recentEvents: [],
            historyBeforeCursor: nil,
            eventCursor: EventCursor(generationID: EventLogGenerationID(UUID().uuidString), sequence: 1),
            revision: 1
        )

        SessionReducer.reduceSnapshot(state: &state, snapshot: snapshot, connectionState: ConnectionState(status: .connected))

        #expect(state.activeToolCallIDs.isEmpty)
        let node = state.toolNodes[ToolCallID("call_orphan_running")]
        #expect(node?.phase == .cancelled)
    }
}

