import Foundation
import LingXiProtocol

/// LingXi Core 宿主：Core 的启动、状态、模块组装与对外契约实现。
public actor CoreHost: CoreEndpoint {
    public static let coreVersion = "0.1.0"
    public static let protocolVersion = "1"

    public let info: CoreInfo
    private let bus = CommandBus()
    private let dataPlane = DataPlane()
    /// 由 Host 显式声明；headless 默认不允许问题工具等待用户输入。
    public let interactive: Bool
    public let questions: QuestionRuntime
    private let processes: ToolProcessStore
    private let sessionStore: any SessionStore
    /// nil 表示显式的 ephemeral Core；设置 LINGXI_DATA_ROOT 时启用 project durable state。
    public let persistence: SQLitePersistenceStore?
    private let gateway: ModelGateway
    private let modelResolver: SubagentModelResolver
    private let subagentService: SubagentToolService
    private let permissionEngine: PermissionEngine
    private let toolRuntime: ToolRuntime
    private let contextEngine: L1ContextEngine
    private let performanceStore: PerformanceStore
    private let contextPager: ContextPager
    private let projectScanner: ProjectScanner
    private let compactor: ContextCompactor
    private let budgetPlanner: ContextBudgetPlanner
    private let diagnosticsEnabled: Bool
    private let subagentLimits: SubagentRuntimeLimits
    private var agent: AgentRuntime?
    private var state: CoreState = .starting
    private var eventContinuations: [UUID: AsyncStream<CoreEvent>.Continuation] = [:]

    /// - Parameter providerAssembly: 显式注入 Provider 运行时（测试用）；nil 时从环境装配。
    public init(
        providerAssembly: ModelRuntimeAssembly? = nil,
        providerMissingRequirements: [String] = [],
        modelRuntimes: [String: ModelRuntimeAssembly] = [:],
        defaultModelSelection: ModelSelection? = nil,
        configuration: CoreConfiguration? = nil,
        sessionStore: (any SessionStore)? = nil,
        workspaceRoot: WorkspaceRoot? = nil,
        dataRoot: URL? = nil,
        permissionDecision: PermissionDecision? = nil,
        toolRegistry: ToolRegistry? = nil,
        mcpPager: MCPToolPager? = nil,
        interactive: Bool? = nil
    ) throws {
        let environment = ProcessInfo.processInfo.environment
        let supportsInteraction = interactive ?? configuration?.runtime.interactive ?? (environment["LINGXI_INTERACTIVE"] == "1")
        self.interactive = supportsInteraction
        questions = QuestionRuntime(interactive: supportsInteraction)
        let processes = ToolProcessStore()
        self.processes = processes
        let subagentService = SubagentToolService()
        self.subagentService = subagentService
        info = CoreInfo(
            name: "LingXiCore",
            version: Self.coreVersion,
            protocolVersion: Self.protocolVersion
        )
        let baseWorkspace = try workspaceRoot ?? WorkspaceRoot(path: environment["LINGXI_WORKSPACE_ROOT"] ?? FileManager.default.currentDirectoryPath)
        let persistentRoot = dataRoot ?? environment["LINGXI_DATA_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let sensitivePaths = SensitivePathPolicy(root: baseWorkspace.url, excluding: persistentRoot.map { [$0] } ?? [])
        let workspace = try WorkspaceRoot(path: baseWorkspace.url.path, sensitivePathPolicy: sensitivePaths)
        let effectiveMCPPager = mcpPager ?? MCPToolPager()
        let persistent = try persistentRoot.map {
            try SQLitePersistenceStore(dataRoot: $0, mainRoot: workspace.url)
        }
        persistence = persistent
        self.sessionStore = sessionStore ?? persistent.map(PersistentSessionStore.init) ?? InMemorySessionStore()
        let legacyDecision = permissionDecision ?? PermissionDecision(rawValue: environment["LINGXI_TOOL_PERMISSION"] ?? "")
        let policy = PermissionPolicy(rawValue: environment["LINGXI_PERMISSION_POLICY"] ?? "")
            ?? (legacyDecision == .allow ? .auto : .ask)
        let profile = ExecutionProfile(rawValue: environment["LINGXI_EXECUTION_PROFILE"] ?? "") ?? .workspace
        let permissions = legacyDecision.map { PermissionEngine(defaultDecision: $0) }
            ?? PermissionEngine(configuration: PermissionConfiguration(policy: policy, profile: profile))
        permissionEngine = permissions
        let l2Budget = Int(environment["LINGXI_L2_MAX_CHARS"] ?? "") ?? 256 * 1024
        let l1ProjectBudget = Int(environment["LINGXI_L1_PROJECT_MAX_CHARS"] ?? "") ?? 32 * 1024
        contextPager = ContextPager(store: ProjectPageStore(persistence: persistent), workingSet: L2WorkingSet(characterBudget: l2Budget), projectCharacterBudget: l1ProjectBudget)
        projectScanner = ProjectScanner(root: workspace.url, sensitivePathPolicy: sensitivePaths)
        toolRuntime = ToolRuntime(
            registry: toolRegistry ?? .builtin(workspace: workspace, contextPager: contextPager, scanner: projectScanner, questions: questions, processes: processes),
            permissions: permissions,
            mutations: ToolMutationCoordinator(pager: contextPager, scanner: projectScanner),
            outputArchive: ToolOutputArchive(persistence: persistent),
            outputSink: { [dataPlane] chunk in await dataPlane.emit(chunk) },
            mcpPager: effectiveMCPPager,
            subagents: subagentService
        )
        contextEngine = L1ContextEngine(policy: L1ContextPolicy(
            systemContext: environment["LINGXI_SYSTEM_CONTEXT"]
        ))
        diagnosticsEnabled = environment["LINGXI_PERF_DEBUG"] == "1"
        let agentSettings = configuration?.agent ?? AgentSettings()
        subagentLimits = SubagentRuntimeLimits(
            maxConcurrentSubagents: agentSettings.maxConcurrentSubagents,
            maxSubagentDepth: agentSettings.maxSubagentDepth,
            maxTotalRunsPerRootRun: agentSettings.maxTotalRunsPerRootRun
        )
        performanceStore = PerformanceStore(enabled: diagnosticsEnabled)
        compactor = ContextCompactor(derivedStore: DerivedContextStore(persistence: persistent))
        budgetPlanner = ContextBudgetPlanner(policy: ContextBudgetPolicy(preferredActiveTokens: environment["LINGXI_CONTEXT_PREFERRED_ACTIVE_TOKENS"].flatMap(Int.init)))

        let fallback = ProviderSetup.resolve(environment)
        let effective = providerAssembly ?? fallback.assembly
        gateway = ModelGateway(
            provider: effective.provider,
            modelID: effective.modelID.rawValue.isEmpty ? nil : effective.modelID,
            missingRequirements: providerAssembly == nil ? fallback.missing : providerMissingRequirements,
            contextProfile: effective.contextProfile
        )
        if let childModel = environment["LINGXI_SUBAGENT_SMOKE_MODEL"], !childModel.isEmpty {
            let child = ModelRuntimeAssembly(
                provider: effective.provider,
                modelID: ModelID(childModel),
                contextProfile: effective.contextProfile,
                endpoint: ResolvedModelEndpoint(providerID: "subagent", modelID: ModelID(childModel), baseURL: effective.endpoint.baseURL, wireProtocol: effective.endpoint.wireProtocol, contextProfile: effective.contextProfile)
            )
            var runtimes = modelRuntimes
            runtimes["subagent"] = child
            modelResolver = SubagentModelResolver(defaultRuntime: effective, runtimes: runtimes, defaultSelection: defaultModelSelection, defaultSubagentSelection: ModelSelection(providerID: "subagent", modelID: childModel))
        } else {
            modelResolver = SubagentModelResolver(defaultRuntime: effective, runtimes: modelRuntimes, defaultSelection: defaultModelSelection)
        }
    }

    /// 注册控制面路由并进入 ready。
    public func start() async {
        guard state == .starting else { return }
        await questions.setEventSink { [weak self] request in
            await self?.agent?.markWaitingForQuestion(request, waiting: true)
            await self?.broadcast(request.originSessionID == request.rootSessionID ? .questionAsked(request) : .questionEscalated(request))
        }
        await bus.add(.ping) { _ in .pong }
        await bus.add(.getInfo) { [self] _ in .info(info) }
        await bus.add(.getState) { [self] _ in .state(await state) }
        await bus.add(.getProviderStatus) { [self] _ in
            .providerStatus(await providerStatus)
        }
        await bus.add(.createSession) { [self] _ in
            let agent = try await requireAgent()
            let id = try await agent.createSession()
            let session = try await sessionStore.session(id)
            return .sessionCreated(session.toInfo())
        }
        await bus.add(.listSessions) { [self] _ in
            let agent = try await requireAgent()
            return .sessionList(try await agent.listSessions())
        }
        await bus.add(.getSession) { [self] command in
            let agent = try await requireAgent()
            guard case let .getSession(sessionID) = command else {
                return .error(CoreError(code: .unsupportedCommand, message: "getSession 参数缺失"))
            }
            return .sessionDetail(try await agent.sessionSnapshot(sessionID))
        }
        await bus.add(.replyPermission) { [self] command in
            guard case let .replyPermission(reply) = command else {
                return .error(CoreError(code: .unsupportedCommand, message: "replyPermission 参数缺失"))
            }
            try await permissionEngine.reply(reply)
            return .permissionReplyAccepted(reply.permissionID)
        }
        await bus.add(.replyQuestion) { [self] command in
            guard case let .replyQuestion(reply) = command else {
                return .error(CoreError(code: .unsupportedCommand, message: "replyQuestion 参数缺失"))
            }
            let request = await questions.request(reply.questionID)
            try await questions.reply(reply)
            if let request { await agent?.markWaitingForQuestion(request, waiting: false) }
            return .questionReplyAccepted(reply.questionID)
        }
        await bus.add(.getContext) { [self] command in
            guard case let .getContext(sessionID) = command else { return .error(CoreError(code: .unsupportedCommand, message: "getContext 参数缺失")) }
            let agent = try await requireAgent()
            guard let snapshot = await agent.contextSnapshot(sessionID) else { return .context(nil) }
            let units = await agent.contextUnitStates(sessionID)
            return .context(ContextDebugSnapshot(
                sessionID: snapshot.sessionID,
                revision: snapshot.revision,
                messageCount: snapshot.metrics.messageCount,
                partCount: snapshot.metrics.partCount,
                characterCount: snapshot.metrics.characterCount,
                sourceCounts: Dictionary(uniqueKeysWithValues: snapshot.metrics.sourceCounts.map { ($0.key.rawValue, $0.value) }),
                sessionCharacterCount: snapshot.metrics.sessionCharacterCount,
                projectCharacterCount: snapshot.metrics.projectCharacterCount,
                projectPageCount: snapshot.metrics.projectPageCount,
                estimatedTokens: snapshot.metrics.estimatedTokens,
                mandatoryTokens: snapshot.metrics.mandatoryTokens,
                recentSessionTokens: snapshot.metrics.recentSessionTokens,
                projectTokens: snapshot.metrics.projectTokens,
                derivedTokens: snapshot.metrics.derivedTokens,
                derivedPageCount: snapshot.metrics.derivedPageCount,
                liveToolBatchCount: snapshot.metrics.liveToolBatchCount,
                compactionGeneration: snapshot.metrics.compactionGeneration,
                units: units,
                materializedDerivedPageIDs: snapshot.entries.compactMap { $0.source == .derivedPage ? $0.messageID?.rawValue : nil }
            ))
        }
        await bus.add(.getPerformance) { [self] command in
            guard case let .getPerformance(sessionID) = command else { return .error(CoreError(code: .unsupportedCommand, message: "getPerformance 参数缺失")) }
            let agent = try await requireAgent()
            return .performance(await agent.performance(sessionID))
        }
        await bus.add(.getPermissionConfiguration) { [self] _ in
            .permissionConfiguration(await permissionEngine.currentConfiguration())
        }
        await bus.add(.setPermissionConfiguration) { [self] command in
            guard case let .setPermissionConfiguration(configuration) = command else { return .error(CoreError(code: .unsupportedCommand, message: "setPermissionConfiguration 参数缺失")) }
            await permissionEngine.setConfiguration(configuration)
            return .permissionConfiguration(configuration)
        }
        await bus.add(.getProjectCache) { [self] _ in
            let agent = try await requireAgent()
            return .projectCache(await agent.projectCache())
        }
        await bus.add(.compactSession) { [self] command in
            guard case let .compactSession(sessionID) = command else { return .error(CoreError(code: .unsupportedCommand, message: "compactSession 参数缺失")) }
            let agent = try await requireAgent()
            return .compactSession(try await agent.compact(sessionID))
        }
        await bus.add(.listChildSessions) { [self] command in
            guard case let .listChildSessions(id) = command else { return .error(CoreError(code: .unsupportedCommand, message: "listChildSessions 参数缺失")) }
            let agent = try await requireAgent()
            return .childSessionList(try await agent.listChildSessions(id))
        }
        await bus.add(.listAgentRuns) { [self] command in
            guard case let .listAgentRuns(id) = command else { return .error(CoreError(code: .unsupportedCommand, message: "listAgentRuns 参数缺失")) }
            let agent = try await requireAgent()
            return .agentRunList(await agent.listAgentRuns(id))
        }
        await bus.add(.getAgentRun) { [self] command in
            guard case let .getAgentRun(id) = command else { return .error(CoreError(code: .unsupportedCommand, message: "getAgentRun 参数缺失")) }
            let agent = try await requireAgent()
            return .agentRun(try await agent.agentRun(id))
        }
        await bus.add(.getAgentTree) { [self] command in
            guard case let .getAgentTree(id) = command else { return .error(CoreError(code: .unsupportedCommand, message: "getAgentTree 参数缺失")) }
            let agent = try await requireAgent()
            return .agentTree(try await agent.agentTree(id))
        }
        await bus.add(.getSubagentResult) { [self] command in
            guard case let .getSubagentResult(id) = command else { return .error(CoreError(code: .unsupportedCommand, message: "getSubagentResult 参数缺失")) }
            let agent = try await requireAgent()
            return .subagentResult(try await agent.agentRunResult(id))
        }
        await bus.add(.cancelAgentRun) { [self] command in
            guard case let .cancelAgentRun(id) = command else { return .error(CoreError(code: .unsupportedCommand, message: "cancelAgentRun 参数缺失")) }
            let agent = try await requireAgent()
            try await agent.cancelAgentRun(id)
            return .agentRunCancelled(id)
        }
        // .openTestStream / .sendMessage 属于数据面，不在控制面路由表中。

        let agent = AgentRuntime(
            store: sessionStore,
            contextEngine: contextEngine,
            modelBus: ModelBus(gateway: gateway),
            dataPlane: dataPlane,
            toolRuntime: toolRuntime,
            performanceStore: performanceStore,
            contextPager: contextPager,
            projectScanner: projectScanner,
            eventSink: { [weak self] event in
                await self?.broadcast(event)
            },
            compactor: compactor,
            budgetPlanner: budgetPlanner,
            persistence: persistence,
            interactive: interactive,
            diagnosticsEnabled: diagnosticsEnabled,
            modelResolver: modelResolver,
            limits: subagentLimits
        )
        self.agent = agent
        await subagentService.bind(
            spawn: { [weak agent] sessionID, runID, task, title, model, toolCallID in try await agent?.spawn(parentSessionID: sessionID, parentRunID: runID, task: task, title: title, modelSelection: model, toolCallID: toolCallID) ?? { throw CoreError(code: .notReady, message: "Agent 未就绪") }() },
            status: { [weak agent] runID, requester in try await agent?.agentRun(runID, requester: requester) ?? { throw CoreError(code: .notReady, message: "Agent 未就绪") }() },
            result: { [weak agent] runID, requester in try await agent?.agentRunResult(runID, requester: requester) ?? { throw CoreError(code: .notReady, message: "Agent 未就绪") }() },
            cancel: { [weak agent] runID, requester in try await agent?.cancelAgentRun(runID, requester: requester) },
            message: { [weak agent] sessionID, parentRunID, content in try await agent?.continueChild(sessionID: sessionID, parentRunID: parentRunID, content: content) ?? { throw CoreError(code: .notReady, message: "Agent 未就绪") }() }
        )
        do {
            try await agent.restore()
        } catch {
            self.agent = nil
            setState(.stopped)
            return
        }
        setState(.ready)
    }

    public func shutdown() async {
        setState(.shuttingDown)
        await agent?.shutdown()
        await dataPlane.closeAll()
        await questions.close()
        await processes.stopAll()
        agent = nil
        eventContinuations.values.forEach { $0.finish() }
        eventContinuations.removeAll()
        setState(.stopped)
    }

    // MARK: - CoreEndpoint（控制面）

    public func handle(_ command: ClientCommand) async throws -> CoreResponse {
        switch command {
        case .ping, .getInfo, .getState, .getProviderStatus:
            break
        default:
            guard state == .ready else { throw CoreError(code: .notReady, message: "Core 未就绪") }
        }
        return try await bus.dispatch(command)
    }

    public func events() -> AsyncStream<CoreEvent> {
        AsyncStream { continuation in
            let key = UUID()
            eventContinuations[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(key) }
            }
        }
    }

    public func toolOutputEvents() async -> AsyncStream<ToolOutputChunk> {
        await dataPlane.toolOutputEvents()
    }

    /// 供 ToolRuntime 或外部进程泵写入独立工具输出数据面。
    public func emitToolOutput(_ chunk: ToolOutputChunk) async {
        await dataPlane.emit(chunk)
    }

    // MARK: - CoreEndpoint（数据面）

    public func openDataStream(_ command: ClientCommand) async throws -> OpenedStream {
        guard state == .ready else { throw CoreError(code: .notReady, message: "Core 未就绪") }
        switch command {
        case .openTestStream:
            return await dataPlane.openTestStream()
        case let .sendMessage(sessionID, content):
            let agent = try requireAgent()
            return try await agent.sendMessage(sessionID, content)
        default:
            throw CoreError(code: .unsupportedCommand, message: "该命令不属于数据面")
        }
    }

    // MARK: - 事件广播

    /// Agent 等模块经此把语义事件送入所有控制面订阅者。
    public func broadcast(_ event: CoreEvent) {
        eventContinuations.values.forEach { $0.yield(event) }
    }

    // MARK: - Private

    private func requireAgent() throws -> AgentRuntime {
        guard state == .ready, let agent else {
            throw CoreError(code: .notReady, message: "Agent 尚未启动")
        }
        return agent
    }

    private var providerStatus: ProviderStatus {
        ProviderStatus(
            configured: gateway.isConfigured,
            model: gateway.modelID?.rawValue,
            baseURL: nil,
            missingRequirements: gateway.missingRequirements
        )
    }

    private func setState(_ newState: CoreState) {
        state = newState
        eventContinuations.values.forEach { $0.yield(.stateChanged(newState)) }
    }

    private func removeEventContinuation(_ key: UUID) {
        eventContinuations.removeValue(forKey: key)
    }
}
