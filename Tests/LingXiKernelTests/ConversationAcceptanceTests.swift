import Foundation
import LingXiKernel
import Testing

// Conversation / loop acceptance tests for Phase 1.1 (contract §4/§5).
//
// Every history assertion is derived from the REAL `AgentLoop` running over one shared
// `SessionStore` + `DurableEventLog` for several turns: the expected history is read back from the
// `ModelRequest` values the provider actually received, never injected as hand-built `ContextEntry`
// arrays. Time-dependent cases use the injected `ManualClock`/`Gate` fixtures only (QA-002); there is
// no fixed `Task.sleep` in this file.
//
// All helpers are `private` and prefixed with `conv` to keep the test-target namespace shared with
// the other acceptance file clean.

// MARK: - Helpers

private func convRequest(
    session: String,
    turn: String,
    run: String,
    prompt: String,
    model: ModelID = "test-model"
) -> RunRequest {
    RunRequest(
        sessionID: SessionID(session),
        turnID: TurnID(turn),
        runID: RunID(run),
        executionID: ExecutionID("exec-\(run)"),
        model: model,
        prompt: prompt
    )
}

/// Provider-agnostic loop fixture: the stock `makeLoop` only takes a `ScriptedProvider`, and the
/// acceptance tests also need `BlockingStreamProvider` and router setups with several providers.
private func convMakeLoop(
    provider: any ModelProvider,
    model: ModelID = "test-model",
    executor: any ToolExecutor = RecordingExecutor(),
    registry: ToolRegistry = ToolRegistry(),
    log: DurableEventLog,
    runs: RunRegistry = RunRegistry(),
    store: SessionStore = SessionStore(),
    clock: any MonotonicClock = ManualClock(),
    instructions: String = "instructions"
) async -> AgentLoop {
    let router = ModelRouter()
    await router.register(provider: provider, id: ProviderID("test.provider"), models: [model])
    return AgentLoop(
        router: router,
        toolRegistry: registry,
        executor: executor,
        log: log,
        runs: runs,
        store: store,
        clock: clock,
        instructions: instructions
    )
}

private func convEntries(_ log: DurableEventLog) async throws -> [ContextEntry] {
    let events = try await log.events()
    return events.compactMap { event -> ContextEntry? in
        guard case .entryRecorded(_, let entry) = event else { return nil }
        return entry
    }
}

private func convTerminals(_ log: DurableEventLog) async throws -> [(status: RunStatus, cause: TerminalCause)] {
    let events = try await log.events()
    return events.compactMap { event -> (status: RunStatus, cause: TerminalCause)? in
        guard case .runTerminal(_, let status, let cause) = event else { return nil }
        return (status: status, cause: cause)
    }
}

private func convAssistantTextEntries(_ log: DurableEventLog) async throws -> [ContextEntry] {
    let entries = try await convEntries(log)
    return entries.filter { entry in
        guard entry.role == .assistant else { return false }
        if case .text = entry.payload { return true }
        return false
    }
}

private func convTexts(_ entries: [ContextEntry]) -> [String] {
    entries.map(\.renderedText)
}

private func convIsNil(_ usage: ModelUsage?) -> Bool {
    if case .none = usage { return true }
    return false
}

private struct ConvScriptedRun {
    let result: RunResult
    let log: DurableEventLog
    let store: SessionStore
    let provider: ScriptedProvider
}

/// Runs one real loop over a single scripted stream, with fresh journal/registry/store.
private func convRunOneScript(
    _ events: [ModelEvent],
    prompt: String = "prompt",
    policy: LoopPolicy = LoopPolicy()
) async throws -> ConvScriptedRun {
    let log = try DurableEventLog(sink: MemorySink())
    let store = SessionStore()
    let provider = ScriptedProvider(scripts: [events])
    let loop = await convMakeLoop(provider: provider, log: log, store: store)
    let result = await loop.run(
        convRequest(session: "session-scripted", turn: "turn", run: "run-one", prompt: prompt),
        policy: policy
    )
    return ConvScriptedRun(result: result, log: log, store: store, provider: provider)
}

private struct ConvConversation {
    let prompts: [String]
    let answers: [String]
    let provider: ScriptedProvider
    let log: DurableEventLog
    let store: SessionStore
    let runs: RunRegistry
    let results: [RunResult]
}

