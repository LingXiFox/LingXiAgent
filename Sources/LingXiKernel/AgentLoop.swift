import Foundation

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
    /// False when the run never reached a durable terminal record (rejected, pre-flight failed, or
    /// the terminal write failed). Such a run stays non-terminal in memory for a later attempt.
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

private enum StepOutcome: Sendable {
    case completed(stop: ModelStopReason, text: String)
    case toolCalls([ToolCall], text: String)
    case failure(ModelFailure)
    case violation(String)
    case cancelled
    case deadlineExceeded
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

        // Pre-flight: a core without a provider is a configuration state, not a failed run. Report
        // guidance without touching the journal or the registry (QA-013).
        do {
            _ = try await router.resolve(model: request.model)
        } catch let error as ModelRouterError {
            return rejectedResult(request, cause: .runtimeFailure, detail: error.guidance)
        } catch {
            return rejectedResult(request, cause: .runtimeFailure, detail: "\(error)")
        }

        do {
            try await runs.create(id: request.runID, sessionID: request.sessionID, turnID: request.turnID)
        } catch let error as RunAdmissionError {
            switch error {
            case .sessionHasActiveRun(let session, let active):
                return rejectedResult(
                    request,
                    cause: .concurrentRunRejected,
                    detail: "session \(session.rawValue) already has an active run \(active.rawValue); only one active run per session is allowed"
                )
            case .duplicateRun:
                return rejectedResult(request, cause: .runtimeFailure, detail: "\(error)")
            }
        } catch {
            return rejectedResult(request, cause: .runtimeFailure, detail: "\(error)")
        }

        // The run exists in the journal only when this transaction committed. On failure the marker
        // is rolled back and the in-memory record discarded: no orphan terminal record is written.
        let userEntry = ContextEntry(
            id: EntryID("turn-\(request.turnID.rawValue)"),
            segment: .currentUser,
            role: .user,
            payload: .text(request.prompt)
        )
        let marker = await log.beginMarker()
        do {
            try await log.append(.runCreated(request.runID, request.sessionID, request.turnID))
            try await log.append(.runStarted(request.runID))
            try await log.append(.entryRecorded(request.runID, userEntry))
        } catch {
            let rolledBack = (try? await log.rollBack(to: marker)) != nil
            await runs.discard(request.runID)
            var detail = "run start failed: \(error)"
            if !rolledBack {
                detail += "; journal rollback failed, the journal needs repair"
            }
            return rejectedResult(request, cause: .runtimeFailure, detail: detail)
        }
        await store.append(userEntry, to: request.sessionID)

