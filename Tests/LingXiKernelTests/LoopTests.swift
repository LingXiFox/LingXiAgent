import Foundation
import LingXiKernel
import Testing

@Test("PROV-001 a stream that never delivers a terminal event is a protocol violation")
func PROV_001_streamWithoutTerminal() async {
    let provider = ScriptedProvider(scripts: [[.started, .textDelta("half")]])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: try! DurableEventLog(sink: MemorySink()))
    let result = await loop.run(runRequest("no-terminal"), policy: LoopPolicy())

    #expect(result.status == .failed)
    #expect(result.cause == .streamProtocolViolation)
}

@Test("PROV-001 completed calls must be paired with a toolCalls terminal reason")
func PROV_001_callsWithStopReason() async {
    let events: [ModelEvent] = [
        .started,
        .toolCallStarted(ToolCallStart(callID: "c1", toolName: "echo")),
        .toolCallCompleted(makeCall("c1")),
        .completed(.stop),
    ]
    let provider = ScriptedProvider(scripts: [events])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: try! DurableEventLog(sink: MemorySink()))
    let result = await loop.run(runRequest("calls-stop"), policy: LoopPolicy())

    #expect(result.cause == .streamProtocolViolation)
}

@Test("PROV-001 a toolCalls terminal reason with nothing completed is a violation")
func PROV_001_toolCallsReasonWithoutCalls() async {
    let provider = ScriptedProvider(scripts: [[.started, .completed(.toolCalls)]])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: try! DurableEventLog(sink: MemorySink()))
    let result = await loop.run(runRequest("empty-calls"), policy: LoopPolicy())

    #expect(result.cause == .streamProtocolViolation)
}

@Test("LOOP-013 repeated failures and empty output do not stop the loop")
func LOOP_013_keepsWorkingThroughIdenticalFailures() async throws {
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let executor = RecordingExecutor()
    executor.throwsSideEffect = true
    let batches = (1...3).map { toolBatch([makeCall("c\($0)")]) }
    let provider = ScriptedProvider(scripts: batches + [completed("done")])
    let loop = await makeLoop(provider: provider, executor: executor, registry: registry, log: try! DurableEventLog(sink: MemorySink()))

    let result = await loop.run(runRequest("grind"), policy: LoopPolicy())

    #expect(result.status == .completed)
    #expect(result.assistantText == "done")
    #expect(executor.executed.count == 3)
}

@Test("LOOP-012 the step limit reports the step count, last call and last observation")
func LOOP_012_stepLimitDetail() async throws {
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let provider = ScriptedProvider(scripts: (1...5).map { toolBatch([makeCall("c\($0)")]) })
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), registry: registry, log: try! DurableEventLog(sink: MemorySink()))

    let result = await loop.run(runRequest("limit"), policy: LoopPolicy(maxSteps: 2))

    #expect(result.status == .stepLimitReached)
    #expect(result.detail?.contains("steps=3") == true)
    #expect(result.detail?.contains("lastToolCall=echo({})") == true)
    #expect(result.detail?.contains("lastObservation=") == true)
}

@Test("LOOP-005 outcomes settle in the order the provider emitted them")
func LOOP_005_orderedSettle() async throws {
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let calls = [makeCall("slow"), makeCall("fast")]
    let provider = ScriptedProvider(scripts: [toolBatch(calls), completed("done")])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), registry: registry, log: try! DurableEventLog(sink: MemorySink()))

    let result = await loop.run(runRequest("order"), policy: LoopPolicy())

    #expect(result.status == .completed)
    let request = try #require(provider.request(at: 1))
    let outcomes = request.entries.compactMap(\.payload.toolOutcomes).flatMap { $0 }
    #expect(outcomes.map(\.callID.rawValue) == ["slow", "fast"])
}

@Test("LOOP-005 a duplicate call id rejects the entire batch")
func LOOP_005_duplicateCallIDRejectsBatch() async throws {
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let executor = RecordingExecutor()

    await #expect(throws: ToolBatchError.duplicateCallID("dup")) {
        _ = try await ToolBatchRunner.settle(
            calls: [makeCall("dup"), makeCall("dup")],
            registry: registry,
            executor: executor,
            allowParallel: true
        )
    }
    #expect(executor.executed.isEmpty)
}

