import Foundation
import Testing
import LingXiPlatform
import LingXiProtocol
import LingXiClient
import LingXiApplication
@testable import LingXiCore

/// The invariant this whole surface is built on: Developer Debug Mode observes, it does not act.
///
/// Everything here exists to answer one question with a machine-checkable yes — does turning debug
/// telemetry on change what LingXiAgent sends to the model? It must not, because the moment it can,
/// the hundreds-of-turns P/E-Core run stops measuring the system and starts measuring the
/// measurement, and every conclusion drawn from it about page-out behaviour and prefix-cache hits
/// becomes an artefact of the observer.
///
/// The proof deliberately does not hash requests. `ModelRequest` and everything inside it are
/// `Equatable`, so the stable fields are compared by real equality — a collision cannot hide a
/// difference. `requestID`, `continuationOf` and `executionID` are excluded because they are
/// per-call identity by construction (`requestID` defaults to a fresh UUID), so no reader should
/// take these assertions as "the whole request object compared equal".
@Suite("Runtime Observatory is a pure bypass", .serialized)
struct RuntimeObservatoryBypassTests {

    // MARK: - Harness
    //
    // Mirrors AgentLoopEndToEndTests' fixture. Duplicated rather than shared because that harness
    // is `private` to its suite, and widening it would tie two unrelated tests' lifetimes together.

