import Foundation
import Testing
import LingXiProtocol
import LingXiClient
import LingXiApplication

/// Contract tests for the serializable front-end layer:
/// `ApplicationUpdate` (state + change set + timeline graph), the snapshot/delta frames,
/// `FrontendCommand` -> `ApplicationAction`, and `ToolFamily`.
///
/// Lives in `Tests/LingXiAgentTests` because `ContractTests/LingXiFrontendContractTests`
/// only links LingXiProtocol + LingXiClient and cannot see LingXiApplication.
struct FrontendWireCodableTests {

    private static let sessionID = SessionID("session-1")

    // MARK: - Fixtures

    private static func makeState() -> ApplicationState {
        var session = SessionViewState(
            sessionID: sessionID,
            title: "Contract",
            mode: .build,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_600),
            reasoningEffort: .high
        )
        session.permissionConfiguration = .askWorkspace

        let message = MessageNode(
            messageID: MessageID("msg-1"),
            role: .assistant,
            content: "hello",
            isStreaming: false,
            isFinal: true,
            citations: [],
            metrics: MessageMetrics(model: "some-model", durationMs: 1200.5, totalTokens: 42)
        )
        let thinking = ThinkingNode(
            stepID: ModelStepID("step-1"),
            title: "planning",
            content: "let me think",
            isStreaming: false,
            isComplete: true,
            outputMetadata: nil,
            duration: .milliseconds(1500),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let tool = ToolNode(
            callID: ToolCallID("call-1"),
            toolName: "mcp__github__list_issues",
            argumentsJSON: "{\"owner\":\"x\"}",
            phase: .completed,
            permissionID: PermissionID("perm-1"),
            stdout: "ok",
            stderr: "",
            result: nil,
            error: nil,
            modelStepID: ModelStepID("step-1"),
            requestedAt: Date(timeIntervalSince1970: 1_700_000_002),
            projectionReceivedAt: Date(timeIntervalSince1970: 1_700_000_003)
        )
        let interaction = InteractionNode(
            interactionID: InteractionID("inter-1"),
            kind: .permission,
            causal: CausalContext(sessionID: sessionID, runID: RunID("run-1")),
            createdAt: Date(timeIntervalSince1970: 1_700_000_004),
            permissionRequest: nil,
            questionRequest: nil,
            decisionRequest: nil,
            isResolved: false,
            resolution: nil
        )
        let subagent = SubagentNode(
            runID: RunID("sub-1"),
            parentRunID: RunID("run-1"),
            status: "completed",
            terminalReason: .completed,
            resultPreview: "done"
        )
        let runTerminal = RunTerminalNode(runID: RunID("run-1"), terminalReason: .completed)
        let errorNode = ErrorNode(errorID: RuntimeErrorID("err-1"), code: "E1", message: "boom", details: ["k": "v"])

        session.appendNode(TimelineNode(id: .message(MessageID("msg-1")), timestamp: Date(timeIntervalSince1970: 1_700_000_010), kind: .message(message), modelStepID: nil))
        session.appendNode(TimelineNode(id: .thinking(ModelStepID("step-1")), timestamp: Date(timeIntervalSince1970: 1_700_000_011), kind: .thinking(thinking), modelStepID: ModelStepID("step-1")))
        session.appendNode(TimelineNode(id: .tool(ToolCallID("call-1")), timestamp: Date(timeIntervalSince1970: 1_700_000_012), kind: .tool(tool), modelStepID: ModelStepID("step-1")))
        session.appendNode(TimelineNode(id: .interaction(InteractionID("inter-1")), timestamp: Date(timeIntervalSince1970: 1_700_000_013), kind: .interaction(interaction), modelStepID: nil))
        session.appendNode(TimelineNode(id: .subagent(RunID("sub-1")), timestamp: Date(timeIntervalSince1970: 1_700_000_014), kind: .subagent(subagent), modelStepID: nil))
        session.appendNode(TimelineNode(id: .runTerminal(RunID("run-1")), timestamp: Date(timeIntervalSince1970: 1_700_000_015), kind: .runTerminal(runTerminal), modelStepID: nil))
        session.appendNode(TimelineNode(id: .error(RuntimeErrorID("err-1")), timestamp: Date(timeIntervalSince1970: 1_700_000_016), kind: .error(errorNode), modelStepID: nil))

        session.committedNodes = session.timelineNodes
        session.thinkingNodes[ModelStepID("step-1")] = thinking
        session.toolNodes[ToolCallID("call-1")] = tool
        session.activeThinkingStepID = ModelStepID("step-1")
        session.activeToolCallIDs = [ToolCallID("call-1")]
        session.turns = [TurnID("turn-1"): TurnSnapshot(
            turnID: TurnID("turn-1"),
            sessionID: sessionID,
            userMessage: MessageSnapshot(messageID: MessageID("msg-0"), role: .user, text: "hi"),
            executionIntent: TurnExecutionIntent()
        )]
        session.turnOrder = [TurnID("turn-1")]
        session.runs = [RunID("run-1"): RunSnapshot(
            runID: RunID("run-1"),
            sessionID: sessionID,
            turnID: TurnID("turn-1"),
            status: .completed,
            model: "some-model"
        )]
        session.todos = [TodoItemData(id: "todo-1", title: "ship it", status: "pending")]
        session.hasActiveError = false
        session.recalculateStatus(connectionState: .connected(version: ProtocolVersion(major: 2, minor: 0), capabilities: RuntimeCapabilities()))

        var state = ApplicationState(
            connectionState: .connected(version: ProtocolVersion(major: 2, minor: 0), capabilities: RuntimeCapabilities()),
            sessionCatalog: [SessionSummary(sessionID: sessionID, title: "Contract", workingDirectory: "/tmp")],
            activeSessionID: sessionID,
            activeSessionState: session
        )
        state.recalculateStatus()
        return state
    }