@Test("LOOP-006 a provider failure is reported as the terminal cause, not rewritten as a cancel")
func LOOP_006_providerFailureSurvives() async throws {
    let provider = ScriptedProvider(scripts: [[.started, .failed(ModelFailure(kind: .rateLimited, message: "429 too many requests"))]])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: try DurableEventLog(sink: MemorySink()))
    let result = await loop.run(runRequest("failure"), policy: LoopPolicy())

    #expect(result.status == .failed)
    #expect(result.cause == .providerFailure)
    #expect(result.detail?.contains("429") == true)
    #expect(result.terminalCommitted)
}

@Test("LOOP-023 cancelling while the provider stream is blocked reports cancelled and never fabricates a failure")
func LOOP_023_cancelWhileStreamBlocked() async throws {
    let provider = BlockingStreamProvider(terminalEvents: [
        .failed(ModelFailure(kind: .rateLimited, message: "late 429")),
    ])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: try DurableEventLog(sink: MemorySink()))
    let request = runRequest("cancel-blocked")
    let task = Task { await loop.run(request, policy: LoopPolicy()) }

    #expect(await provider.arrival.wait())
    task.cancel()
    let result = await task.value

    #expect(result.status == .cancelled)
    #expect(result.cause == .cancelledByUser)
    #expect(result.detail == nil)
    #expect(result.terminalCommitted)
    // Release the stream so the helper task ends. The late failure must not change the outcome.
    provider.release.fire()
    #expect(result.cause == .cancelledByUser)
}

@Test("LOOP-023 a blocked provider stream is bounded by the overall timeout")
func LOOP_023_blockedStreamTimeout() async throws {
    let clock = ManualClock()
    let provider = BlockingStreamProvider(terminalEvents: [.textDelta("late"), .completed(.stop)])
    let loop = await makeLoop(
        provider: provider,
        executor: RecordingExecutor(),
        log: try DurableEventLog(sink: MemorySink()),
        clock: clock
    )
    let request = runRequest("blocked-timeout")
    let task = Task { await loop.run(request, policy: LoopPolicy(overallTimeout: .seconds(10))) }

    #expect(await provider.arrival.wait())
    // Wait until the watchdog has registered its deadline, otherwise advancing time could land
    // before registration and the test would race the scheduler.
    #expect(await clock.sleepStarted.wait())
    clock.advance(.seconds(11))

    let result = await task.value
    #expect(result.status == .deadlineExceeded)
    #expect(result.cause == .deadlineExceeded)
    #expect(result.detail?.contains("overall timeout") == true)
    #expect(result.terminalCommitted)
    provider.release.fire()
}

@Test("LOOP-007 cancelling after a batch settled does not re-run the settled tool")
func LOOP_007_cancelAfterSettled() async throws {
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let executor = GatingExecutor()
    let provider = ScriptedProvider(scripts: [toolBatch([makeCall("c1")]), completed("never asked")])
    let loop = await makeLoop(provider: provider, executor: executor, registry: registry, log: try DurableEventLog(sink: MemorySink()))
    let request = runRequest("late-cancel")

    let task = Task { await loop.run(request, policy: LoopPolicy()) }
    #expect(await executor.arrivalGate.wait())
    task.cancel()
    executor.proceedGate.fire()
    let result = await task.value

    #expect(result.status == .cancelled)
    #expect(result.cause == .cancelledByUser)
    #expect(executor.executedCount == 1)
    #expect(provider.requestCount == 1)
}

