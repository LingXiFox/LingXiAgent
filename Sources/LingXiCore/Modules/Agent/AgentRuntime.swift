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
    private let eventSink: @Sendable (CoreEvent) async -> Void
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
        eventSink: @escaping @Sendable (CoreEvent) async -> Void
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
    }

    // MARK: - Session 生命周期

    public func createSession() async throws -> SessionID {
        let session = try await store.create()
        runtimes[session.id] = makeRuntime(for: session.id)
        await eventSink(.sessionCreated(session.id))
        return session.id
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
        return ProjectCacheDebugSnapshot(
            l2Pages: metrics.l2Pages,
            l2Characters: metrics.l2Characters,
            l2HitRate: metrics.l2Lookups == 0 ? nil : Double(metrics.l2Hits) / Double(metrics.l2Lookups),
            l3Pages: metrics.l3Pages,
            staleRebuilds: metrics.staleRebuilds
        )
    }

    // MARK: - 对话

    /// 在 Session 中发起一轮对话，返回该轮的 DMA 通道。
    public func sendMessage(_ sessionID: SessionID, _ content: String) async throws -> OpenedStream {
        guard let runtime = runtimes[sessionID] else {
            throw CoreError(code: .sessionNotFound, message: "Session 不存在: \(sessionID.rawValue)")
        }
        return try await runtime.startTurn(content)
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
            eventSink: eventSink
        )
    }
}