/// Runs `turns` consecutive REAL turns on one session: each prompt and reply is exactly 200 bytes so
/// the token arithmetic driven by `TokenEstimator` (200/4 + 4 = 54 tokens per entry) is predictable.
private func convRunConversation(
    turns: Int,
    session: String,
    lastPolicy: LoopPolicy = LoopPolicy()
) async throws -> ConvConversation {
    let prompts = (1...turns).map { "prompt-\($0)-" + String(repeating: "p", count: 191) }
    let answers = (1...turns).map { "answer-\($0)-" + String(repeating: "a", count: 191) }
    let provider = ScriptedProvider(scripts: answers.map { completed($0) })
    let log = try DurableEventLog(sink: MemorySink())
    let store = SessionStore()
    let runs = RunRegistry()
    let loop = await convMakeLoop(provider: provider, log: log, runs: runs, store: store)

    var results: [RunResult] = []
    for index in 0..<turns {
        let policy = index == turns - 1 ? lastPolicy : LoopPolicy()
        let result = await loop.run(
            convRequest(session: session, turn: "t\(index + 1)", run: "r\(index + 1)", prompt: prompts[index]),
            policy: policy
        )
        results.append(result)
    }
    return ConvConversation(
        prompts: prompts,
        answers: answers,
        provider: provider,
        log: log,
        store: store,
        runs: runs,
        results: results
    )
}

// MARK: - LOOP-021: one active run per session, different sessions are independent

@Test("LOOP-021 a second run on a session with an active run is rejected without journal pollution", .timeLimit(.minutes(1)))
func LOOP_021_secondRunRejectedWithoutJournalWrites() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let runs = RunRegistry()
    let store = SessionStore()
    let provider = BlockingStreamProvider(terminalEvents: [.textDelta("first answer"), .completed(.stop)])
    let loop = await convMakeLoop(provider: provider, log: log, runs: runs, store: store)

    let firstRequest = convRequest(session: "session-loop021", turn: "t1", run: "r1", prompt: "first prompt")
    let secondRequest = convRequest(session: "session-loop021", turn: "t2", run: "r2", prompt: "second prompt")

    let firstTask = Task { await loop.run(firstRequest, policy: LoopPolicy()) }
    #expect(await provider.arrival.wait())

    // The first run is durably started and blocked in the provider stream.
    let recordsWhileBlocked = await log.recordCount
    let secondResult = await loop.run(secondRequest, policy: LoopPolicy())

    #expect(secondResult.status == .failed)
    #expect(secondResult.cause == .concurrentRunRejected)
    #expect(secondResult.terminalCommitted == false)
    #expect(secondResult.steps == 0)
    // Admission rejection must not write a single journal record and must not leave a run record.
    #expect(await log.recordCount == recordsWhileBlocked)
    #expect(await runs.record(secondRequest.runID) == nil)
    #expect(await runs.openRunIDs == [firstRequest.runID])
    #expect(await runs.activeRun(for: firstRequest.sessionID) == firstRequest.runID)

    // The first run is unaffected by the rejected second run.
    provider.release.fire()
    let firstResult = await firstTask.value
    #expect(firstResult.status == .completed)
    #expect(firstResult.cause == .completedWithText)
    #expect(firstResult.assistantText == "first answer")

    let events = try await log.events()
    let created = events.compactMap { event -> RunID? in
        if case .runCreated(let runID, _, _) = event { return runID }
        return nil
    }
    #expect(created == [firstRequest.runID])
    #expect(try await convTerminals(log).count == 1)
    #expect(!events.contains { $0.runID == secondRequest.runID })
    let stored = await store.entries(for: firstRequest.sessionID)
    #expect(convTexts(stored) == ["first prompt", "first answer"])
}

