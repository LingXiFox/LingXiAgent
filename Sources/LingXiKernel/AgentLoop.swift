public struct LoopPolicy: Sendable {
    public var maxSteps: Int
    public var overallTimeout: Duration?
    public var preferredTokens: Int
    public var hardTokens: Int

    public init(maxSteps: Int = 0, overallTimeout: Duration? = nil, preferredTokens: Int = 6_000, hardTokens: Int = 9_000) {
        self.maxSteps = maxSteps
        self.overallTimeout = overallTimeout
        self.preferredTokens = preferredTokens
        self.hardTokens = hardTokens
    }
}

public struct RunRequest: Sendable {
    public let sessionID: SessionID
    public let turnID: TurnID
    public let runID: RunID
    public let executionID: ExecutionID
    public let model: ModelID
    public let prompt: String

    public init(sessionID: SessionID, turnID: TurnID, runID: RunID, executionID: ExecutionID, model: ModelID, prompt: String) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.runID = runID
        self.executionID = executionID
        self.model = model
        self.prompt = prompt
    }
}

public struct RunResult: Sendable {
    public let runID: RunID
    public let status: RunStatus
    public let cause: TerminalCause
    public let detail: String?
    public let steps: Int
    public let assistantText: String
    public let toolOutcomes: Int
    public let usage: ModelUsage?
    /// False when the terminal record could not be written; the run stays non-terminal in memory.
    public let terminalCommitted: Bool
}

private struct LoopState {
    var steps = 0
    var assistantText = ""
    var toolOutcomeCount = 0
    var usage: ModelUsage?
    var lastToolCall: String?
    var lastObservation: String?
}

private enum StepOutcome {
    case completed(stop: ModelStopReason)
    case toolCalls([ToolCall])
    case failure(ModelFailure)
    case violation(String)
    case cancelled
}

