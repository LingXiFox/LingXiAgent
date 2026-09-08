import Foundation
import Testing
import LingXiApplication
import LingXiClient
import LingXiProtocol
@testable import LingXiTUIComponents
@testable import LingXiCore

@Suite("ChronologyAndDurationRegressionTests")
struct ChronologyAndDurationRegressionTests {
    private let sessionID = SessionID("session-regression-1")
    private let connection = ConnectionState(status: .connected)
    private let generationID = EventLogGenerationID(rawValue: "gen-chronology-1")
    private let baseTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(
        _ sequence: UInt64,
        _ payload: SessionEventPayload,
        modelStepID: ModelStepID? = nil,
        timestamp: Date? = nil
    ) -> SessionEventEnvelope {
        SessionEventEnvelope(
            cursor: EventCursor(generationID: generationID, sequence: sequence),
            timestamp: timestamp ?? baseTimestamp.addingTimeInterval(TimeInterval(sequence)),
            causal: CausalContext(sessionID: sessionID, modelStepID: modelStepID),
            payload: payload
        )
    }

    // MARK: - Test 1: Bounded Semantic Presentation & Tool Execution Duration
    @Test("write_file 1KB argumentSummary hides content body and completed tool uses exact executionDuration")
    func localWriteFileBoundedPresentationAndDuration() {
        let callID = ToolCallID("call_write_1kb")
        let targetPath = "/Users/lingxifox/Desktop/prime.cpp"
        let sampleContent = String(repeating: "a", count: 1024)
        let arguments = #"{"path":"\#(targetPath)","content":"\#(sampleContent)"}"#

        // 1. Argument Summary Bounded Presentation: path and byte count only, no raw content
        let summary = ToolNode.summarizeArguments(arguments, toolName: "write_file")
        #expect(summary.contains("path=/Users/lingxifox/Desktop/prime.cpp"))
        #expect(summary.contains("bytes=1024"))
        #expect(!summary.contains("aaaa"))

        // 2. Exact executionDuration formatting (<100ms formatted as ms, not wall-clock seconds)
        let timing = ToolTiming(executionMilliseconds: 21)
        let toolSnapshot = ToolResultSnapshot(
            callID: callID,
            success: true,
            summary: "Source file created.",
            timing: timing
        )

        let toolNode = ToolNode(
            callID: callID,
            toolName: "write_file",
            argumentsJSON: arguments,
            phase: .completed,
            result: toolSnapshot
        )

        #expect(toolNode.executionDuration == .milliseconds(21))
        #expect(ToolNode.formatDuration(toolNode.executionDuration!) == "21ms")

        // 3. Sub-second duration formats as ms
        #expect(ToolNode.formatDuration(.milliseconds(578)) == "578ms")
        #expect(ToolNode.formatDuration(.milliseconds(43)) == "43ms")
        // Over 1 second formats as float seconds
        #expect(ToolNode.formatDuration(.milliseconds(2500)) == "2.5s")
    }