@Test("LOOP-021 different sessions may have active runs at the same time", .timeLimit(.minutes(1)))
func LOOP_021_differentSessionsRunConcurrently() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let runs = RunRegistry()
    let providerA = BlockingStreamProvider(terminalEvents: [.textDelta("answer a"), .completed(.stop)])
    let providerB = BlockingStreamProvider(terminalEvents: [.textDelta("answer b"), .completed(.stop)])
    let router = ModelRouter()
    await router.register(provider: providerA, id: ProviderID("test.provider.a"), models: ["model-a"])
    await router.register(provider: providerB, id: ProviderID("test.provider.b"), models: ["model-b"])
    let loop = AgentLoop(
        router: router,
        toolRegistry: ToolRegistry(),
        executor: RecordingExecutor(),
        log: log,
        runs: runs,
        store: SessionStore(),
        clock: ManualClock(),
        instructions: "instructions"
    )

    let requestA = convRequest(session: "session-loop021-a", turn: "t1", run: "r1", prompt: "prompt a", model: "model-a")
    let requestB = convRequest(session: "session-loop021-b", turn: "t1", run: "r2", prompt: "prompt b", model: "model-b")
    let taskA = Task { await loop.run(requestA, policy: LoopPolicy()) }
    let taskB = Task { await loop.run(requestB, policy: LoopPolicy()) }

    // Both streams are blocked inside the provider: both runs are admitted and active simultaneously.
    #expect(await providerA.arrival.wait())
    #expect(await providerB.arrival.wait())
    let open = await runs.openRunIDs
    #expect(Set(open) == Set([requestA.runID, requestB.runID]))
    #expect(await runs.activeRun(for: requestA.sessionID) == requestA.runID)
    #expect(await runs.activeRun(for: requestB.sessionID) == requestB.runID)

    providerA.release.fire()
    providerB.release.fire()
    let resultA = await taskA.value
    let resultB = await taskB.value
    #expect(resultA.status == .completed)
    #expect(resultB.status == .completed)
    #expect(resultA.assistantText == "answer a")
    #expect(resultB.assistantText == "answer b")
    #expect(await runs.openRunIDs.isEmpty)
    #expect(try await convTerminals(log).count == 2)
}

// MARK: - LOOP-022: incomplete stop reasons are failures with explicit causes

@Test("LOOP-022 incomplete stop reasons are failures with explicit causes, never completed")
func LOOP_022_incompleteStopReasonsClassified() async throws {
    // .maxTokens: failed / outputTruncated; partial text survives on the result.
    let truncated = try await convRunOneScript([.started, .textDelta("half an answer"), .completed(.maxTokens)])
    #expect(truncated.result.status == .failed)
    #expect(truncated.result.cause == .outputTruncated)
    #expect(truncated.result.assistantText == "half an answer")
    var terminals = try await convTerminals(truncated.log)
    #expect(terminals.count == 1)
    #expect(terminals.first?.status == .failed)
    #expect(terminals.first?.cause == .outputTruncated)

    // .contentFilter: failed / contentFiltered, and filtered text is never persisted.
    let filtered = try await convRunOneScript([.started, .textDelta("filtered words"), .completed(.contentFilter)])
    #expect(filtered.result.status == .failed)
    #expect(filtered.result.cause == .contentFiltered)
    #expect(try await convAssistantTextEntries(filtered.log).isEmpty)
    terminals = try await convTerminals(filtered.log)
    #expect(terminals.count == 1)
    #expect(terminals.first?.cause == .contentFiltered)

    // .refusal: failed / refused, and the refusal text is never persisted.
    let refused = try await convRunOneScript([.started, .textDelta("I cannot help"), .completed(.refusal)])
    #expect(refused.result.status == .failed)
    #expect(refused.result.cause == .refused)
    #expect(try await convAssistantTextEntries(refused.log).isEmpty)
    terminals = try await convTerminals(refused.log)
    #expect(terminals.count == 1)
    #expect(terminals.first?.cause == .refused)

    // .unknown is a protocol violation, not a normal completion.
    let unknown = try await convRunOneScript([.started, .completed(.unknown)])
    #expect(unknown.result.status == .failed)
    #expect(unknown.result.cause == .streamProtocolViolation)

    // A normal .stop with text is the one completed-with-text path.
    let normal = try await convRunOneScript(completed("full answer"))
    #expect(normal.result.status == .completed)
    #expect(normal.result.cause == .completedWithText)
    #expect(normal.result.assistantText == "full answer")

    // A normal .stop without text is completed, but classified as an empty completion.
    let empty = try await convRunOneScript([.started, .completed(.stop)])
    #expect(empty.result.status == .completed)
    #expect(empty.result.cause == .completedWithEmptyText)
}

// MARK: - LOOP-023: cancellation and timeout race over a blocked provider stream

