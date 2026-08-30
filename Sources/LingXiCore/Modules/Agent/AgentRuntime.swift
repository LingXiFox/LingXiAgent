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
    private let diagnosticsEnabled: Bool
    private var runtimes: [SessionID: SessionRuntime] = [:]
    private let modelResolver: SubagentModelResolver
    private let scheduler: AgentRunScheduler
    private let limits: SubagentRuntimeLimits
    private var runs: [AgentRunID: AgentRunInfo] = [:]
    private var results: [AgentRunID: SubagentResult] = [:]
    private var activeSessions: Set<SessionID> = []

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
        budgetPlanner: ContextBudgetPlanner = ContextBudgetPlanner(),
        persistence: SQLitePersistenceStore? = nil,
        interactive: Bool = false,
        diagnosticsEnabled: Bool = false,
        modelResolver: SubagentModelResolver,
        limits: SubagentRuntimeLimits = SubagentRuntimeLimits(),
        scheduler: AgentRunScheduler? = nil
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
        self.diagnosticsEnabled = diagnosticsEnabled
        self.modelResolver = modelResolver
        self.limits = limits
        self.scheduler = scheduler ?? AgentRunScheduler(limits: limits)
    }

    // MARK: - Session 生命周期

    public func createSession() async throws -> SessionID {
        let session = try await store.create(kind: .primary, parentSessionID: nil, rootSessionID: nil, spawnedByRunID: nil, spawnedByToolCallID: nil, title: nil)
        runtimes[session.id] = makeRuntime(for: session.id)
        await eventSink(.sessionCreated(session.id))
        return session.id
    }

    public func restore() async throws {
        try await compactor.restoreDerived()
        guard let persistence else { return }
        for persisted in try await persistence.loadAgentRuns() {
            var run = persisted
            if !run.status.isTerminal {
                run = AgentRunInfo(runID: run.runID, sessionID: run.sessionID, projectID: run.projectID, parentRunID: run.parentRunID, rootRunID: run.rootRunID, agentKind: run.agentKind, status: .recoveryRequired, modelSelection: run.modelSelection, startedAt: run.startedAt, finishedAt: .now, latestActivityAt: .now, error: CoreError(code: .toolCancelled, message: "Core 重启，运行需要恢复"), usage: run.usage, title: run.title)
                try await persistence.saveAgentRun(run)
            }
            runs[run.runID] = run
            if let result = try await persistence.agentRunResult(run.runID) { results[run.runID] = result }
        }
    }

    public func shutdown() async {
        for runtime in runtimes.values { await runtime.shutdown() }
    }

    public func listSessions() async throws -> [SessionInfo] {
        try await store.listSessions().map { $0.toInfo() }
    }

    public func listChildSessions(_ parentSessionID: SessionID) async throws -> [SessionInfo] {
        try await store.listSessions().filter { $0.parentSessionID == parentSessionID }.map { $0.toInfo() }
    }

    public func listAgentRuns(_ sessionID: SessionID) -> [AgentRunInfo] {
        runs.values.filter { $0.sessionID == sessionID }.sorted { $0.latestActivityAt < $1.latestActivityAt }
    }

    public func agentRun(_ runID: AgentRunID) throws -> AgentRunInfo {
        guard let run = runs[runID] else { throw CoreError(code: .agentRunNotFound, message: "AgentRun 不存在: \(runID.rawValue)") }
        return run
    }

    public func agentRun(_ runID: AgentRunID, requester: AgentRunID) throws -> AgentRunInfo {
        let run = try agentRun(runID)
        try requireSameTree(run, requester: requester)
        return run
    }

    public func agentRunResult(_ runID: AgentRunID) throws -> SubagentResult {
        guard let result = results[runID] else { throw CoreError(code: .agentRunNotFound, message: "AgentRun 尚无稳定结果: \(runID.rawValue)") }
        return result
    }

    public func agentRunResult(_ runID: AgentRunID, requester: AgentRunID) throws -> SubagentResult {
        let run = try agentRun(runID)
        try requireSameTree(run, requester: requester)
        return try agentRunResult(runID)
    }

    public func agentTree(_ rootSessionID: SessionID) async throws -> AgentTreeNode {
        let sessions = try await store.listSessions()
        func node(_ session: Session) -> AgentTreeNode {
            let latest = runs.values.filter { $0.sessionID == session.id }.max { $0.latestActivityAt < $1.latestActivityAt }
            return AgentTreeNode(session: session.toInfo(), latestRun: latest, children: sessions.filter { $0.parentSessionID == session.id }.map(node))
        }
        guard let root = sessions.first(where: { $0.id == rootSessionID }) else { throw CoreError(code: .sessionNotFound, message: "Session 不存在") }
        return node(root)
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
        guard !activeSessions.contains(sessionID) else { throw CoreError(code: .turnAlreadyRunning, message: "该 Session 已有进行中的对话轮次") }
        // Preserve the established contract: an unavailable provider still records the user turn.
        if modelBus.gateway.modelID == nil { return try await runtime(for: sessionID).startTurn(content) }
        do {
            // Reserve before the first await so concurrent callers cannot create a second lane.
            activeSessions.insert(sessionID)
            let session = try await store.session(sessionID)
            let run = try await createRun(session: session, parentRunID: nil, requestedModel: nil, title: session.title)
            return try await runtime(for: sessionID, run: run).startTurn(content)
        } catch {
            activeSessions.remove(sessionID)
            throw error
        }
    }

    public func spawn(parentSessionID: SessionID, parentRunID: AgentRunID, task: String, title: String? = nil, modelSelection: ModelSelection? = nil, profile: SubagentExecutionProfile? = nil, toolCallID: ToolCallID? = nil) async throws -> (SessionID, AgentRunInfo) {
        let parent = try await store.session(parentSessionID)
        let parentRun = try agentRun(parentRunID)
        guard parentRun.sessionID == parentSessionID, !parentRun.status.isTerminal else { throw CoreError(code: .toolArgumentInvalid, message: "Parent AgentRun 与 Session 不匹配或已结束") }
        let depth = try await depth(of: parent)
        guard depth < limits.maxSubagentDepth else { throw CoreError(code: .subagentDepthExceeded, message: "Subagent 最大深度已达到") }
        guard runs.values.filter({ $0.rootRunID == parentRun.rootRunID }).count < limits.maxTotalRunsPerRootRun else {
            throw CoreError(code: .subagentDepthExceeded, message: "单个 Root AgentRun 的运行总数已达到上限")
        }
        let child = try await store.create(kind: .subagent, parentSessionID: parent.id, rootSessionID: parent.rootSessionID, spawnedByRunID: parentRunID, spawnedByToolCallID: toolCallID, title: title)
        await eventSink(.childSessionCreated(child.toInfo()))
        var run = try await createRun(session: child, parentRunID: parentRunID, requestedModel: profile?.modelSelection ?? modelSelection, title: title)
        let runID = run.runID
        let status = await scheduler.submit(runID: runID) { [weak self] in await self?.runChild(runID: runID, task: task) }
        if status == .queued {
            run = updated(run, status: .queued)
            runs[run.runID] = run
            try await persistence?.saveAgentRun(run, profile: profile)
        }
        await eventSink(.subagentSpawned(run))
        if status == .queued { await eventSink(.agentRunQueued(run)) }
        return (child.id, run)
    }

    public func cancelAgentRun(_ runID: AgentRunID, descendants: Bool = true) async throws {
        _ = try agentRun(runID)
        let targets = descendants ? runs.values.filter { isDescendant($0, of: runID) || $0.runID == runID }.map(\.runID) : [runID]
        for id in targets {
            await scheduler.cancel(id)
            if let runtime = runtimes[runs[id]?.sessionID ?? SessionID("")] { await runtime.shutdown() }
            await finishRun(id, status: .cancelled, text: nil, usage: nil, error: CoreError(code: .toolCancelled, message: "AgentRun 已取消"))
        }
    }

    public func cancelAgentRun(_ runID: AgentRunID, requester: AgentRunID) async throws {
        let run = try agentRun(runID)
        try requireSameTree(run, requester: requester)
        try await cancelAgentRun(runID)
    }

    public func continueChild(sessionID: SessionID, parentRunID: AgentRunID, content: String) async throws -> AgentRunInfo {
        let session = try await store.session(sessionID)
        guard session.kind == .subagent else { throw CoreError(code: .toolArgumentInvalid, message: "只能继续 Child Session") }
        let parentRun = try agentRun(parentRunID)
        guard let spawnedBy = session.spawnedByRunID, let original = runs[spawnedBy], original.rootRunID == parentRun.rootRunID else { throw CoreError(code: .permissionDenied, message: "Child Session 不属于当前 Agent 树") }
        guard !activeSessions.contains(sessionID) else { throw CoreError(code: .turnAlreadyRunning, message: "该 Child Session 已有进行中的 AgentRun") }
        activeSessions.insert(sessionID)
        var run: AgentRunInfo
        do {
            run = try await createRun(session: session, parentRunID: parentRunID, requestedModel: nil, title: session.title)
        } catch {
            activeSessions.remove(sessionID)
            throw error
        }
        let runID = run.runID
        let status = await scheduler.submit(runID: runID) { [weak self] in await self?.runChild(runID: runID, task: content) }
        if status == .queued { run = updated(run, status: .queued); runs[runID] = run; try await persistence?.saveAgentRun(run) }
        if status == .queued { await eventSink(.agentRunQueued(run)) }
        return run
    }

    public func markWaitingForQuestion(_ request: QuestionRequest, waiting: Bool) async {
        guard let runID = request.originRunID, let run = runs[runID], !run.status.isTerminal else { return }
        let updated = updated(run, status: waiting ? .waitingForUser : .running)
        runs[runID] = updated
        try? await persistence?.saveAgentRun(updated)
        await eventSink(.agentRunStatusChanged(updated))
    }

    // MARK: - Private

    private func makeRuntime(for sessionID: SessionID, run: AgentRunInfo? = nil, modelBus overrideBus: ModelBus? = nil, rootSessionID: SessionID? = nil) -> SessionRuntime {
        SessionRuntime(
            store: store,
            sessionID: sessionID,
            modelBus: overrideBus ?? modelBus,
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
            interactive: interactive,
            diagnosticsEnabled: diagnosticsEnabled,
            runID: run?.runID,
            rootSessionID: rootSessionID ?? sessionID,
            parentSessionID: run?.parentRunID.flatMap { runs[$0]?.sessionID },
            runObserver: { [weak self] status, text, usage, error in
                guard let run else { return }
                await self?.finishRun(run.runID, status: status, text: text, usage: usage, error: error)
            }
        )
    }

    private func runtime(for sessionID: SessionID, run: AgentRunInfo? = nil) async throws -> SessionRuntime {
        if let run {
            let resolved = try await modelResolver.resolve(run.modelSelection, subagent: run.agentKind == .subagent)
            let bus = ModelBus(gateway: ModelGateway(provider: resolved.assembly.provider, modelID: resolved.assembly.modelID, contextProfile: resolved.assembly.contextProfile, reasoning: run.modelSelection.reasoning))
            let session = try await store.session(sessionID)
            let runtime = makeRuntime(for: sessionID, run: run, modelBus: bus, rootSessionID: session.rootSessionID)
            try await runtime.restore()
            runtimes[sessionID] = runtime
            return runtime
        }
        if let runtime = runtimes[sessionID] { return runtime }
        _ = try await store.session(sessionID)
        let runtime = makeRuntime(for: sessionID)
        try await runtime.restore()
        runtimes[sessionID] = runtime
        return runtime
    }

    private func createRun(session: Session, parentRunID: AgentRunID?, requestedModel: ModelSelection?, title: String?) async throws -> AgentRunInfo {
        let resolved = try await modelResolver.resolve(requestedModel, subagent: session.kind == .subagent)
        let id = AgentRunID(UUID().uuidString)
        let root = parentRunID.flatMap { runs[$0]?.rootRunID } ?? id
        let run = AgentRunInfo(runID: id, sessionID: session.id, projectID: session.projectID, parentRunID: parentRunID, rootRunID: root, agentKind: session.kind, status: .starting, modelSelection: resolved.selection, startedAt: .now, latestActivityAt: .now, title: title)
        runs[id] = run
        try await persistence?.saveAgentRun(run)
        await eventSink(.agentRunStarted(run))
        return run
    }

    private func runChild(runID: AgentRunID, task: String) async {
        guard let run = runs[runID] else { return }
        do {
            let stream = try await runtime(for: run.sessionID, run: run).startTurn(task)
            for try await _ in stream.chunks {}
        } catch let error as CoreError {
            await finishRun(runID, status: .failed, text: nil, usage: nil, error: error)
        } catch {
            await finishRun(runID, status: .failed, text: nil, usage: nil, error: CoreError(code: .provider, message: String(describing: error)))
        }
    }

    private func finishRun(_ runID: AgentRunID, status: AgentRunStatus, text: String?, usage: ModelUsage?, error: CoreError?) async {
        guard let old = runs[runID], !old.status.isTerminal else { return }
        let usage = AgentRunUsage(model: usage, elapsedMilliseconds: old.startedAt.map { Date().timeIntervalSince($0) * 1_000 })
        let run = AgentRunInfo(runID: old.runID, sessionID: old.sessionID, projectID: old.projectID, parentRunID: old.parentRunID, rootRunID: old.rootRunID, agentKind: old.agentKind, status: status, modelSelection: old.modelSelection, startedAt: old.startedAt, finishedAt: status.isTerminal ? .now : nil, latestActivityAt: .now, error: error, usage: usage, title: old.title)
        runs[runID] = run
        if status.isTerminal { activeSessions.remove(run.sessionID) }
        if status.isTerminal {
            if let resolved = try? await modelResolver.resolve(old.modelSelection, subagent: old.agentKind == .subagent) {
                await resolved.assembly.provider.endExecution(runID)
            }
            let result = SubagentResult(childSessionID: run.sessionID, runID: runID, status: status, finalText: text, usage: usage, error: error)
            results[runID] = result
            try? await persistence?.saveAgentRunResult(result)
            await scheduler.complete(runID)
            await eventSink(status == .completed ? .agentRunCompleted(run) : status == .cancelled ? .agentRunCancelled(run) : .agentRunFailed(run))
            await eventSink(.subagentResultAvailable(result))
        } else {
            await eventSink(.agentRunStatusChanged(run))
        }
        try? await persistence?.saveAgentRun(run)
    }

    private func depth(of session: Session) async throws -> Int {
        var result = 0; var current = session.parentSessionID
        while let id = current { result += 1; current = try await store.session(id).parentSessionID }
        return result
    }

    private func isDescendant(_ run: AgentRunInfo, of ancestor: AgentRunID) -> Bool {
        var current = run.parentRunID
        while let id = current { if id == ancestor { return true }; current = runs[id]?.parentRunID }
        return false
    }

    private func requireSameTree(_ target: AgentRunInfo, requester: AgentRunID) throws {
        guard let requesterRun = runs[requester], requesterRun.rootRunID == target.rootRunID else {
            throw CoreError(code: .permissionDenied, message: "AgentRun 不属于当前 Agent 树")
        }
    }

    private func updated(_ run: AgentRunInfo, status: AgentRunStatus) -> AgentRunInfo {
        AgentRunInfo(runID: run.runID, sessionID: run.sessionID, projectID: run.projectID, parentRunID: run.parentRunID, rootRunID: run.rootRunID, agentKind: run.agentKind, status: status, modelSelection: run.modelSelection, startedAt: run.startedAt, finishedAt: run.finishedAt, latestActivityAt: .now, error: run.error, usage: run.usage, title: run.title)
    }
}