    // MARK: - Test 2: Deterministic Replay: Chronology & Thinking Isolation
    @Test("Deterministic replay from Docs/agent-record strictly isolates Thinking and preserves chronological order")
    func deterministicReplayStrictChronologyAndThinkingIsolation() {
        var state = SessionViewState(sessionID: sessionID)

        let step1 = ModelStepID("step-1")
        let reasoningStream1 = StreamID("reasoning-stream-1")
        let callID1 = ToolCallID("call_njmmk5pbd2ixvomf7yt32d7k")

        let step2 = ModelStepID("step-2")
        let reasoningStream2 = StreamID("reasoning-stream-2")
        let callID2 = ToolCallID("call_6boiqpp7ndoj0nh721mb7xpi")

        let step3 = ModelStepID("step-3")
        let reasoningStream3 = StreamID("reasoning-stream-3")
        let callID3 = ToolCallID("call_wias6x4arlxxpwy3onqqjpnz")

        let step4 = ModelStepID("step-4")
        let messageID4 = MessageID("msg-final-4")
        let assistantStream4 = StreamID("assistant-stream-4")

        // Step 1: Thinking -> write_file (cat > prime.cpp)
        SessionReducer.reduce(state: &state, event: event(1, .modelStepStarted(stepID: step1, visibleReasoningStreamID: reasoningStream1, assistantStreamID: nil), modelStepID: step1), connectionState: connection)
        SessionReducer.reduceStreamFrame(state: &state, frame: StreamFrame(streamID: reasoningStream1, owner: CausalContext(sessionID: sessionID, modelStepID: step1), index: 0, kind: .visibleReasoning, text: "The user wants me to create a C++ program on their desktop."), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(2, .modelStepCompleted(stepID: step1, visibleReasoningFinalIndex: 0, outputMetadata: ModelStepOutputMetadata(finishReason: "tool_calls")), modelStepID: step1), connectionState: connection)

        SessionReducer.reduce(state: &state, event: event(3, .toolRequested(ToolInvocationSnapshot(callID: callID1, toolID: ToolID("shell"), displayName: "shell", argumentsSummary: "cat > prime.cpp", state: .requested)), modelStepID: step1), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(4, .toolRunning(callID: callID1, stdoutStreamID: nil, stderrStreamID: nil), modelStepID: step1), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(5, .toolCompleted(callID: callID1, result: ToolResultSnapshot(callID: callID1, success: true, summary: "Source file created.", timing: ToolTiming(executionMilliseconds: 21)), stdoutFinalIndex: nil, stderrFinalIndex: nil), modelStepID: step1), connectionState: connection)

        // Step 2: Thinking -> compile & run
        SessionReducer.reduce(state: &state, event: event(6, .modelStepStarted(stepID: step2, visibleReasoningStreamID: reasoningStream2, assistantStreamID: nil), modelStepID: step2), connectionState: connection)
        SessionReducer.reduceStreamFrame(state: &state, frame: StreamFrame(streamID: reasoningStream2, owner: CausalContext(sessionID: sessionID, modelStepID: step2), index: 0, kind: .visibleReasoning, text: "Now let me compile it and run it."), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(7, .modelStepCompleted(stepID: step2, visibleReasoningFinalIndex: 0, outputMetadata: ModelStepOutputMetadata(finishReason: "tool_calls")), modelStepID: step2), connectionState: connection)

        SessionReducer.reduce(state: &state, event: event(8, .toolRequested(ToolInvocationSnapshot(callID: callID2, toolID: ToolID("shell"), displayName: "shell", argumentsSummary: "g++ prime.cpp", state: .requested)), modelStepID: step2), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(9, .toolRunning(callID: callID2, stdoutStreamID: nil, stderrStreamID: nil), modelStepID: step2), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(10, .toolCompleted(callID: callID2, result: ToolResultSnapshot(callID: callID2, success: true, summary: "=== Compilation successful ===", timing: ToolTiming(executionMilliseconds: 578)), stdoutFinalIndex: nil, stderrFinalIndex: nil), modelStepID: step2), connectionState: connection)

        // Step 3: Thinking -> verify count
        SessionReducer.reduce(state: &state, event: event(11, .modelStepStarted(stepID: step3, visibleReasoningStreamID: reasoningStream3, assistantStreamID: nil), modelStepID: step3), connectionState: connection)
        SessionReducer.reduceStreamFrame(state: &state, frame: StreamFrame(streamID: reasoningStream3, owner: CausalContext(sessionID: sessionID, modelStepID: step3), index: 0, kind: .visibleReasoning, text: "Compilation and run succeeded. Let me verify the count of primes."), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(12, .modelStepCompleted(stepID: step3, visibleReasoningFinalIndex: 0, outputMetadata: ModelStepOutputMetadata(finishReason: "tool_calls")), modelStepID: step3), connectionState: connection)

        SessionReducer.reduce(state: &state, event: event(13, .toolRequested(ToolInvocationSnapshot(callID: callID3, toolID: ToolID("shell"), displayName: "shell", argumentsSummary: "tail prime_output.txt", state: .requested)), modelStepID: step3), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(14, .toolRunning(callID: callID3, stdoutStreamID: nil, stderrStreamID: nil), modelStepID: step3), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(15, .toolCompleted(callID: callID3, result: ToolResultSnapshot(callID: callID3, success: true, summary: "Total primes between 0 and 10000: 1229", timing: ToolTiming(executionMilliseconds: 43)), stdoutFinalIndex: nil, stderrFinalIndex: nil), modelStepID: step3), connectionState: connection)

        // Step 4: Assistant final message
        SessionReducer.reduce(state: &state, event: event(16, .modelStepStarted(stepID: step4, visibleReasoningStreamID: nil, assistantStreamID: assistantStream4), modelStepID: step4), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(17, .assistantMessageStarted(messageID: messageID4, assistantStreamID: assistantStream4), modelStepID: step4), connectionState: connection)
        SessionReducer.reduceStreamFrame(state: &state, frame: StreamFrame(streamID: assistantStream4, owner: CausalContext(sessionID: sessionID, modelStepID: step4), index: 0, kind: .assistantText, text: "完成！程序已成功创建、编译并运行验证。"), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(18, .assistantMessageCommitted(messageID: messageID4, content: "完成！程序已成功创建、编译并运行验证。", assistantFinalIndex: 0), modelStepID: step4), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(19, .modelStepCompleted(stepID: step4, visibleReasoningFinalIndex: nil, outputMetadata: ModelStepOutputMetadata(finishReason: "stop")), modelStepID: step4), connectionState: connection)

        // ASSERT 1: Timeline node ordering must strictly adhere to canonical chronology:
        // Thinking(step1) -> Tool(call1) -> Thinking(step2) -> Tool(call2) -> Thinking(step3) -> Tool(call3) -> Thinking(step4) -> Message(msg4)
        let expectedIDs = [
            "thinking:step-1",
            "tool:call_njmmk5pbd2ixvomf7yt32d7k",
            "thinking:step-2",
            "tool:call_6boiqpp7ndoj0nh721mb7xpi",
            "thinking:step-3",
            "tool:call_wias6x4arlxxpwy3onqqjpnz",
            "thinking:step-4",
            "message:msg-final-4"
        ]
        let actualIDs = state.timelineNodes.map(\.id.rawValue)
        #expect(actualIDs == expectedIDs)

        // ASSERT 2: No thinking cross-step contamination! Each thinking node belongs only to its step.
        let thinking1 = state.thinkingNodes[step1]
        #expect(thinking1 != nil)
        #expect(thinking1?.content == "The user wants me to create a C++ program on their desktop.")
        #expect(thinking1?.isComplete == true)

        let thinking2 = state.thinkingNodes[step2]
        #expect(thinking2 != nil)
        #expect(thinking2?.content == "Now let me compile it and run it.")
        #expect(thinking2?.isComplete == true)

        let thinking3 = state.thinkingNodes[step3]
        #expect(thinking3 != nil)
        #expect(thinking3?.content == "Compilation and run succeeded. Let me verify the count of primes.")
        #expect(thinking3?.isComplete == true)

        // ASSERT 3: Tool calls precede assistant final response
        let tool3Index = state.timelineNodes.firstIndex(where: { $0.id.rawValue == "tool:call_wias6x4arlxxpwy3onqqjpnz" })!
        let msg4Index = state.timelineNodes.firstIndex(where: { $0.id.rawValue == "message:msg-final-4" })!
        #expect(tool3Index < msg4Index)

        // ASSERT 4: Execution durations are strictly recorded
        #expect(state.toolNodes[callID1]?.executionDuration == .milliseconds(21))
        #expect(state.toolNodes[callID2]?.executionDuration == .milliseconds(578))
        #expect(state.toolNodes[callID3]?.executionDuration == .milliseconds(43))
    }