    private static func makeUpdate() -> ApplicationUpdate {
        ApplicationUpdate(
            revision: 42,
            state: makeState(),
            changes: ApplicationChangeSet(
                sessionChanged: true,
                transcriptNodesChanged: [.message(MessageID("msg-1"))],
                nodeChanges: [TimelineNodeChange(nodeID: .message(MessageID("msg-1")), kind: .update)],
                statusChanged: true
            )
        )
    }

    // MARK: - Whole-graph round trip

    @Test("ApplicationUpdate encodes to JSON and decodes back to an equal value")
    func applicationUpdateRoundTrips() throws {
        let update = Self.makeUpdate()
        let data = try FrontendWire.makeEncoder().encode(update)
        let decoded = try FrontendWire.makeDecoder().decode(ApplicationUpdate.self, from: data)

        #expect(decoded == update)
        #expect(decoded.revision == 42)
        #expect(decoded.state.activeSessionState?.timelineNodes.count == 7)
        #expect(decoded.changes.nodeChanges == update.changes.nodeChanges)
        // Every node kind survived.
        let kinds = Set((decoded.state.activeSessionState?.timelineNodes ?? []).map { nodeKindName($0.kind) })
        #expect(kinds == ["message", "thinking", "tool", "interaction", "subagent", "runTerminal", "error"])
    }

    @Test("TimelineNodeID is a bare JSON string; canonical IDs keep their rawValue object form")
    func idWireShapes() throws {
        let encoder = FrontendWire.makeEncoder()
        #expect(try json(encoder.encode(TimelineNodeID.message(MessageID("m1")))) == "\"message:m1\"")
        #expect(try json(encoder.encode(Self.sessionID)) == "{\"rawValue\":\"session-1\"}")
        let decoded = try FrontendWire.makeDecoder().decode(TimelineNodeID.self, from: Data("\"tool:c9\"".utf8))
        #expect(decoded == .tool(ToolCallID("c9")))
    }

