#if os(macOS)
import Testing
import Foundation
import AppKit
import SwiftUI
import LingXiApplication
import LingXiProtocol
import LingXiClient
import LingXiPlatform
@testable import LingXiFrontendKit
@testable import LingXiTUI

private actor ComposerBackend: FrontendRuntime {
    var state: ApplicationState
    var availableCommands: [ApplicationCommand] { [] }
    var texts: [String] = []
    var streams: [UUID: AsyncStream<ApplicationUpdate>.Continuation] = [:]
    var revision: UInt64 = 0
    var deferCreation = false
    var deferredText: String?
    func deferNextCreation() { deferCreation = true }
    func createDeferredTurn() { if let text = deferredText { create(text: text, attachments: [], references: []) } }
    init() {
        let id = SessionID("composer-test")
        state = ApplicationState(connectionState: ConnectionState(status: .connected),
            activeSessionID: id, activeSessionState: SessionViewState(sessionID: id))
    }
    var updates: AsyncStream<ApplicationUpdate> {
        let id = UUID()
        let stream = AsyncStream<ApplicationUpdate> { continuation in
            streams[id] = continuation
            continuation.yield(ApplicationUpdate(revision: revision, state: state, changes: .fullSnapshot))
            continuation.onTermination = { [weak self] _ in Task { await self?.removeStream(id) } }
        }
        return stream
    }
    func removeStream(_ id: UUID) { streams.removeValue(forKey: id) }
    func dispatch(_ action: ApplicationAction) async {
        guard case let .submitPrompt(text, attachments, references) = action else { return }
        texts.append(text)
        if deferCreation {
            deferredText = text
            state.activeSessionState?.status = .waitingForProvider
            publish()
            return
        }
        create(text: text, attachments: attachments, references: references)
    }
    private func create(text: String, attachments: [ContentRef], references: [String]) {
        let session = state.activeSessionID!
        let turn = TurnSnapshot(sessionID: session, userMessage: MessageSnapshot(role: .user, text: text, attachments: attachments),
            executionIntent: TurnExecutionIntent(contextReferences: references), status: .running)
        state.activeSessionState?.turns[turn.turnID] = turn
        state.activeSessionState?.turnOrder.append(turn.turnID)
        state.activeSessionState?.activeTurnID = turn.turnID
        publish()
    }
    func finish(_ status: TurnStatus = .completed) {
        guard let id = state.activeSessionState?.activeTurnID,
              let old = state.activeSessionState?.turns[id] else { return }
        state.activeSessionState?.turns[id] = TurnSnapshot(turnID: id, sessionID: old.sessionID,
            userMessage: old.userMessage, executionIntent: old.executionIntent, status: status)
        state.activeSessionState?.activeTurnID = nil
        state.activeSessionState?.status = .ready
        publish()
    }
    private func publish() {
        revision += 1
        let update = ApplicationUpdate(revision: revision, state: state, changes: .fullSnapshot)
        for continuation in streams.values { continuation.yield(update) }
    }
}