@Test("LOOP-023 cancelling a blocked provider stream wins and discards late terminal events", .timeLimit(.minutes(1)))
func LOOP_023_cancelWinsOverBlockedStream() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let runs = RunRegistry()
    let store = SessionStore()
    let provider = BlockingStreamProvider(terminalEvents: [.textDelta("late answer"), .completed(.stop)])
    let loop = await convMakeLoop(provider: provider, log: log, runs: runs, store: store)
    let request = convRequest(session: "session-loop023-cancel", turn: "t1", run: "r1", prompt: "start a long run")

    let task = Task { await loop.run(request, policy: LoopPolicy()) }
    #expect(await provider.arrival.wait())
    task.cancel()
    // The provider terminal arrives after the cancel intent: it must be discarded, not fabricated
    // into a provider failure or a late completion.
    provider.release.fire()
    let result = await task.value

    #expect(result.status == .cancelled)
    #expect(result.cause == .cancelledByUser)
    #expect(result.terminalCommitted)
    #expect(result.assistantText.isEmpty)
    #expect(result.detail?.contains("provider") != true)
    #expect(result.detail?.contains("429") != true)

    let terminals = try await convTerminals(log)
    #expect(terminals.count == 1)
    #expect(terminals.first?.status == .cancelled)
    #expect(terminals.first?.cause == .cancelledByUser)
    let entries = try await convEntries(log)
    #expect(!entries.contains { $0.role == .assistant })
    #expect(await runs.record(request.runID)?.status == .cancelled)
    #expect(await runs.record(request.runID)?.cause == .cancelledByUser)
}

@Test("LOOP-023 the overall timeout wins over a blocked provider stream", .timeLimit(.minutes(1)))
func LOOP_023_deadlineWinsOverBlockedStream() async throws {
    let clock = ManualClock()
    let log = try DurableEventLog(sink: MemorySink())
    let runs = RunRegistry()
    let provider = BlockingStreamProvider(terminalEvents: [.textDelta("too late"), .completed(.stop)])
    let loop = await convMakeLoop(provider: provider, log: log, runs: runs, store: SessionStore(), clock: clock)
    let request = convRequest(session: "session-loop023-deadline", turn: "t1", run: "r1", prompt: "block forever")

    let task = Task { await loop.run(request, policy: LoopPolicy(overallTimeout: .seconds(10))) }
    #expect(await provider.arrival.wait())      // the stream is blocked in the provider now
    #expect(await clock.sleepStarted.wait())    // the watchdog has registered its virtual deadline
    clock.advance(.seconds(11))

    let result = await task.value
    provider.release.fire()                     // drain the abandoned pump task
    #expect(result.status == .deadlineExceeded)
    #expect(result.cause == .deadlineExceeded)
    #expect(result.terminalCommitted)
    #expect(result.assistantText.isEmpty)

    let terminals = try await convTerminals(log)
    #expect(terminals.count == 1)
    #expect(terminals.first?.status == .deadlineExceeded)
    #expect(terminals.first?.cause == .deadlineExceeded)
}

@Test("LOOP-023 a provider failure delivered without a cancel stays a providerFailure", .timeLimit(.minutes(1)))
func LOOP_023_providerFailureDeliveredAfterBlockedStream() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let runs = RunRegistry()
    let store = SessionStore()
    let failure = ModelFailure(kind: .rateLimited, message: "429 upstream rate limited")
    let provider = BlockingStreamProvider(terminalEvents: [.textDelta("partial"), .failed(failure)])
    let loop = await convMakeLoop(provider: provider, log: log, runs: runs, store: store)
    let request = convRequest(session: "session-loop023-failure", turn: "t1", run: "r1", prompt: "call upstream")

    let task = Task { await loop.run(request, policy: LoopPolicy()) }
    #expect(await provider.arrival.wait())
    provider.release.fire()
    let result = await task.value

    #expect(result.status == .failed)
    #expect(result.cause == .providerFailure)
    #expect(result.detail?.contains("429") == true)
    #expect(result.terminalCommitted)

    let terminals = try await convTerminals(log)
    #expect(terminals.count == 1)
    #expect(terminals.first?.status == .failed)
    #expect(terminals.first?.cause == .providerFailure)
}

// MARK: - LOOP-024: assistant text is durable and visible to later turns