    @Test("A decoded SessionViewState still answers its derived index lookups")
    func decodedSessionViewStateRebuildsCaches() throws {
        let original = Self.makeState().activeSessionState!
        let data = try FrontendWire.makeEncoder().encode(original)
        let decoded = try FrontendWire.makeDecoder().decode(SessionViewState.self, from: data)

        // Derived caches are excluded from the wire format, so prove they were rebuilt.
        for node in original.timelineNodes {
            #expect(decoded.node(for: node.id)?.id == node.id)
            #expect(decoded.node(for: node.id)?.kind.descriptionFragment == node.kind.descriptionFragment)
        }
        #expect(decoded.node(for: TimelineNodeID("message:does-not-exist")) == nil)
        // ID-keyed maps arrive as JSON objects keyed by rawValue, not flat arrays.
        #expect(decoded.thinkingNodes.count == 1)
        #expect(decoded.toolNodes[ToolCallID("call-1")]?.toolFamily == .mcp)
        #expect(decoded.turns[TurnID("turn-1")]?.userMessage.text == "hi")
        #expect(decoded.runs[RunID("run-1")]?.status == .completed)
        #expect(String(data: data, encoding: .utf8)!.contains("\"thinkingNodes\":{\"step-1\""))
        #expect(String(data: data, encoding: .utf8)!.contains("\"timelineNodes\":["))
        // Mutating a decoded value behaves correctly (no duplicate append for a known id).
        var mutated = decoded
        mutated.appendNode(original.timelineNodes[0])
        #expect(mutated.timelineNodes.count == decoded.timelineNodes.count)
    }

    // MARK: - Frames

    @Test("Snapshot frame carries the full state and the command catalog")
    func snapshotFrame() throws {
        let update = Self.makeUpdate()
        let command = ApplicationCommand(name: "help", aliases: ["h"], description: "Show help", category: "General", argumentSchema: "[]") { _ in
            ApplicationCommandResult(output: "ok")
        }
        let frame = FrontendWire.snapshot(from: update, commands: [command])
        #expect(frame.protocolVersion == FrontendWire.protocolVersion)
        #expect(frame.commands == [ApplicationCommandDTO(from: command)])
        #expect(frame.state.activeSessionState?.timelineNodes.count == 7)

        let decoded = try FrontendWire.makeDecoder().decode(FrontendSnapshotFrame.self, from: try FrontendWire.makeEncoder().encode(frame))
        #expect(decoded == frame)
    }

    @Test("Delta frame resolves changed nodes and trims transcript containers")
    func deltaFrame() throws {
        let update = Self.makeUpdate()
        let frame = FrontendWire.delta(from: update)

        #expect(frame.requiresSnapshot == false)
        #expect(frame.changedNodes.count == 1)
        #expect(frame.changedNodes.first?.id == .message(MessageID("msg-1")))
        #expect(frame.state.activeSessionState?.timelineNodes.isEmpty == true)
        #expect(frame.state.activeSessionState?.committedNodes.isEmpty == true)
        #expect(frame.state.activeSessionState?.activeCell == nil)
        #expect(frame.state.activeSessionState?.thinkingNodes.isEmpty == true)
        #expect(frame.state.activeSessionState?.toolNodes.isEmpty == true)
        // Non-transcript chrome survives a delta.
        #expect(frame.state.sessionCatalog.count == 1)
        #expect(frame.state.activeSessionState?.turns.count == 1)
        #expect(frame.revision == update.revision)

        let decoded = try FrontendWire.makeDecoder().decode(FrontendDeltaFrame.self, from: try FrontendWire.makeEncoder().encode(frame))
        #expect(decoded == frame)
    }

    @Test("Only a delta that cannot describe the outcome forces a fresh snapshot")
    func deltaFrameRequiresSnapshot() {
        let update = Self.makeUpdate()

        // Structural growth is the common streaming case: a node appended at the tail. The delta
        // carries its payload, so the client applies it in place instead of resyncing everything.
        let appendedID = update.state.activeSessionState?.timelineNodes.first?.id ?? .message(MessageID("msg-1"))
        let structural = ApplicationUpdate(
            revision: 43,
            state: update.state,
            changes: ApplicationChangeSet(
                transcriptStructureChanged: true,
                nodeChanges: [TimelineNodeChange(nodeID: appendedID ?? .message(MessageID("msg-1")), kind: .append)]
            )
        )
        let structuralFrame = FrontendWire.delta(from: structural)
        #expect(structuralFrame.requiresSnapshot == false)
        #expect(structuralFrame.changedNodes.count == 1)

        // A removal is equally describable: the client drops that id.
        let removed = ApplicationUpdate(
            revision: 46,
            state: update.state,
            changes: ApplicationChangeSet(
                transcriptStructureChanged: true,
                nodeChanges: [TimelineNodeChange(nodeID: appendedID ?? .message(MessageID("msg-1")), kind: .remove)]
            )
        )
        #expect(FrontendWire.delta(from: removed).requiresSnapshot == false)

        let reset = ApplicationUpdate(
            revision: 44,
            state: update.state,
            changes: ApplicationChangeSet(nodeChanges: [TimelineNodeChange(nodeID: .message(MessageID("msg-1")), kind: .reset)])
        )
        #expect(FrontendWire.delta(from: reset).requiresSnapshot == true)

        let missing = ApplicationUpdate(
            revision: 45,
            state: update.state,
            changes: ApplicationChangeSet(nodeChanges: [TimelineNodeChange(nodeID: .message(MessageID("ghost")), kind: .update)])
        )
        #expect(FrontendWire.delta(from: missing).requiresSnapshot == true)
        let missingFrame = FrontendWire.delta(from: missing)
        #expect(missingFrame.changedNodes.isEmpty)
    }