        let outcome: (RunStatus, TerminalCause, String?)
        do {
            try await runs.markRunning(request.runID)
            outcome = try await drive(request, policy: policy, state: &state)
        } catch let failure as ModelFailure {
            outcome = (.failed, .providerFailure, failure.message)
        } catch let error as ModelRouterError {
            outcome = (.failed, .runtimeFailure, error.guidance)
        } catch let error as TerminalizationError {
            outcome = (.failed, .runtimeFailure, "\(error)")
        } catch {
            let cancelled = error is CancellationError
            outcome = (cancelled ? .cancelled : .failed, cancelled ? .cancelledByUser : .runtimeFailure, cancelled ? nil : "\(error)")
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

    private func rejectedResult(_ request: RunRequest, cause: TerminalCause, detail: String) -> RunResult {
        RunResult(
            runID: request.runID,
            status: .failed,
            cause: cause,
            detail: detail,
            steps: 0,
            assistantText: "",
            toolOutcomes: 0,
            usage: nil,
            terminalCommitted: false
        )
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
            var remainingTimeout: Duration?
            if let timeout = policy.overallTimeout {
                let elapsed = clock.now() - origin
                if elapsed > timeout {
                    return (.deadlineExceeded, .deadlineExceeded, "elapsed=\(elapsed) limit=\(timeout)")
                }
                remainingTimeout = timeout - elapsed
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

            // The plan adds an eviction reference line and evicts entries; the final request must
            // still be a valid protocol request (CTX-018).
            do {
                try ContextRequestValidator.validate(plan.selected, placement: capabilities.toolResultPlacement)
            } catch {
                return (.failed, .streamProtocolViolation, "budget plan violates the request protocol: \(error)")
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
                remainingTimeout: remainingTimeout,
                state: &state
            )

            switch step {
            case .completed(let stop, let text):
                return try await finish(stop: stop, text: text, request: request, state: &state)
            case .toolCalls(let calls, let text):
                do {
                    try await settle(calls: calls, text: text, request: request, state: &state, allowParallel: capabilities.supportsParallelToolCalls)
                } catch let error as ToolBatchError {
                    return (.failed, .streamProtocolViolation, "\(error)")
                }
            case .failure(let failure):
                return (.failed, .providerFailure, failure.message)
            case .violation(let detail):
                return (.failed, .streamProtocolViolation, detail)
            case .cancelled:
                return (.cancelled, .cancelledByUser, nil)
            case .deadlineExceeded:
                return (.deadlineExceeded, .deadlineExceeded, "the provider stream did not settle within the overall timeout")
            }
        }
    }

    /// Terminal classification: an incomplete reply must never be reported as a normal completion
    /// (LOOP-022). The partially delivered assistant text is persisted for `maxTokens` so the next
    /// turn can see what the user saw.
    private func finish(
        stop: ModelStopReason,
        text: String,
        request: RunRequest,
        state: inout LoopState
    ) async throws -> (RunStatus, TerminalCause, String?) {
        switch stop {
        case .stop:
            state.assistantText = text
            if !text.isEmpty {
                try await record(Self.assistantEntry(text, run: request.runID), run: request.runID, into: request.sessionID)
            }
            return (.completed, text.isEmpty ? .completedWithEmptyText : .completedWithText, "stopReason=stop")
        case .maxTokens:
            state.assistantText = text
            if !text.isEmpty {
                try await record(Self.assistantEntry(text, run: request.runID), run: request.runID, into: request.sessionID)
            }
            return (.failed, .outputTruncated, "stopReason=maxTokens: the reply is incomplete because the output token limit was reached")
        case .contentFilter:
            return (.failed, .contentFiltered, "stopReason=contentFilter: the provider filtered the response")
        case .refusal:
            return (.failed, .refused, "stopReason=refusal: the model refused to answer")
        case .unknown:
            return (.failed, .streamProtocolViolation, "stopReason=unknown: the provider did not report a recognized stop reason")
        case .toolCalls:
            return (.failed, .streamProtocolViolation, "stopReason=toolCalls without completed calls")
        }
    }

    private func assemble(_ request: RunRequest) async throws -> [ContextEntry] {
        var entries: [ContextEntry] = [
            ContextEntry(id: "instructions", segment: .immutableInstructions, role: .system, payload: .text(instructions))
        ]
        entries.append(contentsOf: await store.entries(for: request.sessionID))
        return entries
    }

    /// Consumes the provider stream while racing it against cancellation and the overall deadline.
    /// A blocked stream must not outlive the run's bounds (LOOP-023). Policy: the first of
    /// {terminal event, cancellation, deadline} observed wins; a helper task keeps draining the
    /// stream after cancellation only to release the provider, and its late events are discarded.
    private func consumeStream(
        provider: any ModelProvider,
        modelRequest: ModelRequest,
        remainingTimeout: Duration?,
        state: inout LoopState
    ) async -> StepOutcome {
        let accumulator = StreamAccumulator()
        let race = StepRace()
        let clock = self.clock

        let consumer = Task {
            await Self.pump(provider: provider, request: modelRequest, accumulator: accumulator, race: race)
        }

        let watchdog: Task<Void, Never>?
        if let remainingTimeout {
            watchdog = Task {
                do {
                    try await clock.sleep(for: remainingTimeout)
                } catch {
                    return
                }
                race.resolve(.deadlineExceeded)
            }
        } else {
            watchdog = nil
        }

        if Task.isCancelled {
            race.resolve(.cancelled)
        }
        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            race.resolve(.cancelled)
        }

        consumer.cancel()
        watchdog?.cancel()

        let snapshot = accumulator.snapshot()
        if let usage = snapshot.usage {
            state.usage = addUsage(state.usage, usage)
        }
        return outcome
    }

