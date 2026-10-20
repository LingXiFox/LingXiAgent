import Foundation
import LingXiKernel
import LingXiPluginABI
import LingXiPluginRuntime
import Testing

private let mimoID = "site.lingxi.provider.mimo"

private struct RecordedMiMoCassette: Decodable {
    let provider: String
    let exchanges: [Exchange]
    struct Exchange: Decodable { let events: [ProviderWireEvent] }
}
private let mimoFixtureURL: URL = Bundle.module.url(
    forResource: "mimo-chat-fixture", withExtension: "json", subdirectory: "Fixtures"
)!

private final class MiMoEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ModelEvent] = []
    func append(_ event: ModelEvent) { lock.lock(); stored.append(event); lock.unlock() }
    var events: [ModelEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    func reset() { lock.lock(); stored.removeAll(); lock.unlock() }
}

private struct MiMoTeeProvider: ModelProvider {
    let inner: any ModelProvider
    let recorder: MiMoEventRecorder
    var capabilities: ModelCapabilities { inner.capabilities }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let upstream = try await inner.stream(request)
        let recorder = self.recorder
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        recorder.append(event)
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func endExecution(_ executionID: ExecutionID) async { await inner.endExecution(executionID) }
}

private final class MiMoEchoExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ToolCall] = []
    func execute(_ call: ToolCall, descriptor: ToolDescriptor) async throws -> ToolOutcome {
        record(call)
        return ToolOutcome(callID: call.callID, content: "echo accepted \(call.argumentsJSON)", isError: false, effect: .readOnly)
    }

    private func record(_ call: ToolCall) {
        lock.lock(); calls.append(call); lock.unlock()
    }
    var executed: [ToolCall] { lock.lock(); defer { lock.unlock() }; return calls }
}

private struct MiMoHarness {
    let loop: AgentLoop
    let coordinator: PluginCoordinator
    let recorder: MiMoEventRecorder
    let executor: MiMoEchoExecutor
}

private func makeMiMoHarness(
    grants: [String], model: String = "mimo-v2.6-flash",
    credential: @escaping @Sendable () -> String?
) async throws -> MiMoHarness {
    let bundle = try makeBundle(
        bundleID: mimoID,
        executableName: "MiMoProvider",
        dylib: builtProduct("libMiMoProvider.dylib"),
        capabilities: ["provider.mimo"]
    )
    let registry = try PluginRegistry(configURL: nil)
    let coordinator = PluginCoordinator(
        hostExecutableURL: builtProduct("LingXiPluginHost"),
        registry: registry,
        pipeline: HookPipeline(),
        credential: { _ in credential() }
    )
    try await coordinator.install(bundleID: mimoID, version: "1.0.0", bundlePath: bundle.url.path)
    _ = try await coordinator.enable(bundleID: mimoID, policy: .development, grantedPermissions: grants)
    let bindings = await coordinator.providerBindings(bundleID: mimoID)
    let binding = try #require(bindings.first)

    let recorder = MiMoEventRecorder()
    let router = ModelRouter()
    await router.register(
        provider: MiMoTeeProvider(inner: binding.adapter, recorder: recorder),
        id: ProviderID(binding.declaration.id),
        models: binding.declaration.models.map { ModelID($0) }
    )
    let tools = ToolRegistry()
    try await tools.register(ToolDescriptor(
        id: "test/echo", name: "echo",
        schemaJSON: "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}}}",
        effect: .readOnly
    ))
    let executor = MiMoEchoExecutor()
    let loop = AgentLoop(
        router: router, toolRegistry: tools, executor: executor,
        log: try DurableEventLog(sink: InMemorySink()),
        runs: RunRegistry(), store: SessionStore(),
        instructions: "You are a test assistant."
    )
    return MiMoHarness(loop: loop, coordinator: coordinator, recorder: recorder, executor: executor)
}

private func mimoRequest(turn: Int, prompt: String, model: String = "mimo-v2.6-flash") -> RunRequest {
    RunRequest(
        sessionID: "session-mimo",
        turnID: TurnID("turn-\(turn)"),
        runID: RunID("run-mimo-\(turn)"),
        executionID: ExecutionID("exec-mimo-\(turn)"),
        model: ModelID(model),
        prompt: prompt
    )
}