    // MARK: - Commands

    @Test("FrontendCommand survives JSON and maps onto every ApplicationAction case")
    func frontendCommandMappingIsExhaustive() throws {
        let session = Self.sessionID
        let run = RunID("run-1")
        let interaction = InteractionID("inter-1")
        let commands: [FrontendCommand] = [
            .createSession(title: nil, mode: .plan),
            .createSession(title: "t", mode: .build),
            .switchSession(sessionID: session),
            .renameSession(sessionID: session, newTitle: "new"),
            .deleteSession(sessionID: session),
            .listSessions,
            .submitPrompt(text: "hello"),
            .stopCurrentRun,
            .cancelRun(runID: run, reason: nil),
            .setMode(mode: .plan),
            .setPermissionConfiguration(.yoloFullAccess),
            .setReasoningEffort(.low),
            .respondInteraction(interactionID: interaction, resolution: .permission(.allow)),
            .grantPermission(interactionID: interaction, decision: .deny),
            .replyQuestion(interactionID: interaction, reply: QuestionReply(questionID: QuestionID("q-1"), selectedOptionIndices: [0], text: "yes")),
            .submitDecision(interactionID: interaction, decision: "approve"),
            .selectModel(modelID: "gpt-x"),
            .listProviders,
            .listModels,
            .compactContext(sessionID: nil),
            .refreshExtensions,
            .refreshDiagnostics,
            .executeCommand(rawInput: "/help"),
            .reconnect,
        ]

        let encoder = FrontendWire.makeEncoder()
        let decoder = FrontendWire.makeDecoder()
        for command in commands {
            let data = try encoder.encode(command)
            #expect(try decoder.decode(FrontendCommand.self, from: data) == command, "round trip failed for \(data)")
            // Both sides must report the same case tag: proves the mapping is total and 1:1.
            #expect(commandTag(command) == actionTag(ApplicationAction.from(command)))
        }
        // No wire command may reach a lifecycle or store-internal action.
        #expect(commands.allSatisfy { !["lifecycle", "internal"].contains(actionTag(ApplicationAction.from($0))) })
        // JSON shape is an enum-of-object: {"switchSession":{"sessionID":{...}}}
        #expect(try json(encoder.encode(FrontendCommand.listSessions)) == "{\"listSessions\":{}}")
        #expect(try json(encoder.encode(FrontendCommand.stopCurrentRun)) == "{\"stopCurrentRun\":{}}")
    }

    @Test("SessionSummary produces the wire command that opens it")
    func catalogEntryProducesWireCommand() throws {
        let summary = SessionSummary(sessionID: Self.sessionID, title: "Contract")
        #expect(summary.toWireCommand() == .switchSession(sessionID: Self.sessionID))
        #expect(ApplicationAction.from(summary.toWireCommand()).tag == "switchSession")
    }

    // MARK: - ToolFamily