@Test("LOOP-022 truncated, filtered and refused replies are not reported as normal completions")
func LOOP_022_incompleteOutcomes() async throws {
    let truncated = await makeLoop(
        provider: ScriptedProvider(scripts: [[.started, .textDelta("half"), .completed(.maxTokens)]]),
        executor: RecordingExecutor(),
        log: try DurableEventLog(sink: MemorySink())
    )
    let truncatedResult = await truncated.run(runRequest("truncated"), policy: LoopPolicy())
    #expect(truncatedResult.status == .failed)
    #expect(truncatedResult.cause == .outputTruncated)
    #expect(truncatedResult.assistantText == "half")
    #expect(truncatedResult.terminalCommitted)

    let filtered = await makeLoop(
        provider: ScriptedProvider(scripts: [[.started, .completed(.contentFilter)]]),
        executor: RecordingExecutor(),
        log: try DurableEventLog(sink: MemorySink())
    )
    let filteredResult = await filtered.run(runRequest("filtered"), policy: LoopPolicy())
    #expect(filteredResult.status == .failed)
    #expect(filteredResult.cause == .contentFiltered)

    let refused = await makeLoop(
        provider: ScriptedProvider(scripts: [[.started, .completed(.refusal)]]),
        executor: RecordingExecutor(),
        log: try DurableEventLog(sink: MemorySink())
    )
    let refusedResult = await refused.run(runRequest("refused"), policy: LoopPolicy())
    #expect(refusedResult.status == .failed)
    #expect(refusedResult.cause == .refused)

    let normal = await makeLoop(
        provider: ScriptedProvider(scripts: [completed("done")]),
        executor: RecordingExecutor(),
        log: try DurableEventLog(sink: MemorySink())
    )
    let normalResult = await normal.run(runRequest("normal"), policy: LoopPolicy())
    #expect(normalResult.status == .completed)
    #expect(normalResult.cause == .completedWithText)
}

@Test("CACHE-007 usage is summed across steps and absence stays distinguishable from zero")
func CACHE_007_usageAccumulatesAcrossSteps() async throws {
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let firstStep: [ModelEvent] = [
        .started,
        .toolCallStarted(ToolCallStart(callID: "c1", toolName: "echo")),
        .toolCallCompleted(makeCall("c1")),
        .usage(ModelUsage(inputTokens: 100, outputTokens: 5, cacheReadTokens: 0)),
        .completed(.toolCalls),
    ]
    let secondStep: [ModelEvent] = [
        .started,
        .textDelta("done"),
        .usage(ModelUsage(inputTokens: 20, outputTokens: 7)),
        .completed(.stop),
    ]
    let loop = await makeLoop(
        provider: ScriptedProvider(scripts: [firstStep, secondStep]),
        executor: RecordingExecutor(),
        registry: registry,
        log: try DurableEventLog(sink: MemorySink())
    )

    let result = await loop.run(runRequest("usage"), policy: LoopPolicy())
    #expect(result.status == .completed)
    let usage = try #require(result.usage)
    #expect(usage.inputTokens == 120)
    #expect(usage.outputTokens == 12)
    #expect(usage.cacheReadTokens == 0, "an explicitly reported zero must survive aggregation")
    #expect(usage.reasoningTokens == nil, "a field nobody reported stays absent")
    #expect(usage.cacheWriteTokens == nil)
}

@Test("CACHE-007 an all-nil usage event is no telemetry, not a reported zero")
func CACHE_007_allNilUsageStaysAbsent() async throws {
    let loop = await makeLoop(
        provider: ScriptedProvider(scripts: [[.started, .textDelta("done"), .usage(ModelUsage()), .completed(.stop)]]),
        executor: RecordingExecutor(),
        log: try DurableEventLog(sink: MemorySink())
    )

    let result = await loop.run(runRequest("usage-empty"), policy: LoopPolicy())
    #expect(result.status == .completed)
    #expect(result.usage == nil)
}

@Test("LOOP-024 three real turns keep every prior user and assistant message")
func LOOP_024_threeTurnsKeepHistory() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let store = SessionStore()
    let provider = ScriptedProvider(scripts: [completed("reply-1"), completed("reply-2"), completed("reply-3")])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: log, store: store)
    let session = SessionID("session-multi")

    for turn in 1...3 {
        let request = RunRequest(
            sessionID: session,
            turnID: TurnID("turn-\(turn)"),
            runID: RunID("run-multi-\(turn)"),
            executionID: ExecutionID("exec-\(turn)"),
            model: "test-model",
            prompt: "prompt-\(turn)"
        )
        let result = await loop.run(request, policy: LoopPolicy())
        #expect(result.status == .completed)
        #expect(result.cause == .completedWithText)
    }

    let entries = await store.entries(for: session)
    #expect(
        entries.map(\.id.rawValue)
            == ["turn-turn-1", "assistant-run-multi-1", "turn-turn-2", "assistant-run-multi-2", "turn-turn-3", "assistant-run-multi-3"]
    )
    #expect(entries.map(\.segment) == [.history, .history, .history, .history, .currentUser, .history])

    let thirdRequest = try #require(provider.request(at: 2))
    let visible = thirdRequest.entries.filter { !$0.segment.isPrivileged }.map(\.renderedText)
    #expect(visible.contains("prompt-1"))
    #expect(visible.contains("reply-1"))
    #expect(visible.contains("prompt-2"))
    #expect(visible.contains("reply-2"))
    #expect(visible.contains("prompt-3"))
    #expect(thirdRequest.entries.filter { $0.segment == .currentUser }.count == 1)
    #expect(thirdRequest.entries.filter { $0.segment.isMandatory }.count == 2)
}

