import Foundation
import LingXiKernel
import Testing

/// Test-only hook. Each case states exactly what the kernel must do with a verdict, and nothing about
/// a plugin or a process leaks into these assertions.
private struct ProbeHook: ContextHook {
    let handlerID: String
    let node: HookNode
    let priority: Int
    let canVeto: Bool
    let behaviour: @Sendable (HookInvocation) -> HookVerdict

    init(
        _ handlerID: String,
        node: HookNode = .contextPrepare,
        priority: Int = 0,
        canVeto: Bool = false,
        behaviour: @escaping @Sendable (HookInvocation) -> HookVerdict
    ) {
        self.handlerID = handlerID
        self.node = node
        self.priority = priority
        self.canVeto = canVeto
        self.behaviour = behaviour
    }

    func apply(_ invocation: HookInvocation) async -> HookVerdict { behaviour(invocation) }
}

/// Recorded synchronously inside the handler: the pipeline awaits each handler in order, so the
/// sequence is a fact about the kernel rather than a race the test has to win.
private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func add(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func marker(_ id: String = "hook-marker", role: MessageRole = .user) -> ContextEntry {
    ContextEntry(id: EntryID(id), segment: .derivedPage, role: role, payload: .text("[hook] \(id)"))
}

private func turnRequest(_ tag: String, turn: Int = 1) -> RunRequest {
    RunRequest(
        sessionID: SessionID("session-\(tag)"),
        turnID: TurnID("turn-\(turn)"),
        runID: RunID("run-\(tag)-\(turn)"),
        executionID: ExecutionID("exec-\(tag)-\(turn)"),
        model: ModelID("test-model"),
        prompt: "prompt \(turn)"
    )
}

@Test("PLG-006 a contextPrepare hook rewrites what actually reaches the provider")
func PLG_006_contextPrepareHookChangesTheRequest() async throws {
    let pipeline = HookPipeline(hooks: [ProbeHook("probe.marker") { invocation in
        .rewrite(entries: invocation.entries + [marker()])
    }])
    let provider = ScriptedProvider(scripts: [completed("done")])
    let loop = await makeLoop(
        provider: provider, executor: RecordingExecutor(),
        log: try DurableEventLog(sink: MemorySink()), hooks: pipeline
    )

    let result = await loop.run(turnRequest("hook-rewrite"), policy: LoopPolicy())

    #expect(result.status == .completed)
    // The node changed execution: the injected entry is on the wire, not merely observed.
    let sent = try #require(provider.request(at: 0))
    #expect(sent.entries.contains { $0.id == EntryID("hook-marker") })
    // Injection is data: it never occupies the instruction channel (CTX-001).
    let injected = try #require(sent.entries.first { $0.id == EntryID("hook-marker") })
    #expect(!injected.segment.isPrivileged)
    #expect(injected.role != .system)
}

@Test("CTX-001 hook output cannot escalate to the privileged instruction channel")
func CTX_001_hookOutputIsNeverAnInstruction() async throws {
    let pipeline = HookPipeline(hooks: [ProbeHook("probe.privilege") { invocation in
        .rewrite(entries: invocation.entries + [marker("hook-spoof", role: .system)])
    }])
    let provider = ScriptedProvider(scripts: [completed("never")])
    let loop = await makeLoop(
        provider: provider, executor: RecordingExecutor(),
        log: try DurableEventLog(sink: MemorySink()), hooks: pipeline
    )

    let result = await loop.run(turnRequest("hook-privilege"), policy: LoopPolicy())

    // Rejected by the protocol gate that also guards the budgeted request; nothing is sent.
    #expect(result.status == .failed)
    #expect(result.cause == .streamProtocolViolation)
    #expect(result.detail?.contains("invalid request") == true)
    #expect(provider.requestCount == 0)
}

@Test("PLG-006 a veto at either node stops the run before the provider sees a request")
func PLG_006_vetoDeniesBeforeAnyProviderRequest() async throws {
    for node in [HookNode.contextPrepare, HookNode.beforeModelRequest] {
        let pipeline = HookPipeline(hooks: [ProbeHook("probe.veto", node: node, canVeto: true) { _ in
            .veto(reason: "this request may not leave the process")
        }])
        let provider = ScriptedProvider(scripts: [completed("never")])
        let log = try DurableEventLog(sink: MemorySink())
        let loop = await makeLoop(
            provider: provider, executor: RecordingExecutor(), log: log, hooks: pipeline
        )
        let request = turnRequest("hook-veto-\(node.rawValue)")

        let result = await loop.run(request, policy: LoopPolicy())

        #expect(result.status == .failed)
        #expect(result.cause == .hookDenied)
        #expect(result.detail?.contains("this request may not leave the process") == true)
        #expect(result.detail?.contains(node == .contextPrepare ? "context preparation denied" : "model request denied") == true)
        #expect(provider.requestCount == 0)
        // The run still terminalized durably, so its execution state is released exactly once.
        #expect(result.terminalCommitted)
        #expect(provider.endedExecutions == [request.executionID])
    }
}

@Test("PLG-016 a transform-class hook that fails is skipped, and the skip is reported")
func PLG_016_transformFailureFailsOpenWithDiagnostic() async throws {
    let pipeline = HookPipeline(hooks: [ProbeHook("probe.transform") { _ in
        .failed(reason: "host timed out")
    }])
    let provider = ScriptedProvider(scripts: [completed("done")])
    let loop = await makeLoop(
        provider: provider, executor: RecordingExecutor(),
        log: try DurableEventLog(sink: MemorySink()), hooks: pipeline
    )

    let result = await loop.run(turnRequest("hook-transform-fault"), policy: LoopPolicy())
    #expect(result.status == .completed)
    #expect(result.detail?.contains("hookDiagnostics=[hook probe.transform skipped: host timed out]") == true)
    // Fail-open means the original request still goes out, unmodified.
    let sent = try #require(provider.request(at: 0))
    #expect(!sent.entries.contains { $0.id == EntryID("hook-marker") })
}

@Test("PLG-016 a security-class hook that fails denies, and it cannot opt out")
func PLG_016_securityClassFailureDenies() async throws {
    // The handler holds a veto capability, so the kernel classifies it as security and turns its
    // failure into a denial. There is no declaration available to the handler that changes this.
    let pipeline = HookPipeline(hooks: [ProbeHook("probe.guard", canVeto: true) { _ in
        .failed(reason: "approval service unreachable")
    }])
    let provider = ScriptedProvider(scripts: [completed("must not run")])
    let loop = await makeLoop(
        provider: provider, executor: RecordingExecutor(),
        log: try DurableEventLog(sink: MemorySink()), hooks: pipeline
    )

    let result = await loop.run(turnRequest("hook-security-fault"), policy: LoopPolicy())

    #expect(result.status == .failed)
    #expect(result.cause == .hookDenied)
    #expect(result.detail?.contains("denies on failure") == true)
    #expect(provider.requestCount == 0)

    #expect(HookPipeline.policy(of: ProbeHook("a", canVeto: true) { _ in .keep }) == .security)
    #expect(HookPipeline.policy(of: ProbeHook("b") { _ in .keep }) == .transform)
}

@Test("PLG-006 hooks run by priority then handler id, and later hooks see earlier output")
func PLG_006_orderIsPriorityThenHandlerID() async throws {
    let recorder = OrderRecorder()
    func hook(_ id: String, priority: Int) -> ProbeHook {
        ProbeHook(id, priority: priority) { invocation in
            recorder.add(id)
            return .rewrite(entries: invocation.entries + [marker("hook-\(id)")])
        }
    }
    // Installed in scrambled order on purpose: mounting must not decide execution order.
    let pipeline = HookPipeline(hooks: [
        hook("zulu", priority: 0),
        hook("alpha", priority: 0),
        hook("boss", priority: 10),
    ])
    let provider = ScriptedProvider(scripts: [completed("done")])
    let loop = await makeLoop(
        provider: provider, executor: RecordingExecutor(),
        log: try DurableEventLog(sink: MemorySink()), hooks: pipeline
    )

    #expect((await loop.run(turnRequest("hook-order"), policy: LoopPolicy())).status == .completed)
    #expect(recorder.all == ["boss", "alpha", "zulu"])

    let sent = try #require(provider.request(at: 0))
    #expect(
        sent.entries.filter { $0.id.rawValue.hasPrefix("hook-") }.map(\.id.rawValue)
            == ["hook-boss", "hook-alpha", "hook-zulu"]
    )
}