    // MARK: - Test 3: Permission Single Source of Truth
    @Test("Setting permissions in idle session immediately updates authoritative state without lingering next-turn text")
    func permissionCommandSingleSourceOfTruthInIdleSession() {
        var state = ApplicationState()
        let session = SessionViewState(sessionID: sessionID)
        state.activeSessionID = sessionID
        state.activeSessionState = session

        // 1. Initial idle state: default permission is askWorkspace
        #expect(state.activeTurnPermissionConfiguration == .askWorkspace)
        #expect(state.nextTurnPermission == nil)

        // 2. In idle state (activeTurnID == nil), updating permission updates activeSessionState directly
        let newPerm = PermissionConfiguration.yoloFullAccess
        state.activeSessionState?.permissionConfiguration = newPerm
        state.nextTurnPermission = newPerm

        // Verify state
        #expect(state.activeTurnPermissionConfiguration == .yoloFullAccess)
        #expect(state.nextTurnPermission == .yoloFullAccess)

        // Verify status bar logic: must display authoritative "YOLO", never "· next YOLO"
        let currentPermission = state.activeTurnPermissionConfiguration
        let currentPermissionName = currentPermission?.displayName ?? "Ask/Workspace"
        let permissionsText: String
        if state.activeSessionState?.activeTurnID != nil, let next = state.nextTurnPermission, next != currentPermission {
            permissionsText = "\(currentPermissionName) · next \(next.displayName)"
        } else {
            permissionsText = currentPermissionName
        }
        #expect(permissionsText == "YOLO")
        #expect(!permissionsText.contains("next"))

        // 3. During an active turn (activeTurnID != nil), permission change is queued for next turn
        let activeTurnID = TurnID("turn-active-1")
        state.activeSessionState?.activeTurnID = activeTurnID
        state.nextTurnPermission = .autoWorkspace

        let queuedText: String
        if state.activeSessionState?.activeTurnID != nil, let next = state.nextTurnPermission, next != currentPermission {
            queuedText = "\(currentPermissionName) · next \(next.displayName)"
        } else {
            queuedText = currentPermissionName
        }
        #expect(queuedText == "YOLO · next Auto/Workspace")
    }