@Test("LOOP-024 a tool round persists assistant text and calls as one assistant entry")
func LOOP_024_toolRoundKeepsAssistantText() async throws {
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let stepWithText: [ModelEvent] = [
        .started,
        .textDelta("thinking"),
        .toolCallStarted(ToolCallStart(callID: "c1", toolName: "echo")),
        .toolCallCompleted(makeCall("c1")),
        .completed(.toolCalls),
    ]
    let provider = ScriptedProvider(scripts: [stepWithText, completed("final")])
    let store = SessionStore()
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), registry: registry, log: try DurableEventLog(sink: MemorySink()), store: store)

    let result = await loop.run(runRequest("tool-text"), policy: LoopPolicy())
    #expect(result.status == .completed)
    #expect(result.assistantText == "final")

    let entries = await store.entries(for: runRequest("tool-text").sessionID)
    #expect(entries.count == 4)
    guard case .assistantMessage(let text, let requests) = entries[1].payload else {
        Issue.record("the tool-call entry must keep the assistant text, got \(entries[1].payload)")
        return
    }
    #expect(text == "thinking")
    #expect(requests.map(\.callID.rawValue) == ["c1"])
    #expect(entries[1].unit == "run-tool-text-batch1")
    #expect(entries[2].payload.toolOutcomes.map(\.callID.rawValue) == ["c1"])
    #expect(entries[3].renderedText == "final")

    // The next model request (a later step in the same run) already contained both parts.
    let secondStep = try #require(provider.request(at: 1))
    #expect(secondStep.entries.contains { $0.renderedText.contains("thinking") })
    #expect(secondStep.entries.contains { !$0.payload.toolOutcomes.isEmpty })
}

@Test("LOOP-021 a second active run on the same session is rejected without touching the journal")
func LOOP_021_secondRunOnActiveSessionRejected() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let provider = BlockingStreamProvider(terminalEvents: [.textDelta("late"), .completed(.stop)])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: log)
    let session = SessionID("session-concurrent")

    let first = Task {
        await loop.run(
            RunRequest(sessionID: session, turnID: "turn-1", runID: "run-first", executionID: "exec-1", model: "test-model", prompt: "one"),
            policy: LoopPolicy()
        )
    }
    #expect(await provider.arrival.wait())
    let baselineRecordCount = await log.recordCount

    let rejected = await loop.run(
        RunRequest(sessionID: session, turnID: "turn-2", runID: "run-second", executionID: "exec-2", model: "test-model", prompt: "two"),
        policy: LoopPolicy()
    )

    #expect(rejected.status == .failed)
    #expect(rejected.cause == .concurrentRunRejected)
    #expect(!rejected.terminalCommitted)
    #expect(rejected.detail?.contains("active run") == true)
    #expect(await log.recordCount == baselineRecordCount)

    provider.release.fire()
    let firstResult = await first.value
    #expect(firstResult.status == .completed)
}

