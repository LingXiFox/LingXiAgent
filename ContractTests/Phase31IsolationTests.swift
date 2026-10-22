import Darwin
import Foundation
import LingXiKernel
import LingXiPluginABI
import LingXiPluginRuntime
import Testing

private let mimoBundle = "site.lingxi.provider.mimo"
private let deepSeekBundle = "site.lingxi.provider.deepseek"
private let mimoLive: URL = Bundle.module.url(
    forResource: "mimo-chat-live", withExtension: "json", subdirectory: "Fixtures"
)!
private let deepSeekFixture: URL = Bundle.module.url(
    forResource: "deepseek-responses-fixture", withExtension: "json", subdirectory: "Fixtures"
)!

private struct StubProvider: ModelProvider {
    let capabilities = ModelCapabilities(
        supportsReasoning: false, supportsParallelToolCalls: false, toolResultPlacement: .anywhereInHistory
    )
    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func endExecution(_ executionID: ExecutionID) async {}
}

private final class RouteEchoExecutor: ToolExecutor, @unchecked Sendable {
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

private struct DualHarness {
    let coordinator: PluginCoordinator
    let registry: PluginRegistry
    let router: ModelRouter
    let loop: AgentLoop
}

private func installProviderBundles(_ coordinator: PluginCoordinator) async throws {
    let mimo = try makeBundle(
        bundleID: mimoBundle, executableName: "MiMoProvider",
        dylib: builtProduct("libMiMoProvider.dylib"), capabilities: ["provider.mimo", "settings.view.v1"]
    )
    let deepseek = try makeBundle(
        bundleID: deepSeekBundle, executableName: "DeepSeekProvider",
        dylib: builtProduct("libDeepSeekProvider.dylib"), capabilities: ["provider.deepseek"]
    )
    try await coordinator.install(bundleID: mimoBundle, version: "1.0.0", bundlePath: mimo.url.path)
    try await coordinator.install(bundleID: deepSeekBundle, version: "1.0.0", bundlePath: deepseek.url.path)
}

private func makeDualHarness(
    registryURL: URL? = nil,
    mimoGrants: [String] = ["vcr=\(mimoLive.path)"],
    deepSeekGrants: [String] = ["vcr=\(deepSeekFixture.path)"],
    enableDeepSeek: Bool = true
) async throws -> DualHarness {
    let registry = try PluginRegistry(configURL: registryURL)
    let router = ModelRouter()
    let pipeline = HookPipeline()
    let coordinator = PluginCoordinator(
        hostExecutableURL: builtProduct("LingXiPluginHost"),
        registry: registry, pipeline: pipeline, router: router,
        credential: { _, _ in "offline-test-credential" }
    )
    try await installProviderBundles(coordinator)
    _ = try await coordinator.enable(bundleID: mimoBundle, policy: .development, grantedPermissions: mimoGrants)
    if enableDeepSeek {
        _ = try await coordinator.enable(bundleID: deepSeekBundle, policy: .development, grantedPermissions: deepSeekGrants)
    }
    let tools = ToolRegistry()
    try await tools.register(ToolDescriptor(
        id: "test/echo", name: "echo",
        schemaJSON: "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}}}",
        effect: .readOnly
    ))
    let loop = AgentLoop(
        router: router, toolRegistry: tools, executor: RouteEchoExecutor(),
        log: try DurableEventLog(sink: InMemorySink()),
        runs: RunRegistry(), store: SessionStore(),
        instructions: "You are a test assistant."
    )
    return DualHarness(coordinator: coordinator, registry: registry, router: router, loop: loop)
}

private func providerTurn(_ session: String, turn: Int, model: String, prompt: String) -> RunRequest {
    RunRequest(
        sessionID: SessionID(session),
        turnID: TurnID("turn-\(turn)"),
        runID: RunID("run-\(session)-\(turn)"),
        executionID: ExecutionID("exec-\(session)-\(turn)"),
        model: ModelID(model),
        prompt: prompt
    )
}

private func mimoTurn(_ session: String, turn: Int = 1) -> RunRequest {
    providerTurn(session, turn: turn, model: "mimo-v2.6-flash", prompt: "Reply with the single word: pong")
}

private func deepSeekTurn(_ session: String, turn: Int = 1) -> RunRequest {
    providerTurn(session, turn: turn, model: "deepseek-flash", prompt: "Say hello")
}

@Test("PLG-001 MiMo and DeepSeek load together and each serves a request through its own host")
func PLG_001_twoProvidersServeIndependently() async throws {
    let harness = try await makeDualHarness()
    defer { Task { await harness.coordinator.shutdown() } }

    #expect(await harness.router.offeredModels.map(\.rawValue).sorted()
        == ["deepseek-flash", "mimo-v2.6-flash", "mimo-v2.6-pro"])
    #expect(await harness.router.providerIDs().map(\.rawValue) == ["deepseek", "mimo"])
    #expect(await harness.coordinator.runningBundleIDs() == [deepSeekBundle, mimoBundle].sorted())