@Test("LOOP-024 three real turns keep prior user and assistant history in every later request")
func LOOP_024_historyAcrossThreeTurns() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let store = SessionStore()
    let runs = RunRegistry()
    let prompts = ["prompt one", "prompt two", "prompt three"]
    let answers = ["answer one", "answer two", "answer three"]
    let provider = ScriptedProvider(scripts: answers.map { completed($0) })
    let loop = await convMakeLoop(provider: provider, log: log, runs: runs, store: store)

    for index in 0..<3 {
        let result = await loop.run(
            convRequest(session: "session-loop024", turn: "t\(index + 1)", run: "r\(index + 1)", prompt: prompts[index]),
            policy: LoopPolicy()
        )
        #expect(result.status == .completed)
        #expect(result.cause == .completedWithText)
        #expect(result.assistantText == answers[index])
    }
    #expect(provider.requestCount == 3)

    // Turn 2 request: instructions + turn-1 user + turn-1 assistant + current user.
    let turnTwo = try #require(provider.request(at: 1))
    #expect(turnTwo.entries.map(\.segment) == [.immutableInstructions, .history, .history, .currentUser])
    #expect(turnTwo.entries.map(\.role) == [.system, .user, .assistant, .user])
    #expect(convTexts(turnTwo.entries) == ["instructions", "prompt one", "answer one", "prompt two"])

    // Turn 3 request: the complete history of both previous turns plus the current user.
    let turnThree = try #require(provider.request(at: 2))
    #expect(turnThree.entries.map(\.segment) == [.immutableInstructions, .history, .history, .history, .history, .currentUser])
    #expect(convTexts(turnThree.entries) == [
        "instructions", "prompt one", "answer one", "prompt two", "answer two", "prompt three",
    ])

    // The store rebuilt through real appends matches the request history (CTX-017 demotion included).
    let stored = await store.entries(for: SessionID("session-loop024"))
    #expect(convTexts(stored) == ["prompt one", "answer one", "prompt two", "answer two", "prompt three", "answer three"])
    #expect(stored.map(\.segment) == [.history, .history, .history, .history, .currentUser, .history])

    // Both sides of every turn are durably journaled.
    let journalEntries = try await convEntries(log)
    #expect(convTexts(journalEntries) == ["prompt one", "answer one", "prompt two", "answer two", "prompt three", "answer three"])
}

@Test("LOOP-024 a tool round persists assistant text and calls in one history entry")
func LOOP_024_toolRoundKeepsAssistantTextAndCalls() async throws {
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let log = try DurableEventLog(sink: MemorySink())
    let store = SessionStore()
    let call = makeCall("c1")
    let toolRound: [ModelEvent] = [
        .started,
        .textDelta("checking the file "),
        .toolCallStarted(ToolCallStart(callID: call.callID, toolName: call.toolName)),
        .toolCallCompleted(call),
        .completed(.toolCalls),
    ]
    let provider = ScriptedProvider(scripts: [toolRound, completed("all done")])
    let loop = await convMakeLoop(provider: provider, executor: RecordingExecutor(), registry: registry, log: log, store: store)
    let result = await loop.run(
        convRequest(session: "session-loop024-tool", turn: "t1", run: "r1", prompt: "please check"),
        policy: LoopPolicy()
    )
    #expect(result.status == .completed)
    #expect(result.assistantText == "all done")
    #expect(result.toolOutcomes == 1)

    let entries = try await convEntries(log)
    let callEntries = entries.filter { !$0.payload.toolCalls.isEmpty }
    #expect(callEntries.count == 1)   // text and calls in ONE entry, no separate toolCall entry
    let callEntry = try #require(callEntries.first)
    #expect(callEntry.role == .assistant)
    #expect(callEntry.segment == .history)
    #expect(callEntry.unit == "r1-batch1")
    if case .assistantMessage(text: let text, requests: let calls) = callEntry.payload {
        #expect(text == "checking the file ")
        #expect(calls == [call])
    } else {
        Issue.record("expected the tool round to persist a single .assistantMessage entry")
    }

    let resultEntries = entries.filter { !$0.payload.toolOutcomes.isEmpty }
    #expect(resultEntries.count == 1)
    let outcomeEntry = try #require(resultEntries.first)
    #expect(outcomeEntry.role == .tool)
    #expect(outcomeEntry.unit == callEntry.unit)
    #expect(outcomeEntry.payload.toolOutcomes.map(\.callID) == [call.callID])
    let callIndex = try #require(entries.firstIndex { $0.unit == callEntry.unit && !$0.payload.toolCalls.isEmpty })
    let outcomeIndex = try #require(entries.firstIndex { $0.unit == outcomeEntry.unit && !$0.payload.toolOutcomes.isEmpty })
    #expect(callIndex < outcomeIndex)

    // The next model request carries the full exchange: user -> assistant(text+calls) -> tool result.
    let second = try #require(provider.request(at: 1))
    #expect(second.entries.map(\.role) == [.system, .user, .assistant, .tool])
    #expect(second.entries.map(\.segment) == [.immutableInstructions, .currentUser, .history, .history])
    if case .assistantMessage(text: let text, requests: let calls) = second.entries[2].payload {
        #expect(text == "checking the file ")
        #expect(calls == [call])
    } else {
        Issue.record("the later request lost the assistant text of the tool round")
    }
    #expect(second.entries[3].payload.toolOutcomes.map(\.callID) == [call.callID])

    // The final assistant text is journaled as its own history entry after the tool exchange.
    let assistantTexts = try await convAssistantTextEntries(log)
    #expect(assistantTexts.map(\.renderedText) == ["all done"])
    let finalAssistantIndex = try #require(entries.firstIndex { $0.renderedText == "all done" })
    #expect(outcomeIndex < finalAssistantIndex)
}