@Test("LOOP-021 different sessions may run concurrently")
func LOOP_021_differentSessionsMayRunConcurrently() async throws {
    let provider = BlockingStreamProvider(terminalEvents: [.textDelta("late"), .completed(.stop)])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: try DurableEventLog(sink: MemorySink()))

    let first = Task {
        await loop.run(
            RunRequest(sessionID: "session-a", turnID: "turn-a", runID: "run-a", executionID: "exec-a", model: "test-model", prompt: "a"),
            policy: LoopPolicy()
        )
    }
    let second = Task {
        await loop.run(
            RunRequest(sessionID: "session-b", turnID: "turn-b", runID: "run-b", executionID: "exec-b", model: "test-model", prompt: "b"),
            policy: LoopPolicy()
        )
    }
    #expect(await provider.arrival.wait())
    // Both streams are the same blocking provider; one stream() call per run.
    provider.release.fire()
    let firstResult = await first.value
    let secondResult = await second.value
    #expect(firstResult.status == .completed)
    #expect(secondResult.status == .completed)
    #expect(provider.requestCount == 2)
}

@Test("CTX-018 a long conversation keeps trimming history and keeps every request valid")
func CTX_018_longConversationTrimsHistory() async throws {
    let store = SessionStore()
    let provider = ScriptedProvider(scripts: (1...6).map { _ in completed(String(repeating: "r", count: 200)) })
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: try DurableEventLog(sink: MemorySink()), store: store)
    let session = SessionID("session-budget")

    for turn in 1...6 {
        let request = RunRequest(
            sessionID: session,
            turnID: TurnID("turn-\(turn)"),
            runID: RunID("run-budget-\(turn)"),
            executionID: ExecutionID("exec-\(turn)"),
            model: "test-model",
            prompt: String(repeating: "p", count: 200)
        )
        let result = await loop.run(request, policy: LoopPolicy(preferredTokens: 120, hardTokens: 200))
        #expect(result.status == .completed)
        #expect(result.cause == .completedWithText)
    }

    let lastRequest = try #require(provider.request(at: 5))
    #expect(lastRequest.entries.first?.segment == .immutableInstructions)
    #expect(lastRequest.entries.filter { $0.segment == .currentUser }.count == 1)
    #expect(lastRequest.entries.contains { $0.segment == .derivedPage })
    let reference = try #require(lastRequest.entries.first { $0.segment == .derivedPage })
    #expect(reference.role != .system)
    #expect(reference.renderedText.contains("Evicted for budget"))
    let estimated = lastRequest.entries.reduce(0) { $0 + TokenEstimator().estimate($1) }
    #expect(estimated <= 200)
    #expect(await store.entries(for: session).count == 12)
}

@Test("LOOP-012 the hard budget limit stops the run instead of silently truncating the request")
func LOOP_012_budgetExceeded() async throws {
    let provider = ScriptedProvider(scripts: [completed("x")])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: try DurableEventLog(sink: MemorySink()))

    let result = await loop.run(runRequest("budget"), policy: LoopPolicy(preferredTokens: 5, hardTokens: 10))

    #expect(result.status == .budgetExceeded)
    #expect(result.cause == .budgetExceeded)
    #expect(result.detail?.contains("mandatoryFloorExceedsHardLimit") == true)
    #expect(provider.requestCount == 0)
    #expect(result.terminalCommitted)
}

@Test("QA-013 a model no active provider offers is guidance, not a journal-polluting run")
func QA_013_modelNotOfferedGuidance() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let runs = RunRegistry()
    let store = SessionStore()
    let router = ModelRouter()
    try? await router.register(provider: ScriptedProvider(scripts: []), id: "test.provider", models: ["offered"])
    let loop = AgentLoop(
        router: router,
        toolRegistry: ToolRegistry(),
        executor: RecordingExecutor(),
        log: log,
        runs: runs,
        store: store,
        instructions: "instructions"
    )
    let request = RunRequest(
        sessionID: "session-not-offered",
        turnID: "turn-not-offered",
        runID: "run-not-offered",
        executionID: "exec-not-offered",
        model: "missing-model",
        prompt: "hello"
    )

    let result = await loop.run(request, policy: LoopPolicy())

    #expect(result.status == .failed)
    #expect(result.cause == .runtimeFailure)
    #expect(result.detail?.contains("No active provider offers model missing-model") == true)
    #expect(!result.terminalCommitted)
    #expect(await log.recordCount == 0)
    #expect(await runs.record(request.runID) == nil)
    #expect(await store.sessionIDs().isEmpty)
}