    @Test("ToolFamily classification matches the promoted GUI rules")
    func toolFamilyClassification() {
        let table: [(String, ToolFamily)] = [
            ("mcp__github__list_issues", .mcp),
            ("MCP.GitHub.list", .mcp),
            ("mcp:server:tool", .mcp),
            ("load_skill", .skill),
            ("skill_runner", .skill),
            ("browser_navigate", .browser),
            ("chrome_dev", .browser),
            ("computer_click", .computer),
            ("take_screenshot", .computer),
            ("Edit", .fileEdit),
            ("notebook_edit", .fileEdit),
            ("apply_patch", .fileEdit),
            ("Read", .fileRead),
            ("Grep", .search),
            ("glob_files", .search),
            ("Bash", .shell),
            ("run_command", .shell),
            ("git_status", .git),
            ("create_worktree", .git),
            ("Task", .subagent),
            ("subagent_spawn", .subagent),
            ("WebFetch", .network),
            ("websearch", .network),
            ("mystery_tool", .other),
        ]
        for (name, expected) in table {
            #expect(ToolFamily.classify(toolName: name) == expected, "misclassified \(name)")
        }
        // Capability only decides when the name is uninformative.
        #expect(ToolFamily.classify(toolName: "mystery_tool", capabilityKind: .processExecute) == .shell)
        #expect(ToolFamily.classify(toolName: "mystery_tool", capabilityKind: .networkAccess) == .network)
        #expect(ToolFamily.classify(toolName: "mcp__x__write_file", capabilityKind: .projectWrite) == .mcp)
        #expect(ToolFamily.classify(toolName: "mystery_tool", capabilityKind: .destructive) == .other)
        #expect(ToolFamily.allCases.map(\.rawValue) == [
            "mcp", "skill", "browser", "computer", "fileEdit", "fileRead",
            "search", "shell", "git", "subagent", "network", "other",
        ])
    }

    @Test("ToolNode exposes and encodes its derived tool family")
    func toolNodeFamilyIsEncoded() throws {
        let node = ToolNode(callID: ToolCallID("c"), toolName: "Bash", phase: .running)
        #expect(node.toolFamily == .shell)
        let json = try json(FrontendWire.makeEncoder().encode(node))
        #expect(json.contains("\"toolFamily\":\"shell\""))
        let decoded = try FrontendWire.makeDecoder().decode(ToolNode.self, from: Data(json.utf8))
        #expect(decoded == node)
        // Derived duration stays off the wire; the stored timestamps drive it.
        #expect(!json.contains("executionDuration"))
    }

    @Test("ThinkingNode Duration travels as durationSeconds")
    func thinkingNodeDuration() throws {
        let node = ThinkingNode(stepID: ModelStepID("s"), content: "x", duration: .milliseconds(1500))
        let json = try json(FrontendWire.makeEncoder().encode(node))
        #expect(json.contains("\"durationSeconds\":1.5"))
        #expect(!json.contains("\"duration\""))
        let decoded = try FrontendWire.makeDecoder().decode(ThinkingNode.self, from: Data(json.utf8))
        #expect(decoded == node)
        #expect(decoded.duration == .milliseconds(1500))
    }

    @Test("TimelineNode kind JSON shape is pinned: one key per case, payload under _0")
    func nodeKindShape() throws {
        let update = Self.makeUpdate()
        let data = try FrontendWire.makeEncoder().encode(update.state.activeSessionState!.timelineNodes)
        let json = try json(data)
        #expect(json.contains("\"kind\":{\"message\":{\"_0\":{"))
        #expect(json.contains("\"kind\":{\"tool\":{\"_0\":{"))
        // toolFamily travels next to the stored tool fields, inside the _0 payload.
        #expect(json.contains("\"toolFamily\":\"mcp\""))
    }

    // MARK: - Helpers

    private func json(_ data: Data) throws -> String { String(data: data, encoding: .utf8) ?? "" }

    private func nodeKindName(_ kind: TimelineNode.NodeKind) -> String {
        switch kind {
        case .message: "message"
        case .thinking: "thinking"
        case .tool: "tool"
        case .interaction: "interaction"
        case .subagent: "subagent"
        case .runTerminal: "runTerminal"
        case .error: "error"
        }
    }

    /// Exhaustive over `FrontendCommand`: a new case breaks compilation here.
    private func commandTag(_ command: FrontendCommand) -> String {
        switch command {
        case .createSession: "createSession"
        case .switchSession: "switchSession"
        case .renameSession: "renameSession"
        case .deleteSession: "deleteSession"
        case .listSessions: "listSessions"
        case .submitPrompt: "submitPrompt"
        case .stopCurrentRun: "stopCurrentRun"
        case .cancelRun: "cancelRun"
        case .setMode: "setMode"
        case .setPermissionConfiguration: "setPermissionConfiguration"
        case .setReasoningEffort: "setReasoningEffort"
        case .respondInteraction: "respondInteraction"
        case .grantPermission: "grantPermission"
        case .replyQuestion: "replyQuestion"
        case .submitDecision: "submitDecision"
        case .selectModel: "selectModel"
        case .listProviders: "listProviders"
        case .listModels: "listModels"
        case .compactContext: "compactContext"
        case .refreshExtensions: "refreshExtensions"
        case .refreshDiagnostics: "refreshDiagnostics"
        case .executeCommand: "executeCommand"
        case .reconnect: "reconnect"
        }
    }

    /// Exhaustive over `ApplicationAction`; internal/lifecycle cases map to "" so they can
    /// never be reached from a `FrontendCommand`.
    private func actionTag(_ action: ApplicationAction) -> String {
        switch action {
        case .createSession: "createSession"
        case .switchSession: "switchSession"
        case .renameSession: "renameSession"
        case .deleteSession: "deleteSession"
        case .listSessions: "listSessions"
        case .submitPrompt: "submitPrompt"
        case .stopCurrentRun: "stopCurrentRun"
        case .cancelRun: "cancelRun"
        case .setMode: "setMode"
        case .setPermissionConfiguration: "setPermissionConfiguration"
        case .setReasoningEffort: "setReasoningEffort"
        case .respondInteraction: "respondInteraction"
        case .grantPermission: "grantPermission"
        case .replyQuestion: "replyQuestion"
        case .submitDecision: "submitDecision"
        case .selectModel: "selectModel"
        case .listProviders: "listProviders"
        case .listModels: "listModels"
        case .compactContext: "compactContext"
        case .refreshExtensions: "refreshExtensions"
        case .refreshDiagnostics: "refreshDiagnostics"
        case .executeCommand: "executeCommand"
        case .reconnect: "reconnect"
        case .connect, .disconnect: "lifecycle"
        case ._connectionStateChanged, ._runtimeEventReceived, ._sessionEventReceived,
             ._streamFrameReceived, ._snapshotResynced, ._runtimeInfoResynced,
             ._runtimeHealthResynced, ._runtimeCapabilitiesResynced: "internal"
        }
    }
}