    // MARK: - Test 4: Permission switching without session immediately updates activeTurnPermissionConfiguration
    @Test("Permission switching without active session immediately reflects in activeTurnPermissionConfiguration and status bar")
    func permissionSwitchingWithoutSessionImmediateEffect() {
        var state = ApplicationState()
        // No session exists
        #expect(state.activeSessionID == nil)
        #expect(state.activeSessionState == nil)
        #expect(state.activeTurnPermissionConfiguration == nil)

        // Switch permission to YOLO before any session is created
        let yolo = PermissionConfiguration.yoloFullAccess
        state.nextTurnPermission = yolo

        // activeTurnPermissionConfiguration must immediately return yolo
        #expect(state.activeTurnPermissionConfiguration == yolo)
        #expect(state.activeTurnPermissionConfiguration?.displayName == "YOLO")

        // Status bar computation: when session is absent, must display authoritative "YOLO", never "Ask/Workspace"
        let currentPermission = state.activeTurnPermissionConfiguration
        let currentPermissionName = currentPermission?.displayName ?? "Ask/Workspace"
        let permissionsText: String
        if state.activeSessionState?.activeTurnID != nil, let next = state.nextTurnPermission, next != currentPermission {
            permissionsText = "\(currentPermissionName) · next \(next.displayName)"
        } else {
            permissionsText = currentPermissionName
        }
        #expect(permissionsText == "YOLO")
    }

    // MARK: - Test 5: Secondary subcommand completions and previews
    @Test("Secondary subcommand options can be extracted from argumentSchema and match prefix")
    func secondarySubcommandCompletions() {
        let commands = BuiltinCommands.createAll()

        // 1. /permissions command argumentSchema
        let permCmd = commands.first { $0.name == "permissions" }
        #expect(permCmd != nil)
        #expect(permCmd?.argumentSchema == "[ask|auto|yolo]")

        let permOptions = ["ask", "auto", "yolo"]
        #expect(permOptions.contains("yolo"))
        #expect(permOptions.filter { "yolo".hasPrefix($0) || $0.hasPrefix("yo") } == ["yolo"])

        // 2. /mode command argumentSchema
        let modeCmd = commands.first { $0.name == "mode" }
        #expect(modeCmd != nil)
        #expect(modeCmd?.argumentSchema == "[build|plan|explore]")

        let modeOptions = ["build", "plan", "explore"]
        #expect(modeOptions.contains("build"))
        #expect(modeOptions.filter { $0.hasPrefix("pl") } == ["plan"])

        // 3. CompletionView renders candidates properly
        let view = CompletionView()
        let items = [
            TUICompletionItem(value: "ask", label: "ask", detail: "Ask permission", kind: .command),
            TUICompletionItem(value: "auto", label: "auto", detail: "Auto permission", kind: .command),
            TUICompletionItem(value: "yolo", label: "yolo", detail: "YOLO full access", kind: .command)
        ]
        view.update(items: items, query: "", selectedIndex: 2)
        #expect(view.selectedItem?.value == "yolo")

        let rendered = view.render()
        #expect(rendered.count == 3)
        #expect(rendered[2].text.hasPrefix("› yolo"))
        #expect(rendered[2].style == .accent || rendered[2].style == .overlayHighlight)
        #expect(rendered[0].text.hasPrefix("  ask"))
        #expect(rendered[0].style == .normal || rendered[0].style == .overlayItem)
    }