    private static func pump(
        provider: any ModelProvider,
        request: ModelRequest,
        accumulator: StreamAccumulator,
        race: StepRace
    ) async {
        do {
            let stream = try await provider.stream(request)
            for try await event in stream {
                accumulator.apply(event)
                if let outcome = accumulator.outcome() {
                    race.resolve(outcome)
                    return
                }
            }
            if let outcome = accumulator.outcome() {
                race.resolve(outcome)
            } else {
                race.resolve(.violation("stream ended without a terminal event"))
            }
        } catch let failure as ModelFailure {
            race.resolve(.failure(failure))
        } catch {
            if Task.isCancelled {
                // The run itself was cancelled; by then the race normally already resolved
                // `.cancelled`, so this path is only a fallback.
                race.resolve(.cancelled)
            } else if error is CancellationError {
                // A provider that aborts its own stream with CancellationError must not be reported
                // as a user cancellation: it is a provider-side failure.
                race.resolve(.failure(ModelFailure(kind: .transport, message: "provider stream ended with CancellationError")))
            } else {
                race.resolve(.failure(ModelFailure(kind: .streamProtocol, message: "\(error)")))
            }
        }
    }

    private func settle(
        calls: [ToolCall],
        text: String,
        request: RunRequest,
        state: inout LoopState,
        allowParallel: Bool
    ) async throws {
        let batchID = BatchID("\(request.runID.rawValue)-batch\(state.steps)")
        let callEntry: ContextEntry
        if text.isEmpty {
            callEntry = ContextEntry(
                id: EntryID("call-\(batchID.rawValue)"),
                segment: .history,
                role: .assistant,
                payload: .toolCall(requests: calls),
                unit: batchID.rawValue
            )
        } else {
            callEntry = ContextEntry(
                id: EntryID("call-\(batchID.rawValue)"),
                segment: .history,
                role: .assistant,
                payload: .assistantMessage(text: text, requests: calls),
                unit: batchID.rawValue
            )
        }
        try await record(callEntry, run: request.runID, into: request.sessionID)

        // Durable intent before any side effect: recovery can distinguish "may have partially
        // executed" from "never started" (LOOP-025).
        let startMarker = await log.beginMarker()
        do {
            try await log.append(.batchStarted(request.runID, batchID, calls))
        } catch {
            try? await log.rollBack(to: startMarker)
            throw error
        }

        let outcomes = try await ToolBatchRunner.settle(
            calls: calls,
            registry: toolRegistry,
            executor: executor,
            allowParallel: allowParallel
        )
        let resultEntry = ContextEntry(
            id: EntryID("result-\(batchID.rawValue)"),
            segment: .history,
            role: .tool,
            payload: .toolResult(outcomes: outcomes),
            unit: batchID.rawValue
        )

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
        state.lastToolCall = calls.last.map { "\($0.toolName)(\($0.argumentsJSON))" } ?? state.lastToolCall
    }

    private func record(_ entry: ContextEntry, run: RunID, into sessionID: SessionID) async throws {
        let marker = await log.beginMarker()
        do {
            try await log.append(.entryRecorded(run, entry))
        } catch {
            try? await log.rollBack(to: marker)
            throw error
        }
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

    private static func assistantEntry(_ text: String, run: RunID) -> ContextEntry {
        ContextEntry(
            id: EntryID("assistant-\(run.rawValue)"),
            segment: .history,
            role: .assistant,
            payload: .text(text)
        )
    }
}

/// Sums usage field by field across steps. Absent (nil) is not zero: a field stays nil only when no
/// step reported it, and a reported zero is kept (CACHE-006, CACHE-007).
private func addUsage(_ existing: ModelUsage?, _ incoming: ModelUsage) -> ModelUsage? {
    // An all-nil event is "no usage telemetry", not a reported zero: keep absence distinguishable
    // from a provider that actually reported zeros (CACHE-006, CACHE-007).
    guard incoming.hasAnyReportedField else { return existing }
    guard let existing else { return incoming }
    return ModelUsage(
        inputTokens: addTokenCounts(existing.inputTokens, incoming.inputTokens),
        outputTokens: addTokenCounts(existing.outputTokens, incoming.outputTokens),
        reasoningTokens: addTokenCounts(existing.reasoningTokens, incoming.reasoningTokens),
        cacheReadTokens: addTokenCounts(existing.cacheReadTokens, incoming.cacheReadTokens),
        cacheWriteTokens: addTokenCounts(existing.cacheWriteTokens, incoming.cacheWriteTokens)
    )
}

private extension ModelUsage {
    var hasAnyReportedField: Bool {
        inputTokens != nil || outputTokens != nil || reasoningTokens != nil
            || cacheReadTokens != nil || cacheWriteTokens != nil
    }
}

private func addTokenCounts(_ lhs: Int?, _ rhs: Int?) -> Int? {
    switch (lhs, rhs) {
    case (nil, nil): nil
    case (let value?, nil): value
    case (nil, let value?): value
    case (let left?, let right?): left + right
    }
}

/// Locked accumulator for a provider stream. It survives the consumer task being abandoned, so the
/// loop can still report usage and text received before a cancellation/timeout won the race.
private final class StreamAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var calls: [ToolCall] = []
    private var started: Set<ToolCallID> = []
    private var usage: ModelUsage?
    private var terminal: ModelStopReason?
    private var failure: ModelFailure?
    private var violation: String?
    private var concluded = false

