import Foundation
import LingXiProtocol

/// LingXi Core 宿主：Core 的启动、状态、模块组装与对外契约实现。
public actor CoreHost: CoreEndpoint {
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
    private let budgetPlanner: ContextBudgetPlanner
    private let diagnosticsEnabled: Bool
    private let configurationStore: ConfigurationStore?
    private let credentialStore: (any CredentialStore)?
    private let subagentLimits: SubagentRuntimeLimits
    private let executionDeadlinePolicy: ExecutionDeadlinePolicy
    private let behaviorProfile: AgentBehaviorProfile
    private let restoreScheduler: SessionRestoreScheduler?
    private var agent: AgentRuntime?
    private var workflows: WorkflowRuntime?
    private var state: CoreState = .starting
    private var eventContinuations: [UUID: AsyncStream<CoreEvent>.Continuation] = [:]
    package var toolRuntimeRef: ToolRuntime { toolRuntime }
    package var workflowRuntimeRef: WorkflowRuntime? { workflows }

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
        let instructions = try AgentInstructionSet.load(workspace: workspace.url)
        let agentSettings = configuration?.agent ?? AgentSettings()
        let behaviorProfile = agentSettings.behaviorProfile ?? .build
        self.behaviorProfile = behaviorProfile
        // Preserve legacy request bytes unless behavior policy or repository instructions are configured.
        let systemContext = agentSettings.behaviorProfile != nil || instructions.rendered() != nil
            ? AgentBehaviorInstructions.render(profile: behaviorProfile, configured: agentSettings.systemContext, repository: instructions)
            : agentSettings.systemContext
        let effectiveMCPPager = mcpPager ?? MCPToolPager()
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
            globalRoot: persistentRoot?.appendingPathComponent("global-extensions", isDirectory: true) ?? FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-extensions-\(UUID().uuidString)", isDirectory: true),
            projectRoot: workspace.url,
            permissions: permissions,
            deadlinePolicy: executionDeadlinePolicy
        )
        let l2Budget = agentSettings.l2MaxCharacters
        let l1ProjectBudget = agentSettings.l1ProjectMaxCharacters
        contextPager = ContextPager(store: ProjectPageStore(persistence: persistent), workingSet: L2WorkingSet(characterBudget: l2Budget), projectCharacterBudget: l1ProjectBudget)
        projectScanner = ProjectScanner(root: workspace.url, sensitivePathPolicy: sensitivePaths)
        let codeIntelligence = agentSettings.codeIntelligenceEnabled ? CodeIntelligence(workspace: workspace, scanner: projectScanner, pager: contextPager) : nil
        toolRuntime = ToolRuntime(
            registry: toolRegistry ?? .builtin(workspace: workspace, contextPager: contextPager, scanner: projectScanner, questions: questions, processes: processes, codeIntelligence: codeIntelligence),
            permissions: permissions,
            mutations: ToolMutationCoordinator(pager: contextPager, scanner: projectScanner),
            outputArchive: ToolOutputArchive(persistence: persistent),
            outputSink: { [dataPlane] chunk in await dataPlane.emit(chunk) },
            mcpPager: effectiveMCPPager,
            subagents: subagentService,
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
        compactor = ContextCompactor(derivedStore: DerivedContextStore(persistence: persistent))
        budgetPlanner = ContextBudgetPlanner(policy: ContextBudgetPolicy(preferredActiveTokens: agentSettings.preferredActiveTokens))

        let effective = providerAssembly ?? .unavailable
        gateway = ModelGateway(assembly: effective.modelID.rawValue.isEmpty ? nil : effective, missingRequirements: providerAssembly == nil ? ["providers.defaultSelection"] : providerMissingRequirements, deadlinePolicy: executionDeadlinePolicy)
        let selection = defaultModelSelection ?? ModelSelection(providerID: effective.endpoint.providerID, accountID: effective.endpoint.accountID, profileID: effective.endpoint.profileID, modelID: effective.modelID.rawValue)
        modelResolver = SubagentModelResolver(defaultRuntime: effective, runtimes: modelRuntimes, defaultSelection: selection)
    }

    /// 注册控制面路由并进入 ready。
    public func start() async {
        guard state == .starting else { return }
        await extensionPlatform.restore()
        await questions.setEventSink { [weak self] request in
            await self?.agent?.markWaitingForQuestion(request, waiting: true)
            await self?.routeWorkflowQuestion(request)
            await self?.broadcast(request.originSessionID == request.rootSessionID ? .questionAsked(request) : .questionEscalated(request))
        }
        await bus.add(.ping) { _ in .pong }
        await bus.add(.getInfo) { [self] _ in .info(info) }
        await bus.add(.getState) { [self] _ in .state(await state) }
        await bus.add(.getProviderStatus) { [self] _ in
            .providerStatus(await providerStatus)
        }
        await bus.add(.listProviderProducts) { _ in .providerProducts(BuiltinProviderCatalog.connectableProducts()) }
        await bus.add(.listProviderAccounts) { [self] _ in .providerAccounts(try await providerAccounts()) }
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
            interactive: interactive,
            diagnosticsEnabled: diagnosticsEnabled,
            modelResolver: modelResolver,
            limits: subagentLimits,
            behaviorProfile: behaviorProfile,
            deadlinePolicy: executionDeadlinePolicy,
            restoreScheduler: restoreScheduler
        )
        self.agent = agent
        let workflows = await agent.makeWorkflowRuntime()
        self.workflows = workflows
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
            self.agent = nil
            setState(.stopped)
            return
        }
        setState(.ready)
    }

    public func shutdown() async {
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
        agent = nil
        workflows = nil
        eventContinuations.values.forEach { $0.finish() }
        eventContinuations.removeAll()
        setState(.stopped)
    }

    private func lifecycle(_ event: String, waitingOn: String) {
        guard ExecutionLifecycleTrace.enabled else { return }
        FileHandle.standardError.write(Data("[execution-lifecycle] event=\(event) kind=coreHost waitingOn=\(waitingOn)\n".utf8))
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
        if case let .permissionAsked(request) = event {
            Task { [weak self] in try? await self?.workflows?.suspendForOrigin(sessionID: request.sessionID, input: .permission(request)) }
        }
        eventContinuations.values.forEach { $0.yield(event) }
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

    private var providerStatus: ProviderStatus {
        ProviderStatus(
            configured: gateway.isConfigured,
            model: gateway.modelID?.rawValue,
            baseURL: nil,
            missingRequirements: gateway.missingRequirements
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
        let snapshot = try await requireConfigurationStore().load()
        return snapshot.providers.accounts.map(accountInfo)
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
        return accountInfo(account)
    }

    private func deleteProviderAccount(id: String, deleteUnusedCredential: Bool) async throws -> ProviderDisconnectResult {
        let store = try requireConfigurationStore()
        var snapshot = try await store.load()
        guard let account = snapshot.providers.accounts.first(where: { $0.id == id }) else { throw CoreError(code: .provider, message: "Provider Account 不存在") }
        snapshot.providers.accounts.removeAll { $0.id == id }
        if snapshot.providers.defaultSelection?.accountID == id {
            snapshot.providers.defaultSelection = nil
        }
        try await store.saveProviders(snapshot.providers)
        var deleted = false
        if deleteUnusedCredential, let reference = account.credential, !snapshot.providers.accounts.contains(where: { $0.credential == reference }) {
            try await requireCredentialStore().removeSecret(for: reference)
            deleted = true
        }
        return ProviderDisconnectResult(accountID: id, credentialDeleted: deleted)
    }

    private func deleteProviderCredential(_ reference: CredentialRef) async throws {
        let snapshot = try await requireConfigurationStore().load()
        guard !snapshot.providers.accounts.contains(where: { $0.credential == reference }) else { throw CoreError(code: .provider, message: "Credential 仍被其他 Account 使用") }
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
