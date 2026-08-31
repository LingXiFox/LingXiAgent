import Foundation
import LingXiProtocol

/// 一个 Session 的串行 Agent Lane。Tool 结果以结构化 parts 回写 Session，再进入下一步模型输入。
public actor SessionRuntime {
    private let store: any SessionStore
    private let sessionID: SessionID
    private let modelBus: ModelBus
    private let dataPlane: DataPlane
    private let contextEngine: L1ContextEngine
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
    private let runID: AgentRunID?
    private let rootSessionID: SessionID
    private let parentSessionID: SessionID?
    private let runObserver: (@Sendable (AgentRunStatus, String?, ModelUsage?, CoreError?) async -> Void)?
    private let executionProfile: SubagentExecutionProfile?
    private let maximumAgentSteps: Int
    private var turnRunning = false
    private var turnTask: Task<Void, Never>?
    private var toolBatches: [ToolExchangeBatch] = []
    private var compactionGeneration = 0
    private var latestModelRequestID: ModelRequestID?

    init(
        store: any SessionStore,
        sessionID: SessionID,
        modelBus: ModelBus,
        dataPlane: DataPlane,
        contextEngine: L1ContextEngine,
        toolRuntime: ToolRuntime,
        performanceStore: PerformanceStore,
        contextPager: ContextPager,
        projectScanner: ProjectScanner,
        eventSink: @escaping @Sendable (CoreEvent) async -> Void,
        compactor: ContextCompactor,
        budgetPlanner: ContextBudgetPlanner,
        persistence: SQLitePersistenceStore? = nil,
        interactive: Bool = false,
        diagnosticsEnabled: Bool = false,
        runID: AgentRunID? = nil,
        rootSessionID: SessionID? = nil,
        parentSessionID: SessionID? = nil,
        executionProfile: SubagentExecutionProfile? = nil,
        runObserver: (@Sendable (AgentRunStatus, String?, ModelUsage?, CoreError?) async -> Void)? = nil
    ) {
        self.store = store
        self.sessionID = sessionID
        self.modelBus = modelBus
        self.dataPlane = dataPlane
        self.contextEngine = contextEngine
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
        self.runID = runID
        self.rootSessionID = rootSessionID ?? sessionID
        self.parentSessionID = parentSessionID
        self.executionProfile = executionProfile
        maximumAgentSteps = max(1, executionProfile?.maxSteps ?? 8)
        self.runObserver = runObserver
    }

    public func restore() async throws {
        guard let persistence else { return }
        toolBatches = try await persistence.toolBatches(sessionID: sessionID)
        if let compacted = try await persistence.compaction(sessionID: sessionID) {
            compactionGeneration = compacted.generation
            await compactor.restoreResidencies(sessionID: sessionID, values: compacted.residencies)
        }
    }

    /// 启动一轮对话并立即返回 DMA 通道；同一 Session 只允许一个活动 turn。
    public func startTurn(_ content: String) async throws -> OpenedStream {
        guard !turnRunning else {
            throw CoreError(code: .turnAlreadyRunning, message: "该 Session 已有进行中的对话轮次")
        }
        turnRunning = true
        let profiler = TurnProfiler(sessionID: sessionID, enabled: performanceStore.enabled)
        do {
            _ = try await store.session(sessionID)
            try await store.appendMessage(sessionID, role: .user, content: content)
            guard modelBus.gateway.modelID != nil else {
                throw CoreError(
                    code: .provider,
                    message: "未配置模型 Provider；请检查 providers.json 与 CredentialStore: \(modelBus.gateway.missingRequirements.joined(separator: ", "))"
                )
            }
            let opened = await dataPlane.openAgentStream()
            let handle = TurnHandle(sessionID: sessionID, streamID: opened.stream.id)
            await eventSink(.turnStarted(handle))
            await runObserver?(.running, nil, nil, nil)
            let runID = self.runID
            let rootSessionID = self.rootSessionID
            let parentSessionID = self.parentSessionID
            let sessionID = self.sessionID
            let turnTask = Task {
                await AgentExecutionContext.$current.withValue(runID.map { (sessionID: sessionID, runID: $0, rootSessionID: rootSessionID, parentSessionID: parentSessionID) }) {
                    await self.runTurn(handle: handle, sink: opened.sink, task: content, profiler: profiler)
                }
            }
            self.turnTask = turnTask
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
        profiler: TurnProfiler
    ) async {
        var index = 0
        var finalUsage: ModelUsage?
        var finalReason: ModelFinishReason?
        var lastSuccessfulRead: (signature: ToolRuntime.ReadOnlySignature, content: String)?
        let executionProfile = self.executionProfile

        do {
            for step in 0..<maximumAgentSteps {
                trace("agent.step.begin", step: step + 1)
                let session = try await store.session(sessionID)
                let clock = ContinuousClock()
                let contextStarted = clock.now
                trace("context.build.begin", step: step + 1)
                let scan = try await contextPager.rebuildStaleFiles(using: projectScanner)
                let userMessages = session.messages.compactMap { $0.role == .user ? $0.parts.compactMap { if case let .text(text) = $0 { text } else { nil } }.joined() : nil }
                let query = ContextQuery(currentTask: task, recentUserMessages: Array(userMessages.dropLast()))
                let pagerResult = await contextPager.query(projectRoot: projectScanner.root, query: query)
                let projectPages = pagerResult.pages
                let pages = projectPages.filter { page in
                    !session.messages.contains { message in
                        message.parts.contains { part in
                            if case let .toolResult(result) = part { return result.content == page.content }
                            return false
                        }
                    }
                }
                let availableTools = await toolRuntime.availableDefinitions(sessionID: sessionID, interactive: interactive, executionProfile: executionProfile)
                let toolTokens = ConservativeTokenEstimator().estimate(tools: availableTools)
                let endpointProfile = modelBus.gateway.contextProfile
                let requestedWindow = executionProfile?.contextProfile.flatMap(Int.init)
                let contextProfile = ModelContextProfile(contextWindowTokens: min(endpointProfile.contextWindowTokens, requestedWindow ?? endpointProfile.contextWindowTokens), maxOutputTokens: endpointProfile.maxOutputTokens, recommendedOutputReserveTokens: endpointProfile.recommendedOutputReserveTokens, source: endpointProfile.source)
                let preferred = executionProfile?.budgetProfile.flatMap(Int.init)
                let planner = preferred.map { budgetPlanner.with(preferredActiveTokens: $0) } ?? budgetPlanner
                let budget = planner.plan(profile: contextProfile, toolTokens: toolTokens)
                profiler.recordBudget(budget, modelWindow: contextProfile.contextWindowTokens)
                let allEntries = await contextEngine.entries(for: session, projectPages: pages)
                let compacted = try await compactor.compact(sessionID: sessionID, entries: allEntries, budget: budget, batches: toolBatches, projectBackedContents: Set(projectPages.map(\.content)))
                profiler.recordCompaction(compacted, budget: budget)
                if compacted.triggered { compactionGeneration += 1 }
                if compacted.triggered { try await persistCompaction() }
                // Project retrieval may use recent turns; Derived rehydration must match the current task only.
                let pageIn = await contextPager.pageInDerived(store: compactor.derivedStore, sessionID: sessionID, query: task, remainingTokens: max(0, budget.hardInputLimit - compacted.afterTokens))
                let derivedMetrics = await compactor.cacheMetrics(sessionID: sessionID)
                profiler.recordDerivedPaging(l3Hits: derivedMetrics.l3Hits, l2Hits: derivedMetrics.l2Hits, l2Promotions: derivedMetrics.l2Promotions, pageIns: derivedMetrics.pageInCount)
                var finalEntries = compacted.entries + pageIn
                var finalTokens = ConservativeTokenEstimator().estimate(entries: finalEntries)
                if finalTokens > budget.hardInputLimit {
                    let emergency = try await compactor.compact(sessionID: sessionID, entries: finalEntries, budget: budget, batches: toolBatches, projectBackedContents: Set(projectPages.map(\.content)), trigger: .emergencyHardLimit)
                    profiler.recordCompaction(emergency, budget: budget)
                    finalEntries = emergency.entries
                    finalTokens = emergency.afterTokens
                    if emergency.triggered { compactionGeneration += 1 }
                    if emergency.triggered { try await persistCompaction() }
                }
                let context = await contextEngine.snapshot(for: session, activeEntries: finalEntries, estimatedTokens: finalTokens, mandatoryTokens: compacted.mandatoryFloor, liveToolBatchCount: toolBatches.filter { $0.state != .consumed }.count, compactionGeneration: compactionGeneration)
                await contextPager.recordInjection(pages)
                let paging = await contextPager.debugMetrics(projectRoot: projectScanner.root)
                profiler.recordPaging(paging, turn: pagerResult.turnMetrics, scan: scan)
                trace("context.build.end", step: step + 1)
                profiler.recordContext(context, build: contextStarted.duration(to: clock.now))
                let dispatchStarted = clock.now
                trace("model.next.begin", step: step + 1)
                let effectiveContinuationID = toolBatches.last(where: { $0.state == .settledAwaitingConsumption })?.continuationRequestID ?? latestModelRequestID
                let request = ModelRequest(
                    continuationOf: effectiveContinuationID,
                    model: try modelID(),
                    executionID: runID,
                    messages: context.modelMessages(),
                    tools: availableTools,
                    reasoning: modelBus.gateway.reasoning,
                    debugStep: step + 1
                )
                if finalTokens > budget.hardInputLimit {
                    throw CoreError(code: .contextBudgetExceeded, message: "最终模型请求超出输入预算")
                }
                try ModelRequestProtocolValidator.validate(context.entries)
                profiler.recordProtocolValidator(liveBatches: toolBatches.filter { $0.state != .consumed }.count)
                let submittedBatchIDs = Set(toolBatches.filter { $0.state == .settledAwaitingConsumption }.map(\.batchID))
                trace("provider.stream.begin", step: step + 1)
                latestModelRequestID = request.requestID
                let events = try await modelBus.stream(request)
                let dispatch = dispatchStarted.duration(to: clock.now)
                let streamStarted = clock.now
                var text = ""
                var calls: [ToolCall] = []

                for try await event in events {
                    switch event {
                    case .started:
                        profiler.recordFirstEvent(streamElapsed: streamStarted.duration(to: clock.now))
                    case let .textDelta(delta):
                        sink.yield(StreamChunk(streamID: handle.streamID, sessionID: sessionID, agentRunID: runID, index: index, text: delta, kind: .text))
                        profiler.recordText(delta, streamElapsed: streamStarted.duration(to: clock.now))
                        index += 1
                        text += delta
                    case let .reasoningDelta(delta):
                        sink.yield(StreamChunk(streamID: handle.streamID, sessionID: sessionID, agentRunID: runID, index: index, text: delta, kind: .reasoning))
                        profiler.recordReasoning(delta, streamElapsed: streamStarted.duration(to: clock.now))
                        index += 1
                    case .toolCallStarted, .toolCallDelta:
                        break // Tool arguments 只在完整聚合后进入控制面。
                    case let .toolCallCompleted(call):
                        calls.append(call)
                    case let .usage(usage):
                        finalUsage = usage
                        profiler.recordUsage(usage)
                    case let .completed(reason):
                        finalReason = reason
                    case let .failed(error):
                        throw error
                    }
                }
                trace("provider.stream.end", step: step + 1)
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
                        profiler: profiler
                    )
                    return
                }

                var assistantParts: [SessionMessagePart] = calls.map(SessionMessagePart.toolCall)
                if !text.isEmpty { assistantParts.insert(.text(text), at: 0) }
                trace("tool.batch.begin", step: step + 1, toolCount: calls.count)
                await runObserver?(.waitingForTool, nil, finalUsage, nil)
                trace("tool.batch.count", step: step + 1, toolCount: calls.count)
                guard Set(calls.map(\.callID)).count == calls.count else {
                    throw CoreError(code: .modelStream, message: "Tool batch 含重复 toolCallID")
                }
                trace("session.parts.append.begin", step: step + 1, toolCount: calls.count)
                let assistantMessage: Message
                if persistence != nil { assistantMessage = Message(id: MessageID(UUID().uuidString), role: .assistant, parts: assistantParts, createdAt: .now) }
                else { assistantMessage = try await store.appendMessage(sessionID, role: .assistant, parts: assistantParts) }
                let batch = ToolExchangeBatch(batchID: UUID().uuidString, sessionID: sessionID, assistantMessageID: assistantMessage.id, toolCalls: calls, continuationRequestID: request.requestID, providerStep: step + 1, state: .pending, estimatedTokens: ConservativeTokenEstimator().estimate(entries: assistantParts.map { ContextEntry(messageID: assistantMessage.id, role: .assistant, source: .toolCall, part: $0) }))
                if let persistence { try await persistence.appendAssistantMessageAndBatch(sessionID: sessionID, message: assistantMessage, batch: batch) }
                toolBatches.append(batch)
                trace("session.parts.append.end", step: step + 1, toolCount: calls.count)

                trace("tool.batch.settle.begin", step: step + 1, toolCount: calls.count)
                let signatures = calls.map { try? toolRuntime.readOnlySignature(for: $0) }
                var outcomes = Array<ToolRuntime.ExecutionOutcome?>(repeating: nil, count: calls.count)
                var primaryByIndex: [Int: Int] = [:]
                var primaryBySignature: [ToolRuntime.ReadOnlySignature: Int] = [:]

                for (offset, call) in calls.enumerated() {
                    await eventSink(.toolCallCompleted(call))
                    trace("tool.execute.begin", step: step + 1, toolCallID: call.callID)
                    if let signature = signatures[offset], let previous = lastSuccessfulRead, previous.signature == signature {
                        outcomes[offset] = duplicateOutcome(for: call, signature: signature, content: previous.content)
                    } else if let signature = signatures[offset], let primary = primaryBySignature[signature] {
                        primaryByIndex[offset] = primary
                    } else {
                        if let signature = signatures[offset] { primaryBySignature[signature] = offset }
                        primaryByIndex[offset] = offset
                    }
                }

                await withTaskGroup(of: (Int, ToolRuntime.ExecutionOutcome).self) { group in
                    for (offset, call) in calls.enumerated() where outcomes[offset] == nil && primaryByIndex[offset] == offset {
                        group.addTask { [toolRuntime, sessionID, eventSink] in
                            let outcome = await toolRuntime.executeWithMetrics(call, sessionID: sessionID, projectID: session.projectID ?? ProjectID("ephemeral"), executionProfile: executionProfile) { request in
                                await eventSink(.permissionAsked(request))
                            }
                            return (offset, outcome)
                        }
                    }
                    for await (offset, outcome) in group { outcomes[offset] = outcome }
                }

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
                    if let signature = signatures[offset], result.success || result.error?.code == "duplicateToolCall" {
                        lastSuccessfulRead = (signature, result.content)
                    } else {
                        lastSuccessfulRead = nil
                    }
                    await eventSink(.toolResult(result))
                }
                trace("session.parts.append.begin", step: step + 1, toolCount: settled.count)
                let resultMessage: Message
                if persistence != nil { resultMessage = Message(id: MessageID(UUID().uuidString), role: .tool, parts: settled.map { .toolResult($0.result) }, createdAt: .now) }
                else { resultMessage = try await store.appendMessage(sessionID, role: .tool, parts: settled.map { .toolResult($0.result) }) }
                try await settleLatestBatch(resultMessageID: resultMessage.id, results: settled.map(\.result), resultMessage: resultMessage)
                await toolRuntime.finishMCPProviderStep(sessionID: sessionID)
                await runObserver?(.running, nil, finalUsage, nil)
                trace("session.parts.append.end", step: step + 1, toolCount: settled.count)
                trace("tool.batch.settle.end", step: step + 1, toolCount: calls.count)
            }
            throw CoreError(code: .agentStepLimitReached, message: "Agent Tool Loop 超过 \(maximumAgentSteps) steps")
        } catch let error as CoreError {
            await toolRuntime.abortMCPTurn(sessionID: sessionID)
            await failTurn(handle: handle, sink: sink, error: error, profiler: profiler)
        } catch {
            await toolRuntime.abortMCPTurn(sessionID: sessionID)
            await failTurn(
                handle: handle,
                sink: sink,
                error: CoreError(code: .provider, message: String(describing: error)),
                profiler: profiler
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
        guard diagnosticsEnabled else { return }
        var fields = ["[agent-trace]", "event=\(event)", "sessionID=\(sessionID.rawValue)", "step=\(step)"]
        if let toolCallID { fields.append("toolCallID=\(toolCallID.rawValue)") }
        if let toolCount { fields.append("toolCount=\(toolCount)") }
        FileHandle.standardError.write(Data((fields.joined(separator: " ") + "\n").utf8))
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

    public func compactNow() async throws -> CompactSessionResponse {
        guard !turnRunning else { throw CoreError(code: .turnAlreadyRunning, message: "对话进行中，不能压缩当前 Session") }
        let session = try await store.session(sessionID)
        let task = session.messages.last { $0.role == .user }?.content ?? ""
        let scan = try await contextPager.rebuildStaleFiles(using: projectScanner)
        let users = session.messages.compactMap { $0.role == .user ? $0.content : nil }
        let query = ContextQuery(currentTask: task, recentUserMessages: Array(users.dropLast()))
        let projectPages = (await contextPager.query(projectRoot: projectScanner.root, query: query)).pages
        let toolTokens = ConservativeTokenEstimator().estimate(tools: await toolRuntime.availableDefinitions())
        let budget = budgetPlanner.plan(profile: modelBus.gateway.contextProfile, toolTokens: toolTokens)
        let entries = await contextEngine.entries(for: session, projectPages: projectPages)
        let result = try await compactor.compact(sessionID: sessionID, entries: entries, budget: budget, batches: toolBatches, projectBackedContents: Set(projectPages.map(\.content)), trigger: .manual)
        if result.triggered { compactionGeneration += 1 }
        // /compact only changes L1 residency; the next user task is the sole Derived page-in trigger.
        _ = await contextEngine.snapshot(for: session, activeEntries: result.entries, estimatedTokens: result.afterTokens, mandatoryTokens: result.mandatoryFloor, liveToolBatchCount: toolBatches.filter { $0.state != .consumed }.count, compactionGeneration: compactionGeneration)
        _ = scan
        let response = CompactSessionResponse(triggerSource: result.triggerSource.rawValue, beforeEstimatedTokens: result.beforeTokens, afterEstimatedTokens: result.afterTokens, targetLowWater: budget.lowWaterTokens, mandatoryFloor: result.mandatoryFloor, unitsKept: result.unitsKept, unitsPagedOut: result.pagedOut, historicalToolBatchesPagedOut: result.historicalToolBatchesPagedOut, projectBackedOffloads: result.projectBackedOffloads, derivedPagesCreated: result.derivedCreated, redundantDrops: result.redundantDrops, emergencyTrims: result.emergencyTrims, compactionGeneration: compactionGeneration, noEligibleReduction: result.noEligibleReduction)
        try await persistCompaction()
        return response
    }

    public func shutdown() {
        turnTask?.cancel()
        turnTask = nil
        turnRunning = false
    }

    public func cacheMetrics() async -> (l2Pages: Int, l3Pages: Int, pageOutCount: Int, pageInCount: Int, historicalToolPages: Int, l3Hits: Int, l2Hits: Int, l2Promotions: Int) {
        await compactor.cacheMetrics(sessionID: sessionID)
    }

    public func contextUnitStates() async -> [ContextUnitDebugSnapshot] {
        await compactor.unitStates(sessionID: sessionID)
    }

    private func settleLatestBatch(resultMessageID: MessageID, results: [ToolResult], resultMessage: Message) async throws {
        guard let index = toolBatches.lastIndex(where: { $0.state == .pending }) else { return }
        toolBatches[index] = toolBatches[index].with(state: .settledAwaitingConsumption, resultMessageID: resultMessageID, toolResults: results)
        if let persistence { try await persistence.appendToolResultMessageAndSettle(sessionID: sessionID, message: resultMessage, batch: toolBatches[index]) }
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
        profiler: TurnProfiler
    ) async {
        defer { Task { await dataPlane.finishAgentStream(handle.streamID) } }
        do {
            let message = try await store.appendMessage(handle.sessionID, role: .assistant, content: content)
            turnRunning = false
            turnTask = nil
            if let report = profiler.report() { await performanceStore.save(report) }
            await runObserver?(.completed, content, usage, nil)
            await eventSink(.turnCompleted(TurnResult(
                sessionID: handle.sessionID,
                streamID: handle.streamID,
                assistantMessageID: message.id,
                finishReason: finishReason,
                usage: usage
            )))
        } catch let error as CoreError {
            await failTurn(handle: handle, sink: sink, error: error, profiler: profiler)
        } catch {
            await failTurn(handle: handle, sink: sink, error: CoreError(code: .transport, message: String(describing: error)), profiler: profiler)
        }
    }

    private func failTurn(
        handle: TurnHandle,
        sink: AsyncThrowingStream<StreamChunk, Error>.Continuation,
        error: CoreError,
        profiler: TurnProfiler
    ) async {
        if diagnosticsEnabled {
            FileHandle.standardError.write(Data("[agent-trace] event=turn.failed sessionID=\(sessionID.rawValue) code=\(error.code.rawValue)\n".utf8))
        }
        sink.finish(throwing: error)
        await dataPlane.finishAgentStream(handle.streamID)
        turnRunning = false
        turnTask = nil
        if let report = profiler.report() { await performanceStore.save(report) }
        await runObserver?(Task.isCancelled ? .cancelled : .failed, nil, nil, error)
        await eventSink(.turnFailed(TurnFailure(sessionID: handle.sessionID, streamID: handle.streamID, error: error)))
    }
}