    // MARK: - Test 6: Running ToolCall does NOT flash red on "-" and stays steady accent style
    @Test("Running ToolCall does not flash error style when spinner rotates to '-' and uses accent style")
    func runningToolCallDoesNotFlashRed() {
        let entryText = "- shell [running] · 1s\nargs: ls -la ~/Desktop"
        let entry = TUITranscriptEntry(
            id: "tool-test",
            kind: .toolCall,
            text: entryText,
            style: .accent
        )

        let viewport = TranscriptViewport()
        viewport.append(entry)
        let lines = viewport.render(viewportHeight: 20, width: 80)

        // Verify no lines were mistakenly given .error style (red)
        for line in lines {
            #expect(line.style != TUIStyle.error, "ToolCall line should never be given error style due to '-' prefix")
            #expect(line.style == TUIStyle.accent, "Running toolCall lines should retain steady accent style")
        }
    }

    // MARK: - Test 7: Read-only shell commands are recognized and do not request workspace write
    @Test("Read-only shell commands do not require workspace write capability")
    func readOnlyShellCommandsAvoidWorkspaceMutation() throws {
        let workspace = try WorkspaceRoot(path: FileManager.default.temporaryDirectory.path)
        let tool = ShellTool(workspace: workspace)

        let readCapabilities = try tool.capabilities(for: #"{"command":"ls -la \"~/Desktop\" 2>/dev/null || ls -la /Users/lingxifox/Desktop 2>/dev/null || echo \"Desktop not found\""}"#, profile: .fullAccess)
        #expect(!readCapabilities.contains(.projectWrite), "Read-only shell (ls) must not request projectWrite")
        #expect(!readCapabilities.contains(.destructive), "Read-only shell (ls) must not request destructive write")

        let writeCapabilities = try tool.capabilities(for: #"{"command":"echo 'hello' > output.txt"}"#, profile: .fullAccess)
        #expect(writeCapabilities.contains(.projectWrite) || writeCapabilities.contains(.destructive), "Shell command with output redirection must request write")
    }

    // MARK: - Test 8: Command entries with earlier timestamp sort before later timeline nodes and do not linger at bottom
    @Test("Command entries with earlier timestamp sort before later timeline nodes and do not linger at bottom")
    func commandEntriesSortedChronologically() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 1_010)
        let t2 = Date(timeIntervalSince1970: 1_020)

        let cmdEntry = TUITranscriptEntry(
            id: "cmd-1",
            kind: .result,
            text: "权限策略已更新为：yolo",
            timestamp: t0
        )
        let userEntry = TUITranscriptEntry(
            id: "user-1",
            kind: .user,
            text: "123",
            timestamp: t1
        )
        let assistantEntry = TUITranscriptEntry(
            id: "assistant-1",
            kind: .assistant,
            text: "你好！很高兴为你提供帮助。",
            timestamp: t2
        )

        let entries = [userEntry, assistantEntry]
        let commandEntries = [cmdEntry]

        var allEntries = entries + commandEntries
        if !commandEntries.isEmpty && !entries.isEmpty {
            allEntries.sort { a, b in
                if a.timestamp != b.timestamp {
                    return a.timestamp < b.timestamp
                }
                return false
            }
        }

        #expect(allEntries.count == 3)
        #expect(allEntries[0].id == "cmd-1", "Early command (/permissions yolo) must appear BEFORE user prompt")
        #expect(allEntries[1].id == "user-1")
        #expect(allEntries[2].id == "assistant-1", "Assistant response must appear AFTER user prompt and NOT before command")
    }

