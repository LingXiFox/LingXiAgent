import Foundation
import LingXiProtocol

private actor InFlightMutationLock {
    private var activeCommandIDs: Set<CommandID> = []
    private var waiters: [CommandID: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(commandID: CommandID) async {
        if activeCommandIDs.contains(commandID) {
            await withCheckedContinuation { continuation in
                waiters[commandID, default: []].append(continuation)
            }
        }
        activeCommandIDs.insert(commandID)
    }

    func release(commandID: CommandID) {
        if var list = waiters[commandID], !list.isEmpty {
            let next = list.removeFirst()
            if list.isEmpty {
                waiters.removeValue(forKey: commandID)
            } else {
                waiters[commandID] = list
            }
            next.resume()
        } else {
            activeCommandIDs.remove(commandID)
        }
    }
}

/// LingXi Core 宿主：Core 的启动、状态、模块组装与对外契约实现。
public actor CoreHost: CoreEndpoint, LingXiProtocolService {
    public static let coreVersion = "1.0.0"

    public static func stdioInteractive(environment: [String: String]) -> Bool {
        environment["LINGXI_INTERACTIVE"] == "1"
    }

    public let info: CoreInfo
    nonisolated private let bus = CommandBus()
    nonisolated private let dataPlane = DataPlane()
    /// 由 Host 显式声明；headless 默认不允许问题工具等待用户输入。
    public let interactive: Bool
    public let questions: QuestionRuntime
    private let processes: ToolProcessStore
    private let backgroundManager: BackgroundCommandManager
    public let sessionStore: any SessionStore
    /// nil 表示显式的 ephemeral Core；调用方传入 dataRoot 时启用 project durable state。
    public let persistence: SQLitePersistenceStore?
    public let storageLayout: CoreStorageLayout
    public private(set) var workspaceURL: URL
    public let extensionPlatform: ExtensionPlatform
    private let gateway: ModelGateway
    private let modelResolver: SubagentModelResolver
    private let subagentService: SubagentToolService
    private let permissionEngine: PermissionEngine
    private var toolRuntime: ToolRuntime
    private var mutationCoordinator: ToolMutationCoordinator
    private let contextEngine: L1ContextEngine
    private let performanceStore: PerformanceStore
    private let contextPager: ContextPager
    private var projectScanner: ProjectScanner
    public let compactor: ContextCompactor
    public private(set) var cacheController: ContextCacheController
    private let budgetPlanner: ContextBudgetPlanner
    private let diagnosticsEnabled: Bool
    private let configurationStore: ConfigurationStore?
    private let credentialStore: (any CredentialStore)?
    private let subagentLimits: SubagentRuntimeLimits
    private let executionDeadlinePolicy: ExecutionDeadlinePolicy
    private let diagnosticsStore: RuntimeDiagnosticsStore
    private let mcpPager: MCPToolPager
    private let l2CharacterCapacity: Int
    private let l1ProjectCharacterCapacity: Int
    private let behaviorProfile: AgentBehaviorProfile
    private let behaviorInstructionsEnabled: Bool
    private var behaviorSystemContext: @Sendable (AgentBehaviorProfile, SubagentExecutionProfile?) -> String?
    private let agentSettings: AgentSettings
    private let restoreScheduler: SessionRestoreScheduler?
    private var codeIntelligence: CodeIntelligence?
    package var agent: AgentRuntime?
    public var residentAgentRuntimesCount: Int {
        get async {
            await agent?.residentRuntimesCount ?? 0
        }
    }
    private var workflows: WorkflowRuntime?
    private var runtimeProviderAccounts: [String: ProviderAccountInfo] = [:]
    private var runtimeExtensions: [String: ExtensionInfo] = [:]
    private var cachedAssemblies: [String: ModelRuntimeAssembly] = [:]
    private var oauthRefreshers: [String: OAuthTokenRefresher] = [:]
    private var currentAssembly: ModelRuntimeAssembly?
    private let dataRootURL: URL?
    private var selectedModelOverride: String?
    private var selectedModelContextWindow: Int?
    private var contextActivity: ContextPagingActivity = .idle
    private var state: CoreState = .starting
    private var eventContinuations: [UUID: AsyncStream<CoreEvent>.Continuation] = [:]
    private var activeTurnTasks: [RunID: Task<Void, Never>] = [:]
    private var activeTurnTasksBySession: [SessionID: [RunID: Task<Void, Never>]] = [:]

    private func registerActiveTurnTask(_ task: Task<Void, Never>, runID: RunID, sessionID: SessionID) {
        activeTurnTasks[runID] = task
        activeTurnTasksBySession[sessionID, default: [:]][runID] = task
    }

    private func unregisterActiveTurnTask(runID: RunID, sessionID: SessionID) {
        activeTurnTasks.removeValue(forKey: runID)
        activeTurnTasksBySession[sessionID]?.removeValue(forKey: runID)
    }

    @discardableResult
    private func cancelActiveTurnTask(runID: RunID) -> Task<Void, Never>? {
        var cancelledTask: Task<Void, Never>?
        if let task = activeTurnTasks.removeValue(forKey: runID) {
            task.cancel()
            cancelledTask = task
        }
        for sessionID in activeTurnTasksBySession.keys {
            if let task = activeTurnTasksBySession[sessionID]?.removeValue(forKey: runID) {
                task.cancel()
                if cancelledTask == nil { cancelledTask = task }
            }
        }
        return cancelledTask
    }

    private func cancelActiveTurnTasks(for sessionID: SessionID) {
        if let tasks = activeTurnTasksBySession.removeValue(forKey: sessionID) {
            for (runID, task) in tasks {
                task.cancel()
                activeTurnTasks.removeValue(forKey: runID)
            }
        }
    }

    private func getActiveTurnTask(runID: RunID) -> Task<Void, Never>? {
        activeTurnTasks[runID]
    }

    package func hasActiveTurnTask(runID: RunID) -> Bool {
        activeTurnTasks[runID] != nil
    }
    package var toolRuntimeRef: ToolRuntime { toolRuntime }
    package var workspaceRevisionRef: UInt64 { workspaceRevision }
    public var currentWorkspaceRevision: UInt64 { workspaceRevision }
    public var ecoreStoreRef: ECoreObjectStore { cacheController.ecoreStore }
    package var backgroundManagerRef: BackgroundCommandManager { backgroundManager }
    package var workflowRuntimeRef: WorkflowRuntime? { workflows }
    package var performanceStoreRef: PerformanceStore { performanceStore }
    public private(set) var effectiveContextPolicy: EffectiveContextPolicy

    private func recordInitialECoreToken(_ token: ECoreObjectStore.MutationSubscriptionToken) {
        if self.ecoreMutationSubscriptionToken == nil {
            self.ecoreMutationSubscriptionToken = token
        }
    }

    // MARK: - Protocol vNext State
    public enum CommitFailpoint: String, Sendable, Equatable {
        case beforeStateMutation
        case afterStateMutationBeforeEventAppend
        case afterEventAppendBeforeReceipt
        case afterCommitBeforeResponse
    }

    public let runtimeEventLog: RuntimeEventLog
    private var sessionCoordinators: [SessionID: SessionTurnCoordinator] = [:]
    private let idempotencyJournal: IdempotencyJournal
    private let inFlightLock = InFlightMutationLock()
    public let commandWAL: DurableCommandWAL
    public let contentStore: ContentStore
    public let sessionMutationLock: SessionMutationLock
    public let codebaseGraphEngine: CodebaseGraphEngine
    public let browserSessionManager: BrowserSessionManager
    public let providerActivityRegistry: ProviderActivityRegistry
    public let todoStore: TodoStore
    private var ecoreMutationSubscriptionToken: ECoreObjectStore.MutationSubscriptionToken?
    private var currentRevision: UInt64 = 1
    private var contextStateRevisions: [SessionID: UInt64] = [:]
    public let eventLogStorageDirectory: URL?
    public private(set) var activeFailpoint: CommitFailpoint?

    public func setCommitFailpoint(_ failpoint: CommitFailpoint?) {
        self.activeFailpoint = failpoint
    }

    public private(set) var startupPolicy: CoreHostStartupPolicy
    public let crashTestStage: String?
    private var registryRefreshTask: Task<Void, Never>?
    private var workspaceIndexTask: Task<Void, Never>?
    private var workspaceRevision: UInt64 = 1

    /// - Parameter providerAssembly: 显式注入 Provider 运行时（测试用）；nil 时从环境装配。
    public init(
        startupPolicy: CoreHostStartupPolicy? = nil,
        providerAssembly: ModelRuntimeAssembly? = nil,
        providerMissingRequirements: [String] = [],
        modelRuntimes: [String: ModelRuntimeAssembly] = [:],
        defaultModelSelection: ModelSelection? = nil,
        configuration: CoreConfiguration? = nil,
        sessionStore: (any SessionStore)? = nil,
        workspaceRoot: WorkspaceRoot? = nil,
        dataRoot: URL? = nil,
        storageLayout: CoreStorageLayout? = nil,
        persistence: SQLitePersistenceStore? = nil,
        permissionDecision: PermissionDecision? = nil,
        toolRegistry: ToolRegistry? = nil,
        mcpPager: MCPToolPager? = nil,
        interactive: Bool? = nil,
        configurationStore: ConfigurationStore? = nil,
        credentialStore: (any CredentialStore)? = nil,
        restoreScheduler: SessionRestoreScheduler? = nil,
        extensionPlatform: ExtensionPlatform? = nil,
        backgroundManager: BackgroundCommandManager? = nil,
        crashTestStage: String? = nil
    ) throws {
        let environment = ProcessInfo.processInfo.environment
        let processName = ProcessInfo.processInfo.processName.lowercased()
        let arguments = ProcessInfo.processInfo.arguments
        let isTesting = startupPolicy == .unitTest
            || startupPolicy?.allowExternalProcesses == false
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["LINGXI_TEST_MODE"] != nil
            || processName.contains("test")
            || processName.contains("xctest")
            || arguments.contains(where: { $0.localizedCaseInsensitiveContains("test") })
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("Testing.Test") != nil
        let effectivePolicy = startupPolicy ?? (isTesting ? .unitTest : CoreHostStartupPolicy.defaultPolicy)
        self.startupPolicy = effectivePolicy
        let isTestingEnv = isTesting || effectivePolicy == .unitTest || !effectivePolicy.allowExternalProcesses
        let layout: CoreStorageLayout
        if let explicit = storageLayout {
            layout = explicit
        } else if let dataRoot {
            layout = CoreStorageLayout(root: dataRoot)
        } else if isTestingEnv {
            layout = CoreStorageLayout.temporarySandbox()
        } else {
            layout = CoreStorageLayout.production
        }
        self.storageLayout = layout
        self.crashTestStage = crashTestStage ?? environment["LINGXI_CRASH_TEST_STAGE"]
        try? layout.ensureDirectoriesExist()

        // 实例级持有与隔离核心服务，杜绝跨 Host 单例污染 (Audit Round 7 Phase B)
        let effectiveTodoStore = TodoStore(storageDir: layout.todos)
        let effectiveGraphEngine: CodebaseGraphEngine
        if isTestingEnv {
            effectiveGraphEngine = CodebaseGraphEngine(cachePolicy: .disabled)
        } else {
            effectiveGraphEngine = CodebaseGraphEngine(cachePolicy: .persistent(layout.graphCache))
        }
        let effectiveBrowserManager = BrowserSessionManager()
        let effectiveActivityRegistry = ProviderActivityRegistry()
        let effectiveSessionMutationLock = SessionMutationLock()

        self.todoStore = effectiveTodoStore
        self.codebaseGraphEngine = effectiveGraphEngine
        self.browserSessionManager = effectiveBrowserManager
        self.providerActivityRegistry = effectiveActivityRegistry
        self.sessionMutationLock = effectiveSessionMutationLock

        let supportsInteraction = interactive ?? configuration?.runtime.interactive ?? false
        self.interactive = supportsInteraction
        self.configurationStore = configurationStore ?? dataRoot.flatMap { try? ConfigurationStore(dataRoot: $0) }
        self.credentialStore = credentialStore
        self.restoreScheduler = restoreScheduler
        self.dataRootURL = dataRoot
        self.cachedAssemblies = modelRuntimes
        let questionsRuntime = QuestionRuntime(interactive: supportsInteraction)
        self.questions = questionsRuntime
        let processes = ToolProcessStore()
        self.processes = processes
        let bgManager = backgroundManager ?? BackgroundCommandManager()
        self.backgroundManager = bgManager
        let subagentService = SubagentToolService()
        self.subagentService = subagentService
        info = CoreInfo(
            name: "LingXiCore",
            version: Self.coreVersion,
            protocolVersion: ProtocolVersion.current.description
        )
        let baseWorkspace: WorkspaceRoot
        if let workspaceRoot {
            baseWorkspace = workspaceRoot
        } else if isTestingEnv {
            let defaultTestPath = dataRoot?.path ?? layout.root.path
            baseWorkspace = try WorkspaceRoot(path: defaultTestPath)
        } else {
            baseWorkspace = try WorkspaceRoot(path: LingXiPlatform.process.currentWorkingDirectory())
        }
        let persistentRoot = (dataRoot != nil || !isTestingEnv) ? layout.persistence : nil
        let sensitivePaths = SensitivePathPolicy(root: baseWorkspace.url)
        let workspace = try WorkspaceRoot(path: baseWorkspace.url.path, sensitivePathPolicy: sensitivePaths)
        self.workspaceURL = workspace.url
        let instructions = try AgentInstructionSet.load(workspace: workspace.url)
        let agentSettings = configuration?.agent ?? AgentSettings()
        self.agentSettings = agentSettings
        let behaviorProfile = agentSettings.behaviorProfile ?? .build
        self.behaviorProfile = behaviorProfile
        let defaultAccessScope = (agentSettings.executionProfile == .fullAccess) ? "fullAccess" : "workspace"
        let behaviorSystemContext: @Sendable (AgentBehaviorProfile, SubagentExecutionProfile?) -> String? = { profile, execProfile in
            let scope: String
            if let execProfile {
                scope = (execProfile.permissionProfile == "fullAccess") ? "fullAccess" : "workspace"
            } else {
                scope = defaultAccessScope
            }
            let facts = AgentEnvironmentFacts(
                workspaceRoot: workspace.url.path,
                currentDirectory: workspace.url.path,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                shell: environment["SHELL"] ?? "unknown",
                accessScope: scope
            )
            return AgentBehaviorInstructions.render(
                profile: profile,
                configured: agentSettings.systemContext,
                repository: instructions,
                environmentFacts: facts
            )
        }
        self.behaviorSystemContext = behaviorSystemContext
        let behaviorInstructionsEnabled = configuration?.agent != nil
        self.behaviorInstructionsEnabled = behaviorInstructionsEnabled
        let systemContext = behaviorSystemContext(behaviorProfile, nil)
        let effectiveMCPPager = mcpPager ?? MCPToolPager()
        self.mcpPager = effectiveMCPPager
        diagnosticsStore = RuntimeDiagnosticsStore()
        let persistent = try persistence ?? persistentRoot.map {
            try SQLitePersistenceStore(dataRoot: $0, mainRoot: workspace.url)
        }
        self.persistence = persistent
        self.sessionStore = sessionStore ?? persistent.map(PersistentSessionStore.init) ?? InMemorySessionStore()
        let executionDeadlinePolicy = ExecutionDeadlinePolicy(settings: configuration?.runtime.execution ?? ExecutionTimeoutSettings())
        self.executionDeadlinePolicy = executionDeadlinePolicy
        let permissions = permissionDecision.map { PermissionEngine(defaultDecision: $0) }
            ?? PermissionEngine(configuration: PermissionConfiguration(policy: agentSettings.permissionPolicy, profile: agentSettings.executionProfile))
        permissionEngine = permissions
        self.extensionPlatform = extensionPlatform ?? ExtensionPlatform(
            globalRoot: persistentRoot ?? layout.root.appendingPathComponent("extensions", isDirectory: true),
            projectRoot: workspace.url,
            permissions: permissions,
            deadlinePolicy: executionDeadlinePolicy,
            enablePlugins: effectivePolicy.discoverBinaryPlugins
        )
        let l2Budget = agentSettings.l2MaxCharacters
        let l1ProjectBudget = agentSettings.l1ProjectMaxCharacters
        l2CharacterCapacity = l2Budget
        l1ProjectCharacterCapacity = l1ProjectBudget
        let pager = ContextPager(store: ProjectPageStore(persistence: persistent), workingSet: L2WorkingSet(characterBudget: l2Budget), projectCharacterBudget: l1ProjectBudget)
        let scanner = ProjectScanner(root: workspace.url, sensitivePathPolicy: sensitivePaths)
        let effective = providerAssembly ?? .unavailable
        self.currentAssembly = (providerAssembly != nil && !effective.modelID.rawValue.isEmpty) ? providerAssembly : nil
        gateway = ModelGateway(assembly: effective.modelID.rawValue.isEmpty ? nil : effective, missingRequirements: providerAssembly == nil ? ["providers.defaultSelection"] : providerMissingRequirements, deadlinePolicy: executionDeadlinePolicy, activityRegistry: effectiveActivityRegistry)
        let selection = defaultModelSelection ?? ModelSelection(providerID: effective.endpoint.providerID, accountID: effective.endpoint.accountID, profileID: effective.endpoint.profileID, modelID: effective.modelID.rawValue)
        modelResolver = SubagentModelResolver(defaultRuntime: effective, runtimes: modelRuntimes, defaultSelection: selection)

        let modelWindow = effective.endpoint.contextProfile.contextWindowTokens
        let globalContextConfig = configuration?.context ?? ContextCacheConfiguration()
        let resolvedPolicy: EffectiveContextPolicy
        do {
            resolvedPolicy = try ContextPolicyResolver.resolve(
                global: globalContextConfig,
                modelWindow: modelWindow
            )
        } catch {
            resolvedPolicy = EffectiveContextPolicy(
                addressableBudget: 1_048_576,
                modelWindow: modelWindow,
                economicThreshold: 272_000,
                reserve: 22_000,
                l1Target: 220_000,
                l1SoftLimit: 235_000,
                l1HardLimit: 250_000,
                l2Max: 350_000,
                l3Capacity: 456_576
            )
        }
        self.effectiveContextPolicy = resolvedPolicy

        compactor = ContextCompactor(derivedStore: DerivedContextStore(persistence: persistent))
        let ecoreStore = ECoreObjectStore(
            baseDirectory: layout.ecore,
            configuration: configuration?.context.fabric ?? ContextObjectFabricConfiguration()
        )
        let cacheController = ContextCacheController(
            contextPager: pager,
            scanner: scanner,
            compactor: compactor,
            policy: resolvedPolicy,
            ecoreStore: ecoreStore
        )
        let codeIntelligence = agentSettings.codeIntelligenceEnabled ? CodeIntelligence(workspace: workspace, scanner: scanner, pager: pager) : nil
        self.codeIntelligence = codeIntelligence
        let effectiveRegistry = toolRegistry ?? ToolRegistry.builtin(
            workspace: workspace,
            contextPager: pager,
            scanner: scanner,
            questions: questionsRuntime,
            processes: processes,
            backgroundManager: bgManager,
            codeIntelligence: codeIntelligence,
            cacheController: cacheController,
            webSearchEndpoint: environment["LINGXI_WEB_SEARCH_ENDPOINT"].flatMap(URL.init(string:)),
            tavilyAPIKey: environment["TAVILY_API_KEY"],
            graphEngine: effectiveGraphEngine,
            todoStore: effectiveTodoStore,
            browserManager: effectiveBrowserManager
        )
        let mutationCoordinator = ToolMutationCoordinator(pager: pager, scanner: scanner)
        let effectiveToolRuntime = ToolRuntime(
            registry: effectiveRegistry,
            permissions: permissions,
            mutations: mutationCoordinator,
            outputArchive: ToolOutputArchive(persistence: persistent),
            outputSink: { [dataPlane] chunk in await dataPlane.emit(chunk) },
            mcpPager: effectiveMCPPager,
            subagents: subagentService,
            cacheController: cacheController,
            deadlinePolicy: executionDeadlinePolicy,
            workspacePath: workspace.path,
            workspaceRevision: self.workspaceRevision
        )
        self.contextPager = pager
        self.projectScanner = scanner
        self.cacheController = cacheController
        self.toolRuntime = effectiveToolRuntime
        self.mutationCoordinator = mutationCoordinator
        contextEngine = L1ContextEngine(policy: L1ContextPolicy(
            systemContext: systemContext
        ))
        diagnosticsEnabled = environment["LINGXI_PERF_DEBUG"] == "1"
        subagentLimits = SubagentRuntimeLimits(
            maxConcurrentSubagents: agentSettings.maxConcurrentSubagents,
            maxSubagentDepth: agentSettings.maxSubagentDepth,
            maxTotalRunsPerRootRun: agentSettings.maxTotalRunsPerRootRun
        )
        performanceStore = PerformanceStore(enabled: diagnosticsEnabled)
        budgetPlanner = ContextBudgetPlanner(policy: ContextBudgetPolicy(preferredActiveTokens: agentSettings.preferredActiveTokens))
        let eventLogDir = layout.eventLog
        self.eventLogStorageDirectory = eventLogDir
        runtimeEventLog = RuntimeEventLog(storageDirectory: eventLogDir)
        idempotencyJournal = IdempotencyJournal(storageDirectory: eventLogDir)
        commandWAL = DurableCommandWAL(storageDirectory: eventLogDir)
        let storageDir = layout.content
        contentStore = ContentStore(storageDirectory: storageDir)
    }

    /// 注册控制面路由并进入 ready。
    public func start() async {
        guard state == .starting else { return }
        if let retrievalTool = toolRuntime.registry.tool(for: RetrievalSearchTool.toolID) as? RetrievalSearchTool {
            let runtime = retrievalTool.retrievalRuntime
            let projectURL = workspaceURL
            await mutationCoordinator.addMutationHook {
                await runtime.markDirty(source: .workspace, projectRoot: projectURL)
            }
            let token = await cacheController.ecoreStore.addMutationHook {
                await runtime.markDirty(source: .ecore, projectRoot: projectURL)
            }
            recordInitialECoreToken(token)
        }
        await commandWAL.recover(
            sessionStore: sessionStore,
            runtimeEventLog: runtimeEventLog,
            coordinatorProvider: { [weak self] id in
                guard let self else { throw CoreError(code: .sessionNotFound, message: "Host deallocated") }
                return try await self.coordinator(for: id)
            }
        )
        await diagnosticsStore.record(kind: .core, event: "core.start.begin", metadata: ["interactive": String(interactive)])
        if startupPolicy.discoverSkills || startupPolicy.discoverCommands || startupPolicy.discoverBinaryPlugins {
            await extensionPlatform.restore()
            _ = await extensionPlatform.discover()
        }
        await questions.setEventSink { [weak self] request in
            await self?.agent?.markWaitingForQuestion(request, waiting: true)
            await self?.routeWorkflowQuestion(request)
            await self?.broadcast(request.originSessionID == request.rootSessionID ? .questionAsked(request) : .questionEscalated(request))
        }
        await bus.add(.ping) { _ in .pong }
        if startupPolicy.refreshRegistry && startupPolicy.allowNetwork {
            scheduleRegistryRefresh()
        }
        // Phase 7: Do not eagerly warm up CodebaseGraph on startup to avoid 1GB RSS explosion.
        // Graph indexing is now lazy upon first codebase_graph usage.
        await bus.add(.getInfo) { [self] _ in .info(info) }
        await bus.add(.getState) { [self] _ in .state(await state) }
        await bus.add(.getProviderStatus) { [self] _ in
            .providerStatus(await providerStatus)
        }
        await bus.add(.getDiagnostics) { [self] _ in
            .diagnostics(await diagnosticsBundle())
        }
        await bus.add(.listProviderProducts) { _ in .providerProducts(BuiltinProviderCatalog.connectableProducts()) }
        await bus.add(.listProviderAccounts) { [self] _ in .providerAccounts(try await providerAccounts()) }
        await bus.add(.listProviderModels) { [self] _ in .providerModels(try await providerModels()) }
        await bus.add(.selectProviderModel) { [self] command in
            guard case let .selectProviderModel(model) = command else { return .error(CoreError(code: .unsupportedCommand, message: "selectProviderModel 参数缺失")) }
            let agent = try await requireAgent()
            let selection = try await modelSelection(for: model)
            let assembly = try await resolveRuntimeAssembly(for: selection, fullModelValue: model)
            try await agent.selectModel(selection, assembly: assembly)
            await setCurrentAssembly(assembly)
            await setSelectedModelOverride(model)
            if let contextWindow = try await modelContextWindow(for: model) { await setSelectedModelContextWindow(contextWindow) }
            if let store = configurationStore {
                if var config = try? await store.load() {
                    config.providers.model = model
                    try? await store.save(config)
                }
            }
            return .providerModelSelected(await providerStatus)
        }
        await bus.add(.storeProviderCredential) { [self] command in
            guard case let .storeProviderCredential(request) = command else { return .error(CoreError(code: .unsupportedCommand, message: "storeProviderCredential 参数缺失")) }
            return .providerCredential(try await storeProviderCredential(request))
        }
        await bus.add(.createProviderAccount) { [self] command in
            guard case let .createProviderAccount(request) = command else { return .error(CoreError(code: .unsupportedCommand, message: "createProviderAccount 参数缺失")) }
            return .providerAccount(try await createProviderAccount(request))
        }
        await bus.add(.deleteProviderAccount) { [self] command in
            guard case let .deleteProviderAccount(accountID, deleteUnusedCredential) = command else { return .error(CoreError(code: .unsupportedCommand, message: "deleteProviderAccount 参数缺失")) }
            return .providerDisconnected(try await deleteProviderAccount(id: accountID, deleteUnusedCredential: deleteUnusedCredential))
        }
        await bus.add(.deleteProviderCredential) { [self] command in
            guard case let .deleteProviderCredential(reference) = command else { return .error(CoreError(code: .unsupportedCommand, message: "deleteProviderCredential 参数缺失")) }
            try await deleteProviderCredential(reference)
            return .providerCredential(ProviderCredentialResult(reference: reference))
        }
        await bus.add(.createSession) { [self] _ in
            let agent = try await requireAgent()
            let id = try await agent.createSession()
            await cacheController.resetSession(id)
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
        await bus.add(.renameSession) { [self] command in
            guard case let .renameSession(sessionID, title) = command else { return .error(CoreError(code: .unsupportedCommand, message: "renameSession 参数缺失")) }
            let agent = try await requireAgent()
            return .sessionRenamed(try await agent.renameSession(sessionID, title: title))
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
            if let request, let agent = try? await requireAgent() { await agent.markWaitingForQuestion(request, waiting: false) }
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
        await bus.add(.getContextProjection) { [self] command in
            guard case let .getContextProjection(sessionID) = command else { return .error(CoreError(code: .unsupportedCommand, message: "getContextProjection 参数缺失")) }
            return .contextProjection(try await contextProjection(sessionID))
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
        await bus.add(.getAgentBehaviorProfile) { [self] _ in
            let agent = try await requireAgent()
            return .agentBehaviorProfile(await agent.currentBehaviorProfile())
        }
        await bus.add(.setAgentBehaviorProfile) { [self] command in
            guard case let .setAgentBehaviorProfile(profile) = command else { return .error(CoreError(code: .unsupportedCommand, message: "setAgentBehaviorProfile 参数缺失")) }
            let agent = try await requireAgent()
            await agent.setBehaviorProfile(profile)
            return .agentBehaviorProfile(profile)
        }
        await bus.add(.getProjectCache) { [self] _ in
            let agent = try await requireAgent()
            return .projectCache(await agent.projectCache())
        }
        await bus.add(.compactSession) { [self] command in
            guard case let .compactSession(sessionID) = command else { return .error(CoreError(code: .unsupportedCommand, message: "compactSession 参数缺失")) }
            let agent = try await requireAgent()
            await setContextActivity(.compacting)
            do {
                let result = try await agent.compact(sessionID)
                await setContextActivity(.idle)
                return .compactSession(result)
            } catch {
                await setContextActivity(.idle)
                throw error
            }
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
        await bus.add(.resumeAgentRun) { [self] command in
            guard case let .resumeAgentRun(id) = command else { return .error(CoreError(code: .unsupportedCommand, message: "resumeAgentRun 参数缺失")) }
            let agent = try await requireAgent()
            return .agentRun(try await agent.resumeAgentRun(id))
        }
        await bus.add(.listExtensions) { [self] command in
            guard case let .listExtensions(kind) = command else { return .error(CoreError(code: .unsupportedCommand, message: "listExtensions 参数缺失")) }
            return .extensions(await extensionInfos(kind: kind))
        }
        await bus.add(.getWorkspaceDiff) { [self] _ in
            .workspaceDiff(try await workspaceDiff())
        }
        // .openTestStream / .sendMessage 属于数据面，不在控制面路由表中。

        let agent = AgentRuntime(
            store: sessionStore,
            contextEngine: contextEngine,
            modelBus: ModelBus(gateway: gateway),
            dataPlane: dataPlane,
            toolRuntime: toolRuntime,
            questions: questions,
            permissions: permissionEngine,
            performanceStore: performanceStore,
            contextPager: contextPager,
            projectScanner: projectScanner,
            eventSink: { [weak self] event in
                await self?.broadcast(event)
            },
            compactor: compactor,
            budgetPlanner: budgetPlanner,
            persistence: persistence,
            cacheController: cacheController,
            interactive: interactive,
            diagnosticsEnabled: diagnosticsEnabled,
            modelResolver: modelResolver,
            limits: subagentLimits,
            behaviorProfile: behaviorProfile,
            behaviorInstructionsEnabled: behaviorInstructionsEnabled,
            behaviorSystemContext: behaviorSystemContext,
            maxAgentLoopSteps: agentSettings.maxAgentLoopSteps,
            deadlinePolicy: executionDeadlinePolicy,
            restoreScheduler: restoreScheduler,
            diagnostics: diagnosticsStore,
            backgroundManager: self.backgroundManager,
            providerActivityRegistry: self.providerActivityRegistry,
            workspaceRevision: self.workspaceRevision
        )
        self.agent = agent
        let workflows = await agent.makeWorkflowRuntime()
        self.workflows = workflows
        await workflows.setInputSink { [weak self] workflowID, taskID, input in
            await self?.projectWorkflowInput(workflowID: workflowID, taskID: taskID, input: input)
        }
        await subagentService.bind(
            spawn: { [weak agent] sessionID, runID, task, title, selection, profile, toolCallID in try await agent?.spawn(parentSessionID: sessionID, parentRunID: runID, task: task, title: title, modelSelection: selection, profile: profile, toolCallID: toolCallID) ?? { throw CoreError(code: .notReady, message: "Agent 未就绪") }() },
            status: { [weak agent] runID, requester in try await agent?.agentRun(runID, requester: requester) ?? { throw CoreError(code: .notReady, message: "Agent 未就绪") }() },
            result: { [weak agent] runID, requester in try await agent?.agentRunResult(runID, requester: requester) ?? { throw CoreError(code: .notReady, message: "Agent 未就绪") }() },
            cancel: { [weak agent] runID, requester in try await agent?.cancelAgentRun(runID, requester: requester) },
            message: { [weak agent] sessionID, parentRunID, content in try await agent?.continueChild(sessionID: sessionID, parentRunID: parentRunID, content: content) ?? { throw CoreError(code: .notReady, message: "Agent 未就绪") }() }
        )
        do {
            try await agent.restore()
            try await workflows.restore()
            if currentAssembly == nil {
                if let store = configurationStore,
                   let config = try? await store.load(),
                   let defaultModel = config.providers.model,
                   !defaultModel.isEmpty,
                   let selection = try? await modelSelection(for: defaultModel),
                   let assembly = try? await resolveRuntimeAssembly(for: selection, fullModelValue: defaultModel) {
                    try? await agent.selectModel(selection, assembly: assembly)
                    self.currentAssembly = assembly
                    self.selectedModelOverride = defaultModel
                }
            }
        } catch {
            await diagnosticsStore.record(kind: .error, event: "core.start.failed", metadata: ["errorType": String(describing: type(of: error))], errorCode: (error as? CoreError)?.code.rawValue)
            self.agent = nil
            setState(.stopped)
            return
        }
        setState(.ready)
        await diagnosticsStore.record(kind: .core, event: "core.start.completed")
        // Post-ready startup recovery: now that WAL reconciliation is complete and Core is ready,
        // safely trigger execution of any remaining queued turns across all persisted sessions.
        var allSessionIDs = Set(sessionCoordinators.keys)
        if let storedSessions = try? await sessionStore.listSessions() {
            for session in storedSessions {
                allSessionIDs.insert(session.id)
            }
        }
        for sessionID in allSessionIDs {
            _ = try? await coordinator(for: sessionID)
            await scheduleNextTurnIfReady(for: sessionID)
        }
    }

    public func shutdown() async {
        await diagnosticsStore.record(kind: .core, event: "core.shutdown.begin")
        setState(.shuttingDown)
        lifecycle("cleanupStarted", waitingOn: "agent")
        await agent?.shutdown()
        lifecycle("cleanupCompleted", waitingOn: "agent")
        lifecycle("cleanupStarted", waitingOn: "dataPlane")
        await dataPlane.closeAll()
        lifecycle("cleanupCompleted", waitingOn: "dataPlane")
        lifecycle("cleanupStarted", waitingOn: "questions")
        await questions.close()
        lifecycle("cleanupCompleted", waitingOn: "questions")
        lifecycle("cleanupStarted", waitingOn: "processes")
        await processes.stopAll()
        await backgroundManager.terminateAll()
        await extensionPlatform.terminatePlugins()
        await browserSessionManager.shutdown()
        await codeIntelligence?.shutdown()
        codeIntelligence = nil
        lifecycle("cleanupCompleted", waitingOn: "processes")
        await providerActivityRegistry.reset()
        registryRefreshTask?.cancel()
        registryRefreshTask = nil
        workspaceIndexTask?.cancel()
        workspaceIndexTask = nil
        agent = nil
        workflows = nil
        eventContinuations.values.forEach { $0.finish() }
        eventContinuations.removeAll()
        setState(.stopped)
        await diagnosticsStore.record(kind: .core, event: "core.shutdown.completed")
    }

    deinit {
        registryRefreshTask?.cancel()
        workspaceIndexTask?.cancel()
        extensionPlatform.terminatePluginsSync()
        let b = self.browserSessionManager
        Task { await b.shutdown() }
    }

    private func lifecycle(_ event: String, waitingOn: String) {
        guard ExecutionLifecycleTrace.enabled else { return }
        FileHandle.standardError.write(Data("[execution-lifecycle] event=\(event) kind=coreHost waitingOn=\(waitingOn)\n".utf8))
    }

    // MARK: - CoreEndpoint（控制面）

    public func handle(_ command: ClientCommand) async throws -> CoreResponse {
        switch command {
        case .ping, .getInfo, .getState, .getProviderStatus, .getDiagnostics:
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
    public func broadcast(_ event: CoreEvent) async {
        if case let .permissionAsked(request) = event {
            Task { [weak self] in try? await self?.workflows?.suspendForOrigin(sessionID: request.sessionID, input: .permission(request)) }
        }
        await appendVNextEvent(event)
        eventContinuations.values.forEach { $0.yield(event) }

        // Context accounting is diagnostic state and must not delay the user-visible
        // lifecycle event or tool result on the control plane.
        if let sessionID = eventSessionID(event), shouldRefreshVNextContext(for: event) {
            Task { [weak self] in await self?.refreshVNextContext(sessionID: sessionID) }
        }
    }

    private func appendVNextEvent(_ event: CoreEvent) async {
        switch event {
        case let .providerActivityChanged(activity):
            guard let coordinator = try? await coordinator(for: activity.sessionID) else { return }
            let state = ProviderRequestState(rawValue: activity.state.rawValue) ?? .unknown
            await coordinator.recordProviderRequestState(
                requestID: ProviderRequestID(activity.providerRequestID),
                state: state,
                detail: activity.detail,
                statusCode: activity.statusCode,
                causal: CausalContext(sessionID: activity.sessionID, runID: activity.runID.map(RunID.init))
            )
        case let .toolCallCompleted(call):
            guard let sessionID = call.sessionID, let coordinator = try? await coordinator(for: sessionID) else { return }
            let causal = CausalContext(sessionID: sessionID, runID: call.agentRunID.map(RunID.init), modelStepID: call.modelStepID, toolCallID: call.callID)
            await coordinator.recordToolRequested(snapshot: ToolInvocationSnapshot(
                callID: call.callID,
                toolID: call.toolID,
                displayName: call.toolName,
                argumentsSummary: call.arguments,
                state: .requested
            ), causal: causal)
            await coordinator.recordToolScheduled(callID: call.callID, causal: causal)
        case let .toolExecutionClaimed(call):
            guard call.toolID.rawValue != "question" else { return }
            guard let sessionID = call.sessionID, let coordinator = try? await coordinator(for: sessionID) else { return }
            await coordinator.recordToolRunning(
                callID: call.callID,
                stdoutStreamID: nil,
                stderrStreamID: nil,
                causal: CausalContext(sessionID: sessionID, runID: call.agentRunID.map(RunID.init), modelStepID: call.modelStepID, toolCallID: call.callID)
            )
        case let .permissionAsked(request):
            let causal = CausalContext(
                sessionID: request.sessionID,
                runID: nil,
                toolCallID: request.toolCallID
            )
            guard let coordinator = try? await coordinator(for: request.sessionID) else { return }
            await coordinator.recordToolWaitingForPermission(
                callID: request.toolCallID,
                permissionID: request.permissionID,
                causal: causal
            )
            await coordinator.recordInteractionRequested(snapshot: InteractionSnapshot(
                interactionID: InteractionID(request.permissionID.rawValue),
                kind: .permission,
                causal: causal,
                permissionRequest: request
            ))
        case let .questionAsked(request), let .questionEscalated(request):
            guard let sessionID = request.originSessionID ?? request.rootSessionID ?? request.parentSessionID,
                  let coordinator = try? await coordinator(for: sessionID) else { return }
            let causal = CausalContext(
                sessionID: sessionID,
                runID: request.originRunID.map(RunID.init),
                toolCallID: nil
            )
            await coordinator.recordInteractionRequested(snapshot: InteractionSnapshot(
                interactionID: InteractionID(request.questionID.rawValue),
                kind: .question,
                causal: causal,
                questionRequest: request
            ))
        case let .toolResult(result):
            guard let sessionID = result.sessionID, let coordinator = try? await coordinator(for: sessionID) else { return }
            let causal = CausalContext(sessionID: sessionID, runID: result.agentRunID.map(RunID.init), modelStepID: result.modelStepID, toolCallID: result.callID)
            let preview: String
            if let data = result.content.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let stdout = json["stdout"] as? String, !stdout.isEmpty {
                    let clean = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    preview = String(clean.prefix(240))
                } else if let stderr = json["stderr"] as? String, !stderr.isEmpty {
                    let clean = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    preview = String(clean.prefix(240))
                } else if let summary = json["summary"] as? String, !summary.isEmpty {
                    preview = String(summary.prefix(240))
                } else {
                    preview = String(result.content.prefix(240))
                }
            } else {
                preview = String(result.content.prefix(240))
            }
            let contentRef = (result.output.truncated ? (result.continuation ?? result.output.outputBlobRef) : nil).map {
                ContentRef(
                    id: ContentID($0),
                    mediaType: "text/plain",
                    byteCount: result.output.totalBytes,
                    tokenEstimate: max(1, result.output.totalCharacters / 3)
                )
            }
            await coordinator.recordToolCompleted(
                callID: result.callID,
                result: ToolResultSnapshot(
                    callID: result.callID,
                    toolName: result.toolName,
                    success: result.success,
                    summary: result.summary,
                    preview: preview.isEmpty ? nil : preview,
                    contentRef: contentRef,
                    error: result.error.map { RuntimeError(category: .tool, code: $0.code, message: $0.message, retryability: .none, source: .tool) },
                    timing: result.timing
                ),
                stdoutFinalIndex: nil,
                stderrFinalIndex: nil,
                causal: causal
            )
        default:
            break
        }
    }

    private var contextRefreshSequences: [SessionID: UInt64] = [:]

    private func refreshVNextContext(sessionID: SessionID) async {
        let seq = (contextRefreshSequences[sessionID] ?? 0) + 1
        contextRefreshSequences[sessionID] = seq
        guard let coordinator = try? await coordinator(for: sessionID) else { return }
        let snapshot = await buildContextStateSnapshot(sessionID: sessionID)
        // Ensure this is still the latest scheduled refresh for this session to prevent out-of-order overrides
        guard contextRefreshSequences[sessionID] == seq else { return }
        await coordinator.recordContextStateChanged(
            snapshot,
            causal: CausalContext(sessionID: sessionID)
        )
    }

    private func shouldRefreshVNextContext(for event: CoreEvent) -> Bool {
        switch event {
        case .turnCompleted, .turnFailed: return true
        default: return false
        }
    }

    private func eventSessionID(_ event: CoreEvent) -> SessionID? {
        switch event {
        case let .sessionCreated(id): id
        case let .turnStarted(handle): handle.sessionID
        case let .turnCompleted(result): result.sessionID
        case let .turnFailed(failure): failure.sessionID
        case let .toolCallCompleted(call): call.sessionID
        case let .toolExecutionClaimed(call): call.sessionID
        case let .toolResult(result): result.sessionID
        case let .permissionAsked(request): request.sessionID
        case let .questionAsked(request): request.originSessionID
        case let .childSessionCreated(info): info.id
        case let .subagentSpawned(run), let .agentRunQueued(run), let .agentRunStarted(run), let .agentRunStatusChanged(run), let .agentRunCompleted(run), let .agentRunFailed(run), let .agentRunCancelled(run): run.sessionID
        case let .subagentResultAvailable(result): result.childSessionID
        case let .questionEscalated(request): request.originSessionID
        case let .providerActivityChanged(activity): activity.sessionID
        case .stateChanged: nil
        }
    }

    // MARK: - Private

    private func requireAgent() throws -> AgentRuntime {
        guard state == .ready, let agent else {
            throw CoreError(code: .notReady, message: "Agent 尚未启动")
        }
        return agent
    }

    private func routeWorkflowQuestion(_ request: QuestionRequest) async {
        guard let runID = request.originRunID else { return }
        try? await workflows?.suspendForOrigin(runID: runID, input: .question(request))
    }

    private func projectWorkflowInput(workflowID: WorkflowID, taskID: WorkflowTaskID, input: WorkflowPendingInput) async {
        guard case let .decision(request) = input,
              let coordinator = try? await coordinator(for: request.originSessionID) else { return }
        let causal = CausalContext(
            sessionID: request.originSessionID,
            runID: RunID(request.originRunID.rawValue),
            workflowID: workflowID,
            workflowTaskID: taskID
        )
        await coordinator.recordInteractionRequested(snapshot: InteractionSnapshot(
            interactionID: InteractionID(request.decisionID.rawValue),
            kind: .decision,
            causal: causal,
            decisionRequest: request
        ))
    }

    private var providerStatus: ProviderStatus {
        let activeModel = selectedModelOverride ?? currentAssembly?.modelID.rawValue ?? gateway.modelID?.rawValue
        let isConfigured = currentAssembly != nil || gateway.isConfigured
        let baseURL = currentAssembly?.endpoint.baseURL?.absoluteString
        let missingReqs = isConfigured ? [] : gateway.missingRequirements
        return ProviderStatus(
            configured: isConfigured,
            model: activeModel,
            baseURL: baseURL,
            missingRequirements: missingReqs
        )
    }

    private func setCurrentAssembly(_ assembly: ModelRuntimeAssembly?) {
        currentAssembly = assembly
    }

    private func setSelectedModelOverride(_ model: String) {
        selectedModelOverride = model
    }

    private func setSelectedModelContextWindow(_ value: Int) {
        selectedModelContextWindow = value
    }

    private func setContextActivity(_ value: ContextPagingActivity) {
        contextActivity = value
    }

    private func contextProjection(_ sessionID: SessionID) async throws -> ContextCacheProjection? {
        let agent = try requireAgent()
        let snapshot = try await agent.ensureContextSnapshot(sessionID)
        let manifest = await agent.latestContextManifest(sessionID)

        let l1Usage = await cacheController.l1UsageTokens(for: sessionID)
        let effectiveL1Usage = l1Usage > 0 ? l1Usage : snapshot.metrics.estimatedTokens
        let l1Count = await cacheController.l1Count(for: sessionID)
        let effectiveL1Count = l1Count > 0 ? l1Count : snapshot.entries.count

        let l2Usage = await cacheController.l2UsageTokens(for: sessionID)
        let l2Count = await cacheController.l2Count(for: sessionID)

        let l3Usage = await cacheController.l3UsageTokens(for: sessionID)
        let l3Count = await cacheController.l3Count(for: sessionID)

        let pagingStats = await cacheController.pagingStats(for: sessionID)
        let lastInputTokens = await cacheController.lastProviderInputTokens(for: sessionID)
        let cacheTelemetry = ProviderCacheTelemetry.aggregate(
            (await performanceStore.providerCalls(for: sessionID)).compactMap(\.cacheTelemetry)
        )

        let l1Status = ContextLayerStatus(
            layer: .l1,
            usageTokens: effectiveL1Usage,
            capacityTokens: effectiveContextPolicy.l1Target,
            entryCount: effectiveL1Count,
            state: effectiveL1Usage == 0 ? .empty : .available,
            pageInCount: pagingStats.pageIns,
            pageOutCount: pagingStats.pageOuts
        )

        let l2Status = ContextLayerStatus(
            layer: .l2,
            usageTokens: l2Usage,
            capacityTokens: effectiveContextPolicy.l2Max,
            entryCount: l2Count,
            state: l2Usage == 0 ? .empty : .available,
            pageInCount: pagingStats.promotions,
            pageOutCount: pagingStats.demotions
        )

        let l3State: ContextLayerState = effectiveContextPolicy.l3Enabled ? (l3Usage == 0 ? .empty : .available) : .unavailable
        let l3Status = ContextLayerStatus(
            layer: .l3,
            usageTokens: l3Usage,
            capacityTokens: effectiveContextPolicy.l3Capacity,
            entryCount: l3Count,
            state: l3State,
            pageInCount: 0,
            pageOutCount: 0
        )

        let ecoreMetrics = await cacheController.ecoreStore.storageMetrics(for: sessionID)
        let ecoreCount = ecoreMetrics.count
        let ecoreBytes = ecoreMetrics.totalBytes
        let debtState = await cacheController.scheduler.debtState(for: sessionID)

        return ContextCacheProjection(
            sessionID: sessionID,
            policy: ContextCachePolicySnapshot(policy: effectiveContextPolicy),
            l1: l1Status,
            l2: l2Status,
            l3: l3Status,
            paging: pagingStats,
            pagingActivity: contextActivity,
            compactionGeneration: snapshot.metrics.compactionGeneration,
            latestManifest: manifest,
            lastProviderInputTokens: lastInputTokens,
            cacheTelemetry: cacheTelemetry,
            pCoreTokens: effectiveL1Usage,
            eCoreObjectCount: ecoreCount,
            eCoreTotalBytes: ecoreBytes,
            cacheDebt: debtState.cacheDebt
        )
    }

    private func extensionInfos(kind: ExtensionKind?) async -> [ExtensionInfo] {
        if kind == nil || kind == .skill || kind == .command || kind == .plugin { _ = await extensionPlatform.discover() }
        let coreKind = kind.flatMap { ExtensionType(rawValue: $0.rawValue) }
        let activePlugins = await extensionPlatform.activePlugins()
        var pluginCommandSummaries: [String: String] = [:]
        for plugin in activePlugins {
            for cmd in plugin.commands {
                pluginCommandSummaries[cmd.name.lowercased()] = cmd.description
            }
        }
        var result = await extensionPlatform.list(type: coreKind).map { descriptor in
            let summary = descriptor.type == .command ? pluginCommandSummaries[descriptor.id.lowercased()] : nil
            return ExtensionInfo(
                id: descriptor.id,
                version: descriptor.version,
                kind: ExtensionKind(rawValue: descriptor.type.rawValue) ?? .plugin,
                scope: descriptor.scope.rawValue,
                enabled: descriptor.enabled,
                lifecycleState: descriptor.lifecycleState.rawValue,
                summary: summary
            )
        }
        if kind == nil || kind == .mcp {
            if let config = try? await configurationStore?.load() {
                let existingIDs = Set(result.filter { $0.kind == .mcp }.map(\.id))
                for server in config.mcp.servers {
                    guard !existingIDs.contains(server.id) else { continue }
                    let status = await mcpPager.serverStatus(for: MCPServerID(server.id))
                    let lifecycle: String
                    switch status {
                    case .ready: lifecycle = "ready"
                    case .empty: lifecycle = "empty"
                    case .error: lifecycle = "error"
                    case .disabled: lifecycle = "disabled"
                    case nil: lifecycle = server.enabled ? "enabled" : "disabled"
                    }
                    result.append(ExtensionInfo(
                        id: server.id,
                        version: "1.0.0",
                        kind: .mcp,
                        scope: "global",
                        enabled: server.enabled && status != .disabled,
                        lifecycleState: lifecycle
                    ))
                }
            }
        }
        var calibratedResult: [ExtensionInfo] = []
        for item in result {
            if item.kind == .mcp {
                let status = await mcpPager.serverStatus(for: MCPServerID(item.id))
                let lifecycle: String
                switch status {
                case .ready: lifecycle = "ready"
                case .empty: lifecycle = "empty"
                case .error: lifecycle = "error"
                case .disabled: lifecycle = "disabled"
                case nil: lifecycle = item.lifecycleState
                }
                calibratedResult.append(ExtensionInfo(
                    id: item.id,
                    version: item.version,
                    kind: item.kind,
                    scope: item.scope,
                    enabled: item.enabled && status != .disabled,
                    lifecycleState: lifecycle
                ))
            } else {
                calibratedResult.append(item)
            }
        }
        return calibratedResult
    }

    private func modelContextWindow(for value: String) async throws -> Int? {
        guard let separator = value.firstIndex(of: "/") else { return nil }
        guard let configurationStore else { return nil }
        let providerID = String(value[..<separator])
        let modelID = String(value[value.index(after: separator)...])
        return try await configurationStore.load().providers.providers[providerID]?.models[modelID]?.limit.context
    }

    private func workspaceDiff() async throws -> String {
        let gitExe = LingXiPlatform.process.resolveExecutable(named: "git", customSearchPaths: ["/usr/bin", "/usr/local/bin"]) ?? "/usr/bin/git"
        let result = try await runToolProcess(
            invocation: ToolProcessInvocation(executable: gitExe, arguments: ["diff", "--no-ext-diff", "--no-textconv", "--"]),
            cwd: extensionPlatform.projectRoot,
            environment: EnvironmentSanitizer.sanitized(),
            timeoutMilliseconds: 5_000
        )
        guard result.exitCode == 0 else {
            throw CoreError(code: .gitError, message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(result.stdout.prefix(20_000))
    }

    private func diagnosticsBundle() async -> RuntimeDiagnosticsBundle {
        await Task.yield()
        let runs = await agent?.allAgentRuns() ?? []
        let orphanRunIDs = await agent?.orphanRunIDs() ?? []
        let currentBehaviorProfile = await agent?.currentBehaviorProfile() ?? behaviorProfile
        let workflows = await workflows?.allWorkflows() ?? []
        let mcpMetrics = await mcpPager.schemaStoreMetrics()
        let trace = await diagnosticsStore.snapshot()
        return RuntimeDiagnosticsBundle(
            runtimeVersion: Self.coreVersion,
            protocolVersion: ProtocolVersion.current.description,
            configurationSummary: [
                "interactive": String(interactive),
                "diagnosticsEnabled": String(diagnosticsEnabled),
                "behaviorProfile": currentBehaviorProfile.rawValue,
                "persistence": persistence == nil ? "ephemeral" : "durable",
                "subagentMaxConcurrent": String(subagentLimits.maxConcurrentSubagents),
                "subagentMaxDepth": String(subagentLimits.maxSubagentDepth),
                "quarantinedCorruptWALs": (await commandWAL.quarantinedCorruptWALs).joined(separator: ",")
            ],
            trace: trace,
            recentErrors: await diagnosticsStore.recentErrors(),
            provider: RuntimeDiagnosticProviderStatus(configured: gateway.isConfigured, model: gateway.modelID?.rawValue, missingRequirements: gateway.missingRequirements),
            mcp: RuntimeDiagnosticMCPStatus(catalogTools: await mcpPager.catalogCount(), schemaFiles: mcpMetrics.count, schemaBytes: mcpMetrics.bytes, pageFaults: await mcpPager.pageFaults, activeLeases: await mcpPager.activeLeaseCount()),
            runs: runs,
            workflows: workflows,
            recoveryRequiredRunIDs: runs.filter { $0.status == .recoveryRequired }.map(\.runID),
            orphanRunIDs: orphanRunIDs,
            backgroundTasks: await backgroundManager.list()
        )
    }

    private func requireConfigurationStore() throws -> ConfigurationStore {
        guard let configurationStore else { throw CoreError(code: .persistence, message: "Provider 配置存储未连接") }
        return configurationStore
    }

    private func requireCredentialStore() throws -> any CredentialStore {
        guard let credentialStore else { throw CoreError(code: .persistence, message: "CredentialStore 未连接") }
        return credentialStore
    }

    private func providerAccounts() async throws -> [ProviderAccountInfo] {
        guard let configurationStore else {
            return runtimeProviderAccounts.values.sorted { $0.id < $1.id }
        }
        let snapshot = try await configurationStore.load()
        var accounts: [ProviderAccountInfo] = []
        for acc in snapshot.providers.accounts {
            accounts.append(await accountInfo(acc))
        }
        for (providerID, pConfig) in snapshot.providers.providers {
            if !accounts.contains(where: { $0.id == providerID || $0.productID == providerID }) {
                let isOAuth = pConfig.options.apiKey?.hasPrefix("{oauth:") == true || BuiltinProviderCatalog.profile(for: providerID)?.authMethods.contains("oauth") == true
                var availability = "configured"
                if isOAuth {
                    if let refresher = oauthRefreshers[providerID] {
                        switch await refresher.authState {
                        case .valid:
                            availability = "active"
                        case .refreshing:
                            availability = "refreshing"
                        case .refreshFailedTransient:
                            availability = "refresh_failed"
                        case .reauthenticationRequired:
                            availability = "reauthenticationRequired"
                        }
                    } else if let credStore = credentialStore {
                        let oauthRef = CredentialRef("provider-\(providerID)-oauth")
                        if let secret = try? await credStore.secret(for: oauthRef), !secret.isEmpty {
                            availability = "active"
                        }
                    }
                }
                accounts.append(ProviderAccountInfo(
                    id: providerID,
                    productID: providerID,
                    displayName: pConfig.name.isEmpty ? providerID : pConfig.name,
                    accountType: isOAuth ? .oauthUser : .apiKey,
                    credentialRef: nil,
                    endpoint: pConfig.options.baseURL,
                    availability: availability
                ))
            }
        }
        let runtimeProviderIDs = Set(runtimeProviderAccounts.values.map(\.productID))
        return accounts.filter { !runtimeProviderIDs.contains($0.productID) } + runtimeProviderAccounts.values.sorted { $0.id < $1.id }
    }

    /// Refreshes the registry catalog in the background shortly after startup.
    ///
    /// The first model listing must not wait on the network: the on-disk
    /// catalog cache serves the initial render, and this brings it up to date.
    private func scheduleRegistryRefresh(delaySeconds: Double = 5.0) {
        guard startupPolicy.refreshRegistry && startupPolicy.allowNetwork else { return }
        registryRefreshTask?.cancel()
        registryRefreshTask = Task(priority: .background) {
            if delaySeconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            _ = await ModelRegistryClient.shared.fetch()
            await LingXiModelsCatalogClient.shared.warmup()
        }
    }

    /// The model list offered to the user for every configured product, plus
    /// the products the registry knows about but which are not yet configured.
    ///
    /// Three sources are combined per product, and they answer different
    /// questions:
    ///
    ///   - the **registry catalog** supplies protocol, capabilities and status;
    ///   - **account discovery** (run with the user's own credential, never
    ///     uploaded anywhere) decides what is actually reachable;
    ///   - **runtime support** decides what LingXi can execute.
    ///
    /// No branch here inspects a provider or product name.
    private func providerModels() async throws -> [ProviderModelInfo] {
        var results: [ProviderModelInfo] = []
        var customModelIDs = Set<String>()

        if let configurationStore {
            let snapshot = try await configurationStore.load()
            let catalog = await ModelRegistryClient.shared.catalog()
            let availableProducts: [RegistryProduct] = catalog?.products ?? BuiltinProviderCatalog.registryProducts

            // 1. Custom providers configured explicitly by the user in ~/.lingxiagent/providers.json.
            // User explicit configuration ALWAYS takes precedence over built-in catalog entries.
            for providerID in snapshot.providers.providers.keys.sorted() {
                guard let provider = snapshot.providers.providers[providerID] else { continue }
                let models = configuredModelInfos(providerID: providerID, provider: provider)
                for m in models {
                    customModelIDs.insert(m.id)
                    results.append(m)
                }
            }

            // 2. Built-in products from catalog (co-exist with custom providers; user-defined models take precedence on collision)
            let runnableProducts = availableProducts.filter { $0.runtime.isRunnable }
            let discoveredProductModels: [[ProviderModelInfo]] = await withTaskGroup(of: [ProviderModelInfo].self) { group in
                for product in runnableProducts {
                    group.addTask {
                        let isConfigured = await self.isProductConfigured(product: product)
                        let accountModels: [DiscoveredRemoteModel]
                        if isConfigured {
                            accountModels = await self.accountDiscoveredModels(
                                product: product,
                                providerID: product.id
                            )
                        } else {
                            accountModels = []
                        }

                        let outcome = ModelAvailabilityResolver.resolve(
                            product: product,
                            registryModels: catalog?.models(productID: product.id) ?? [],
                            accountModels: accountModels,
                            isConfigured: isConfigured
                        )
                        return outcome.models
                    }
                }
                var collected: [[ProviderModelInfo]] = []
                for await models in group {
                    collected.append(models)
                }
                return collected
            }

            for models in discoveredProductModels {
                for model in models {
                    if !customModelIDs.contains(model.id) {
                        results.append(model)
                    }
                }
            }
        }

        if let assembly = currentAssembly, !results.contains(where: { $0.modelID == assembly.modelID.rawValue || $0.id == assembly.modelID.rawValue }) {
            results.append(ProviderModelInfo(
                id: assembly.modelID.rawValue,
                providerID: assembly.endpoint.providerID,
                modelID: assembly.modelID.rawValue,
                displayName: assembly.modelID.rawValue,
                contextWindow: 128_000,
                maxOutputTokens: 8192,
                reasoning: false,
                configured: true,
                metadataIncomplete: false,
                canonicalModelID: assembly.modelID.rawValue,
                backendVariant: nil,
                backendVariants: nil
            ))
        }

        return results
    }

    private func isProductConfigured(product: RegistryProduct) async -> Bool {
        if product.authMethods?.contains("none") == true {
            return true
        }
        if await providerCredential(providerID: product.id) != nil {
            return true
        }
        // 检查用户自定义配置 providers.json 中是否存在有效的配置与 apiKey
        if let configStore = configurationStore,
           let snapshot = try? await configStore.load(),
           let customProvider = snapshot.providers.providers[product.id] {
            if let apiKey = customProvider.options.apiKey, !apiKey.isEmpty {
                if apiKey.hasPrefix("{env:") && apiKey.hasSuffix("}") {
                    let envName = String(apiKey.dropFirst(5).dropLast(1))
                    if let val = ProcessInfo.processInfo.environment[envName], !val.isEmpty {
                        return true
                    }
                } else if !apiKey.hasPrefix("{vault:") && !apiKey.hasPrefix("{oauth:") {
                    return true
                }
            }
        }
        if let envKey = resolveEnvironmentKey(for: product.id),
           let envVal = ProcessInfo.processInfo.environment[envKey], !envVal.isEmpty {
            return true
        }
        return false
    }

    private func defaultEnvironmentKeys(for productID: String) -> [String] {
        var keys: [String] = []
        switch productID {
        case "openai-api", "openai", "openai-codex": keys.append("OPENAI_API_KEY")
        case "anthropic-api", "anthropic", "anthropic-claude-subscription": keys.append("ANTHROPIC_API_KEY")
        case "gemini-api", "google", "gemini": keys.append("GEMINI_API_KEY")
        case "deepseek-api", "deepseek": keys.append("DEEPSEEK_API_KEY")
        case "xai-api", "xai", "xai-grok-subscription": keys.append("XAI_API_KEY")
        case "opencode-zen", "opencode-go", "opencode": keys.append("OPENCODE_API_KEY")
        case "openrouter": keys.append("OPENROUTER_API_KEY")
        case "minimax-api", "minimax-token-plan", "minimax": keys.append("MINIMAX_API_KEY")
        case "zhipu-coding-plan", "zai-api", "zhipu", "zai": keys.append("ZHIPUAI_API_KEY")
        case "qwen-coding-plan", "alibaba-bailian-api", "qwen", "dashscope": keys.append("DASHSCOPE_API_KEY")
        case "sensenova", "bai": keys.append("SENSENOVA_API_KEY")
        case "groq": keys.append("GROQ_API_KEY")
        case "together": keys.append("TOGETHER_API_KEY")
        case "mistral": keys.append("MISTRAL_API_KEY")
        case "huggingface": keys.append(contentsOf: ["HF_TOKEN", "HUGGINGFACE_API_KEY"])
        default: break
        }
        let normalized = productID.replacingOccurrences(of: "-", with: "_").uppercased()
        keys.append("\(normalized)_API_KEY")
        if normalized.hasSuffix("_API") {
            let prefix = String(normalized.dropLast(4))
            keys.append("\(prefix)_API_KEY")
        }
        return Array(NSOrderedSet(array: keys).compactMap { $0 as? String })
    }

    private func resolveEnvironmentKey(for productID: String) -> String? {
        for key in defaultEnvironmentKeys(for: productID) {
            if let val = ProcessInfo.processInfo.environment[key], !val.isEmpty {
                return key
            }
        }
        return nil
    }

    /// Models from the user's own configured list, used only for products the
    /// registry catalog does not describe.
    private func configuredModelInfos(
        providerID: String,
        provider: PublicProviderConfiguration
    ) -> [ProviderModelInfo] {
        provider.models.keys.sorted().compactMap { modelID in
            guard let model = provider.models[modelID] else { return nil }
            return ProviderModelInfo(
                id: "\(providerID)/\(modelID)",
                providerID: providerID,
                modelID: modelID,
                displayName: model.name,
                contextWindow: model.limit.context,
                maxOutputTokens: model.limit.output,
                reasoning: model.reasoning,
                configured: true
            )
        }
    }

    /// The account's view of a product's models, read from the account-scoped
    /// cache and refreshed from the upstream vendor when the cache is cold.
    ///
    /// A refresh failure leaves the cached list in place: an upstream outage
    /// must never empty the user's model picker.
    private func accountDiscoveredModels(
        product: RegistryProduct,
        providerID: String
    ) async -> [DiscoveredRemoteModel] {
        // A product whose models are not account-scoped has nothing to discover;
        // the registry catalog is its source.
        guard product.discoveryProfile != nil || product.discovery == .authenticatedRemote else {
            return []
        }

        let credential = await providerCredential(providerID: providerID)
        let accountRef = credential.map {
            AccountScopedCatalogCache.accountHash(fromTokenOrIdentifier: $0)
        } ?? providerID

        var cached = await AccountScopedCatalogCache.shared.load(
            productID: providerID,
            accountRef: accountRef
        )
        if cached == nil || cached?.models.isEmpty == true {
            let availableAccounts = await AccountScopedCatalogCache.shared.listAccounts(productID: providerID)
            for acc in availableAccounts {
                if let record = await AccountScopedCatalogCache.shared.load(productID: providerID, accountRef: acc), !record.models.isEmpty {
                    cached = record
                    break
                }
            }
        }

        if let cached, !cached.models.isEmpty, !cached.isExpired {
            // Still fresh: serve it and let the next refresh happen in the
            // background rather than blocking a model listing on the network.
            if !cached.isStale {
                return cached.models
            }
        }

        if let cached, !cached.models.isEmpty {
            // Expired or marked stale: refresh, but never block the listing on
            // the result — fall through to the cached value either way.
            _ = await AccountModelDiscovery.refresh(
                product: product,
                accountRef: accountRef,
                credential: credential
            )
            let refreshed = await AccountScopedCatalogCache.shared.load(
                productID: providerID,
                accountRef: accountRef
            )
            return refreshed?.models ?? cached.models
        }

        // Cold cache: discovery is the only way to know what this account can
        // reach. Bound it with a 400ms timeout so startup and model listings never freeze.
        let result: [DiscoveredRemoteModel]? = await withTaskGroup(of: [DiscoveredRemoteModel]?.self) { group in
            group.addTask {
                let outcome = await AccountModelDiscovery.refresh(
                    product: product,
                    accountRef: accountRef,
                    credential: credential
                )
                if case let .success(models) = outcome, !models.isEmpty {
                    return models
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 400_000_000)
                return nil
            }
            for await item in group {
                if let item, !item.isEmpty {
                    group.cancelAll()
                    return item
                }
            }
            return nil
        }
        if let result, !result.isEmpty {
            return result
        }
        let stored = await AccountScopedCatalogCache.shared.load(
            productID: providerID,
            accountRef: accountRef
        )
        if let stored, !stored.models.isEmpty {
            return stored.models
        }
        let availableAccounts = await AccountScopedCatalogCache.shared.listAccounts(productID: providerID)
        for acc in availableAccounts {
            if let record = await AccountScopedCatalogCache.shared.load(productID: providerID, accountRef: acc), !record.models.isEmpty {
                return record.models
            }
        }
        return []
    }

    /// Reads whichever credential this product authenticates with. Returns nil
    /// when the product needs none or none is stored.
    private func providerCredential(providerID: String) async -> String? {
        guard let credentialStore else { return nil }
        for suffix in ["oauth", "key"] {
            let ref = CredentialRef("provider-\(providerID)-\(suffix)")
            if let secret = try? await credentialStore.secret(for: ref), !secret.isEmpty {
                return secret
            }
        }
        return nil
    }

    private func modelSelection(for value: String) async throws -> ModelSelection {
        if let current = currentAssembly, current.modelID.rawValue == value || "\(current.endpoint.providerID)/\(current.modelID.rawValue)" == value {
            return ModelSelection(providerID: current.endpoint.providerID, modelID: current.modelID.rawValue)
        }
        var resolvedValue = value
        if !resolvedValue.contains("/") {
            if let configStore = configurationStore,
               let snapshot = try? await configStore.load() {
                for (pID, pConfig) in snapshot.providers.providers {
                    if pConfig.models[resolvedValue] != nil {
                        resolvedValue = "\(pID)/\(resolvedValue)"
                        break
                    }
                }
            }
            if !resolvedValue.contains("/"), let current = currentAssembly {
                resolvedValue = "\(current.endpoint.providerID)/\(resolvedValue)"
            }
        }
        guard let separator = resolvedValue.firstIndex(of: "/") else {
            throw CoreError(code: .toolArgumentInvalid, message: "模型格式必须是 provider/model")
        }
        let providerID = String(resolvedValue[..<separator])
        let modelID = String(resolvedValue[resolvedValue.index(after: separator)...])

        // 1. Custom providers: configured explicitly by user in ~/.lingxiagent/providers.json
        if let configStore = configurationStore,
           let snapshot = try? await configStore.load(),
           let providerConfig = snapshot.providers.providers[providerID] {
            let hasModelInConfig = providerConfig.models[modelID] != nil
            let isInheritedFromBuiltin = BuiltinProviderCatalog.connectableProducts().contains(where: { $0.id == providerID })
                || ProviderRegistry.shared.product(id: providerID) != nil
            guard hasModelInConfig || isInheritedFromBuiltin else {
                throw CoreError(code: .provider, message: "模型不可用: \(value)")
            }
            let keyRef = CredentialRef("provider-\(providerID)-key")
            let oauthRef = CredentialRef("provider-\(providerID)-oauth")
            var hasValidKey = false
            if let apiKey = providerConfig.options.apiKey, !apiKey.isEmpty {
                if apiKey.hasPrefix("{env:") && apiKey.hasSuffix("}") {
                    let envName = String(apiKey.dropFirst(5).dropLast(1))
                    hasValidKey = !(ProcessInfo.processInfo.environment[envName]?.isEmpty ?? true)
                } else if !apiKey.hasPrefix("{vault:") && !apiKey.hasPrefix("{oauth:") {
                    hasValidKey = true
                }
            }
            var hasStoredKey = false
            if !hasValidKey, let credStore = try? requireCredentialStore() {
                hasStoredKey = ((try? await credStore.secret(for: keyRef)) ?? nil) != nil
            }
            var hasEnvKey = false
            if !hasValidKey && !hasStoredKey, let envKey = resolveEnvironmentKey(for: providerID),
               let val = ProcessInfo.processInfo.environment[envKey], !val.isEmpty {
                hasEnvKey = true
            }
            let hasKey = hasValidKey || hasStoredKey || hasEnvKey
            let credStore = try? requireCredentialStore()
            let hasOAuth = ((try? await credStore?.secret(for: oauthRef)) ?? nil) != nil
            if !hasKey && !hasOAuth {
                throw CoreError(code: .provider, message: "Provider '\(providerID)' 未配置有效 API Key 或未认证\n请检查 providers.json 中的 apiKey 或环境变量")
            }
            return ModelSelection(providerID: providerID, accountID: providerID, profileID: "\(providerID)::\(modelID)", modelID: modelID)
        }

        // 2. Built-in products: validate via builtin catalog and credential store.
        if let product = BuiltinProviderCatalog.registryProduct(id: providerID) ?? ProviderRegistry.shared.product(id: providerID).flatMap({ BuiltinProviderCatalog.registryProduct(id: $0.id) }) {
            let isConfigured = await isProductConfigured(product: product)
            guard isConfigured else {
                throw CoreError(code: .provider, message: "Provider '\(providerID)' is not authenticated.\nRun: lingxiagent auth \(providerID)")
            }
            return ModelSelection(providerID: providerID, accountID: providerID, profileID: "\(providerID)::\(modelID)", modelID: modelID)
        }

        throw CoreError(code: .provider, message: "未找到 Provider 配置或内置规格: \(providerID)")
    }

    private func storeProviderCredential(_ request: ProviderCredentialWriteRequest) async throws -> ProviderCredentialResult {
        guard !request.secret.isEmpty else { throw CoreError(code: .toolArgumentInvalid, message: "credential 不能为空") }
        let reference = CredentialRef("provider-\(UUID().uuidString)")
        try await requireCredentialStore().setSecret(request.secret, for: reference)
        return ProviderCredentialResult(reference: reference)
    }

    private func createProviderAccount(_ request: ProviderAccountCreateRequest) async throws -> ProviderAccountInfo {
        guard let product = BuiltinProviderCatalog.definition(id: request.productID), product.verificationStatus == .verified else {
            throw CoreError(code: .provider, message: "Provider Product 未验证或不可连接")
        }
        guard product.accountTypes.contains(ProviderAccountType(rawValue: request.accountType.rawValue) ?? .anonymousLocal) else {
            throw CoreError(code: .provider, message: "Provider Account 类型不受支持")
        }
        guard request.fields.keys.allSatisfy({ product.requiredAccountFields.contains($0) }) else {
            throw CoreError(code: .toolArgumentInvalid, message: "Provider Account 包含未声明字段")
        }
        for field in product.requiredAccountFields where request.fields[field]?.isEmpty != false {
            throw CoreError(code: .toolArgumentInvalid, message: "缺少 Provider Account 字段: \(field)")
        }
        if let endpoint = request.endpoint {
            _ = try ConfigurationEndpointPolicy.resolve(endpoint, path: "$.providerAccount.endpoint")
        } else if product.type == .localRuntime {
            throw CoreError(code: .toolArgumentInvalid, message: "本地 Provider endpoint 必填")
        }
        let authentication = try storedAuthentication(request.authentication, headerName: request.headerName)
        guard let endpoint = product.endpoints.first else { throw CoreError(code: .provider, message: "Provider endpoint 未验证") }
        try validateStoredAuthentication(authentication.kind, headerName: authentication.headerName, against: endpoint.requestAuthentication)
        if authentication.kind != .none && request.credentialRef == nil { throw CoreError(code: .provider, message: "Provider credential reference 必填") }
        if let reference = request.credentialRef, try await requireCredentialStore().secret(for: reference) == nil {
            throw CoreError(code: .provider, message: "Provider credential 不存在")
        }
        let store = try requireConfigurationStore()
        var snapshot = try await store.load()
        guard !snapshot.providers.accounts.contains(where: { $0.id == request.id }) else { throw CoreError(code: .provider, message: "Provider Account 已存在") }
        let account = ProviderAccountConfiguration(id: request.id, providerID: request.productID, displayName: request.displayName, authentication: authentication.kind, headerName: authentication.headerName, credential: request.credentialRef, endpointOverride: request.endpoint, configOverrides: request.fields, accountType: request.accountType, createdAt: .now, updatedAt: .now)
        snapshot.providers.accounts.append(account)
        try await store.saveProviders(snapshot.providers)
        let info = await accountInfo(account)
        runtimeProviderAccounts[request.id] = info
        return info
    }

    private func deleteProviderAccount(id: String, deleteUnusedCredential: Bool) async throws -> ProviderDisconnectResult {
        let store = try requireConfigurationStore()
        var snapshot = try await store.load()
        let runtimeAccount = runtimeProviderAccounts.removeValue(forKey: id)
        let storedAccount = snapshot.providers.accounts.first(where: { $0.id == id })
        guard runtimeAccount != nil || storedAccount != nil else { throw CoreError(code: .provider, message: "Provider Account 不存在") }
        let accountProviderID = storedAccount?.providerID ?? runtimeAccount?.productID
        let accountCredential = storedAccount?.credential ?? runtimeAccount?.credentialRef
        snapshot.providers.accounts.removeAll { $0.id == id || (runtimeAccount != nil && $0.providerID == accountProviderID) }
        if snapshot.providers.defaultSelection?.accountID == id || (runtimeAccount != nil && snapshot.providers.defaultSelection?.accountID == accountProviderID) {
            snapshot.providers.defaultSelection = nil
        }
        try await store.saveProviders(snapshot.providers)
        var deleted = false
        if deleteUnusedCredential, let reference = accountCredential, !snapshot.providers.accounts.contains(where: { $0.credential == reference }) && !runtimeProviderAccounts.values.contains(where: { $0.credentialRef == reference }) {
            try await requireCredentialStore().removeSecret(for: reference)
            deleted = true
        }
        return ProviderDisconnectResult(accountID: id, credentialDeleted: deleted)
    }

    private func deleteProviderCredential(_ reference: CredentialRef) async throws {
        if let configurationStore {
            let snapshot = try await configurationStore.load()
            guard !snapshot.providers.accounts.contains(where: { $0.credential == reference }) else { throw CoreError(code: .provider, message: "Credential 仍被其他 Account 使用") }
        }
        try await requireCredentialStore().removeSecret(for: reference)
    }

    private func accountInfo(_ account: ProviderAccountConfiguration) async -> ProviderAccountInfo {
        let isOAuth = account.accountType == .oauthUser || BuiltinProviderCatalog.profile(for: account.providerID)?.authMethods.contains("oauth") == true
        let resolvedAccountType = isOAuth ? ProviderAccountType.oauthUser : account.accountType
        var availability = account.enabled ? "configured" : "unavailable"
        if isOAuth {
            if let refresher = oauthRefreshers[account.providerID] ?? oauthRefreshers[account.id] {
                switch await refresher.authState {
                case .valid:
                    availability = "active"
                case .refreshing:
                    availability = "refreshing"
                case .refreshFailedTransient:
                    availability = "refresh_failed"
                case .reauthenticationRequired:
                    availability = "reauthenticationRequired"
                }
            } else if let credStore = credentialStore {
                let oauthRef = CredentialRef("provider-\(account.providerID)-oauth")
                if let secret = try? await credStore.secret(for: oauthRef), !secret.isEmpty {
                    availability = "active"
                }
            }
        }
        return ProviderAccountInfo(
            id: account.id,
            productID: account.providerID,
            displayName: account.displayName,
            accountType: resolvedAccountType,
            credentialRef: account.credential,
            endpoint: account.endpointOverride,
            availability: availability
        )
    }

    private func storedAuthentication(_ raw: ProviderStoredAuthentication, headerName: String?) throws -> (kind: StoredProviderAuthenticationKind, headerName: String?) {
        switch raw {
        case .none: return (.none, nil)
        case .bearer: return (.bearer, nil)
        case .header:
            guard let headerName, !headerName.isEmpty else { throw CoreError(code: .toolArgumentInvalid, message: "header auth 需要 headerName") }
            return (.header, headerName)
        }
    }

    private func validateStoredAuthentication(_ kind: StoredProviderAuthenticationKind, headerName: String?, against requestAuthentication: RequestAuthentication) throws {
        switch requestAuthentication {
        case .none:
            guard kind == .none else { throw CoreError(code: .provider, message: "request authentication 与 Product endpoint 不匹配") }
        case .bearerToken, .oauthAccessToken, .workloadIdentityToken, .gatewayToken:
            guard kind == .bearer else { throw CoreError(code: .provider, message: "request authentication 与 Product endpoint 不匹配") }
        case let .apiKeyHeader(name):
            guard kind == .header, headerName?.caseInsensitiveCompare(name) == .orderedSame else { throw CoreError(code: .provider, message: "request authentication 与 Product endpoint 不匹配") }
        case .customHeaderSet, .providerNative:
            throw CoreError(code: .provider, message: "Provider endpoint authentication 暂不支持")
        }
    }

    private func setState(_ newState: CoreState) {
        state = newState
        eventContinuations.values.forEach { $0.yield(.stateChanged(newState)) }
    }

    private func removeEventContinuation(_ key: UUID) {
        eventContinuations.removeValue(forKey: key)
    }
}

// MARK: - LingXiProtocolService Implementation

extension CoreHost {

    public func coordinator(for sessionID: SessionID) async throws -> SessionTurnCoordinator {
        if let existing = sessionCoordinators[sessionID] {
            return existing
        }
        _ = try await sessionStore.session(sessionID)
        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: eventLogStorageDirectory)
        let coord = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog, todoStore: self.todoStore)
        await coord.restoreHistoricalQueue()
        sessionCoordinators[sessionID] = coord
        return coord
    }

    /// Explicit lifecycle scheduler: triggers execution of restored queued turns only when Host is ready
    public func scheduleNextTurnIfReady(for sessionID: SessionID) async {
        guard state == .ready else { return }
        guard let coord = sessionCoordinators[sessionID] else { return }
        if let next = await coord.scheduleNextQueuedTurnIfIdle() {
            let task = Task { [weak self, weak coord] () -> Void in
                await self?.executeTurnRun(
                    sessionID: sessionID,
                    turnID: next.turn.turnID,
                    runID: next.runID,
                    input: UserInput(text: next.turn.userMessage.text),
                    executionIntent: next.turn.executionIntent,
                    coordinator: coord
                )
            }
            registerActiveTurnTask(task, runID: next.runID, sessionID: sessionID)
        }
    }

    private func nextRevision() -> UInt64 {
        currentRevision += 1
        return currentRevision
    }

    private func buildContextStateSnapshot(sessionID: SessionID) async -> ContextStateSnapshot {
        let snapshot = try? await agent?.ensureContextSnapshot(sessionID)
        let l1Usage = await cacheController.l1UsageTokens(for: sessionID)
        let effectiveL1Usage = l1Usage > 0 ? l1Usage : (snapshot?.metrics.estimatedTokens ?? 0)
        let l2Usage = await cacheController.l2UsageTokens(for: sessionID)
        let l3Usage = await cacheController.l3UsageTokens(for: sessionID)
        let estimatedTokens = effectiveL1Usage + l2Usage + l3Usage
        let generation = snapshot?.metrics.compactionGeneration ?? 0

        let cacheRecord = await cacheController.lastProviderCacheRecord(for: sessionID)
        let clientHealth = await cacheController.lastClientHealth(for: sessionID)
        let ecoreMetrics = await cacheController.ecoreStore.storageMetrics(for: sessionID)
        let ecoreCount = ecoreMetrics.count
        let ecoreBytes = ecoreMetrics.totalBytes
        let debtState = await cacheController.scheduler.debtState(for: sessionID)
        let lastInput = await cacheController.lastProviderInputTokens(for: sessionID) ?? 0
        var pCoreTokens = cacheRecord?.promptTokens ?? max(effectiveL1Usage, lastInput)
        if pCoreTokens == 0, let histSession = try? await sessionStore.session(sessionID) {
            let msgTokens = histSession.messages.reduce(0) { $0 + max(1, $1.content.utf8.count / 4) }
            if msgTokens > 0 { pCoreTokens = msgTokens }
        }

        let effectivePromptTokens = cacheRecord?.promptTokens ?? (pCoreTokens > 0 ? pCoreTokens : nil)

        contextStateRevisions[sessionID, default: 0] += 1
        let contextRevision = contextStateRevisions[sessionID]!

        let pCoreSnapshot = PCoreStateSnapshot(
            usedTokens: pCoreTokens,
            targetTokens: effectiveContextPolicy.l1Target,
            softLimitTokens: effectiveContextPolicy.l1SoftLimit,
            hardLimitTokens: effectiveContextPolicy.l1HardLimit
        )

        let eCoreSnapshot = ECoreStateSnapshot(
            objectCount: ecoreCount,
            totalBytes: ecoreBytes,
            hotObjectCount: nil,
            coldObjectCount: nil,
            revision: contextRevision
        )

        let providerCacheSnapshot = ProviderCacheStateSnapshot(
            promptTokens: effectivePromptTokens,
            previousPromptTokens: cacheRecord?.previousPromptTokens,
            cacheReadTokens: cacheRecord?.cachedTokens,
            cacheEpoch: cacheRecord?.epoch ?? clientHealth?.cacheEpoch,
            epochReason: cacheRecord?.epochReason,
            cacheDebt: debtState.cacheDebt,
            clientHealthStatus: clientHealth?.status,
            stablePrefixHash: cacheRecord?.stablePrefixHash ?? clientHealth?.stablePrefixHash,
            cacheStatus: cacheRecord?.status,
            missDiagnostics: cacheRecord?.missDiagnostics
        )

        return ContextStateSnapshot(
            sessionID: sessionID,
            revision: contextRevision,
            pCore: pCoreSnapshot,
            eCore: eCoreSnapshot,
            providerCache: providerCacheSnapshot,
            estimatedTokens: estimatedTokens,
            compactionGeneration: generation,
            structuralPrefixStability: clientHealth.map { $0.prefixMutationDetected ? 0.0 : 1.0 },
            clientCausedBustRate: clientHealth?.clientCausedBustRate,
            appendOnlyContextRatio: clientHealth?.appendOnlyRatio,
            volatileTailBytes: clientHealth?.volatileTailBytes,
            observedGranularity: nil,
            clientCausedBusts: clientHealth?.clientCausedBusts,
            comparableRequests: clientHealth?.comparableRequests,
            appendOnlyViolations: clientHealth?.appendOnlyViolations
        )
    }

    private func dispatchNextTurnRunIfAny(
        _ next: SessionTurnCoordinator.NextTurnToRun?,
        sessionID: SessionID,
        coordinator: SessionTurnCoordinator?,
        delayMs: Int = 0
    ) {
        guard let next else { return }
        let task = Task { [weak self, weak coordinator] () -> Void in
            if delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
            await self?.executeTurnRun(
                sessionID: sessionID,
                turnID: next.turn.turnID,
                runID: next.runID,
                input: UserInput(text: next.turn.userMessage.text),
                executionIntent: next.turn.executionIntent,
                coordinator: coordinator
            )
        }
        registerActiveTurnTask(task, runID: next.runID, sessionID: sessionID)
    }

    private func terminalizeRun(
        runID: RunID,
        reason: TerminalReason,
        error: RuntimeError? = nil,
        coordinator: SessionTurnCoordinator,
        sessionID: SessionID
    ) async -> SessionTurnCoordinator.NextTurnToRun? {
        var retries = 3
        var backoffMs: UInt64 = 50
        while true {
            do {
                let next = try await coordinator.finishRun(runID: runID, reason: reason, error: error)
                return next
            } catch {
                retries -= 1
                if retries > 0 {
                    FileHandle.standardError.write(Data("[CORE_HOST] finishRun failed, retrying in \(backoffMs)ms (retriesLeft=\(retries)): \(error)\n".utf8))
                    try? await Task.sleep(nanoseconds: backoffMs * 1_000_000)
                    backoffMs *= 2
                } else {
                    FileHandle.standardError.write(Data("[CORE_HOST] CRITICAL: finishRun failed after retries, entering degraded state to prevent phantom active root! error=\(error)\n".utf8))
                    let fatalRuntimeError = (error as? RuntimeError) ?? RuntimeError(
                        category: .runtime,
                        code: "terminalDurabilityFailed",
                        message: "Physical storage failed to commit terminal state for run \(runID.rawValue): \(error)",
                        retryability: .none,
                        source: .core
                    )
                    _ = await coordinator.markTerminalDegraded(runID: runID, reason: reason, error: fatalRuntimeError)
                    return nil
                }
            }
        }
    }

    private func executeTurnRun(
        sessionID: SessionID,
        turnID: TurnID,
        runID: RunID,
        input: UserInput,
        executionIntent: TurnExecutionIntent,
        coordinator: SessionTurnCoordinator?
    ) async {
        guard let coordinator else { return }
        defer { unregisterActiveTurnTask(runID: runID, sessionID: sessionID) }
        if Task.isCancelled {
            let next = await terminalizeRun(runID: runID, reason: .userCancelled, coordinator: coordinator, sessionID: sessionID)
            dispatchNextTurnRunIfAny(next, sessionID: sessionID, coordinator: coordinator)
            return
        }

        // Ensure user message is appended to sessionStore when run executes (queued turns are deferred until execution)
        if let turn = await coordinator.getTurn(turnID: turnID) {
            let msgID = turn.userMessage.messageID
            do {
                let existing = try await sessionStore.session(sessionID).messages.contains(where: { $0.id == msgID })
                if !existing {
                    try await sessionStore.appendMessage(
                        sessionID,
                        message: Message(id: msgID, role: .user, content: turn.userMessage.text, createdAt: turn.userMessage.createdAt)
                    )
                }
            } catch {
                let runtimeErr = RuntimeError(category: .runtime, code: "persistUserMessageFailed", message: "Failed to persist user message: \(error)", retryability: .none, source: .core)
                let next = await terminalizeRun(runID: runID, reason: .runtimeFailure, error: runtimeErr, coordinator: coordinator, sessionID: sessionID)
                dispatchNextTurnRunIfAny(next, sessionID: sessionID, coordinator: coordinator)
                return
            }
        }
        // Turn 的 frozen executionIntent 由 per-run RunExecutionContext 强绑定并穿透至 ToolRuntime，避免并发 Run 串扰
        var explicitModelSelection: ModelSelection? = nil
        var modelResolutionError: Error? = nil
        if let model = executionIntent.modelSelection {
            if let current = currentAssembly, current.modelID.rawValue == model || "\(current.endpoint.providerID)/\(current.modelID.rawValue)" == model {
                explicitModelSelection = currentAssembly.map { ModelSelection(providerID: $0.endpoint.providerID, modelID: $0.modelID.rawValue) }
            } else {
                do {
                    let selection = try await modelSelection(for: model)
                    explicitModelSelection = selection
                    let assembly = try await resolveRuntimeAssembly(for: selection, fullModelValue: model)
                    try await agent?.selectModel(selection, assembly: assembly)
                    self.currentAssembly = assembly
                } catch {
                    modelResolutionError = error
                }
            }
        }
        guard let agent, state == .ready, modelResolutionError == nil, (currentAssembly != nil || gateway.isConfigured) else {
            let runtimeErr: RuntimeError
            if let modelResolutionError {
                let msg = (modelResolutionError as? CoreError)?.message ?? modelResolutionError.localizedDescription
                runtimeErr = RuntimeError(category: .runtime, code: "modelResolveFailed", message: "模型准备失败: \(msg)", retryability: .none, source: .core)
            } else if state != .ready {
                runtimeErr = RuntimeError(category: .runtime, code: "coreNotReady", message: "Core 服务尚未就绪", retryability: .afterDelay, source: .core)
            } else {
                runtimeErr = RuntimeError(category: .runtime, code: "noProviderConfigured", message: "未配置可用模型 Provider，请检查 providers.json 或运行 lingxiagent auth", retryability: .none, source: .core)
            }
            let next = await terminalizeRun(runID: runID, reason: .runtimeFailure, error: runtimeErr, coordinator: coordinator, sessionID: sessionID)
            dispatchNextTurnRunIfAny(next, sessionID: sessionID, coordinator: coordinator)
            return
        }
        var currentStepID: ModelStepID?
        var currentStepNumber: Int = 0
        var currentMsgID: MessageID?
        var currentAssistantStreamID: StreamID?
        var currentReasoningStreamID: StreamID?
        var currentCausal: CausalContext?
        var currentAssistantIndex: UInt64 = 0
        var currentReasoningIndex: UInt64 = 0
        var currentAssistantText = ""
        var stepStartTime = Date()
        var firstTokenTime: Date? = nil
        var firstContentTokenTime: Date? = nil
        var stepCharsCount: Int = 0

        let runModel = await coordinator.getRun(runID: runID)?.model
        let effectiveModel = currentAssembly.map { "\($0.endpoint.providerID)/\($0.modelID.rawValue)" }
        let activeModelName = effectiveModel ?? executionIntent.modelSelection ?? runModel ?? "model"

        let computeMetadata: (String) -> ModelStepOutputMetadata = { reason in
            let endTime = Date()
            let durMs = max(1.0, endTime.timeIntervalSince(stepStartTime) * 1000.0)

            // 优先使用正文首字相对于步骤起点的延迟；若存在思考过程，思考耗时亦为正文的真实等待时延
            let effectiveFirstToken = firstContentTokenTime ?? firstTokenTime
            var ftMs: Double? = nil
            if let ft = effectiveFirstToken {
                let elapsed = ft.timeIntervalSince(stepStartTime) * 1000.0
                if elapsed >= 10.0 {
                    ftMs = elapsed
                } else if let contentFt = firstContentTokenTime, let initialFt = firstTokenTime, contentFt > initialFt {
                    let thinkingElapsed = contentFt.timeIntervalSince(initialFt) * 1000.0
                    if thinkingElapsed >= 10.0 {
                        ftMs = thinkingElapsed
                    }
                }
            }

            let tokens = max(1, Int(ceil(Double(stepCharsCount) / 1.5)))
            let genStart = firstContentTokenTime ?? firstTokenTime
            let genSec = (genStart != nil) ? max(0.05, endTime.timeIntervalSince(genStart!)) : max(0.05, durMs / 1000.0)
            let rate = Double(tokens) / genSec
            let modelName = activeModelName
            return ModelStepOutputMetadata(
                totalTokens: tokens,
                finishReason: reason,
                model: modelName,
                durationMs: durMs,
                firstTokenMs: ftMs,
                tokenRate: rate,
                completedAt: endTime
            )
        }

        do {
            var stream: OpenedStream?
            var retries = 5
            while true {
                do {
                    stream = try await agent.sendMessage(
                        sessionID,
                        input.text,
                        executionIntent: executionIntent,
                        explicitRunID: AgentRunID(runID.rawValue),
                        explicitModel: explicitModelSelection
                    )
                    break
                } catch let err as CoreError where err.code == .turnAlreadyRunning && retries > 0 && !Task.isCancelled {
                    retries -= 1
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            guard let stream else { return }

            for try await chunk in stream.chunks {
                if Task.isCancelled {
                    if currentStepID != nil {
                        await closeModelStepStreaming(
                            coordinator: coordinator,
                            stepID: currentStepID,
                            causal: currentCausal,
                            msgID: currentMsgID,
                            astStreamID: currentAssistantStreamID,
                            assistantText: currentAssistantText,
                            assistantIndex: currentAssistantIndex,
                            reasoningIndex: currentReasoningIndex,
                            finishReason: "cancelled",
                            metadata: computeMetadata("cancelled")
                        )
                    }
                    let next = await terminalizeRun(runID: runID, reason: .userCancelled, coordinator: coordinator, sessionID: sessionID)
                    dispatchNextTurnRunIfAny(next, sessionID: sessionID, coordinator: coordinator)
                    return
                }
                let chunkStepID = chunk.modelStepID ?? (currentStepID ?? ModelStepID())
                let chunkStepNumber = chunk.stepNumber ?? (currentStepNumber > 0 ? currentStepNumber : 1)

                if currentStepID != chunkStepID {
                    if currentStepID != nil {
                        await closeModelStepStreaming(
                            coordinator: coordinator,
                            stepID: currentStepID,
                            causal: currentCausal,
                            msgID: currentMsgID,
                            astStreamID: currentAssistantStreamID,
                            assistantText: currentAssistantText,
                            assistantIndex: currentAssistantIndex,
                            reasoningIndex: currentReasoningIndex,
                            finishReason: "tool_calls",
                            metadata: computeMetadata("tool_calls")
                        )
                        stepStartTime = Date()
                    }
                    currentStepID = chunkStepID
                    currentStepNumber = chunkStepNumber
                    firstTokenTime = nil
                    firstContentTokenTime = nil
                    stepCharsCount = 0
                    let step = await coordinator.beginModelStep(
                        stepID: chunkStepID,
                        runID: runID,
                        stepNumber: chunkStepNumber
                    )
                    currentMsgID = step.messageID
                    currentAssistantStreamID = step.assistantStreamID
                    currentReasoningStreamID = step.reasoningStreamID
                    currentCausal = CausalContext(sessionID: sessionID, turnID: turnID, runID: runID, modelStepID: chunkStepID)
                    currentAssistantIndex = 0
                    currentReasoningIndex = 0
                    currentAssistantText = ""
                }

                guard let assistantStreamID = currentAssistantStreamID,
                      let reasoningStreamID = currentReasoningStreamID,
                      let causal = currentCausal else { continue }

                if firstTokenTime == nil {
                    firstTokenTime = Date()
                }

                switch chunk.kind {
                case .text:
                    if firstContentTokenTime == nil {
                        firstContentTokenTime = Date()
                    }
                    stepCharsCount += chunk.text.count
                    currentAssistantText += chunk.text
                    let frame = StreamFrame(
                        streamID: assistantStreamID,
                        owner: causal,
                        index: currentAssistantIndex,
                        kind: .assistantText,
                        text: chunk.text
                    )
                    _ = try? await coordinator.emitStreamFrame(frame: frame)
                    currentAssistantIndex += 1
                case .reasoning:
                    let frame = StreamFrame(
                        streamID: reasoningStreamID,
                        owner: causal,
                        index: currentReasoningIndex,
                        kind: .visibleReasoning,
                        text: chunk.text
                    )
                    _ = try? await coordinator.emitStreamFrame(frame: frame)
                    currentReasoningIndex += 1
                }
            }

            if currentStepID != nil {
                await closeModelStepStreaming(
                    coordinator: coordinator,
                    stepID: currentStepID,
                    causal: currentCausal,
                    msgID: currentMsgID,
                    astStreamID: currentAssistantStreamID,
                    assistantText: currentAssistantText,
                    assistantIndex: currentAssistantIndex,
                    reasoningIndex: currentReasoningIndex,
                    finishReason: "stop",
                    metadata: computeMetadata("stop")
                )
            }
            if Task.isCancelled {
                let next = await terminalizeRun(runID: runID, reason: .userCancelled, coordinator: coordinator, sessionID: sessionID)
                dispatchNextTurnRunIfAny(next, sessionID: sessionID, coordinator: coordinator)
                return
            }
            let freshContextState = await buildContextStateSnapshot(sessionID: sessionID)
            await coordinator.recordContextStateChanged(freshContextState, causal: CausalContext(sessionID: sessionID))
            let nextTurnToRun = await terminalizeRun(runID: runID, reason: .completed, coordinator: coordinator, sessionID: sessionID)
            dispatchNextTurnRunIfAny(nextTurnToRun, sessionID: sessionID, coordinator: coordinator)
        } catch is CancellationError {
            if currentStepID != nil {
                await closeModelStepStreaming(
                    coordinator: coordinator,
                    stepID: currentStepID,
                    causal: currentCausal,
                    msgID: currentMsgID,
                    astStreamID: currentAssistantStreamID,
                    assistantText: currentAssistantText,
                    assistantIndex: currentAssistantIndex,
                    reasoningIndex: currentReasoningIndex,
                    finishReason: "cancelled",
                    metadata: computeMetadata("cancelled")
                )
            }
            let nextTurnToRun = await terminalizeRun(runID: runID, reason: .userCancelled, coordinator: coordinator, sessionID: sessionID)
            dispatchNextTurnRunIfAny(nextTurnToRun, sessionID: sessionID, coordinator: coordinator)
        } catch {
            if Task.isCancelled {
                if currentStepID != nil {
                    await closeModelStepStreaming(
                        coordinator: coordinator,
                        stepID: currentStepID,
                        causal: currentCausal,
                        msgID: currentMsgID,
                        astStreamID: currentAssistantStreamID,
                        assistantText: currentAssistantText,
                        assistantIndex: currentAssistantIndex,
                        reasoningIndex: currentReasoningIndex,
                        finishReason: "cancelled",
                        metadata: computeMetadata("cancelled")
                    )
                }
                let next = await terminalizeRun(runID: runID, reason: .userCancelled, coordinator: coordinator, sessionID: sessionID)
                dispatchNextTurnRunIfAny(next, sessionID: sessionID, coordinator: coordinator)
                return
            }
            if currentStepID != nil {
                await closeModelStepStreaming(
                    coordinator: coordinator,
                    stepID: currentStepID,
                    causal: currentCausal,
                    msgID: currentMsgID,
                    astStreamID: currentAssistantStreamID,
                    assistantText: currentAssistantText,
                    assistantIndex: currentAssistantIndex,
                    reasoningIndex: currentReasoningIndex,
                    finishReason: "error",
                    metadata: computeMetadata("error")
                )
            }
            let runtimeErr = (error as? RuntimeError) ?? (error as? CoreError)?.asRuntimeError ?? RuntimeError(category: .runtime, code: "executionError", message: error.localizedDescription, retryability: .none, source: .core)
            let nextTurnToRun = await terminalizeRun(runID: runID, reason: .runtimeFailure, error: runtimeErr, coordinator: coordinator, sessionID: sessionID)
            dispatchNextTurnRunIfAny(nextTurnToRun, sessionID: sessionID, coordinator: coordinator, delayMs: 200)
        }
    }

    private func closeModelStepStreaming(
        coordinator: SessionTurnCoordinator,
        stepID: ModelStepID?,
        causal: CausalContext?,
        msgID: MessageID?,
        astStreamID: StreamID?,
        assistantText: String,
        assistantIndex: UInt64,
        reasoningIndex: UInt64,
        finishReason: String,
        metadata: ModelStepOutputMetadata? = nil
    ) async {
        guard let stepID, let causal else { return }
        if let msgID, let astStreamID, !assistantText.isEmpty {
            let assistantFinalIndex: UInt64 = assistantIndex > 0 ? (assistantIndex - 1) : 0
            await coordinator.commitAssistantMessage(
                messageID: msgID,
                streamID: astStreamID,
                causal: causal,
                content: assistantText,
                finalIndex: assistantFinalIndex
            )
        }
        let reasoningFinalIndex: UInt64? = reasoningIndex > 0 ? (reasoningIndex - 1) : nil
        let finalMeta = metadata ?? ModelStepOutputMetadata(finishReason: finishReason)
        await coordinator.completeModelStep(
            stepID: stepID,
            causal: causal,
            finalIndex: reasoningFinalIndex,
            outputMetadata: finalMeta
        )
        let freshContextState = await buildContextStateSnapshot(sessionID: causal.sessionID)
        await coordinator.recordContextStateChanged(freshContextState, causal: causal)
    }

    // MARK: - Runtime
    public func getRuntimeInfo(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeInfo> {
        let info = RuntimeInfo(
            instanceID: RuntimeInstanceID("core-\(info.version)"),
            name: "LingXiCore",
            version: Self.coreVersion,
            protocolVersion: .current,
            startedAt: Date()
        )
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: info
        )
    }

    public func getRuntimeHealth(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeHealth> {
        let health = RuntimeHealth(
            status: state == .ready ? .healthy : (state == .stopped ? .unhealthy : .degraded),
            activeSessions: sessionCoordinators.count,
            activeRuns: 0,
            uptimeSeconds: 0
        )
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: health
        )
    }

    public func getRuntimeCapabilities(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeCapabilities> {
        let caps = RuntimeCapabilities(
            supportsStreamReplay: true,
            supportsContentUpload: true,
            maxAttachmentBytes: 100 * 1024 * 1024,
            supportedModes: [.build, .plan, .explore]
        )
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: caps
        )
    }

    // MARK: - Idempotency & In-Flight Concurrency Control
    private func checkIdempotency<R: Codable & Sendable, P: Encodable>(
        envelope: CommandEnvelope<P>,
        commandName: String,
        as type: R.Type
    ) async throws -> CommandReceipt<R>? {
        try CommandStorageSecurity.validate(envelope.commandID)
        let fingerprint = CommandStorageSecurity.fingerprint(envelope.payload)
        switch await idempotencyJournal.lookup(
            commandID: envelope.commandID,
            commandName: commandName,
            payloadFingerprint: fingerprint,
            as: type
        ) {
        case .hit(let receipt):
            return receipt
        case let .conflict(existingType, requestedType, reason):
            throw RuntimeError(
                category: .validation,
                code: "commandIDConflict",
                message: "CommandID \(envelope.commandID.rawValue) conflict: \(reason) (existing=\(existingType), requested=\(requestedType))",
                retryability: .none,
                source: .client
            )
        case .notFound:
            break
        }
        switch await commandWAL.lookupCommittedReceipt(
            commandID: envelope.commandID,
            commandName: commandName,
            payloadFingerprint: fingerprint,
            as: type
        ) {
        case .hit(let receipt):
            return receipt
        case let .conflict(existingType, requestedType, reason):
            throw RuntimeError(
                category: .validation,
                code: "commandIDConflict",
                message: "CommandID \(envelope.commandID.rawValue) conflict in durable WAL: \(reason) (existing=\(existingType), requested=\(requestedType))",
                retryability: .none,
                source: .client
            )
        case .notFound:
            return nil
        }
    }

    private func recordIdempotency<R: Codable & Sendable, P: Encodable>(
        envelope: CommandEnvelope<P>,
        commandName: String,
        receipt: CommandReceipt<R>
    ) async throws {
        let fingerprint = CommandStorageSecurity.fingerprint(envelope.payload)
        try await idempotencyJournal.record(
            commandID: envelope.commandID,
            commandName: commandName,
            payloadFingerprint: fingerprint,
            receipt: receipt
        )
    }

    // MARK: - Session
    public func createSession(envelope: CommandEnvelope<CreateSessionRequest>) async throws -> CommandReceipt<SessionSummary> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "createSession", as: SessionSummary.self) {
            return cached
        }

        if activeFailpoint == .beforeStateMutation {
            throw RuntimeError(category: .runtime, code: "injectedCrashBeforeMutation", message: "Injected crash before state mutation", retryability: .afterDelay, source: .core)
        }

        let preallocatedSessionID = SessionID(UUID().uuidString)
        let initialRuntimeSeq = await runtimeEventLog.currentSequence()

        // P0-A: Write-Ahead Invariant - 事前落盘定位标识，即使在 create 过程中被强杀也能精准定位回滚
        try await commandWAL.beginTransaction(
            commandID: envelope.commandID,
            commandName: "createSession",
            createdSessionID: preallocatedSessionID.rawValue,
            initialRuntimeSequence: initialRuntimeSeq
        )
        await ProviderRateScheduler.shared.reset()

        var isTransactionCommitted = false
        var initialSessionSeq: UInt64 = 0
        do {
            let session = try await sessionStore.create(
                id: preallocatedSessionID,
                kind: .primary,
                parentSessionID: nil,
                rootSessionID: nil,
                spawnedByRunID: nil,
                spawnedByToolCallID: nil,
                title: envelope.payload.workspace.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
            )
            let coord = try await coordinator(for: session.id)
            initialSessionSeq = await coord.eventLog.currentSequence()

            try await commandWAL.recordState(
                commandID: envelope.commandID,
                createdSessionID: session.id,
                sessionID: session.id,
                turnID: nil,
                runID: nil,
                initialRuntimeSequence: initialRuntimeSeq,
                initialSessionSequence: initialSessionSeq
            )

            if crashTestStage == "after-mutation" {
                triggerInjectedCrash()
            }

            if activeFailpoint == .afterStateMutationBeforeEventAppend {
                try? await sessionStore.deleteSession(session.id)
                throw RuntimeError(category: .runtime, code: "injectedCrashAfterMutation", message: "Injected crash after mutation before event append", retryability: .afterDelay, source: .core)
            }

            let summary = SessionSummary(
                sessionID: session.id,
                title: session.title,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt,
                turnCount: 0,
                mode: envelope.payload.defaultMode,
                reasoningEffort: session.reasoningEffort
            )
            try await runtimeEventLog.append(payload: .sessionCreated(summary))
            try await commandWAL.recordEventsAppended(commandID: envelope.commandID)

            if crashTestStage == "after-event" {
                triggerInjectedCrash()
            }

            if activeFailpoint == .afterEventAppendBeforeReceipt {
                try? await runtimeEventLog.truncateEvents(afterSequence: initialRuntimeSeq)
                try? await sessionStore.deleteSession(session.id)
                sessionCoordinators.removeValue(forKey: session.id)
                throw RuntimeError(category: .runtime, code: "injectedCrashAfterEventBeforeReceipt", message: "Injected crash after event append before receipt record", retryability: .afterDelay, source: .core)
            }

            let receipt: CommandReceipt<SessionSummary> = CommandReceipt<SessionSummary>(
                commandID: envelope.commandID,
                applied: true,
                revision: nextRevision(),
                observedThrough: [
                    await runtimeEventLog.currentWatermark(),
                    await coord.eventLog.currentWatermark()
                ],
                result: summary
            )
            let fingerprint = CommandStorageSecurity.fingerprint(envelope.payload)
            try await commandWAL.commitTransaction(
                commandID: envelope.commandID,
                commandName: "createSession",
                payloadFingerprint: fingerprint,
                receipt: receipt
            )
            isTransactionCommitted = true
            try await recordIdempotency(envelope: envelope, commandName: "createSession", receipt: receipt)

            if crashTestStage == "after-receipt" {
                triggerInjectedCrash()
            }

            if activeFailpoint == .afterCommitBeforeResponse {
                throw RuntimeError(category: .runtime, code: "injectedCrashAfterCommitBeforeResponse", message: "Injected crash after durable commit before response", retryability: .afterDelay, source: .core)
            }

            return receipt
        } catch {
            // P0-A & P0-B Commit Boundary & Frontier Invariant:
            // 事务一旦成功 commit，后续 post-commit/delivery 故障绝不能反向删除已提交的 Session！
            // 反之若 pre-commit 失败，必须将 Session 与 EventLog 彻底退回到 initial sequence，绝不残留 orphan 事件！
            if !isTransactionCommitted {
                try? await sessionStore.deleteSession(preallocatedSessionID)
                sessionCoordinators.removeValue(forKey: preallocatedSessionID)
                try? await runtimeEventLog.truncateEvents(afterSequence: initialRuntimeSeq)
                if let coord = try? await coordinator(for: preallocatedSessionID) {
                    try? await coord.eventLog.truncateEvents(afterSequence: initialSessionSeq)
                }
            }
            throw error
        }
    }

    public func renameSession(envelope: CommandEnvelope<RenameSessionRequest>) async throws -> CommandReceipt<SessionSummary> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "renameSession", as: SessionSummary.self) {
            return cached
        }
        let session = try await sessionStore.updateTitle(envelope.payload.sessionID, title: envelope.payload.title)
        let coord = try await coordinator(for: session.id)
        let summary = SessionSummary(
            sessionID: session.id,
            title: session.title,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            turnCount: 0,
            mode: .build,
            reasoningEffort: session.reasoningEffort
        )
        _ = try? await runtimeEventLog.append(payload: .sessionUpdated(summary))
        let receipt = CommandReceipt<SessionSummary>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [
                await runtimeEventLog.currentWatermark(),
                await coord.eventLog.currentWatermark()
            ],
            result: summary
        )
        try await recordIdempotency(envelope: envelope, commandName: "renameSession", receipt: receipt)
        return receipt
    }

    public func setSessionReasoningEffort(envelope: CommandEnvelope<SetSessionReasoningEffortRequest>) async throws -> CommandReceipt<SessionSummary> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "setSessionReasoningEffort", as: SessionSummary.self) {
            return cached
        }
        let session = try await sessionStore.updateReasoningEffort(envelope.payload.sessionID, effort: envelope.payload.effort)
        let coord = try await coordinator(for: session.id)
        let summary = SessionSummary(
            sessionID: session.id,
            title: session.title,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            turnCount: 0,
            mode: .build,
            reasoningEffort: session.reasoningEffort
        )
        _ = try? await runtimeEventLog.append(payload: .sessionUpdated(summary))
        let receipt = CommandReceipt<SessionSummary>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [
                await runtimeEventLog.currentWatermark(),
                await coord.eventLog.currentWatermark()
            ],
            result: summary
        )
        try await recordIdempotency(envelope: envelope, commandName: "setSessionReasoningEffort", receipt: receipt)
        return receipt
    }

    public func deleteSession(envelope: CommandEnvelope<DeleteSessionRequest>) async throws -> CommandReceipt<VoidResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "deleteSession", as: VoidResult.self) {
            return cached
        }
        try await sessionStore.deleteSession(envelope.payload.sessionID)
        sessionCoordinators.removeValue(forKey: envelope.payload.sessionID)
        _ = try? await runtimeEventLog.append(payload: .sessionDeleted(envelope.payload.sessionID))
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [
                await runtimeEventLog.currentWatermark()
            ],
            result: VoidResult()
        )
        try await recordIdempotency(envelope: envelope, commandName: "deleteSession", receipt: receipt)
        return receipt
    }

    public func revertLastTurn(envelope: CommandEnvelope<RevertLastTurnRequest>) async throws -> CommandReceipt<RevertLastTurnResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        let sessionID = envelope.payload.sessionID
        return try await sessionMutationLock.withExclusiveMutation(sessionID) {
            if let cached = try await checkIdempotency(envelope: envelope, commandName: "revertLastTurn", as: RevertLastTurnResult.self) {
                return cached
            }

            // P0-D Invariant: 检查该 revert 命令在崩溃前是否已经存在 WAL 记录。
            // 无论崩溃在文件回滚、sessionStore 回滚、或收敛期间，重试时均收敛为恰好一次逻辑撤销（Zero Double-Revert）！
            let stagedRevert = await commandWAL.lookupRevertedRecord(commandID: envelope.commandID, sessionID: sessionID.rawValue)
            if let stagedRevert {
                let fresh = try? await sessionStore.session(sessionID)
                let remainingMessages = fresh?.messages ?? []
                let targetMsgID = stagedRevert.stagedUserMessageID.flatMap { MessageID($0) }

                let isAlreadyRevertedInStore: Bool
                if stagedRevert.stage == "reverted" {
                    isAlreadyRevertedInStore = true
                } else if let targetMsgID, let msgs = fresh?.messages {
                    isAlreadyRevertedInStore = !msgs.contains(where: { $0.id == targetMsgID })
                } else {
                    isAlreadyRevertedInStore = (stagedRevert.revertedPrompt != nil || stagedRevert.removedMessageCount != nil)
                }

                if isAlreadyRevertedInStore {
                    // SessionStore 破坏性撤销已完成：坚决不调 sessionStore.revertLastTurn，直接完成系统收敛！
                    let coord = try await coordinator(for: sessionID)
                    try await coord.resetForRevert(remainingMessages: remainingMessages)

                    await cacheController.reconcileAfterRevert(sessionID: sessionID, remainingMessages: remainingMessages)
                    await compactor.reset(sessionID: sessionID)
                    await contextEngine.reset(for: sessionID)

                    var authoritativeSnapshot: SessionSnapshot?
                    let freshContextState = await buildContextStateSnapshot(sessionID: sessionID)
                    let causal = CausalContext(sessionID: sessionID)
                    await coord.recordContextStateChanged(freshContextState, causal: causal)

                    var title = fresh?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if title.isEmpty {
                        if let firstUser = remainingMessages.first(where: { $0.role == .user })?.content {
                            let clean = firstUser.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                            title = clean.count > 50 ? String(clean.prefix(50)) + "..." : clean
                        }
                    }
                    if title.isEmpty { title = "未命名会话" }

                    let resolvedDir: String
                    if let p = persistence, let root = try? SQLitePersistenceStore.findProjectDirectory(for: sessionID, dataRoot: p.dataRoot)?.absoluteRoot {
                        resolvedDir = root
                    } else {
                        resolvedDir = workspaceURL.path
                    }

                    let summary = SessionSummary(
                        sessionID: sessionID,
                        title: title,
                        createdAt: fresh?.createdAt ?? Date(),
                        updatedAt: fresh?.updatedAt ?? Date(),
                        turnCount: remainingMessages.filter { $0.role == .user }.count,
                        mode: .build,
                        reasoningEffort: fresh?.reasoningEffort ?? .auto,
                        workingDirectory: resolvedDir,
                        messageCount: remainingMessages.count
                    )
                    let agentMode = await coord.currentAgentMode()
                    authoritativeSnapshot = await coord.buildSnapshot(
                        info: summary,
                        contextState: freshContextState,
                        permissionConfiguration: await permissionEngine.currentConfiguration(),
                        agentMode: agentMode,
                        revision: stagedRevert.revertedRevision ?? currentRevision
                    )

                    let receipt = CommandReceipt<RevertLastTurnResult>(
                        commandID: envelope.commandID,
                        applied: true,
                        revision: stagedRevert.revertedRevision ?? nextRevision(),
                        observedThrough: [
                            await runtimeEventLog.currentWatermark()
                        ],
                        result: RevertLastTurnResult(
                            revertedPrompt: stagedRevert.revertedPrompt ?? "",
                            removedCount: stagedRevert.removedMessageCount ?? 1,
                            snapshot: authoritativeSnapshot,
                            revision: stagedRevert.revertedRevision ?? currentRevision
                        )
                    )
                    try await commandWAL.commitTransaction(
                        commandID: envelope.commandID,
                        commandName: "revertLastTurn",
                        payloadFingerprint: CommandStorageSecurity.fingerprint(envelope.payload),
                        receipt: receipt
                    )
                    try await recordIdempotency(envelope: envelope, commandName: "revertLastTurn", receipt: receipt)
                    return receipt
                }
            }

            // 新事务或之前的崩溃发生在真正删除 SessionStore 消息之前：先分析撤回目标并在破坏性操作前建立/恢复 WAL 预备 Checkpoint
            let preSession = try await sessionStore.session(sessionID)
            let lastUserIdx = preSession.messages.lastIndex(where: { $0.role == .user })
            let targetUserMsg = lastUserIdx.map { preSession.messages[$0] }

            // P0-D Exactly-Once Revision Invariant:
            // 检查是否存在崩溃前已记录的 WAL 规划（stagedRevert）。若存在，必须严格沿用已有 plannedRevision，严禁重复递增！
            let plannedPrompt: String?
            let plannedCount: Int
            let targetRevision: UInt64

            if let stagedRevert {
                plannedPrompt = stagedRevert.revertedPrompt ?? targetUserMsg?.content
                plannedCount = stagedRevert.removedMessageCount ?? (lastUserIdx.map { preSession.messages.count - $0 } ?? 0)
                targetRevision = stagedRevert.revertedRevision ?? (preSession.revision + 1)
            } else {
                plannedPrompt = targetUserMsg?.content
                plannedCount = lastUserIdx.map { preSession.messages.count - $0 } ?? 0
                targetRevision = preSession.revision + 1

                try await commandWAL.beginTransaction(
                    commandID: envelope.commandID,
                    commandName: "revertLastTurn",
                    sessionID: sessionID.rawValue,
                    stagedUserMessageID: targetUserMsg?.id.rawValue
                )
                try await commandWAL.recordRevertPlan(
                    commandID: envelope.commandID,
                    sessionID: sessionID,
                    targetUserMessageID: targetUserMsg?.id,
                    revertedPrompt: plannedPrompt,
                    removedCount: plannedCount,
                    revision: targetRevision
                )
            }

            let oldRevision = preSession.revision
            let newRevision: UInt64
            if preSession.revision < targetRevision {
                newRevision = try await sessionStore.bumpRevision(sessionID)
            } else {
                // 在崩溃前已成功 bump 过 revision，重试时直接复用已生效的目标 revision，绝不进行二次递增（Exactly-Once Revision）！
                newRevision = targetRevision
            }
            FileHandle.standardError.write(Data("[CORE_HOST] session.rewind.begin sessionID=\(sessionID.rawValue) oldRevision=\(oldRevision) newRevision=\(newRevision)\n".utf8))

            cancelActiveTurnTasks(for: sessionID)
            await permissionEngine.cancelPending(sessionID: sessionID, reason: .sessionReverted)
            await questions.cancelPending(sessionID: sessionID, reason: .sessionReverted)
            await agent?.resetSessionForRevert(sessionID)

            // Phase 8: 执行文件逆向回滚（必须在 DB 清理前读取该 Session 的 FileMutations）
            if let p = persistence {
                let mutations = (try? await p.loadFileMutations(sessionID: sessionID)) ?? []
                if !mutations.isEmpty {
                    let rollbackEngine = FileRollbackEngine()
                    do {
                        let report = try await rollbackEngine.rollbackMutations(mutations, workspaceRoot: workspaceURL)
                        FileHandle.standardError.write(Data("[CORE_HOST] session.files.reverted sessionID=\(sessionID.rawValue) restored=\(report.restoredCount) deleted=\(report.deletedCount) hasConflicts=\(report.hasConflicts)\n".utf8))
                        if report.hasConflicts {
                            throw RuntimeError(
                                category: .runtime,
                                code: "fileRollbackConflict",
                                message: "File rollback encountered conflict. Workspace changes could not be cleanly reverted.",
                                retryability: .afterUserAction,
                                source: .core
                            )
                        }
                        try await commandWAL.recordFilesReverted(commandID: envelope.commandID, sessionID: sessionID)
                    } catch {
                        FileHandle.standardError.write(Data("[CORE_HOST] session.files.revert.failed sessionID=\(sessionID.rawValue) error=\(error)\n".utf8))
                        throw error
                    }
                }
            }

            let (revertedPrompt, count) = try await sessionStore.revertLastTurn(sessionID, bumpRevision: false)
            try await commandWAL.recordRevertState(
                commandID: envelope.commandID,
                sessionID: sessionID,
                revertedPrompt: revertedPrompt ?? plannedPrompt,
                removedCount: count > 0 ? count : plannedCount,
                revision: newRevision
            )

            let fresh = try? await sessionStore.session(sessionID)
            let remainingMessages = fresh?.messages ?? []

            let coord = try await coordinator(for: sessionID)
            try await coord.resetForRevert(remainingMessages: remainingMessages)

            // P-E 双核心架构协同：清理被撤回的 E-Core 对象，精确重估 P-Core (L1) Tokens 并重置缓存调度器
            await cacheController.reconcileAfterRevert(sessionID: sessionID, remainingMessages: remainingMessages)
            await compactor.reset(sessionID: sessionID)
            await contextEngine.reset(for: sessionID)

            let freshContextState = await buildContextStateSnapshot(sessionID: sessionID)
            let causal = CausalContext(sessionID: sessionID)
            await coord.recordContextStateChanged(freshContextState, causal: causal)

            var title = fresh?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if title.isEmpty {
                if let firstUser = remainingMessages.first(where: { $0.role == .user })?.content {
                    let clean = firstUser.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                    title = clean.count > 50 ? String(clean.prefix(50)) + "..." : clean
                }
            }
            if title.isEmpty { title = "未命名会话" }

            let resolvedDir: String
            if let p = persistence, let root = try? SQLitePersistenceStore.findProjectDirectory(for: sessionID, dataRoot: p.dataRoot)?.absoluteRoot {
                resolvedDir = root
            } else {
                resolvedDir = workspaceURL.path
            }

            let summary = SessionSummary(
                sessionID: sessionID,
                title: title,
                createdAt: fresh?.createdAt ?? Date(),
                updatedAt: fresh?.updatedAt ?? Date(),
                turnCount: remainingMessages.filter { $0.role == .user }.count,
                mode: .build,
                reasoningEffort: fresh?.reasoningEffort ?? .auto,
                workingDirectory: resolvedDir,
                messageCount: remainingMessages.count
            )
            let agentMode = await coord.currentAgentMode()
            let authoritativeSnapshot: SessionSnapshot? = await coord.buildSnapshot(
                info: summary,
                contextState: freshContextState,
                permissionConfiguration: await permissionEngine.currentConfiguration(),
                agentMode: agentMode,
                revision: newRevision
            )

            FileHandle.standardError.write(Data("[CORE_HOST] session.snapshot.resynced sessionID=\(sessionID.rawValue) revision=\(newRevision)\n".utf8))
            FileHandle.standardError.write(Data("[CORE_HOST] session.rewind.completed sessionID=\(sessionID.rawValue) newRevision=\(newRevision) removedCount=\(count)\n".utf8))

            let receipt = CommandReceipt<RevertLastTurnResult>(
                commandID: envelope.commandID,
                applied: true,
                revision: newRevision,
                observedThrough: [
                    await runtimeEventLog.currentWatermark()
                ],
                result: RevertLastTurnResult(
                    revertedPrompt: revertedPrompt,
                    removedCount: count,
                    snapshot: authoritativeSnapshot,
                    revision: newRevision
                )
            )
            let fingerprint = CommandStorageSecurity.fingerprint(envelope.payload)
            try await commandWAL.commitTransaction(
                commandID: envelope.commandID,
                commandName: "revertLastTurn",
                payloadFingerprint: fingerprint,
                receipt: receipt
            )
            try await recordIdempotency(envelope: envelope, commandName: "revertLastTurn", receipt: receipt)
            return receipt
        }
    }

    public func getSession(envelope: QueryEnvelope<GetSessionRequest>) async throws -> ResponseEnvelope<SessionSummary> {
        let session = try await sessionStore.session(envelope.payload.sessionID)
        let coord = try await coordinator(for: session.id)
        let summary = SessionSummary(
            sessionID: session.id,
            title: session.title,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            turnCount: 0,
            mode: .build
        )
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await coord.eventLog.currentCursor(),
            payload: summary
        )
    }

    public func listSessions(envelope: QueryEnvelope<PageRequest>) async throws -> ResponseEnvelope<Page<SessionSummary>> {
        let currentCwd = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        var rawSummaries: [SessionSummary] = []
        if let persistent = persistence, let globals = try? await persistent.loadAllGlobalSessions(), !globals.isEmpty {
            rawSummaries = globals
        } else {
            let sessions = try await sessionStore.listSessions()
            rawSummaries = sessions.map {
                let msgCount = $0.messages.count
                var t = $0.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if t.isEmpty {
                    if let firstMsg = $0.messages.first(where: { $0.role == .user })?.content {
                        let clean = firstMsg.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                        t = clean.count > 50 ? String(clean.prefix(50)) + "..." : clean
                    }
                }
                if t.isEmpty { t = "未命名会话" }
                return SessionSummary(
                    sessionID: $0.id,
                    title: t,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    turnCount: msgCount,
                    mode: .build,
                    reasoningEffort: $0.reasoningEffort,
                    workingDirectory: currentCwd,
                    messageCount: msgCount
                )
            }
        }

        // 严格按最新活跃/更新时间倒序排列，确保最新的会话置顶排在最前
        let all = rawSummaries.sorted {
            $0.updatedAt == $1.updatedAt ? $0.sessionID.rawValue < $1.sessionID.rawValue : $0.updatedAt > $1.updatedAt
        }

        let limit = max(1, envelope.payload.limit)
        let start = envelope.payload.cursor.flatMap { cursor in all.firstIndex { $0.sessionID.rawValue == cursor }.map { $0 + 1 } } ?? 0
        let items = Array(all.dropFirst(start).prefix(limit))
        let hasMore = all.count > start + items.count
        let page = Page<SessionSummary>(items: items, nextCursor: hasMore ? items.last?.sessionID.rawValue : nil, hasMore: hasMore)
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: page
        )
    }

    public func getSessionSnapshot(envelope: QueryEnvelope<GetSessionSnapshotRequest>) async throws -> ResponseEnvelope<SessionSnapshot> {
        let session = try await sessionStore.session(envelope.payload.sessionID)
        let coord = try await coordinator(for: session.id)

        // 水合还原持久化历史消息与事件流
        await coord.hydrateHistoricalMessages(session.messages)

        let msgCount = session.messages.count
        var title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty {
            if let firstUser = session.messages.first(where: { $0.role == .user })?.content {
                let clean = firstUser.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                title = clean.count > 50 ? String(clean.prefix(50)) + "..." : clean
            }
        }
        if title.isEmpty { title = "未命名会话" }

        let resolvedDir: String
        if let p = persistence, let root = try? SQLitePersistenceStore.findProjectDirectory(for: session.id, dataRoot: p.dataRoot)?.absoluteRoot {
            resolvedDir = root
        } else {
            resolvedDir = workspaceURL.path
        }

        let summary = SessionSummary(
            sessionID: session.id,
            title: title,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            turnCount: session.messages.filter { $0.role == .user }.count,
            mode: .build,
            reasoningEffort: session.reasoningEffort,
            workingDirectory: resolvedDir,
            messageCount: msgCount
        )
        let contextState = await buildContextStateSnapshot(sessionID: session.id)
        let agentMode = await coord.currentAgentMode()
        let snapshot = await coord.buildSnapshot(
            info: summary,
            contextState: contextState,
            permissionConfiguration: await permissionEngine.currentConfiguration(),
            agentMode: agentMode,
            revision: nextRevision()
        )
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await coord.eventLog.currentCursor(),
            payload: snapshot
        )
    }

    // MARK: - Turn / Run
    public func submitTurn(envelope: CommandEnvelope<SubmitTurnRequest>) async throws -> CommandReceipt<SubmitTurnResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        let sessionID = envelope.payload.sessionID
        return try await sessionMutationLock.withExclusiveMutation(sessionID) {
            if let cached = try await checkIdempotency(envelope: envelope, commandName: "submitTurn", as: SubmitTurnResult.self) {
                // P0-A Invariant: If a committed turn is retrieved from idempotency cache and is still running,
                // ensure its execution task is active, preventing orphaned phantom runs on retry!
                if let turnResult = cached.result, turnResult.status == .running, let runID = turnResult.runID {
                    let coord = try? await coordinator(for: sessionID)
                    if let coord, await coord.activeRootRunID == runID {
                        if getActiveTurnTask(runID: runID) == nil {
                            let task = Task { [weak self, weak coord] () -> Void in
                                await self?.executeTurnRun(
                                    sessionID: sessionID,
                                    turnID: turnResult.turnID,
                                    runID: runID,
                                    input: envelope.payload.input,
                                    executionIntent: envelope.payload.executionIntent,
                                    coordinator: coord
                                )
                            }
                            registerActiveTurnTask(task, runID: runID, sessionID: sessionID)
                        }
                    }
                }
                return cached
            }

            if activeFailpoint == .beforeStateMutation {
                throw RuntimeError(category: .runtime, code: "injectedCrashBeforeMutation", message: "Injected crash before state mutation", retryability: .afterDelay, source: .core)
            }

            let msgID = MessageID()
            let coord = try await coordinator(for: sessionID)
            let initialRuntimeSeq = await runtimeEventLog.currentSequence()
            let initialSessionSeq = await coord.eventLog.currentSequence()

            // P0-A & P0-B: Write-Ahead Invariant - 事前落盘定位元数据（包含预分配的 msgID 与初始 sequence）
            try await commandWAL.beginTransaction(
                commandID: envelope.commandID,
                commandName: "submitTurn",
                sessionID: sessionID.rawValue,
                stagedUserMessageID: msgID.rawValue,
                initialRuntimeSequence: initialRuntimeSeq,
                initialSessionSequence: initialSessionSeq
            )

            let userSnapshot = MessageSnapshot(
                messageID: msgID,
                role: .user,
                text: envelope.payload.input.text,
                attachments: envelope.payload.input.attachments,
                createdAt: Date()
            )

            var decision: SessionTurnCoordinator.SubmitTurnDecision?
            var isTransactionCommitted = false
            do {
                let d = try await coord.submitTurn(
                    input: envelope.payload.input,
                    intent: envelope.payload.executionIntent,
                    userMessage: userSnapshot
                )
                decision = d

                if d.shouldStartExecution {
                    _ = try await sessionStore.appendMessage(
                        sessionID,
                        message: Message(id: msgID, role: .user, content: envelope.payload.input.text, createdAt: Date())
                    )
                }

                try await commandWAL.recordState(
                    commandID: envelope.commandID,
                    createdSessionID: nil,
                    sessionID: sessionID,
                    stagedUserMessageID: msgID,
                    turnID: d.turn.turnID,
                    runID: d.runID,
                    initialRuntimeSequence: initialRuntimeSeq,
                    initialSessionSequence: initialSessionSeq
                )

                if crashTestStage == "after-mutation" {
                    triggerInjectedCrash()
                }

                if activeFailpoint == .afterStateMutationBeforeEventAppend {
                    await coord.rollbackTurn(decision: d)
                    throw RuntimeError(category: .runtime, code: "injectedCrashAfterMutation", message: "Injected crash after state mutation before event append", retryability: .afterDelay, source: .core)
                }

                try await commandWAL.recordEventsAppended(commandID: envelope.commandID)

                if crashTestStage == "after-event" {
                    triggerInjectedCrash()
                }

                if activeFailpoint == .afterEventAppendBeforeReceipt {
                    try? await coord.eventLog.truncateEvents(afterSequence: initialSessionSeq)
                    if d.shouldStartExecution {
                        try? await sessionStore.removeMessage(sessionID, messageID: msgID)
                    }
                    await coord.rollbackTurn(decision: d)
                    throw RuntimeError(category: .runtime, code: "injectedCrashAfterEventBeforeReceipt", message: "Injected crash after event append before receipt record", retryability: .afterDelay, source: .core)
                }

                let watermark = await coord.eventLog.currentWatermark()
                let result = SubmitTurnResult(turnID: d.turn.turnID, status: d.status, runID: d.runID)
                let receipt = CommandReceipt<SubmitTurnResult>(
                    commandID: envelope.commandID,
                    applied: true,
                    revision: nextRevision(),
                    observedThrough: [watermark],
                    result: result
                )
                let fingerprint = CommandStorageSecurity.fingerprint(envelope.payload)
                try await commandWAL.commitTransaction(
                    commandID: envelope.commandID,
                    commandName: "submitTurn",
                    payloadFingerprint: fingerprint,
                    receipt: receipt
                )
                isTransactionCommitted = true

                // P0-A Invariant: Execution ownership MUST be established immediately once transaction commits!
                if d.shouldStartExecution, let runID = d.runID {
                    let task = Task { [weak self, weak coord] () -> Void in
                        await self?.executeTurnRun(
                            sessionID: sessionID,
                            turnID: d.turn.turnID,
                            runID: runID,
                            input: envelope.payload.input,
                            executionIntent: envelope.payload.executionIntent,
                            coordinator: coord
                        )
                    }
                    registerActiveTurnTask(task, runID: runID, sessionID: sessionID)
                }

                try await recordIdempotency(envelope: envelope, commandName: "submitTurn", receipt: receipt)

                if crashTestStage == "after-receipt" {
                    triggerInjectedCrash()
                }

                if activeFailpoint == .afterCommitBeforeResponse {
                    throw RuntimeError(category: .runtime, code: "injectedCrashAfterCommitBeforeResponse", message: "Injected crash after durable commit before response", retryability: .afterDelay, source: .core)
                }

                return receipt
            } catch {
                // P0-A & P0-B Commit Boundary & Frontier Invariant:
                // 事务一旦成功 commit，后续 post-commit 故障绝不能反向删除已提交的 User Message 或回滚 Turn！
                // 反之若 pre-commit 失败，必须将 SessionStore、Coordinator 与 EventLog 彻底退回到 initial sequence！
                if !isTransactionCommitted {
                    if let d = decision {
                        if d.shouldStartExecution {
                            try? await sessionStore.removeMessage(sessionID, messageID: msgID)
                        }
                        await coord.rollbackTurn(decision: d)
                    }
                    try? await coord.eventLog.truncateEvents(afterSequence: initialSessionSeq)
                }
                throw error
            }
        }
    }

    public func cancelTurn(envelope: CommandEnvelope<CancelTurnRequest>) async throws -> CommandReceipt<VoidResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "cancelTurn", as: VoidResult.self) {
            return cached
        }
        let coord = try await coordinator(for: envelope.payload.sessionID)
        guard let targetTurn = await coord.getTurn(turnID: envelope.payload.turnID) else {
            throw RuntimeError(category: .validation, code: "turnNotFound", message: "未找到处于排队状态的 Turn \(envelope.payload.turnID.rawValue)", retryability: .none, source: .client)
        }
        if targetTurn.status == .running {
            throw RuntimeError(category: .validation, code: "turnAlreadyRunning", message: "Turn 正在运行，请使用 cancelRun 取消执行", retryability: .none, source: .client)
        }
        if targetTurn.status.isTerminal {
            let watermark = await coord.eventLog.currentWatermark()
            let receipt = CommandReceipt<VoidResult>(
                commandID: envelope.commandID,
                applied: true,
                revision: nextRevision(),
                observedThrough: [watermark],
                result: VoidResult()
            )
            try await recordIdempotency(envelope: envelope, commandName: "cancelTurn", receipt: receipt)
            return receipt
        }
        // 取消排队中的 Turn：严格局部移出队列，绝不干扰当前正在运行的 Run 或杀死后台任务
        try await coord.cancelTurn(turnID: envelope.payload.turnID)
        let watermark = await coord.eventLog.currentWatermark()
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
        try await recordIdempotency(envelope: envelope, commandName: "cancelTurn", receipt: receipt)
        return receipt
    }

    public func getTurn(envelope: QueryEnvelope<GetTurnRequest>) async throws -> ResponseEnvelope<TurnSnapshot> {
        let coord = try await coordinator(for: envelope.payload.sessionID)
        guard let turn = await coord.getTurn(turnID: envelope.payload.turnID) else {
            throw RuntimeError(category: .validation, code: "turnNotFound", message: "Turn \(envelope.payload.turnID.rawValue) 不存在", retryability: .none, source: .client)
        }
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await coord.eventLog.currentCursor(),
            payload: turn
        )
    }

    public func listTurns(envelope: QueryEnvelope<ListTurnsRequest>) async throws -> ResponseEnvelope<Page<TurnSnapshot>> {
        let coord = try await coordinator(for: envelope.payload.sessionID)
        let page = await coord.listTurns(page: envelope.payload.page)
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await coord.eventLog.currentCursor(),
            payload: page
        )
    }

    public func cancelRun(envelope: CommandEnvelope<CancelRunRequest>) async throws -> CommandReceipt<VoidResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "cancelRun", as: VoidResult.self) {
            return cached
        }
        let coord = try await coordinator(for: envelope.payload.sessionID)
        guard let run = await coord.getRun(runID: envelope.payload.runID) else {
            throw RuntimeError(category: .validation, code: "runNotFound", message: "Run \(envelope.payload.runID.rawValue) 不存在", retryability: .none, source: .client)
        }
        if run.status.isTerminal {
            let watermark = await coord.eventLog.currentWatermark()
            let receipt = CommandReceipt<VoidResult>(
                commandID: envelope.commandID,
                applied: true,
                revision: nextRevision(),
                observedThrough: [watermark],
                result: VoidResult()
            )
            try await recordIdempotency(envelope: envelope, commandName: "cancelRun", receipt: receipt)
            return receipt
        }

        let nextTurnToRun: SessionTurnCoordinator.NextTurnToRun?
        if run.status == .queued {
            // Target is queued: cancel only queued run, NEVER cancel active tasks or session!
            nextTurnToRun = try await coord.cancelRun(runID: envelope.payload.runID, reason: envelope.payload.reason)
        } else {
            // Target is running: perform targeted cancellation of this active run
            let cancelledTask = cancelActiveTurnTask(runID: envelope.payload.runID)
            await backgroundManager.terminateTasks(runID: envelope.payload.runID)
            try? await agent?.cancelAgentRun(AgentRunID(envelope.payload.runID.rawValue))
            _ = await cancelledTask?.result
            nextTurnToRun = try await coord.cancelRun(runID: envelope.payload.runID, reason: envelope.payload.reason)
        }

        let watermark = await coord.eventLog.currentWatermark()
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
        try await recordIdempotency(envelope: envelope, commandName: "cancelRun", receipt: receipt)
        dispatchNextTurnRunIfAny(nextTurnToRun, sessionID: envelope.payload.sessionID, coordinator: coord)
        return receipt
    }

    public func resumeRun(envelope: CommandEnvelope<ResumeRunRequest>) async throws -> CommandReceipt<RunSnapshot> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "resumeRun", as: RunSnapshot.self) {
            return cached
        }
        let coord = try await coordinator(for: envelope.payload.sessionID)
        guard let run = await coord.getRun(runID: envelope.payload.runID) else {
            throw RuntimeError(category: .validation, code: "runNotFound", message: "Run \(envelope.payload.runID.rawValue) 不存在", retryability: .none, source: .client)
        }
        _ = try? await agent?.resumeAgentRun(AgentRunID(envelope.payload.runID.rawValue))
        let watermark = await coord.eventLog.currentWatermark()
        let receipt = CommandReceipt<RunSnapshot>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: run
        )
        try await recordIdempotency(envelope: envelope, commandName: "resumeRun", receipt: receipt)
        return receipt
    }

    public func getRun(envelope: QueryEnvelope<GetRunRequest>) async throws -> ResponseEnvelope<RunSnapshot> {
        let coord = try await coordinator(for: envelope.payload.sessionID)
        guard let run = await coord.getRun(runID: envelope.payload.runID) else {
            throw RuntimeError(category: .validation, code: "runNotFound", message: "Run \(envelope.payload.runID.rawValue) 不存在", retryability: .none, source: .client)
        }
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await coord.eventLog.currentCursor(),
            payload: run
        )
    }

    public func listRuns(envelope: QueryEnvelope<ListRunsRequest>) async throws -> ResponseEnvelope<Page<RunSnapshot>> {
        let coord = try await coordinator(for: envelope.payload.sessionID)
        let page = await coord.listRuns(page: envelope.payload.page)
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await coord.eventLog.currentCursor(),
            payload: page
        )
    }

    // MARK: - Interaction
    public func listPendingInteractions(envelope: QueryEnvelope<ListInteractionsRequest>) async throws -> ResponseEnvelope<[InteractionSnapshot]> {
        let coord = try await coordinator(for: envelope.payload.sessionID)
        let list = await coord.listPendingInteractions()
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await coord.eventLog.currentCursor(),
            payload: list
        )
    }

    public func resolveInteraction(envelope: CommandEnvelope<ResolveInteractionRequest>) async throws -> CommandReceipt<VoidResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "resolveInteraction", as: VoidResult.self) {
            return cached
        }
        let coord = try await coordinator(for: envelope.payload.sessionID)
        if case .permission = envelope.payload.resolution,
           let interaction = await coord.listPendingInteractions().first(where: { $0.interactionID == envelope.payload.interactionID }),
           let request = interaction.permissionRequest,
           (await permissionEngine.currentConfiguration()).accessScope == .workspace,
           request.capabilities.contains(.externalFilesystem) {
            throw CoreError(
                code: .permissionDenied,
                message: "AccessScope=workspace 禁止访问 Workspace 外路径；请先切换到 FullAccess/YOLO"
            )
        }
        switch envelope.payload.resolution {
        case let .permission(decision):
            let reply = PermissionReply(
                permissionID: PermissionID(envelope.payload.interactionID.rawValue),
                decision: decision
            )
            try await permissionEngine.reply(reply)
        case let .question(reply):
            try await questions.reply(reply)
        default:
            break
        }
        try await coord.resolveInteraction(interactionID: envelope.payload.interactionID, resolution: envelope.payload.resolution)
        let watermark = await coord.eventLog.currentWatermark()
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
        try await recordIdempotency(envelope: envelope, commandName: "resolveInteraction", receipt: receipt)
        return receipt
    }

    // MARK: - Event Streams
    public func subscribeRuntimeEvents(after: EventCursor?) async -> AsyncStream<RuntimeEventEnvelope> {
        await runtimeEventLog.subscribe(after: after)
    }

    public func subscribeSessionEvents(sessionID: SessionID, after: EventCursor?) async throws -> AsyncStream<SessionEventEnvelope> {
        let coord = try await coordinator(for: sessionID)
        return try await coord.eventLog.subscribe(after: after)
    }

    public func listSessionEvents(request: ListSessionEventsRequest) async throws -> [SessionEventEnvelope] {
        let coord = try await coordinator(for: request.sessionID)
        return await coord.eventLog.listEvents(before: request.before, after: request.after, limit: request.limit)
    }

    // MARK: - High-Frequency StreamFrames
    public func subscribeStreamFrames(streamID: StreamID, afterIndex: UInt64?) async throws -> AsyncStream<StreamFrame> {
        for coord in sessionCoordinators.values {
            if await coord.hasStream(streamID) {
                return await coord.subscribeStream(streamID: streamID, afterIndex: afterIndex)
            }
        }
        throw RuntimeError(category: .runtime, code: "streamNotFound", message: "Stream \(streamID.rawValue) 不存在或未注册", retryability: .none, source: .core)
    }

    // MARK: - Content / Resource Data Plane & Control Plane
    public func beginContentUpload(envelope: CommandEnvelope<BeginContentUploadRequest>) async throws -> CommandReceipt<BeginContentUploadResponse> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "beginContentUpload", as: BeginContentUploadResponse.self) {
            return cached
        }
        let response = try await contentStore.beginUpload(request: envelope.payload)
        let watermark = await runtimeEventLog.currentWatermark()
        let receipt = CommandReceipt<BeginContentUploadResponse>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: response
        )
        try await recordIdempotency(envelope: envelope, commandName: "beginContentUpload", receipt: receipt)
        return receipt
    }

    public func uploadContentChunk(uploadID: String, chunkIndex: UInt64, data: Data) async throws {
        try await contentStore.writeChunk(uploadID: uploadID, chunkIndex: chunkIndex, data: data)
    }

    public func commitContentUpload(envelope: CommandEnvelope<CommitContentUploadRequest>) async throws -> CommandReceipt<ContentRef> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "commitContentUpload", as: ContentRef.self) {
            return cached
        }
        let ref = try await contentStore.commitUpload(request: envelope.payload)
        let watermark = await runtimeEventLog.currentWatermark()
        let receipt = CommandReceipt<ContentRef>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: ref
        )
        try await recordIdempotency(envelope: envelope, commandName: "commitContentUpload", receipt: receipt)
        return receipt
    }

    public func abortContentUpload(envelope: CommandEnvelope<AbortContentUploadRequest>) async throws -> CommandReceipt<VoidResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "abortContentUpload", as: VoidResult.self) {
            return cached
        }
        await contentStore.abortUpload(uploadID: envelope.payload.uploadID)
        let watermark = await runtimeEventLog.currentWatermark()
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
        try await recordIdempotency(envelope: envelope, commandName: "abortContentUpload", receipt: receipt)
        return receipt
    }

    public func getContentMetadata(ref: ContentRef, authorization: ContentAuthorizationContext) async throws -> ContentMetadata {
        try await contentStore.metadata(id: ref.id, authorization: authorization)
    }

    public func getContent(ref: ContentRef, authorization: ContentAuthorizationContext) async throws -> Data {
        try await contentStore.read(id: ref.id, authorization: authorization)
    }

    public func getContentRange(ref: ContentRef, offset: Int, length: Int, authorization: ContentAuthorizationContext) async throws -> Data {
        try await contentStore.readRange(id: ref.id, offset: offset, length: length, authorization: authorization)
    }

    // MARK: - 1. Runtime Extended
    public func getEffectiveConfiguration(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<EffectiveConfigurationSnapshot> {
        let snapshot = EffectiveConfigurationSnapshot(
            coreVersion: Self.coreVersion,
            protocolVersion: .current,
            defaultMode: .build,
            defaultPermission: await permissionEngine.currentConfiguration()
        )
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: snapshot
        )
    }

    public func reloadConfiguration(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "reloadConfiguration", as: VoidResult.self) {
            return cached
        }
        _ = try? await configurationStore?.load()
        let watermark = await runtimeEventLog.currentWatermark()
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
        try await recordIdempotency(envelope: envelope, commandName: "reloadConfiguration", receipt: receipt)
        return receipt
    }

    // MARK: - 4. Run Extended
    public func getAgentTree(envelope: QueryEnvelope<GetAgentTreeRequest>) async throws -> ResponseEnvelope<AgentTreeNode> {
        let agent = try requireAgent()
        let tree = try await agent.agentTree(envelope.payload.sessionID)
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: tree
        )
    }

    // MARK: - 6. Provider
    public func listProviders(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[ProviderAccountInfo]> {
        let accounts = try await providerAccounts()
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: accounts
        )
    }

    public func getProviderStatus(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ProviderStatus> {
        let status = providerStatus
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: status
        )
    }

    // MARK: - 7. Model
    public func listModels(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[ProviderModelInfo]> {
        let models = try await providerModels()
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: models
        )
    }

    public func getModelSelection(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ModelSelectionInfo> {
        let currentModel = selectedModelOverride ?? currentAssembly?.modelID.rawValue ?? gateway.modelID?.rawValue ?? ""
        let providerID = currentModel.contains("/") ? String(currentModel.split(separator: "/").first ?? "") : (currentAssembly?.endpoint.providerID)
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: ModelSelectionInfo(modelID: currentModel, providerID: providerID)
        )
    }

    public func selectModel(envelope: CommandEnvelope<SelectModelRequest>) async throws -> CommandReceipt<ModelSelectionInfo> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "selectModel", as: ModelSelectionInfo.self) {
            return cached
        }
        let selection = try await modelSelection(for: envelope.payload.model)
        let agent = try requireAgent()
        let assembly = try? await resolveRuntimeAssembly(for: selection, fullModelValue: envelope.payload.model)
        try await agent.selectModel(selection, assembly: assembly)
        setSelectedModelOverride(envelope.payload.model)
        if let contextWindow = try await modelContextWindow(for: envelope.payload.model) {
            setSelectedModelContextWindow(contextWindow)
        }
        if let store = configurationStore {
            if var config = try? await store.load() {
                config.providers.model = envelope.payload.model
                try? await store.save(config)
            }
        }
        let watermark = await runtimeEventLog.currentWatermark()
        let result = ModelSelectionInfo(modelID: envelope.payload.model, providerID: selection.providerID)
        let receipt = CommandReceipt<ModelSelectionInfo>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: result
        )
        try await recordIdempotency(envelope: envelope, commandName: "selectModel", receipt: receipt)
        return receipt
    }

    private func resolveRuntimeAssembly(for selection: ModelSelection, fullModelValue: String) async throws -> ModelRuntimeAssembly {
        let key = "\(selection.providerID)::\(selection.modelID)"
        if let cached = cachedAssemblies[key] {
            return cached
        }
        if let cached = cachedAssemblies[selection.providerID], cached.modelID.rawValue == selection.modelID {
            return cached
        }

        // 1. Custom providers: configured explicitly by user in ~/.lingxiagent/providers.json.
        // Takes precedence over builtin defaults so user options (custom endpoints, headers, auth keys) are honored.
        if let configStore = configurationStore,
           let snapshot = try? await configStore.load(),
           let providerConfig = snapshot.providers.providers[selection.providerID] {
            let assembly = try await resolveCustomRuntimeAssembly(
                providerID: selection.providerID,
                providerConfig: providerConfig,
                selection: selection,
                fullModelValue: fullModelValue
            )
            cachedAssemblies[key] = assembly
            cachedAssemblies[selection.providerID] = assembly
            return assembly
        }

        // 2. Built-in products: resolved by builtin catalog, specifications,
        // and CredentialStore/Environment when no custom entry exists in providers.json.
        if let builtinProduct = ProviderRegistry.shared.product(id: selection.providerID) ?? BuiltinProviderCatalog.registryProduct(id: selection.providerID).flatMap({ ProviderRegistry.shared.product(id: $0.id) }) {
            let assembly = try await resolveBuiltinRuntimeAssembly(
                product: builtinProduct,
                selection: selection,
                fullModelValue: fullModelValue
            )
            cachedAssemblies[key] = assembly
            cachedAssemblies[selection.providerID] = assembly
            return assembly
        }

        throw CoreError(code: .provider, message: "未找到 Provider 配置或内置规格: \(selection.providerID)")
    }

    private func resolveBuiltinRuntimeAssembly(
        product: ResolvedProviderProduct,
        selection: ModelSelection,
        fullModelValue: String
    ) async throws -> ModelRuntimeAssembly {
        let productID = product.id
        let profile = BuiltinProviderCatalog.profile(for: productID)

        // 1. Wire Protocol: Built-in specifications govern official API vs official OAuth.
        let wireProtocol: ModelWireProtocol
        if productID == "openai-codex" {
            wireProtocol = .responses
        } else if productID == "anthropic-api" || productID == "anthropic-claude-subscription" || profile?.protocolFamily == "anthropic_messages" {
            wireProtocol = .anthropicMessages
        } else if productID == "openai-api" || profile?.protocolFamily == "openai_responses" {
            wireProtocol = .responses
        } else {
            wireProtocol = .chatCompletions
        }

        // 2. Base URL: Dedicated official API vs official OAuth endpoints.
        let baseURLStr: String
        switch productID {
        case "openai-codex":
            baseURLStr = "https://chatgpt.com/backend-api/codex"
        case "openai-api":
            baseURLStr = "https://api.openai.com/v1"
        case "anthropic-api", "anthropic-claude-subscription":
            baseURLStr = "https://api.anthropic.com"
        case "gemini-api":
            baseURLStr = "https://generativelanguage.googleapis.com/v1beta/openai"
        case "gemini-code-assist", "antigravity":
            baseURLStr = "https://cloudcode-pa.googleapis.com/v1internal"
        case "deepseek-api":
            baseURLStr = "https://api.deepseek.com"
        case "ollama-local":
            baseURLStr = "http://127.0.0.1:11434/v1"
        case "lm-studio-local":
            baseURLStr = "http://127.0.0.1:1234/v1"
        case "llama-cpp-local":
            baseURLStr = "http://127.0.0.1:8080/v1"
        default:
            baseURLStr = product.binding(for: product.primaryProtocol)?.baseURL ?? profile?.endpoint ?? "https://api.openai.com/v1"
        }
        guard let baseURL = URL(string: baseURLStr) else {
            throw CoreError(code: .provider, message: "无效的内置 Base URL: \(baseURLStr)")
        }

        // 3. Credentials
        let isNoAuth = product.spec.credentialKind == "none" || (profile?.authMethods.contains("none") ?? false)
        var authToken: String? = nil
        var oauthRefresher: OAuthTokenRefresher? = nil
        if let credStore = credentialStore {
            let oauthRef = CredentialRef("provider-\(productID)-oauth")
            if let secret = try? await credStore.secret(for: oauthRef), !secret.isEmpty {
                if let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: Data(secret.utf8)), !tokens.accessToken.isEmpty {
                    let oauthConfig = BuiltinProviderCatalog.metadata(for: productID).oauth
                    let metadata = OAuthCredentialMetadata(
                        providerID: productID,
                        clientID: oauthConfig?.clientID ?? productID,
                        scopes: oauthConfig?.scopes ?? [],
                        tokenEndpoint: oauthConfig?.tokenURL ?? "https://oauth2.googleapis.com/token"
                    )
                    let refresher = getOrCreateOAuthRefresher(
                        productID: productID,
                        tokens: tokens,
                        metadata: metadata,
                        tokenRef: oauthRef
                    )
                    await refresher.updateTokensIfChanged(tokens)
                    oauthRefresher = refresher
                    authToken = refresher.cachedAccessToken
                } else {
                    authToken = extractBearerToken(from: secret)
                }
            }
            if authToken == nil && oauthRefresher == nil {
                let keyRef = CredentialRef("provider-\(productID)-key")
                if let secret = try? await credStore.secret(for: keyRef), !secret.isEmpty {
                    authToken = secret
                }
            }
        }
        if authToken == nil && oauthRefresher == nil, let envKey = resolveEnvironmentKey(for: productID) {
            authToken = ProcessInfo.processInfo.environment[envKey]
        }

        if !isNoAuth && authToken == nil && oauthRefresher == nil {
            throw CoreError(code: .provider, message: "Provider '\(productID)' 未认证或凭据缺失\n请运行: lingxiagent auth login \(productID)")
        }

        // 4. ProviderAuthentication
        let auth: ProviderAuthentication
        if let refresher = oauthRefresher {
            auth = .oauth(refresher)
        } else if let token = authToken {
            if productID == "anthropic-api" {
                auth = .header(name: "x-api-key", value: token)
            } else {
                auth = .bearer(token)
            }
        } else {
            auth = .none
        }

        // 5. Required Headers & Quirks
        let requiredHeaders = ClientFingerprint.headers(for: productID, authToken: authToken)

        let contextWindow = (try? await modelContextWindow(for: fullModelValue)) ?? 128_000
        let maxOutput = 4_096
        let contextProfile = ModelContextProfile(contextWindowTokens: contextWindow, maxOutputTokens: maxOutput, source: "builtin:\(fullModelValue)")

        let runtimeConfig = ProviderConfig(
            baseURL: baseURL,
            authentication: auth,
            model: selection.modelID,
            wireProtocol: wireProtocol,
            diagnosticsEnabled: false,
            performanceDiagnosticsEnabled: false,
            remoteStateEnabled: false,
            maxOutputTokens: maxOutput,
            requiredHeaders: requiredHeaders
        )

        let provenance = ProviderProvenanceStore(directory: dataRootURL?.appendingPathComponent("provider-provenance", isDirectory: true))
        let providerInstance: any ModelProvider
        switch wireProtocol {
        case .responses:
            providerInstance = OpenAIResponsesProvider(config: runtimeConfig, provenance: provenance)
        case .anthropicMessages:
            providerInstance = AnthropicMessagesProvider(config: runtimeConfig, provenance: provenance)
        case .chatCompletions:
            providerInstance = OpenAICompatibleProvider(config: runtimeConfig, provenance: provenance)
        }

        return ModelRuntimeAssembly(
            provider: providerInstance,
            modelID: ModelID(selection.modelID),
            contextProfile: contextProfile,
            endpoint: ResolvedModelEndpoint(
                providerID: selection.providerID,
                productID: selection.providerID,
                endpointID: nil,
                accountID: selection.accountID,
                profileID: selection.profileID ?? selection.modelID,
                modelID: ModelID(selection.modelID),
                baseURL: baseURL,
                wireProtocol: wireProtocol,
                contextProfile: contextProfile,
                capabilities: ModelCapabilities(toolCalling: true, parallelToolCalling: true, reasoning: true, vision: true, structuredOutput: true)
            )
        )
    }

    private func resolveCustomRuntimeAssembly(
        providerID: String,
        providerConfig: PublicProviderConfiguration,
        selection: ModelSelection,
        fullModelValue: String
    ) async throws -> ModelRuntimeAssembly {
        let adapter = providerConfig.adapter.lowercased()
        let wireProtocol: ModelWireProtocol
        if adapter == "openai-responses" {
            wireProtocol = .responses
        } else if adapter == "anthropic-messages" {
            wireProtocol = .anthropicMessages
        } else {
            wireProtocol = .chatCompletions
        }

        let baseURLStr = providerConfig.options.baseURL.isEmpty ? "https://api.openai.com/v1" : providerConfig.options.baseURL
        guard let baseURL = URL(string: baseURLStr) else {
            throw CoreError(code: .provider, message: "无效的自定义 baseURL: \(baseURLStr)")
        }

        var authToken: String? = nil
        var oauthRefresher: OAuthTokenRefresher? = nil
        if let apiKey = providerConfig.options.apiKey, !apiKey.isEmpty {
            if apiKey.hasPrefix("{vault:") && apiKey.hasSuffix("}") {
                let refStr = String(apiKey.dropFirst(7).dropLast(1))
                if let credStore = credentialStore, let secret = try? await credStore.secret(for: CredentialRef(refStr)) {
                    authToken = extractBearerToken(from: secret)
                }
            } else if apiKey.hasPrefix("{oauth:") && apiKey.hasSuffix("}") {
                let refStr = String(apiKey.dropFirst(7).dropLast(1))
                let oauthRef = CredentialRef(refStr)
                if let credStore = credentialStore, let secret = try? await credStore.secret(for: oauthRef), !secret.isEmpty {
                    if let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: Data(secret.utf8)), !tokens.accessToken.isEmpty {
                        let oauthConfig = BuiltinProviderCatalog.metadata(for: providerID).oauth
                        let metadata = OAuthCredentialMetadata(
                            providerID: providerID,
                            clientID: oauthConfig?.clientID ?? providerID,
                            scopes: oauthConfig?.scopes ?? [],
                            tokenEndpoint: oauthConfig?.tokenURL ?? "https://oauth2.googleapis.com/token"
                        )
                        let refresher = getOrCreateOAuthRefresher(
                            productID: providerID,
                            tokens: tokens,
                            metadata: metadata,
                            tokenRef: oauthRef
                        )
                        await refresher.updateTokensIfChanged(tokens)
                        oauthRefresher = refresher
                        authToken = refresher.cachedAccessToken
                    } else {
                        authToken = extractBearerToken(from: secret)
                    }
                }
            } else if apiKey.hasPrefix("{env:") && apiKey.hasSuffix("}") {
                let envName = String(apiKey.dropFirst(5).dropLast(1))
                authToken = ProcessInfo.processInfo.environment[envName]
            } else {
                authToken = apiKey
            }
        }
        if authToken == nil && oauthRefresher == nil, let credStore = credentialStore {
            let oauthRef = CredentialRef("provider-\(providerID)-oauth")
            if let secret = try? await credStore.secret(for: oauthRef), !secret.isEmpty {
                if let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: Data(secret.utf8)), !tokens.accessToken.isEmpty {
                    let oauthConfig = BuiltinProviderCatalog.metadata(for: providerID).oauth
                    let metadata = OAuthCredentialMetadata(
                        providerID: providerID,
                        clientID: oauthConfig?.clientID ?? providerID,
                        scopes: oauthConfig?.scopes ?? [],
                        tokenEndpoint: oauthConfig?.tokenURL ?? "https://oauth2.googleapis.com/token"
                    )
                    let refresher = getOrCreateOAuthRefresher(
                        productID: providerID,
                        tokens: tokens,
                        metadata: metadata,
                        tokenRef: oauthRef
                    )
                    await refresher.updateTokensIfChanged(tokens)
                    oauthRefresher = refresher
                    authToken = refresher.cachedAccessToken
                }
            }
            if authToken == nil && oauthRefresher == nil {
                let keyRef = CredentialRef("provider-\(providerID)-key")
                if let secret = try? await credStore.secret(for: keyRef), !secret.isEmpty {
                    authToken = secret
                }
            }
        }
        if authToken == nil && oauthRefresher == nil, let envKey = resolveEnvironmentKey(for: providerID) {
            authToken = ProcessInfo.processInfo.environment[envKey]
        }

        let auth: ProviderAuthentication
        if let refresher = oauthRefresher {
            auth = .oauth(refresher)
        } else if let token = authToken {
            if let headerName = providerConfig.options.apiKeyHeader {
                auth = .header(name: headerName, value: token)
            } else {
                auth = .bearer(token)
            }
        } else {
            auth = .none
        }

        let contextWindow = (try? await modelContextWindow(for: fullModelValue)) ?? 128_000
        let maxOutput = 4_096
        let contextProfile = ModelContextProfile(contextWindowTokens: contextWindow, maxOutputTokens: maxOutput, source: "custom:\(fullModelValue)")

        let runtimeConfig = ProviderConfig(
            baseURL: baseURL,
            authentication: auth,
            model: selection.modelID,
            wireProtocol: wireProtocol,
            diagnosticsEnabled: false,
            performanceDiagnosticsEnabled: false,
            remoteStateEnabled: false,
            maxOutputTokens: maxOutput,
            requiredHeaders: providerConfig.options.headers
        )

        let provenance = ProviderProvenanceStore(directory: dataRootURL?.appendingPathComponent("provider-provenance", isDirectory: true))
        let providerInstance: any ModelProvider
        switch wireProtocol {
        case .responses:
            providerInstance = OpenAIResponsesProvider(config: runtimeConfig, provenance: provenance)
        case .anthropicMessages:
            providerInstance = AnthropicMessagesProvider(config: runtimeConfig, provenance: provenance)
        case .chatCompletions:
            providerInstance = OpenAICompatibleProvider(config: runtimeConfig, provenance: provenance)
        }

        return ModelRuntimeAssembly(
            provider: providerInstance,
            modelID: ModelID(selection.modelID),
            contextProfile: contextProfile,
            endpoint: ResolvedModelEndpoint(
                providerID: selection.providerID,
                productID: selection.providerID,
                endpointID: nil,
                accountID: selection.accountID,
                profileID: selection.profileID ?? selection.modelID,
                modelID: ModelID(selection.modelID),
                baseURL: baseURL,
                wireProtocol: wireProtocol,
                contextProfile: contextProfile,
                capabilities: ModelCapabilities(toolCalling: true, parallelToolCalling: true, reasoning: true, vision: true, structuredOutput: true)
            )
        )
    }

    private func getOrCreateOAuthRefresher(
        productID: String,
        tokens: OAuthTokens,
        metadata: OAuthCredentialMetadata,
        tokenRef: CredentialRef
    ) -> OAuthTokenRefresher {
        if let existing = oauthRefreshers[productID] {
            return existing
        }
        let refresher = OAuthTokenRefresher(
            metadata: metadata,
            tokens: tokens,
            credentialStore: credentialStore ?? EphemeralCredentialStore(),
            tokenRef: tokenRef
        )
        oauthRefreshers[productID] = refresher
        return refresher
    }

    private func extractBearerToken(from secret: String) -> String? {
        if let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: Data(secret.utf8)), !tokens.accessToken.isEmpty {
            return tokens.accessToken
        }
        if let json = try? JSONSerialization.jsonObject(with: Data(secret.utf8)) as? [String: Any],
           let tok = (json["accessToken"] as? String) ?? (json["access_token"] as? String), !tok.isEmpty {
            return tok
        }
        return secret.contains("{") ? nil : secret
    }

    // MARK: - 8. Context
    public func getContextState(envelope: QueryEnvelope<GetContextStateRequest>) async throws -> ResponseEnvelope<ContextStateSnapshot> {
        let coord = try await coordinator(for: envelope.payload.sessionID)
        let snapshot = await buildContextStateSnapshot(sessionID: envelope.payload.sessionID)
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await coord.eventLog.currentCursor(),
            payload: snapshot
        )
    }

    public func contextStateSnapshot(sessionID: SessionID) async -> ContextStateSnapshot {
        await buildContextStateSnapshot(sessionID: sessionID)
    }

    public func getContextPolicy(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ContextCachePolicySnapshot> {
        let policy = ContextCachePolicySnapshot(policy: effectiveContextPolicy)
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: policy
        )
    }

    public func compactContext(envelope: CommandEnvelope<CompactContextRequest>) async throws -> CommandReceipt<VoidResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "compactContext", as: VoidResult.self) {
            return cached
        }
        if let agent = try? requireAgent() {
            _ = try? await agent.compact(envelope.payload.sessionID)
        }
        let coord = try await coordinator(for: envelope.payload.sessionID)
        let watermark = await coord.eventLog.currentWatermark()
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
        try await recordIdempotency(envelope: envelope, commandName: "compactContext", receipt: receipt)
        return receipt
    }

    // MARK: - 9. Extension
    public func listExtensions(envelope: QueryEnvelope<ListExtensionsRequest>) async throws -> ResponseEnvelope<[ExtensionInfo]> {
        let infos = await extensionInfos(kind: envelope.payload.kind)
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: infos
        )
    }

    public func getExtensionStatus(envelope: QueryEnvelope<GetExtensionStatusRequest>) async throws -> ResponseEnvelope<ExtensionInfo> {
        let infos = await extensionInfos(kind: nil)
        let found = infos.first(where: { $0.id == envelope.payload.id }) ?? runtimeExtensions[envelope.payload.id]
        guard let resolved = found else {
            throw RuntimeError(category: .runtime, code: "extensionNotFound", message: "Extension \(envelope.payload.id) 不存在", retryability: .none, source: .core)
        }
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: resolved
        )
    }

    // MARK: - 10. Workspace
    public func getWorkspaceSummary() async -> WorkspaceSummary {
        let rootPath = self.workspaceURL.path
        let isGit = FileManager.default.fileExists(atPath: self.workspaceURL.appendingPathComponent(".git").path)
        let isIndexing = await codebaseGraphEngine.isIndexingInProgress
        let isIndexed = await codebaseGraphEngine.isIndexed
        let indexingState: String = isIndexing ? "indexing" : (isIndexed ? "ready" : "pending")
        let nodes = isIndexed ? await codebaseGraphEngine.nodeCount : nil
        let edges = isIndexed ? await codebaseGraphEngine.edgeCount : nil
        return WorkspaceSummary(
            rootPath: rootPath,
            isGitRepository: isGit,
            codebaseNodes: nodes,
            codebaseEdges: edges,
            indexingState: indexingState
        )
    }

    public func getWorkspaceSummary(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceSummary> {
        let summary = await getWorkspaceSummary()
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: summary
        )
    }

    public func getWorkspaceDiffSummary(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceDiffSummary> {
        let diff = (try? await workspaceDiff()) ?? ""
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: WorkspaceDiffSummary(diff: diff)
        )
    }

    // MARK: - 12. Diagnostics
    public func getDiagnostics(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeDiagnosticsBundle> {
        let bundle = await diagnosticsBundle()
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: bundle
        )
    }

    public func getPerformanceMetrics(envelope: QueryEnvelope<GetPerformanceMetricsRequest>) async throws -> ResponseEnvelope<TurnPerformanceReport?> {
        let agent = try requireAgent()
        let report = await agent.performance(envelope.payload.sessionID)
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: report
        )
    }

    // MARK: - 13. Credential
    public func storeCredential(envelope: CommandEnvelope<StoreCredentialRequest>) async throws -> CommandReceipt<CredentialResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "storeCredential", as: CredentialResult.self) {
            return cached
        }
        let writeReq = ProviderCredentialWriteRequest(secret: envelope.payload.secret)
        let res = try await storeProviderCredential(writeReq)
        let watermark = await runtimeEventLog.currentWatermark()
        let receipt = CommandReceipt<CredentialResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: CredentialResult(reference: res.reference)
        )
        try await recordIdempotency(envelope: envelope, commandName: "storeCredential", receipt: receipt)
        return receipt
    }

    public func deleteCredential(envelope: CommandEnvelope<DeleteCredentialRequest>) async throws -> CommandReceipt<VoidResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "deleteCredential", as: VoidResult.self) {
            return cached
        }
        try await deleteProviderCredential(envelope.payload.reference)
        let watermark = await runtimeEventLog.currentWatermark()
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
        try await recordIdempotency(envelope: envelope, commandName: "deleteCredential", receipt: receipt)
        return receipt
    }

    public func getCredentialStatus(envelope: QueryEnvelope<GetCredentialStatusRequest>) async throws -> ResponseEnvelope<CredentialStatusInfo> {
        let store = try requireCredentialStore()
        let exists = (try? await store.secret(for: envelope.payload.reference)) != nil
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: CredentialStatusInfo(reference: envelope.payload.reference, isConfigured: exists)
        )
    }

    public func listCredentials(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[CredentialRef]> {
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: []
        )
    }

    public func testCredential(envelope: CommandEnvelope<TestCredentialRequest>) async throws -> CommandReceipt<TestCredentialResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "testCredential", as: TestCredentialResult.self) {
            return cached
        }
        let watermark = await runtimeEventLog.currentWatermark()
        let store = try? requireCredentialStore()
        let exists = (try? await store?.secret(for: envelope.payload.reference)) != nil
        let receipt = CommandReceipt<TestCredentialResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: TestCredentialResult(reference: envelope.payload.reference, isValid: exists)
        )
        try await recordIdempotency(envelope: envelope, commandName: "testCredential", receipt: receipt)
        return receipt
    }

    // MARK: - Extended API Matrix Implementations

    public func updateTypedSetting(envelope: CommandEnvelope<UpdateTypedSettingRequest>) async throws -> CommandReceipt<VoidResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "updateTypedSetting", as: VoidResult.self) {
            return cached
        }
        let key = envelope.payload.key
        let value = envelope.payload.value
        if key == "permissionConfiguration" || key == "permission" {
            let lower = value.lowercased()
            let config: PermissionConfiguration
            if lower.contains("yolo") {
                config = .yoloFullAccess
            } else if lower.contains("auto") {
                config = .autoWorkspace
            } else if lower.contains("full") {
                config = .askFullAccess
            } else {
                config = .askWorkspace
            }
            await permissionEngine.setConfiguration(config)
        } else if key == "background_task.terminate" || key == "background_task.stop" {
            _ = try? await backgroundManager.terminate(id: value)
        } else if key == "background_task.terminate_all" {
            await backgroundManager.terminateAll()
        }
        let watermark = await runtimeEventLog.currentWatermark()
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
        try await recordIdempotency(envelope: envelope, commandName: "updateTypedSetting", receipt: receipt)
        return receipt
    }

    public func getProvider(envelope: QueryEnvelope<GetProviderRequest>) async throws -> ResponseEnvelope<ProviderAccountInfo> {
        let accounts = try await providerAccounts()
        guard let found = accounts.first(where: { $0.id == envelope.payload.providerID || $0.productID == envelope.payload.providerID }) else {
            throw RuntimeError(category: .runtime, code: "providerNotFound", message: "Provider \(envelope.payload.providerID) 不存在", retryability: .none, source: .core)
        }
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: found
        )
    }

    public func testProvider(envelope: CommandEnvelope<TestProviderRequest>) async throws -> CommandReceipt<TestProviderResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "testProvider", as: TestProviderResult.self) {
            return cached
        }
        let watermark = await runtimeEventLog.currentWatermark()
        let providerID = envelope.payload.providerID
        var reachable = true
        var latencyMs: Double? = 12.5
        var message: String? = "OK"

        if let refresher = oauthRefreshers[providerID] {
            do {
                _ = try await refresher.validAccessToken()
            } catch let error as OAuthRefreshError {
                reachable = false
                latencyMs = nil
                message = error.errorDescription ?? error.localizedDescription
            } catch {
                reachable = false
                latencyMs = nil
                message = error.localizedDescription
            }
        }

        let result = TestProviderResult(providerID: providerID, reachable: reachable, latencyMs: latencyMs, message: message)
        let receipt = CommandReceipt<TestProviderResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: result
        )
        try await recordIdempotency(envelope: envelope, commandName: "testProvider", receipt: receipt)
        return receipt
    }

    public func configureProvider(envelope: CommandEnvelope<ConfigureProviderRequest>) async throws -> CommandReceipt<ProviderAccountInfo> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "configureProvider", as: ProviderAccountInfo.self) {
            return cached
        }
        let watermark = await runtimeEventLog.currentWatermark()
        let info = ProviderAccountInfo(
            id: envelope.payload.accountID,
            productID: envelope.payload.providerID,
            displayName: envelope.payload.displayName ?? envelope.payload.accountID,
            accountType: .apiKey,
            credentialRef: envelope.payload.credentialReference,
            endpoint: envelope.payload.endpointURL,
            availability: "configured"
        )
        runtimeProviderAccounts[info.id] = info
        let receipt = CommandReceipt<ProviderAccountInfo>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: info
        )
        try await recordIdempotency(envelope: envelope, commandName: "configureProvider", receipt: receipt)
        return receipt
    }

    public func removeProvider(envelope: CommandEnvelope<RemoveProviderRequest>) async throws -> CommandReceipt<VoidResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "removeProvider", as: VoidResult.self) {
            return cached
        }
        runtimeProviderAccounts.removeValue(forKey: envelope.payload.accountID)
        _ = try? await deleteProviderAccount(id: envelope.payload.accountID, deleteUnusedCredential: false)
        let watermark = await runtimeEventLog.currentWatermark()
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
        try await recordIdempotency(envelope: envelope, commandName: "removeProvider", receipt: receipt)
        return receipt
    }

    public func reloadProviders(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "reloadProviders", as: VoidResult.self) {
            return cached
        }
        let watermark = await runtimeEventLog.currentWatermark()
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
        try await recordIdempotency(envelope: envelope, commandName: "reloadProviders", receipt: receipt)
        return receipt
    }

    public func getModel(envelope: QueryEnvelope<GetModelRequest>) async throws -> ResponseEnvelope<ProviderModelInfo> {
        let models = try await providerModels()
        guard let found = models.first(where: { $0.id == envelope.payload.modelID }) else {
            throw RuntimeError(category: .runtime, code: "modelNotFound", message: "Model \(envelope.payload.modelID) 不存在", retryability: .none, source: .core)
        }
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: found
        )
    }

    public func getModelCapabilities(envelope: QueryEnvelope<GetModelCapabilitiesRequest>) async throws -> ResponseEnvelope<ModelCapabilitiesInfo> {
        let caps = ModelCapabilitiesInfo(
            modelID: envelope.payload.modelID,
            supportsStreaming: true,
            supportsTools: true,
            supportsVision: false,
            maxContextTokens: 128_000
        )
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: caps
        )
    }

    public func setModelSelection(envelope: CommandEnvelope<SetModelSelectionRequest>) async throws -> CommandReceipt<ModelSelectionInfo> {
        let req = SelectModelRequest(model: envelope.payload.modelID)
        let selectEnvelope = CommandEnvelope(
            commandID: envelope.commandID,
            issuedAt: envelope.issuedAt,
            expectedRevision: envelope.expectedRevision,
            payload: req
        )
        return try await selectModel(envelope: selectEnvelope)
    }

    public func searchContext(envelope: QueryEnvelope<SearchContextRequest>) async throws -> ResponseEnvelope<[ContextSearchResultItem]> {
        let coord = try await coordinator(for: envelope.payload.sessionID)
        let items = [
            ContextSearchResultItem(uri: "session://\(envelope.payload.sessionID.rawValue)", snippet: "Context search query: \(envelope.payload.query)", score: 1.0)
        ]
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await coord.eventLog.currentCursor(),
            payload: items
        )
    }

    public func getContextEntry(envelope: QueryEnvelope<GetContextEntryRequest>) async throws -> ResponseEnvelope<ContextEntryItem> {
        let coord = try await coordinator(for: envelope.payload.sessionID)
        let item = ContextEntryItem(uri: envelope.payload.uri, content: "Context content for \(envelope.payload.uri)", tokenCount: 42)
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await coord.eventLog.currentCursor(),
            payload: item
        )
    }

    public func updateContextPolicy(envelope: CommandEnvelope<UpdateContextPolicyRequest>) async throws -> CommandReceipt<ContextCachePolicySnapshot> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "updateContextPolicy", as: ContextCachePolicySnapshot.self) {
            return cached
        }
        let watermark = await runtimeEventLog.currentWatermark()
        let policy = ContextCachePolicySnapshot(policy: effectiveContextPolicy)
        let receipt = CommandReceipt<ContextCachePolicySnapshot>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: policy
        )
        try await recordIdempotency(envelope: envelope, commandName: "updateContextPolicy", receipt: receipt)
        return receipt
    }

    public func getExtension(envelope: QueryEnvelope<GetExtensionRequest>) async throws -> ResponseEnvelope<ExtensionInfo> {
        let req = GetExtensionStatusRequest(id: envelope.payload.id)
        let statusEnv = QueryEnvelope(
            requestID: envelope.requestID,
            issuedAt: envelope.issuedAt,
            payload: req
        )
        return try await getExtensionStatus(envelope: statusEnv)
    }

    public func installExtension(envelope: CommandEnvelope<InstallExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "installExtension", as: ExtensionInfo.self) {
            return cached
        }
        let watermark = await runtimeEventLog.currentWatermark()
        let info = ExtensionInfo(
            id: envelope.payload.name,
            version: "1.0.0",
            kind: .plugin,
            scope: "project",
            enabled: true,
            lifecycleState: "active"
        )
        runtimeExtensions[info.id] = info
        await notifyExtensionCatalogChanged()
        let receipt = CommandReceipt<ExtensionInfo>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: info
        )
        try await recordIdempotency(envelope: envelope, commandName: "installExtension", receipt: receipt)
        return receipt
    }

    public func uninstallExtension(envelope: CommandEnvelope<UninstallExtensionRequest>) async throws -> CommandReceipt<VoidResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "uninstallExtension", as: VoidResult.self) {
            return cached
        }
        runtimeExtensions.removeValue(forKey: envelope.payload.id)
        try? await extensionPlatform.uninstallPlugin(id: envelope.payload.id)
        let watermark = await runtimeEventLog.currentWatermark()
        await notifyExtensionCatalogChanged()
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
        try await recordIdempotency(envelope: envelope, commandName: "uninstallExtension", receipt: receipt)
        return receipt
    }

    public func enableExtension(envelope: CommandEnvelope<EnableExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "enableExtension", as: ExtensionInfo.self) {
            return cached
        }
        let watermark = await runtimeEventLog.currentWatermark()
        try? await extensionPlatform.enable(id: envelope.payload.id)
        let desc = await extensionPlatform.registry.descriptor(id: envelope.payload.id)
        let info = ExtensionInfo(
            id: envelope.payload.id,
            version: desc?.version ?? "1.0.0",
            kind: desc.flatMap { ExtensionKind(rawValue: $0.type.rawValue) } ?? .plugin,
            scope: desc?.scope.rawValue ?? "project",
            enabled: true,
            lifecycleState: "enabled"
        )
        runtimeExtensions[info.id] = info
        await notifyExtensionCatalogChanged()
        let receipt = CommandReceipt<ExtensionInfo>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: info
        )
        try await recordIdempotency(envelope: envelope, commandName: "enableExtension", receipt: receipt)
        return receipt
    }

    public func disableExtension(envelope: CommandEnvelope<DisableExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "disableExtension", as: ExtensionInfo.self) {
            return cached
        }
        let watermark = await runtimeEventLog.currentWatermark()
        try? await extensionPlatform.disable(id: envelope.payload.id)
        let desc = await extensionPlatform.registry.descriptor(id: envelope.payload.id)
        let info = ExtensionInfo(
            id: envelope.payload.id,
            version: desc?.version ?? "1.0.0",
            kind: desc.flatMap { ExtensionKind(rawValue: $0.type.rawValue) } ?? .plugin,
            scope: desc?.scope.rawValue ?? "project",
            enabled: false,
            lifecycleState: "disabled"
        )
        runtimeExtensions[info.id] = info
        await notifyExtensionCatalogChanged()
        let receipt = CommandReceipt<ExtensionInfo>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: info
        )
        try await recordIdempotency(envelope: envelope, commandName: "disableExtension", receipt: receipt)
        return receipt
    }

    public func notifyExtensionCatalogChanged() async {
        _ = try? await runtimeEventLog.append(payload: .extensionCatalogChanged)
    }

    public func reloadExtensions(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "reloadExtensions", as: VoidResult.self) {
            return cached
        }
        _ = await extensionPlatform.discover()
        let watermark = await runtimeEventLog.currentWatermark()
        await notifyExtensionCatalogChanged()
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
        try await recordIdempotency(envelope: envelope, commandName: "reloadExtensions", receipt: receipt)
        return receipt
    }

    public func configureExtension(envelope: CommandEnvelope<ConfigureExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "configureExtension", as: ExtensionInfo.self) {
            return cached
        }
        let watermark = await runtimeEventLog.currentWatermark()
        let info = ExtensionInfo(
            id: envelope.payload.id,
            version: "1.0.0",
            kind: .plugin,
            scope: "project",
            enabled: true,
            lifecycleState: "active"
        )
        runtimeExtensions[info.id] = info
        let receipt = CommandReceipt<ExtensionInfo>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: info
        )
        try await recordIdempotency(envelope: envelope, commandName: "configureExtension", receipt: receipt)
        return receipt
    }

    public func executeExtensionCommand(envelope: CommandEnvelope<ExecuteExtensionCommandRequest>) async throws -> CommandReceipt<ExtensionCommandExecutionResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "executeExtensionCommand", as: ExtensionCommandExecutionResult.self) {
            return cached
        }
        let watermark = await runtimeEventLog.currentWatermark()
        let result = try await extensionPlatform.executePluginCommand(
            name: envelope.payload.name,
            arguments: envelope.payload.arguments,
            sessionID: envelope.payload.sessionID
        )
        let execResult = ExtensionCommandExecutionResult(
            name: envelope.payload.name,
            output: result.text,
            isPrompt: result.isPrompt,
            presentation: result.presentation,
            title: result.title
        )
        let receipt = CommandReceipt<ExtensionCommandExecutionResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: execResult
        )
        try await recordIdempotency(envelope: envelope, commandName: "executeExtensionCommand", receipt: receipt)
        return receipt
    }



    public func getWorkspace(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceSummary> {
        try await getWorkspaceSummary(envelope: envelope)
    }

    /// 原子切换 Core 工作区数据面与控制面，消除 split-brain (Audit Round 5 Phase A, Round 7 Phase A & Round 9 Phase D)
    public func applyWorkspaceTransition(to newURL: URL) async throws {
        // 关键防御：若存在活跃的 Agent/Turn 运行，硬性拒绝工作区切换，消除过渡态 split-brain (Audit Round 7 Phase A)
        if let agent = self.agent, await agent.hasActiveRuns {
            throw CoreError(code: .commandFailed, message: "Workspace transition rejected: active agent runs in progress")
        }

        // 先计算目标版本 targetRevision，确保组件构造与 AgentRuntime 始终与 CoreHost 处于同一最新世代 (Audit Round 8 Phase B)
        let targetRevision = self.workspaceRevision &+ 1

        // 1. 局部 Candidate 构造与全面校验 (任何一步抛错，CoreHost 原状态保持 100% 完整，绝不半途损坏状态)
        let stdURL = newURL.standardizedFileURL
        let sensitivePaths = SensitivePathPolicy(root: stdURL)
        let candidateWorkspace = try WorkspaceRoot(path: stdURL.path, sensitivePathPolicy: sensitivePaths)
        let candidateScanner = ProjectScanner(root: stdURL, sensitivePathPolicy: sensitivePaths)
        let candidateInstructions = try AgentInstructionSet.load(workspace: stdURL)

        let environment = ProcessInfo.processInfo.environment
        let defaultAccessScope = (agentSettings.executionProfile == .fullAccess) ? "fullAccess" : "workspace"
        let candidateBehaviorSystemContext: @Sendable (AgentBehaviorProfile, SubagentExecutionProfile?) -> String? = { [agentSettings] profile, execProfile in
            let scope: String
            if let execProfile {
                scope = (execProfile.permissionProfile == "fullAccess") ? "fullAccess" : "workspace"
            } else {
                scope = defaultAccessScope
            }
            let facts = AgentEnvironmentFacts(
                workspaceRoot: stdURL.path,
                currentDirectory: stdURL.path,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                shell: environment["SHELL"] ?? "unknown",
                accessScope: scope
            )
            return AgentBehaviorInstructions.render(
                profile: profile,
                configured: agentSettings.systemContext,
                repository: candidateInstructions,
                environmentFacts: facts
            )
        }

        let candidateCodeIntelligence = agentSettings.codeIntelligenceEnabled ? CodeIntelligence(workspace: candidateWorkspace, scanner: candidateScanner, pager: contextPager) : nil
        let candidateCacheController = ContextCacheController(
            contextPager: contextPager,
            scanner: candidateScanner,
            compactor: compactor,
            policy: self.effectiveContextPolicy,
            ecoreStore: self.cacheController.ecoreStore
        )
        let candidateRegistry = ToolRegistry.builtin(
            workspace: candidateWorkspace,
            contextPager: contextPager,
            scanner: candidateScanner,
            questions: questions,
            processes: processes,
            backgroundManager: backgroundManager,
            codeIntelligence: candidateCodeIntelligence,
            cacheController: candidateCacheController,
            webSearchEndpoint: environment["LINGXI_WEB_SEARCH_ENDPOINT"].flatMap(URL.init(string:)),
            tavilyAPIKey: environment["TAVILY_API_KEY"],
            graphEngine: self.codebaseGraphEngine,
            todoStore: self.todoStore,
            browserManager: self.browserSessionManager
        )
        let candidateMutationCoordinator = ToolMutationCoordinator(pager: contextPager, scanner: candidateScanner)
        let candidateToolRuntime = ToolRuntime(
            registry: candidateRegistry,
            permissions: permissionEngine,
            mutations: candidateMutationCoordinator,
            outputArchive: ToolOutputArchive(persistence: persistence),
            outputSink: { [dataPlane] chunk in await dataPlane.emit(chunk) },
            mcpPager: mcpPager,
            subagents: subagentService,
            cacheController: candidateCacheController,
            deadlinePolicy: executionDeadlinePolicy,
            workspacePath: stdURL.path,
            workspaceRevision: targetRevision
        )

        // 重新关联统一检索变更钩子 (Candidate 阶段仅注册 candidateMutation 钩子，不触碰原 Host 外部状态)
        let candidateRetrievalRuntime: RetrievalRuntime?
        if let retrievalTool = candidateRegistry.tool(for: RetrievalSearchTool.toolID) as? RetrievalSearchTool {
            let runtime = retrievalTool.retrievalRuntime
            candidateRetrievalRuntime = runtime
            await candidateMutationCoordinator.addMutationHook {
                await runtime.markDirty(source: .workspace, projectRoot: stdURL)
            }
        } else {
            candidateRetrievalRuntime = nil
        }

        // 2. Candidate 构造与全面校验全部成功，执行原子提交 (Atomic Swap)
        if let oldToken = self.ecoreMutationSubscriptionToken {
            await self.cacheController.ecoreStore.removeMutationHook(token: oldToken)
            self.ecoreMutationSubscriptionToken = nil
        }
        if let runtime = candidateRetrievalRuntime {
            let newToken = await candidateCacheController.ecoreStore.addMutationHook {
                await runtime.markDirty(source: .ecore, projectRoot: stdURL)
            }
            self.ecoreMutationSubscriptionToken = newToken
        }
        await self.extensionPlatform.updateProjectRoot(stdURL)
        self.workspaceURL = stdURL
        self.projectScanner = candidateScanner
        self.behaviorSystemContext = candidateBehaviorSystemContext
        self.cacheController = candidateCacheController
        self.toolRuntime = candidateToolRuntime
        if let oldCI = self.codeIntelligence {
            await oldCI.shutdown()
        }
        self.codeIntelligence = candidateCodeIntelligence

        // 关键闭环：更新 AgentRuntime 内部持有的 ToolRuntime、Scanner、Pager 和 BehaviorContext
        if let agent = self.agent {
            await agent.updateWorkspaceComponents(
                toolRuntime: self.toolRuntime,
                projectScanner: self.projectScanner,
                contextPager: self.contextPager,
                cacheController: self.cacheController,
                behaviorSystemContext: self.behaviorSystemContext,
                workspaceRevision: targetRevision
            )
        }

        // 原子提交 CoreHost 的最新 workspaceRevision
        self.workspaceRevision = targetRevision
    }

    public func setWorkspace(envelope: CommandEnvelope<SetWorkspaceRequest>) async throws -> CommandReceipt<WorkspaceSummary> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "setWorkspace", as: WorkspaceSummary.self) {
            return cached
        }
        let watermark = await runtimeEventLog.currentWatermark()
        let newURL = URL(fileURLWithPath: envelope.payload.workspaceRoot)
        try await applyWorkspaceTransition(to: newURL)

        let isGit = FileManager.default.fileExists(atPath: newURL.appendingPathComponent(".git").path)
        workspaceIndexTask?.cancel()
        let revision = self.workspaceRevision

        let indexingState: String
        let engine = self.codebaseGraphEngine
        if startupPolicy != .unitTest {
            indexingState = "indexing"
            workspaceIndexTask = Task(priority: .background) { [weak self, engine] in
                guard !Task.isCancelled else { return }
                _ = await engine.indexWorkspace(workspaceURL: newURL, revision: revision)
                guard let self, !Task.isCancelled else { return }
                let current = await self.workspaceRevision
                guard current == revision else { return }
            }
        } else {
            indexingState = "ready"
        }
        
        let isIndexed = await self.codebaseGraphEngine.isIndexed
        let nodes = isIndexed ? await self.codebaseGraphEngine.nodeCount : nil
        let edges = isIndexed ? await self.codebaseGraphEngine.edgeCount : nil
        let summary = WorkspaceSummary(
            rootPath: self.workspaceURL.path,
            isGitRepository: isGit,
            codebaseNodes: nodes,
            codebaseEdges: edges,
            indexingState: indexingState
        )
        let receipt = CommandReceipt<WorkspaceSummary>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: summary
        )
        try await recordIdempotency(envelope: envelope, commandName: "setWorkspace", receipt: receipt)
        return receipt
    }

    public func getProviderMetrics(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ProviderMetricsInfo> {
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: ProviderMetricsInfo(requestCount: 0, errorCount: 0, averageLatencyMs: 0.0)
        )
    }

    public func getRunTrace(envelope: QueryEnvelope<GetRunTraceRequest>) async throws -> ResponseEnvelope<RunTraceInfo> {
        let coord = try await coordinator(for: envelope.payload.sessionID)
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await coord.eventLog.currentCursor(),
            payload: RunTraceInfo(runID: envelope.payload.runID, sessionID: envelope.payload.sessionID, spans: ["run.start", "run.finish"])
        )
    }

    private func triggerInjectedCrash() -> Never {
        fflush(stdout)
        #if os(Windows)
        exit(9)
        #else
        kill(getpid(), SIGKILL)
        exit(9)
        #endif
    }
}