@Suite("GUI automation real Composer path", .serialized)
@MainActor
struct GUIAutomationComposerTests {
    private func setup() async -> (RuntimeFrontend, ComposerBackend) {
        let runtime = RuntimeFrontend()
        let backend = ComposerBackend()
        runtime.attach(backend)
        runtime.apply(await backend.state)
        return (runtime, backend)
    }
    private func until(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw WaitTimeout() }
            await Task.yield()
        }
    }
    private struct WaitTimeout: Error {}
    private func send(_ runtime: RuntimeFrontend, _ text: String = "真实 Composer 输入", source: SubmissionSource = .cli) -> Task<GUIAutomationResponse, Never> {
        Task { await runtime.automationController.handle(GUIAutomationRequest(action: .send,
            tasks: [GUIAutomationTask(id: "T001", text: text)], source: source)) }
    }
    private func present(_ runtime: RuntimeFrontend) {
        runtime.automationController.composerPresented(revision: runtime.composerModel.draftRevision, text: runtime.composerModel.text)
    }

    @Test("CLI draft is real and observable before any User Message or Turn")
    func revisionBeforeTurnAndClearAfterSend() async throws {
        let (runtime, backend) = await setup()
        let submission = send(runtime, "第一行\n第二行\n第三行")
        try await until { runtime.composerModel.automationPending }
        #expect(runtime.composerModel.text == "第一行\n第二行\n第三行")
        #expect(runtime.composerModel.draftRevision > 0)
        #expect(runtime.composerModel.presentedRevision == nil)
        #expect(await backend.texts.isEmpty)
        #expect(await backend.state.activeSessionState?.turns.isEmpty == true)
        #expect(runtime.submitComposer() == nil, "Return must not bypass the pending presentation")
        let revision = runtime.composerModel.draftRevision
        present(runtime)
        let result = await submission.value
        #expect(result.accepted)
        #expect(result.results.first?.draftRevision == revision)
        #expect(result.results.first?.presentedRevision == revision)
        #expect(runtime.composerModel.text.isEmpty)
        #expect(await backend.texts == ["第一行\n第二行\n第三行"])
        #expect(result.events.map(\.name) == ["automation.command_received", "composer.draft_set", "composer.presented", "composer.send_invoked", "turn.created"])
        await runtime.closeWorkspace()
    }

    @Test("A nonempty user draft, including whitespace, is never overwritten")
    func occupied() async {
        let (runtime, backend) = await setup()
        for draft in ["用户正在编辑", "   "] {
            runtime.composerModel.text = draft
            let result = await send(runtime).value
            #expect(!result.accepted && result.reason == "composerOccupied")
            #expect(runtime.composerModel.text == draft)
        }
        #expect(await backend.texts.isEmpty)
        await runtime.closeWorkspace()
    }

    @Test("Stop before presentation creates no Turn and preserves the real draft")
    func stopBeforePresentation() async throws {
        let (runtime, backend) = await setup()
        let submission = send(runtime)
        try await until { runtime.composerModel.automationPending }
        runtime.stopGenerating()
        present(runtime)
        #expect(await submission.value.reason == "cancelled")
        #expect(await backend.texts.isEmpty)
        #expect(runtime.composerModel.text == "真实 Composer 输入")
        await runtime.closeWorkspace()
    }

    @Test("Stale or incorrect presentation acknowledgements cannot send")
    func stalePresentation() async throws {
        let (runtime, backend) = await setup()
        let submission = send(runtime)
        try await until { runtime.composerModel.automationPending }
        let model = runtime.composerModel
        runtime.automationController.composerPresented(revision: model.draftRevision - 1, text: model.text)
        runtime.automationController.composerPresented(revision: model.draftRevision, text: "wrong")
        #expect(model.presentedRevision == nil)
        #expect(await backend.texts.isEmpty)
        present(runtime)
        #expect(await submission.value.accepted)
        await runtime.closeWorkspace()
    }

    @Test("User edits cancel ownership, preserve their draft and create no Turn")
    func userEdit() async throws {
        let (runtime, backend) = await setup()
        let submission = send(runtime)
        try await until { runtime.composerModel.automationPending }
        runtime.composerModel.text = "用户改写的新内容"
        #expect(await submission.value.reason == "cancelled")
        #expect(runtime.composerModel.text == "用户改写的新内容")
        #expect(await backend.texts.isEmpty)
        await runtime.closeWorkspace()
    }

    @Test("Concurrent automation cannot replace the owned draft")
    func concurrent() async throws {
        let (runtime, backend) = await setup()
        let submission = send(runtime)
        try await until { runtime.composerModel.automationPending }
        #expect(await send(runtime, "overwrite").value.reason == "automationBusy")
        #expect(runtime.composerModel.text == "真实 Composer 输入")
        runtime.automationController.cancel()
        #expect(await submission.value.reason == "cancelled")
        #expect(await backend.texts.isEmpty)
        await runtime.closeWorkspace()
    }

    @Test("Every benchmark task repeats fill, presentation, Send and terminal wait")
    func batch() async throws {
        let (runtime, backend) = await setup()
        let benchmark = BenchmarkController(runtime: runtime)
        let submission = Task { await benchmark.run(tasks: (1...3).map { GUIAutomationTask(id: "T00\($0)", text: "Task \($0)") }) }
        for index in 1...3 {
            try await until { runtime.composerModel.automationPending && runtime.composerModel.text == "Task \(index)" }
            #expect(await backend.texts.count == index - 1)
            present(runtime)
            try await until { await backend.texts.count == index }
            #expect(runtime.composerModel.text.isEmpty)
            for _ in 0..<10 { await Task.yield() }
            #expect(!runtime.composerModel.automationPending, "Next draft waits for terminal")
            await backend.finish()
        }
        let result = await submission.value
        #expect(result.accepted && result.results.count == 3)
        for index in 1...3 {
            let events = result.events.filter { $0.taskID == "T00\(index)" }
            #expect(events.map(\.name) == ["automation.command_received", "composer.draft_set", "composer.presented", "composer.send_invoked", "turn.created", "turn.terminal"])
            #expect(events.allSatisfy { $0.source == .benchmark })
        }
        #expect(result.events.map(\.sequence) == result.events.map(\.sequence).sorted())
        await runtime.closeWorkspace()
    }

    @Test("Stopping a batch prevents all subsequent submissions")
    func cancelBatch() async throws {
        let (runtime, backend) = await setup()
        let submission = Task { await BenchmarkController(runtime: runtime).run(tasks: [GUIAutomationTask(id: "a", text: "One"), GUIAutomationTask(id: "b", text: "Two")]) }
        try await until { runtime.composerModel.automationPending }
        present(runtime)
        try await until { await backend.texts.count == 1 }
        runtime.stopGenerating()
        let response = await submission.value
        #expect(!response.accepted && response.reason == "cancelled")
        #expect(await backend.texts == ["One"])
        await runtime.closeWorkspace()
    }

    @Test("Source remains telemetry: User Message and execution intent contain only normal input")
    func sourceDoesNotEnterTurn() async throws {
        let (runtime, backend) = await setup()
        let submission = send(runtime, "same body", source: .benchmark)
        try await until { runtime.composerModel.automationPending }
        present(runtime)
        #expect(await submission.value.accepted)
        let turn = try #require(await backend.state.activeSessionState?.turns.values.first)
        #expect(turn.userMessage.text == "same body")
        #expect(turn.executionIntent.contextReferences.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(turn), as: UTF8.self)
        #expect(!encoded.contains("benchmark") && !encoded.contains("SubmissionSource"))
        await runtime.closeWorkspace()
    }

    @Test("CLI has no Core submission or client-send path; button and automation share Composer Send")
    func routing() throws {
        #expect(CLIParser.parse(arguments: ["gui", "send", "hello"]) == .gui(["send", "hello"]))
        let parsed = try GUIAutomationCLI.parse(["send", "hello\nworld"])
        #expect(parsed.tasks.first?.text == "hello\nworld")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cli = try String(contentsOf: root.appendingPathComponent("Sources/LingXiApplication/GUIAutomation/GUIAutomationCLI.swift"), encoding: .utf8)
        #expect(!cli.contains("CoreHost") && !cli.contains("LingXiClient") && !cli.contains("submitTurn") && !cli.contains("sendMessage"))
        let automation = try String(contentsOf: root.appendingPathComponent("Apps/macOS/FrontendKit/Frontend/GUIAutomationController.swift"), encoding: .utf8)
        #expect(!automation.contains(".dispatch(") && !automation.contains("sendMessage(") && !automation.contains("Task.sleep"))
        #expect(automation.contains("runtime.submitComposer()"))
        let composer = try String(contentsOf: root.appendingPathComponent("Apps/macOS/FrontendKit/Components/ComposerDock.swift"), encoding: .utf8)
        #expect(composer.contains("runtime.submitComposer()") && composer.contains("presentationRevision: model.automationPending"))
    }

    private struct NativeComposerFixture: View {
        @ObservedObject var model: ComposerModel
        let controller: GUIAutomationController
        var body: some View {
            MacNativeTextView(text: $model.text,
                presentationRevision: model.automationPending ? model.draftRevision : nil,
                focusRevision: model.automationPending ? model.draftRevision : nil,
                onPresented: controller.composerPresented)
        }
    }

    @Test("Real SwiftUI draft binding renders native text before acknowledging presentation and sending")
    func nativePresentation() async throws {
        let (runtime, backend) = await setup()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSHostingView(rootView: NativeComposerFixture(model: runtime.composerModel, controller: runtime.automationController))
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        let submission = send(runtime, "真实第一行\n真实第二行")
        try await until { runtime.composerModel.automationPending }
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        #expect(runtime.composerModel.presentedRevision == nil)
        #expect(await backend.texts.isEmpty)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(3)
        while runtime.composerModel.presentedRevision == nil && Date() < deadline {
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            NSApp.updateWindows()
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(runtime.composerModel.presentedRevision != nil, "visible=\(window.isVisible), occlusion=\(window.occlusionState.rawValue)")
        if runtime.composerModel.presentedRevision == nil { runtime.automationController.cancel() }
        #expect(await submission.value.accepted)
        #expect(await backend.texts == ["真实第一行\n真实第二行"])
        #expect(runtime.composerModel.text.isEmpty)
        await runtime.closeWorkspace()
    }

    @Test("Debug pause happens after presentation and Stop still prevents Turn creation")
    func pausedCancel() async throws {
        let (runtime, backend) = await setup()
        let submission = Task { await runtime.automationController.handle(GUIAutomationRequest(action: .send,
            tasks: [GUIAutomationTask(text: "pause")], source: .benchmark, pauseBeforeSend: true)) }
        try await until { runtime.composerModel.automationPending }
        present(runtime)
        #expect(runtime.composerModel.presentedRevision == runtime.composerModel.draftRevision)
        #expect(await backend.texts.isEmpty)
        runtime.stopGenerating()
        #expect(await submission.value.reason == "cancelled")
        #expect(await backend.texts.isEmpty)
        await runtime.closeWorkspace()
    }

    @Test("Explicit resume proceeds from a genuinely presented real draft")
    func resume() async throws {
        let (runtime, backend) = await setup()
        let submission = Task { await runtime.automationController.handle(GUIAutomationRequest(action: .send,
            tasks: [GUIAutomationTask(text: "resume")], source: .benchmark, pauseBeforeSend: true)) }
        try await until { runtime.composerModel.automationPending }
        #expect(await runtime.automationController.handle(GUIAutomationRequest(action: .resume)).reason == "notPaused")
        present(runtime)
        #expect(await backend.texts.isEmpty)
        #expect(await runtime.automationController.handle(GUIAutomationRequest(action: .resume)).accepted)
        #expect(await submission.value.accepted)
        #expect(await backend.texts == ["resume"])
        await runtime.closeWorkspace()
    }

    @Test("Normal Composer Send resumes a presented draft instead of cancelling or submitting twice")
    func normalSendResumesPresentedDraft() async throws {
        let (runtime, backend) = await setup()
        let submission = Task { await runtime.automationController.handle(GUIAutomationRequest(action: .send,
            tasks: [GUIAutomationTask(text: "user presses Send")], source: .benchmark, pauseBeforeSend: true)) }
        try await until { runtime.composerModel.automationPending }
        #expect(!runtime.conversationModel.isGenerating)
        #expect(await backend.texts.isEmpty)
        // Even a manual Send cannot bypass the native presentation boundary.
        await runtime.submitComposer()?.value
        #expect(await backend.texts.isEmpty)
        present(runtime)
        #expect(runtime.composerModel.text == "user presses Send")
        await runtime.submitComposer()?.value
        #expect(await submission.value.accepted)
        #expect(await backend.texts == ["user presses Send"])
        #expect(runtime.composerModel.text.isEmpty)
        #expect(!runtime.composerModel.automationPending)
        #expect(runtime.automationController.events.map(\.name) == [
            "automation.command_received", "composer.draft_set", "composer.presented", "composer.send_invoked", "turn.created"])
        await runtime.closeWorkspace()
    }

    @Test("Await actual turn-created evidence when dispatch returns before the Core event")
    func delayedCreation() async throws {
        let (runtime, backend) = await setup()
        await backend.deferNextCreation()
        let submission = send(runtime, "delayed")
        try await until { runtime.composerModel.automationPending }
        present(runtime)
        try await until { await backend.texts.count == 1 }
        #expect(!runtime.automationController.events.contains { $0.name == "turn.created" })
        await backend.createDeferredTurn()
        #expect(await submission.value.accepted)
        #expect(runtime.automationController.events.last?.name == "turn.created")
        await runtime.closeWorkspace()
    }

    @Test("A cancelled deferred creation wait returns without waiting for another Core event")
    func cancelCreationWait() async throws {
        let (runtime, backend) = await setup()
        await backend.deferNextCreation()
        let submission = send(runtime, "delayed")
        try await until { await backend.texts.count == 1 || runtime.composerModel.automationPending }
        present(runtime)
        try await until { await backend.texts.count == 1 }
        for _ in 0..<10 { await Task.yield() }
        runtime.automationController.cancel()
        #expect(await submission.value.reason == "cancelled")
        await runtime.closeWorkspace()
    }

    @Test("IPC routes into the GUI handler and protects its same-user socket")
    func ipc() async throws {
        let directory = URL(fileURLWithPath: "/tmp/gui-ipc-test-\(UUID().uuidString)")
        let path = directory.appendingPathComponent("automation.sock").path
        let server = try GUIAutomationIPC(path: path) { request in
            GUIAutomationResponse(accepted: request.action == .status, reason: request.action.rawValue)
        }
        defer { server.close(); try? FileManager.default.removeItem(at: directory) }
        let data = try await GUIAutomationSocket.request(JSONEncoder().encode(GUIAutomationRequest(action: .status)), path: path)
        let result = try JSONDecoder().decode(GUIAutomationResponse.self, from: data)
        #expect(result.accepted && result.reason == "status")
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int) == 0o700)
    }
}
#endif