    /// Records every `ModelRequest` Core hands the provider and replays a fixed reply.
    private final class ScriptedProvider: ModelProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ModelRequest] = []
        private let reply: String

        init(replying text: String) { self.reply = text }

        var requests: [ModelRequest] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
            lock.lock()
            storage.append(request)
            lock.unlock()
            return AsyncThrowingStream { continuation in
                continuation.yield(.started)
                continuation.yield(.textDelta(reply))
                continuation.yield(.completed(.stop))
                continuation.finish()
            }
        }
    }

    private struct Fixture {
        let host: CoreHost
        let client: LingXiClientVNext
        let store: ApplicationStore
        /// Per-run: holds `debug/mode.json`, so one arm can be on and the other off.
        let root: URL
        /// Shared across arms. The environment block injected into the system message embeds
        /// `workspaceRoot` and `cwd`, so two runs against different workspaces differ for a reason
        /// that has nothing to do with debug mode — and the comparison would be comparing paths.
        let workspace: URL

        func shutdown() async {
            await host.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// The real stack the GUI uses: Core actor -> in-process transport -> typed client -> store.
    /// Only the provider is substituted.
    private func makeFixture(provider: any ModelProvider, workspace: URL) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-observatory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = try CoreHost(
            startupPolicy: .integrationTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")),
            workspaceRoot: try WorkspaceRoot(path: workspace.path),
            dataRoot: root,
            interactive: false,
            credentialStore: EphemeralCredentialStore()
        )
        await host.start()
        let client = try await LingXiClientVNext.inProcess(service: host)
        let store = await ApplicationStore(
            client: client,
            preferencesStore: UserPreferencesStore(fileURL: root.appendingPathComponent("prefs.json"))
        )
        try await store.connect()
        return Fixture(host: host, client: client, store: store, root: root, workspace: workspace)
    }

    /// One workspace shared by every arm of a comparison, cleaned up by the caller.
    private func makeSharedWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-observatory-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func newSession(_ fixture: Fixture) async throws -> SessionID {
        let receipt = try await fixture.client.session.create(workspace: fixture.workspace.path)
        return try #require(receipt.result?.sessionID)
    }

    private func waitUntil(timeout: TimeInterval = 30, _ check: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("条件在 \(timeout)s 内未成立")
    }

    /// Drives one prompt at a time through the same entry point the GUI uses, waiting for each Turn
    /// to settle so the next one starts from a known state.
    private func runPrompts(_ fixture: Fixture, session sessionID: SessionID,
                            prompts: [String], on provider: ScriptedProvider) async throws {
        for prompt in prompts {
            let before = provider.requests.count
            await fixture.store.dispatch(.submitPrompt(text: prompt))
            try await waitUntil { provider.requests.count > before }
            try await waitUntil {
                let turns = try await fixture.client.turn.listTurns(sessionID: sessionID)
                #expect(!turns.items.isEmpty)
                return turns.items.allSatisfy {
                    [.completed, .failed, .cancelled].contains($0.status)
                }
            }
        }
    }

    // MARK: - Default off

    @Test("a fresh Core has debug mode off and says so rather than throwing")
    func debugModeDefaultsToOff() async throws {
        let workspace = try makeSharedWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = try await makeFixture(provider: ScriptedProvider(replying: "ok"), workspace: workspace)
        defer { Task { await fixture.shutdown() } }

        // Status answers even while disabled. It is how a client learns whether this Core has an
        // Observatory at all, so "off" must not be reported as "absent".
        let status = try await fixture.client.debug.status()
        #expect(status.enabled == false)
        #expect(status.recording == false)
        #expect(status.eventsBuffered == 0)
        #expect(status.eventsDropped == 0)

        let availability = await fixture.client.debug.probe()
        #expect(availability == .disabled, "探测把「未开启」误判成「没有这个功能」：\(availability)")
    }

    // MARK: - Disabled means unavailable, never fake

    @Test("with debug mode off the reads refuse instead of answering with empty or zero")
    func disabledReadsAreUnavailableNotFabricated() async throws {
        let workspace = try makeSharedWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = try await makeFixture(provider: ScriptedProvider(replying: "ok"), workspace: workspace)
        defer { Task { await fixture.shutdown() } }
        let sessionID = try await newSession(fixture)

        // An empty page would be indistinguishable from "recording, nothing happened"; a zeroed
        // snapshot from "recording, and the cache is fine". Both are fabrications, so both throw.
        do {
            _ = try await fixture.client.debug.snapshot(sessionID: sessionID)
            Issue.record("未开启时 snapshot 竟然成功返回")
        } catch let error as CoreError {
            #expect(error.code == .unsupportedCommand,
                    "未开启时应报 unsupportedCommand，实际 \(error.code.rawValue)")
        }

        do {
            _ = try await fixture.client.debug.events()
            Issue.record("未开启时 events 竟然返回空页")
        } catch let error as CoreError {
            #expect(error.code == .unsupportedCommand)
        }
    }

    // MARK: - The equivalence proof

    @Test("turning debug mode on does not change a single model request")
    func debugModeDoesNotChangeModelRequests() async throws {
        let prompts = ["第一条指令", "第二条指令", "第三条指令"]
        let workspace = try makeSharedWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        // Run A: default off. Run B: enabled before any turn. Same prompts, same scripted reply,
        // same fresh data root, so the flag is the only difference between them.
        let providerA = ScriptedProvider(replying: "steady answer")
        let fixtureA = try await makeFixture(provider: providerA, workspace: workspace)
        defer { Task { await fixtureA.shutdown() } }
        let sessionA = try await newSession(fixtureA)
        await fixtureA.store.switchToSession(sessionA)
        try await runPrompts(fixtureA, session: sessionA, prompts: prompts, on: providerA)

        let statusA = try await fixtureA.client.debug.status()
        #expect(statusA.enabled == false, "A 组必须确实处于关闭态，否则这条对比是空的")

        let providerB = ScriptedProvider(replying: "steady answer")
        let fixtureB = try await makeFixture(provider: providerB, workspace: workspace)
        defer { Task { await fixtureB.shutdown() } }
        let sessionB = try await newSession(fixtureB)
        await fixtureB.store.switchToSession(sessionB)
        let enabled = try await fixtureB.client.debug.setEnabled(true)
        #expect(enabled.enabled, "开启后 Core 未确认状态，后续对比无意义")
        try await runPrompts(fixtureB, session: sessionB, prompts: prompts, on: providerB)

        let requestsA = providerA.requests
        let requestsB = providerB.requests

        // Count first. If a debug branch changed *when* compaction fires, or added a step, the runs
        // diverge here — and without this check every element-wise comparison below could be
        // vacuously true over a truncated zip.
        #expect(requestsA.count == requestsB.count,
                "请求数不同：off=\(requestsA.count) on=\(requestsB.count)，说明 Debug Mode 影响了 Agent Loop")
        #expect(requestsA.count >= prompts.count,
                "脚本未产生预期的 provider 调用数：\(requestsA.count)，两组对比都可能落空")

        for (index, pair) in zip(requestsA, requestsB).enumerated() {
            let diff = Self.firstDifference(Self.stable(of: pair.0), Self.stable(of: pair.1))
            #expect(diff == nil,
                    "第 \(index) 次 provider 调用在 Debug Mode 开启后发生了变化：\(diff ?? "")")
        }

        // The bypass must actually have run, or both arms may simply have taken the same dead path.
        let statusB = try await fixtureB.client.debug.status()
        #expect(statusB.enabled)
        #expect(statusB.eventsBuffered > 0,
                "Debug Mode 开启却一条遥测都没有，on 组是空的，等价性证明不成立")
    }

    @Test("enabling debug mode mid-session does not perturb the next request")
    func midSessionToggleLeavesRequestsIdentical() async throws {
        // The case a lazy implementation gets wrong: state allocated on first enable — a ring, a
        // per-session map — leaking into what the next turn sends.
        let prompts = ["一", "二", "三", "四"]
        let workspace = try makeSharedWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let providerRef = ScriptedProvider(replying: "same")
        let fixtureRef = try await makeFixture(provider: providerRef, workspace: workspace)
        defer { Task { await fixtureRef.shutdown() } }
        let refSession = try await newSession(fixtureRef)
        await fixtureRef.store.switchToSession(refSession)
        try await runPrompts(fixtureRef, session: refSession, prompts: prompts, on: providerRef)

        let providerToggle = ScriptedProvider(replying: "same")
        let fixtureToggle = try await makeFixture(provider: providerToggle, workspace: workspace)
        defer { Task { await fixtureToggle.shutdown() } }
        let toggleSession = try await newSession(fixtureToggle)
        await fixtureToggle.store.switchToSession(toggleSession)
        try await runPrompts(fixtureToggle, session: toggleSession,
                             prompts: Array(prompts.prefix(2)), on: providerToggle)
        _ = try await fixtureToggle.client.debug.setEnabled(true)
        try await runPrompts(fixtureToggle, session: toggleSession,
                             prompts: Array(prompts.dropFirst(2)), on: providerToggle)

        let reference = providerRef.requests
        let toggled = providerToggle.requests
        #expect(toggled.count == reference.count,
                "中途开启改变了请求数：\(toggled.count) vs \(reference.count)")
        for (index, pair) in zip(reference, toggled).enumerated() {
            let diff = Self.firstDifference(Self.stable(of: pair.0), Self.stable(of: pair.1))
            let stage = index < 2 ? "开启之前" : "开启之后"
            #expect(diff == nil, "第 \(index) 次调用（\(stage)）发生了变化：\(diff ?? "")")
        }
    }

    // MARK: - Bounded, fail-open

    @Test("the ring is bounded and reports what it discarded")
    func ringBufferIsBoundedAndReportsLosses() {
        let capacity = 32
        let hub = DebugTelemetryHub(capacity: capacity)
        let sessionID = SessionID("s-ring")
        let emitted = capacity * 4

        for _ in 0..<emitted {
            hub.record(.cacheHit, sessionID: sessionID)
        }

        let status = hub.status()
        #expect(status.eventsBuffered == capacity,
                "环形缓冲超出容量：\(status.eventsBuffered) > \(capacity)")
        #expect(status.eventsDropped == emitted - capacity,
                "丢弃数量与实际不符：\(status.eventsDropped)")
        // Loss has to be admitted rather than reconstructed from a gap a reader must notice.
        #expect(status.eventsDropped > 0)
        #expect(hub.totalRecorded() == emitted,
                "总数须包含被挤掉的事件，否则无法区分「没发生」与「发生了但被丢弃」")

        #expect(hub.hasGap(before: 1), "已经丢弃过却报告无缺口")
        #expect(hub.events(after: 0, limit: 1000).count == capacity)
        // Sequence stays monotonic across the retained window, which is what makes causal
        // ordering ("page-out preceded bust") answerable at all.
        let retained = hub.events(after: 0, limit: 1000)
        #expect(retained.map(\.sequence) == retained.map(\.sequence).sorted(),
                "读取顺序不是按 sequence 递增")
    }

    @Test("a recorder that cannot write degrades instead of failing the run")
    func recorderWriteFailureFailsOpen() async throws {
        // A path that cannot become a directory: an ordinary file sits where one is needed.
        let blockerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-recorder-blocked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: blockerRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: blockerRoot) }
        let blocker = blockerRoot.appendingPathComponent("blocked", isDirectory: false)
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        let archive = blocker.appendingPathComponent("nested", isDirectory: true)

        let hub = DebugTelemetryHub(capacity: 512)
        let recorder = DebugRunRecorder(directory: archive)
        let opened = await recorder.start(runName: "blocked", manifest: nil)
        hub.setRecorder(recorder, runName: "blocked")

        for _ in 0..<200 {
            hub.record(.cacheMiss, sessionID: SessionID("s-fail-open"))
        }
        await recorder.flush()

        let snapshot = await recorder.snapshot()
        let status = hub.status()
        // Either the archive never opened, or it opened and then failed. Both must be counted,
        // neither may throw.
        #expect(opened == false || snapshot.failures > 0,
                "写入失败被静默吞掉：opened=\(opened) failures=\(snapshot.failures)")
        #expect(status.eventsDropped == 0,
                "归档坏了不该波及内存遥测：dropped=\(status.eventsDropped)")
        #expect(hub.events(after: 0, limit: 500).count > 0,
                "归档失败后内存环形缓冲也跟着丢数据")
        hub.setRecorder(nil, runName: nil)
    }

    // MARK: - Stable projection

    /// Everything about a request that must survive a debug-mode toggle, minus the three fields
    /// that are per-call identity by construction.
    ///
    /// `cachePlan` stays in: it is what a provider's own prefix cache keys on, so a toggle that
    /// perturbs the epoch or the immutable base is exactly the failure being tested for. Nested
    /// values are compared as themselves rather than stringified, because `ModelContentPart` has
    /// five cases including tool calls and results — a hand-written text rendering would be a
    /// second definition of "same request", and the whole point is to have only one.
    ///
    /// Excluded, each for a reason that is not "it happened to differ":
    ///   - `requestID`, `continuationOf`, `executionID`: per-call identity; `requestID` defaults to
    ///     a fresh UUID, so two runs can never compare equal with them included.
    ///   - `overallTimeoutSeconds`, `idleTimeoutSeconds`: `SessionRuntime` fills these from
    ///     `deadline.remainingSeconds()`, so they are wall-clock residuals that differ between any
    ///     two runs of the same script. They were excluded after a pre-toggle request already
    ///     differed on them, which is the proof they are not debug-dependent.
    static func stable(of request: ModelRequest) -> StableRequest {
        StableRequest(request)
    }

    /// Names the first field that differs.
    ///
    /// Field-by-field rather than one whole-struct equality: a `StableRequest` carries the entire
    /// tool schema, so `#expect(a == b)` prints tens of kilobytes and still does not say which
    /// field moved.
    static func firstDifference(_ lhs: StableRequest, _ rhs: StableRequest) -> String? {
        if lhs.model != rhs.model { return "model" }
        if lhs.system != rhs.system { return "system" }
        if lhs.messages != rhs.messages {
            guard lhs.messages.count == rhs.messages.count else {
                return "messages count \(lhs.messages.count) vs \(rhs.messages.count)"
            }
            for (i, pair) in zip(lhs.messages, rhs.messages).enumerated() where pair.0 != pair.1 {
                return "messages[\(i)] role \(pair.0.role.rawValue)/\(pair.1.role.rawValue) "
                    + "parts:\n  OFF \(Self.brief(pair.0))\n  ON  \(Self.brief(pair.1))"
            }
            return "messages"
        }
        if lhs.tools != rhs.tools { return "tools(\(lhs.tools.count) vs \(rhs.tools.count))" }
        if lhs.reasoning != rhs.reasoning { return "reasoning" }
        if lhs.debugStep != rhs.debugStep { return "debugStep" }
        if lhs.cachePlan != rhs.cachePlan { return "cachePlan" }
        return nil
    }

    /// A short, comparable rendering of one message, for a failure message that has to fit on screen.
    static func brief(_ message: ModelMessage) -> String {
        message.parts.map { part -> String in
            switch part {
            case .text(let text):
                return "text[" + text.prefix(320).replacingOccurrences(of: "\n", with: "⏎") + "]"
            case .image(let mediaType, let data):
                return "image[\(mediaType),\(data.count)B]"
            case .imageFile(let mediaType, let data, let fileID):
                return "imageFile[\(mediaType),\(data.count)B,\(fileID)]"
            case .toolCall, .toolResult:
                // Rendered generically on purpose: these carry ids and timing, and this helper
                // only has to point at where two runs diverged, not model their schema.
                return String(describing: part).prefix(180).description
            }
        }.joined(separator: " + ")
    }

    struct StableRequest: Equatable {
        let model: LingXiCore.ModelID
        let system: String?
        let messages: [ModelMessage]
        let tools: [ToolDefinition]
        let reasoning: String?
        let debugStep: Int?
        let cachePlan: CanonicalCachePlan?

        init(_ request: ModelRequest) {
            self.model = request.model
            self.system = request.system
            self.messages = request.messages
            self.tools = request.tools
            self.reasoning = request.reasoning
            self.debugStep = request.debugStep
            self.cachePlan = request.cachePlan
        }
    }
}
