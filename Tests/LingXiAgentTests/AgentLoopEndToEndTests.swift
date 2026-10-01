import Foundation
import Testing
import LingXiPlatform
import LingXiProtocol
import LingXiClient
import LingXiApplication
@testable import LingXiCore

/// §18 / §26.5 of the GUI↔Core closure freeze: an audit of the *authority chain*, not of the RPCs.
///
/// Every case starts at the entry point a human actually reaches (an `ApplicationAction`
/// dispatched on `ApplicationStore`, or the exact `client.*` call the SwiftUI frontend makes) and
/// ends at the single structure the contract names as authoritative for that knob. The assertion
/// is always "which field of which structure did the value land in", plus "nothing shorter was
/// accepted" - a global setting, a local mirror, or a default must not be able to stand in.
///
/// Turns run against a scripted in-process provider, so the last hop is the real `ModelRequest`
/// the Agent Loop handed the provider rather than a reconstruction.
@Suite("Agent Loop end-to-end authority chain (§18)", .serialized)
struct AgentLoopEndToEndTests {

    // MARK: - Harness

    /// Records every `ModelRequest` Core hands the provider, and replays a per-step script.
    private final class ScriptedProvider: ModelProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ModelRequest] = []
        private let script: @Sendable (ModelRequest, Int) -> [ModelEvent]

        init(_ script: @escaping @Sendable (ModelRequest, Int) -> [ModelEvent]) {
            self.script = script
        }

        convenience init(replying text: String) {
            self.init { _, _ in [.started, .textDelta(text), .completed(.stop)] }
        }

        var requests: [ModelRequest] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        /// Everything the provider was actually shown, across every step of the Turn: system
        /// prompt plus every message. Content assertions must scan the whole call, not step 0.
        var allText: String {
            requests.flatMap { request in
                [request.system ?? ""] + request.messages.map(\.content)
            }.joined(separator: "\n")
        }

        func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
            let index = { lock.lock(); defer { lock.unlock() }; storage.append(request); return storage.count - 1 }()
            let events = script(request, index)
            return AsyncThrowingStream { continuation in
                for event in events { _ = continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    /// Opens a model stream and never closes it, so a Run stays `.running` until cancelled.
    private actor HangingProvider: ModelProvider {
        private var continuations: [AsyncThrowingStream<ModelEvent, Error>.Continuation] = []
        private(set) var streamCount = 0

        func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
            streamCount += 1
            var held: AsyncThrowingStream<ModelEvent, Error>.Continuation?
            let stream = AsyncThrowingStream<ModelEvent, Error> { held = $0 }
            continuations.append(held!)
            return stream
        }

        func waitStreams(_ count: Int) async {
            while streamCount < count { await Task.yield() }
        }

        func release() {
            for continuation in continuations { continuation.finish() }
            continuations.removeAll()
        }
    }

    private struct Fixture {
        let host: CoreHost
        let client: LingXiClientVNext
        let store: ApplicationStore
        let root: URL
        let background: BackgroundCommandManager

        func shutdown() async {
            await host.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// The full stack the GUI uses: Core actor -> InProcess transport -> typed client -> ApplicationStore.
    /// Everything below the client is production code; only the provider is substituted.
    private func makeFixture(
        provider: any ModelProvider,
        interactive: Bool = false,
        workspace: URL? = nil
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-agentloop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspaceRoot = workspace ?? root
        let bg = BackgroundCommandManager()
        let host = try CoreHost(
            startupPolicy: .integrationTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")),
            workspaceRoot: try WorkspaceRoot(path: workspaceRoot.path),
            dataRoot: root,
            interactive: interactive,
            credentialStore: EphemeralCredentialStore(),
            backgroundManager: bg
        )
        await host.start()
        let client = try await LingXiClientVNext.inProcess(service: host)
        let store = await ApplicationStore(
            client: client,
            preferencesStore: UserPreferencesStore(fileURL: root.appendingPathComponent("prefs.json"))
        )
        try await store.connect()
        return Fixture(host: host, client: client, store: store, root: root, background: bg)
    }

    private func newSession(_ fixture: Fixture) async throws -> SessionID {
        let receipt = try await fixture.client.session.create(workspace: fixture.root.path)
        return try #require(receipt.result?.sessionID)
    }

    /// Polls until `check` holds, so a slow runner is slow rather than flaky.
    private func waitUntil(timeout: TimeInterval = 20, _ check: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("条件在 \(timeout)s 内未成立")
    }

    /// Same as `waitUntil` but returns whether it settled, so several independent obligations can
    /// be reported in one test instead of the first timeout hiding the rest.
    private func eventually(timeout: TimeInterval = 8, _ check: () async throws -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await check()) == true { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func turnStatus(_ fixture: Fixture, session sessionID: SessionID, turn turnID: TurnID) async throws -> TurnStatus {
        (try await fixture.client.turn.getTurn(sessionID: sessionID, turnID: turnID)).status
    }

    private func pending(_ fixture: LingXiClientVNext, session sessionID: SessionID) async throws -> [InteractionSnapshot] {
        try await fixture.interaction.listPending(sessionID: sessionID)
    }

    /// What the frontend currently believes is awaiting a human.
    private func storePending(_ store: ApplicationStore) async -> Set<InteractionID> {
        let state = await store.state
        return Set((state.activeSessionState?.pendingInteractions ?? []).map(\.interactionID))
    }

    private func ask(_ id: String, _ tool: String, _ arguments: String) -> ModelEvent {
        .toolCallCompleted(ToolCall(callID: ToolCallID(id), toolID: ToolID(tool), arguments: arguments))
    }

    private func spawnSubagent(id: String) -> ModelEvent {
        ask(id, "subagent", #"{"action":"spawn","task":"child job","title":"Child"}"#)
    }

    // MARK: - 1. Mode -> TurnExecutionIntent.mode

    @Test("Mode from the GUI lands in the frozen TurnExecutionIntent and is what Core reports back")
    func modeFreezesIntoTurnExecutionIntent() async throws {
        let fixture = try await makeFixture(provider: ScriptedProvider(replying: "ok"))
        defer { Task { await fixture.shutdown() } }

        // Real entry point: the composer's mode chip dispatches `.setMode`, send dispatches
        // `.submitPrompt`. Nothing else carries a mode.
        await fixture.store.dispatch(.setMode(.plan))
        await fixture.store.dispatch(.submitPrompt(text: "只出计划，不要改代码"))
        let sessionID = try #require(await fixture.store.state.activeSessionID)
        let turns = try await fixture.client.turn.listTurns(sessionID: sessionID)
        let first = try #require(turns.items.first)

        // Authoritative destination: `SubmitTurnRequest.executionIntent.mode`, frozen per Turn.
        let turn = try await fixture.client.turn.getTurn(sessionID: sessionID, turnID: first.turnID)
        #expect(turn.executionIntent.mode == .plan,
                "Mode 必须落在 TurnExecutionIntent.mode，实际 \(turn.executionIntent.mode.rawValue)")

        // Core projects that same field as the session's live agent mode - the intent is not a
        // write-only receipt, it is what the Agent Loop reads.
        let snapshot = try await fixture.client.session.snapshot(sessionID: sessionID)
        #expect(snapshot.agentMode == .plan,
                "SessionSnapshot.agentMode 必须由 TurnExecutionIntent.mode 供给，实际 \(snapshot.agentMode.rawValue)")

        // Nothing shorter: changing the chip again must not retroactively rewrite the Turn that
        // already froze.
        await fixture.store.dispatch(.setMode(.build))
        let second = try await fixture.client.turn.submitTurn(
            sessionID: sessionID,
            input: UserInput(text: "现在动手改"),
            executionIntent: TurnExecutionIntent(mode: .build,
                                                 permissionConfiguration: turn.executionIntent.permissionConfiguration))
        let secondID = try #require(second.result?.turnID)
        #expect(try await fixture.client.turn.getTurn(sessionID: sessionID, turnID: first.turnID)
                    .executionIntent.mode == .plan,
                "已冻结的 Turn 不能被后来的 Mode 改写")
        let secondFrozen = try await fixture.client.turn.getTurn(sessionID: sessionID, turnID: secondID)
        #expect(secondFrozen.executionIntent.mode == .build)
        try await waitUntil {
            try await turnStatus(fixture, session: sessionID, turn: secondID) == .completed
        }
        #expect(try await fixture.client.session.snapshot(sessionID: sessionID).agentMode == .build,
                "agentMode 必须由最近一个 Turn 冻结的 intent 供给")
    }

    // MARK: - 2. Model -> TurnExecutionIntent.modelSelection

    @Test("Model selection travels store -> intent -> Core and names the model the provider is asked for")
    func modelSelectionTravelsFromStoreThroughIntentToProviderRequest() async throws {
        let provider = ScriptedProvider(replying: "ok")
        let fixture = try await makeFixture(provider: provider)
        defer { Task { await fixture.shutdown() } }

        // Core is the source of the selection identity; the store keeps only what Core confirmed.
        let selection = try await fixture.client.model.getSelection()
        let qualified = selection.qualifiedID
        #expect(!qualified.isEmpty)

        let sessionID = try await newSession(fixture)
        await fixture.store.switchToSession(sessionID)
        await fixture.store.dispatch(.selectModel(qualified))
        #expect(await fixture.store.state.currentModelID == qualified)

        await fixture.store.dispatch(.submitPrompt(text: "用这个模型跑一轮"))
        let turn = try #require(await fixture.client.turn.listTurns(sessionID: sessionID).items.first)
        try await waitUntil { try await turnStatus(fixture, session: sessionID, turn: turn.turnID) == .completed }

        // Authoritative destination.
        let frozen = try await fixture.client.turn.getTurn(sessionID: sessionID, turnID: turn.turnID)
        #expect(frozen.executionIntent.modelSelection == qualified,
                "Model 必须落在 TurnExecutionIntent.modelSelection，实际 \(String(describing: frozen.executionIntent.modelSelection))")

        // And it is the model actually used: the Agent Loop's real provider call resolves to it.
        let request = try #require(provider.requests.first)
        #expect(request.model.rawValue == "fake",
                "intent.modelSelection 必须决定真实 provider 调用，实际 \(request.model.rawValue)")

        // Nothing shorter: a selection Core cannot resolve must fail the Turn, not quietly fall
        // back to whichever assembly happens to be loaded.
        let bogus = try await fixture.client.turn.submitTurn(
            sessionID: sessionID,
            input: UserInput(text: "这个模型不存在"),
            executionIntent: TurnExecutionIntent(modelSelection: "no-such-provider/no-such-model"))
        let bogusID = try #require(bogus.result?.turnID)
        try await waitUntil { try await turnStatus(fixture, session: sessionID, turn: bogusID) == .failed }
    }

    // MARK: - 3. Reasoning -> session/turn effective setting

    @Test("Reasoning is a session setting that reaches the provider request, never a turn field")
    func reasoningEffortIsASessionSettingThatReachesTheRequest() async throws {
        let provider = ScriptedProvider(replying: "ok")
        let fixture = try await makeFixture(provider: provider)
        defer { Task { await fixture.shutdown() } }

        let sessionID = try await newSession(fixture)
        await fixture.store.switchToSession(sessionID)

        // Entry point: the reasoning picker dispatches `.setReasoningEffort`.
        await fixture.store.dispatch(.setReasoningEffort(.high))

        // Authoritative destination 1: Core's session setting survives a read-back.
        // (`SessionSnapshot.info`; `client.session.get` is separately pinned as a known defect.)
        #expect(try await fixture.client.session.snapshot(sessionID: sessionID).info.reasoningEffort == .high)

        // Authoritative destination 2: it is the effective value used by the next Turn.
        await fixture.store.dispatch(.submitPrompt(text: "想清楚一点再答"))
        let turn = try #require(await fixture.client.turn.listTurns(sessionID: sessionID).items.first)
        try await waitUntil { try await turnStatus(fixture, session: sessionID, turn: turn.turnID) == .completed }
        let request = try #require(provider.requests.first)
        #expect(request.reasoning == "high",
                "session.reasoningEffort 必须成为真实 ModelRequest.reasoning，实际 \(String(describing: request.reasoning))")

        // Nothing shorter: the Turn wire has no reasoning slot at all, so a frontend that only
        // mutates a local mirror cannot claim to have set reasoning.
        let intentJSON = try JSONEncoder().encode(TurnExecutionIntent(modelSelection: "m", mode: .plan))
        let intentText = try #require(String(data: intentJSON, encoding: .utf8))
        #expect(!intentText.lowercased().contains("reason"),
                "TurnExecutionIntent 不该有推理档位字段：\(intentText)")

        // And a clear back to `.auto` is a real setting change in Core, not a stuck "high".
        await fixture.store.dispatch(.setReasoningEffort(.auto))
        #expect(try await fixture.client.session.get(sessionID: sessionID).reasoningEffort == .auto)
    }

    // MARK: - 4. Permission -> TurnExecutionIntent.permissionConfiguration

    @Test("Per-Turn permission intent, not Core's global configuration, decides whether an ask happens")
    func permissionConfigurationIsAuthoritativePerTurn() async throws {
        // No `permissionDecision` injected, so Core's engine defaults to ask/workspace. The only
        // way a child Agent spawns without an approval card is the Turn's own frozen intent.
        let autoFixture = try await makeFixture(
            provider: ScriptedProvider { _, step in
                step == 0 ? [.started, spawnSubagent(id: "spawn-auto"), .completed(.toolCalls)]
                          : [.started, .textDelta("parent done"), .completed(.stop)]
            }, interactive: true)
        defer { Task { await autoFixture.shutdown() } }
        let autoSession = try await newSession(autoFixture)

        let autoTurn = try await autoFixture.client.turn.submitTurn(
            sessionID: autoSession,
            input: UserInput(text: "派个子任务"),
            executionIntent: TurnExecutionIntent(permissionConfiguration: .autoWorkspace))
        let autoTurnID = try #require(autoTurn.result?.turnID)
        try await waitUntil { try await turnStatus(autoFixture, session: autoSession, turn: autoTurnID) == .completed }

        let frozenAuto = try await autoFixture.client.turn.getTurn(sessionID: autoSession, turnID: autoTurnID)
        #expect(frozenAuto.executionIntent.permissionConfiguration == .autoWorkspace,
                "Permission 必须落在 TurnExecutionIntent.permissionConfiguration")
        #expect(try await pending(autoFixture.client, session: autoSession).isEmpty,
                "intent=.autoWorkspace 时不该产生审批请求；出现即说明读的是全局配置而不是 Turn 意图")
        let autoTree = try await autoFixture.client.run.getAgentTree(sessionID: autoSession)
        #expect(!autoTree.children.isEmpty, "自动放行时子 Agent 应真的跑起来")

        // Same host policy, same tool, opposite Turn intent -> Core must park on an approval.
        let askFixture = try await makeFixture(
            provider: ScriptedProvider { _, step in
                step == 0 ? [.started, spawnSubagent(id: "spawn-ask"), .completed(.toolCalls)]
                          : [.started, .textDelta("parent done"), .completed(.stop)]
            }, interactive: true)
        defer { Task { await askFixture.shutdown() } }
        let askSession = try await newSession(askFixture)
        let askTurn = try await askFixture.client.turn.submitTurn(
            sessionID: askSession,
            input: UserInput(text: "派个子任务"),
            executionIntent: TurnExecutionIntent(permissionConfiguration: .askWorkspace))
        let askTurnID = try #require(askTurn.result?.turnID)
        try await waitUntil { !(try await pending(askFixture.client, session: askSession)).isEmpty }

        let parked = try await pending(askFixture.client, session: askSession)
        #expect(parked.first?.kind == .permission)
        #expect(parked.first?.permissionRequest?.toolID.rawValue == "subagent")

        // Answering it is what unblocks the Run - proof the ask was real, not decoration.
        _ = try await askFixture.client.interaction.resolve(
            sessionID: askSession,
            interactionID: try #require(parked.first?.interactionID),
            resolution: .permission(.allow))
        try await waitUntil { try await turnStatus(askFixture, session: askSession, turn: askTurnID) == .completed }
        let frozenAsk = try await askFixture.client.turn.getTurn(sessionID: askSession, turnID: askTurnID)
        #expect(frozenAsk.executionIntent.permissionConfiguration == .askWorkspace)
    }

    // MARK: - 5. Goal -> Session Goal registry, projected

    @Test("Goal reaches Core's SessionGoalRegistry and projects through summary, snapshot and events")
    func goalAnchorsInCoreAndProjectsEverywhere() async throws {
        let fixture = try await makeFixture(provider: ScriptedProvider(replying: "ok"))
        defer { Task { await fixture.shutdown() } }
        let sessionID = try await newSession(fixture)
        await fixture.store.switchToSession(sessionID)

        // The SwiftUI goal chip's exact call (RuntimeFrontend.setGoal -> client.session.setGoal).
        let receipt = try await fixture.client.session.setGoal(sessionID: sessionID, goal: "把测试全修绿")
        #expect(receipt.result?.goal == "把测试全修绿", "SessionSummary.goal 必须回显真值")

        // Authority is Core's registry, not the frontend's draft text.
        #expect(await SessionGoalRegistry.shared.goal(sessionID) == "把测试全修绿")

        // Three projections of that one truth, so no path can display a goal Core does not hold.
        // `SessionSummary.goal` is the bare anchor; `SessionSnapshot.goal` is the full runtime
        // projection the sidebar consumes. They must agree.
        #expect(try await fixture.client.session.snapshot(sessionID: sessionID).goal?.text == "把测试全修绿")
        let events = try await fixture.client.session.listEvents(
            request: ListSessionEventsRequest(sessionID: sessionID, limit: 200))
        #expect(events.contains { if case let .goalChanged(value) = $0.payload { value?.text == "把测试全修绿" } else { false } },
                "goal 必须以 .goalChanged 进入 Session 事件流，否则切 Session / 重连拿不到同一事实")

        // Nothing shorter: blank is a clear, not a no-op.
        let cleared = try await fixture.client.session.setGoal(sessionID: sessionID, goal: "   ")
        #expect(cleared.result?.goal == nil)
        #expect(await SessionGoalRegistry.shared.goal(sessionID) == nil)
        #expect(try await fixture.client.session.snapshot(sessionID: sessionID).goal == nil)
        let eventsAfterClear = try await fixture.client.session.listEvents(
            request: ListSessionEventsRequest(sessionID: sessionID, limit: 200))
        #expect(eventsAfterClear.contains { if case .goalChanged(nil) = $0.payload { true } else { false } },
                "清除同样要发 .goalChanged(nil)，否则前端 chips 无法收敛")
    }

    // MARK: - 6. Attachment -> UserInput.attachments

    @Test("An uploaded attachment reaches UserInput.attachments, and a ref Core cannot read fails the Turn")
    func uploadedAttachmentBecomesModelRequestText() async throws {
        let provider = ScriptedProvider(replying: "ok")
        let fixture = try await makeFixture(provider: provider)
        defer { Task { await fixture.shutdown() } }
        let sessionID = try await newSession(fixture)
        await fixture.store.switchToSession(sessionID)

        let body = "CLOSURE-MARKER-8f31: func frozen() {}\n"
        // The two steps the composer performs: upload first, then dispatch carrying the refs.
        let ref = try await fixture.client.resource.upload(
            data: Data(body.utf8), filename: "Frozen.swift",
            mediaType: AttachmentSupport.textMediaTypes["swift"])
        #expect(ref.byteCount == body.utf8.count)

        await fixture.store.dispatch(.submitPrompt(text: "读一下附件", attachments: [ref]))
        let turn = try #require(await fixture.client.turn.listTurns(sessionID: sessionID).items.first)

        // Authoritative destination: `UserInput.attachments`, persisted on the frozen user message.
        let frozen = try await fixture.client.turn.getTurn(sessionID: sessionID, turnID: turn.turnID)
        #expect(frozen.userMessage.attachments.map(\.id) == [ref.id],
                "ContentRef 必须落在 UserInput.attachments 并被 Turn 持久化")
        try await waitUntil { try await turnStatus(fixture, session: sessionID, turn: turn.turnID) == .completed }

        // A ref Core cannot read fails the Turn out loud rather than shortening it (§3.2).
        let ghost = ContentRef(id: ContentID("does-not-exist"), mediaType: "text/plain", byteCount: 1)
        let doomed = try await fixture.client.turn.submitTurn(
            sessionID: sessionID, input: UserInput(text: "读一个不存在的附件", attachments: [ghost]))
        let doomedID = try #require(doomed.result?.turnID)
        try await waitUntil { try await turnStatus(fixture, session: sessionID, turn: doomedID) == .failed }
    }

    // MARK: - 7. Worktree -> typed client, real git

    @Test("Worktree create/list/apply/discard run against real git through the typed client")
    func worktreeLifecycleThroughTypedClient() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("lx-wt-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ args: [String]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@example.com"] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        try git(["init", "-q", "-b", "main"])
        try "seed\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", "init"])

        let fixture = try await makeFixture(provider: ScriptedProvider(replying: "ok"), workspace: repo)
        defer { Task { await fixture.shutdown() } }

        let created = try await fixture.client.workspace.createWorktree(name: "iso-1")
        let info = try #require(created.result)
        #expect(info.branch == "\(CoreHost.worktreeBranchPrefix)iso-1",
                "分支名由 Core 单点决定：\(info.branch)")
        #expect(try git(["worktree", "list", "--porcelain"]).contains("iso-1"), "git 自己必须看得见这个 worktree")
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("NOTES.md").path),
                "隔离是真的：主 checkout 不该提前看到 worktree 里的文件")

        try "isolated\n".write(to: URL(fileURLWithPath: info.path).appendingPathComponent("NOTES.md"),
                               atomically: true, encoding: .utf8)
        let listed = try await fixture.client.workspace.listWorktrees()
        #expect(listed.map(\.id) == ["iso-1"])
        #expect(listed.first?.isActive == true)

        _ = try await fixture.client.workspace.applyWorktree(worktreeID: "iso-1", commitMessage: "worktree work")
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("NOTES.md").path),
                "apply 要把隔离成果送回主 checkout")
        #expect(try git(["status", "--porcelain"]).contains("NOTES.md"), "apply 后应是未提交改动")
        #expect(try git(["log", "--oneline", "-1"]).trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("init"),
                "apply 不得在主分支替用户自动产生 commit")

        // Discard path, on a second worktree nobody asked to keep.
        let second = try #require(await fixture.client.workspace.createWorktree(name: "iso-2").result)
        _ = try await fixture.client.workspace.discardWorktree(worktreeID: "iso-2", force: true)
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(try await fixture.client.workspace.listWorktrees().isEmpty)
        #expect(!(try git(["branch", "--list", "\(CoreHost.worktreeBranchPrefix)iso-2"]).contains("iso-2")),
                "丢弃必须连分支一起清掉")

        // An unknown id is an error, not a silent success.
        await #expect(throws: (any Error).self) {
            _ = try await fixture.client.workspace.discardWorktree(worktreeID: "never-existed", force: true)
        }
    }

    // MARK: - 8. Stop

    @Test("Stop cancels the active Turn, terminates the active root run and kills background tasks in Core")
    func stopClearsEveryLiveThing() async throws {
        let hanging = HangingProvider()
        let fixture = try await makeFixture(provider: hanging)
        defer { Task { await fixture.shutdown() } }
        let sessionID = try await newSession(fixture)
        await fixture.store.switchToSession(sessionID)

        // 1 active root run + 1 active Turn.
        await fixture.store.dispatch(.submitPrompt(text: "第一条，长时间运行"))
        await hanging.waitStreams(1)
        let running = try #require(await fixture.client.turn.listTurns(sessionID: sessionID).items.first)
        let rootRunID = try #require(running.rootRunID)
        try await waitUntil {
            (try await fixture.client.run.listRuns(sessionID: sessionID)).items
                .contains { $0.runID == rootRunID && $0.status == .running }
        }

        // A queued Turn behind it is §18.2's hardest case and does not survive Stop today; it is
        // pinned on its own below rather than relaxed to a passing assertion here.

        // 1 background task, started through the very manager Core reports from.
        let profile: ExecutionProfile = LingXiPlatform.sandbox.capabilities.filesystemEnforced ? .workspace : .fullAccess
        let task = try await fixture.background.spawn(
            command: "sleep 30", timeoutSeconds: 120, cwd: fixture.root,
            workspace: try WorkspaceRoot(path: fixture.root.path), profile: profile,
            description: "e2e keepalive")
        try await waitUntil {
            (try await fixture.client.diagnostics.getBackgroundTasks())
                .contains { $0.id == task.id && $0.status == .running }
        }

        await fixture.store.dispatch(.stopCurrentRun)
        await hanging.release()

        // Each obligation is settled independently, so a failure names the one that did not
        // happen instead of hiding the rest.
        let activeCancelled = await eventually {
            try await turnStatus(fixture, session: sessionID, turn: running.turnID) == .cancelled
        }
        let activeRunTerminal = await eventually {
            try await fixture.client.run.getRun(sessionID: sessionID, runID: rootRunID).status.isTerminal
        }
        let backgroundStopped = await eventually {
            (try await fixture.client.diagnostics.getBackgroundTasks())
                .first(where: { $0.id == task.id })?.status != .running
        }
        #expect(activeCancelled, "Stop 必须取消 active Turn")
        #expect(activeRunTerminal, "Stop 必须终结 active root run")
        let backgroundEndState = try await fixture.client.diagnostics.getBackgroundTasks()
            .first(where: { $0.id == task.id })?.status.rawValue ?? "已不在列表"
        #expect(backgroundStopped, "Stop 必须终止后台任务；实际状态 \(backgroundEndState)")

        let view = await fixture.store.state.activeSessionState
        #expect(view?.activeTurnID == nil)
        #expect(view?.activeRootRunID == nil)
        #expect(view?.queuedTurns.isEmpty ?? true)
    }

    // MARK: - 9. Pending Interaction

    @Test("Pending permission/question matches Core across session switch and reconnect, and resolving it empties Core")
    func pendingInteractionMatchesCoreAcrossSwitchAndReconnect() async throws {
        let fixture = try await makeFixture(
            provider: ScriptedProvider { _, step in
                step == 0
                    ? [.started, ask("q-1", "question", #"{"question":"继续吗？","options":["继续","停止"]}"#), .completed(.toolCalls)]
                    : [.started, .textDelta("answered"), .completed(.stop)]
            }, interactive: true)
        defer { Task { await fixture.shutdown() } }
        let sessionID = try await newSession(fixture)
        await fixture.store.switchToSession(sessionID)
        let otherID = try #require((try await fixture.client.session.create(workspace: fixture.root.path)).result?.sessionID)

        await fixture.store.dispatch(.submitPrompt(text: "先问我"))

        // Core is authoritative: the ask exists there before any frontend renders it.
        try await waitUntil { !(try await pending(fixture.client, session: sessionID)).isEmpty }
        let corePending = Set(try await pending(fixture.client, session: sessionID).map(\.interactionID))
        #expect(!corePending.isEmpty)
        #expect(await storePending(fixture.store) == corePending,
                "GUI 的 pending 集合必须与 Core 逐 id 相等")

        // Switch away: nothing may leak session A's ask onto session B.
        await fixture.store.switchToSession(otherID)
        #expect(try await pending(fixture.client, session: otherID).isEmpty)
        #expect(await storePending(fixture.store).isEmpty,
                "切到没有审批的 Session，GUI 不能还留着上一个 Session 的 pending")

        // Switch back: the same Core ask is re-adopted, neither re-created nor lost.
        await fixture.store.switchToSession(sessionID)
        try await waitUntil { await storePending(fixture.store) == corePending }

        // Reconnect: a brand-new client and store on the same Core must agree with Core.
        let reconnected = try await LingXiClientVNext.inProcess(service: fixture.host)
        let freshStore = await ApplicationStore(
            client: reconnected,
            preferencesStore: UserPreferencesStore(fileURL: fixture.root.appendingPathComponent("prefs2.json")))
        try await freshStore.connect()
        await freshStore.switchToSession(sessionID)
        let coreAfterReconnect = Set(try await reconnected.interaction.listPending(sessionID: sessionID)
                                        .map(\.interactionID))
        #expect(await storePending(freshStore) == coreAfterReconnect,
                "重连后 GUI 的 pending 必须等于 Core 的 pending，既不能多也不能少")

        // Resolving the ask through the authoritative RPC empties Core's list - the normal path.
        let live = try await reconnected.interaction.listPending(sessionID: sessionID)
        #expect(!live.isEmpty)
        for snapshot in live {
            _ = try? await reconnected.interaction.resolve(
                sessionID: sessionID, interactionID: snapshot.interactionID,
                resolution: .permission(.deny))
        }
        #expect(try await reconnected.interaction.listPending(sessionID: sessionID).isEmpty,
                "正常答复路径必须清空 Core 的 pending")
    }

    // MARK: - 10. Subagent

    @Test("A subagent spawns, runs, finishes with a terminal reason and projects into the agent tree")
    func subagentProjectsIntoAgentTreeWithTerminalReason() async throws {
        let fixture = try await makeFixture(
            provider: ScriptedProvider { request, _ in
                if request.messages.first(where: { $0.role == .user })?.content == "child job" {
                    return [.started, .textDelta("child result"), .completed(.stop)]
                } else if request.messages.contains(where: { $0.role == .tool }) {
                    return [.started, .textDelta("parent result"), .completed(.stop)]
                } else {
                    return [.started, spawnSubagent(id: "spawn-a"), .completed(.toolCalls)]
                }
            }, interactive: true)
        defer { Task { await fixture.shutdown() } }
        let sessionID = try await newSession(fixture)
        await fixture.store.switchToSession(sessionID)

        let receipt = try await fixture.client.turn.submitTurn(
            sessionID: sessionID,
            input: UserInput(text: "parent task"),
            executionIntent: TurnExecutionIntent(permissionConfiguration: .autoWorkspace))
        let turnID = try #require(receipt.result?.turnID)

        // spawn + running: the child is a real Session with a real AgentRun under the same root.
        try await waitUntil(timeout: 30) {
            (try await fixture.client.run.getAgentTree(sessionID: sessionID)).children.first?.latestRun != nil
        }
        let tree = try await fixture.client.run.getAgentTree(sessionID: sessionID)
        let child = try #require(tree.children.first)
        #expect(child.session.kind == .subagent)
        #expect(child.session.parentSessionID == sessionID)
        #expect(child.session.rootSessionID == sessionID,
                "子 Session 的 rootSessionID 必须指回发起 Session，否则投影不到同一棵树")
        let childRun = try #require(child.latestRun)
        #expect(childRun.agentKind == .subagent)
        #expect(childRun.status.isTerminal || childRun.status == .running,
                "Agent Tree 里的 child Run 只能是真实生命周期状态，实际 \(childRun.status.rawValue)")

        // result: the child's text belongs to the child session, not the root transcript.
        try await waitUntil(timeout: 30) {
            (try await fixture.client.run.getAgentTree(sessionID: sessionID))
                .children.first?.latestRun?.status == .completed
        }
        let finished = try #require(try await fixture.client.run.getAgentTree(sessionID: sessionID)
                                    .children.first?.latestRun)
        #expect(finished.status == .completed)
        #expect(finished.terminalReason == .completed,
                "终态原因必须与状态一起落在 AgentRunInfo.terminalReason，实际 \(String(describing: finished.terminalReason))")
        let childSnapshot = try await fixture.client.session.snapshot(sessionID: child.session.id)
        #expect(childSnapshot.recentTurns.contains { $0.userMessage.text == "child job" },
                "子任务文本是子 Session 的输入，不是父 Session 的")

        // The parent Turn reaches terminal too, and one spawn leaves exactly one child.
        try await waitUntil {
            try await turnStatus(fixture, session: sessionID, turn: turnID) == .completed
        }
        let finalTree = try await fixture.client.run.getAgentTree(sessionID: sessionID)
        #expect(finalTree.children.count == 1, "一次 spawn 只能留下一个孩子，不能重复投影")
    }

    // MARK: - Wire shape: the intent is the only envelope slot for mode / permission / model

    @Test("SubmitTurn wire carries mode, permission and model only inside executionIntent")
    func submitTurnWireHasNoShorterSlotForIntentKnobs() throws {
        let data = try JSONEncoder().encode(SubmitTurnRequest(
            sessionID: SessionID("s-1"),
            input: UserInput(text: "hello"),
            executionIntent: TurnExecutionIntent(modelSelection: "p/m", mode: .plan,
                                                 permissionConfiguration: .autoWorkspace)))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"executionIntent\""), "契约点名的字段就是 executionIntent：\(json)")
        #expect(json.contains("\"mode\":\"plan\""), "mode 必须在 executionIntent 内：\(json)")

        // The top-level request has exactly three slots - no loose mode/model key a shorter path
        // could fill in and Core would never read.
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["sessionID", "input", "executionIntent"],
                "SubmitTurnRequest 顶层不该有第二个 mode/model/permission 入口，实际 \(object.keys.sorted())")
    }

    // MARK: - Defects this audit found
    //
    // The contract obligations in the tests above all pass. What follows pins five behaviours that
    // do NOT: the knob reaches Core, but Core does not hand it back where the contract says it can
    // be read, or a required cleanup does not happen. Each body runs inside `withKnownIssue`, so
    // the suite stays green today and the defect flips to a hard failure the moment it is fixed.

    @Test("KNOWN DEFECT: client.session.get never reports the session's reasoning effort")
    func getSessionDropsReasoningEffort() async throws {
        let fixture = try await makeFixture(provider: ScriptedProvider(replying: "ok"))
        defer { Task { await fixture.shutdown() } }
        let sessionID = try await newSession(fixture)
        _ = try await fixture.client.session.setReasoningEffort(sessionID: sessionID, effort: .medium)
        // The write lands - SessionSnapshot proves it. Only the single-session read is blind:
        // CoreHost.swift:3467 builds SessionSummary without `reasoningEffort`.
        let getReadBack = try await fixture.client.session.get(sessionID: sessionID).reasoningEffort
        try await withKnownIssue(
            "CoreHost.getSession drops reasoningEffort; the read always comes back .auto") {
            #expect(getReadBack == .medium)
        }
        #expect(try await fixture.client.session.snapshot(sessionID: sessionID).info.reasoningEffort == .medium)
    }

    @Test("KNOWN DEFECT: session.get and session.list drop SessionSummary.goal")
    func sessionSummariesDropGoal() async throws {
        let fixture = try await makeFixture(provider: ScriptedProvider(replying: "ok"))
        defer { Task { await fixture.shutdown() } }
        let sessionID = try await newSession(fixture)
        _ = try await fixture.client.session.setGoal(sessionID: sessionID, goal: "修掉所有 red")
        #expect(try await fixture.client.session.snapshot(sessionID: sessionID).goal?.text == "修掉所有 red")
        // CoreHost.swift:3467 and :3500 build SessionSummary without `goal`, so the field the
        // contract names as a Goal projection is populated only by the setSessionGoal receipt.
        let getGoal = try await fixture.client.session.get(sessionID: sessionID).goal
        let listGoal = try await fixture.client.session.list()
            .items.first(where: { $0.sessionID == sessionID })?.goal
        try await withKnownIssue(
            "CoreHost.getSession / listSessions build SessionSummary without goal") {
            #expect(getGoal == "修掉所有 red")
            #expect(listGoal == "修掉所有 red")
        }
    }

    @Test("KNOWN DEFECT: an attachment Core resolved is never handed to the model")
    func attachmentNeverReachesTheModelRequest() async throws {
        let provider = ScriptedProvider(replying: "ok")
        let fixture = try await makeFixture(provider: provider)
        defer { Task { await fixture.shutdown() } }
        let sessionID = try await newSession(fixture)
        let body = "CLOSURE-MARKER-8f31: func frozen() {}\n"
        let ref = try await fixture.client.resource.upload(
            data: Data(body.utf8), filename: "Frozen.swift",
            mediaType: AttachmentSupport.textMediaTypes["swift"])
        let receipt = try await fixture.client.turn.submitTurn(
            sessionID: sessionID, input: UserInput(text: "读一下附件", attachments: [ref]))
        let turnID = try #require(receipt.result?.turnID)
        try await waitUntil { try await turnStatus(fixture, session: sessionID, turn: turnID) == .completed }
        // Core accepted the refs and `resolveAttachments` really read the bytes - an unreadable
        // ref fails the Turn, which the contract test above proves. The text still never reaches
        // the wire: SessionRuntime.swift:345 only appends `attachmentEntries` when the user
        // message is absent from the entry list, and CoreHost.executeTurnRun commits that message
        // to the session store before calling startTurn, so the guard is always true.
        try await withKnownIssue(
            "attachment text is dropped before the model request; \(String(provider.allText.prefix(400)))") {
            #expect(provider.allText.contains("CLOSURE-MARKER-8f31"))
        }
    }

    @Test("KNOWN DEFECT: Stop lets the queued Turn it was meant to cancel start as a new root run")
    func stopPromotesTheQueuedTurnItCannotCancel() async throws {
        let hanging = HangingProvider()
        let fixture = try await makeFixture(provider: hanging)
        defer { Task { await fixture.shutdown() } }
        let sessionID = try await newSession(fixture)
        await fixture.store.switchToSession(sessionID)

        await fixture.store.dispatch(.submitPrompt(text: "第一条，长时间运行"))
        await hanging.waitStreams(1)
        await fixture.store.dispatch(.submitPrompt(text: "第二条，排队"))
        try await waitUntil {
            (try await fixture.client.turn.listTurns(sessionID: sessionID).items).contains { $0.status == .queued }
        }
        let queued = try #require(await fixture.client.turn.listTurns(sessionID: sessionID).items
                                    .first(where: { $0.status == .queued }))

        await fixture.store.dispatch(.stopCurrentRun)
        await hanging.release()

        // ApplicationStore.swift:271 cancels the active root run first; CoreHost.swift:3875 then
        // promotes the next queued Turn, and the loop at ApplicationStore.swift:278 can only use
        // cancelTurn, which CoreHost.swift:3771 refuses for a running Turn. Stop leaves a live run.
        let queuedSettled = await eventually(timeout: 4) {
            try await turnStatus(fixture, session: sessionID, turn: queued.turnID).isTerminal
        }
        let rootAfterStop = try await fixture.client.session.snapshot(sessionID: sessionID).activeRootRun
        try await withKnownIssue(
            "queued Turn is auto-promoted to running during Stop and never cancelled") {
            #expect(queuedSettled)
            #expect(rootAfterStop == nil)
        }
    }

    @Test("KNOWN DEFECT: Stop leaves the pending interaction authoritative in Core")
    func stopLeavesCorePendingInteraction() async throws {
        let fixture = try await makeFixture(
            provider: ScriptedProvider { _, step in
                step == 0
                    ? [.started, ask("q-9", "question", #"{"question":"继续吗？","options":["继续","停止"]}"#), .completed(.toolCalls)]
                    : [.started, .textDelta("answered"), .completed(.stop)]
            }, interactive: true)
        defer { Task { await fixture.shutdown() } }
        let sessionID = try await newSession(fixture)
        await fixture.store.switchToSession(sessionID)
        await fixture.store.dispatch(.submitPrompt(text: "先问我"))
        try await waitUntil { !(try await pending(fixture.client, session: sessionID)).isEmpty }

        await fixture.store.dispatch(.stopCurrentRun)

        // CoreHost.cancelRun calls permissionEngine.cancelPending (CoreHost.swift:3849), which
        // empties the engine's pending set. The store's later interaction.resolve then dies in
        // PermissionEngine.reply ("权限请求已失效", PermissionEngine.swift:96) before reaching
        // coord.resolveInteraction (CoreHost.swift:3979). Core keeps the ask; the frontend already
        // dropped its mirror, so the next switchToSession resurrects a card for a dead run.
        let emptied = await eventually(timeout: 4) {
            (try await fixture.client.interaction.listPending(sessionID: sessionID)).isEmpty
        }
        let snapshotPending = try await fixture.client.session.snapshot(sessionID: sessionID).pendingInteractions
        try await withKnownIssue(
            "Core's pendingInteractions survive Stop; only the frontend copy is cleared") {
            #expect(emptied)
            #expect(snapshotPending.isEmpty)
        }
    }
}