@Test("LOOP-021 reusing a run id that already reached a terminal state is rejected without journal writes")
func LOOP_021_duplicateRunIDRejected() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let loop = await makeLoop(
        provider: ScriptedProvider(scripts: [completed("one"), completed("two")]),
        executor: RecordingExecutor(),
        log: log
    )
    let request = runRequest("dup-run")

    let first = await loop.run(request, policy: LoopPolicy())
    #expect(first.status == .completed)
    let countAfterFirst = await log.recordCount

    let second = await loop.run(request, policy: LoopPolicy())
    #expect(second.status == .failed)
    #expect(second.cause == .runtimeFailure)
    #expect(second.detail?.contains("duplicateRun") == true)
    #expect(!second.terminalCommitted)
    #expect(await log.recordCount == countAfterFirst)
    let terminals = try await log.events().filter { if case .runTerminal(RunID("run-dup-run"), _, _) = $0 { true } else { false } }
    #expect(terminals.count == 1)
}

@Test("DEADLINE a step boundary past the overall deadline stops before the next model request")
func DEADLINE_stepBoundaryCheck() async throws {
    let clock = ManualClock()
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let executor = RecordingExecutor()
    executor.onExecute = { _ in clock.advance(.seconds(30)) }
    let provider = ScriptedProvider(scripts: [toolBatch([makeCall("c1")]), completed("never asked")])
    let loop = await makeLoop(
        provider: provider,
        executor: executor,
        registry: registry,
        log: try DurableEventLog(sink: MemorySink()),
        clock: clock
    )

    let result = await loop.run(runRequest("step-deadline"), policy: LoopPolicy(overallTimeout: .seconds(10)))

    #expect(result.status == .deadlineExceeded)
    #expect(result.cause == .deadlineExceeded)
    #expect(result.detail?.contains("elapsed=") == true)
    #expect(result.terminalCommitted)
    #expect(provider.requestCount == 1)
}

@Test("LOOP-006 a provider aborting its own stream is a provider failure, not a user cancel")
func LOOP_006_providerCancellationIsProviderFailure() async throws {
    let provider = ScriptedProvider(scripts: [], preStreamError: CancellationError())
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: try DurableEventLog(sink: MemorySink()))

    let result = await loop.run(runRequest("provider-abort"), policy: LoopPolicy())

    #expect(result.status == .failed)
    #expect(result.cause == .providerFailure)
    #expect(result.detail?.contains("CancellationError") == true)
    #expect(result.terminalCommitted)
}

@Test("LOOP-005 a duplicate tool call id never poisons the session history")
func LOOP_005_duplicateCallIDDoesNotPoisonHistory() async throws {
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let store = SessionStore()
    let log = try DurableEventLog(sink: MemorySink())
    let duplicated: [ModelEvent] = [
        .started,
        .toolCallStarted(ToolCallStart(callID: "dup", toolName: "echo")),
        .toolCallCompleted(makeCall("dup")),
        .toolCallCompleted(makeCall("dup")),
        .completed(.toolCalls),
    ]
    let provider = ScriptedProvider(scripts: [duplicated, completed("recovered")])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), registry: registry, log: log, store: store)
    let session = SessionID("session-duplicate-call")

    let first = RunRequest(
        sessionID: session, turnID: "turn-1", runID: "run-dup-1",
        executionID: "exec-1", model: "test-model", prompt: "first"
    )
    let firstResult = await loop.run(first, policy: LoopPolicy())
    #expect(firstResult.status == .failed)
    #expect(firstResult.cause == .streamProtocolViolation)

    // The invalid batch must not be persisted: only the user entry remains.
    let entriesAfterFirst = await store.entries(for: session)
    #expect(entriesAfterFirst.count == 1)
    #expect(entriesAfterFirst.allSatisfy { $0.payload.toolCalls.isEmpty })

    // The session is still usable for the next turn.
    let second = RunRequest(
        sessionID: session, turnID: "turn-2", runID: "run-dup-2",
        executionID: "exec-2", model: "test-model", prompt: "second"
    )
    let secondResult = await loop.run(second, policy: LoopPolicy())
    #expect(secondResult.status == .completed)
    #expect(secondResult.assistantText == "recovered")
}