    func apply(_ event: ModelEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !concluded else { return }
        switch event {
        case .providerRequestID, .started, .heartbeat, .reasoningDelta:
            break
        case .textDelta(let fragment):
            text += fragment
        case .usage(let incoming):
            usage = addUsage(usage, incoming)
        case .toolCallStarted(let start):
            guard started.insert(start.callID).inserted else {
                violation = "duplicate toolCallStarted for \(start.callID.rawValue)"
                concluded = true
                return
            }
        case .toolCallDelta(let delta):
            guard started.contains(delta.callID) else {
                violation = "toolCallDelta for unstarted call \(delta.callID.rawValue)"
                concluded = true
                return
            }
        case .toolCallCompleted(let call):
            guard started.contains(call.callID) else {
                violation = "toolCallCompleted for unstarted call \(call.callID.rawValue)"
                concluded = true
                return
            }
            calls.append(call)
        case .completed(let reason):
            terminal = reason
            concluded = true
        case .failed(let modelFailure):
            failure = modelFailure
            concluded = true
        }
    }

    func outcome() -> StepOutcome? {
        lock.lock()
        defer { lock.unlock() }
        guard concluded else { return nil }
        if let violation { return .violation(violation) }
        if let failure { return .failure(failure) }
        guard let terminal else { return nil }
        if terminal == .toolCalls {
            guard !calls.isEmpty else { return .violation("terminal reason is toolCalls but no call completed") }
            return .toolCalls(calls, text: text)
        }
        guard calls.isEmpty else {
            return .violation("calls completed but terminal reason was \(terminal.rawValue)")
        }
        return .completed(stop: terminal, text: text)
    }

    func snapshot() -> (text: String, usage: ModelUsage?) {
        lock.lock()
        defer { lock.unlock() }
        return (text, usage)
    }
}

/// First resolution wins. A terminal event delivered by the provider resolves before the loop can
/// observe a concurrent cancellation, so a real provider failure is never rewritten as a cancel
/// (LOOP-006); a cancel or deadline observed first discards late stream events (LOOP-023).
private final class StepRace: @unchecked Sendable {
    private enum State {
        case open
        case waiting(CheckedContinuation<StepOutcome, Never>)
        case resolved(StepOutcome)
    }

    private let lock = NSLock()
    private var state: State = .open

    func resolve(_ outcome: StepOutcome) {
        lock.lock()
        switch state {
        case .open:
            state = .resolved(outcome)
            lock.unlock()
        case .waiting(let continuation):
            state = .resolved(outcome)
            lock.unlock()
            continuation.resume(returning: outcome)
        case .resolved:
            lock.unlock()
        }
    }

    func wait() async -> StepOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            switch state {
            case .open:
                state = .waiting(continuation)
                lock.unlock()
            case .resolved(let outcome):
                lock.unlock()
                continuation.resume(returning: outcome)
            case .waiting:
                lock.unlock()
                continuation.resume(returning: .cancelled)
            }
        }
    }
}