@Test("LOOP-024 text produced before a maxTokens cut is persisted for the next turn")
func LOOP_024_truncatedTextPersisted() async throws {
    let run = try await convRunOneScript([.started, .textDelta("partial answer"), .completed(.maxTokens)])
    #expect(run.result.status == .failed)
    #expect(run.result.cause == .outputTruncated)

    let assistants = try await convAssistantTextEntries(run.log)
    #expect(assistants.count == 1)
    #expect(assistants.first?.renderedText == "partial answer")
    #expect(assistants.first?.segment == .history)
    #expect(assistants.first?.role == .assistant)
    let stored = await run.store.entries(for: SessionID("session-scripted"))
    #expect(stored.contains { $0.role == .assistant && $0.renderedText == "partial answer" })

    // Durable before memory: the text record precedes the terminal record in the journal.
    let events = try await run.log.events()
    let textIndex = try #require(events.firstIndex { event in
        if case .entryRecorded(_, let entry) = event, entry.role == .assistant { return true }
        return false
    })
    let terminalIndex = try #require(events.firstIndex { event in
        if case .runTerminal = event { return true }
        return false
    })
    #expect(textIndex < terminalIndex)
}

// MARK: - CTX-017: only the current turn's user entry is mandatory

@Test("CTX-017 only the current turn's user entry is currentUser, earlier user turns are history")
func CTX_017_onlyCurrentUserIsMandatory() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let store = SessionStore()
    let runs = RunRegistry()
    let prompts = ["prompt one", "prompt two", "prompt three"]
    let answers = ["answer one", "answer two", "answer three"]
    let provider = ScriptedProvider(scripts: answers.map { completed($0) })
    let loop = await convMakeLoop(provider: provider, log: log, runs: runs, store: store)

    for index in 0..<3 {
        let result = await loop.run(
            convRequest(session: "session-ctx017", turn: "t\(index + 1)", run: "r\(index + 1)", prompt: prompts[index]),
            policy: LoopPolicy()
        )
        #expect(result.status == .completed)
    }

    let stored = await store.entries(for: SessionID("session-ctx017"))
    #expect(stored.filter { $0.segment == .currentUser }.count == 1)
    #expect(stored.filter { $0.segment == .currentUser }.map(\.renderedText) == ["prompt three"])
    #expect(stored.filter { $0.segment == .history && $0.role == .user }.map(\.renderedText) == ["prompt one", "prompt two"])
    #expect(ContextSegment.currentUser.isMandatory)
    #expect(ContextSegment.history.isMandatory == false)

    // Every request has exactly one mandatory user entry: the one belonging to that turn.
    for index in 0..<3 {
        let request = try #require(provider.request(at: index))
        let currentUsers = request.entries.filter { $0.segment == .currentUser }
        #expect(currentUsers.count == 1)
        #expect(currentUsers.map(\.renderedText) == [prompts[index]])
        #expect(request.entries.filter { $0.role == .user && $0.segment == .history }.count == index)
    }

    // Prior user turns participate in the budget like any history entry: they can be evicted, while
    // the current user and the instruction block never are.
    let latest = try #require(provider.request(at: 2))
    let plan = try ContextBudgetPlanner().plan(
        latest.entries,
        limits: BudgetLimits(preferredTokens: 30, hardTokens: 400)
    )
    #expect(plan.evicted.contains { $0.segment == .history && $0.role == .user })
    #expect(plan.evicted.map(\.renderedText).contains("prompt one"))
    #expect(plan.evicted.allSatisfy { $0.segment.isMandatory == false })
    #expect(plan.selected.contains { $0.segment == .currentUser && $0.renderedText == "prompt three" })
    #expect(plan.selected.contains { $0.segment == .immutableInstructions })
}

// MARK: - CTX-018: budget trimming keeps the request protocol-valid and the reference on the data channel

