import Foundation
import LingXiProtocol

/// SessionTurnCoordinator：负责 Session 内 Turn / Run 生命周期、并发约束、Event Log 与 Stream 屏障。
/// 硬规则：一个 Session 最多一个 active Root Run；额外 Turn 默认排队 (queue)。
public actor SessionTurnCoordinator {
    public let sessionID: SessionID
    public let eventLog: SessionEventLog

    public private(set) var activeRootRunID: RunID?
    private var queuedTurns: [TurnSnapshot] = []
    private var turns: [TurnID: TurnSnapshot] = [:]
    private var runs: [RunID: RunSnapshot] = [:]
    private var interactions: [InteractionID: InteractionSnapshot] = [:]
    private var modelSteps: [ModelStepID: ModelStepSnapshot] = [:]
    private var toolInvocations: [ToolCallID: ToolInvocationSnapshot] = [:]

    private var streamFrames: [StreamID: [StreamFrame]] = [:]
    private var streamSubscribers: [StreamID: [UUID: AsyncStream<StreamFrame>.Continuation]] = [:]

    public init(sessionID: SessionID, eventLog: SessionEventLog) {
        self.sessionID = sessionID
        self.eventLog = eventLog
    }

    /// 从持久化消息流中水合还原历史 turns 和 timeline events
    public func hydrateHistoricalMessages(_ messages: [Message]) async {
        guard turns.isEmpty, !messages.isEmpty else { return }

        var currentTurnID: TurnID?
        for msg in messages {
            let causal = CausalContext(sessionID: sessionID, turnID: currentTurnID)
            switch msg.role {
            case .user:
                let tID = TurnID(msg.id.rawValue)
                currentTurnID = tID
                let snap = MessageSnapshot(
                    messageID: msg.id,
                    role: .user,
                    text: msg.content,
                    createdAt: msg.createdAt
                )
                let turnSnap = TurnSnapshot(
                    turnID: tID,
                    sessionID: sessionID,
                    userMessage: snap,
                    executionIntent: TurnExecutionIntent(),
                    status: .completed,
                    createdAt: msg.createdAt
                )
                turns[tID] = turnSnap

                let turnCausal = CausalContext(sessionID: sessionID, turnID: tID)
                await eventLog.append(causal: turnCausal, payload: .turnCreated(turnSnap))
                await eventLog.append(causal: turnCausal, payload: .userMessageCommitted(snap))

            case .assistant:
                var textContent = ""
                for part in msg.parts {
                    switch part {
                    case let .text(txt):
                        textContent += txt
                    case let .toolCall(tc):
                        let invocation = ToolInvocationSnapshot(
                            callID: tc.callID,
                            toolID: tc.toolID,
                            displayName: tc.toolName,
                            argumentsSummary: tc.arguments,
                            state: .completed
                        )
                        toolInvocations[tc.callID] = invocation
                        await eventLog.append(causal: causal, payload: .toolRequested(invocation))
                        await eventLog.append(causal: causal, payload: .toolRunning(callID: tc.callID, stdoutStreamID: nil, stderrStreamID: nil))
                    case .toolResult:
                        break
                    }
                }
                if !textContent.isEmpty || !msg.parts.isEmpty {
                    await eventLog.append(causal: causal, payload: .assistantMessageCommitted(
                        messageID: msg.id,
                        content: textContent,
                        assistantFinalIndex: 0
                    ))
                }
                if let tID = currentTurnID {
                    await eventLog.append(causal: causal, payload: .turnCompleted(turnID: tID, terminalReason: .completed))
                }

            case .tool:
                for part in msg.parts {
                    if case let .toolResult(res) = part {
                        let summaryText = res.summary.isEmpty ? (res.content.count > 100 ? String(res.content.prefix(100)) + "..." : res.content) : res.summary
                        let resSnap = ToolResultSnapshot(
                            callID: res.callID,
                            success: res.success,
                            summary: summaryText
                        )
                        await eventLog.append(causal: causal, payload: .toolCompleted(
                            callID: res.callID,
                            result: resSnap,
                            stdoutFinalIndex: nil,
                            stderrFinalIndex: nil
                        ))
                    }
                }
            }
        }
    }

    // MARK: - Turn 提交与调度

    public struct SubmitTurnDecision: Sendable {
        public let turn: TurnSnapshot
        public let status: TurnStatus
        public let runID: RunID?
        public let shouldStartExecution: Bool
    }

    public func submitTurn(
        input: UserInput,
        intent: TurnExecutionIntent,
        userMessage: MessageSnapshot
    ) async -> SubmitTurnDecision {
        let turnID = TurnID()
        let causal = CausalContext(sessionID: sessionID, turnID: turnID)

        // 1. Commit user message and turn created events
        await eventLog.append(causal: causal, payload: .turnCreated(
            TurnSnapshot(turnID: turnID, sessionID: sessionID, userMessage: userMessage, executionIntent: intent, status: .queued)
        ))
        await eventLog.append(causal: causal, payload: .userMessageCommitted(userMessage))

        // 2. Check Root Run concurrency (max 1 active Root Run)
        if activeRootRunID != nil {
            let queuedTurn = TurnSnapshot(
                turnID: turnID,
                sessionID: sessionID,
                userMessage: userMessage,
                executionIntent: intent,
                status: .queued,
                rootRunID: nil,
                createdAt: Date()
            )
            queuedTurns.append(queuedTurn)
            turns[turnID] = queuedTurn
            await eventLog.append(causal: causal, payload: .runQueued(runID: RunID()))
            return SubmitTurnDecision(turn: queuedTurn, status: .queued, runID: nil, shouldStartExecution: false)
        } else {
            let runID = RunID()
            activeRootRunID = runID
            let run = RunSnapshot(
                runID: runID,
                sessionID: sessionID,
                turnID: turnID,
                rootRunID: runID,
                status: .running,
                model: intent.modelSelection ?? "default",
                createdAt: Date()
            )
            runs[runID] = run

            let runningTurn = TurnSnapshot(
                turnID: turnID,
                sessionID: sessionID,
                userMessage: userMessage,
                executionIntent: intent,
                status: .running,
                rootRunID: runID,
                createdAt: Date()
            )
            turns[turnID] = runningTurn

            let runCausal = CausalContext(sessionID: sessionID, turnID: turnID, runID: runID, rootRunID: runID)
            await eventLog.append(causal: runCausal, payload: .runCreated(run))
            await eventLog.append(causal: runCausal, payload: .runStarted(runID: runID))

            return SubmitTurnDecision(turn: runningTurn, status: .running, runID: runID, shouldStartExecution: true)
        }
    }

    public func cancelTurn(turnID: TurnID) async throws {
        guard let index = queuedTurns.firstIndex(where: { $0.turnID == turnID }) else {
            if let turn = turns[turnID], turn.status == .running {
                throw RuntimeError(category: .validation, code: "turnAlreadyRunning", message: "Turn 正在运行，请使用 cancelRun 取消执行", retryability: .none, source: .client)
            }
            throw RuntimeError(category: .validation, code: "turnNotFound", message: "未找到处于排队状态的 Turn \(turnID.rawValue)", retryability: .none, source: .client)
        }
        let queued = queuedTurns.remove(at: index)
        let cancelledTurn = TurnSnapshot(
            turnID: turnID,
            sessionID: sessionID,
            userMessage: queued.userMessage,
            executionIntent: queued.executionIntent,
            status: .cancelled,
            rootRunID: nil,
            createdAt: queued.createdAt,
            completedAt: Date()
        )
        turns[turnID] = cancelledTurn
        let causal = CausalContext(sessionID: sessionID, turnID: turnID)
        await eventLog.append(causal: causal, payload: .turnCompleted(turnID: turnID, terminalReason: .userCancelled))
    }

    public func rollbackTurn(decision: SubmitTurnDecision) async {
        rollbackTurnID(decision.turn.turnID, runID: decision.runID)
    }

    public func rollbackTurnID(_ turnID: TurnID, runID: RunID?) {
        turns.removeValue(forKey: turnID)
        queuedTurns.removeAll(where: { $0.turnID == turnID })
        if let runID {
            runs.removeValue(forKey: runID)
            if activeRootRunID == runID {
                activeRootRunID = nil
            }
        }
    }

    public struct NextTurnToRun: Sendable {
        public let turn: TurnSnapshot
        public let runID: RunID
    }

    public func finishRun(runID: RunID, reason: TerminalReason, error: RuntimeError? = nil) async -> NextTurnToRun? {
        guard let run = runs[runID] else { return nil }
        let turnID = run.turnID
        let causal = CausalContext(sessionID: sessionID, turnID: turnID, runID: runID, rootRunID: run.rootRunID)

        if let error {
            let failedRun = RunSnapshot(
                runID: runID,
                sessionID: sessionID,
                turnID: turnID,
                rootRunID: run.rootRunID,
                status: .failed,
                model: run.model,
                createdAt: run.createdAt,
                completedAt: Date(),
                terminalReason: reason
            )
            runs[runID] = failedRun
            if let turn = turns[turnID] {
                turns[turnID] = TurnSnapshot(
                    turnID: turnID,
                    sessionID: sessionID,
                    userMessage: turn.userMessage,
                    executionIntent: turn.executionIntent,
                    status: .failed,
                    rootRunID: run.rootRunID ?? runID,
                    createdAt: turn.createdAt,
                    completedAt: Date()
                )
            }
            await eventLog.append(causal: causal, payload: .runFailed(runID: runID, error: error))
            await eventLog.append(causal: causal, payload: .turnFailed(turnID: turnID, error: error))
        } else {
            let completedRun = RunSnapshot(
                runID: runID,
                sessionID: sessionID,
                turnID: turnID,
                rootRunID: run.rootRunID,
                status: .completed,
                model: run.model,
                createdAt: run.createdAt,
                completedAt: Date(),
                terminalReason: reason
            )
            runs[runID] = completedRun
            if let turn = turns[turnID] {
                turns[turnID] = TurnSnapshot(
                    turnID: turnID,
                    sessionID: sessionID,
                    userMessage: turn.userMessage,
                    executionIntent: turn.executionIntent,
                    status: .completed,
                    rootRunID: run.rootRunID ?? runID,
                    createdAt: turn.createdAt,
                    completedAt: Date()
                )
            }
            await eventLog.append(causal: causal, payload: .runCompleted(runID: runID, terminalReason: reason))
            await eventLog.append(causal: causal, payload: .turnCompleted(turnID: turnID, terminalReason: reason))
        }

        if activeRootRunID == runID {
            activeRootRunID = nil
        }

        return await scheduleNextQueuedTurn()
    }

    public func cancelRun(runID: RunID, reason: String? = nil) async throws -> NextTurnToRun? {
        guard let run = runs[runID] else {
            throw RuntimeError(category: .validation, code: "runNotFound", message: "Run \(runID.rawValue) 不存在", retryability: .none, source: .client)
        }
        let causal = CausalContext(sessionID: sessionID, turnID: run.turnID, runID: runID, rootRunID: run.rootRunID)
        let cancelledRun = RunSnapshot(
            runID: runID,
            sessionID: sessionID,
            turnID: run.turnID,
            rootRunID: run.rootRunID,
            status: .cancelled,
            model: run.model,
            createdAt: run.createdAt,
            completedAt: Date(),
            terminalReason: .userCancelled
        )
        runs[runID] = cancelledRun
        if let turn = turns[run.turnID] {
            turns[run.turnID] = TurnSnapshot(
                turnID: run.turnID,
                sessionID: sessionID,
                userMessage: turn.userMessage,
                executionIntent: turn.executionIntent,
                status: .cancelled,
                rootRunID: run.rootRunID ?? runID,
                createdAt: turn.createdAt,
                completedAt: Date()
            )
        }
        await eventLog.append(causal: causal, payload: .runCancelled(runID: runID, reason: reason ?? "userCancelled"))
        await eventLog.append(causal: causal, payload: .turnCompleted(turnID: run.turnID, terminalReason: .userCancelled))

        if activeRootRunID == runID {
            activeRootRunID = nil
        }

        return await scheduleNextQueuedTurn()
    }

    private func scheduleNextQueuedTurn() async -> NextTurnToRun? {
        // Schedule next queued Turn if any
        if !queuedTurns.isEmpty {
            let next = queuedTurns.removeFirst()
            let nextRunID = RunID()
            activeRootRunID = nextRunID

            let nextRun = RunSnapshot(
                runID: nextRunID,
                sessionID: sessionID,
                turnID: next.turnID,
                rootRunID: nextRunID,
                status: .running,
                model: next.executionIntent.modelSelection ?? "default",
                createdAt: Date()
            )
            runs[nextRunID] = nextRun

            let runningTurn = TurnSnapshot(
                turnID: next.turnID,
                sessionID: sessionID,
                userMessage: next.userMessage,
                executionIntent: next.executionIntent,
                status: .running,
                rootRunID: nextRunID,
                createdAt: next.createdAt
            )
            turns[next.turnID] = runningTurn

            let nextCausal = CausalContext(sessionID: sessionID, turnID: next.turnID, runID: nextRunID, rootRunID: nextRunID)
            await eventLog.append(causal: nextCausal, payload: .runCreated(nextRun))
            await eventLog.append(causal: nextCausal, payload: .runStarted(runID: nextRunID))

            return NextTurnToRun(turn: runningTurn, runID: nextRunID)
        }

        return nil
    }

    public func currentAgentMode() -> AgentMode {
        if let activeID = activeRootRunID, let run = runs[activeID], let turn = turns[run.turnID] {
            return turn.executionIntent.mode
        }
        return turns.values.sorted(by: { $0.createdAt < $1.createdAt }).last?.executionIntent.mode ?? .build
    }

    private var streamTerminalIndices: [StreamID: UInt64] = [:]
    private var knownStreamIDs: Set<StreamID> = []

    // Assistant streaming 在首 frame 前必须已有稳定 MessageID
    public func beginAssistantStream(stepID: ModelStepID, runID: RunID) async -> (messageID: MessageID, streamID: StreamID) {
        let messageID = MessageID()
        let streamID = StreamID()
        knownStreamIDs.insert(streamID)
        let run = runs[runID]
        let causal = CausalContext(sessionID: sessionID, turnID: run?.turnID, runID: runID, rootRunID: run?.rootRunID, modelStepID: stepID)

        // Assistant streaming 在首 frame 前必须已有稳定 MessageID
        await eventLog.append(causal: causal, payload: .assistantMessageStarted(messageID: messageID, assistantStreamID: streamID))
        return (messageID, streamID)
    }

    @discardableResult
    public func emitStreamFrame(frame: StreamFrame) throws -> StreamFrame {
        knownStreamIDs.insert(frame.streamID)
        if let terminal = streamTerminalIndices[frame.streamID] {
            if frame.index > terminal {
                throw RuntimeError(category: .runtime, code: "streamAlreadyTerminated", message: "Stream \(frame.streamID.rawValue) 已在 finalIndex \(terminal) 结束", retryability: .none, source: .core)
            }
        }

        streamFrames[frame.streamID, default: []].append(frame)
        if let continuations = streamSubscribers[frame.streamID] {
            for continuation in continuations.values {
                continuation.yield(frame)
            }
        }
        return frame
    }

    public func closeStream(streamID: StreamID, finalIndex: UInt64) {
        streamTerminalIndices[streamID] = finalIndex
        if let continuations = streamSubscribers.removeValue(forKey: streamID) {
            for continuation in continuations.values {
                continuation.finish()
            }
        }
    }

    public func hasStream(_ streamID: StreamID) -> Bool {
        knownStreamIDs.contains(streamID) || streamFrames[streamID] != nil || modelSteps.values.contains { $0.visibleReasoningStreamID == streamID || $0.assistantStreamID == streamID }
    }

    public func commitAssistantMessage(
        messageID: MessageID,
        streamID: StreamID? = nil,
        causal: CausalContext,
        content: String,
        finalIndex: UInt64
    ) async {
        if let streamID {
            closeStream(streamID: streamID, finalIndex: finalIndex)
        }
        await eventLog.append(causal: causal, payload: .assistantMessageCommitted(
            messageID: messageID,
            content: content,
            assistantFinalIndex: finalIndex
        ))
    }

    // MARK: - ModelStep Streaming & Barrier

    public func beginModelStep(
        stepID: ModelStepID,
        runID: RunID,
        stepNumber: Int
    ) async -> (messageID: MessageID, reasoningStreamID: StreamID, assistantStreamID: StreamID) {
        let messageID = MessageID()
        let reasoningStreamID = StreamID()
        let assistantStreamID = StreamID()
        knownStreamIDs.insert(reasoningStreamID)
        knownStreamIDs.insert(assistantStreamID)
        let run = runs[runID]
        let causal = CausalContext(sessionID: sessionID, turnID: run?.turnID, runID: runID, rootRunID: run?.rootRunID, modelStepID: stepID)

        let snapshot = ModelStepSnapshot(
            stepID: stepID,
            runID: runID,
            stepNumber: stepNumber,
            status: "running",
            visibleReasoningStreamID: reasoningStreamID,
            assistantStreamID: assistantStreamID,
            startedAt: Date()
        )
        modelSteps[stepID] = snapshot

        await eventLog.append(causal: causal, payload: .modelStepStarted(
            stepID: stepID,
            visibleReasoningStreamID: reasoningStreamID,
            assistantStreamID: assistantStreamID
        ))
        await eventLog.append(causal: causal, payload: .assistantMessageStarted(messageID: messageID, assistantStreamID: assistantStreamID))
        return (messageID, reasoningStreamID, assistantStreamID)
    }

    public func completeModelStep(
        stepID: ModelStepID,
        causal: CausalContext,
        finalIndex: UInt64?,
        outputMetadata: ModelStepOutputMetadata?
    ) async {
        if let existing = modelSteps[stepID] {
            if let finalIndex, let streamID = existing.visibleReasoningStreamID {
                closeStream(streamID: streamID, finalIndex: finalIndex)
            }
            modelSteps[stepID] = ModelStepSnapshot(
                stepID: stepID,
                runID: existing.runID,
                stepNumber: existing.stepNumber,
                status: "completed",
                visibleReasoningStreamID: existing.visibleReasoningStreamID,
                assistantStreamID: existing.assistantStreamID,
                startedAt: existing.startedAt,
                completedAt: Date()
            )
        }
        await eventLog.append(causal: causal, payload: .modelStepCompleted(
            stepID: stepID,
            visibleReasoningFinalIndex: finalIndex,
            outputMetadata: outputMetadata
        ))
    }

    // MARK: - Tool Invocations & Barrier

    private var toolStreams: [ToolCallID: (stdout: StreamID?, stderr: StreamID?)] = [:]

    public func recordToolRequested(snapshot: ToolInvocationSnapshot, causal: CausalContext) async {
        toolInvocations[snapshot.callID] = snapshot
        await eventLog.append(causal: causal, payload: .toolRequested(snapshot))
    }

    public func recordToolScheduled(callID: ToolCallID, causal: CausalContext) async {
        if let inv = toolInvocations[callID] {
            toolInvocations[callID] = ToolInvocationSnapshot(
                callID: inv.callID,
                toolID: inv.toolID,
                displayName: inv.displayName,
                argumentsSummary: inv.argumentsSummary,
                state: .scheduled,
                resultPreview: inv.resultPreview,
                resultRef: inv.resultRef,
                durationMs: inv.durationMs,
                error: inv.error
            )
        }
        await eventLog.append(causal: causal, payload: .toolScheduled(callID: callID))
    }

    public func recordToolWaitingForPermission(callID: ToolCallID, permissionID: PermissionID, causal: CausalContext) async {
        if let inv = toolInvocations[callID] {
            toolInvocations[callID] = ToolInvocationSnapshot(
                callID: callID,
                toolID: inv.toolID,
                displayName: inv.displayName,
                argumentsSummary: inv.argumentsSummary,
                state: .waitingForPermission,
                resultPreview: inv.resultPreview,
                resultRef: inv.resultRef,
                durationMs: inv.durationMs,
                error: inv.error
            )
        }
        await eventLog.append(causal: causal, payload: .toolWaitingForPermission(callID: callID, permissionID: permissionID))
    }

    public func recordToolRunning(callID: ToolCallID, stdoutStreamID: StreamID?, stderrStreamID: StreamID?, causal: CausalContext) async {
        if let stdoutStreamID { knownStreamIDs.insert(stdoutStreamID) }
        if let stderrStreamID { knownStreamIDs.insert(stderrStreamID) }
        toolStreams[callID] = (stdout: stdoutStreamID, stderr: stderrStreamID)
        if let inv = toolInvocations[callID] {
            toolInvocations[callID] = ToolInvocationSnapshot(
                callID: callID,
                toolID: inv.toolID,
                displayName: inv.displayName,
                argumentsSummary: inv.argumentsSummary,
                state: .running,
                resultPreview: inv.resultPreview,
                resultRef: inv.resultRef,
                durationMs: inv.durationMs,
                error: inv.error
            )
        }
        await eventLog.append(causal: causal, payload: .toolRunning(callID: callID, stdoutStreamID: stdoutStreamID, stderrStreamID: stderrStreamID))
    }

    public func recordToolCompleted(
        callID: ToolCallID,
        result: ToolResultSnapshot,
        stdoutFinalIndex: UInt64?,
        stderrFinalIndex: UInt64?,
        causal: CausalContext
    ) async {
        if let streams = toolStreams.removeValue(forKey: callID) {
            if let stdoutFinalIndex, let stdout = streams.stdout {
                closeStream(streamID: stdout, finalIndex: stdoutFinalIndex)
            }
            if let stderrFinalIndex, let stderr = streams.stderr {
                closeStream(streamID: stderr, finalIndex: stderrFinalIndex)
            }
        }
        if let inv = toolInvocations[callID] {
            toolInvocations[callID] = ToolInvocationSnapshot(
                callID: callID,
                toolID: inv.toolID,
                displayName: inv.displayName,
                argumentsSummary: inv.argumentsSummary,
                state: .completed,
                resultPreview: result.preview,
                resultRef: result.contentRef,
                durationMs: result.timing.executionMilliseconds > 0 ? result.timing.executionMilliseconds : inv.durationMs,
                error: result.error
            )
        }
        await eventLog.append(causal: causal, payload: .toolCompleted(
            callID: callID,
            result: result,
            stdoutFinalIndex: stdoutFinalIndex,
            stderrFinalIndex: stderrFinalIndex
        ))
    }

    public func recordProviderRequestState(requestID: ProviderRequestID, state: ProviderRequestState, causal: CausalContext) async {
        await eventLog.append(causal: causal, payload: .providerRequestStateChanged(requestID: requestID, state: state))
    }

    public func recordContextStateChanged(_ snapshot: ContextStateSnapshot, causal: CausalContext) async {
        await eventLog.append(causal: causal, payload: .contextStateChanged(snapshot))
    }

    // MARK: - Interactions

    public func recordInteractionRequested(snapshot: InteractionSnapshot) async {
        interactions[snapshot.interactionID] = snapshot
        await eventLog.append(causal: snapshot.causal, payload: .interactionRequested(snapshot))
    }

    public func resolveInteraction(interactionID: InteractionID, resolution: InteractionResolution) async throws {
        guard let interaction = interactions[interactionID] else {
            throw RuntimeError(category: .permission, code: "interactionNotFound", message: "Interaction \(interactionID.rawValue) 不存在", retryability: .none, source: .client)
        }
        interactions.removeValue(forKey: interactionID)
        await eventLog.append(causal: interaction.causal, payload: .interactionResolved(interactionID: interactionID, resolution: resolution))
    }

    public func listPendingInteractions() -> [InteractionSnapshot] {
        Array(interactions.values)
    }

    // MARK: - Stream Subscription

    public func subscribeStream(streamID: StreamID, afterIndex: UInt64?) -> AsyncStream<StreamFrame> {
        let key = UUID()
        let cached = streamFrames[streamID] ?? []
        let replay = cached.filter { frame in
            if let afterIndex { return frame.index > afterIndex }
            return true
        }
        let terminalIndex = streamTerminalIndices[streamID]
        let lastReplayIndex = replay.last?.index

        return AsyncStream { continuation in
            for frame in replay {
                continuation.yield(frame)
            }
            if let terminalIndex, let lastReplayIndex, lastReplayIndex >= terminalIndex {
                continuation.finish()
                return
            }
            self.streamSubscribers[streamID, default: [:]][key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeStreamSubscriber(streamID: streamID, key: key)
                }
            }
        }
    }

    private func removeStreamSubscriber(streamID: StreamID, key: UUID) {
        streamSubscribers[streamID]?.removeValue(forKey: key)
    }

    // MARK: - Snapshot 组装

    public func buildSnapshot(
        info: SessionSummary,
        contextState: ContextStateSnapshot,
        permissionConfiguration: PermissionConfiguration,
        agentMode: AgentMode,
        revision: UInt64
    ) async -> SessionSnapshot {
        let cursor = await eventLog.currentCursor()
        let recentEvents = await eventLog.recentEvents(count: 2000)
        let activeRun = activeRootRunID.flatMap { runs[$0] }

        return SessionSnapshot(
            sessionID: sessionID,
            info: info,
            recentTurns: Array(turns.values),
            activeRootRun: activeRun,
            activeChildRuns: [],
            pendingInteractions: Array(interactions.values),
            activeModelSteps: Array(modelSteps.values),
            recentToolInvocations: Array(toolInvocations.values),
            contextState: contextState,
            permissionConfiguration: permissionConfiguration,
            agentMode: agentMode,
            recentEvents: recentEvents,
            historyBeforeCursor: nil,
            eventCursor: cursor,
            revision: revision
        )
    }

    public func getTurn(turnID: TurnID) -> TurnSnapshot? {
        turns[turnID]
    }

    public func listTurns(page: PageRequest) -> Page<TurnSnapshot> {
        let all = Array(turns.values).sorted(by: { $0.createdAt < $1.createdAt })
        let items = Array(all.prefix(page.limit))
        return Page(items: items, nextCursor: nil, hasMore: all.count > items.count)
    }

    public func getRun(runID: RunID) -> RunSnapshot? {
        runs[runID]
    }

    public func listRuns(page: PageRequest) -> Page<RunSnapshot> {
        let all = Array(runs.values).sorted(by: { $0.createdAt < $1.createdAt })
        let items = Array(all.prefix(page.limit))
        return Page(items: items, nextCursor: nil, hasMore: all.count > items.count)
    }
}