@Test("PLG-003 an unmounted hook stops participating in later runs")
func PLG_003_unmountedHookStopsParticipating() async throws {
    let provider = ScriptedProvider(scripts: [completed("one"), completed("two")])
    let log = try DurableEventLog(sink: MemorySink())
    let store = SessionStore()
    let pipeline = HookPipeline(hooks: [ProbeHook("probe.revocable") { invocation in
        .rewrite(entries: invocation.entries + [marker()])
    }])
    let loop = await makeLoop(
        provider: provider, executor: RecordingExecutor(), log: log, store: store, hooks: pipeline
    )

    let mounted = await loop.run(turnRequest("hook-revoke"), policy: LoopPolicy())
    #expect(mounted.status == .completed)
    #expect(try #require(provider.request(at: 0)).entries.contains { $0.id == EntryID("hook-marker") })

    // Revoke the capability: the next turn must not be touched by it at all.
    #expect(await pipeline.uninstall(handlerID: "probe.revocable"))
    #expect(await pipeline.mountedHandlerIDs.isEmpty)

    let after = await loop.run(turnRequest("hook-revoke", turn: 2), policy: LoopPolicy())
    #expect(after.status == .completed)
    let second = try #require(provider.request(at: 1))
    #expect(!second.entries.contains { $0.id == EntryID("hook-marker") })
}

@Test("PLG-006 the beforeModelRequest node runs after budgeting")
func PLG_006_beforeModelRequestRunsAfterBudget() async throws {
    let recorder = OrderRecorder()
    let pipeline = HookPipeline(hooks: [ProbeHook("probe.postbudget", node: .beforeModelRequest) { invocation in
        recorder.add("saw=\(invocation.entries.count)")
        return .rewrite(entries: invocation.entries + [marker()])
    }])
    let provider = ScriptedProvider(scripts: [completed("done")])
    let loop = await makeLoop(
        provider: provider, executor: RecordingExecutor(),
        log: try DurableEventLog(sink: MemorySink()), hooks: pipeline
    )

    // Tight enough that the planner has to evict before the node is reached.
    let result = await loop.run(turnRequest("hook-postbudget"), policy: LoopPolicy(preferredTokens: 40, hardTokens: 80))
    #expect(result.status == .completed)

    let sent = try #require(provider.request(at: 0))
    #expect(sent.entries.contains { $0.id == EntryID("hook-marker") })
    // The hook received the planned set, and the request carried what it returned.
    let saw = try #require(recorder.all.first)
    let plannedCount = try #require(Int(saw.split(separator: "=").last!))
    #expect(sent.entries.count == plannedCount + 1)
}
