import Foundation
import LingXiProtocol

/// Agent 最小编排入口（Session 化）。
/// sendMessage：append user → SessionContextBuilder 构建模型输入 → 推理。
/// 高频 delta 只走 DMA + 本轮内存 buffer 聚合；
/// Session 在 turn 完成时一次性写入最终 assistant content。
/// 本类型不解析任何 Provider JSON。
public actor AgentRuntime {
    private let store: any SessionStore
    private let contextEngine: L1ContextEngine
    private let modelBus: ModelBus
    private let dataPlane: DataPlane
    private let toolRuntime: ToolRuntime
    private let performanceStore: PerformanceStore
    private let contextPager: ContextPager
    private let projectScanner: ProjectScanner
    private let compactor: ContextCompactor
    private let budgetPlanner: ContextBudgetPlanner
    private let persistence: SQLitePersistenceStore?
    private let eventSink: @Sendable (CoreEvent) async -> Void
    private let interactive: Bool
    private var runtimes: [SessionID: SessionRuntime] = [:]

    init(
        store: any SessionStore,
        contextEngine: L1ContextEngine,
        modelBus: ModelBus,
        dataPlane: DataPlane,
        toolRuntime: ToolRuntime,
        performanceStore: PerformanceStore,
        contextPager: ContextPager,
        projectScanner: ProjectScanner,
        eventSink: @escaping @Sendable (CoreEvent) async -> Void,
        compactor: ContextCompactor = ContextCompactor(),
        budgetPlanner: ContextBudgetPlanner = ContextBudgetPlanner(policy: ContextBudgetPolicy(preferredActiveTokens: ProcessInfo.processInfo.environment["LINGXI_CONTEXT_PREFERRED_ACTIVE_TOKENS"].flatMap(Int.init))),
        persistence: SQLitePersistenceStore? = nil,
        interactive: Bool = false
    ) {
        self.store = store
        self.contextEngine = contextEngine
        self.modelBus = modelBus
        self.dataPlane = dataPlane
        self.toolRuntime = toolRuntime
        self.performanceStore = performanceStore
        self.contextPager = contextPager
        self.projectScanner = projectScanner
        self.eventSink = eventSink
        self.compactor = compactor
        self.budgetPlanner = budgetPlanner
        self.persistence = persistence
        self.interactive = interactive
    }

    // MARK: - Session 生命周期

    public func createSession() async throws -> SessionID {
        let session = try await store.create()
        runtimes[session.id] = makeRuntime(for: session.id)
        await eventSink(.sessionCreated(session.id))
        return session.id
    }

    public func restore() async throws {
        try await compactor.restoreDerived()
    }

    public func shutdown() async {
        for runtime in runtimes.values { await runtime.shutdown() }
    }

    public func listSessions() async throws -> [SessionInfo] {
        try await store.listSessions().map { $0.toInfo() }
    }

    public func sessionSnapshot(_ id: SessionID) async throws -> SessionSnapshot {
        try await store.session(id).toSnapshot()
    }

    public func contextSnapshot(_ id: SessionID) async -> L1ContextSnapshot? {
        await contextEngine.latestSnapshot(for: id)
    }

    public func performance(_ id: SessionID) async -> TurnPerformanceReport? {
        await performanceStore.report(for: id)
    }

    public func projectCache() async -> ProjectCacheDebugSnapshot {
        let metrics = await contextPager.debugMetrics(projectRoot: projectScanner.root)
        let derived = await compactor.cacheMetrics()
        return ProjectCacheDebugSnapshot(
            l2Pages: metrics.l2Pages,
            l2Characters: metrics.l2Characters,
            l2HitRate: metrics.l2Lookups == 0 ? nil : Double(metrics.l2Hits) / Double(metrics.l2Lookups),
            l3Pages: metrics.l3Pages,
            staleRebuilds: metrics.staleRebuilds,
            symbolCount: metrics.symbolCount,
            symbolIndexedFiles: metrics.symbolIndexedFiles,
            referenceCount: metrics.referenceCount,
            dependencyCount: metrics.dependencyCount,
            sessionL2DerivedPages: derived.l2Pages,
            derivedL3Pages: derived.l3Pages,
            derivedPageOutCount: derived.pageOutCount,
            derivedPageInCount: derived.pageInCount,
            historicalToolEvidencePages: derived.historicalToolPages,
            derivedL3Hits: derived.l3Hits,
            sessionL2DerivedHits: derived.l2Hits,
            sessionL2DerivedPromotions: derived.l2Promotions
        )
    }

    public func compact(_ sessionID: SessionID) async throws -> CompactSessionResponse {
        try await runtime(for: sessionID).compactNow()
    }

    public func cacheMetrics(_ sessionID: SessionID) async -> (l2Pages: Int, l3Pages: Int, pageOutCount: Int, pageInCount: Int, historicalToolPages: Int, l3Hits: Int, l2Hits: Int, l2Promotions: Int)? {
        await runtimes[sessionID]?.cacheMetrics()
    }

    public func contextUnitStates(_ sessionID: SessionID) async -> [ContextUnitDebugSnapshot] {
        await runtimes[sessionID]?.contextUnitStates() ?? []
    }

    // MARK: - 对话

    /// 在 Session 中发起一轮对话，返回该轮的 DMA 通道。
    public func sendMessage(_ sessionID: SessionID, _ content: String) async throws -> OpenedStream {
        try await runtime(for: sessionID).startTurn(content)
    }

    // MARK: - Private

    private func makeRuntime(for sessionID: SessionID) -> SessionRuntime {
        SessionRuntime(
            store: store,
            sessionID: sessionID,
            modelBus: modelBus,
            dataPlane: dataPlane,
            contextEngine: contextEngine,
            toolRuntime: toolRuntime,
            performanceStore: performanceStore,
            contextPager: contextPager,
            projectScanner: projectScanner,
            eventSink: eventSink,
            compactor: compactor,
            budgetPlanner: budgetPlanner,
            persistence: persistence,
            interactive: interactive
        )
    }

    private func runtime(for sessionID: SessionID) async throws -> SessionRuntime {
        if let runtime = runtimes[sessionID] { return runtime }
        _ = try await store.session(sessionID)
        let runtime = makeRuntime(for: sessionID)
        try await runtime.restore()
        runtimes[sessionID] = runtime
        return runtime
    }
}