public actor AgentLoop {
    private let router: ModelRouter
    private let toolRegistry: ToolRegistry
    private let executor: any ToolExecutor
    private let log: DurableEventLog
    private let runs: RunRegistry
    private let store: SessionStore
    private let clock: any MonotonicClock
    private let instructions: String
    private let planner = ContextBudgetPlanner()

    public init(
        router: ModelRouter,
        toolRegistry: ToolRegistry,
        executor: any ToolExecutor,
        log: DurableEventLog,
        runs: RunRegistry,
        store: SessionStore,
        clock: any MonotonicClock = SystemMonotonicClock(),
        instructions: String
    ) {
        self.router = router
        self.toolRegistry = toolRegistry
        self.executor = executor
        self.log = log
        self.runs = runs
        self.store = store
        self.clock = clock
        self.instructions = instructions
    }

    public func run(_ request: RunRequest, policy: LoopPolicy) async -> RunResult {
        var state = LoopState()
        let outcome: (RunStatus, TerminalCause, String?)
        do {
            try await begin(request)
            outcome = try await drive(request, policy: policy, state: &state)
        } catch let failure as ModelFailure {
            outcome = (.failed, .providerFailure, failure.message)
        } catch let error as ModelRouterError {
            outcome = (.failed, .runtimeFailure, error.guidance)
        } catch let error as TerminalizationError {
            outcome = (.failed, .runtimeFailure, "\(error)")
        } catch {
            outcome = (error is CancellationError ? .cancelled : .failed, error is CancellationError ? .cancelledByUser : .runtimeFailure, error is CancellationError ? nil : "\(error)")
        }

        let committed = await commit(request, outcome: outcome)
        return RunResult(
            runID: request.runID,
            status: committed.status,
            cause: committed.cause,
            detail: committed.detail,
            steps: state.steps,
            assistantText: state.assistantText,
            toolOutcomes: state.toolOutcomeCount,
            usage: state.usage,
            terminalCommitted: committed.committed
        )
    }

    private func begin(_ request: RunRequest) async throws {
        try await runs.create(id: request.runID, sessionID: request.sessionID, turnID: request.turnID)
        let marker = await log.beginMarker()
        let userEntry = ContextEntry(
            id: EntryID("turn-\(request.turnID.rawValue)"),
            segment: .currentUser,
            role: .user,
            payload: .text(request.prompt)
        )
        do {
            try await log.append(.runCreated(request.runID, request.sessionID, request.turnID))
            try await log.append(.runStarted(request.runID))
            try await log.append(.entryRecorded(request.runID, userEntry))
        } catch {
            try? await log.rollBack(to: marker)
            throw error
        }
        await store.append(userEntry, to: request.sessionID)
        try await runs.markRunning(request.runID)
    }

    private func drive(_ request: RunRequest, policy: LoopPolicy, state: inout LoopState) async throws -> (RunStatus, TerminalCause, String?) {
        let origin = clock.now()

        while true {
            state.steps += 1
            if Task.isCancelled {
                return (.cancelled, .cancelledByUser, nil)
            }
            if policy.maxSteps > 0, state.steps > policy.maxSteps {
                return (
                    .stepLimitReached,
                    .stepLimitReached,
                    "steps=\(state.steps) limit=\(policy.maxSteps) lastToolCall=\(state.lastToolCall ?? "none") lastObservation=\(state.lastObservation ?? "none")"
                )
            }
            if let timeout = policy.overallTimeout, clock.now() - origin > timeout {
                return (.deadlineExceeded, .deadlineExceeded, "elapsed=\(clock.now() - origin) limit=\(timeout)")
            }

            let provider = try await router.resolve(model: request.model)
            let capabilities = provider.capabilities
            let requestEntries = try await assemble(request)
            try ContextRequestValidator.validate(requestEntries, placement: capabilities.toolResultPlacement)

            let plan: BudgetPlan
            do {
                plan = try planner.plan(
                    requestEntries,
                    limits: BudgetLimits(preferredTokens: policy.preferredTokens, hardTokens: policy.hardTokens)
                )
            } catch let error as BudgetError {
                return (.budgetExceeded, .budgetExceeded, "\(error)")
            }

            let manifest = await toolRegistry.manifest()
            let step = await consumeStream(
                provider: provider,
                modelRequest: ModelRequest(
                    requestID: RequestID("\(request.runID.rawValue)-step\(state.steps)"),
                    continuationOf: state.steps == 1 ? nil : RequestID("\(request.runID.rawValue)-step\(state.steps - 1)"),
                    executionID: request.executionID,
                    model: request.model,
                    entries: plan.selected,
                    tools: manifest,
                    overallTimeout: policy.overallTimeout
                ),
                state: &state
            )

            switch step {
            case .completed(let stop):
                state.assistantText = state.assistantText.isEmpty ? "" : state.assistantText
                let cause: TerminalCause = state.assistantText.isEmpty ? .completedWithEmptyText : .completedWithText
                return (.completed, cause, state.assistantText.isEmpty ? nil : "stopReason=\(stop.rawValue)")
            case .toolCalls(let calls):
                try await settle(calls: calls, request: request, state: &state, allowParallel: capabilities.supportsParallelToolCalls)
            case .failure(let failure):
                return (.failed, .providerFailure, failure.message)
            case .violation(let detail):
                return (.failed, .streamProtocolViolation, detail)
            case .cancelled:
                return (.cancelled, .cancelledByUser, nil)
            }
        }
    }

    private func assemble(_ request: RunRequest) async throws -> [ContextEntry] {
        var entries: [ContextEntry] = [
            ContextEntry(id: "instructions", segment: .immutableInstructions, role: .system, payload: .text(instructions))
        ]
        entries.append(contentsOf: await store.entries(for: request.sessionID))
        return entries
    }

    private func consumeStream(
        provider: any ModelProvider,
        modelRequest: ModelRequest,
        state: inout LoopState
    ) async -> StepOutcome {
        let stream: AsyncThrowingStream<ModelEvent, Error>
        do {
            stream = try await provider.stream(modelRequest)
        } catch {
            if error is CancellationError { return .cancelled }
            return .failure(ModelFailure(kind: .transport, message: "\(error)"))
        }

        var text = ""
        var calls: [ToolCall] = []
        var started: Set<ToolCallID> = []
        var terminal: ModelStopReason?
        var failure: ModelFailure?

        do {
            for try await event in stream {
                switch event {
                case .providerRequestID, .started, .heartbeat, .reasoningDelta:
                    break
                case .textDelta(let fragment):
                    text += fragment
                case .usage(let usage):
                    state.usage = Self.merge(state.usage, usage)
                case .toolCallStarted(let start):
                    guard started.insert(start.callID).inserted else {
                        return .violation("duplicate toolCallStarted for \(start.callID.rawValue)")
                    }
                case .toolCallDelta(let delta):
                    guard started.contains(delta.callID) else {
                        return .violation("toolCallDelta for unstarted call \(delta.callID.rawValue)")
                    }
                case .toolCallCompleted(let call):
                    guard started.contains(call.callID) else {
                        return .violation("toolCallCompleted for unstarted call \(call.callID.rawValue)")
                    }
                    calls.append(call)
                case .completed(let reason):
                    guard terminal == nil, failure == nil else { return .violation("second terminal event") }
                    terminal = reason
                case .failed(let modelFailure):
                    guard terminal == nil, failure == nil else { return .violation("second terminal event") }
                    failure = modelFailure
                }

                // A terminal event delivered by the provider outranks a concurrent cancel, so the
                // stream is drained to its terminal instead of being abandoned here (LOOP-006).
                // Cancellation is honored at the step boundary, before the next request is sent.
                if terminal != nil || failure != nil { break }
            }
        } catch let modelFailure as ModelFailure {
            failure = failure ?? modelFailure
        } catch {
            if error is CancellationError || Task.isCancelled { return .cancelled }
            return .failure(ModelFailure(kind: .streamProtocol, message: "\(error)"))
        }

        if let failure { return .failure(failure) }
        guard let terminal else { return .violation("stream ended without a terminal event") }

        if terminal == .toolCalls {
            guard !calls.isEmpty else { return .violation("terminal reason is toolCalls but no call completed") }
            state.lastToolCall = calls.last.map { "\($0.toolName)(\($0.argumentsJSON))" } ?? state.lastToolCall
            return .toolCalls(calls)
        }

        guard calls.isEmpty else { return .violation("calls completed but terminal reason was \(terminal.rawValue)") }
        state.assistantText = text
        return .completed(stop: terminal)
    }

    private func settle(
        calls: [ToolCall],
        request: RunRequest,
        state: inout LoopState,
        allowParallel: Bool
    ) async throws {
        let batchID = BatchID("\(request.runID.rawValue)-batch\(state.steps)")
        let callEntry = ContextEntry(id: EntryID("call-\(batchID.rawValue)"), segment: .history, role: .assistant, payload: .toolCall(requests: calls), unit: batchID.rawValue)
        try await record(callEntry, run: request.runID, into: request.sessionID)

        let outcomes = try await ToolBatchRunner.settle(
            calls: calls,
            registry: toolRegistry,
            executor: executor,
            allowParallel: allowParallel
        )
        let resultEntry = ContextEntry(id: EntryID("result-\(batchID.rawValue)"), segment: .history, role: .tool, payload: .toolResult(outcomes: outcomes), unit: batchID.rawValue)

        let marker = await log.beginMarker()
        do {
            try await log.append(.batchSettled(request.runID, batchID, outcomes))
            try await log.append(.entryRecorded(request.runID, resultEntry))
            try await log.append(.batchConsumed(request.runID, batchID))
        } catch {
            try? await log.rollBack(to: marker)
            throw error
        }
        await store.append(resultEntry, to: request.sessionID)

        state.toolOutcomeCount += outcomes.count
        state.lastObservation = outcomes.last?.content
    }

    private func record(_ entry: ContextEntry, run: RunID, into sessionID: SessionID) async throws {
        try await log.append(.entryRecorded(run, entry))
        await store.append(entry, to: sessionID)
    }

    /// Terminal record first; memory only moves once the write succeeded. A failed write leaves the
    /// run non-terminal so a later attempt can still own it (LOOP-002, STORE-001).
    private func commit(
        _ request: RunRequest,
        outcome: (RunStatus, TerminalCause, String?)
    ) async -> (status: RunStatus, cause: TerminalCause, detail: String?, committed: Bool) {
        do {
            _ = try await runs.terminalize(request.runID, status: outcome.0, cause: outcome.1, detail: outcome.2, via: log)
            return (outcome.0, outcome.1, outcome.2, true)
        } catch {
            let current = await runs.record(request.runID)
            return (current?.status ?? .failed, current?.cause ?? .runtimeFailure, current?.detail ?? "terminal record failed: \(error)", false)
        }
    }

    private static func merge(_ existing: ModelUsage?, _ incoming: ModelUsage) -> ModelUsage {
        guard var merged = existing else { return incoming }
        merged.inputTokens = merged.inputTokens ?? incoming.inputTokens
        merged.outputTokens = merged.outputTokens ?? incoming.outputTokens
        merged.reasoningTokens = merged.reasoningTokens ?? incoming.reasoningTokens
        merged.cacheReadTokens = merged.cacheReadTokens ?? incoming.cacheReadTokens
        merged.cacheWriteTokens = merged.cacheWriteTokens ?? incoming.cacheWriteTokens
        return merged
    }
}
