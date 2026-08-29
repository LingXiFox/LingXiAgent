import Foundation
import LingXiProtocol

/// LingXi Core 宿主：Core 的启动、状态、模块组装与对外契约实现。
public actor CoreHost: CoreEndpoint {
    public static let coreVersion = "0.1.0"
    public static let protocolVersion = "1"

    public let info: CoreInfo
    private let bus = CommandBus()
    private let dataPlane = DataPlane()
    private let sessionStore: any SessionStore
    /// nil 表示显式的 ephemeral Core；设置 LINGXI_DATA_ROOT 时启用 project durable state。
    public let persistence: SQLitePersistenceStore?
    private let gateway: ModelGateway
    private let permissionEngine: PermissionEngine
    private let toolRuntime: ToolRuntime
    private let contextEngine: L1ContextEngine
    private let performanceStore: PerformanceStore
    private let contextPager: ContextPager
    private let projectScanner: ProjectScanner
    private let compactor: ContextCompactor
    private var agent: AgentRuntime?
    private var state: CoreState = .starting
    private var eventContinuations: [UUID: AsyncStream<CoreEvent>.Continuation] = [:]

    /// - Parameter providerAssembly: 显式注入 Provider 运行时（测试用）；nil 时从环境装配。
    public init(
        providerAssembly: ModelRuntimeAssembly? = nil,
        sessionStore: (any SessionStore)? = nil,
        workspaceRoot: WorkspaceRoot? = nil,
        dataRoot: URL? = nil,
        permissionDecision: PermissionDecision? = nil,
        toolRegistry: ToolRegistry? = nil
    ) throws {
        info = CoreInfo(
            name: "LingXiCore",
            version: Self.coreVersion,
            protocolVersion: Self.protocolVersion
        )
        let workspace = try workspaceRoot ?? WorkspaceRoot.fromEnvironment()
        let environment = ProcessInfo.processInfo.environment
        let persistentRoot = dataRoot ?? environment["LINGXI_DATA_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
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
        toolRuntime = ToolRuntime(registry: toolRegistry ?? .builtin(workspace: workspace), permissions: permissions)
        let l2Budget = Int(environment["LINGXI_L2_MAX_CHARS"] ?? "") ?? 256 * 1024
        let l1ProjectBudget = Int(environment["LINGXI_L1_PROJECT_MAX_CHARS"] ?? "") ?? 32 * 1024
        contextPager = ContextPager(store: ProjectPageStore(persistence: persistent), workingSet: L2WorkingSet(characterBudget: l2Budget), projectCharacterBudget: l1ProjectBudget)
        projectScanner = ProjectScanner(root: workspace.url)
        contextEngine = L1ContextEngine(policy: L1ContextPolicy(
            systemContext: ProcessInfo.processInfo.environment["LINGXI_SYSTEM_CONTEXT"]
        ))
        performanceStore = PerformanceStore()
        compactor = ContextCompactor(derivedStore: DerivedContextStore(persistence: persistent))

        let (assembly, missing) = ProviderSetup.resolve()
        let effective = providerAssembly ?? assembly
        gateway = ModelGateway(
            provider: effective.provider,
            modelID: effective.modelID.rawValue.isEmpty ? nil : effective.modelID,
            missingRequirements: providerAssembly == nil ? missing : [],
            contextProfile: effective.contextProfile
        )
    }

    /// 注册控制面路由并进入 ready。
    public func start() async {
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
            persistence: persistence
        )
        self.agent = agent
        do {
            try await agent.restore()
        } catch {
            setState(.stopped)
            return
        }
        setState(.ready)
    }

    public func shutdown() async {
        setState(.shuttingDown)
        await dataPlane.closeAll()
        eventContinuations.values.forEach { $0.finish() }
        eventContinuations.removeAll()
        setState(.stopped)
    }

    // MARK: - CoreEndpoint（控制面）

    public func handle(_ command: ClientCommand) async throws -> CoreResponse {
        try await bus.dispatch(command)
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

    // MARK: - CoreEndpoint（数据面）

    public func openDataStream(_ command: ClientCommand) async throws -> OpenedStream {
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
        guard let agent else {
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