@Test("CTX-018 a long real conversation is trimmed and still reaches the provider protocol-valid")
func CTX_018_budgetTrimKeepsRequestValid() async throws {
    let conversation = try await convRunConversation(
        turns: 6,
        session: "session-ctx018",
        lastPolicy: LoopPolicy(preferredTokens: 300, hardTokens: 400)
    )
    #expect(conversation.results.prefix(5).allSatisfy { $0.status == .completed })
    let sixth = try #require(conversation.results.last)
    #expect(sixth.status == .completed)
    #expect(sixth.cause == .completedWithText)
    #expect(sixth.assistantText == conversation.answers[5])
    #expect(conversation.provider.requestCount == 6)

    let request = try #require(conversation.provider.request(at: 5))
    // The trimmed context still passes the protocol validator (the loop re-validates plan.selected).
    try ContextRequestValidator.validate(request.entries, placement: .anywhereInHistory)

    #expect(request.entries.map(\.segment) == [
        .immutableInstructions, .history, .history, .history, .currentUser, .derivedPage,
    ])
    #expect(request.entries.filter { $0.segment.isPrivileged }.count == 1)
    #expect(request.entries.first?.role == .system)
    #expect(request.entries.filter { $0.role == .system }.count == 1)   // no derived entry on the instruction channel
    #expect(request.entries.filter { $0.segment == .currentUser }.map(\.renderedText) == [conversation.prompts[5]])

    let texts = convTexts(request.entries)
    #expect(texts.count == 6)
    #expect(texts[0] == "instructions")
    #expect(texts[1] == conversation.answers[3])     // answer-4
    #expect(texts[2] == conversation.prompts[4])     // prompt-5
    #expect(texts[3] == conversation.answers[4])     // answer-5
    #expect(texts[4] == conversation.prompts[5])     // prompt-6
    #expect(texts[5].contains("Evicted for budget"))
    #expect(!texts.contains(conversation.prompts[0]))

    let reference = try #require(request.entries.first { $0.segment == .derivedPage })
    #expect(reference.role == .user)                 // data channel, never role .system
    #expect(reference.renderedText.contains("recoverable by entry id"))

    // The request that actually reached the provider, reference line included, fits the hard limit.
    let estimator = TokenEstimator()
    let sentTokens = request.entries.reduce(0) { $0 + estimator.estimate($1) }
    #expect(sentTokens <= 400)
}

@Test("CTX-018 the eviction reference line counts toward the budget and the hard limit")
func CTX_018_referenceCountsTowardHardLimit() async throws {
    let conversation = try await convRunConversation(turns: 5, session: "session-ctx018-hard")
    let prior = try #require(conversation.provider.request(at: 4))
    // Five untrimmed turns: instructions + 4 (user, assistant) pairs + current user.
    #expect(prior.entries.count == 10)

    // preferred=200 -> high water 230 / low water 160. The 493-token history is trimmed to the low
    // water mark; the reference line then has to be counted, forcing one more eviction to stay under
    // the 145-token hard limit.
    let plan = try ContextBudgetPlanner().plan(
        prior.entries,
        limits: BudgetLimits(preferredTokens: 200, hardTokens: 145)
    )
    #expect(plan.highWaterTokens == 230)
    #expect(plan.lowWaterTokens == 160)
    #expect(plan.estimatedTokens <= 145)

    let estimator = TokenEstimator()
    let selectedTokens = plan.selected.reduce(0) { $0 + estimator.estimate($1) }
    #expect(plan.estimatedTokens == selectedTokens)   // the reference line's own tokens are included

    let reference = try #require(plan.selected.first { $0.segment == .derivedPage })
    #expect(reference.role == .user)
    #expect(reference.renderedText.contains("Evicted for budget"))
    #expect(plan.selected.contains { $0.segment == .immutableInstructions })
    #expect(plan.selected.contains { $0.segment == .currentUser })
    #expect(plan.evicted.contains { $0.segment == .history && $0.role == .user })
    #expect(plan.evicted.allSatisfy { $0.segment.isMandatory == false })
    try ContextRequestValidator.validate(plan.selected, placement: .anywhereInHistory)
}

// MARK: - CACHE-007: usage is summed per field, absence stays distinct from zero