@Test("MIMO a Chat Completions stream drives multi-turn text and a full tool loop offline")
func MIMO_cassetteDrivesMultiTurnAndToolLoop() async throws {
    let harness = try await makeMiMoHarness(
        grants: ["vcr=\(mimoFixtureURL.path)"], credential: { "offline-test-credential" }
    )
    defer { Task { await harness.coordinator.disable(bundleID: mimoID) } }

    let first = await harness.loop.run(mimoRequest(turn: 1, prompt: "Say hello"), policy: LoopPolicy())
    #expect(first.status == .completed)
    #expect(first.assistantText.contains("MiMo"))
    let deltas = harness.recorder.events.filter { if case .textDelta = $0 { true } else { false } }
    #expect(deltas.count >= 2)
    #expect(first.usage?.inputTokens == 11)

    harness.recorder.reset()
    let second = await harness.loop.run(mimoRequest(turn: 2, prompt: "Call the echo tool with value 42"), policy: LoopPolicy())
    #expect(second.status == .completed)
    #expect(second.steps == 2)
    #expect(second.toolOutcomes == 1)
    #expect(second.assistantText.contains("42"))
    #expect(harness.executor.executed.map(\.toolName) == ["echo"])
}

@Test("MIMO disabling the provider removes its model route and its host process")
func MIMO_disableRemovesProviderRoute() async throws {
    let harness = try await makeMiMoHarness(
        grants: ["vcr=\(mimoFixtureURL.path)"], credential: { "offline-test-credential" }
    )
    #expect(await harness.coordinator.isRunning(bundleID: mimoID))
    let pid = try #require(await harness.coordinator.processIdentifier(bundleID: mimoID))
    await harness.coordinator.disable(bundleID: mimoID)
    #expect(await harness.coordinator.isRunning(bundleID: mimoID) == false)
    #expect(await waitUntil { kill(pid, 0) != 0 })
}

@Test("LOOP-023 a MiMo provider stream is cancelled at the deadline without leaving a host")
func MIMO_providerStreamCancellation() async throws {
    let harness = try await makeMiMoHarness(
        grants: ["vcr=\(mimoFixtureURL.path)", "fault.slow"], credential: { "offline-test-credential" }
    )
    let pid = try #require(await harness.coordinator.processIdentifier(bundleID: mimoID))
    let result = await harness.loop.run(
        mimoRequest(turn: 1, prompt: "Say hello"),
        policy: LoopPolicy(overallTimeout: .milliseconds(150))
    )
    #expect(result.status == .deadlineExceeded)
    #expect(await harness.coordinator.isRunning(bundleID: mimoID))
    await harness.coordinator.disable(bundleID: mimoID)
    #expect(await waitUntil { kill(pid, 0) != 0 })
}

@Test("MIMO replay with recording enabled writes a real cassette file")
func MIMO_recordingWritesCassette() async throws {
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimo-record-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: output) }
    let harness = try await makeMiMoHarness(
        grants: ["vcr=\(mimoFixtureURL.path)", "record=\(output.path)"],
        credential: { "offline-test-credential" }
    )
    defer { Task { await harness.coordinator.disable(bundleID: mimoID) } }

    #expect((await harness.loop.run(mimoRequest(turn: 1, prompt: "Say hello"), policy: LoopPolicy())).status == .completed)
    let data = try Data(contentsOf: output)
    let cassette = try JSONDecoder().decode(RecordedMiMoCassette.self, from: data)
    #expect(cassette.provider == "mimo")
    #expect(cassette.exchanges.count == 1)
    #expect(cassette.exchanges[0].events.contains { $0.type == "completed" })
}

@Test("MIMO live smoke and optional cassette recording", .enabled(
    if: ProcessInfo.processInfo.environment["LINGXI_RUN_REAL_PROVIDER_SMOKE"] == "1"
))
func MIMO_liveSmoke() async throws {
    let key = try #require(ProcessInfo.processInfo.environment["MIMO_API_KEY"])
    let model = ProcessInfo.processInfo.environment["LINGXI_MIMO_MODEL"] ?? "mimo-v2.6-flash"
    var grants: [String] = []
    if let record = ProcessInfo.processInfo.environment["LINGXI_RECORD_MIMO_CASSETTE"] {
        grants.append("record=\(record)")
    }
    let harness = try await makeMiMoHarness(grants: grants, model: model, credential: { key })
    defer { Task { await harness.coordinator.disable(bundleID: mimoID) } }

    let first = await harness.loop.run(mimoRequest(turn: 1, prompt: "Reply with the single word: pong", model: model), policy: LoopPolicy())
    #expect(first.status == .completed, "live run failed: \(first.status) \(first.detail ?? "")")
    #expect(!first.assistantText.isEmpty)

    let tool = await harness.loop.run(
        mimoRequest(turn: 2, prompt: "Call the echo tool with value 42, then say what it returned.", model: model),
        policy: LoopPolicy()
    )
    #expect(tool.status == .completed, "live tool run failed: \(tool.status) \(tool.detail ?? "")")
    #expect(tool.toolOutcomes == 1, "the model did not complete the echo tool call: \(tool.assistantText)")

    let followUp = await harness.loop.run(
        mimoRequest(turn: 3, prompt: "In one sentence, what did the tool return?", model: model),
        policy: LoopPolicy()
    )
    #expect(followUp.status == .completed)
    #expect(!followUp.assistantText.isEmpty)
}