private extension TimelineNode.NodeKind {
    /// Stable per-kind marker used to prove the payload survived decoding.
    var descriptionFragment: String {
        switch self {
        case let .message(node): "message:\(node.messageID.rawValue)"
        case let .thinking(node): "thinking:\(node.stepID.rawValue)"
        case let .tool(node): "tool:\(node.callID.rawValue)"
        case let .interaction(node): "interaction:\(node.interactionID.rawValue)"
        case let .subagent(node): "subagent:\(node.runID.rawValue)"
        case let .runTerminal(node): "runTerminal:\(node.runID.rawValue)"
        case let .error(node): "error:\(node.errorID.rawValue)"
        }
    }
}

private extension ApplicationAction {
    var tag: String {
        switch self {
        case .createSession: "createSession"
        case .switchSession: "switchSession"
        case .renameSession: "renameSession"
        case .deleteSession: "deleteSession"
        case .listSessions: "listSessions"
        case .submitPrompt: "submitPrompt"
        case .stopCurrentRun: "stopCurrentRun"
        case .cancelRun: "cancelRun"
        case .setMode: "setMode"
        case .setPermissionConfiguration: "setPermissionConfiguration"
        case .setReasoningEffort: "setReasoningEffort"
        case .respondInteraction: "respondInteraction"
        case .grantPermission: "grantPermission"
        case .replyQuestion: "replyQuestion"
        case .submitDecision: "submitDecision"
        case .selectModel: "selectModel"
        case .listProviders: "listProviders"
        case .listModels: "listModels"
        case .compactContext: "compactContext"
        case .refreshExtensions: "refreshExtensions"
        case .refreshDiagnostics: "refreshDiagnostics"
        case .executeCommand: "executeCommand"
        case .reconnect: "reconnect"
        case .connect, .disconnect: "lifecycle"
        case ._connectionStateChanged, ._runtimeEventReceived, ._sessionEventReceived,
             ._streamFrameReceived, ._snapshotResynced, ._runtimeInfoResynced,
             ._runtimeHealthResynced, ._runtimeCapabilitiesResynced: "internal"
        }
    }
}