    let mimo = await harness.loop.run(mimoTurn("dual-mimo"), policy: LoopPolicy())
    #expect(mimo.status == .completed)
    #expect(mimo.assistantText.lowercased().contains("pong"))

    let deepseek = await harness.loop.run(deepSeekTurn("dual-deepseek"), policy: LoopPolicy())
    #expect(deepseek.status == .completed)
    #expect(deepseek.assistantText.contains("DeepSeek"))
}

@Test("PLG-002 disabling MiMo removes only its routes; DeepSeek keeps serving and can be re-enabled")
func PLG_002_disableRevokesOnlyOwnedRoutes() async throws {
    let harness = try await makeDualHarness()
    defer { Task { await harness.coordinator.shutdown() } }

    let deepSeekPID = try #require(await harness.coordinator.processIdentifier(bundleID: deepSeekBundle))
    let mimoPID = try #require(await harness.coordinator.processIdentifier(bundleID: mimoBundle))

    try await harness.coordinator.disable(bundleID: mimoBundle)

    // Model routes, not just the process: MiMo is gone, DeepSeek is untouched.
    let models = await harness.router.offeredModels.map(\.rawValue).sorted()
    #expect(models == ["deepseek-flash"])
    var mimoResolutionFailed = false
    do { _ = try await harness.router.resolve(model: "mimo-v2.6-flash") } catch { mimoResolutionFailed = true }
    #expect(mimoResolutionFailed)
    let deepSeekProvider = try await harness.router.resolve(model: "deepseek-flash")
    #expect(deepSeekProvider is PluginProviderAdapter)

    #expect(await waitUntil { kill(mimoPID, 0) != 0 })
    #expect(await harness.coordinator.processIdentifier(bundleID: deepSeekBundle) == deepSeekPID)
    #expect(await harness.coordinator.isRunning(bundleID: deepSeekBundle))

    // A new DeepSeek run still completes after the other provider is gone.
    let continued = await harness.loop.run(deepSeekTurn("after-disable"), policy: LoopPolicy())
    #expect(continued.status == .completed)

    // A run aimed at the disabled model is refused before reaching any plugin.
    let refused = await harness.loop.run(mimoTurn("after-disable"), policy: LoopPolicy())
    #expect(refused.status == .failed)
    #expect(refused.cause == .runtimeFailure)
    #expect(refused.detail?.contains("No active provider offers model") == true)

    // Re-enable without restarting anything: a fresh host, the same routes.
    _ = try await harness.coordinator.enable(bundleID: mimoBundle, policy: .development, grantedPermissions: ["vcr=\(mimoLive.path)"])
    #expect(await harness.router.offeredModels.map(\.rawValue).sorted()
        == ["deepseek-flash", "mimo-v2.6-flash", "mimo-v2.6-pro"])
    let restored = await harness.loop.run(mimoTurn("after-reenable"), policy: LoopPolicy())
    #expect(restored.status == .completed)
    #expect(restored.assistantText.lowercased().contains("pong"))

    // Uninstall also revokes, and only the owner's routes.
    try await harness.coordinator.uninstall(bundleID: mimoBundle)
    #expect(await harness.router.offeredModels.map(\.rawValue).sorted() == ["deepseek-flash"])
    #expect(await harness.registry.entry(mimoBundle) == nil)
    #expect(await harness.coordinator.isRunning(bundleID: deepSeekBundle))
}

@Test("PLG-011 duplicate providers and model ids are refused without damaging existing routes")
func PLG_011_registrationConflicts() async throws {
    let router = ModelRouter()
    try await router.register(provider: StubProvider(), id: ProviderID("provider-a"), models: ["model-1"])
    try await router.register(provider: StubProvider(), id: ProviderID("provider-b"), models: ["model-2"])

    await #expect(throws: ModelRouterError.duplicateModel(ModelID("model-2"), existing: ProviderID("provider-b"))) {
        try await router.register(provider: StubProvider(), id: ProviderID("provider-c"), models: ["model-3", "model-2"])
    }
    // Atomic: the conflicting registration installed nothing.
    #expect(await router.offeredModels.map(\.rawValue).sorted() == ["model-1", "model-2"])
    #expect(await router.models(providerID: ProviderID("provider-c")).isEmpty)

    await #expect(throws: ModelRouterError.duplicateProvider(ProviderID("provider-a"))) {
        try await router.register(provider: StubProvider(), id: ProviderID("provider-a"), models: ["model-9"])
    }
    #expect(await router.offeredModels.map(\.rawValue).sorted() == ["model-1", "model-2"])

    // Unregistering removes exactly one owner's routes.
    #expect(await router.unregister(providerID: ProviderID("provider-a")) == ["model-1"])
    #expect(await router.offeredModels.map(\.rawValue) == ["model-2"])
    #expect(try await router.resolve(model: "model-2") is StubProvider)
}

