import Foundation
import LingXiKernel
import LingXiPluginABI
import LingXiPluginRuntime
import Testing

private let deepSeekID = "site.lingxi.provider.deepseek"

private struct RecordedDeepSeekCassette: Decodable {
    let provider: String
    let exchanges: [Exchange]
    struct Exchange: Decodable { let events: [ProviderWireEvent] }
}
private let fixtureURL: URL = Bundle.module.url(forResource: "deepseek-responses-fixture", withExtension: "json", subdirectory: "Fixtures")!

private final class ModelEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ModelEvent] = []
    func append(_ event: ModelEvent) { lock.lock(); stored.append(event); lock.unlock() }
    var events: [ModelEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    func reset() { lock.lock(); stored.removeAll(); lock.unlock() }
}

private struct TeeProvider: ModelProvider {
    let inner: any ModelProvider
    let recorder: ModelEventRecorder

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

    func endExecution(_ executionID: ExecutionID) async {
        await inner.endExecution(executionID)
    }
}

private final class EchoExecutor: ToolExecutor, @unchecked Sendable {
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

private struct DeepSeekHarness {
    let loop: AgentLoop
    let coordinator: PluginCoordinator
    let recorder: ModelEventRecorder
    let executor: EchoExecutor
}

private func makeDeepSeekHarness(grants: [String], credential: @escaping @Sendable () -> String?) async throws -> DeepSeekHarness {
    let bundle = try makeBundle(
        bundleID: deepSeekID,
        executableName: "DeepSeekProvider",
        dylib: builtProduct("libDeepSeekProvider.dylib"),
        capabilities: ["provider.deepseek"]
    )
    let registry = try PluginRegistry(configURL: nil)
    let coordinator = PluginCoordinator(
        hostExecutableURL: builtProduct("LingXiPluginHost"),
        registry: registry,
        pipeline: HookPipeline(),
        credential: { _, _ in credential() }
    )
    try await coordinator.install(bundleID: deepSeekID, version: "1.0.0", bundlePath: bundle.url.path)
    _ = try await coordinator.enable(
        bundleID: deepSeekID, policy: .development, grantedPermissions: grants
    )
    let bindings = await coordinator.providerBindings(bundleID: deepSeekID)
    let binding = try #require(bindings.first)

    let recorder = ModelEventRecorder()
    let router = ModelRouter()
    try await router.register(
        provider: TeeProvider(inner: binding.adapter, recorder: recorder),
        id: ProviderID(binding.declaration.id),
        models: binding.declaration.models.map { ModelID($0) }
    )
    let tools = ToolRegistry()
    try await tools.register(ToolDescriptor(
        id: "test/echo", name: "echo", schemaJSON: "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}}}",
        effect: .readOnly
    ))
    let executor = EchoExecutor()
    let loop = AgentLoop(
        router: router, toolRegistry: tools, executor: executor,
        log: try DurableEventLog(sink: InMemorySink()),
        runs: RunRegistry(), store: SessionStore(),
        instructions: "You are a test assistant."
    )
    return DeepSeekHarness(loop: loop, coordinator: coordinator, recorder: recorder, executor: executor)
}

private func deepSeekRequest(turn: Int, prompt: String) -> RunRequest {
    RunRequest(
        sessionID: "session-deepseek",
        turnID: TurnID("turn-\(turn)"),
        runID: RunID("run-deepseek-\(turn)"),
        executionID: ExecutionID("exec-deepseek-\(turn)"),
        model: "deepseek-flash",
        prompt: prompt
    )
}

@Test("DEEPSEEK a recorded stream drives multi-turn text and one full tool loop offline")
func DEEPSEEK_cassetteDrivesMultiTurnAndToolLoop() async throws {
    let harness = try await makeDeepSeekHarness(
        grants: ["vcr=\(fixtureURL.path)"], credential: { "offline-test-credential" }
    )
    defer { Task { try? await harness.coordinator.disable(bundleID: deepSeekID) } }

    // Turn 1: streamed text. More than one delta proves events arrived as a stream, not one blob.
    let first = await harness.loop.run(
        deepSeekRequest(turn: 1, prompt: "Say hello"), policy: LoopPolicy()
    )
    #expect(first.status == .completed)
    #expect(first.assistantText.contains("DeepSeek"))
    let textDeltas = harness.recorder.events.filter {
        if case .textDelta = $0 { return true } else { return false }
    }
    #expect(textDeltas.count >= 2)
    #expect(first.usage?.inputTokens == 12)

    // Turn 2: the cassette calls the echo tool, the loop executes it, then a second model request
    // returns the final answer. This is the full tool round trip over the real process boundary.
    harness.recorder.reset()
    let second = await harness.loop.run(
        deepSeekRequest(turn: 2, prompt: "Call the echo tool with value 42"), policy: LoopPolicy()
    )
    #expect(second.status == .completed)
    #expect(second.steps == 2)
    #expect(second.toolOutcomes == 1)
    #expect(second.assistantText.contains("42"))
    #expect(harness.executor.executed.map(\.toolName) == ["echo"])
    #expect(harness.executor.executed.first?.argumentsJSON.contains("42") == true)
}

@Test("LOOP-023 a provider stream is cancelled at the deadline and leaves no host behind")
func DEEPSEEK_providerStreamCancellation() async throws {
    let harness = try await makeDeepSeekHarness(
        grants: ["vcr=\(fixtureURL.path)", "fault.slow"], credential: { "offline-test-credential" }
    )
    let pid = try #require(await harness.coordinator.processIdentifier(bundleID: deepSeekID))

    // The fixture takes ~300ms when every event is slowed; a 150ms budget must cut it short.
    let result = await harness.loop.run(
        deepSeekRequest(turn: 1, prompt: "Say hello"),
        policy: LoopPolicy(overallTimeout: .milliseconds(150))
    )
    #expect(result.status == .deadlineExceeded)
    #expect(result.cause == .deadlineExceeded)

    // The host survived the cancellation and still answers, then shuts down cleanly.
    #expect(await harness.coordinator.isRunning(bundleID: deepSeekID))
    try await harness.coordinator.disable(bundleID: deepSeekID)
    #expect(await waitUntil { kill(pid, 0) != 0 })
}

@Test("DEEPSEEK disabling the provider removes its model route and its host process")
func DEEPSEEK_disableRemovesProviderRoute() async throws {
    let harness = try await makeDeepSeekHarness(
        grants: ["vcr=\(fixtureURL.path)"], credential: { "offline-test-credential" }
    )
    #expect(await harness.coordinator.isRunning(bundleID: deepSeekID))
    let pid = try #require(await harness.coordinator.processIdentifier(bundleID: deepSeekID))
    try await harness.coordinator.disable(bundleID: deepSeekID)
    #expect(await harness.coordinator.isRunning(bundleID: deepSeekID) == false)
    #expect(await waitUntil { kill(pid, 0) != 0 })
}

@Test("DEEPSEEK replay with recording enabled writes a real cassette file")
func DEEPSEEK_recordingWritesCassette() async throws {
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent("deepseek-record-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: output) }
    let harness = try await makeDeepSeekHarness(
        grants: ["vcr=\(fixtureURL.path)", "record=\(output.path)"],
        credential: { "offline-test-credential" }
    )
    defer { Task { try? await harness.coordinator.disable(bundleID: deepSeekID) } }

    #expect((await harness.loop.run(deepSeekRequest(turn: 1, prompt: "Say hello"), policy: LoopPolicy())).status == .completed)
    let data = try Data(contentsOf: output)
    #expect(!String(decoding: data, as: UTF8.self).contains("offline-test-credential"))
    let cassette = try JSONDecoder().decode(RecordedDeepSeekCassette.self, from: data)
    #expect(cassette.provider == "deepseek")
    #expect(cassette.exchanges.count == 1)
    #expect(cassette.exchanges[0].events.contains { $0.type == "completed" })
}

// MARK: - real API (owner-run; never in CI)

@Test("DEEPSEEK live Responses API smoke and optional cassette recording", .enabled(
    if: ProcessInfo.processInfo.environment["LINGXI_RUN_REAL_PROVIDER_SMOKE"] == "1"
))
func DEEPSEEK_liveSmoke() async throws {
    let key = try #require(ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"])
    var grants: [String] = []
    if let record = ProcessInfo.processInfo.environment["LINGXI_RECORD_DEEPSEEK_CASSETTE"] {
        grants.append("record=\(record)")
    }
    let harness = try await makeDeepSeekHarness(grants: grants, credential: { key })
    defer { Task { try? await harness.coordinator.disable(bundleID: deepSeekID) } }

    let first = await harness.loop.run(
        deepSeekRequest(turn: 1, prompt: "Reply with the single word: pong"), policy: LoopPolicy()
    )
    #expect(first.status == .completed, "live run failed: \(first.status) \(first.detail ?? "")")
    #expect(!first.assistantText.isEmpty)

    let tool = await harness.loop.run(
        deepSeekRequest(turn: 2, prompt: "Call the echo tool with value 42, then say what it returned."),
        policy: LoopPolicy()
    )
    #expect(tool.status == .completed, "live tool run failed: \(tool.status) \(tool.detail ?? "")")
    #expect(tool.toolOutcomes == 1, "the model did not complete the echo tool call: \(tool.assistantText)")

    let followUp = await harness.loop.run(
        deepSeekRequest(turn: 3, prompt: "In one sentence, what did the tool return?"), policy: LoopPolicy()
    )
    #expect(followUp.status == .completed)
    #expect(!followUp.assistantText.isEmpty)
}
