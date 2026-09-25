#if canImport(SwiftUI)
import Foundation
import Testing
@testable import LingXiApplication
@testable import LingXiProtocol
@testable import LingXiFrontendKit

@Suite("GUI: ApplicationState projection and live backend", .serialized)
struct GUICoreProjectionTests {

    private func sessionState() -> SessionViewState {
        var session = SessionViewState(sessionID: SessionID("s1"), title: "修复构建")
        session.appendNode(TimelineNode(id: .message(MessageID("m1")),
                                        kind: .message(MessageNode(messageID: MessageID("m1"), role: .user, content: "跑一下构建"))))
        session.appendNode(TimelineNode(id: .tool(ToolCallID("t1")),
                                        kind: .tool(ToolNode(callID: ToolCallID("t1"), toolName: "shell",
                                                             argumentsJSON: #"{"command":"swift build","cwd":"/tmp/ws"}"#,
                                                             phase: .failed, stderr: "error: boom"))))
        let permission = PermissionRequest(permissionID: PermissionID("p1"), sessionID: SessionID("s1"),
                                           toolCallID: ToolCallID("t2"), toolID: ToolID("shell"),
                                           resource: "/tmp/ws", description: "rm -rf build")
        session.appendNode(TimelineNode(id: .interaction(InteractionID("i1")),
                                        kind: .interaction(InteractionNode(interactionID: InteractionID("i1"), kind: .permission,
                                                                           causal: CausalContext(sessionID: SessionID("s1")),
                                                                           permissionRequest: permission))))
        session.appendNode(TimelineNode(id: .message(MessageID("m2")),
                                        kind: .message(MessageNode(messageID: MessageID("m2"), role: .assistant,
                                                                   content: "构建失败", isStreaming: true))))
        session.activeTurnID = TurnID("turn-1")
        return session
    }

    @Test("Timeline nodes map to presentation items without inventing fields")
    func timelineProjection() {
        let items = CoreProjection.timeline(sessionState())
        #expect(items.count == 4)

        guard case let .user(text, _, messageID, _, sessionID) = items[0].kind else { Issue.record("expected user"); return }
        #expect(text == "跑一下构建")
        #expect(messageID == "m1")
        #expect(sessionID == "s1")

        guard case .tool(let call) = items[1].kind else { Issue.record("expected tool"); return }
        #expect(call.summary == "swift build")
        #expect(call.status == "failed")
        #expect(call.workingDirectory == "/tmp/ws")
        #expect(call.stderr == "error: boom")
        #expect(call.exitCode == nil)

        guard case .interaction(let card) = items[2].kind else { Issue.record("expected interaction"); return }
        #expect(card.kind == .permission)
        #expect(card.status == .pending)
        #expect(card.resource == "/tmp/ws")
        #expect(card.parametersSummary == "rm -rf build")

        guard case .assistant(let answer, let streaming) = items[3].kind else { Issue.record("expected assistant"); return }
        #expect(answer == "构建失败" && streaming)
    }

    @Test("Session catalog groups by working directory, newest first, running marked")
    func sidebarProjection() {
        var state = ApplicationState()
        state.sessionCatalog = [
            SessionSummary(sessionID: SessionID("old"), title: "旧", updatedAt: Date(timeIntervalSince1970: 1), workingDirectory: "/w/LingXi"),
            SessionSummary(sessionID: SessionID("s1"), title: nil, updatedAt: Date(timeIntervalSince1970: 9), workingDirectory: "/w/LingXi"),
            SessionSummary(sessionID: SessionID("x"), title: "别处", updatedAt: Date(timeIntervalSince1970: 5), workingDirectory: "/w/Other"),
        ]
        state.activeSessionID = SessionID("s1")
        state.activeSessionState = sessionState()

        let folders = CoreProjection.sessionFolders(state)
        #expect(folders.map(\.folderName) == ["LingXi", "Other"])
        #expect(folders[0].sessions.map(\.id) == ["s1", "old"])
        #expect(folders[0].sessions[0].title == "未命名会话")
        #expect(folders[0].sessions[0].isActive)
        #expect(!folders[0].sessions[1].isActive)
    }

    @Test("Unified diff parses into Git-style file changes")
    func diffParsing() {
        let diff = """
        diff --git a/A.swift b/A.swift
        index 1..2 100644
        --- a/A.swift
        +++ b/A.swift
        @@ -1,2 +1,3 @@
        -old
        +new
        +more
        diff --git a/New.swift b/New.swift
        new file mode 100644
        --- /dev/null
        +++ b/New.swift
        @@ -0,0 +1 @@
        +hello
        diff --git a/Old.swift b/Old.swift
        deleted file mode 100644
        --- a/Old.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        """
        let files = CoreProjection.fileChanges(fromUnifiedDiff: diff)
        #expect(files.map(\.path) == ["A.swift", "New.swift", "Old.swift"])
        #expect(files.map(\.change) == [.modified, .added, .deleted])
        #expect(files[0].additions == 2 && files[0].deletions == 1)
        #expect(files[1].additions == 1 && files[2].deletions == 1)
    }

    @Test("Permission presets round-trip Core's frozen configurations")
    func permissionPresets() {
        for preset in PermissionPreset.allCases {
            #expect(PermissionPreset(preset.configuration) == preset)
        }
        #expect(PermissionPreset.yoloFullAccess.isElevated)
        #expect(!PermissionPreset.autoWorkspace.isElevated)
    }

    @Test("Live backend: updates project into models, intents dispatch to the store")
    @MainActor
    func liveBackend() async throws {
        let runtime = RuntimeFrontend()
        #expect(runtime.conversationModel.items.isEmpty)   // no fixture outside preview()

        var state = ApplicationState()
        state.activeSessionID = SessionID("s1")
        state.activeSessionState = sessionState()
        state.sessionCatalog = [SessionSummary(sessionID: SessionID("s1"), title: "修复构建", workingDirectory: "/w/LingXi")]
        let mock = MockFrontendRuntime(initialState: state)
        runtime.attach(mock)
        mock.emitUpdate(ApplicationUpdate(revision: 1, state: state, changes: .fullSnapshot))

        for _ in 0..<50 where runtime.conversationModel.items.count != 4 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(runtime.conversationModel.items.count == 4)
        #expect(runtime.conversationModel.isGenerating)
        #expect(runtime.sidebarModel.selectedSessionID == "s1")
        #expect(runtime.inspectorModel.live != nil)

        runtime.sendMessage(text: "继续")
        runtime.composerModel.selectedMode = .plan
        runtime.resolveInteraction(interactionID: "i1", approved: false)

        for _ in 0..<50 where mock.dispatchedActions.count < 3 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let actions = mock.dispatchedActions.map { "\($0)" }
        #expect(actions.contains { $0.hasPrefix("submitPrompt(\"继续\")") })
        #expect(actions.contains { $0.hasPrefix("setMode(") && $0.contains("plan") })
        #expect(actions.contains { $0.hasPrefix("grantPermission(") && $0.contains("deny") })
    }
}
#endif