@Test("STORE-010 a registry write failure rolls the whole enable back")
func STORE_010_registryWriteFailureRollsBackEnable() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("isolation-registry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    let configURL = directory.appendingPathComponent("plugins.json")

    let harness = try await makeDualHarness(
        registryURL: configURL, mimoGrants: ["vcr=\(mimoLive.path)"], enableDeepSeek: false
    )
    defer { Task { await harness.coordinator.shutdown() } }

    // Remove MiMo so the enable below is a fresh attempt, then make the registry unwritable.
    try await harness.coordinator.disable(bundleID: mimoBundle)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

    var failure: String?
    do {
        _ = try await harness.coordinator.enable(
            bundleID: mimoBundle, policy: .development, grantedPermissions: ["vcr=\(mimoLive.path)"]
        )
    } catch {
        failure = "\(error)"
    }
    #expect(failure != nil, "enable should fail when the registry cannot be written")
    // Nothing was left installed: no routes, no host, and the registry did not claim enabled.
    #expect(await harness.router.offeredModels.isEmpty)
    #expect(await harness.coordinator.runningBundleIDs().isEmpty)
    #expect(await harness.registry.entry(mimoBundle)?.enabled == false)
}

@Test("PLG-018 force-killing a provider host cleans only that provider's routes and registry state")
func PLG_018_forceKilledProviderIsScoped() async throws {
    let harness = try await makeDualHarness()
    defer { Task { await harness.coordinator.shutdown() } }

    let deepSeekPID = try #require(await harness.coordinator.processIdentifier(bundleID: deepSeekBundle))
    let mimoPID = try #require(await harness.coordinator.processIdentifier(bundleID: mimoBundle))

    kill(mimoPID, SIGKILL)

    #expect(await waitUntil { await harness.coordinator.isRunning(bundleID: mimoBundle) == false })
    #expect(await waitUntil { await harness.router.offeredModels.map(\.rawValue).sorted() == ["deepseek-flash"] })
    #expect(await harness.coordinator.isRunning(bundleID: deepSeekBundle))
    #expect(await harness.coordinator.processIdentifier(bundleID: deepSeekBundle) == deepSeekPID)
    // The unexpected-exit handler persists enabled=false asynchronously after teardown; poll it
    // instead of racing the registry write.
    #expect(await waitUntil { await harness.registry.entry(mimoBundle)?.enabled == false })

    let continued = await harness.loop.run(deepSeekTurn("after-kill"), policy: LoopPolicy())
    #expect(continued.status == .completed)

    // The crashed plugin can be re-enabled; the survivor never needed a restart.
    _ = try await harness.coordinator.enable(bundleID: mimoBundle, policy: .development, grantedPermissions: ["vcr=\(mimoLive.path)"])
    #expect(await harness.loop.run(mimoTurn("after-kill-reenable"), policy: LoopPolicy()).status == .completed)
}

@Test("LOOP-023 disabling during an in-flight provider request cancels it and leaves no ghost route")
func LOOP_023_disableDuringInFlightProviderRequest() async throws {
    let harness = try await makeDualHarness(
        mimoGrants: ["vcr=\(mimoLive.path)", "fault.slow"]
    )
    defer { Task { await harness.coordinator.shutdown() } }

    let binding = try #require(await harness.coordinator.providerBindings(bundleID: mimoBundle).first)
    let mimoPID = try #require(await harness.coordinator.processIdentifier(bundleID: mimoBundle))
    let deepSeekPID = try #require(await harness.coordinator.processIdentifier(bundleID: deepSeekBundle))

    let run = Task {
        await harness.loop.run(mimoTurn("in-flight"), policy: LoopPolicy(overallTimeout: .seconds(30)))
    }
    #expect(await waitUntil(timeout: .seconds(30)) { binding.adapter.inFlightRequestCount > 0 })

    try await harness.coordinator.disable(bundleID: mimoBundle)
    let outcome = await run.value
    #expect(outcome.status == .failed)

    // No ghost route, no process, and the surviving provider is untouched.
    #expect(await harness.router.offeredModels.map(\.rawValue).sorted() == ["deepseek-flash"])
    #expect(await waitUntil { kill(mimoPID, 0) != 0 })
    #expect(await harness.coordinator.processIdentifier(bundleID: deepSeekBundle) == deepSeekPID)

    let late = await harness.loop.run(mimoTurn("late"), policy: LoopPolicy())
    #expect(late.status == .failed)
    #expect(late.detail?.contains("No active provider offers model") == true)
    #expect(await harness.loop.run(deepSeekTurn("during-disable"), policy: LoopPolicy()).status == .completed)

    // Re-enable and run: the new stream is clean, not contaminated by the cancelled one.
    _ = try await harness.coordinator.enable(bundleID: mimoBundle, policy: .development, grantedPermissions: ["vcr=\(mimoLive.path)"])
    let fresh = await harness.loop.run(mimoTurn("fresh-after-cancel"), policy: LoopPolicy())
    #expect(fresh.status == .completed)
    #expect(fresh.assistantText.lowercased() == "pong")
}
