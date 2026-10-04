import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import LingXiProtocol
import LingXiClient
import LingXiApplication
@testable import LingXiCore

@Suite("Runtime context policy generation", .serialized)
struct RuntimeContextPolicyRefreshTests {
    private static let model = "qwen3.8-9b-q6k"
    private static let selection = ModelSelection(providerID: "lmstudio", modelID: model)

    private actor NativeRuntime {
        var window: Int?
        var calls = 0
        init(_ window: Int?) { self.window = window }
        func setWindow(_ window: Int?) { self.window = window }
        func request(_ request: URLRequest) throws -> (Data, URLResponse) {
            calls += 1
            guard let window else { throw URLError(.cannotConnectToHost) }
            let body = LMStudioRuntimeTests.nativeJSON.replacingOccurrences(of: "65536", with: String(window))
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                    httpVersion: nil, headerFields: nil)!)
        }
    }

    private struct Fixture {
        let root: URL
        let host: CoreHost
        let store: ConfigurationStore
        let sessions: InMemorySessionStore
        let native: NativeRuntime
        let provider: ScriptedFakeProvider
        func shutdown() async {
            await host.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture(window: Int, nativeWindow: Int? = nil, local: Bool = false,
                         source: String = "test-runtime") async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-runtime-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try ConfigurationStore(dataRoot: root.appendingPathComponent("data"))
        let providerID = local ? "lmstudio" : "cloud-test"
        let native = NativeRuntime(nativeWindow)
        let options = PublicProviderOptions(baseURL: "http://runtime-policy.test:1234/v1",
                                            localRuntime: local ? LocalRuntimeOptions(backend: .lmStudio) : nil)
        try await store.saveProviders(ProvidersConfiguration(providers: [providerID: PublicProviderConfiguration(
            name: "Runtime policy test", options: options,
            models: [Self.model: PublicModelConfiguration(name: "test", limit: PublicModelLimit(context: 262_144))])]))
        let sessions = InMemorySessionStore()
        let provider = ScriptedFakeProvider(script: [[.textDelta("ok"), .completed(.stop)]])
        let assembly = assembly(window, providerID: providerID, provider: provider, source: source)
        let host = try CoreHost(startupPolicy: .unitTest, providerAssembly: assembly,
            sessionStore: sessions, workspaceRoot: WorkspaceRoot(path: root.path), dataRoot: root.appendingPathComponent("data"),
            permissionDecision: .allow, configurationStore: store,
            localRuntimeHTTPClient: { try await native.request($0) })
        return Fixture(root: root, host: host, store: store, sessions: sessions, native: native, provider: provider)
    }

    private func assembly(_ window: Int, providerID: String = "lmstudio", provider: any ModelProvider = ObservatoryFakeProvider(),
                          source: String = "lmstudio-runtime:lmstudio/qwen3.8-9b-q6k") -> ModelRuntimeAssembly {
        ModelRuntimeAssembly(provider: provider, modelID: ModelID(Self.model), endpoint: ResolvedModelEndpoint(
            providerID: providerID, modelID: ModelID(Self.model), baseURL: URL(string: "http://runtime-policy.test:1234/v1"),
            wireProtocol: .chatCompletions, contextProfile: ModelContextProfile(contextWindowTokens: window, source: source)))
    }

    private func assertGeneration(_ host: CoreHost, window: Int) async {
        let generation = await host.runtimeContextSnapshot
        let controller = await host.cacheController
        #expect(generation.assembly?.contextProfile.contextWindowTokens == window)
        #expect(generation.policy.modelWindow == window)
        #expect(await host.effectiveContextPolicy == generation.policy)
        #expect(controller.policy == generation.policy)
        #expect(controller.runtimeContext.snapshot().generation == generation.generation)
        #expect(generation.policy.pCoreTarget <= generation.policy.pCoreSoftLimit)
        #expect(generation.policy.pCoreSoftLimit <= generation.policy.pCoreHardLimit)
        #expect(generation.policy.pCoreHardLimit + generation.policy.reserve <= window)
    }

    @Test("Concurrent session attachment shares the policy event coordinator")
    func concurrentPolicyCoordinator() async throws {
        let f = try await fixture(window: 65_536)
        defer { await f.shutdown() }
        let sid = try await f.sessions.create().id
        let coordinators = try await withThrowingTaskGroup(of: SessionTurnCoordinator.self) { group in
            for _ in 0..<20 { group.addTask { try await f.host.coordinator(for: sid) } }
            var values: [SessionTurnCoordinator] = []
            for try await value in group { values.append(value) }
            return values
        }
        let first = try #require(coordinators.first)
        #expect(coordinators.allSatisfy { $0 === first })
        try await f.host.applyModelRuntimeContextChange(assembly(32_768), selection: Self.selection)
        let published = await first.eventLog.allEvents().compactMap { event -> ContextStateSnapshot? in
            if case let .contextStateChanged(snapshot) = event.payload { return snapshot }
            return nil
        }
        let state = try #require(published.last)
        #expect(state.pCore?.targetTokens == (await f.host.effectiveContextPolicy).pCoreTarget)
        #expect(state.pCore?.hardLimitTokens == (await f.host.effectiveContextPolicy).pCoreHardLimit)
    }

    @Test("initial policies use the injected active window", arguments: [131_072, 65_536, 32_768])
    func initialWindow(_ window: Int) async throws {
        let f = try await fixture(window: window)
        defer { await f.shutdown() }
        await assertGeneration(f.host, window: window)
    }

    @Test("native 128K to 64K to 32K to 64K refresh publishes one policy; unchanged refresh preserves prefix")
    func nativeGenerationAndPrefix() async throws {
        let f = try await fixture(window: 131_072, nativeWindow: 131_072, local: true)
        defer { await f.shutdown() }
        await f.host.start()
        let client = try await LingXiClientVNext.inProcess(service: f.host)
        let controller = await f.host.cacheController
        let sessionID = SessionID("prefix-refresh")
        let fingerprint = PrefixFingerprint(systemHash: "system", coreToolsHash: "tools", leasedToolsHash: "leased",
                                            requestProfileHash: "model-reasoning", stablePrefixHash: "stable-prefix")
        await controller.recordFingerprint(sessionID: sessionID, fingerprint: fingerprint, canonicalStablePrefix: "immutable prefix")
        await controller.recordProviderCacheHit(sessionID: sessionID, cachedTokens: 100, promptTokens: 150)
        let health = await controller.lastClientHealth(for: sessionID)
        let cache = await controller.lastProviderCacheRecord(for: sessionID)
        for window in [65_536, 32_768, 65_536] {
            await f.native.setWindow(window)
            await f.host.refreshLocalRuntimeIfStale(maxAge: -1)
            await assertGeneration(f.host, window: window)
            let generation = await f.host.runtimeContextSnapshot.generation
            _ = try await client.model.select(model: "lmstudio/\(Self.model)")
            await assertGeneration(f.host, window: window)
            #expect(await f.host.runtimeContextSnapshot.generation == generation)
            #expect(await controller.lastClientHealth(for: sessionID) == health)
            #expect(await controller.lastProviderCacheRecord(for: sessionID) == cache)
        }
        let before = await f.host.runtimeContextSnapshot
        let stats = await controller.pagingStats(for: sessionID)
        await f.host.refreshLocalRuntimeIfStale(maxAge: -1)
        #expect(await f.host.runtimeContextSnapshot.generation == before.generation)
        #expect(controller.policy == before.policy)
        #expect(await controller.lastClientHealth(for: sessionID) == health)
        #expect(await controller.lastProviderCacheRecord(for: sessionID) == cache)
        #expect(await controller.pagingStats(for: sessionID) == stats)
        let native = try #require(await f.host.localRuntimeRegistry.status(providerID: "lmstudio"))
        #expect(native.modelMaxContextTokens == 262_144)
        #expect(native.runtimeContextTokens == 65_536)
    }

    @Test("context meter uses measured active input rather than retained historical estimates")
    func activeContextMeter() async throws {
        let f = try await fixture(window: 65_536)
        defer { await f.shutdown() }
        let controller = await f.host.cacheController
        let sid = SessionID("restored-context-meter")
        await controller.recordPCoreBaseTokens(sessionID: sid, tokens: 131_072)
        await controller.recordProviderCacheHit(sessionID: sid, cachedTokens: 0, promptTokens: 17_733)
        let object = await controller.ecoreStore.pageOut(sessionID: sid,
            content: String(repeating: "archived history ", count: 8_000), origin: .message,
            contextOccurrenceID: "meter-object", evictionEpoch: 1, summary: "history", pageOutReason: "test")
        let before = await controller.ecoreStore.storageMetrics(for: sid)
        let state = await f.host.contextStateSnapshot(sessionID: sid)
        #expect(state.estimatedTokens == 17_733)
        #expect(state.estimatedTokens == state.pCore?.usedTokens)
        #expect(state.providerCache?.promptTokens == state.estimatedTokens)
        #expect(state.eCore?.objectCount == before.count)
        #expect(state.eCore?.totalBytes == before.totalBytes)
        #expect(await controller.ecoreStore.reference(sessionID: sid, referenceID: object.referenceID) != nil)
        #expect(await controller.pCoreResidentTokens(for: sid) == 131_072)
        await assertGeneration(f.host, window: 65_536)
    }

    @Test("controller updates preserve resident pages and E-Core objects; growth does not page in")
    func controllerResidency() async throws {
        let f = try await fixture(window: 65_536)
        defer { await f.shutdown() }
        let controller = ContextCacheController(contextPager: ContextPager(store: ProjectPageStore(), workingSet: RecallWorkingSet()),
            scanner: ProjectScanner(root: f.root), policy: try ContextPolicyResolver.resolve(modelWindow: 65_536))
        try "struct RuntimeBudgetFixture {}".write(to: f.root.appendingPathComponent("Budget.swift"), atomically: true, encoding: .utf8)
        let sid = SessionID("resident-policy")
        _ = try await controller.handleSearch(sessionID: sid, query: "RuntimeBudgetFixture")
        let object = await controller.ecoreStore.pageOut(sessionID: sid, content: "resident object", origin: .message,
            contextOccurrenceID: "policy-object", evictionEpoch: 1, summary: "object", pageOutReason: "test")
        let pages = await controller.residentPages(for: sid)
        let stats = await controller.pagingStats(for: sid)
        let storage = await controller.ecoreStore.storageMetrics(for: sid)
        let policy = try ContextPolicyResolver.resolve(modelWindow: 32_768)
        #expect(controller.updatePolicy(policy))
        #expect(!controller.updatePolicy(policy))
        #expect(controller.policy == policy)
        #expect(await controller.residentPages(for: sid) == pages)
        #expect(await controller.ecoreStore.storageMetrics(for: sid).count == storage.count)
        #expect(await controller.ecoreStore.reference(sessionID: sid, referenceID: object.referenceID) != nil)
        #expect(controller.updatePolicy(try ContextPolicyResolver.resolve(modelWindow: 65_536)))
        await controller.reconcilePolicyPressure()
        #expect(await controller.residentPages(for: sid) == pages)
        #expect(await controller.pagingStats(for: sid) == stats)
    }

    @Test("shrink safely pages history out via the existing compactor without deleting messages")
    func shrinkPressure() async throws {
        let f = try await fixture(window: 65_536, nativeWindow: 65_536, local: true)
        defer { await f.shutdown() }
        await f.host.start()
        let client = try await LingXiClientVNext.inProcess(service: f.host)
        let sid = try #require(try await client.session.create(workspace: f.root.path).result?.sessionID)
        for index in 0..<6 {
            _ = try await f.sessions.appendMessage(sid, role: .assistant,
                content: "Historical segment \(index): " + String(repeating: "persistent evidence ", count: 1_200))
        }
        _ = try await f.sessions.appendMessage(sid, role: .user, content: "Keep this current instruction.")
        let original = try await f.sessions.session(sid).messages
        let before = await f.host.contextStateSnapshot(sessionID: sid)
        #expect((before.pCore?.usedTokens ?? 0) > 32_768)
        await f.native.setWindow(32_768)
        await f.host.refreshLocalRuntimeIfStale(maxAge: -1)
        await assertGeneration(f.host, window: 32_768)
        let after = await f.host.contextStateSnapshot(sessionID: sid)
        #expect((after.pCore?.usedTokens ?? Int.max) <= (after.pCore?.hardLimitTokens ?? 0))
        #expect(after.compactionGeneration > before.compactionGeneration)
        #expect((after.eCore?.objectCount ?? 0) > 0)
        #expect(try await f.sessions.session(sid).messages == original)
        let stats = await f.host.cacheController.pagingStats(for: sid)
        await f.native.setWindow(65_536)
        await f.host.refreshLocalRuntimeIfStale(maxAge: -1)
        await assertGeneration(f.host, window: 65_536)
        #expect(await f.host.cacheController.pagingStats(for: sid) == stats)
        #expect(try await f.sessions.session(sid).messages == original)
    }

    @Test("unavailable discovery does not promote model maximum into an active runtime; recovery needs no Core restart")
    func unavailableAndRecovery() async throws {
        let f = try await fixture(window: 262_144, local: true)
        defer { await f.shutdown() }
        await f.host.start()
        #expect(await f.host.runtimeContextSnapshot.assembly == nil)
        await f.native.setWindow(65_536)
        await f.host.refreshLocalRuntimeIfStale(maxAge: -1)
        await assertGeneration(f.host, window: 65_536)
        let generation = await f.host.runtimeContextSnapshot.generation
        await f.native.setWindow(nil)
        await f.host.refreshLocalRuntimeIfStale(maxAge: -1)
        #expect(await f.host.runtimeContextSnapshot.generation == generation)
        await assertGeneration(f.host, window: 65_536)
    }

    @Test("cloud providers do not run native discovery or change their configured budgets")
    func cloudBehavior() async throws {
        let f = try await fixture(window: 131_072)
        defer { await f.shutdown() }
        await f.host.start()
        let generation = await f.host.runtimeContextSnapshot.generation
        await f.host.refreshLocalRuntimeIfStale(maxAge: -1)
        await assertGeneration(f.host, window: 131_072)
        #expect(await f.native.calls == 0)
        #expect(await f.host.runtimeContextSnapshot.generation == generation)
    }

    @Test("policy-only refresh preserves the actual provider request and stable prefix")
    func requestEquivalence() async throws {
        let f = try await fixture(window: 131_072)
        defer { await f.shutdown() }
        await f.host.start()
        let initial = try #require(await f.host.runtimeContextSnapshot.assembly)
        let controller = await f.host.cacheController
        let gateway = ModelGateway(assembly: initial, runtimeContext: controller.runtimeContext)
        let request = ModelRequest(model: initial.modelID, system: "stable prefix", messages: [ModelMessage(role: .user, content: "hello")],
            tools: [ToolDefinition(id: ToolID("write_file"), description: "Write a file", inputSchema: ToolInputSchema(properties: [:], required: []), capability: ToolCapability(readOnly: false))], reasoning: "on")
        for try await _ in try await gateway.stream(request) {}
        let updated = assembly(65_536, providerID: initial.endpoint.providerID, provider: f.provider)
        try await f.host.applyModelRuntimeContextChange(updated, selection: ModelSelection(providerID: initial.endpoint.providerID, modelID: Self.model))
        #expect(gateway.contextProfile.contextWindowTokens == 65_536)
        for try await _ in try await gateway.stream(request) {}
        #expect(f.provider.recorder.requests.count == 2)
        #expect(f.provider.recorder.requests.first == f.provider.recorder.requests.last)
    }

    @Test("latest global and model overrides are resolved together, even without a window change")
    func configurationInputs() async throws {
        let f = try await fixture(window: 65_536)
        defer { await f.shutdown() }
        await f.host.start()
        var configuration = try await f.store.load()
        configuration.core.context.reserve = 4_000
        configuration.core.context.economicThreshold = 80_000
        let override = ContextCacheConfiguration(reserve: 3_000, economicThreshold: 70_000,
            pCore: ContextCachePCoreConfiguration(target: 40_000, softLimit: 45_000, hardLimit: 50_000))
        configuration.providers.providers["cloud-test"]?.models[Self.model]?.context = override
        try await f.store.save(configuration)
        let current = try #require(await f.host.runtimeContextSnapshot.assembly)
        #expect(try await f.host.applyModelRuntimeContextChange(current, selection: ModelSelection(providerID: "cloud-test", modelID: Self.model)))
        let policy = await f.host.effectiveContextPolicy
        #expect(policy.reserve == 3_000)
        #expect(policy.economicThreshold == 70_000)
        #expect(policy.pCoreTarget == 40_000)
        #expect(policy.pCoreHardLimit == 50_000)
        #expect(!(try await f.host.applyModelRuntimeContextChange(current, selection: ModelSelection(providerID: "cloud-test", modelID: Self.model))))
    }

    @Test("a stale native generation cannot overwrite a newer model installation")
    func staleGeneration() async throws {
        let f = try await fixture(window: 131_072)
        defer { await f.shutdown() }
        await f.host.start()
        let generation = await f.host.runtimeContextSnapshot.generation
        let next = assembly(65_536, providerID: "cloud-test", provider: f.provider)
        let selection = ModelSelection(providerID: "cloud-test", modelID: Self.model)
        try await f.host.applyModelRuntimeContextChange(next, selection: selection)
        await #expect(throws: CoreError.self) {
            try await f.host.applyModelRuntimeContextChange(assembly(32_768, providerID: "cloud-test"),
                selection: selection, expectedGeneration: generation)
        }
        await assertGeneration(f.host, window: 65_536)
    }

    @Test("restarted Core projections outrank durable events from the previous policy")
    func durablePolicyProjection() async throws {
        let f = try await fixture(window: 131_072)
        defer { await f.shutdown() }
        await f.host.start()
        let client = try await LingXiClientVNext.inProcess(service: f.host)
        let sid = try #require(try await client.session.create(workspace: f.root.path).result?.sessionID)
        let coordinator = try await f.host.coordinator(for: sid)
        let current = await f.host.contextStateSnapshot(sessionID: sid)
        let old = ContextStateSnapshot(sessionID: sid, revision: 900, pCore: current.pCore,
            eCore: current.eCore, providerCache: current.providerCache,
            estimatedTokens: current.estimatedTokens, compactionGeneration: current.compactionGeneration)
        await coordinator.recordContextStateChanged(old, causal: CausalContext(sessionID: sid))
        await f.host.shutdown()
        let restarted = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: assembly(65_536, providerID: "cloud-test", provider: f.provider),
            sessionStore: f.sessions, workspaceRoot: WorkspaceRoot(path: f.root.path),
            dataRoot: f.root.appendingPathComponent("data"), configurationStore: f.store)
        defer { await restarted.shutdown() }
        await restarted.start()
        let response = try await restarted.getSessionSnapshot(envelope: QueryEnvelope(payload: GetSessionSnapshotRequest(sessionID: sid)))
        #expect(response.payload.contextState.revision > 900)
        var projected = SessionViewState(sessionID: sid)
        SessionReducer.reduceSnapshot(state: &projected, snapshot: response.payload,
            connectionState: ConnectionState(status: .connected))
        #expect(projected.contextState?.pCore?.targetTokens == 51_905)
        #expect(projected.contextState?.pCore?.hardLimitTokens == 58_983)
    }

    @Test("Observatory exposes the actual generation and detects mismatches instead of masking them")
    func observatoryConsistency() async throws {
        let f = try await fixture(window: 65_536)
        defer { await f.shutdown() }
        await f.host.start()
        let client = try await LingXiClientVNext.inProcess(service: f.host)
        let sid = try #require(try await client.session.create(workspace: f.root.path).result?.sessionID)
        _ = try await client.debug.setEnabled(true)
        let snapshot = try await client.debug.snapshot(sessionID: sid)
        let context = try #require(snapshot.runtimeContextPolicy)
        #expect(context.runtimeModelWindow == 65_536)
        #expect(context.effectivePolicy == ContextCachePolicySnapshot(policy: await f.host.effectiveContextPolicy))
        #expect(context.isConsistent)
        let mismatch = DebugRuntimeContextPolicy(runtimeModelWindow: 32_768, effectivePolicy: context.effectivePolicy, generation: context.generation)
        #expect(!mismatch.isConsistent)
        #expect(try JSONDecoder().decode(RuntimeObservatorySnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }
}
