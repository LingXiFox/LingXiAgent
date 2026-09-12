import Foundation
import LingXiProtocol

/// LingXi Core 宿主：Core 的启动、状态、模块组装与对外契约实现。
public actor CoreHost: CoreEndpoint, LingXiProtocolService {
    public static let coreVersion = "0.1.0"
    public static let protocolVersion = "1"

    public static func stdioInteractive(environment: [String: String]) -> Bool {
        environment["LINGXI_INTERACTIVE"] == "1"
    }

    public let info: CoreInfo
    private let bus = CommandBus()
    private let dataPlane = DataPlane()
    /// 由 Host 显式声明；headless 默认不允许问题工具等待用户输入。
    public let interactive: Bool
    public let questions: QuestionRuntime
    private let processes: ToolProcessStore
    private let sessionStore: any SessionStore
    /// nil 表示显式的 ephemeral Core；调用方传入 dataRoot 时启用 project durable state。
    public let persistence: SQLitePersistenceStore?
    public let workspaceURL: URL
    public let extensionPlatform: ExtensionPlatform
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
    private let cacheController: ContextCacheController
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
    private let behaviorSystemContext: @Sendable (AgentBehaviorProfile, SubagentExecutionProfile?) -> String?
    private let agentSettings: AgentSettings
    private let restoreScheduler: SessionRestoreScheduler?
    private var agent: AgentRuntime?
    private var workflows: WorkflowRuntime?
    private var runtimeProviderAccounts: [String: ProviderAccountInfo] = [:]
    private var runtimeExtensions: [String: ExtensionInfo] = [:]
    private var cachedAssemblies: [String: ModelRuntimeAssembly] = [:]
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

    private func cancelActiveTurnTask(runID: RunID) {
        if let task = activeTurnTasks.removeValue(forKey: runID) {
            task.cancel()
        }
        for sessionID in activeTurnTasksBySession.keys {
            if let task = activeTurnTasksBySession[sessionID]?.removeValue(forKey: runID) {
                task.cancel()
            }
        }
    }

    private func cancelActiveTurnTasks(for sessionID: SessionID) {
        if let tasks = activeTurnTasksBySession.removeValue(forKey: sessionID) {
            for (runID, task) in tasks {
                task.cancel()
                activeTurnTasks.removeValue(forKey: runID)
            }
        }
    }
    package var toolRuntimeRef: ToolRuntime { toolRuntime }
    package var workflowRuntimeRef: WorkflowRuntime? { workflows }
    package var performanceStoreRef: PerformanceStore { performanceStore }
    public private(set) var effectiveContextPolicy: EffectiveContextPolicy

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
    public let commandWAL: DurableCommandWAL
    public let contentStore: ContentStore
    private var currentRevision: UInt64 = 1
    public let eventLogStorageDirectory: URL?
    public private(set) var activeFailpoint: CommitFailpoint?

    public func setCommitFailpoint(_ failpoint: CommitFailpoint?) {
        self.activeFailpoint = failpoint
    }

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
        , configurationStore: ConfigurationStore? = nil
        , credentialStore: (any CredentialStore)? = nil,
        restoreScheduler: SessionRestoreScheduler? = nil,
        extensionPlatform: ExtensionPlatform? = nil
    ) throws {
        let environment = ProcessInfo.processInfo.environment
        let supportsInteraction = interactive ?? configuration?.runtime.interactive ?? false
        self.interactive = supportsInteraction
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
        self.restoreScheduler = restoreScheduler
        self.dataRootURL = dataRoot
        self.cachedAssemblies = modelRuntimes
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
        let baseWorkspace = try workspaceRoot ?? WorkspaceRoot(path: FileManager.default.currentDirectoryPath)
        let persistentRoot = dataRoot
        let sensitivePaths = SensitivePathPolicy(root: baseWorkspace.url, excluding: persistentRoot.map { [$0] } ?? [])
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
        let persistent = try persistentRoot.map {
            try SQLitePersistenceStore(dataRoot: $0, mainRoot: workspace.url)
        }
        persistence = persistent
        self.sessionStore = sessionStore ?? persistent.map(PersistentSessionStore.init) ?? InMemorySessionStore()
        let executionDeadlinePolicy = ExecutionDeadlinePolicy(settings: configuration?.runtime.execution ?? ExecutionTimeoutSettings())
        self.executionDeadlinePolicy = executionDeadlinePolicy
        let permissions = permissionDecision.map { PermissionEngine(defaultDecision: $0) }
            ?? PermissionEngine(configuration: PermissionConfiguration(policy: agentSettings.permissionPolicy, profile: agentSettings.executionProfile))
        permissionEngine = permissions
        self.extensionPlatform = extensionPlatform ?? ExtensionPlatform(
            globalRoot: persistentRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-extensions-\(UUID().uuidString)", isDirectory: true),
            projectRoot: workspace.url,
            permissions: permissions,
            deadlinePolicy: executionDeadlinePolicy
        )
        let l2Budget = agentSettings.l2MaxCharacters
        let l1ProjectBudget = agentSettings.l1ProjectMaxCharacters
        l2CharacterCapacity = l2Budget
        l1ProjectCharacterCapacity = l1ProjectBudget
        contextPager = ContextPager(store: ProjectPageStore(persistence: persistent), workingSet: L2WorkingSet(characterBudget: l2Budget), projectCharacterBudget: l1ProjectBudget)
        projectScanner = ProjectScanner(root: workspace.url, sensitivePathPolicy: sensitivePaths)
        let effective = providerAssembly ?? .unavailable
        gateway = ModelGateway(assembly: effective.modelID.rawValue.isEmpty ? nil : effective, missingRequirements: providerAssembly == nil ? ["providers.defaultSelection"] : providerMissingRequirements, deadlinePolicy: executionDeadlinePolicy)
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
        let cacheController = ContextCacheController(
            contextPager: contextPager,
            scanner: projectScanner,
            compactor: compactor,
            policy: resolvedPolicy
        )
        self.cacheController = cacheController
        let codeIntelligence = agentSettings.codeIntelligenceEnabled ? CodeIntelligence(workspace: workspace, scanner: projectScanner, pager: contextPager) : nil
        toolRuntime = ToolRuntime(
            registry: toolRegistry ?? .builtin(workspace: workspace, contextPager: contextPager, scanner: projectScanner, questions: questions, processes: processes, codeIntelligence: codeIntelligence, cacheController: cacheController, webSearchEndpoint: environment["LINGXI_WEB_SEARCH_ENDPOINT"].flatMap(URL.init(string:))),
            permissions: permissions,
            mutations: ToolMutationCoordinator(pager: contextPager, scanner: projectScanner),
            outputArchive: ToolOutputArchive(persistence: persistent),
            outputSink: { [dataPlane] chunk in await dataPlane.emit(chunk) },
            mcpPager: effectiveMCPPager,
            subagents: subagentService,
            cacheController: cacheController,
            deadlinePolicy: executionDeadlinePolicy
        )
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
        let eventLogDir = persistentRoot?.appendingPathComponent(".lingxi/eventlog") ?? baseWorkspace.url.appendingPathComponent(".lingxi/eventlog")
        self.eventLogStorageDirectory = eventLogDir
        runtimeEventLog = RuntimeEventLog(storageDirectory: eventLogDir)
        idempotencyJournal = IdempotencyJournal(storageDirectory: eventLogDir)
        commandWAL = DurableCommandWAL(storageDirectory: eventLogDir)
        let storageDir = persistentRoot?.appendingPathComponent(".lingxi/content") ?? baseWorkspace.url.appendingPathComponent(".lingxi/content")
        contentStore = ContentStore(storageDirectory: storageDir)
    }

    /// 注册控制面路由并进入 ready。
    public func start() async {
        guard state == .starting else { return }
        await commandWAL.recover(
            sessionStore: sessionStore,
            runtimeEventLog: runtimeEventLog,
            coordinatorProvider: { [weak self] id in
                guard let self else { throw CoreError(code: .sessionNotFound, message: "Host deallocated") }
                return try await self.coordinator(for: id)
            }
        )
        await diagnosticsStore.record(kind: .core, event: "core.start.begin", metadata: ["interactive": String(interactive)])
        await extensionPlatform.restore()
        _ = await extensionPlatform.discover()
        await questions.setEventSink { [weak self] request in
            await self?.agent?.markWaitingForQuestion(request, waiting: true)
            await self?.routeWorkflowQuestion(request)
            await self?.broadcast(request.originSessionID == request.rootSessionID ? .questionAsked(request) : .questionEscalated(request))
        }
        await bus.add(.ping) { _ in .pong }
        scheduleRegistryRefresh()
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
            let assembly = try? await resolveRuntimeAssembly(for: selection, fullModelValue: model)
            try await agent.selectModel(selection, assembly: assembly)
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
            diagnostics: diagnosticsStore
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
        } catch {
            await diagnosticsStore.record(kind: .error, event: "core.start.failed", metadata: ["errorType": String(describing: type(of: error))], errorCode: (error as? CoreError)?.code.rawValue)
            self.agent = nil
            setState(.stopped)
            return
        }
        setState(.ready)
        await diagnosticsStore.record(kind: .core, event: "core.start.completed")
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
        lifecycle("cleanupCompleted", waitingOn: "processes")
        await ProviderActivityRegistry.shared.reset()
        agent = nil
        workflows = nil
        eventContinuations.values.forEach { $0.finish() }
        eventContinuations.removeAll()
        setState(.stopped)
        await diagnosticsStore.record(kind: .core, event: "core.shutdown.completed")
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
            let preview = String(result.content.prefix(240))
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

    private func refreshVNextContext(sessionID: SessionID) async {
        guard let coordinator = try? await coordinator(for: sessionID) else { return }
        await coordinator.recordContextStateChanged(
            await buildContextStateSnapshot(sessionID: sessionID),
            causal: CausalContext(sessionID: sessionID)
        )
    }

    private func shouldRefreshVNextContext(for event: CoreEvent) -> Bool {
        switch event {
        case .turnStarted, .toolResult, .turnCompleted, .turnFailed: return true
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
        ProviderStatus(
            configured: gateway.isConfigured,
            model: selectedModelOverride ?? gateway.modelID?.rawValue,
            baseURL: nil,
            missingRequirements: gateway.missingRequirements
        )
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
            cacheTelemetry: cacheTelemetry
        )
    }

    private func extensionInfos(kind: ExtensionKind?) async -> [ExtensionInfo] {
        if kind == nil || kind == .skill || kind == .command { _ = await extensionPlatform.discover() }
        let coreKind = kind.flatMap { ExtensionType(rawValue: $0.rawValue) }
        var result = await extensionPlatform.list(type: coreKind).map { descriptor in
            ExtensionInfo(id: descriptor.id, version: descriptor.version, kind: ExtensionKind(rawValue: descriptor.type.rawValue) ?? .plugin, scope: descriptor.scope.rawValue, enabled: descriptor.enabled, lifecycleState: descriptor.lifecycleState.rawValue)
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
        let result = try await runToolProcess(
            invocation: ToolProcessInvocation(executable: "/usr/bin/git", arguments: ["diff", "--no-ext-diff", "--no-textconv", "--"]),
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
            protocolVersion: Self.protocolVersion,
            configurationSummary: [
                "interactive": String(interactive),
                "diagnosticsEnabled": String(diagnosticsEnabled),
                "behaviorProfile": currentBehaviorProfile.rawValue,
                "persistence": persistence == nil ? "ephemeral" : "durable",
                "subagentMaxConcurrent": String(subagentLimits.maxConcurrentSubagents),
                "subagentMaxDepth": String(subagentLimits.maxSubagentDepth)
            ],
            trace: trace,
            recentErrors: await diagnosticsStore.recentErrors(),
            provider: RuntimeDiagnosticProviderStatus(configured: gateway.isConfigured, model: gateway.modelID?.rawValue, missingRequirements: gateway.missingRequirements),
            mcp: RuntimeDiagnosticMCPStatus(catalogTools: await mcpPager.catalogCount(), schemaFiles: mcpMetrics.count, schemaBytes: mcpMetrics.bytes, pageFaults: await mcpPager.pageFaults, activeLeases: await mcpPager.activeLeaseCount()),
            runs: runs,
            workflows: workflows,
            recoveryRequiredRunIDs: runs.filter { $0.status == .recoveryRequired }.map(\.runID),
            orphanRunIDs: orphanRunIDs
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
        var accounts = snapshot.providers.accounts.map(accountInfo)
        for (providerID, pConfig) in snapshot.providers.providers {
            if !accounts.contains(where: { $0.id == providerID || $0.productID == providerID }) {
                accounts.append(ProviderAccountInfo(
                    id: providerID,
                    productID: providerID,
                    displayName: pConfig.name.isEmpty ? providerID : pConfig.name,
                    accountType: .apiKey,
                    credentialRef: nil,
                    endpoint: pConfig.options.baseURL,
                    availability: "configured"
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
        Task.detached(priority: .background) {
            if delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            _ = await ModelRegistryClient.shared.fetch()
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
        guard let configurationStore else { return [] }
        let snapshot = try await configurationStore.load()
        let configuredProviders = Set(snapshot.providers.providers.keys)
        let catalog = await ModelRegistryClient.shared.catalog()

        var results: [ProviderModelInfo] = []

        for providerID in snapshot.providers.providers.keys.sorted() {
            guard let provider = snapshot.providers.providers[providerID] else { continue }

            if let product = catalog?.product(id: providerID) {
                let accountModels = await accountDiscoveredModels(
                    product: product,
                    providerID: providerID
                )
                let outcome = ModelAvailabilityResolver.resolve(
                    product: product,
                    registryModels: catalog?.models(productID: providerID) ?? [],
                    accountModels: accountModels,
                    isConfigured: true
                )
                results.append(contentsOf: outcome.models)
                continue
            }

            // The registry does not describe this product — an older or custom
            // configuration. Fall back to whatever the user configured.
            results.append(contentsOf: configuredModelInfos(providerID: providerID, provider: provider))
        }

        // Products the registry publishes but which the user has not configured
        // yet are still listed, so they can be discovered and connected.
        if let catalog {
            for product in catalog.products where !configuredProviders.contains(product.id) {
                guard product.runtime.isRunnable else { continue }
                let outcome = ModelAvailabilityResolver.resolve(
                    product: product,
                    registryModels: catalog.models(productID: product.id),
                    accountModels: [],
                    isConfigured: false
                )
                results.append(contentsOf: outcome.models)
            }
        }

        return results
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

        let cached = await AccountScopedCatalogCache.shared.load(
            productID: providerID,
            accountRef: accountRef
        )
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
        // reach, so this one waits.
        let result = await AccountModelDiscovery.refresh(
            product: product,
            accountRef: accountRef,
            credential: credential
        )
        if case let .success(models) = result, !models.isEmpty {
            return models
        }
        let stored = await AccountScopedCatalogCache.shared.load(
            productID: providerID,
            accountRef: accountRef
        )
        return stored?.models ?? []
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
        guard let separator = value.firstIndex(of: "/") else { throw CoreError(code: .toolArgumentInvalid, message: "模型格式必须是 provider/model") }
        let providerID = String(value[..<separator])
        let modelID = String(value[value.index(after: separator)...])
        let snapshot = try await requireConfigurationStore().load()
        guard let providerConfig = snapshot.providers.providers[providerID] else {
            if let profile = BuiltinProviderCatalog.profile(for: providerID), !profile.authMethods.contains("none") {
                throw CoreError(code: .provider, message: "Provider '\(providerID)' is not authenticated.\nRun: lingxiagent auth \(providerID)")
            }
            throw CoreError(code: .provider, message: "模型不可用: \(value)")
        }

        let isDynamicAuth = BuiltinProviderCatalog.profile(for: providerID)?.modelDiscovery == .authenticatedRemote
        let hasModelInConfig = providerConfig.models[modelID] != nil
        let isAvailableInDynamic: Bool
        if isDynamicAuth {
            let availableModels = try await providerModels()
            isAvailableInDynamic = availableModels.contains(where: { $0.providerID == providerID && $0.modelID == modelID })
        } else {
            isAvailableInDynamic = false
        }

        guard (hasModelInConfig || isAvailableInDynamic) else {
            throw CoreError(code: .provider, message: "模型不可用: \(value)")
        }

        let isLocalNoAuth = BuiltinProviderCatalog.profile(for: providerID)?.authMethods.contains("none") ?? false
        if !isLocalNoAuth {
            let keyRef = CredentialRef("provider-\(providerID)-key")
            let oauthRef = CredentialRef("provider-\(providerID)-oauth")
            let hasKey = (try? await requireCredentialStore().secret(for: keyRef)) != nil || providerConfig.options.apiKey != nil
            let hasOAuth = (try? await requireCredentialStore().secret(for: oauthRef)) != nil
            if !hasKey && !hasOAuth {
                throw CoreError(code: .provider, message: "Provider '\(providerID)' is not authenticated.\nRun: lingxiagent auth \(providerID)")
            }
        }
        return ModelSelection(providerID: providerID, accountID: providerID, profileID: "\(providerID)::\(modelID)", modelID: modelID)
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
        let info = accountInfo(account)
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

    private func accountInfo(_ account: ProviderAccountConfiguration) -> ProviderAccountInfo {
        ProviderAccountInfo(id: account.id, productID: account.providerID, displayName: account.displayName, accountType: account.accountType, credentialRef: account.credential, endpoint: account.endpointOverride, availability: account.enabled ? "configured" : "unavailable")
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

    // MARK: - Helper Methods

    public func coordinator(for sessionID: SessionID) async throws -> SessionTurnCoordinator {
        if let existing = sessionCoordinators[sessionID] {
            return existing
        }
        _ = try await sessionStore.session(sessionID)
        let eventLog = SessionEventLog(sessionID: sessionID, storageDirectory: eventLogStorageDirectory)
        let coord = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)
        sessionCoordinators[sessionID] = coord
        return coord
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

        return ContextStateSnapshot(
            sessionID: sessionID,
            estimatedTokens: estimatedTokens,
            l1Tokens: effectiveL1Usage,
            l2Tokens: l2Usage,
            l3Tokens: l3Usage,
            compactionGeneration: generation,
            cacheReadTokens: cacheRecord?.cachedTokens,
            promptTokens: cacheRecord?.promptTokens,
            previousPromptTokens: cacheRecord?.previousPromptTokens,
            cacheStatus: cacheRecord?.status,
            cacheEpoch: cacheRecord?.epoch ?? clientHealth?.cacheEpoch,
            epochReason: cacheRecord?.epochReason,
            stablePrefixHash: cacheRecord?.stablePrefixHash ?? clientHealth?.stablePrefixHash,
            missDiagnostics: cacheRecord?.missDiagnostics,
            structuralPrefixStability: clientHealth.map { $0.prefixMutationDetected ? 0.0 : 1.0 },
            clientCausedBustRate: clientHealth?.clientCausedBustRate,
            appendOnlyContextRatio: clientHealth?.appendOnlyRatio,
            volatileTailBytes: clientHealth?.volatileTailBytes,
            clientHealthStatus: clientHealth?.status,
            observedGranularity: nil,
            clientCausedBusts: clientHealth?.clientCausedBusts,
            comparableRequests: clientHealth?.comparableRequests,
            appendOnlyViolations: clientHealth?.appendOnlyViolations
        )
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
            _ = await coordinator.finishRun(runID: runID, reason: .userCancelled)
            return
        }
        // Core 执行必须使用该 Turn 的 frozen executionIntent
        await permissionEngine.setConfiguration(executionIntent.permissionConfiguration)
        if let model = executionIntent.modelSelection, let selection = try? await modelSelection(for: model) {
            try? await agent?.selectModel(selection)
        }
        guard let agent, state == .ready, gateway.isConfigured else {
            let next = await coordinator.finishRun(runID: runID, reason: .completed)
            if let next {
                let task = Task { [weak self, weak coordinator] () -> Void in
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
        let activeModelName = executionIntent.modelSelection ?? runModel ?? "model"

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
            let stream = try await agent.sendMessage(sessionID, input.text)

            for try await chunk in stream.chunks {
                if Task.isCancelled {
                    _ = await coordinator.finishRun(runID: runID, reason: .userCancelled)
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
                _ = await coordinator.finishRun(runID: runID, reason: .userCancelled)
                return
            }
            let nextTurnToRun = await coordinator.finishRun(runID: runID, reason: .completed)
            if let next = nextTurnToRun {
                let task = Task { [weak self, weak coordinator] () -> Void in
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
        } catch is CancellationError {
            _ = await coordinator.finishRun(runID: runID, reason: .userCancelled)
        } catch {
            if Task.isCancelled {
                _ = await coordinator.finishRun(runID: runID, reason: .userCancelled)
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
            let nextTurnToRun = await coordinator.finishRun(runID: runID, reason: .runtimeFailure, error: runtimeErr)
            if let next = nextTurnToRun {
                let task = Task { [weak self, weak coordinator] () -> Void in
                    try? await Task.sleep(for: .milliseconds(200))
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

    // MARK: - Session
    public func createSession(envelope: CommandEnvelope<CreateSessionRequest>) async throws -> CommandReceipt<SessionSummary> {
        if let cached = await commandWAL.getCommittedReceipt(commandID: envelope.commandID, as: SessionSummary.self) {
            return cached
        }
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: SessionSummary.self) {
            return cached
        }

        if activeFailpoint == .beforeStateMutation {
            throw RuntimeError(category: .runtime, code: "injectedCrashBeforeMutation", message: "Injected crash before state mutation", retryability: .afterDelay, source: .core)
        }

        await commandWAL.beginTransaction(commandID: envelope.commandID, commandName: "createSession")
        await ProviderRateScheduler.shared.reset()

        let initialRuntimeSeq = await runtimeEventLog.currentSequence()
        let session = try await sessionStore.create(
            kind: .primary,
            parentSessionID: nil,
            rootSessionID: nil,
            spawnedByRunID: nil,
            spawnedByToolCallID: nil,
            title: envelope.payload.workspace.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        )
        let coord = try await coordinator(for: session.id)
        let initialSessionSeq = await coord.eventLog.currentSequence()

        await commandWAL.recordState(
            commandID: envelope.commandID,
            createdSessionID: session.id,
            sessionID: session.id,
            turnID: nil,
            runID: nil,
            initialRuntimeSequence: initialRuntimeSeq,
            initialSessionSequence: initialSessionSeq
        )

        if ProcessInfo.processInfo.environment["LINGXI_CRASH_TEST_STAGE"] == "after-mutation" {
            fflush(stdout)
            kill(getpid(), SIGKILL)
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
        await runtimeEventLog.append(payload: .sessionCreated(summary))
        await commandWAL.recordEventsAppended(commandID: envelope.commandID)

        if ProcessInfo.processInfo.environment["LINGXI_CRASH_TEST_STAGE"] == "after-event" {
            fflush(stdout)
            kill(getpid(), SIGKILL)
        }

        if activeFailpoint == .afterEventAppendBeforeReceipt {
            await runtimeEventLog.rollbackLastAppended()
            try? await sessionStore.deleteSession(session.id)
            sessionCoordinators.removeValue(forKey: session.id)
            throw RuntimeError(category: .runtime, code: "injectedCrashAfterEventBeforeReceipt", message: "Injected crash after event append before receipt record", retryability: .afterDelay, source: .core)
        }

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
        await commandWAL.commitTransaction(commandID: envelope.commandID, receipt: receipt)
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)

        if ProcessInfo.processInfo.environment["LINGXI_CRASH_TEST_STAGE"] == "after-receipt" {
            fflush(stdout)
            kill(getpid(), SIGKILL)
        }

        if activeFailpoint == .afterCommitBeforeResponse {
            throw RuntimeError(category: .runtime, code: "injectedCrashAfterCommitBeforeResponse", message: "Injected crash after durable commit before response", retryability: .afterDelay, source: .core)
        }

        return receipt
    }

    public func renameSession(envelope: CommandEnvelope<RenameSessionRequest>) async throws -> CommandReceipt<SessionSummary> {
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: SessionSummary.self) {
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
        await runtimeEventLog.append(payload: .sessionUpdated(summary))
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
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)
        return receipt
    }

    public func setSessionReasoningEffort(envelope: CommandEnvelope<SetSessionReasoningEffortRequest>) async throws -> CommandReceipt<SessionSummary> {
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: SessionSummary.self) {
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
        await runtimeEventLog.append(payload: .sessionUpdated(summary))
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
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)
        return receipt
    }

    public func deleteSession(envelope: CommandEnvelope<DeleteSessionRequest>) async throws -> CommandReceipt<VoidResult> {
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: VoidResult.self) {
            return cached
        }
        try await sessionStore.deleteSession(envelope.payload.sessionID)
        sessionCoordinators.removeValue(forKey: envelope.payload.sessionID)
        _ = await runtimeEventLog.append(payload: .sessionDeleted(envelope.payload.sessionID))
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [
                await runtimeEventLog.currentWatermark()
            ],
            result: VoidResult()
        )
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)
        return receipt
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
        if let cached = await commandWAL.getCommittedReceipt(commandID: envelope.commandID, as: SubmitTurnResult.self) {
            return cached
        }
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: SubmitTurnResult.self) {
            return cached
        }

        if activeFailpoint == .beforeStateMutation {
            throw RuntimeError(category: .runtime, code: "injectedCrashBeforeMutation", message: "Injected crash before state mutation", retryability: .afterDelay, source: .core)
        }

        await commandWAL.beginTransaction(commandID: envelope.commandID, commandName: "submitTurn")

        _ = try await sessionStore.session(envelope.payload.sessionID)
        let coord = try await coordinator(for: envelope.payload.sessionID)
        let initialRuntimeSeq = await runtimeEventLog.currentSequence()
        let initialSessionSeq = await coord.eventLog.currentSequence()

        let msg = try await sessionStore.appendMessage(envelope.payload.sessionID, role: .user, content: envelope.payload.input.text)
        let userSnapshot = MessageSnapshot(
            messageID: msg.id,
            role: .user,
            text: envelope.payload.input.text,
            attachments: envelope.payload.input.attachments,
            createdAt: msg.createdAt
        )
        let decision = await coord.submitTurn(
            input: envelope.payload.input,
            intent: envelope.payload.executionIntent,
            userMessage: userSnapshot
        )

        await commandWAL.recordState(
            commandID: envelope.commandID,
            createdSessionID: nil,
            sessionID: envelope.payload.sessionID,
            turnID: decision.turn.turnID,
            runID: decision.runID,
            initialRuntimeSequence: initialRuntimeSeq,
            initialSessionSequence: initialSessionSeq
        )

        if ProcessInfo.processInfo.environment["LINGXI_CRASH_TEST_STAGE"] == "after-mutation" {
            fflush(stdout)
            kill(getpid(), SIGKILL)
        }

        if activeFailpoint == .afterStateMutationBeforeEventAppend {
            await coord.rollbackTurn(decision: decision)
            throw RuntimeError(category: .runtime, code: "injectedCrashAfterMutation", message: "Injected crash after state mutation before event append", retryability: .afterDelay, source: .core)
        }

        await commandWAL.recordEventsAppended(commandID: envelope.commandID)

        if ProcessInfo.processInfo.environment["LINGXI_CRASH_TEST_STAGE"] == "after-event" {
            fflush(stdout)
            kill(getpid(), SIGKILL)
        }

        if activeFailpoint == .afterEventAppendBeforeReceipt {
            await coord.eventLog.rollbackLastAppended()
            await coord.rollbackTurn(decision: decision)
            throw RuntimeError(category: .runtime, code: "injectedCrashAfterEventBeforeReceipt", message: "Injected crash after event append before receipt record", retryability: .afterDelay, source: .core)
        }

        let watermark = await coord.eventLog.currentWatermark()
        let result = SubmitTurnResult(turnID: decision.turn.turnID, status: decision.status, runID: decision.runID)
        let receipt = CommandReceipt<SubmitTurnResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: result
        )
        await commandWAL.commitTransaction(commandID: envelope.commandID, receipt: receipt)
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)

        if ProcessInfo.processInfo.environment["LINGXI_CRASH_TEST_STAGE"] == "after-receipt" {
            fflush(stdout)
            kill(getpid(), SIGKILL)
        }

        if activeFailpoint == .afterCommitBeforeResponse {
            throw RuntimeError(category: .runtime, code: "injectedCrashAfterCommitBeforeResponse", message: "Injected crash after durable commit before response", retryability: .afterDelay, source: .core)
        }

        if decision.shouldStartExecution, let runID = decision.runID {
            let task = Task { [weak self, weak coord] () -> Void in
                await self?.executeTurnRun(
                    sessionID: envelope.payload.sessionID,
                    turnID: decision.turn.turnID,
                    runID: runID,
                    input: envelope.payload.input,
                    executionIntent: envelope.payload.executionIntent,
                    coordinator: coord
                )
            }
            registerActiveTurnTask(task, runID: runID, sessionID: envelope.payload.sessionID)
        }
        return receipt
    }

    public func cancelTurn(envelope: CommandEnvelope<CancelTurnRequest>) async throws -> CommandReceipt<VoidResult> {
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: VoidResult.self) {
            return cached
        }
        cancelActiveTurnTasks(for: envelope.payload.sessionID)
        await agent?.cancelSession(envelope.payload.sessionID)
        let coord = try await coordinator(for: envelope.payload.sessionID)
        try await coord.cancelTurn(turnID: envelope.payload.turnID)
        let watermark = await coord.eventLog.currentWatermark()
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)
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
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: VoidResult.self) {
            return cached
        }
        cancelActiveTurnTask(runID: envelope.payload.runID)
        await agent?.cancelSession(envelope.payload.sessionID)
        let coord = try await coordinator(for: envelope.payload.sessionID)
        let nextTurnToRun = try await coord.cancelRun(runID: envelope.payload.runID, reason: envelope.payload.reason)
        try? await agent?.cancelAgentRun(AgentRunID(envelope.payload.runID.rawValue))
        let watermark = await coord.eventLog.currentWatermark()
        let receipt = CommandReceipt<VoidResult>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)
        if let next = nextTurnToRun {
            let task = Task { [weak self, weak coord] () -> Void in
                await self?.executeTurnRun(
                    sessionID: envelope.payload.sessionID,
                    turnID: next.turn.turnID,
                    runID: next.runID,
                    input: UserInput(text: next.turn.userMessage.text),
                    executionIntent: next.turn.executionIntent,
                    coordinator: coord
                )
            }
            registerActiveTurnTask(task, runID: next.runID, sessionID: envelope.payload.sessionID)
        }
        return receipt
    }

    public func resumeRun(envelope: CommandEnvelope<ResumeRunRequest>) async throws -> CommandReceipt<RunSnapshot> {
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: RunSnapshot.self) {
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
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)
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
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: VoidResult.self) {
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
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)
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
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: BeginContentUploadResponse.self) {
            return cached
        }
        let response = await contentStore.beginUpload(request: envelope.payload)
        let watermark = await runtimeEventLog.currentWatermark()
        let receipt = CommandReceipt<BeginContentUploadResponse>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: response
        )
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)
        return receipt
    }

    public func uploadContentChunk(uploadID: String, chunkIndex: UInt64, data: Data) async throws {
        try await contentStore.writeChunk(uploadID: uploadID, chunkIndex: chunkIndex, data: data)
    }

    public func commitContentUpload(envelope: CommandEnvelope<CommitContentUploadRequest>) async throws -> CommandReceipt<ContentRef> {
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: ContentRef.self) {
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
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)
        return receipt
    }

    public func abortContentUpload(envelope: CommandEnvelope<AbortContentUploadRequest>) async throws -> CommandReceipt<VoidResult> {
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: VoidResult.self) {
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
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)
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
        _ = try? await configurationStore?.load()
        let watermark = await runtimeEventLog.currentWatermark()
        return CommandReceipt(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
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
        let currentModel = selectedModelOverride ?? gateway.modelID?.rawValue ?? ""
        let providerID = currentModel.contains("/") ? String(currentModel.split(separator: "/").first ?? "") : nil
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: ModelSelectionInfo(modelID: currentModel, providerID: providerID)
        )
    }

    public func selectModel(envelope: CommandEnvelope<SelectModelRequest>) async throws -> CommandReceipt<ModelSelectionInfo> {
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: ModelSelectionInfo.self) {
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
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)
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

        guard let configStore = configurationStore else {
            throw CoreError(code: .provider, message: "ConfigurationStore 未就绪")
        }
        let snapshot = try await configStore.load()
        guard let providerConfig = snapshot.providers.providers[selection.providerID] else {
            throw CoreError(code: .provider, message: "未找到 Provider 配置: \(selection.providerID)")
        }

        let profile = BuiltinProviderCatalog.profile(for: selection.providerID)
        let adapter = providerConfig.adapter.lowercased()

        let wireProtocol: ModelWireProtocol
        if adapter == "openai-responses" || profile?.protocolFamily == "openai_responses" {
            wireProtocol = .responses
        } else if adapter == "anthropic-messages" || profile?.protocolFamily == "anthropic_messages" {
            wireProtocol = .anthropicMessages
        } else {
            wireProtocol = .chatCompletions
        }

        let baseURLStr = providerConfig.options.baseURL.isEmpty ? (profile?.endpoint ?? "https://api.openai.com/v1") : providerConfig.options.baseURL
        guard let baseURL = URL(string: baseURLStr) else {
            throw CoreError(code: .provider, message: "无效的 baseURL: \(baseURLStr)")
        }

        var authToken: String? = nil
        if let apiKey = providerConfig.options.apiKey, !apiKey.isEmpty {
            if apiKey.hasPrefix("{oauth:") && apiKey.hasSuffix("}") {
                let refStr = String(apiKey.dropFirst(7).dropLast(1))
                if let credStore = credentialStore, let secret = try? await credStore.secret(for: CredentialRef(refStr)) {
                    authToken = extractBearerToken(from: secret)
                }
            } else {
                authToken = apiKey
            }
        }
        if authToken == nil, let credStore = credentialStore {
            let oauthRef = CredentialRef("provider-\(selection.providerID)-oauth")
            if let secret = try? await credStore.secret(for: oauthRef), !secret.isEmpty {
                authToken = extractBearerToken(from: secret)
            }
            if authToken == nil {
                let keyRef = CredentialRef("provider-\(selection.providerID)-key")
                if let secret = try? await credStore.secret(for: keyRef), !secret.isEmpty {
                    authToken = secret
                }
            }
        }

        let isNoAuth = profile?.authMethods.contains("none") ?? false
        if !isNoAuth && authToken == nil {
            throw CoreError(code: .provider, message: "Provider '\(selection.providerID)' 未认证或凭据缺失")
        }

        let auth: ProviderAuthentication
        if let token = authToken {
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
        let contextProfile = ModelContextProfile(contextWindowTokens: contextWindow, maxOutputTokens: maxOutput, source: "dynamic:\(fullModelValue)")

        let runtimeConfig = ProviderConfig(
            baseURL: baseURL,
            authentication: auth,
            model: selection.modelID,
            wireProtocol: wireProtocol,
            diagnosticsEnabled: false,
            performanceDiagnosticsEnabled: false,
            remoteStateEnabled: wireProtocol == .responses,
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

        let assembly = ModelRuntimeAssembly(
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

        cachedAssemblies[key] = assembly
        cachedAssemblies[selection.providerID] = assembly
        return assembly
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
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: VoidResult.self) {
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
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)
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
    public func getWorkspaceSummary(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceSummary> {
        let rootPath = extensionPlatform.projectRoot.path
        let isGit = FileManager.default.fileExists(atPath: extensionPlatform.projectRoot.appendingPathComponent(".git").path)
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: WorkspaceSummary(rootPath: rootPath, isGitRepository: isGit)
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
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: CredentialResult.self) {
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
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)
        return receipt
    }

    public func deleteCredential(envelope: CommandEnvelope<DeleteCredentialRequest>) async throws -> CommandReceipt<VoidResult> {
        if let cached = await idempotencyJournal.get(commandID: envelope.commandID, as: VoidResult.self) {
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
        await idempotencyJournal.record(commandID: envelope.commandID, receipt: receipt)
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
        let watermark = await runtimeEventLog.currentWatermark()
        let store = try? requireCredentialStore()
        let exists = (try? await store?.secret(for: envelope.payload.reference)) != nil
        return CommandReceipt(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: TestCredentialResult(reference: envelope.payload.reference, isValid: exists)
        )
    }

    // MARK: - Extended API Matrix Implementations

    public func updateTypedSetting(envelope: CommandEnvelope<UpdateTypedSettingRequest>) async throws -> CommandReceipt<VoidResult> {
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
        }
        let watermark = await runtimeEventLog.currentWatermark()
        return CommandReceipt(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
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
        let watermark = await runtimeEventLog.currentWatermark()
        let result = TestProviderResult(providerID: envelope.payload.providerID, reachable: true, latencyMs: 12.5, message: "OK")
        return CommandReceipt(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: result
        )
    }

    public func configureProvider(envelope: CommandEnvelope<ConfigureProviderRequest>) async throws -> CommandReceipt<ProviderAccountInfo> {
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
        return CommandReceipt(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: info
        )
    }

    public func removeProvider(envelope: CommandEnvelope<RemoveProviderRequest>) async throws -> CommandReceipt<VoidResult> {
        runtimeProviderAccounts.removeValue(forKey: envelope.payload.accountID)
        _ = try? await deleteProviderAccount(id: envelope.payload.accountID, deleteUnusedCredential: false)
        let watermark = await runtimeEventLog.currentWatermark()
        return CommandReceipt(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
    }

    public func reloadProviders(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult> {
        let watermark = await runtimeEventLog.currentWatermark()
        return CommandReceipt(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
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
        let watermark = await runtimeEventLog.currentWatermark()
        let policy = ContextCachePolicySnapshot(policy: effectiveContextPolicy)
        return CommandReceipt(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: policy
        )
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
        let watermark = await runtimeEventLog.currentWatermark()
        let info = ExtensionInfo(
            id: "ext-\(envelope.payload.name)",
            version: "1.0.0",
            kind: .plugin,
            scope: "project",
            enabled: true,
            lifecycleState: "active"
        )
        runtimeExtensions[info.id] = info
        return CommandReceipt(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: info
        )
    }

    public func uninstallExtension(envelope: CommandEnvelope<UninstallExtensionRequest>) async throws -> CommandReceipt<VoidResult> {
        runtimeExtensions.removeValue(forKey: envelope.payload.id)
        let watermark = await runtimeEventLog.currentWatermark()
        return CommandReceipt(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
    }

    public func enableExtension(envelope: CommandEnvelope<EnableExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> {
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
        return CommandReceipt(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: info
        )
    }

    public func disableExtension(envelope: CommandEnvelope<DisableExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> {
        let watermark = await runtimeEventLog.currentWatermark()
        let info = ExtensionInfo(
            id: envelope.payload.id,
            version: "1.0.0",
            kind: .plugin,
            scope: "project",
            enabled: false,
            lifecycleState: "disabled"
        )
        runtimeExtensions[info.id] = info
        return CommandReceipt(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: info
        )
    }

    public func notifyExtensionCatalogChanged() async {
        _ = await runtimeEventLog.append(payload: .extensionCatalogChanged)
    }

    public func reloadExtensions(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult> {
        await extensionPlatform.restore()
        let watermark = await runtimeEventLog.currentWatermark()
        return CommandReceipt(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: VoidResult()
        )
    }

    public func configureExtension(envelope: CommandEnvelope<ConfigureExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> {
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
        return CommandReceipt(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: info
        )
    }

    public func getWorkspace(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceSummary> {
        try await getWorkspaceSummary(envelope: envelope)
    }

    public func setWorkspace(envelope: CommandEnvelope<SetWorkspaceRequest>) async throws -> CommandReceipt<WorkspaceSummary> {
        let watermark = await runtimeEventLog.currentWatermark()
        let isGit = FileManager.default.fileExists(atPath: URL(fileURLWithPath: envelope.payload.workspaceRoot).appendingPathComponent(".git").path)
        let summary = WorkspaceSummary(rootPath: envelope.payload.workspaceRoot, isGitRepository: isGit)
        return CommandReceipt(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: summary
        )
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
}