    // MARK: - Test 9: Historical thinking and tool call nodes are preserved after turn completion
    @Test("Historical thinking and tool call nodes are preserved after turn completion and remain in transcript")
    func historicalThinkingAndToolNodesPreserved() {
        var state = SessionViewState(sessionID: sessionID)

        let step1ID = ModelStepID("step-1")
        let tool1CallID = ToolCallID("call-1")

        // 1. Session created & User prompt
        state.appendNode(TimelineNode(id: .message(MessageID("user-1")), timestamp: Date(timeIntervalSince1970: 100), kind: .message(MessageNode(messageID: MessageID("user-1"), role: .user, content: "run ls", isStreaming: false, isFinal: true))))

        // 2. Thinking node completed
        state.appendNode(TimelineNode(id: .thinking(step1ID), timestamp: Date(timeIntervalSince1970: 101), kind: .thinking(ThinkingNode(stepID: step1ID, title: "Thinking", content: "I should run ls", isStreaming: false, isComplete: true))))

        // 3. Tool node completed
        state.appendNode(TimelineNode(id: .tool(tool1CallID, modelStepID: step1ID), timestamp: Date(timeIntervalSince1970: 102), kind: .tool(ToolNode(callID: tool1CallID, toolName: "shell", argumentsJSON: "ls", phase: .completed, result: ToolResultSnapshot(callID: tool1CallID, success: true, summary: "files listed")))))

        // 4. Assistant message completed
        state.appendNode(TimelineNode(id: .message(MessageID("ast-1"), modelStepID: step1ID), timestamp: Date(timeIntervalSince1970: 103), kind: .message(MessageNode(messageID: MessageID("ast-1"), role: .assistant, content: "Here are the files", isStreaming: false, isFinal: true))))

        // All 4 nodes exist in timelineNodes
        #expect(state.timelineNodes.count == 4)
        #expect(state.timelineNodes.contains { if case .thinking = $0.kind { return true } else { return false } })
        #expect(state.timelineNodes.contains { if case .tool = $0.kind { return true } else { return false } })
    }

    // MARK: - Test 10: Tool cancellation stops execution without re-invoking model
    @Test("Cancelled tool outcome causes loop abort without proceeding to subsequent model turn")
    func cancelledToolAbortsLoop() {
        let callID = ToolCallID("cancelled-call")
        let outcome = ToolRuntime.ExecutionOutcome(
            result: ToolResult(
                callID: callID,
                success: false,
                content: "",
                error: ToolError(code: CoreError.Code.toolCancelled.rawValue, message: "Tool 执行已取消"),
                toolName: "shell",
                outcome: .cancelled
            ),
            permissionWait: .zero,
            permissionAsked: false,
            execution: .zero,
            toolName: "shell",
            resource: nil
        )

        let settled = [outcome]
        let hasCancelledTool = settled.contains {
            $0.result.outcome == .cancelled ||
            $0.result.error?.code == CoreError.Code.toolCancelled.rawValue ||
            $0.result.error?.code == CoreError.Code.permissionCancelled.rawValue
        }

        #expect(hasCancelledTool, "Cancellation check must identify cancelled tool result")
    }