@Test("CACHE-007 usage is summed field by field across steps, keeping absence and zero distinct")
func CACHE_007_usageSummedAcrossSteps() async throws {
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let firstStep: [ModelEvent] = [
        .started,
        .usage(ModelUsage(inputTokens: 10, outputTokens: 5, cacheReadTokens: 0)),
        .toolCallStarted(ToolCallStart(callID: "c1", toolName: "echo")),
        .toolCallCompleted(makeCall("c1")),
        .completed(.toolCalls),
    ]
    let secondStep: [ModelEvent] = [
        .started,
        .usage(ModelUsage()),   // all-nil telemetry must not erase or zero the previous step
        .usage(ModelUsage(inputTokens: 20, cacheReadTokens: 0, cacheWriteTokens: 3)),
        .textDelta("finished"),
        .completed(.stop),
    ]
    let log = try DurableEventLog(sink: MemorySink())
    let provider = ScriptedProvider(scripts: [firstStep, secondStep])
    let loop = await convMakeLoop(provider: provider, registry: registry, log: log)
    let result = await loop.run(
        convRequest(session: "session-cache007", turn: "t1", run: "r1", prompt: "do work"),
        policy: LoopPolicy()
    )

    #expect(result.status == .completed)
    #expect(result.steps == 2)
    let usage = try #require(result.usage)
    #expect(usage.inputTokens == 30)          // 10 + 20
    #expect(usage.outputTokens == 5)          // reported by step 1 only
    #expect(usage.reasoningTokens == nil)     // never reported by any step
    #expect(usage.cacheReadTokens == 0)       // explicit zero preserved and summed
    #expect(usage.cacheWriteTokens == 3)      // reported by step 2 only
}

@Test("CACHE-007 a run without usage telemetry keeps the aggregated usage nil")
func CACHE_007_absentUsageStaysNil() async throws {
    let noUsageEvent = try await convRunOneScript(completed("no telemetry"))
    #expect(noUsageEvent.result.status == .completed)
    #expect(convIsNil(noUsageEvent.result.usage))

    // An all-nil ModelUsage event is "nothing reported", not a reported zero.
    let emptyUsageEvent = try await convRunOneScript([
        .started, .usage(ModelUsage()), .textDelta("still nothing"), .completed(.stop),
    ])
    #expect(emptyUsageEvent.result.status == .completed)
    #expect(convIsNil(emptyUsageEvent.result.usage))
}

// MARK: - QA-013: a core without a provider only reports guidance

@Test("QA-013 a run without a provider reports guidance and writes nothing")
func QA_013_noProviderWritesNothing() async throws {
    let sink = MemorySink()
    let log = try DurableEventLog(sink: sink)
    let runs = RunRegistry()
    let store = SessionStore()
    let loop = AgentLoop(
        router: ModelRouter(),
        toolRegistry: ToolRegistry(),
        executor: RecordingExecutor(),
        log: log,
        runs: runs,
        store: store,
        instructions: "instructions"
    )
    let request = convRequest(session: "session-qa013", turn: "t1", run: "r1", prompt: "hello", model: "any-model")

    let result = await loop.run(request, policy: LoopPolicy())

    #expect(result.status == .failed)
    #expect(result.cause == .runtimeFailure)
    #expect(result.detail?.contains("No provider plugin is active") == true)
    #expect(result.terminalCommitted == false)
    #expect(result.steps == 0)
    // No journal record, no run record, no session history was produced.
    #expect(await log.recordCount == 0)
    #expect(sink.lineCount == 0)
    #expect(try await log.events().isEmpty)
    #expect(await runs.record(request.runID) == nil)
    #expect(await runs.openRunIDs.isEmpty)
    #expect(await store.sessionIDs().isEmpty)
}

// MARK: - LOOP-001 concurrent variant (terminal race stays single-winner)

@Test("LOOP-001 concurrent terminalization attempts have exactly one winner")
func LOOP_001_concurrentTerminalizationHasOneWinner() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let runs = RunRegistry()
    let runID = newRunID("concurrent-terminal")
    try await runs.create(id: runID, sessionID: "session-loop001", turnID: "t1")
    try await runs.markRunning(runID)

    async let completedAttempt = runs.terminalize(
        runID, status: .completed, cause: .completedWithText, detail: "completed", via: log
    )
    async let cancelledAttempt = runs.terminalize(
        runID, status: .cancelled, cause: .cancelledByUser, detail: "cancelled", via: log
    )
    let (completedWon, cancelledWon) = try await (completedAttempt, cancelledAttempt)
    #expect(completedWon != cancelledWon)   // exactly one winner

    let winner = try #require(await runs.record(runID))
    let terminals = try await convTerminals(log)
    #expect(terminals.count == 1)
    if completedWon {
        #expect(winner.status == .completed)
        #expect(winner.cause == .completedWithText)
        #expect(terminals.first?.status == .completed)
        #expect(terminals.first?.cause == .completedWithText)
    } else {
        #expect(winner.status == .cancelled)
        #expect(winner.cause == .cancelledByUser)
        #expect(terminals.first?.status == .cancelled)
        #expect(terminals.first?.cause == .cancelledByUser)
    }
    #expect(try await runs.terminalize(runID, status: .failed, cause: .runtimeFailure, detail: nil, via: log) == false)
}