@Test("LOOP-025 an in-process dangling tool batch is healed before the next request")
func LOOP_025_danglingBatchHealedInProcess() async throws {
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let log = try DurableEventLog(sink: MemorySink())
    let store = SessionStore()
    let session = SessionID("session-heal")
    let batchID = BatchID("ghost-run-batch1")
    let call = makeCall("c1")
    // Simulate a run that persisted its call entry and durable dispatch intent but died before the
    // result (the same crash image KernelRecovery heals on restart).
    let callEntry = ContextEntry(
        id: EntryID("call-ghost-run-batch1"),
        segment: .history,
        role: .assistant,
        payload: .toolCall(requests: [call]),
        unit: batchID.rawValue
    )
    await store.append(callEntry, to: session)
    try await log.append(.batchStarted(RunID("ghost-run"), batchID, [call]))

    let provider = ScriptedProvider(scripts: [completed("recovered")])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), registry: registry, log: log, store: store)
    let request = RunRequest(
        sessionID: session, turnID: "turn-heal", runID: "run-heal",
        executionID: "exec-heal", model: "test-model", prompt: "next"
    )

    let result = await loop.run(request, policy: LoopPolicy())
    #expect(result.status == .completed)

    let entries = await store.entries(for: session)
    let healedResult = try #require(entries.first { $0.unit == batchID.rawValue && !$0.payload.toolOutcomes.isEmpty })
    #expect(healedResult.role == .tool)
    #expect(healedResult.payload.toolOutcomes.first?.isError == true)
    #expect(healedResult.payload.toolOutcomes.first?.content.contains("executionStateUnknown") == true)
    try ContextRequestValidator.validate(
        [ContextEntry(id: "instructions", segment: .immutableInstructions, role: .system, payload: .text("sys"))] + entries,
        placement: .immediatelyAfterCall
    )
    // The request that reached the provider already contained the healed pairing.
    let sent = try #require(provider.request(at: 0))
    #expect(sent.entries.contains { $0.unit == batchID.rawValue && !$0.payload.toolOutcomes.isEmpty })
}

@Test("LOOP-026 a completed run releases the provider execution state")
func LOOP_026_endExecutionAfterCompletedRun() async throws {
    let provider = ScriptedProvider(scripts: [completed("done")])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: try DurableEventLog(sink: MemorySink()))
    let request = runRequest("end-ok")

    let result = await loop.run(request, policy: LoopPolicy())

    #expect(result.status == .completed)
    #expect(provider.endedExecutions == [request.executionID])
}

@Test("LOOP-026 a provider failure releases the execution state with the cause intact")
func LOOP_026_endExecutionAfterProviderFailure() async throws {
    let provider = ScriptedProvider(scripts: [[.started, .failed(ModelFailure(kind: .rateLimited, message: "429"))]])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: try DurableEventLog(sink: MemorySink()))
    let request = runRequest("end-failure")

    let result = await loop.run(request, policy: LoopPolicy())

    #expect(result.status == .failed)
    #expect(result.cause == .providerFailure)
    #expect(provider.endedExecutions == [request.executionID])
}

@Test("LOOP-026 cancelling a blocked stream releases the execution state")
func LOOP_026_endExecutionAfterCancellation() async throws {
    let provider = BlockingStreamProvider(terminalEvents: [.failed(ModelFailure(kind: .transport, message: "late"))])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: try DurableEventLog(sink: MemorySink()))
    let request = runRequest("end-cancel")
    let task = Task { await loop.run(request, policy: LoopPolicy()) }

    #expect(await provider.arrival.wait())
    task.cancel()
    let result = await task.value
    provider.release.fire()

    #expect(result.status == .cancelled)
    #expect(result.cause == .cancelledByUser)
    #expect(provider.endedExecutions == [request.executionID])
}

@Test("LOOP-026 an overall deadline releases the execution state")
func LOOP_026_endExecutionAfterDeadline() async throws {
    let clock = ManualClock()
    let provider = BlockingStreamProvider(terminalEvents: [.completed(.stop)])
    let loop = await makeLoop(
        provider: provider, executor: RecordingExecutor(),
        log: try DurableEventLog(sink: MemorySink()), clock: clock
    )
    let request = runRequest("end-deadline")
    let task = Task { await loop.run(request, policy: LoopPolicy(overallTimeout: .seconds(10))) }

    #expect(await provider.arrival.wait())
    #expect(await clock.sleepStarted.wait())
    clock.advance(.seconds(11))
    let result = await task.value
    provider.release.fire()

    #expect(result.status == .deadlineExceeded)
    #expect(provider.endedExecutions == [request.executionID])
}

