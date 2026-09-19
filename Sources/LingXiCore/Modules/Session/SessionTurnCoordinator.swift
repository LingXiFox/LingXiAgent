import Foundation
import LingXiProtocol

/// SessionTurnCoordinator：负责 Session 内 Turn / Run 生命周期、并发约束、Event Log 与 Stream 屏障。
/// 硬规则：一个 Session 最多一个 active Root Run；额外 Turn 默认排队 (queue)。
public actor SessionTurnCoordinator {
    public let sessionID: SessionID
    public let eventLog: SessionEventLog

    public private(set) var activeRootRunID: RunID?
    private var queuedTurns: [TurnSnapshot] = []
    public var queuedTurnsSnapshot: [TurnSnapshot] {
        queuedTurns
    }
    private var turns: [TurnID: TurnSnapshot] = [:]
    private var runs: [RunID: RunSnapshot] = [:]
    private var interactions: [InteractionID: InteractionSnapshot] = [:]
    private var modelSteps: [ModelStepID: ModelStepSnapshot] = [:]
    private var toolInvocations: [ToolCallID: ToolInvocationSnapshot] = [:]

    public let todoStore: TodoStore?

    private var streamReplayState = StreamReplayState()

    public init(sessionID: SessionID, eventLog: SessionEventLog, todoStore: TodoStore? = nil) {
        self.sessionID = sessionID
        self.eventLog = eventLog
        self.todoStore = todoStore
    }

    /// 撤回（undo）操作后的全量状态重置与重新水合
    public func resetForRevert(remainingMessages: [Message]) async {
        activeRootRunID = nil
        queuedTurns.removeAll()
        turns.removeAll()
        runs.removeAll()
        interactions.removeAll()
        modelSteps.removeAll()
        toolInvocations.removeAll()
        streamReplayState.reset()

        await eventLog.resetToEvents([])
        await hydrateHistoricalMessages(remainingMessages)
    }

    /// 从持久化消息流中水合还原历史 turns 和 timeline events
    public func hydrateHistoricalMessages(_ messages: [Message]) async {
        guard turns.isEmpty, !messages.isEmpty else { return }

        // 检查 eventLog 是否已从持久化存储（events.jsonl）加载过历史事件；若是，则内存水合只恢复 turns/tools，绝不重复写入 eventLog
        let existingEvents = await eventLog.recentEvents(count: 1)
        let hasExistingEvents = !existingEvents.isEmpty

        // 预先建立 callID 到 toolResult 的全局索引，杜绝历史工具水合产生孤儿悬空 running 状态
        var toolResultsByCallID: [ToolCallID: ToolResult] = [:]
        for msg in messages {
            for part in msg.parts {
                if case let .toolResult(res) = part {
                    toolResultsByCallID[res.callID] = res
                }
            }
        }

        var completedCallIDs: Set<ToolCallID> = []
        var currentTurnID: TurnID?
        var lastRole: MessageRole?
        var lastUserContent: String?
        for msg in messages {
            if msg.role == .user {
                if lastRole == .user && lastUserContent == msg.content {
                    continue
                }
                lastUserContent = msg.content
            }
            lastRole = msg.role

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

                if !hasExistingEvents {
                    let turnCausal = CausalContext(sessionID: sessionID, turnID: tID)
                    await eventLog.append(causal: turnCausal, payload: .turnCreated(turnSnap))
                    await eventLog.append(causal: turnCausal, payload: .userMessageCommitted(snap))
                }

            case .assistant:
                var textContent = ""
                for part in msg.parts {
                    switch part {
                    case let .text(txt):
                        textContent += txt
                    case let .toolCall(tc):
                        let hasResult = toolResultsByCallID[tc.callID] != nil
                        let invocation = ToolInvocationSnapshot(
                            callID: tc.callID,
                            toolID: tc.toolID,
                            displayName: tc.toolName,
                            argumentsSummary: tc.arguments,
                            state: hasResult ? .completed : .cancelled
                        )
                        toolInvocations[tc.callID] = invocation
                        if !hasExistingEvents {
                            await eventLog.append(causal: causal, payload: .toolRequested(invocation))
                            if let res = toolResultsByCallID[tc.callID] {
                                let summaryText = res.summary.isEmpty ? (res.content.count > 100 ? String(res.content.prefix(100)) + "..." : res.content) : res.summary
                                let resSnap = ToolResultSnapshot(
                                    callID: res.callID,
                                    toolName: res.toolName,
                                    success: res.success,
                                    summary: summaryText
                                )
                                await eventLog.append(causal: causal, payload: .toolCompleted(
                                    callID: res.callID,
                                    result: resSnap,
                                    stdoutFinalIndex: nil,
                                    stderrFinalIndex: nil
                                ))
                            } else {
                                await eventLog.append(causal: causal, payload: .toolCancelled(
                                    callID: tc.callID,
                                    stdoutFinalIndex: nil,
                                    stderrFinalIndex: nil
                                ))
                            }
                        }
                        completedCallIDs.insert(tc.callID)
                    case .toolResult, .observation:
                        break
                    }
                }
                if !hasExistingEvents {
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
                }

            case .tool:
                for part in msg.parts {
                    if case let .toolResult(res) = part, !completedCallIDs.contains(res.callID) {
                        let summaryText = res.summary.isEmpty ? (res.content.count > 100 ? String(res.content.prefix(100)) + "..." : res.content) : res.summary
                        let resSnap = ToolResultSnapshot(
                            callID: res.callID,
                            toolName: res.toolName,
                            success: res.success,
                            summary: summaryText
                        )
                        if !hasExistingEvents {
                            await eventLog.append(causal: causal, payload: .toolCompleted(
                                callID: res.callID,
                                result: resSnap,
                                stdoutFinalIndex: nil,
                                stderrFinalIndex: nil
                            ))
                        }
                        completedCallIDs.insert(res.callID)
                    }
                }
            }
        }
    }

    /// Rebuilds queued and historical state from durable EventLog, aborting started-but-nonterminal runs and preserving queued FIFO
    public func restoreHistoricalQueue() async {
        let allEvents = await eventLog.allEvents()
        guard !allEvents.isEmpty else { return }

        var createdTurns: [TurnID: TurnSnapshot] = [:]
        var createdRuns: [RunID: RunSnapshot] = [:]
        var queuedRunIDs: [RunID] = []
        var startedRunIDs: Set<RunID> = []
        var terminalTurnIDs: Set<TurnID> = []
        var terminalRunIDs: Set<RunID> = []

        for envelope in allEvents {
            switch envelope.payload {
            case let .turnCreated(snap):
                createdTurns[snap.turnID] = snap
            case let .turnCompleted(turnID, terminalReason):
                terminalTurnIDs.insert(turnID)
                if let t = createdTurns[turnID] {
                    let status: TurnStatus = (terminalReason == .userCancelled) ? .cancelled : .completed
                    createdTurns[turnID] = TurnSnapshot(
                        turnID: t.turnID,
                        sessionID: t.sessionID,
                        userMessage: t.userMessage,
                        executionIntent: t.executionIntent,
                        status: status,
                        rootRunID: t.rootRunID,
                        createdAt: t.createdAt,
                        completedAt: envelope.timestamp
                    )
                }
            case let .turnFailed(turnID, _):
                terminalTurnIDs.insert(turnID)
                if let t = createdTurns[turnID] {
                    createdTurns[turnID] = TurnSnapshot(
                        turnID: t.turnID,
                        sessionID: t.sessionID,
                        userMessage: t.userMessage,
                        executionIntent: t.executionIntent,
                        status: .failed,
                        rootRunID: t.rootRunID,
                        createdAt: t.createdAt,
                        completedAt: envelope.timestamp
                    )
                }
            case let .runCreated(snap):
                createdRuns[snap.runID] = snap
            case let .runStarted(runID):
                startedRunIDs.insert(runID)
                if let r = createdRuns[runID], !terminalRunIDs.contains(runID) {
                    createdRuns[runID] = RunSnapshot(
                        runID: r.runID,
                        sessionID: r.sessionID,
                        turnID: r.turnID,
                        rootRunID: r.rootRunID,
                        status: .running,
                        model: r.model,
                        createdAt: r.createdAt,
                        completedAt: nil,
                        terminalReason: nil
                    )
                }
            case let .runCompleted(runID, terminalReason):
                terminalRunIDs.insert(runID)
                if let r = createdRuns[runID] {
                    createdRuns[runID] = RunSnapshot(
                        runID: r.runID,
                        sessionID: r.sessionID,
                        turnID: r.turnID,
                        rootRunID: r.rootRunID,
                        status: .completed,
                        model: r.model,
                        createdAt: r.createdAt,
                        completedAt: envelope.timestamp,
                        terminalReason: terminalReason
                    )
                }
            case let .runFailed(runID, _):
                terminalRunIDs.insert(runID)
                if let r = createdRuns[runID] {
                    createdRuns[runID] = RunSnapshot(
                        runID: r.runID,
                        sessionID: r.sessionID,
                        turnID: r.turnID,
                        rootRunID: r.rootRunID,
                        status: .failed,
                        model: r.model,
                        createdAt: r.createdAt,
                        completedAt: envelope.timestamp,
                        terminalReason: .runtimeFailure
                    )
                }
            case let .runCancelled(runID, _):
                terminalRunIDs.insert(runID)
                if let r = createdRuns[runID] {
                    createdRuns[runID] = RunSnapshot(
                        runID: r.runID,
                        sessionID: r.sessionID,
                        turnID: r.turnID,
                        rootRunID: r.rootRunID,
                        status: .cancelled,
                        model: r.model,
                        createdAt: r.createdAt,
                        completedAt: envelope.timestamp,
                        terminalReason: .userCancelled
                    )
                }
            case let .runQueued(runID):
                if !queuedRunIDs.contains(runID) {
                    queuedRunIDs.append(runID)
                }
            default:
                break
            }
        }

        // 1. Populate memory state for historical turns and runs
        for (turnID, snap) in createdTurns {
            turns[turnID] = snap
        }
        for (runID, snap) in createdRuns {
            runs[runID] = snap
        }

        // 2. Critical Safety: Runs started before crash but not terminal must be marked as failed/aborted,
        // and never requeued from scratch to avoid repeated side effects.
        for runID in startedRunIDs where !terminalRunIDs.contains(runID) {
            if let existing = runs[runID] {
                let abortedRun = RunSnapshot(
                    runID: runID,
                    sessionID: sessionID,
                    turnID: existing.turnID,
                    rootRunID: existing.rootRunID,
                    status: .failed,
                    model: existing.model,
                    createdAt: existing.createdAt,
                    completedAt: Date(),
                    terminalReason: .runtimeFailure
                )
                runs[runID] = abortedRun
                terminalRunIDs.insert(runID)

                if let turn = turns[existing.turnID], !terminalTurnIDs.contains(turn.turnID) {
                    let abortedTurn = TurnSnapshot(
                        turnID: turn.turnID,
                        sessionID: sessionID,
                        userMessage: turn.userMessage,
                        executionIntent: turn.executionIntent,
                        status: .failed,
                        rootRunID: turn.rootRunID,
                        createdAt: turn.createdAt,
                        completedAt: Date()
                    )
                    turns[turn.turnID] = abortedTurn
                    terminalTurnIDs.insert(turn.turnID)
                }

                // Persist terminal events to ensure deterministic replay semantics
                let causal = CausalContext(sessionID: sessionID, turnID: existing.turnID, runID: runID, rootRunID: existing.rootRunID)
                let runtimeErr = RuntimeError(category: .runtime, code: "interruptedBySystemCrash", message: "Run interrupted by system crash", retryability: .afterDelay, source: .core)
                await eventLog.append(causal: causal, payload: .runFailed(runID: runID, error: runtimeErr))
                await eventLog.append(causal: causal, payload: .turnFailed(turnID: existing.turnID, error: runtimeErr))
            }
        }

        // 3. Reconstruct queuedTurns: Only restore turns queued but never started, preserving original FIFO order
        for runID in queuedRunIDs {
            if !terminalRunIDs.contains(runID), !startedRunIDs.contains(runID), let run = runs[runID] {
                if let turn = turns[run.turnID], !terminalTurnIDs.contains(turn.turnID) {
                    if !queuedTurns.contains(where: { $0.turnID == turn.turnID }) {
                        queuedTurns.append(turn)
                    }
                }
            }
        }
    }

    /// Attempt to schedule the next queued turn from the restored queue when coordinator is idle
    public func scheduleNextQueuedTurnIfIdle() async -> NextTurnToRun? {
        guard activeRootRunID == nil else { return nil }
        return await scheduleNextQueuedTurn()
    }

    public func isTurnQueued(turnID: TurnID) -> Bool {
        queuedTurns.contains(where: { $0.turnID == turnID })
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

        // 2. Check Root Run concurrency & Queue FIFO (max 1 active Root Run; never bypass queued turns)
        if activeRootRunID != nil || !queuedTurns.isEmpty {
            let queuedRunID = RunID()
            let queuedTurn = TurnSnapshot(
                turnID: turnID,
                sessionID: sessionID,
                userMessage: userMessage,
                executionIntent: intent,
                status: .queued,
                rootRunID: queuedRunID,
                createdAt: Date()
            )
            let queuedRun = RunSnapshot(
                runID: queuedRunID,
                sessionID: sessionID,
                turnID: turnID,
                rootRunID: queuedRunID,
                status: .queued,
                model: intent.modelSelection ?? "default",
                createdAt: Date()
            )
            runs[queuedRunID] = queuedRun
            queuedTurns.append(queuedTurn)
            turns[turnID] = queuedTurn
            let queuedCausal = CausalContext(sessionID: sessionID, turnID: turnID, runID: queuedRunID, rootRunID: queuedRunID)
            await eventLog.append(causal: queuedCausal, payload: .runCreated(queuedRun))
            await eventLog.append(causal: causal, payload: .runQueued(runID: queuedRunID))
            return SubmitTurnDecision(turn: queuedTurn, status: .queued, runID: queuedRunID, shouldStartExecution: false)
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
        if let runID = queued.rootRunID, let r = runs[runID] {
            runs[runID] = RunSnapshot(
                runID: runID,
                sessionID: sessionID,
                turnID: turnID,
                rootRunID: r.rootRunID,
                status: .cancelled,
                model: r.model,
                createdAt: r.createdAt,
                completedAt: Date(),
                terminalReason: .userCancelled
            )
        }
        let cancelledTurn = TurnSnapshot(
            turnID: turnID,
            sessionID: sessionID,
            userMessage: queued.userMessage,
            executionIntent: queued.executionIntent,
            status: .cancelled,
            rootRunID: queued.rootRunID,
            createdAt: queued.createdAt,
            completedAt: Date()
        )
        turns[turnID] = cancelledTurn
        let causal = CausalContext(sessionID: sessionID, turnID: turnID, runID: queued.rootRunID, rootRunID: queued.rootRunID)
        if let runID = queued.rootRunID {
            await eventLog.append(causal: causal, payload: .runCancelled(runID: runID, reason: "Turn cancelled while queued"))
        }
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
        guard let run = runs[runID], !run.status.isTerminal else {
            // Idempotent guard: already terminal or not found. Never advance queue twice!
            return nil
        }
        let turnID = run.turnID
        let causal = CausalContext(sessionID: sessionID, turnID: turnID, runID: runID, rootRunID: run.rootRunID)

        let terminalStatus: RunStatus
        if reason == .userCancelled {
            terminalStatus = .cancelled
        } else if error != nil || reason == .runtimeFailure {
            terminalStatus = .failed
        } else {
            terminalStatus = .completed
        }

        let terminalRun = RunSnapshot(
            runID: runID,
            sessionID: sessionID,
            turnID: turnID,
            rootRunID: run.rootRunID,
            status: terminalStatus,
            model: run.model,
            createdAt: run.createdAt,
            completedAt: Date(),
            terminalReason: reason
        )
        runs[runID] = terminalRun

        if let turn = turns[turnID] {
            let turnStatus: TurnStatus = (terminalStatus == .cancelled) ? .cancelled : ((terminalStatus == .failed) ? .failed : .completed)
            turns[turnID] = TurnSnapshot(
                turnID: turnID,
                sessionID: sessionID,
                userMessage: turn.userMessage,
                executionIntent: turn.executionIntent,
                status: turnStatus,
                rootRunID: run.rootRunID ?? runID,
                createdAt: turn.createdAt,
                completedAt: Date()
            )
        }

        if terminalStatus == .cancelled {
            await eventLog.append(causal: causal, payload: .runCancelled(runID: runID, reason: "userCancelled"))
            await eventLog.append(causal: causal, payload: .turnCompleted(turnID: turnID, terminalReason: .userCancelled))
        } else if let error {
            await eventLog.append(causal: causal, payload: .runFailed(runID: runID, error: error))
            await eventLog.append(causal: causal, payload: .turnFailed(turnID: turnID, error: error))
        } else {
            await eventLog.append(causal: causal, payload: .runCompleted(runID: runID, terminalReason: reason))
            await eventLog.append(causal: causal, payload: .turnCompleted(turnID: turnID, terminalReason: reason))
        }

        let wasActiveRoot = (activeRootRunID == runID)
        if wasActiveRoot {
            activeRootRunID = nil
        }

        // Only the winner terminal transition of an active root run may advance the queue!
        if wasActiveRoot {
            return await scheduleNextQueuedTurn()
        } else {
            return nil
        }
    }

    public func cancelRun(runID: RunID, reason: String? = nil) async throws -> NextTurnToRun? {
        guard let run = runs[runID] else {
            throw RuntimeError(category: .validation, code: "runNotFound", message: "Run \(runID.rawValue) 不存在", retryability: .none, source: .client)
        }
        if run.status.isTerminal {
            // Already terminal, idempotent no-op!
            return nil
        }

        // If target run is queued: remove from queuedTurns and mark cancelled, NEVER advance queue!
        if run.status == .queued {
            queuedTurns.removeAll(where: { $0.rootRunID == runID || $0.turnID == run.turnID })
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
            return nil
        }

        // Target run is running: route through single terminalization path
        return await finishRun(runID: runID, reason: .userCancelled)
    }

    private func scheduleNextQueuedTurn() async -> NextTurnToRun? {
        // Schedule next queued Turn if any
        if !queuedTurns.isEmpty {
            let next = queuedTurns.removeFirst()
            let nextRunID = next.rootRunID ?? RunID()
            activeRootRunID = nextRunID

            let existingRun = runs[nextRunID]
            let nextRun = RunSnapshot(
                runID: nextRunID,
                sessionID: sessionID,
                turnID: next.turnID,
                rootRunID: nextRunID,
                status: .running,
                model: next.executionIntent.modelSelection ?? "default",
                createdAt: existingRun?.createdAt ?? Date()
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
            // Invariant: If this Run was already created during queueing, NEVER emit duplicate .runCreated!
            if existingRun == nil {
                await eventLog.append(causal: nextCausal, payload: .runCreated(nextRun))
            }
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

    // Assistant streaming 在首 frame 前必须已有稳定 MessageID
    public func beginAssistantStream(stepID: ModelStepID, runID: RunID) async -> (messageID: MessageID, streamID: StreamID) {
        let messageID = MessageID()
        let streamID = StreamID()
        streamReplayState.recordKnownStream(streamID)
        let run = runs[runID]
        let causal = CausalContext(sessionID: sessionID, turnID: run?.turnID, runID: runID, rootRunID: run?.rootRunID, modelStepID: stepID)

        // Assistant streaming 在首 frame 前必须已有稳定 MessageID
        await eventLog.append(causal: causal, payload: .assistantMessageStarted(messageID: messageID, assistantStreamID: streamID))
        return (messageID, streamID)
    }

    @discardableResult
    public func emitStreamFrame(frame: StreamFrame) throws -> StreamFrame {
        try streamReplayState.emitFrame(frame)
    }

    public func closeStream(streamID: StreamID, finalIndex: UInt64) {
        streamReplayState.closeStream(streamID: streamID, finalIndex: finalIndex)
    }

    public func hasStream(_ streamID: StreamID) -> Bool {
        streamReplayState.hasStream(streamID) || modelSteps.values.contains { $0.visibleReasoningStreamID == streamID || $0.assistantStreamID == streamID }
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
        streamReplayState.recordKnownStream(reasoningStreamID)
        streamReplayState.recordKnownStream(assistantStreamID)
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
        if let stdoutStreamID { streamReplayState.recordKnownStream(stdoutStreamID) }
        if let stderrStreamID { streamReplayState.recordKnownStream(stderrStreamID) }
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

    public func recordProviderRequestState(
        requestID: ProviderRequestID,
        state: ProviderRequestState,
        detail: String? = nil,
        statusCode: Int? = nil,
        causal: CausalContext
    ) async {
        await eventLog.append(causal: causal, payload: .providerRequestStateChanged(
            requestID: requestID,
            state: state,
            detail: detail,
            statusCode: statusCode
        ))
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
        streamReplayState.subscribeStream(streamID: streamID, afterIndex: afterIndex) { [weak self] key in
            Task { [weak self] in
                await self?.removeStreamSubscriber(streamID: streamID, key: key)
            }
        }
    }

    private func removeStreamSubscriber(streamID: StreamID, key: UUID) {
        streamReplayState.removeSubscriber(streamID: streamID, key: key)
    }

    /// 暴露只读 StreamReplayState 供诊断和测试断言生命周期指标
    public var currentStreamReplayState: StreamReplayState {
        streamReplayState
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
            revision: revision,
            todos: todoStore?.getTodos(for: sessionID.rawValue) ?? []
        )
    }

    package func todoSnapshot() -> [TodoItemData] {
        todoStore?.getTodos(for: sessionID.rawValue) ?? []
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