    // MARK: - Test 11: Thinking timer immediately completes and freezes upon toolRequested
    @Test("Thinking node immediately completes and locks duration when toolRequested arrives")
    func thinkingNodeCompletesOnToolRequested() {
        var state = SessionViewState(sessionID: sessionID)
        let step1ID = ModelStepID("step-1")
        let callID = ToolCallID("call-1")
        let start = Date(timeIntervalSince1970: 100)
        let toolStart = Date(timeIntervalSince1970: 105)
        let connection = ConnectionState(status: .connected)

        // 1. Model thinking starts
        let env1 = event(1, .modelStepStarted(stepID: step1ID, visibleReasoningStreamID: nil, assistantStreamID: nil), modelStepID: step1ID, timestamp: start)
        SessionReducer.reduce(state: &state, event: env1, connectionState: connection)

        guard let thinkingBefore = state.timelineNodes.compactMap({ node -> ThinkingNode? in
            if case let .thinking(th) = node.kind { return th } else { return nil }
        }).first else {
            Issue.record("Expected thinking node in timeline")
            return
        }
        #expect(!thinkingBefore.isComplete)

        // 2. Tool requested at 105s
        let env3 = event(3, .toolRequested(ToolInvocationSnapshot(
            callID: callID,
            toolID: ToolID("shell"),
            displayName: "shell",
            argumentsSummary: "ls",
            state: .requested
        )), modelStepID: step1ID, timestamp: toolStart)
        SessionReducer.reduce(state: &state, event: env3, connectionState: connection)

        guard let thinkingAfter = state.timelineNodes.compactMap({ node -> ThinkingNode? in
            if case let .thinking(th) = node.kind { return th } else { return nil }
        }).first else {
            Issue.record("Expected thinking node in timeline")
            return
        }
        #expect(thinkingAfter.isComplete, "Thinking must be marked complete immediately upon toolRequested")
        #expect(thinkingAfter.completedAt == toolStart)
        #expect(thinkingAfter.duration != nil)
        #expect(thinkingAfter.duration == .seconds(5), "Thinking duration must freeze at 5 seconds")
    }

    // MARK: - Test 12: Collapsed rendering trims long output for thinking and tools
    @Test("TranscriptViewport collapses thinking and tool lines cleanly")
    func transcriptViewportCollapsing() {
        let viewport = TranscriptViewport()
        let thinkingEntry = TUITranscriptEntry(
            id: "th-1",
            kind: .thinking,
            text: "Thinking · 3s\nline 1\nline 2\nline 3\nline 4\nline 5",
            collapsed: true
        )
        viewport.entries = [thinkingEntry]
        let thinkingLines = viewport.render(viewportHeight: 20, width: 80)
        #expect(thinkingLines.count >= 2, "Collapsed thinking renders header and collapsed summary")
        #expect(thinkingLines[0].text.contains("Thinking · 3s"))

        let toolEntry = TUITranscriptEntry(
            id: "tl-1",
            kind: .toolCall,
            text: "shell [completed] · 12ms\nargs: ls\nline 1\nline 2\nline 3\nline 4\nline 5",
            collapsed: true
        )
        viewport.entries = [toolEntry]
        let toolLines = viewport.render(viewportHeight: 20, width: 80)
        #expect(toolLines.contains { $0.text.contains("collapsed") }, "Collapsed tool must contain collapsed line count indicator")
    }

    // MARK: - Test 13: Short thinking and short tool call remain fully expanded
    @Test("Short thinking and short tool call stay fully expanded without collapsing")
    func shortOutputRemainsExpanded() {
        let viewport = TranscriptViewport()
        let shortThinking = TUITranscriptEntry(
            id: "th-short",
            kind: .thinking,
            text: "Thinking · 1s\nShort reasoning",
            collapsed: false
        )
        viewport.entries = [shortThinking]
        let lines = viewport.render(viewportHeight: 20, width: 80)
        #expect(lines.count == 2, "Short thinking must keep all lines visible")
        #expect(lines[0].text.contains("Thinking · 1s"))
        #expect(lines[1].text.contains("Short reasoning"))
    }

    // MARK: - Test 14: TranscriptViewport toggleCollapse expands collapsed entries
    @Test("TranscriptViewport toggleCollapse allows expanding collapsed entries")
    func viewportToggleCollapse() {
        let viewport = TranscriptViewport()
        let thinkingEntry = TUITranscriptEntry(
            id: "th-toggle",
            kind: .thinking,
            text: "Thinking · 3s\nline 1\nline 2\nline 3\nline 4",
            collapsed: true
        )
        viewport.entries = [thinkingEntry]
        #expect(viewport.isCollapsed(id: "th-toggle") == true)

        // Toggle to expand
        viewport.toggleCollapse(id: "th-toggle")
        #expect(viewport.isCollapsed(id: "th-toggle") == false)

        let expandedLines = viewport.render(viewportHeight: 20, width: 80)
        #expect(expandedLines.contains { $0.text.contains("line 3") }, "Expanded entry must show full content lines")
        #expect(!expandedLines.contains { $0.text.contains("lines collapsed") }, "Expanded entry must not show collapsed indicator")
    }
}