@Test("LOOP-026 a multi-step run releases its execution once, not once per step")
func LOOP_026_endExecutionFiresOnceAcrossSteps() async throws {
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let provider = ScriptedProvider(scripts: [toolBatch([makeCall("c1")]), toolBatch([makeCall("c2")]), completed("done")])
    let loop = await makeLoop(
        provider: provider, executor: RecordingExecutor(), registry: registry,
        log: try DurableEventLog(sink: MemorySink())
    )
    let request = runRequest("end-multi-step")

    let result = await loop.run(request, policy: LoopPolicy())

    #expect(result.status == .completed)
    #expect(result.steps == 3)
    #expect(provider.requestCount == 3)
    // One run is one execution: three model requests, a single release.
    #expect(provider.endedExecutions == [request.executionID])
}

@Test("LOOP-026 a run rejected at admission never started an execution to release")
func LOOP_026_noEndExecutionWhenRunNeverStarted() async throws {
    let sink = MemorySink()
    let log = try DurableEventLog(sink: sink)
    let provider = ScriptedProvider(scripts: [completed("one"), completed("two")])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: log)
    let request = runRequest("end-rejected")

    #expect((await loop.run(request, policy: LoopPolicy())).status == .completed)
    let endedBefore = provider.endedExecutions.count
    let recordsBefore = sink.lineCount

    let second = await loop.run(request, policy: LoopPolicy())
    #expect(second.status == .failed)
    #expect(second.detail?.contains("duplicateRun") == true)
    #expect(provider.endedExecutions.count == endedBefore)
    #expect(sink.lineCount == recordsBefore)
}

@Test("LOOP-027 reusing a recorded turn id is rejected without journal writes")
func LOOP_027_duplicateTurnIDRejectedWithoutJournalWrites() async throws {
    let sink = MemorySink()
    let log = try DurableEventLog(sink: sink)
    let runs = RunRegistry()
    let store = SessionStore()
    let provider = ScriptedProvider(scripts: [completed("first"), completed("later")])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: log, runs: runs, store: store)
    let session = SessionID("session-dup-turn")

    let first = RunRequest(
        sessionID: session, turnID: "turn-1", runID: "run-dup-turn-1",
        executionID: "exec-1", model: "test-model", prompt: "one"
    )
    #expect((await loop.run(first, policy: LoopPolicy())).status == .completed)
    let recordsAfterFirst = sink.lineCount

    // Same session, same turn id, a fresh run id: admission would allow it, the entry id must not.
    let second = RunRequest(
        sessionID: session, turnID: "turn-1", runID: "run-dup-turn-2",
        executionID: "exec-2", model: "test-model", prompt: "one again"
    )
    let result = await loop.run(second, policy: LoopPolicy())

    #expect(result.status == .failed)
    #expect(result.cause == .runtimeFailure)
    #expect(result.detail?.contains("already recorded") == true)
    #expect(!result.terminalCommitted)
    // Rejected before any durable write and before the provider was asked for anything.
    #expect(sink.lineCount == recordsAfterFirst)
    #expect(provider.requestCount == 1)
    #expect(await runs.record(second.runID) == nil)
    #expect(await store.entries(for: session).filter { $0.id == EntryID("turn-turn-1") }.count == 1)
    #expect(await runs.openRunIDs.isEmpty)

    // The session stays usable: a new turn id runs normally.
    let third = RunRequest(
        sessionID: session, turnID: "turn-2", runID: "run-dup-turn-3",
        executionID: "exec-3", model: "test-model", prompt: "two"
    )
    let thirdResult = await loop.run(third, policy: LoopPolicy())
    #expect(thirdResult.status == .completed)
    #expect(await store.entries(for: session).filter { $0.segment.isMandatory }.map(\.id.rawValue) == ["turn-turn-2"])
}
