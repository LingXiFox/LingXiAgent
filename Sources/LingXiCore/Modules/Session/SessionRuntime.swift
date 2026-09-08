import Foundation
import LingXiProtocol

public actor SessionRestoreScheduler {
    private var ready = false
    private var completed = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    func markReady() {
        guard !ready else { return }
        ready = true
        readyWaiters.forEach { $0.resume() }
        readyWaiters.removeAll()
    }

    func markCompleted() {
        guard !completed else { return }
        completed = true
        completionWaiters.forEach { $0.resume() }
        completionWaiters.removeAll()
    }

    public func waitUntilReady() async {
        guard !ready else { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    public func waitUntilCompleted() async {
        guard !completed else { return }
        await withCheckedContinuation { completionWaiters.append($0) }
    }
}

/// 一个 Session 的串行 Agent Lane。Tool 结果以结构化 parts 回写 Session，再进入下一步模型输入。
public actor SessionRuntime {
    private struct ActiveExecution {
        let id: UUID
        let task: Task<Void, Never>
        let streamID: StreamID
        let isRestore: Bool
    }

    private let store: any SessionStore
    private let sessionID: SessionID
    private let modelBus: ModelBus
    private let dataPlane: DataPlane
    private let contextEngine: L1ContextEngine
    private let toolRuntime: ToolRuntime
    private let questions: QuestionRuntime
    private let permissions: PermissionEngine
    private let performanceStore: PerformanceStore
    private let contextPager: ContextPager
    private let projectScanner: ProjectScanner
    private let compactor: ContextCompactor
    private let cacheController: ContextCacheController
    private let budgetPlanner: ContextBudgetPlanner
    private let persistence: SQLitePersistenceStore?
    private let eventSink: @Sendable (CoreEvent) async -> Void
    private let interactive: Bool
    private let diagnosticsEnabled: Bool
    private let runID: AgentRunID?
    private let rootRunID: AgentRunID?
    private let parentRunID: AgentRunID?
    private let rootSessionID: SessionID
    private let parentSessionID: SessionID?
    private let runObserver: (@Sendable (AgentRunStatus, String?, ModelUsage?, CoreError?, AgentTerminalTrace?) async -> Void)?
    private let executionProfile: SubagentExecutionProfile?
    private let systemContext: String?
    private let systemContextAtBeginning: Bool
    private let maximumAgentSteps: Int
    private let deadlinePolicy: ExecutionDeadlinePolicy
    private let restoreScheduler: SessionRestoreScheduler?
    private let diagnostics: RuntimeDiagnosticsStore?
    private var turnRunning = false
    private var activeExecution: ActiveExecution?
    private var shuttingDown = false
    private var toolBatches: [ToolExchangeBatch] = []
    private var compactionGeneration = 0
    private var latestModelRequestID: ModelRequestID?
    public private(set) var latestContextManifest: ProviderContextManifest?
    private var currentActiveEntries: [ContextEntry] = []
    private var activeStreamContinuation: AsyncThrowingStream<ModelEvent, Error>.Continuation?
    private var providerCacheEpoch: ProviderCacheEpoch?

    private func abortActiveProviderStream() {
        activeStreamContinuation?.finish(throwing: CancellationError())
        activeStreamContinuation = nil
    }

    private func canonicalToolDefinition(_ tool: ToolDefinition) -> String {
        var properties: [String] = []
        for key in tool.inputSchema.properties.keys.sorted() {
            guard let property = tool.inputSchema.properties[key] else { continue }
            let enumValues = property.enumValues?.joined(separator: ",") ?? ""
            let minimum = property.minimum.map { String($0) } ?? ""
            let maximum = property.maximum.map { String($0) } ?? ""
            properties.append("\(key):\(property.type.rawValue):\(property.description):\(enumValues):\(minimum):\(maximum)")
        }
        let required = tool.inputSchema.required.sorted().joined(separator: ",")
        let capabilities = tool.capability.kinds.map(\.rawValue).sorted().joined(separator: ",")
        let rawSchema: String
        if let rawInputSchema = tool.rawInputSchema {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            rawSchema = (try? String(decoding: encoder.encode(rawInputSchema), as: UTF8.self)) ?? ""
        } else {
            rawSchema = ""
        }
        return "\(tool.id.rawValue)|\(tool.name)|\(tool.description)|\(properties.joined(separator: ","))|\(required)|\(capabilities)|\(rawSchema)"
    }

    private func cacheEpoch(for tools: [ToolDefinition]) -> ProviderCacheEpoch {
        let toolSchema = tools.map(canonicalToolDefinition).joined(separator: "\n")
        let canonical = "system:\(systemContext ?? "")\ntools:\(toolSchema)"
        var hashValue: UInt64 = 14_695_981_039_346_656_037
        for byte in canonical.utf8 {
            hashValue ^= UInt64(byte)
            hashValue &*= 1_099_511_628_211
        }
        let hash = String(format: "%016llx", hashValue)
        if let providerCacheEpoch, providerCacheEpoch.hash == hash { return providerCacheEpoch }
        let epoch = ProviderCacheEpoch(epoch: (providerCacheEpoch?.epoch ?? 0) + 1, hash: hash)
        providerCacheEpoch = epoch
        return epoch
    }

    init(
        store: any SessionStore,
        sessionID: SessionID,
        modelBus: ModelBus,
        dataPlane: DataPlane,
        contextEngine: L1ContextEngine,
        toolRuntime: ToolRuntime,
        questions: QuestionRuntime,
        permissions: PermissionEngine,
        performanceStore: PerformanceStore,
        contextPager: ContextPager,
        projectScanner: ProjectScanner,
        eventSink: @escaping @Sendable (CoreEvent) async -> Void,
        compactor: ContextCompactor,
        budgetPlanner: ContextBudgetPlanner,
        persistence: SQLitePersistenceStore? = nil,
        cacheController: ContextCacheController? = nil,
        interactive: Bool = false,
        diagnosticsEnabled: Bool = false,
        runID: AgentRunID? = nil,
        rootRunID: AgentRunID? = nil,
        parentRunID: AgentRunID? = nil,
        rootSessionID: SessionID? = nil,
        parentSessionID: SessionID? = nil,
        executionProfile: SubagentExecutionProfile? = nil,
        systemContext: String? = nil,
        systemContextAtBeginning: Bool = true,
        maxAgentLoopSteps: Int = 32,
        runObserver: (@Sendable (AgentRunStatus, String?, ModelUsage?, CoreError?, AgentTerminalTrace?) async -> Void)? = nil,
        deadlinePolicy: ExecutionDeadlinePolicy = ExecutionDeadlinePolicy(),
        restoreScheduler: SessionRestoreScheduler? = nil,
        diagnostics: RuntimeDiagnosticsStore? = nil
    ) {
        self.store = store
        self.sessionID = sessionID
        self.modelBus = modelBus
        self.dataPlane = dataPlane
        self.contextEngine = contextEngine
        self.toolRuntime = toolRuntime
        self.questions = questions
        self.permissions = permissions
        self.performanceStore = performanceStore
        self.contextPager = contextPager
        self.projectScanner = projectScanner
        self.compactor = compactor
        self.cacheController = cacheController ?? ContextCacheController(contextPager: contextPager, scanner: projectScanner, compactor: compactor)
        self.eventSink = eventSink
        self.budgetPlanner = budgetPlanner
        self.persistence = persistence
        self.interactive = interactive
        self.diagnosticsEnabled = diagnosticsEnabled
        self.runID = runID
        self.rootRunID = rootRunID
        self.parentRunID = parentRunID
        self.rootSessionID = rootSessionID ?? sessionID
        self.parentSessionID = parentSessionID
        self.executionProfile = executionProfile
        self.systemContext = systemContext
        self.systemContextAtBeginning = systemContextAtBeginning
        maximumAgentSteps = max(1, executionProfile?.maxSteps ?? maxAgentLoopSteps)
        self.runObserver = runObserver
        self.deadlinePolicy = deadlinePolicy
        self.restoreScheduler = restoreScheduler
        self.diagnostics = diagnostics
    }

    public func restore() async throws {
        guard let persistence else { return }
        toolBatches = try await persistence.toolBatches(sessionID: sessionID)
        if let compacted = try await persistence.compaction(sessionID: sessionID) {
            compactionGeneration = compacted.generation
            await compactor.restoreResidencies(sessionID: sessionID, values: compacted.residencies)
        }
        for call in toolBatches.flatMap(\.toolCallStates) where call.reply == nil {
            switch call.request {
            case let .permission(request):
                await permissions.register(request, onAsk: { [eventSink] in
                    await eventSink(.permissionAsked(request))
                }, onReply: { [weak self] reply in
                    await self?.humanReply(batchID: call.provenance.batchID, callID: call.call.callID, request: .permission(request), reply: .permission(reply))
                    await self?.resumeDurableTurn()
                })
            case let .question(request):
                await questions.register(request) { [weak self] _, reply in
                    await self?.humanReply(batchID: call.provenance.batchID, callID: call.call.callID, request: .question(request), reply: .question(reply))
                    await self?.resumeDurableTurn()
                }
            case nil:
                break
            }
        }
        if toolBatches.contains(where: { $0.state == .pending || $0.state == .recoveryRequired }) && !toolBatches.flatMap(\.toolCallStates).contains(where: { $0.request != nil && $0.reply == nil }) {
            await resumeDurableTurn()
        }
    }

    /// Continue a persisted Tool batch before making the next provider request.
    private func resumeDurableTurn() async {
        guard !shuttingDown, !turnRunning else { return }
        turnRunning = true
        let profiler = TurnProfiler(sessionID: sessionID, enabled: performanceStore.enabled)
        let opened = await dataPlane.openAgentStream()
        let handle = TurnHandle(sessionID: sessionID, streamID: opened.stream.id)
        let task = (try? await store.session(sessionID).messages.last { $0.role == .user }?.content) ?? ""
        let runID = self.runID
        let rootSessionID = self.rootSessionID
        let parentSessionID = self.parentSessionID
        let sessionID = self.sessionID
        let deadline = deadlinePolicy.deadline(for: runID == nil ? .agentRun : .subagent, requested: executionProfile?.timeoutSeconds.map { .seconds($0) })
        let executionID = UUID()
        let turnTask = Task {
            await AgentExecutionContext.$current.withValue(runID.map { (sessionID: sessionID, runID: $0, rootSessionID: rootSessionID, parentSessionID: parentSessionID) }) {
                await self.runTurn(handle: handle, sink: opened.sink, task: task, profiler: profiler, deadline: deadline, executionID: executionID, resume: true)
            }
        }
        activeExecution = ActiveExecution(id: executionID, task: turnTask, streamID: opened.stream.id, isRestore: true)
        await restoreScheduler?.markReady()
        await dataPlane.trackAgent(turnTask, streamID: opened.stream.id)
    }

    /// 启动一轮对话并立即返回 DMA 通道；同一 Session 只允许一个活动 turn。
    public func startTurn(_ content: String) async throws -> OpenedStream {
        guard !shuttingDown, !turnRunning else {
            throw CoreError(code: .turnAlreadyRunning, message: "该 Session 已有进行中的对话轮次")
        }
        turnRunning = true
        let profiler = TurnProfiler(sessionID: sessionID, enabled: performanceStore.enabled)
        do {
            _ = try await store.session(sessionID)
            let userMessage = try await store.appendMessage(sessionID, role: .user, content: content)
            let userEntry = ContextEntry(messageID: userMessage.id, role: .user, source: .userMessage, part: .text(content))
            var updatedEntries = currentActiveEntries
            if updatedEntries.isEmpty {
                if let snapshot = await contextEngine.latestSnapshot(for: sessionID) {
                    updatedEntries = snapshot.entries
                } else if let session = try? await store.session(sessionID) {
                    let residentPages = await cacheController.residentPages(for: sessionID)
                    updatedEntries = await contextEngine.entries(for: session, projectPages: residentPages, systemContext: systemContext, systemContextAtBeginning: systemContextAtBeginning)
                }
            }
            if !updatedEntries.contains(where: { $0.messageID == userMessage.id }) {
                updatedEntries.append(userEntry)
            }
            await syncL1ResidentAccounting(with: updatedEntries)
            guard modelBus.gateway.modelID != nil else {
                throw CoreError(
                    code: .provider,
                    message: "未配置模型 Provider；请检查 providers.json 与 CredentialStore: \(modelBus.gateway.missingRequirements.joined(separator: ", "))"
                )
            }
            let opened = await dataPlane.openAgentStream()
            let handle = TurnHandle(sessionID: sessionID, streamID: opened.stream.id)
            await eventSink(.turnStarted(handle))
            await runObserver?(.running, nil, nil, nil, nil)
            let runID = self.runID
            let rootSessionID = self.rootSessionID
            let parentSessionID = self.parentSessionID
            let sessionID = self.sessionID
            let deadline = deadlinePolicy.deadline(for: runID == nil ? .agentRun : .subagent, requested: executionProfile?.timeoutSeconds.map { .seconds($0) })
            let executionID = UUID()
            let turnTask = Task {
                await AgentExecutionContext.$current.withValue(runID.map { (sessionID: sessionID, runID: $0, rootSessionID: rootSessionID, parentSessionID: parentSessionID) }) {
                    await self.runTurn(handle: handle, sink: opened.sink, task: content, profiler: profiler, deadline: deadline, executionID: executionID)
                }
            }
            activeExecution = ActiveExecution(id: executionID, task: turnTask, streamID: opened.stream.id, isRestore: false)
            await dataPlane.trackAgent(turnTask, streamID: opened.stream.id)
            return opened.stream
        } catch {
            turnRunning = false
            throw error
        }
    }

    private func runTurn(
        handle: TurnHandle,
        sink: AsyncThrowingStream<StreamChunk, Error>.Continuation,
        task: String,
        profiler: TurnProfiler,
        deadline: ExecutionDeadline,
        executionID: UUID,
        resume: Bool = false
    ) async {
        var index = 0
        var finalUsage: ModelUsage?
        var finalReason: ModelFinishReason?
            var lastSuccessfulRead: (signature: ToolRuntime.ReadOnlySignature, content: String)?
            var deterministicFailures: [String: String] = [:]
        let executionProfile = self.executionProfile

        do {
            try ensureExecuting(executionID)
            let userTurnID = try await store.session(sessionID).messages.last(where: { $0.role == .user })?.id
                ?? MessageID("recovery:\(sessionID.rawValue):\(runID?.rawValue ?? "session")")
            if resume {
                let session = try await store.session(sessionID)
                try await settleDurableBatches(session: session, deadline: deadline, profiler: profiler)
                try ensureExecuting(executionID)
            }
            var lastCallBatchSignature: String?
            var consecutiveIdenticalBatches = 0
            var consecutiveIdenticalFailures = 0
            var lastObservedFailure: String?
            var lastExecutedCall: ToolCall?
            var lastObservedContent: String?
            var pendingLifecycleTraces: [ToolLifecycleTrace] = []

            for step in 0..<maximumAgentSteps {
                try Task.checkCancellation()
                let currentModelStepID = ModelStepID()
                let currentStepNumber = step + 1
                trace("agent.step.begin", step: step + 1)
                for lifecycle in pendingLifecycleTraces { lifecycle.record(.nextModelStepStarted) }
                pendingLifecycleTraces.removeAll(keepingCapacity: true)
                finalUsage = nil
                finalReason = nil
                let session = try await store.session(sessionID)
                let clock = ContinuousClock()
                let contextStarted = clock.now
                trace("context.build.begin", step: step + 1)
                let availableTools = await toolRuntime.availableDefinitions(sessionID: sessionID, runID: runID, interactive: interactive, executionProfile: executionProfile)
                let toolTokens = ConservativeTokenEstimator().estimate(tools: availableTools)
                let endpointProfile = modelBus.gateway.contextProfile
                let requestedWindow = executionProfile?.contextProfile.flatMap(Int.init)
                let contextProfile = ModelContextProfile(contextWindowTokens: min(endpointProfile.contextWindowTokens, requestedWindow ?? endpointProfile.contextWindowTokens), maxOutputTokens: endpointProfile.maxOutputTokens, recommendedOutputReserveTokens: endpointProfile.recommendedOutputReserveTokens, source: endpointProfile.source)
                let preferred = executionProfile?.budgetProfile.flatMap(Int.init)
                let planner = preferred.map { budgetPlanner.with(preferredActiveTokens: $0) } ?? budgetPlanner
                let budget = planner.plan(profile: contextProfile, toolTokens: toolTokens)
                profiler.recordBudget(budget, modelWindow: contextProfile.contextWindowTokens)

                // Cache Controller Scheduling Invariant:
                // Prompt Builder ONLY reads: Pinned Context + L1 Working Set + Current Turn.
                // Dynamic pages enter L1 ONLY via Cache Controller explicit retrieval.
                let residentPages = await cacheController.residentPages(for: sessionID)
                let allEntries = await contextEngine.entries(for: session, projectPages: residentPages, systemContext: systemContext, systemContextAtBeginning: systemContextAtBeginning)
                let compacted = try await compactor.compact(sessionID: sessionID, entries: allEntries, budget: budget, batches: toolBatches, projectBackedContents: Set(residentPages.map(\.content)))
                profiler.recordCompaction(compacted, budget: budget)
                if compacted.triggered { compactionGeneration += 1 }
                if compacted.triggered { try await persistCompaction() }

                let residentDerived = await cacheController.residentDerivedPages(for: sessionID)
                let residentDerivedEntries: [ContextEntry] = residentDerived.map { page in
                    ContextEntry(messageID: MessageID(page.id), role: .system, source: .derivedPage, part: .text("[Session context]\n\(page.content)"))
                }
                var finalEntries = compacted.entries + residentDerivedEntries
                var finalTokens = ConservativeTokenEstimator().estimate(entries: finalEntries)
                if finalTokens > budget.hardInputLimit {
                    let emergency = try await compactor.compact(sessionID: sessionID, entries: finalEntries, budget: budget, batches: toolBatches, projectBackedContents: Set(residentPages.map(\.content)), trigger: .emergencyHardLimit)
                    profiler.recordCompaction(emergency, budget: budget)
                    finalEntries = emergency.entries
                    finalTokens = emergency.afterTokens
                    if emergency.triggered { compactionGeneration += 1 }
                    if emergency.triggered { try await persistCompaction() }
                }
                await cacheController.recordProviderInputTokens(sessionID: sessionID, tokens: finalTokens)
                await syncL1ResidentAccounting(with: finalEntries)
                let context = await contextEngine.snapshot(for: session, activeEntries: finalEntries, systemContext: systemContext, estimatedTokens: finalTokens, mandatoryTokens: compacted.mandatoryFloor, liveToolBatchCount: toolBatches.filter { $0.state != .consumed }.count, compactionGeneration: compactionGeneration)

                let manifestEntries: [ContextManifestEntry] = finalEntries.compactMap { entry in
                    let tokenCount = ConservativeTokenEstimator().estimate(text: ContextCompactor.content(of: entry.part))
                    let sourceKind: String
                    let origin: String
                    let inclusionReason: String
                    let cacheProvenance: String
                    let sourceID = entry.messageID?.rawValue ?? entry.page?.id ?? "transient"

                    switch entry.source {
                    case .system:
                        sourceKind = "Pinned"
                        origin = "systemContext"
                        inclusionReason = "Pinned system prompt"
                        cacheProvenance = "pinned"
                    case .userMessage:
                        if entry.messageID == session.messages.last?.id {
                            sourceKind = "Current Turn"
                            origin = "currentTurn"
                            inclusionReason = "Active turn user message"
                            cacheProvenance = "currentTurn"
                        } else {
                            sourceKind = "L1"
                            origin = entry.messageID?.rawValue ?? "history"
                            inclusionReason = "L1 historical user turn"
                            cacheProvenance = "l1WorkingSet"
                        }
                    case .assistantMessage:
                        sourceKind = "L1"
                        origin = entry.messageID?.rawValue ?? "history"
                        inclusionReason = "L1 historical assistant response"
                        cacheProvenance = "l1WorkingSet"
                    case .toolCall, .toolResult:
                        sourceKind = "L1"
                        origin = entry.messageID?.rawValue ?? "tool"
                        inclusionReason = "L1 tool execution record"
                        cacheProvenance = "l1WorkingSet"
                    case .projectPage:
                        sourceKind = "L1"
                        origin = entry.page?.path ?? "projectPage"
                        inclusionReason = "Dynamic page-in via Cache Controller"
                        cacheProvenance = "cacheControllerL1"
                    case .derivedPage:
                        sourceKind = "L1"
                        origin = entry.page?.path ?? "derivedSummary"
                        inclusionReason = "Dynamic page-in via Cache Controller"
                        cacheProvenance = "cacheControllerL1"
                    }
                    return ContextManifestEntry(
                        sourceKind: sourceKind,
                        sourceID: sourceID,
                        origin: origin,
                        tokenCount: tokenCount,
                        inclusionReason: inclusionReason,
                        cacheProvenance: cacheProvenance
                    )
                }
                let manifest = ProviderContextManifest(
                    sessionID: sessionID,
                    step: step + 1,
                    entries: manifestEntries,
                    totalTokens: finalTokens
                )
                self.latestContextManifest = manifest
                trace("context.manifest", step: step + 1)
                trace("context.build.end", step: step + 1)
                profiler.recordContext(context, build: contextStarted.duration(to: clock.now))
                let dispatchStarted = clock.now
                trace("model.next.begin", step: step + 1)
                let effectiveContinuationID = toolBatches.last(where: { $0.state == .settledAwaitingConsumption })?.continuationRequestID ?? latestModelRequestID
                let supportsTools = modelBus.gateway.endpoint?.capabilities.toolCalling ?? true
                let effectiveTools = supportsTools ? availableTools : []
                let supportsReasoning = modelBus.gateway.endpoint?.capabilities.reasoning ?? true
                let effectiveReasoning = supportsReasoning ? modelBus.gateway.reasoning : nil
                let request = ModelRequest(
                    continuationOf: effectiveContinuationID,
                    model: try modelID(),
                    executionID: runID,
                    messages: context.modelMessages(),
                    tools: effectiveTools,
                    reasoning: effectiveReasoning,
                    debugStep: step + 1,
                    overallTimeoutSeconds: deadline.remainingSeconds(),
                    idleTimeoutSeconds: deadlinePolicy.idleTimeout(for: .provider).map { Self.durationSeconds($0) }
                )
                if finalTokens > budget.hardInputLimit {
                    throw CoreError(code: .contextBudgetExceeded, message: "最终模型请求超出输入预算")
                }
                try ModelRequestProtocolValidator.validate(context.entries)
                profiler.recordProtocolValidator(liveBatches: toolBatches.filter { $0.state != .consumed }.count)
                let submittedBatchIDs = Set(toolBatches.filter { $0.state == .settledAwaitingConsumption }.map(\.batchID))
                trace("provider.stream.begin", step: step + 1)
                latestModelRequestID = request.requestID

                let toolSchemaTokens = ConservativeTokenEstimator().estimate(tools: effectiveTools)
                let systemPinnedTokens = context.entries.filter { $0.source == .system }.reduce(0) { $0 + ConservativeTokenEstimator().estimate(entries: [$1]) }
                let currentTurnTokens = context.entries.filter { $0.messageID == userTurnID }.reduce(0) { $0 + ConservativeTokenEstimator().estimate(entries: [$1]) }
                let l1Tokens = max(0, finalTokens - systemPinnedTokens - currentTurnTokens)
                let providerFramingTokens = budgetPlanner.policy.fixedOverheadTokens
                let estimatedPromptTokens = finalTokens + toolSchemaTokens + providerFramingTokens
                let cacheTelemetry = ProviderCacheTelemetry(
                    stablePrefixTokens: systemPinnedTokens + toolSchemaTokens,
                    reusableHistoryTokens: l1Tokens,
                    volatileTailTokens: currentTurnTokens + providerFramingTokens,
                    epoch: cacheEpoch(for: effectiveTools)
                )
                let triggerReason = step == 0 ? "initial_turn_prompt" : "tool_result_continuation"
                let callTrace = ProviderCallTrace(
                    sessionID: sessionID,
                    userTurnID: userTurnID,
                    runID: runID,
                    parentRunID: parentRunID,
                    providerRequestID: "local:\(request.requestID.rawValue)",
                    sequence: step + 1,
                    reason: triggerReason,
                    model: request.model.rawValue,
                    estimatedPromptTokens: estimatedPromptTokens,
                    actualUsage: nil,
                    toolSchemaTokens: toolSchemaTokens,
                    toolCount: effectiveTools.count,
                    l1Tokens: l1Tokens,
                    systemPinnedTokens: systemPinnedTokens,
                    currentTurnTokens: currentTurnTokens,
                    providerFramingTokens: providerFramingTokens,
                    retryAttempt: 0,
                    cacheTelemetry: cacheTelemetry
                )
                profiler.recordProviderCall(callTrace)

                let initialActivity = ProviderActivitySnapshot(
                    sessionID: sessionID,
                    runID: runID,
                    providerRequestID: "local:\(request.requestID.rawValue)",
                    state: .requesting,
                    model: request.model.rawValue,
                    updatedAt: Date()
                )
                await eventSink(.providerActivityChanged(initialActivity))

                let events: AsyncThrowingStream<ModelEvent, Error>
                do {
                    events = try await modelBus.stream(request)
                } catch {
                    let failedActivity = ProviderActivitySnapshot(
                        sessionID: sessionID,
                        runID: runID,
                        providerRequestID: "local:\(request.requestID.rawValue)",
                        state: .failed,
                        model: request.model.rawValue,
                        updatedAt: Date()
                    )
                    await eventSink(.providerActivityChanged(failedActivity))
                    profiler.updateLastProviderCallRateMetrics(await modelBus.gateway.rateMetrics(for: request.requestID))
                    throw error
                }
                let dispatch = dispatchStarted.duration(to: clock.now)
                let streamStarted = clock.now
                var text = ""
                var visibleReasoning = false
                var calls: [ToolCall] = []
                var providerRequestID = "local:\(request.requestID.rawValue)"

                var streamContinuation: AsyncThrowingStream<ModelEvent, Error>.Continuation?
                let cancellableEvents = AsyncThrowingStream<ModelEvent, Error> { cont in
                    streamContinuation = cont
                }
                activeStreamContinuation = streamContinuation
                let pumpTask = Task {
                    do {
                        for try await event in events {
                            streamContinuation?.yield(event)
                        }
                        streamContinuation?.finish()
                    } catch {
                        streamContinuation?.finish(throwing: error)
                    }
                }
                defer {
                    activeStreamContinuation = nil
                    pumpTask.cancel()
                }

                try await withTaskCancellationHandler {
                    for try await event in cancellableEvents {
                        if Task.isCancelled || shuttingDown { throw CancellationError() }
                        if await ProviderActivityRegistry.shared.isCancelled(providerRequestID: providerRequestID, runID: runID) {
                            throw CancellationError()
                        }
                        switch event {
                        case let .providerRequestID(value):
                            providerRequestID = value
                            profiler.updateLastProviderCallRequestID(value)
                            let snapshot = await ProviderActivityRegistry.shared.record(
                                sessionID: sessionID,
                                runID: runID,
                                providerRequestID: value,
                                state: .streaming,
                                model: request.model.rawValue
                            )
                            await eventSink(.providerActivityChanged(snapshot))
                        case .started:
                            trace("provider.stream.start", step: step + 1)
                        case let .textDelta(delta):
                            sink.yield(StreamChunk(streamID: handle.streamID, sessionID: sessionID, agentRunID: runID, modelStepID: currentModelStepID, stepNumber: currentStepNumber, index: index, text: delta, kind: .text))
                            profiler.recordText(delta, streamElapsed: streamStarted.duration(to: clock.now))
                            index += 1
                            text += delta
                        case let .reasoningDelta(delta):
                            sink.yield(StreamChunk(streamID: handle.streamID, sessionID: sessionID, agentRunID: runID, modelStepID: currentModelStepID, stepNumber: currentStepNumber, index: index, text: delta, kind: .reasoning))
                            profiler.recordReasoning(delta, streamElapsed: streamStarted.duration(to: clock.now))
                            visibleReasoning = true
                            index += 1
                        case .toolCallStarted, .toolCallDelta:
                            break // Tool arguments 只在完整聚合后进入控制面。
                        case let .toolCallCompleted(call):
                            calls.append(call.withProvenance(sessionID: sessionID, agentRunID: runID, modelStepID: currentModelStepID))
                        case let .usage(usage):
                            finalUsage = usage
                            profiler.recordUsage(usage)
                            profiler.updateLastProviderCallUsage(usage)
                        case let .completed(reason):
                            finalReason = reason
                        case let .failed(error):
                            throw error
                        }
                    }
                } onCancel: {
                    streamContinuation?.finish(throwing: CancellationError())
                }
                try ensureExecuting(executionID)
                if modelBus.gateway.endpoint?.wireProtocol == .chatCompletions,
                   (finalUsage?.reasoningTokens ?? 0) > 0,
                   !visibleReasoning {
                    throw CoreError(code: .modelStream, message: "Provider 返回 reasoning_tokens 但未产生 visible reasoning")
                }
                let rateMetrics = await modelBus.gateway.rateMetrics(for: request.requestID)
                profiler.updateLastProviderCallRateMetrics(rateMetrics)
                trace("provider.stream.end", step: step + 1)
                await diagnostics?.record(
                    kind: .provider,
                    event: "provider.call.trace",
                    sessionID: sessionID,
                    runID: runID,
                    parentRunID: parentRunID,
                    providerRequestID: providerRequestID,
                    metadata: [
                        "sequence": String(step + 1),
                        "reason": triggerReason,
                        "model": request.model.rawValue,
                        "estimatedPromptTokens": String(estimatedPromptTokens),
                        "actualInputTokens": finalUsage?.inputTokens.map(String.init) ?? "none",
                        "toolSchemaTokens": String(toolSchemaTokens),
                        "toolCount": String(effectiveTools.count),
                        "l1Tokens": String(l1Tokens),
                        "systemPinnedTokens": String(systemPinnedTokens),
                        "currentTurnTokens": String(currentTurnTokens),
                        "providerFramingTokens": String(providerFramingTokens),
                        "retryAttempt": String(rateMetrics.retryCount),
                        "retryCount": String(rateMetrics.retryCount),
                        "rateWaitMilliseconds": String(rateMetrics.rateWaitMilliseconds),
                        "rateLimit429Count": String(rateMetrics.rateLimit429Count)
                    ]
                )

                try await consumeSettledBatches(submittedBatchIDs)
                profiler.recordModel(dispatch: dispatch, stream: streamStarted.duration(to: clock.now))

                guard !calls.isEmpty else {
                    await toolRuntime.finishMCPProviderStep(sessionID: sessionID)
                    await completeTurn(
                        handle: handle,
                        sink: sink,
                        content: text,
                        finishReason: finalReason,
                        usage: finalUsage,
                        profiler: profiler,
                        executionID: executionID
                    )
                    return
                }

                var assistantParts: [SessionMessagePart] = calls.map(SessionMessagePart.toolCall)
                if !text.isEmpty { assistantParts.insert(.text(text), at: 0) }
                trace("tool.batch.begin", step: step + 1, toolCount: calls.count)
                await runObserver?(.waitingForTool, nil, finalUsage, nil, nil)
                trace("tool.batch.count", step: step + 1, toolCount: calls.count)
                guard Set(calls.map(\.callID)).count == calls.count else {
                    throw CoreError(code: .modelStream, message: "Tool batch 含重复 toolCallID")
                }
                trace("session.parts.append.begin", step: step + 1, toolCount: calls.count)
                let assistantMessage: Message
                if persistence != nil { assistantMessage = Message(id: MessageID(UUID().uuidString), role: .assistant, parts: assistantParts, createdAt: .now) }
                else { assistantMessage = try await store.appendMessage(sessionID, role: .assistant, parts: assistantParts) }
                let batchID = UUID().uuidString
                let batch = ToolExchangeBatch(batchID: batchID, sessionID: sessionID, assistantMessageID: assistantMessage.id, toolCalls: calls, toolCallStates: calls.map { DurableToolCall(call: $0, provenance: ToolCallProvenance(batchID: batchID, sessionID: sessionID, agentRunID: runID, providerRequestID: request.requestID, providerStep: step + 1)) }, continuationRequestID: request.requestID, providerStep: step + 1, state: .pending, estimatedTokens: ConservativeTokenEstimator().estimate(entries: assistantParts.map { ContextEntry(messageID: assistantMessage.id, role: .assistant, source: .toolCall, part: $0) }))
                if let persistence { try await persistence.appendAssistantMessageAndBatch(sessionID: sessionID, message: assistantMessage, batch: batch) }
                toolBatches.append(batch)
                let assistantEntries = assistantParts.map { ContextEntry(messageID: assistantMessage.id, role: .assistant, source: .toolCall, part: $0) }
                var updatedEntries = currentActiveEntries
                updatedEntries.append(contentsOf: assistantEntries)
                await syncL1ResidentAccounting(with: updatedEntries)
                trace("session.parts.append.end", step: step + 1, toolCount: calls.count)

                trace("tool.batch.settle.begin", step: step + 1, toolCount: calls.count)
                let signatures = calls.map { try? toolRuntime.readOnlySignature(for: $0) }
                var outcomes = Array<ToolRuntime.ExecutionOutcome?>(repeating: nil, count: calls.count)
                var primaryByIndex: [Int: Int] = [:]
                var primaryBySignature: [ToolRuntime.ReadOnlySignature: Int] = [:]

                for (offset, call) in calls.enumerated() {
                    await eventSink(.toolCallCompleted(call.withProvenance(sessionID: sessionID, agentRunID: runID, modelStepID: currentModelStepID)))
                    trace("tool.execute.begin", step: step + 1, toolCallID: call.callID)
                    if let signature = signatures[offset], let previous = lastSuccessfulRead, previous.signature == signature {
                        outcomes[offset] = duplicateOutcome(for: call, signature: signature, content: previous.content)
                    } else if let failureSignature = deterministicFailures[failureKey(for: call)] {
                        outcomes[offset] = repeatedFailureOutcome(for: call, signature: failureSignature)
                    } else if let signature = signatures[offset], let primary = primaryBySignature[signature] {
                        primaryByIndex[offset] = primary
                    } else {
                        if let signature = signatures[offset] { primaryBySignature[signature] = offset }
                        primaryByIndex[offset] = offset
                    }
                }

                await withTaskGroup(of: (Int, ToolRuntime.ExecutionOutcome).self) { group in
                    for (offset, call) in calls.enumerated() where outcomes[offset] == nil && primaryByIndex[offset] == offset {
                        let executionCall = call.withProvenance(sessionID: sessionID, agentRunID: runID, modelStepID: currentModelStepID)
                        let observer = ToolExecutionObserver(
                            permissionAsked: { request in await self.waitingForHuman(batchID: batchID, callID: call.callID, request: .permission(request)) },
                            permissionResolved: { request, reply in await self.humanReply(batchID: batchID, callID: call.callID, request: .permission(request), reply: .permission(reply)) },
                            executionClaimed: { claim in
                                await self.executionClaimed(batchID: batchID, callID: call.callID, claim: claim)
                                await self.eventSink(.toolExecutionClaimed(executionCall))
                            },
                            questionAsked: { request in await self.waitingForHuman(batchID: batchID, callID: call.callID, request: .question(request)) },
                            questionResolved: { request, reply in await self.humanReply(batchID: batchID, callID: call.callID, request: .question(request), reply: .question(reply)) }
                        )
                        group.addTask { [toolRuntime, sessionID, eventSink] in
                            let outcome = await toolRuntime.executeWithMetrics(executionCall, sessionID: sessionID, projectID: session.projectID ?? ProjectID("ephemeral"), executionProfile: executionProfile, onPermissionAsked: { request in
                                await eventSink(.permissionAsked(request))
                            }, observer: observer)
                            return (offset, outcome)
                        }
                    }
                    for await (offset, outcome) in group { outcomes[offset] = outcome }
                }
                try Task.checkCancellation()

                for (offset, call) in calls.enumerated() where outcomes[offset] == nil {
                    guard let primary = primaryByIndex[offset], let previous = outcomes[primary] else {
                        throw CoreError(code: .modelStream, message: "Tool batch settlement 缺少结果: \(call.callID.rawValue)")
                    }
                    outcomes[offset] = duplicateOutcome(for: call, signature: signatures[offset]!, content: previous.result.content)
                }

                let settled = outcomes.compactMap { $0 }
                guard settled.count == calls.count, zip(calls, settled).allSatisfy({ $0.0.callID == $0.1.result.callID }) else {
                    throw CoreError(code: .modelStream, message: "ToolCall 与 ToolResult ID 不匹配")
                }
                for (offset, outcome) in settled.enumerated() {
                    let call = calls[offset]
                    trace("tool.execute.end", step: step + 1, toolCallID: call.callID)
                    profiler.recordTool(outcome)
                    let result = outcome.result
                    await completedToolCall(batchID: batchID, result: result)
                    outcome.lifecycleTrace?.record(.resultCommitted, exitCode: result.exitCode.map { Int32($0) })
                    if let signature = signatures[offset], result.success || result.error?.code == "duplicateToolCall" {
                        lastSuccessfulRead = (signature, result.content)
                    } else {
                        lastSuccessfulRead = nil
                    }
                    if let error = result.error, isDeterministicFailure(result) {
                        deterministicFailures[failureKey(for: call)] = "\(error.code):\(error.message)"
                    }
                    await eventSink(.toolResult(result.withProvenance(sessionID: sessionID, agentRunID: runID, modelStepID: currentModelStepID)))
                    outcome.lifecycleTrace?.record(.applicationProjectionReceived, exitCode: result.exitCode.map { Int32($0) })
                }
                trace("session.parts.append.begin", step: step + 1, toolCount: settled.count)
                let resultMessage: Message
                if persistence != nil { resultMessage = Message(id: MessageID(UUID().uuidString), role: .tool, parts: settled.map { .toolResult($0.result) }, createdAt: .now) }
                else { resultMessage = try await store.appendMessage(sessionID, role: .tool, parts: settled.map { .toolResult($0.result) }) }
                try await settleBatch(batchID: batchID, resultMessageID: resultMessage.id, results: settled.map(\.result), resultMessage: resultMessage)
                await toolRuntime.finishMCPProviderStep(sessionID: sessionID)
                let hasCancelledTool = settled.contains {
                    $0.result.outcome == .cancelled ||
                    $0.result.error?.code == CoreError.Code.toolCancelled.rawValue ||
                    $0.result.error?.code == CoreError.Code.permissionCancelled.rawValue
                }
                if Task.isCancelled || shuttingDown || hasCancelledTool {
                    throw CoreError(code: .toolCancelled, message: "AgentRun 已取消")
                }
                await runObserver?(.running, nil, finalUsage, nil, nil)
                let toolResultEntries = settled.map { ContextEntry(messageID: resultMessage.id, role: .tool, source: .toolResult, part: .toolResult($0.result)) }
                var postToolEntries = currentActiveEntries
                postToolEntries.append(contentsOf: toolResultEntries)
                await syncL1ResidentAccounting(with: postToolEntries)
                trace("session.parts.append.end", step: step + 1, toolCount: settled.count)
                trace("tool.batch.settle.end", step: step + 1, toolCount: calls.count)
                pendingLifecycleTraces = settled.compactMap(\.lifecycleTrace)

                lastExecutedCall = calls.last
                lastObservedContent = settled.last?.result.content

                // No-progress detection:
                let batchSignature = calls.map { "\($0.toolID.rawValue):\($0.arguments)" }.joined(separator: ";")
                if batchSignature == lastCallBatchSignature {
                    consecutiveIdenticalBatches += 1
                } else {
                    lastCallBatchSignature = batchSignature
                    consecutiveIdenticalBatches = 1
                }

                let batchFailures = settled.compactMap { $0.result.error?.message }.joined(separator: ";")
                if !batchFailures.isEmpty && batchFailures == lastObservedFailure {
                    consecutiveIdenticalFailures += 1
                } else {
                    lastObservedFailure = batchFailures.isEmpty ? nil : batchFailures
                    consecutiveIdenticalFailures = batchFailures.isEmpty ? 0 : 1
                }

                if consecutiveIdenticalFailures >= 3 {
                    let callDesc = lastExecutedCall.map { "\($0.toolID.rawValue) \($0.arguments.prefix(80))" } ?? "none"
                    throw CoreError(
                        code: .agentStepLimitReached,
                        message: "Agent Tool Loop 检测到无进展死循环：连续 \(consecutiveIdenticalFailures) 次遇到相同的 Tool 失败: \(lastObservedFailure ?? "") · 当前 step: \(step + 1) · 最后 ToolCall: \(callDesc)"
                    )
                }

                if consecutiveIdenticalBatches >= 8 {
                    let callDesc = lastExecutedCall.map { "\($0.toolID.rawValue) \($0.arguments.prefix(80))" } ?? "none"
                    throw CoreError(
                        code: .agentStepLimitReached,
                        message: "Agent Tool Loop 检测到无进展死循环：连续 \(consecutiveIdenticalBatches) 次调用完全相同的 ToolCall · 当前 step: \(step + 1) · 最后 ToolCall: \(callDesc) · 最后 observation: \(String((lastObservedContent ?? "").prefix(80)))"
                    )
                }
            }
            let lastCallDesc = lastExecutedCall.map { "\($0.toolID.rawValue) \($0.arguments.prefix(80))" } ?? "none"
            let lastObsDesc = String((lastObservedContent ?? "").prefix(80))
            throw CoreError(
                code: .agentStepLimitReached,
                message: "Agent Tool Loop 超过上限 (\(maximumAgentSteps) steps) · 当前 step: \(maximumAgentSteps) · 最后 ToolCall: \(lastCallDesc) · 最后 observation: \(lastObsDesc)"
            )
        } catch let error as CoreError {
            await toolRuntime.abortMCPTurn(sessionID: sessionID)
            await failTurn(handle: handle, sink: sink, error: error, profiler: profiler, executionID: executionID)
        } catch is CancellationError {
            await toolRuntime.abortMCPTurn(sessionID: sessionID)
            await failTurn(handle: handle, sink: sink, error: CoreError(code: .toolCancelled, message: "AgentRun 已取消"), profiler: profiler, executionID: executionID)
        } catch {
            await toolRuntime.abortMCPTurn(sessionID: sessionID)
            await failTurn(
                handle: handle,
                sink: sink,
                error: CoreError(code: .provider, message: String(describing: error)),
                profiler: profiler,
                executionID: executionID
            )
        }
    }

    private func modelID() throws -> ModelID {
        guard let modelID = modelBus.gateway.modelID else {
            throw CoreError(code: .provider, message: "未配置模型 Provider")
        }
        return modelID
    }

    private func trace(_ event: String, step: Int, toolCallID: ToolCallID? = nil, toolCount: Int? = nil) {
        guard diagnosticsEnabled || diagnostics != nil else { return }
        var fields = ["[agent-trace]", "event=\(event)", "sessionID=\(sessionID.rawValue)", "step=\(step)"]
        if let toolCallID { fields.append("toolCallID=\(toolCallID.rawValue)") }
        if let toolCount { fields.append("toolCount=\(toolCount)") }
        let kind: RuntimeTraceKind = event.hasPrefix("provider.") ? .provider : event.hasPrefix("tool.") || event.hasPrefix("session.parts") ? .tool : event.hasPrefix("context.") ? .session : .agentRun
        let executionID = activeExecution?.id.uuidString
        let providerRequestID = latestModelRequestID?.rawValue
        Task { await diagnostics?.record(kind: kind, event: event, sessionID: sessionID, runID: runID, rootRunID: rootRunID, parentRunID: parentRunID, executionID: executionID, providerRequestID: providerRequestID, toolCallID: toolCallID, metadata: ["step": String(step), "toolCount": String(toolCount ?? 0)]) }
    }

    private func syncL1ResidentAccounting(with entries: [ContextEntry]) async {
        currentActiveEntries = entries
        let tokens = ConservativeTokenEstimator().estimate(entries: entries)
        await cacheController.recordSessionL1Tokens(sessionID: sessionID, tokens: tokens, count: entries.count)
        if let session = try? await store.session(sessionID) {
            _ = await contextEngine.snapshot(for: session, activeEntries: entries, systemContext: systemContext, estimatedTokens: tokens, liveToolBatchCount: toolBatches.filter { $0.state != .consumed }.count, compactionGeneration: compactionGeneration)
        }
    }

    private func duplicateOutcome(for call: ToolCall, signature: ToolRuntime.ReadOnlySignature, content: String) -> ToolRuntime.ExecutionOutcome {
        ToolRuntime.ExecutionOutcome(
            result: ToolResult(callID: call.callID, success: false, content: content, error: ToolError(code: "duplicateToolCall", message: "连续重复调用已复用前一成功结果"), toolName: signature.toolName),
            permissionWait: .zero,
            permissionAsked: false,
            execution: .zero,
            toolName: signature.toolName,
            resource: signature.resource
        )
    }

    private func failureKey(for call: ToolCall) -> String {
        "\(call.toolID.rawValue)|\(call.arguments)"
    }

    private func isDeterministicFailure(_ result: ToolResult) -> Bool {
        guard !result.success, let error = result.error else { return false }
        if result.outcome == .timedOut || result.outcome == .idleTimedOut || result.outcome == .cancelled { return false }
        return [
            CoreError.Code.toolNotFound.rawValue,
            CoreError.Code.toolArgumentInvalid.rawValue,
            CoreError.Code.toolValidationError.rawValue,
            CoreError.Code.permissionDenied.rawValue,
            CoreError.Code.workspaceViolation.rawValue,
            CoreError.Code.resourceNotFound.rawValue,
            CoreError.Code.resourceOutsideWorkspace.rawValue,
            CoreError.Code.symlinkEscape.rawValue,
            CoreError.Code.binaryFileUnsupported.rawValue,
            CoreError.Code.contentChanged.rawValue,
            CoreError.Code.ambiguousEdit.rawValue,
            CoreError.Code.invalidPatch.rawValue,
            CoreError.Code.patchConflict.rawValue,
            CoreError.Code.editTargetNotFound.rawValue
        ].contains(error.code)
    }

    private func repeatedFailureOutcome(for call: ToolCall, signature: String) -> ToolRuntime.ExecutionOutcome {
        let message = "相同 ToolID 和参数已再次产生确定性失败，已阻止原样重试；请更换策略或先修复原因。"
        return ToolRuntime.ExecutionOutcome(
            result: ToolResult(
                callID: call.callID,
                success: false,
                content: message,
                error: ToolError(code: "deterministicFailureRepeated", message: message),
                toolName: call.toolID.rawValue,
                outcome: .failure,
                summary: "repeat blocked",
                metadata: ["repeatBlocked": "true", "errorSignature": signature, "retryability": Retryability.none.rawValue]
            ),
            permissionWait: .zero,
            permissionAsked: false,
            execution: .zero,
            toolName: call.toolID.rawValue,
            resource: nil
        )
    }

    public func compactNow() async throws -> CompactSessionResponse {
        guard !turnRunning else { throw CoreError(code: .turnAlreadyRunning, message: "对话进行中，不能压缩当前 Session") }
        let session = try await store.session(sessionID)
        let residentPages = await cacheController.residentPages(for: sessionID)
        let toolTokens = ConservativeTokenEstimator().estimate(tools: await toolRuntime.availableDefinitions())
        let budget = budgetPlanner.plan(profile: modelBus.gateway.contextProfile, toolTokens: toolTokens)
        let entries = await contextEngine.entries(for: session, projectPages: residentPages, systemContext: systemContext, systemContextAtBeginning: systemContextAtBeginning)
        let result = try await compactor.compact(sessionID: sessionID, entries: entries, budget: budget, batches: toolBatches, projectBackedContents: Set(residentPages.map(\.content)), trigger: .manual)
        if result.triggered { compactionGeneration += 1 }
        await syncL1ResidentAccounting(with: result.entries)
        let response = CompactSessionResponse(triggerSource: result.triggerSource.rawValue, beforeEstimatedTokens: result.beforeTokens, afterEstimatedTokens: result.afterTokens, targetLowWater: budget.lowWaterTokens, mandatoryFloor: result.mandatoryFloor, unitsKept: result.unitsKept, unitsPagedOut: result.pagedOut, historicalToolBatchesPagedOut: result.historicalToolBatchesPagedOut, projectBackedOffloads: result.projectBackedOffloads, derivedPagesCreated: result.derivedCreated, redundantDrops: result.redundantDrops, emergencyTrims: result.emergencyTrims, compactionGeneration: compactionGeneration, noEligibleReduction: result.noEligibleReduction)
        try await persistCompaction()
        return response
    }

    public func cancelCurrentTurn() async {
        abortActiveProviderStream()
        guard let execution = activeExecution else { turnRunning = false; return }
        execution.task.cancel()
        lifecycle("cancellationRequested", waitingOn: "turnTask")
        await dataPlane.finishAgentStream(execution.streamID)
    }

    public func shutdown() async {
        shuttingDown = true
        abortActiveProviderStream()
        guard let execution = activeExecution else { turnRunning = false; return }
        execution.task.cancel()
        lifecycle("cancellationRequested", waitingOn: "turnTask")
        await dataPlane.finishAgentStream(execution.streamID)
        await execution.task.value
        _ = await finishExecution(execution.id)
        lifecycle("cleanupCompleted", waitingOn: "turnTask")
    }

    public func cacheMetrics() async -> (l2Pages: Int, l3Pages: Int, pageOutCount: Int, pageInCount: Int, historicalToolPages: Int, l3Hits: Int, l2Hits: Int, l2Promotions: Int) {
        await compactor.cacheMetrics(sessionID: sessionID)
    }

    public func contextUnitStates() async -> [ContextUnitDebugSnapshot] {
        await compactor.unitStates(sessionID: sessionID)
    }

    private func settleDurableBatches(session: Session, deadline: ExecutionDeadline, profiler: TurnProfiler) async throws {
        for batchID in toolBatches.filter({ $0.state == .pending || $0.state == .recoveryRequired }).map(\.batchID) {
            guard let batch = toolBatches.first(where: { $0.batchID == batchID }), batch.resultMessageID == nil else { continue }
            for call in batch.toolCallStates where call.state == .recoveryRequired {
                await completedToolCall(batchID: batchID, result: ToolResult(callID: call.call.callID, success: false, content: "", error: ToolError(code: CoreError.Code.executionStateUnknown.rawValue, message: "重启时 mutation Tool 的执行状态未知，需要验证"), toolName: call.call.toolID.rawValue, metadata: ["executionState": "unknown", "verificationRequired": "true"]))
            }
            for call in batch.toolCallStates {
                guard call.state == .requested, case let .question(request)? = call.request, case let .question(reply)? = call.reply else { continue }
                let selected = reply.selectedOptionIndices.map { request.options[$0] }
                let payload: [String: Any] = ["questionID": request.questionID.rawValue, "cancelled": reply.cancelled, "selectedOptions": selected, "text": reply.text ?? NSNull()]
                let content = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
                await completedToolCall(batchID: batchID, result: ToolResult(callID: call.call.callID, success: true, content: content, toolName: call.call.toolID.rawValue))
            }

            let executable = toolBatches.first(where: { $0.batchID == batchID })?.toolCallStates.filter {
                guard $0.state == .requested else { return false }
                if case .question? = $0.request { return false }
                return true
            } ?? []
            await withTaskGroup(of: ToolRuntime.ExecutionOutcome.self) { group in
                for durable in executable {
                    let call = durable.call
                    let executionCall = call.withProvenance(sessionID: sessionID, agentRunID: runID)
                    let observer = ToolExecutionObserver(
                        permissionAsked: { request in await self.waitingForHuman(batchID: batchID, callID: call.callID, request: .permission(request)) },
                        permissionResolved: { request, reply in await self.humanReply(batchID: batchID, callID: call.callID, request: .permission(request), reply: .permission(reply)) },
                        executionClaimed: { claim in
                            await self.executionClaimed(batchID: batchID, callID: call.callID, claim: claim)
                            await self.eventSink(.toolExecutionClaimed(executionCall))
                        },
                        questionAsked: { request in await self.waitingForHuman(batchID: batchID, callID: call.callID, request: .question(request)) },
                        questionResolved: { request, reply in await self.humanReply(batchID: batchID, callID: call.callID, request: .question(request), reply: .question(reply)) }
                    )
                    group.addTask { [toolRuntime, sessionID, eventSink, executionProfile] in
                        await toolRuntime.executeWithMetrics(executionCall, sessionID: sessionID, projectID: session.projectID ?? ProjectID("ephemeral"), executionProfile: executionProfile, onPermissionAsked: { request in
                            await eventSink(.permissionAsked(request))
                        }, observer: observer)
                    }
                }
                for await outcome in group {
                    profiler.recordTool(outcome)
                    await completedToolCall(batchID: batchID, result: outcome.result)
                    outcome.lifecycleTrace?.record(.resultCommitted, exitCode: outcome.result.exitCode.map { Int32($0) })
                    await eventSink(.toolResult(outcome.result.withProvenance(sessionID: sessionID, agentRunID: runID)))
                    outcome.lifecycleTrace?.record(.applicationProjectionReceived, exitCode: outcome.result.exitCode.map { Int32($0) })
                }
            }

            guard let settled = toolBatches.first(where: { $0.batchID == batchID }), settled.toolCallStates.allSatisfy({ $0.state == .completed && $0.result != nil }) else { continue }
            let results = settled.toolCalls.compactMap { call in settled.toolCallStates.first { $0.call.callID == call.callID }?.result }
            guard results.count == settled.toolCalls.count else { continue }
            let message = Message(id: MessageID(UUID().uuidString), role: .tool, parts: results.map(SessionMessagePart.toolResult), createdAt: .now)
            try await settleBatch(batchID: batchID, resultMessageID: message.id, results: results, resultMessage: message)
            await toolRuntime.finishMCPProviderStep(sessionID: sessionID)
        }
    }

    private func settleBatch(batchID: String, resultMessageID: MessageID, results: [ToolResult], resultMessage: Message) async throws {
        guard let index = toolBatches.firstIndex(where: { $0.batchID == batchID }), toolBatches[index].resultMessageID == nil, toolBatches[index].state == .pending || toolBatches[index].state == .recoveryRequired else { return }
        toolBatches[index] = toolBatches[index].with(state: .settledAwaitingConsumption, resultMessageID: resultMessageID, toolResults: results)
        if let persistence { try await persistence.appendToolResultMessageAndSettle(sessionID: sessionID, message: resultMessage, batch: toolBatches[index]) }
    }

    private func waitingForHuman(batchID: String, callID: ToolCallID, request: ToolCallHumanRequest) async {
        await updateToolCall(batchID: batchID, callID: callID) { $0.with(state: .waitingForHuman, request: request, replaceHumanExchange: true) }
        await runObserver?(.waitingForUser, nil, nil, nil, nil)
    }

    private func humanReply(batchID: String, callID: ToolCallID, request: ToolCallHumanRequest, reply: ToolCallHumanReply) async {
        await updateToolCall(batchID: batchID, callID: callID) { $0.with(state: .requested, request: request, reply: reply, replaceHumanExchange: true) }
        await runObserver?(.running, nil, nil, nil, nil)
    }

    private func executionClaimed(batchID: String, callID: ToolCallID, claim: ToolExecutionClaim) async {
        await updateToolCall(batchID: batchID, callID: callID) { $0.with(state: .executing, executionClaim: claim) }
    }

    private func completedToolCall(batchID: String, result: ToolResult) async {
        await updateToolCall(batchID: batchID, callID: result.callID) { $0.with(state: .completed, result: result) }
    }

    private func updateToolCall(batchID: String, callID: ToolCallID, _ update: (DurableToolCall) -> DurableToolCall) async {
        guard let batchIndex = toolBatches.firstIndex(where: { $0.batchID == batchID }), let callIndex = toolBatches[batchIndex].toolCallStates.firstIndex(where: { $0.call.callID == callID }) else { return }
        var states = toolBatches[batchIndex].toolCallStates
        states[callIndex] = update(states[callIndex])
        toolBatches[batchIndex] = toolBatches[batchIndex].with(state: toolBatches[batchIndex].state, toolCallStates: states)
        try? await persistence?.saveToolBatch(toolBatches[batchIndex])
    }

    private func consumeSettledBatches(_ batchIDs: Set<String>) async throws {
        let updates = toolBatches.enumerated().compactMap { index, batch -> (Int, ToolExchangeBatch)? in
            guard batchIDs.contains(batch.batchID), batch.state == .settledAwaitingConsumption else { return nil }
            return (index, batch.with(state: .consumed))
        }
        if let persistence { try await persistence.saveToolBatches(updates.map(\.1)) }
        for (index, batch) in updates { toolBatches[index] = batch }
    }

    private func persistCompaction() async throws {
        guard let persistence else { return }
        try await persistence.saveCompaction(
            sessionID: sessionID,
            generation: compactionGeneration,
            residencies: await compactor.unitStates(sessionID: sessionID),
            derivedPages: await compactor.derivedStore.pages(sessionID: sessionID)
        )
    }

    private func completeTurn(
        handle: TurnHandle,
        sink: AsyncThrowingStream<StreamChunk, Error>.Continuation,
        content: String,
        finishReason: ModelFinishReason?,
        usage: ModelUsage?,
        profiler: TurnProfiler,
        executionID: UUID
    ) async {
        defer { Task { await dataPlane.finishAgentStream(handle.streamID) } }
        do {
            guard isExecuting(executionID) else { return }
            if let runID, await ProviderActivityRegistry.shared.isRunCancelled(runID) { return }
            let message = try await store.appendMessage(handle.sessionID, role: .assistant, content: content)
            let assistantEntry = ContextEntry(messageID: message.id, role: .assistant, source: .assistantMessage, part: .text(content))
            var updatedEntries = currentActiveEntries
            if !updatedEntries.contains(where: { $0.messageID == message.id }) {
                updatedEntries.append(assistantEntry)
            }
            await syncL1ResidentAccounting(with: updatedEntries)
            guard await finishExecution(executionID) else { return }
            await performanceStore.recordProviderCalls(sessionID: handle.sessionID, calls: profiler.recordedProviderCalls)
            if let report = profiler.report() { await performanceStore.save(report) }
            let reason: TerminalReason = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .emptyCompletion : .completed
            let trace = makeTerminalTrace(
                reason: reason,
                transition: "running -> completed",
                source: "completeTurn",
                explanation: reason == .emptyCompletion ? "模型生成了空回复" : "模型完成了目标",
                finishReason: finishReason?.rawValue
            )
            await runObserver?(.completed, content, usage, nil, trace)
            await eventSink(.turnCompleted(TurnResult(
                sessionID: handle.sessionID,
                streamID: handle.streamID,
                assistantMessageID: message.id,
                finishReason: finishReason,
                usage: usage
            )))
        } catch let error as CoreError {
            await failTurn(handle: handle, sink: sink, error: error, profiler: profiler, executionID: executionID)
        } catch {
            await failTurn(handle: handle, sink: sink, error: CoreError(code: .transport, message: String(describing: error)), profiler: profiler, executionID: executionID)
        }
    }

    private func makeTerminalTrace(
        reason: TerminalReason,
        transition: String,
        source: String,
        explanation: String,
        finishReason: String? = nil
    ) -> AgentTerminalTrace {
        AgentTerminalTrace(
            runID: runID ?? AgentRunID(UUID().uuidString),
            sessionID: sessionID,
            lastProviderRequestID: latestModelRequestID?.rawValue,
            finishReason: finishReason,
            lastToolCallID: toolBatches.last?.toolCalls.last?.callID,
            terminalTransition: transition,
            terminalReason: reason,
            transitionSource: source,
            explanation: explanation
        )
    }

    private func failTurn(
        handle: TurnHandle,
        sink: AsyncThrowingStream<StreamChunk, Error>.Continuation,
        error: CoreError,
        profiler: TurnProfiler,
        executionID: UUID
    ) async {
        guard activeExecution?.id == executionID else { return }
        await diagnostics?.record(kind: .error, event: "turn.failed", sessionID: sessionID, runID: runID, rootRunID: rootRunID, parentRunID: parentRunID, executionID: executionID.uuidString, providerRequestID: latestModelRequestID?.rawValue, errorCode: error.code.rawValue)
        let preservesDurableBatch = toolBatches.contains { ($0.state == .pending || $0.state == .recoveryRequired) && $0.resultMessageID == nil }
        if Task.isCancelled && preservesDurableBatch {
            sink.finish()
            await dataPlane.finishAgentStream(handle.streamID)
            guard await finishExecution(executionID) else { return }
            await performanceStore.recordProviderCalls(sessionID: handle.sessionID, calls: profiler.recordedProviderCalls)
            if let report = profiler.report() { await performanceStore.save(report) }
            return
        }
        let isCancellation = Task.isCancelled || error.code == .toolCancelled || shuttingDown
        if let latestID = latestModelRequestID?.rawValue {
            let snapshot = await ProviderActivityRegistry.shared.record(
                sessionID: sessionID,
                runID: runID,
                providerRequestID: "local:\(latestID)",
                state: isCancellation ? .cancelled : .failed
            )
            await eventSink(.providerActivityChanged(snapshot))
        }
        sink.finish(throwing: error)
        await dataPlane.finishAgentStream(handle.streamID)
        guard await finishExecution(executionID) else { return }
        await performanceStore.recordProviderCalls(sessionID: handle.sessionID, calls: profiler.recordedProviderCalls)
        if let report = profiler.report() { await performanceStore.save(report) }
        let reason: TerminalReason = {
            if isCancellation { return .userCancelled }
            if [.commandTimedOut, .idleTimedOut].contains(error.code) { return .deadlineExceeded }
            if error.code == .agentStepLimitReached { return .maxStepsReached }
            if error.code == .permissionDenied { return .blocked }
            if error.code == .provider { return .providerFailure }
            return .runtimeFailure
        }()
        let status: AgentRunStatus = isCancellation ? .cancelled : [.commandTimedOut, .idleTimedOut].contains(error.code) ? .timedOut : .failed
        let trace = makeTerminalTrace(
            reason: reason,
            transition: "running -> \(status.rawValue)",
            source: "failTurn",
            explanation: error.message
        )
        await runObserver?(status, nil, nil, error, trace)
        await eventSink(.turnFailed(TurnFailure(sessionID: handle.sessionID, streamID: handle.streamID, error: error)))
    }

    private func finishExecution(_ id: UUID) async -> Bool {
        guard let execution = activeExecution, execution.id == id else { return false }
        activeExecution = nil
        turnRunning = false
        if execution.isRestore { await restoreScheduler?.markCompleted() }
        return true
    }

    private func isExecuting(_ id: UUID) -> Bool {
        !shuttingDown && activeExecution?.id == id
    }

    private func ensureExecuting(_ id: UUID) throws {
        guard isExecuting(id) else { throw CancellationError() }
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func lifecycle(_ event: String, waitingOn: String) {
        ExecutionLifecycleTrace.log(event, category: runID == nil ? .agentRun : .subagent, waitingOn: waitingOn)
    }
}
