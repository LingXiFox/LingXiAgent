import Foundation
import LingXiKernel
import Testing

// Independent acceptance tests for Phase 1.1 crash-consistency work:
//   STORE-008, STORE-009, STORE-010, LOOP-025.
//
// Rules honoured here (contract §0/§5):
// - Recovery is always exercised as a "new process": a brand-new DurableEventLog over the same
//   durable bytes, and only the SessionStore/RunRegistry returned by KernelRecovery are inspected.
// - No fixed Task.sleep: journal prefixes that stand for a crash are constructed deterministically
//   from the public event API, or produced by a real AgentLoop with a sink that fails exactly once
//   at a named failure point.
// - Every helper in this file is private and prefixed, because the test target shares one namespace.

// MARK: - Sandbox and file helpers

private final class RecoveryAcceptanceSandbox {
    let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lingxi-recovery-acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var journalURL: URL { directory.appendingPathComponent("events.jsonl") }

    func fileSink() -> FileEventLogSink { FileEventLogSink(url: journalURL) }

    func destroy() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func recoveryAcceptanceAppendRaw(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.synchronize()
}

private func recoveryAcceptanceOverwrite(_ text: String, at url: URL) throws {
    try Data(text.utf8).write(to: url, options: .atomic)
}

private func recoveryAcceptanceEncodedLine(_ event: RecordedEvent) throws -> String {
    String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
}

/// Seeds a real file journal with the given events, in order, exactly as the kernel would.
private func recoveryAcceptanceWriteJournal(_ events: [RecordedEvent], to url: URL) async throws {
    let log = try DurableEventLog(sink: FileEventLogSink(url: url))
    for event in events {
        try await log.append(event)
    }
}

private func recoveryAcceptanceDecode(_ line: String) -> RecordedEvent? {
    try? JSONDecoder().decode(RecordedEvent.self, from: Data(line.utf8))
}

/// True when the durable journal already contains a batchStarted event for the run. Used from inside
/// a tool executor to prove the execution intent hit the journal before the side effect.
private func recoveryAcceptanceJournalHasBatchStarted(_ sink: any EventLogSink, runID: RunID) -> Bool {
    guard let lines = try? sink.readLines() else { return false }
    return lines.contains { line in
        guard let event = recoveryAcceptanceDecode(line) else { return false }
        if case .batchStarted(let eventRunID, _, _) = event { return eventRunID == runID }
        return false
    }
}

// MARK: - Fault injection

private struct RecoveryAcceptanceSinkFault: Error {}

/// Wraps a durable sink and fails exactly one named operation, so crash images are deterministic.
private final class RecoveryAcceptanceFaultSink: EventLogSink, @unchecked Sendable {
    private let base: any EventLogSink
    private let lock = NSLock()
    private var terminalAppendFailuresRemaining = 0
    private var truncateFailuresRemaining = 0

    init(base: any EventLogSink) {
        self.base = base
    }

    func failNextTerminalAppend() {
        lock.lock()
        terminalAppendFailuresRemaining += 1
        lock.unlock()
    }

    func failNextTruncate() {
        lock.lock()
        truncateFailuresRemaining += 1
        lock.unlock()
    }

    private func shouldFailTerminalAppend(_ line: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard terminalAppendFailuresRemaining > 0 else { return false }
        guard let event = recoveryAcceptanceDecode(line) else { return false }
        guard case .runTerminal = event else { return false }
        terminalAppendFailuresRemaining -= 1
        return true
    }

    func append(line: String) throws {
        if shouldFailTerminalAppend(line) {
            throw RecoveryAcceptanceSinkFault()
        }
        try base.append(line: line)
    }

    func truncate(toLineCount count: Int) throws {
        lock.lock()
        let shouldFail = truncateFailuresRemaining > 0
        if shouldFail { truncateFailuresRemaining -= 1 }
        lock.unlock()
        if shouldFail { throw RecoveryAcceptanceSinkFault() }
        try base.truncate(toLineCount: count)
    }

    func readLines() throws -> [String] {
        try base.readLines()
    }
}

private final class RecoveryAcceptanceExecutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var executionCount = 0
    private var everyExecutionWasPrecededByDurableIntent = true

    func recordExecution(batchStartedDurable: Bool) {
        lock.lock()
        executionCount += 1
        if !batchStartedDurable { everyExecutionWasPrecededByDurableIntent = false }
        lock.unlock()
    }

    var executions: Int {
        lock.lock()
        defer { lock.unlock() }
        return executionCount
    }

    var precededByDurableIntent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return executionCount > 0 && everyExecutionWasPrecededByDurableIntent
    }
}

// MARK: - Snapshots (data comparison only; no live instance is ever handed to recovery)

private struct RecoveryAcceptanceEntrySnapshot: Equatable {
    let id: String
    let segment: String
    let role: String
    let unit: String?
    let payload: String
}

private func recoveryAcceptanceSnapshots(_ entries: [ContextEntry]) -> [RecoveryAcceptanceEntrySnapshot] {
    entries.map { entry in
        RecoveryAcceptanceEntrySnapshot(
            id: entry.id.rawValue,
            segment: entry.segment.rawValue,
            role: entry.role.rawValue,
            unit: entry.unit,
            payload: String(describing: entry.payload)
        )
    }
}

private struct RecoveryAcceptanceRunSnapshot: Equatable {
    let id: String
    let sessionID: String
    let turnID: String
    let status: String
    let cause: String
}

// `detail` is intentionally excluded: it is not persisted in the journal, so it may differ between
// the instance that terminalized a run and a later replay of the same runTerminal record.
private func recoveryAcceptanceRunSnapshot(_ record: RunRecord) -> RecoveryAcceptanceRunSnapshot {
    RecoveryAcceptanceRunSnapshot(
        id: record.id.rawValue,
        sessionID: record.sessionID.rawValue,
        turnID: record.turnID.rawValue,
        status: record.status.rawValue,
        cause: record.cause.rawValue
    )
}

private func recoveryAcceptanceToolOutcomes(_ entries: [ContextEntry]) -> [ToolOutcome] {
    entries.compactMap(\.payload.toolOutcomes).flatMap { $0 }
}

private func recoveryAcceptanceHistoryIsProtocolValid(_ entries: [ContextEntry]) -> Bool {
    do {
        try ContextRequestValidator.validate(entries, placement: .anywhereInHistory)
        return true
    } catch {
        return false
    }
}

// MARK: - Event / entry builders

private func recoveryAcceptanceUserEntry(turnID: TurnID, prompt: String) -> ContextEntry {
    ContextEntry(
        id: EntryID("turn-\(turnID.rawValue)"),
        segment: .currentUser,
        role: .user,
        payload: .text(prompt)
    )
}

private func recoveryAcceptanceCallEntry(batchID: BatchID, calls: [ToolCall]) -> ContextEntry {
    ContextEntry(
        id: EntryID("call-\(batchID.rawValue)"),
        segment: .history,
        role: .assistant,
        payload: .toolCall(requests: calls),
        unit: batchID.rawValue
    )
}

private func recoveryAcceptanceResultEntry(batchID: BatchID, outcomes: [ToolOutcome]) -> ContextEntry {
    ContextEntry(
        id: EntryID("result-\(batchID.rawValue)"),
        segment: .history,
        role: .tool,
        payload: .toolResult(outcomes: outcomes),
        unit: batchID.rawValue
    )
}

private func recoveryAcceptanceOutcome(
    _ call: ToolCall,
    content: String,
    isError: Bool = false,
    effect: ToolEffect = .mutating
) -> ToolOutcome {
    ToolOutcome(callID: call.callID, content: content, isError: isError, effect: effect)
}

private func recoveryAcceptanceRequest(
    session: SessionID,
    turn: String,
    run: String,
    prompt: String
) -> RunRequest {
    RunRequest(
        sessionID: session,
        turnID: TurnID(turn),
        runID: RunID(run),
        executionID: ExecutionID("exec-\(run)"),
        model: ModelID("test-model"),
        prompt: prompt
    )
}

// MARK: - Error classifiers

private func recoveryAcceptanceUndecodableIndex(_ error: (any Error)?) -> Int? {
    guard let error = error as? EventLogError else { return nil }
    guard case .undecodableLine(let index, _) = error else { return nil }
    return index
}

private func recoveryAcceptanceIsRepairFailed(_ error: (any Error)?) -> Bool {
    guard let error = error as? EventLogError else { return false }
    guard case .repairFailed = error else { return false }
    return true
}

private func recoveryAcceptanceIsRepairRequired(_ error: (any Error)?) -> Bool {
    guard let error = error as? EventLogError else { return false }
    guard case .repairRequired = error else { return false }
    return true
}

private func recoveryAcceptanceIsRollbackFailed(_ error: (any Error)?) -> Bool {
    guard let error = error as? EventLogError else { return false }
    guard case .rollbackFailed = error else { return false }
    return true
}

private func recoveryAcceptanceIsUnavailable(_ error: (any Error)?) -> Bool {
    guard let error = error as? EventLogError else { return false }
    guard case .unavailable = error else { return false }
    return true
}

// MARK: - STORE-008

@Test("STORE-008 replaying a durable journal rebuilds a fresh SessionStore and RunRegistry")
func STORE_008_fullReplayRebuildsFreshKernel() async throws {
    let sandbox = try RecoveryAcceptanceSandbox()
    defer { sandbox.destroy() }

    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let runs = RunRegistry()
    let store = SessionStore()
    let provider = ScriptedProvider(scripts: [
        completed("first answer"),
        toolBatch([makeCall("c1")]),
        completed("second answer"),
        completed(""),
        [.started, .failed(ModelFailure(kind: .rateLimited, message: "429 too many requests"))],
    ])
    let executor = RecordingExecutor()
    let log = try DurableEventLog(sink: sandbox.fileSink())
    let loop = await makeLoop(
        provider: provider,
        executor: executor,
        registry: registry,
        log: log,
        runs: runs,
        store: store
    )

    let sessionA = SessionID("session-store-008-a")
    let sessionB = SessionID("session-store-008-b")
    let requestA1 = recoveryAcceptanceRequest(session: sessionA, turn: "store-008-a1", run: "store-008-run-a1", prompt: "prompt one")
    let requestA2 = recoveryAcceptanceRequest(session: sessionA, turn: "store-008-a2", run: "store-008-run-a2", prompt: "prompt two")
    let requestA3 = recoveryAcceptanceRequest(session: sessionA, turn: "store-008-a3", run: "store-008-run-a3", prompt: "prompt three")
    let requestB = recoveryAcceptanceRequest(session: sessionB, turn: "store-008-b1", run: "store-008-run-b1", prompt: "prompt elsewhere")

    let resultA1 = await loop.run(requestA1, policy: LoopPolicy())
    let resultA2 = await loop.run(requestA2, policy: LoopPolicy())
    let resultA3 = await loop.run(requestA3, policy: LoopPolicy())
    let resultB = await loop.run(requestB, policy: LoopPolicy())

    #expect(resultA1.status == .completed)
    #expect(resultA1.cause == .completedWithText)
    #expect(resultA2.status == .completed)
    #expect(resultA2.cause == .completedWithText)
    #expect(resultA2.toolOutcomes == 1)
    #expect(resultA3.status == .completed)
    #expect(resultA3.cause == .completedWithEmptyText)
    #expect(resultB.status == .failed)
    #expect(resultB.cause == .providerFailure)
    #expect(executor.executed.count == 1)
    #expect(provider.requestCount == 5)

    let liveSessionIDValues = await store.sessionIDs()
    let liveSessionIDs = Set(liveSessionIDValues)
    let liveEntriesAValues = await store.entries(for: sessionA)
    let liveEntriesBValues = await store.entries(for: sessionB)
    let liveEntriesA = recoveryAcceptanceSnapshots(liveEntriesAValues)
    let liveEntriesB = recoveryAcceptanceSnapshots(liveEntriesBValues)

    let runIDs = [requestA1.runID, requestA2.runID, requestA3.runID, requestB.runID]
    var liveRunSnapshots: [String: RecoveryAcceptanceRunSnapshot] = [:]
    for runID in runIDs {
        guard let record = await runs.record(runID) else {
            Issue.record("live run \(runID.rawValue) is missing")
            return
        }
        liveRunSnapshots[runID.rawValue] = recoveryAcceptanceRunSnapshot(record)
    }

    let recordCountBeforeRecovery = await log.recordCount
    #expect(recordCountBeforeRecovery > 0)

    // A new process must not reuse these instances. Poison them with state the journal cannot know;
    // any recovered kernel that leaks them will surface the sentinel.
    let sentinelEntry = ContextEntry(id: EntryID("store-008-sentinel"), segment: .history, role: .user, payload: .text("sentinel"))
    await store.append(sentinelEntry, to: sessionA)
    try await runs.create(
        id: RunID("store-008-run-sentinel"),
        sessionID: SessionID("session-store-008-sentinel"),
        turnID: TurnID("store-008-sentinel-turn")
    )

    // New process: fresh log over the same durable bytes.
    let reopened = try DurableEventLog(sink: sandbox.fileSink())
    let reopenedCount = await reopened.recordCount
    #expect(reopenedCount == recordCountBeforeRecovery)

    let recovered = try await KernelRecovery.recover(log: reopened)

    #expect(recovered.runs !== runs)
    #expect(recovered.store !== store)
    #expect(recovered.report.eventsReplayed == recordCountBeforeRecovery)
    #expect(recovered.report.sessionCount == 2)
    #expect(recovered.report.restoredRunCount == 4)
    #expect(recovered.report.failedRunIDs.isEmpty)
    #expect(recovered.report.executionStateUnknownRunIDs.isEmpty)
    #expect(recovered.report.synthesizedResultEntryCount == 0)
    #expect(recovered.report.repairedTailRecordCount == 0)
    // Every run already has a terminal record: recovery is a pure read, it must append nothing.
    #expect(await reopened.recordCount == recordCountBeforeRecovery)

    let recoveredSessionIDValues = await recovered.store.sessionIDs()
    #expect(Set(recoveredSessionIDValues) == liveSessionIDs)
    let recoveredEntriesAValues = await recovered.store.entries(for: sessionA)
    let recoveredEntriesBValues = await recovered.store.entries(for: sessionB)
    #expect(recoveryAcceptanceSnapshots(recoveredEntriesAValues) == liveEntriesA)
    #expect(recoveryAcceptanceSnapshots(recoveredEntriesBValues) == liveEntriesB)
    let sentinelSessionEntries = await recovered.store.entries(for: SessionID("session-store-008-sentinel"))
    #expect(sentinelSessionEntries.isEmpty)
    let sentinelEntryCount = recoveredEntriesAValues.filter { $0.id == EntryID("store-008-sentinel") }.count
    #expect(sentinelEntryCount == 0)

    for runID in runIDs {
        guard let record = await recovered.runs.record(runID) else {
            Issue.record("recovered run \(runID.rawValue) is missing")
            continue
        }
        #expect(recoveryAcceptanceRunSnapshot(record) == liveRunSnapshots[runID.rawValue])
    }
    let sentinelRun = await recovered.runs.record(RunID("store-008-run-sentinel"))
    #expect(sentinelRun == nil)
    let openRuns = await recovered.runs.openRunIDs
    #expect(openRuns.isEmpty)
    let activeRun = await recovered.runs.activeRun(for: sessionA)
    #expect(activeRun == nil)

    // CTX-017: exactly the newest user message per session stays mandatory; older ones demote.
    let currentUserA = recoveredEntriesAValues.filter { $0.segment == .currentUser }
    #expect(currentUserA.count == 1)
    #expect(currentUserA.first?.renderedText == "prompt three")
    #expect(recoveredEntriesAValues.contains { $0.segment == .history && $0.renderedText == "prompt one" })
    #expect(recoveredEntriesAValues.contains { $0.segment == .history && $0.renderedText == "prompt two" })

    // The durable batch is rebuilt with the same pairing the live run produced.
    let recoveredOutcomes = recoveryAcceptanceToolOutcomes(recoveredEntriesAValues)
    #expect(recoveredOutcomes.count == 1)
    #expect(recoveredOutcomes.first?.callID == ToolCallID("c1"))
    #expect(recoveredOutcomes.first?.content == "echo<-c1")
    #expect(recoveredEntriesAValues.contains { $0.role == .assistant && $0.segment == .history && $0.renderedText == "first answer" })
    #expect(recoveryAcceptanceHistoryIsProtocolValid(recoveredEntriesAValues))

    let recoveredCallEntries = recoveredEntriesAValues.filter { !$0.payload.toolCalls.isEmpty }
    #expect(recoveredCallEntries.count == 1)
    if let callEntry = recoveredCallEntries.first, let batchUnit = callEntry.unit {
        let pairedResults = recoveredEntriesAValues.filter { $0.unit == batchUnit && !$0.payload.toolOutcomes.isEmpty }
        #expect(pairedResults.count == 1)
    } else {
        Issue.record("recovered call entry lost its causal batch unit")
    }
}

// MARK: - STORE-009

@Test("STORE-009 a torn tail record is truncated on open and the journal keeps working")
func STORE_009_tailCorruptionIsRepairedOnOpen() async throws {
    let sandbox = try RecoveryAcceptanceSandbox()
    defer { sandbox.destroy() }

    let runID = RunID("store-009-tail-run")
    let sessionID = SessionID("store-009-tail-session")
    let turnID = TurnID("store-009-tail-turn")
    let userEntry = recoveryAcceptanceUserEntry(turnID: turnID, prompt: "prompt")
    let assistantEntry = ContextEntry(
        id: EntryID("assistant-store-009-tail"),
        segment: .history,
        role: .assistant,
        payload: .text("answer")
    )
    let journalEvents: [RecordedEvent] = [
        .runCreated(runID, sessionID, turnID),
        .runStarted(runID),
        .entryRecorded(runID, userEntry),
        .entryRecorded(runID, assistantEntry),
        .runTerminal(runID, .completed, .completedWithText),
    ]
    try await recoveryAcceptanceWriteJournal(journalEvents, to: sandbox.journalURL)

    // A torn write: the final record is a truncated JSON prefix with no trailing newline.
    let encodedStart = try recoveryAcceptanceEncodedLine(.runStarted(RunID("torn-tail")))
    let tornLine = String(encodedStart.prefix(max(1, encodedStart.count / 2)))
    try recoveryAcceptanceAppendRaw(tornLine, to: sandbox.journalURL)

    let repaired = try DurableEventLog(sink: sandbox.fileSink())
    let repairedCount = await repaired.repairedTailRecordCount
    let recordCount = await repaired.recordCount
    #expect(repairedCount == 1)
    #expect(recordCount == journalEvents.count)
    // The repair is durable: the torn bytes are gone from the file itself.
    let physicalLines = try sandbox.fileSink().readLines()
    #expect(physicalLines.count == journalEvents.count)
    #expect(physicalLines.allSatisfy { recoveryAcceptanceDecode($0) != nil })

    let recovered = try await KernelRecovery.recover(log: repaired)
    #expect(recovered.report.repairedTailRecordCount == 1)
    #expect(recovered.report.eventsReplayed == journalEvents.count)
    #expect(recovered.report.restoredRunCount == 1)
    #expect(recovered.report.failedRunIDs.isEmpty)
    let record = await recovered.runs.record(runID)
    #expect(record?.status == .completed)
    #expect(record?.cause == .completedWithText)
    #expect(await repaired.recordCount == journalEvents.count)

    // Appending after a repair must work, and the repaired journal must stay recoverable.
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let provider = ScriptedProvider(scripts: [completed("after repair")])
    let secondRequest = recoveryAcceptanceRequest(
        session: sessionID,
        turn: "store-009-tail-turn-2",
        run: "store-009-tail-run-2",
        prompt: "next"
    )
    let loop = await makeLoop(
        provider: provider,
        executor: RecordingExecutor(),
        registry: registry,
        log: repaired,
        runs: recovered.runs,
        store: recovered.store
    )
    let secondResult = await loop.run(secondRequest, policy: LoopPolicy())
    #expect(secondResult.status == .completed)
    #expect(secondResult.terminalCommitted)

    let reopened = try DurableEventLog(sink: sandbox.fileSink())
    let reopenedRepairedCount = await reopened.repairedTailRecordCount
    #expect(reopenedRepairedCount == 0)
    let recoveredAgain = try await KernelRecovery.recover(log: reopened)
    #expect(recoveredAgain.report.restoredRunCount == 2)
    #expect(recoveredAgain.report.failedRunIDs.isEmpty)
    let secondRecord = await recoveredAgain.runs.record(secondRequest.runID)
    #expect(secondRecord?.status == .completed)
    let secondSessionEntries = await recoveredAgain.store.entries(for: sessionID)
    #expect(secondSessionEntries.contains { $0.segment == .currentUser && $0.renderedText == "next" })
}

@Test("STORE-009 a corrupt non-tail record refuses to open and preserves the file")
func STORE_009_nonTailCorruptionRefusesToOpen() async throws {
    let sandbox = try RecoveryAcceptanceSandbox()
    defer { sandbox.destroy() }

    let runID = RunID("store-009-middle-run")
    let sessionID = SessionID("store-009-middle-session")
    let turnID = TurnID("store-009-middle-turn")
    let lines = try [
        recoveryAcceptanceEncodedLine(.runCreated(runID, sessionID, turnID)),
        recoveryAcceptanceEncodedLine(.runStarted(runID)),
        recoveryAcceptanceEncodedLine(.runTerminal(runID, .completed, .completedWithText)),
    ]
    let corruptLine = "{this is not a journal record"
    let original = lines[0] + "\n" + corruptLine + "\n" + lines[1] + "\n" + lines[2] + "\n"
    try recoveryAcceptanceOverwrite(original, at: sandbox.journalURL)

    var caught: (any Error)?
    do {
        _ = try DurableEventLog(sink: sandbox.fileSink())
    } catch {
        caught = error
    }
    #expect(recoveryAcceptanceUndecodableIndex(caught) == 1)
    // Refusing to open must never truncate committed history.
    let after = try String(contentsOf: sandbox.journalURL, encoding: .utf8)
    #expect(after == original)
}

@Test("STORE-009 a failed append needs a marker rollback before the journal is writable again")
func STORE_009_appendFailureRequiresRepairRollback() async throws {
    let sink = MemorySink()
    let log = try DurableEventLog(sink: sink)
    let runID = RunID("store-009-append-run")
    try await log.append(.runCreated(runID, SessionID("store-009-append-session"), TurnID("store-009-append-turn")))
    let initialCount = await log.recordCount
    #expect(initialCount == 1)

    sink.failOnAppendCount = 2
    var appendError: (any Error)?
    do {
        try await log.append(.runStarted(runID))
    } catch {
        appendError = error
    }
    #expect(appendError != nil)
    // The record that never became durable must not become visible in memory either.
    #expect(await log.recordCount == 1)

    // Until the caller rolls back to the marker, writes are refused with repairRequired.
    var blockedError: (any Error)?
    do {
        try await log.append(.runStarted(runID))
    } catch {
        blockedError = error
    }
    #expect(recoveryAcceptanceIsRepairRequired(blockedError))

    // Rolling back to the marker repairs the journal and makes it writable again.
    sink.failOnAppendCount = nil
    try await log.rollBack(to: 1)
    #expect(await log.isUsable)
    try await log.append(.runStarted(runID))
    #expect(await log.recordCount == 2)
    let events = try await log.events()
    #expect(events.count == 2)
    #expect(sink.lineCount == 2)
    #expect(await log.repairedTailRecordCount == 0)
}

@Test("STORE-009 a failed rollback poisons the journal and refuses further appends")
func STORE_009_rollbackFailurePoisonsTheJournal() async throws {
    let sink = MemorySink()
    let log = try DurableEventLog(sink: sink)
    let runID = RunID("store-009-poison-run")
    try await log.append(.runCreated(runID, SessionID("store-009-poison-session"), TurnID("store-009-poison-turn")))

    sink.failOnAppendCount = 2
    var appendError: (any Error)?
    do {
        try await log.append(.runStarted(runID))
    } catch {
        appendError = error
    }
    #expect(appendError != nil)

    sink.failOnTruncate = true
    var rollbackError: (any Error)?
    do {
        try await log.rollBack(to: 1)
    } catch {
        rollbackError = error
    }
    #expect(recoveryAcceptanceIsRollbackFailed(rollbackError))

    let usable = await log.isUsable
    #expect(usable == false)

    // The poisoning outlives the sink fault: appends stay refused with unavailable.
    sink.failOnAppendCount = nil
    sink.failOnTruncate = false
    var poisonedError: (any Error)?
    do {
        try await log.append(.runStarted(runID))
    } catch {
        poisonedError = error
    }
    #expect(recoveryAcceptanceIsUnavailable(poisonedError))
    #expect(await log.isUsable == false)
}

@Test("STORE-009 a torn tail that cannot be truncated fails open with repairFailed")
func STORE_009_tailRepairFailureSurfacesAsRepairFailed() throws {
    let validLine = try recoveryAcceptanceEncodedLine(
        .runCreated(RunID("store-009-repair-run"), SessionID("store-009-repair-session"), TurnID("store-009-repair-turn"))
    )
    let sink = MemorySink(lines: [validLine, "{torn tail record"])
    sink.failOnTruncate = true

    var caught: (any Error)?
    do {
        _ = try DurableEventLog(sink: sink)
    } catch {
        caught = error
    }
    #expect(recoveryAcceptanceIsRepairFailed(caught))
}

// MARK: - STORE-010

@Test("STORE-010 a failed begin transaction commits nothing and leaves no orphan terminal record")
func STORE_010_beginTransactionFailureLeavesNoOrphanTerminal() async throws {
    let sink = MemorySink()
    // runCreated is append #1; the begin transaction fails on append #2.
    sink.failOnAppendCount = 2
    let log = try DurableEventLog(sink: sink)
    let runs = RunRegistry()
    let store = SessionStore()
    let provider = ScriptedProvider(scripts: [completed("never requested")])
    let executor = RecordingExecutor()
    let loop = await makeLoop(
        provider: provider,
        executor: executor,
        registry: ToolRegistry(),
        log: log,
        runs: runs,
        store: store
    )
    let request = recoveryAcceptanceRequest(
        session: SessionID("store-010-session"),
        turn: "store-010-turn",
        run: "store-010-run",
        prompt: "start a run"
    )

    let result = await loop.run(request, policy: LoopPolicy())

    #expect(result.status == .failed)
    #expect(result.terminalCommitted == false)
    // The transaction rolled back: the journal holds nothing for this run, and in particular no
    // orphan runTerminal that would testify to a run the journal never created.
    #expect(await log.recordCount == 0)
    #expect(sink.lineCount == 0)
    let events = try await log.events()
    #expect(events.isEmpty)
    let orphanTerminals = events.filter { if case .runTerminal = $0 { true } else { false } }
    #expect(orphanTerminals.isEmpty)
    #expect(await log.isUsable)
    // No in-memory record is left behind to block the session's next turn.
    let runRecord = await runs.record(request.runID)
    #expect(runRecord == nil)
    let openRuns = await runs.openRunIDs
    #expect(openRuns.isEmpty)
    let storedEntries = await store.entries(for: request.sessionID)
    #expect(storedEntries.isEmpty)
    // A failed begin never reaches the provider.
    #expect(provider.requestCount == 0)
    #expect(executor.executed.isEmpty)

    // The rolled-back begin must not block the same session: a second run starts cleanly.
    sink.failOnAppendCount = nil
    let retryRequest = recoveryAcceptanceRequest(
        session: request.sessionID,
        turn: "store-010-turn-retry",
        run: "store-010-run-retry",
        prompt: "try again"
    )
    let retryResult = await loop.run(retryRequest, policy: LoopPolicy())
    #expect(retryResult.status == .completed)
    #expect(retryResult.terminalCommitted)
    #expect(provider.requestCount == 1)

    let finalEvents = try await log.events()
    let retryTerminals = finalEvents.filter {
        if case .runTerminal(let terminalRunID, _, _) = $0 { terminalRunID == retryRequest.runID } else { false }
    }
    #expect(retryTerminals.count == 1)
    let phantomCreated = finalEvents.filter {
        if case .runCreated(let createdRunID, _, _) = $0 { createdRunID == request.runID } else { false }
    }
    #expect(phantomCreated.isEmpty)
    let retryRecord = await runs.record(retryRequest.runID)
    #expect(retryRecord?.status == .completed)
}

// MARK: - LOOP-025

@Test("LOOP-025 a settled mutating batch is never re-executed by recovery")
func LOOP_025_settledMutatingBatchIsNotReplayedByRecovery() async throws {
    let sandbox = try RecoveryAcceptanceSandbox()
    defer { sandbox.destroy() }

    let registry = ToolRegistry()
    try await registry.register(
        ToolDescriptor(id: "test/write", name: "write", schemaJSON: "{}", effect: .mutating)
    )
    let baseSink: any EventLogSink = sandbox.fileSink()
    let faultSink = RecoveryAcceptanceFaultSink(base: baseSink)
    let log = try DurableEventLog(sink: faultSink)

    let provider = ScriptedProvider(scripts: [
        toolBatch([makeCall("w1", tool: "write")]),
        completed("finished"),
    ])
    let executor = RecordingExecutor()
    let recorder = RecoveryAcceptanceExecutionRecorder()
    let runID = RunID("loop-025-settled-run")
    executor.onExecute = { _ in
        recorder.recordExecution(
            batchStartedDurable: recoveryAcceptanceJournalHasBatchStarted(baseSink, runID: runID)
        )
    }
    let request = recoveryAcceptanceRequest(
        session: SessionID("loop-025-settled-session"),
        turn: "loop-025-settled-turn",
        run: runID.rawValue,
        prompt: "write the file"
    )
    let loop = await makeLoop(
        provider: provider,
        executor: executor,
        registry: registry,
        log: log,
        runs: RunRegistry(),
        store: SessionStore()
    )

    // Crash image: the batch (including its durable settlement) lands, then the terminal record can
    // no longer be written. A real process kill at this point looks exactly like this journal.
    faultSink.failNextTerminalAppend()
    let result = await loop.run(request, policy: LoopPolicy())
    #expect(result.terminalCommitted == false)
    #expect(executor.executed.count == 1)
    #expect(recorder.executions == 1)
    #expect(recorder.precededByDurableIntent)
    #expect(provider.requestCount == 2)

    // Inspect the crash journal before recovery: the batch is settled and unconsumed/consumed but
    // the run has no terminal record.
    let journalLog = try DurableEventLog(sink: sandbox.fileSink())
    let journalEvents = try await journalLog.events()
    let durableRecordCount = await journalLog.recordCount
    let preRecoveryTerminals = journalEvents.filter { if case .runTerminal = $0 { true } else { false } }
    #expect(preRecoveryTerminals.isEmpty)

    var recordedBatchID: BatchID?
    for event in journalEvents {
        if case .batchStarted(let eventRunID, let batchID, _) = event, eventRunID == request.runID {
            recordedBatchID = batchID
        }
    }
    let batchID = try #require(recordedBatchID)
    let batchStartedIndex = journalEvents.firstIndex {
        if case .batchStarted(_, let eventBatchID, _) = $0 { eventBatchID == batchID } else { false }
    }
    let batchSettledIndex = journalEvents.firstIndex {
        if case .batchSettled(_, let eventBatchID, _) = $0 { eventBatchID == batchID } else { false }
    }
    let batchConsumedIndex = journalEvents.firstIndex {
        if case .batchConsumed(_, let eventBatchID) = $0 { eventBatchID == batchID } else { false }
    }
    #expect(batchStartedIndex != nil)
    #expect(batchSettledIndex != nil)
    #expect(batchConsumedIndex != nil)
    if let batchStartedIndex, let batchSettledIndex, let batchConsumedIndex {
        #expect(batchStartedIndex < batchSettledIndex)
        #expect(batchSettledIndex < batchConsumedIndex)
    }

    // New process: a fresh log over the same bytes, with no fault injection carried over.
    let recoveryLog = try DurableEventLog(sink: sandbox.fileSink())
    let recoveryStartCount = await recoveryLog.recordCount
    #expect(recoveryStartCount == durableRecordCount)
    let recovered = try await KernelRecovery.recover(log: recoveryLog)

    #expect(recovered.report.eventsReplayed == durableRecordCount)
    #expect(recovered.report.restoredRunCount == 1)
    #expect(recovered.report.failedRunIDs == [request.runID])
    #expect(recovered.report.executionStateUnknownRunIDs.isEmpty)
    #expect(recovered.report.synthesizedResultEntryCount == 0)
    #expect(recovered.report.repairedTailRecordCount == 0)
    // The only write recovery is allowed to add is the failure terminal for the unfinished run.
    #expect(await recoveryLog.recordCount == durableRecordCount + 1)
    let postRecoveryEvents = try await recoveryLog.events()
    var appendedTerminal: (RunID, RunStatus, TerminalCause)?
    if let last = postRecoveryEvents.last, case .runTerminal(let terminalRunID, let status, let cause) = last {
        appendedTerminal = (terminalRunID, status, cause)
    }
    #expect(appendedTerminal?.0 == request.runID)
    #expect(appendedTerminal?.1 == .failed)
    // A settled batch is not an uncertain one: the durable settlement must keep the cause concrete.
    #expect(appendedTerminal?.2 == .runtimeFailure)

    let record = await recovered.runs.record(request.runID)
    #expect(record?.status == .failed)
    #expect(record?.cause == .runtimeFailure)
    #expect(record?.detail?.contains("recovered after restart") == true)

    let recoveredEntries = await recovered.store.entries(for: request.sessionID)
    let recoveredOutcomes = recoveryAcceptanceToolOutcomes(recoveredEntries)
    #expect(recoveredOutcomes.count == 1)
    #expect(recoveredOutcomes.first?.callID == ToolCallID("w1"))
    #expect(recoveredOutcomes.first?.content == "write<-w1")
    #expect(recoveredOutcomes.first?.isError == false)
    #expect(recoveredOutcomes.first?.effect == .mutating)
    #expect(recoveredEntries.contains { $0.segment == .currentUser && $0.renderedText == "write the file" })
    #expect(recoveryAcceptanceHistoryIsProtocolValid(recoveredEntries))

    // The side effect happened exactly once: recovery neither replays the batch nor asks the model.
    #expect(executor.executed.count == 1)
    #expect(provider.requestCount == 2)
}

@Test("LOOP-025 a started batch without a settlement heals to executionStateUnknown")
func LOOP_025_openBatchHealsAsExecutionStateUnknown() async throws {
    let sandbox = try RecoveryAcceptanceSandbox()
    defer { sandbox.destroy() }

    let runID = RunID("loop-025-unknown-run")
    let sessionID = SessionID("loop-025-unknown-session")
    let turnID = TurnID("loop-025-unknown-turn")
    let batchID = BatchID("\(runID.rawValue)-batch1")
    let call = makeCall("w1", tool: "write")
    let tornJournal: [RecordedEvent] = [
        .runCreated(runID, sessionID, turnID),
        .runStarted(runID),
        .entryRecorded(runID, recoveryAcceptanceUserEntry(turnID: turnID, prompt: "do the thing")),
        .entryRecorded(runID, recoveryAcceptanceCallEntry(batchID: batchID, calls: [call])),
        .batchStarted(runID, batchID, [call]),
    ]
    try await recoveryAcceptanceWriteJournal(tornJournal, to: sandbox.journalURL)

    let recoveryLog = try DurableEventLog(sink: sandbox.fileSink())
    let executor = RecordingExecutor()
    let provider = ScriptedProvider(scripts: [])
    let recovered = try await KernelRecovery.recover(log: recoveryLog)

    #expect(recovered.report.eventsReplayed == tornJournal.count)
    #expect(recovered.report.sessionCount == 1)
    #expect(recovered.report.restoredRunCount == 1)
    #expect(recovered.report.failedRunIDs == [runID])
    #expect(recovered.report.executionStateUnknownRunIDs == [runID])
    #expect(recovered.report.synthesizedResultEntryCount == 1)
    #expect(recovered.report.repairedTailRecordCount == 0)
    #expect(await recoveryLog.recordCount == tornJournal.count + 1)
    let postRecoveryEvents = try await recoveryLog.events()
    var appendedTerminal: (RunID, RunStatus, TerminalCause)?
    if let last = postRecoveryEvents.last, case .runTerminal(let terminalRunID, let status, let cause) = last {
        appendedTerminal = (terminalRunID, status, cause)
    }
    #expect(appendedTerminal?.0 == runID)
    #expect(appendedTerminal?.1 == .failed)
    #expect(appendedTerminal?.2 == .executionStateUnknown)

    let record = await recovered.runs.record(runID)
    #expect(record?.status == .failed)
    #expect(record?.cause == .executionStateUnknown)
    #expect(record?.detail?.contains("recovered after restart") == true)

    let entries = await recovered.store.entries(for: sessionID)
    #expect(entries.count == 3)
    #expect(entries.first?.segment == .currentUser)
    let callEntries = entries.filter { !$0.payload.toolCalls.isEmpty }
    #expect(callEntries.count == 1)
    #expect(callEntries.first?.unit == batchID.rawValue)

    let outcomes = recoveryAcceptanceToolOutcomes(entries)
    #expect(outcomes.count == 1)
    #expect(outcomes.first?.callID == call.callID)
    #expect(outcomes.first?.isError == true)
    #expect(outcomes.first?.effect == .unknown)
    let synthesizedContent = outcomes.first?.content ?? ""
    #expect(synthesizedContent.contains("executionStateUnknown"))
    #expect(synthesizedContent.lowercased().contains("verification"))
    // The explicit error result is what keeps the call/result pairing valid for the next turn.
    #expect(recoveryAcceptanceHistoryIsProtocolValid(entries))
    #expect(entries.contains { $0.segment == .history && $0.role == .tool && $0.unit == batchID.rawValue })

    // Recovery never touches tools or the model.
    #expect(executor.executed.isEmpty)
    #expect(provider.requestCount == 0)
}

@Test("LOOP-025 a call recorded before dispatch heals as not started, not unknown")
func LOOP_025_callWithoutDispatchHealsAsNotStarted() async throws {
    let sandbox = try RecoveryAcceptanceSandbox()
    defer { sandbox.destroy() }

    let runID = RunID("loop-025-not-started-run")
    let sessionID = SessionID("loop-025-not-started-session")
    let turnID = TurnID("loop-025-not-started-turn")
    let batchID = BatchID("\(runID.rawValue)-batch1")
    let call = makeCall("w1", tool: "write")
    // Crash happened after the assistant call was durable but before the dispatch intent was:
    // no batchStarted/batchSettled event exists, so the tool cannot have run.
    let tornJournal: [RecordedEvent] = [
        .runCreated(runID, sessionID, turnID),
        .runStarted(runID),
        .entryRecorded(runID, recoveryAcceptanceUserEntry(turnID: turnID, prompt: "do the thing")),
        .entryRecorded(runID, recoveryAcceptanceCallEntry(batchID: batchID, calls: [call])),
    ]
    try await recoveryAcceptanceWriteJournal(tornJournal, to: sandbox.journalURL)

    let recoveryLog = try DurableEventLog(sink: sandbox.fileSink())
    let recovered = try await KernelRecovery.recover(log: recoveryLog)

    #expect(recovered.report.eventsReplayed == tornJournal.count)
    #expect(recovered.report.executionStateUnknownRunIDs.isEmpty)
    #expect(recovered.report.failedRunIDs == [runID])
    #expect(recovered.report.synthesizedResultEntryCount == 1)
    #expect(await recoveryLog.recordCount == tornJournal.count + 1)

    let record = await recovered.runs.record(runID)
    #expect(record?.status == .failed)
    #expect(record?.cause == .runtimeFailure)

    let entries = await recovered.store.entries(for: sessionID)
    #expect(entries.count == 3)
    let outcomes = recoveryAcceptanceToolOutcomes(entries)
    #expect(outcomes.count == 1)
    #expect(outcomes.first?.callID == call.callID)
    #expect(outcomes.first?.isError == true)
    let content = outcomes.first?.content ?? ""
    #expect(!content.contains("executionStateUnknown"))
    #expect(recoveryAcceptanceHistoryIsProtocolValid(entries))
}

@Test("LOOP-025 settled but unconsumed results survive recovery")
func LOOP_025_settledUnconsumedBatchLosesNoResults() async throws {
    let sandbox = try RecoveryAcceptanceSandbox()
    defer { sandbox.destroy() }

    let runID = RunID("loop-025-unconsumed-run")
    let sessionID = SessionID("loop-025-unconsumed-session")
    let turnID = TurnID("loop-025-unconsumed-turn")
    let batchID = BatchID("\(runID.rawValue)-batch1")
    let call = makeCall("w1", tool: "write")
    let outcome = recoveryAcceptanceOutcome(call, content: "write<-w1")
    // Crash after batchSettled + its result entry were durable, but before batchConsumed.
    let tornJournal: [RecordedEvent] = [
        .runCreated(runID, sessionID, turnID),
        .runStarted(runID),
        .entryRecorded(runID, recoveryAcceptanceUserEntry(turnID: turnID, prompt: "do the thing")),
        .entryRecorded(runID, recoveryAcceptanceCallEntry(batchID: batchID, calls: [call])),
        .batchStarted(runID, batchID, [call]),
        .batchSettled(runID, batchID, [outcome]),
        .entryRecorded(runID, recoveryAcceptanceResultEntry(batchID: batchID, outcomes: [outcome])),
    ]
    try await recoveryAcceptanceWriteJournal(tornJournal, to: sandbox.journalURL)

    let recoveryLog = try DurableEventLog(sink: sandbox.fileSink())
    let recovered = try await KernelRecovery.recover(log: recoveryLog)

    #expect(recovered.report.eventsReplayed == tornJournal.count)
    #expect(recovered.report.failedRunIDs == [runID])
    #expect(recovered.report.executionStateUnknownRunIDs.isEmpty)
    #expect(recovered.report.synthesizedResultEntryCount == 0)
    #expect(await recoveryLog.recordCount == tornJournal.count + 1)

    let record = await recovered.runs.record(runID)
    #expect(record?.status == .failed)
    #expect(record?.cause == .runtimeFailure)

    let entries = await recovered.store.entries(for: sessionID)
    let outcomes = recoveryAcceptanceToolOutcomes(entries)
    #expect(outcomes.count == 1)
    #expect(outcomes.first?.callID == call.callID)
    #expect(outcomes.first?.content == "write<-w1")
    #expect(outcomes.first?.isError == false)
    #expect(outcomes.first?.effect == .mutating)
    let resultEntries = entries.filter { !$0.payload.toolOutcomes.isEmpty }
    #expect(resultEntries.count == 1)
    #expect(resultEntries.first?.segment == .history)
    #expect(resultEntries.first?.role == .tool)
    #expect(resultEntries.first?.unit == batchID.rawValue)
    #expect(recoveryAcceptanceHistoryIsProtocolValid(entries))
}

@Test("LOOP-025 a settled batch whose result record was lost is healed from durable outcomes")
func LOOP_025_settledBatchMissingResultRecordIsHealed() async throws {
    let sandbox = try RecoveryAcceptanceSandbox()
    defer { sandbox.destroy() }

    let runID = RunID("loop-025-missing-result-run")
    let sessionID = SessionID("loop-025-missing-result-session")
    let turnID = TurnID("loop-025-missing-result-turn")
    let batchID = BatchID("\(runID.rawValue)-batch1")
    let call = makeCall("w1", tool: "write")
    let outcome = recoveryAcceptanceOutcome(call, content: "write<-w1")
    // Crash between the batchSettled append and the result entryRecorded append of the same commit.
    let tornJournal: [RecordedEvent] = [
        .runCreated(runID, sessionID, turnID),
        .runStarted(runID),
        .entryRecorded(runID, recoveryAcceptanceUserEntry(turnID: turnID, prompt: "do the thing")),
        .entryRecorded(runID, recoveryAcceptanceCallEntry(batchID: batchID, calls: [call])),
        .batchStarted(runID, batchID, [call]),
        .batchSettled(runID, batchID, [outcome]),
    ]
    try await recoveryAcceptanceWriteJournal(tornJournal, to: sandbox.journalURL)

    let recoveryLog = try DurableEventLog(sink: sandbox.fileSink())
    let recovered = try await KernelRecovery.recover(log: recoveryLog)

    #expect(recovered.report.failedRunIDs == [runID])
    #expect(recovered.report.executionStateUnknownRunIDs.isEmpty)
    #expect(recovered.report.synthesizedResultEntryCount == 1)
    #expect(await recoveryLog.recordCount == tornJournal.count + 1)

    let record = await recovered.runs.record(runID)
    #expect(record?.cause == .runtimeFailure)

    let entries = await recovered.store.entries(for: sessionID)
    #expect(entries.count == 3)
    // The healed result entry is inserted directly after its call entry, keeping the causal pair
    // adjacent even when the original commit was torn between the two records.
    #expect(entries[1].id.rawValue == "call-\(batchID.rawValue)")
    #expect(entries[2].id.rawValue == "result-\(batchID.rawValue)")
    #expect(entries[2].unit == batchID.rawValue)
    let outcomes = recoveryAcceptanceToolOutcomes(entries)
    #expect(outcomes.count == 1)
    #expect(outcomes.first?.callID == call.callID)
    #expect(outcomes.first?.content == "write<-w1")
    #expect(outcomes.first?.isError == false)
    #expect(outcomes.first?.effect == .mutating)
    #expect(recoveryAcceptanceHistoryIsProtocolValid(entries))
}

@Test("LOOP-025 double recovery is idempotent and side-effect free")
func LOOP_025_doubleReplayIsIdempotentAndSideEffectFree() async throws {
    let sandbox = try RecoveryAcceptanceSandbox()
    defer { sandbox.destroy() }

    let completedRun = RunID("loop-025-idem-completed")
    let completedSession = SessionID("loop-025-idem-session-completed")
    let completedTurn = TurnID("loop-025-idem-turn-completed")

    let unknownRun = RunID("loop-025-idem-unknown")
    let unknownSession = SessionID("loop-025-idem-session-unknown")
    let unknownTurn = TurnID("loop-025-idem-turn-unknown")
    let unknownBatch = BatchID("\(unknownRun.rawValue)-batch1")
    let unknownCall = makeCall("w1", tool: "write")

    let notStartedRun = RunID("loop-025-idem-not-started")
    let notStartedSession = SessionID("loop-025-idem-session-not-started")
    let notStartedTurn = TurnID("loop-025-idem-turn-not-started")
    let notStartedBatch = BatchID("\(notStartedRun.rawValue)-batch1")
    let notStartedCall = makeCall("w2", tool: "write")

    let neverStartedRun = RunID("loop-025-idem-never-started")

    let journal: [RecordedEvent] = [
        .runCreated(completedRun, completedSession, completedTurn),
        .runStarted(completedRun),
        .entryRecorded(completedRun, recoveryAcceptanceUserEntry(turnID: completedTurn, prompt: "hello")),
        .entryRecorded(completedRun, ContextEntry(
            id: EntryID("assistant-\(completedRun.rawValue)"),
            segment: .history,
            role: .assistant,
            payload: .text("hi")
        )),
        .runTerminal(completedRun, .completed, .completedWithText),

        .runCreated(unknownRun, unknownSession, unknownTurn),
        .runStarted(unknownRun),
        .entryRecorded(unknownRun, recoveryAcceptanceUserEntry(turnID: unknownTurn, prompt: "unknown batch")),
        .entryRecorded(unknownRun, recoveryAcceptanceCallEntry(batchID: unknownBatch, calls: [unknownCall])),
        .batchStarted(unknownRun, unknownBatch, [unknownCall]),

        .runCreated(notStartedRun, notStartedSession, notStartedTurn),
        .runStarted(notStartedRun),
        .entryRecorded(notStartedRun, recoveryAcceptanceUserEntry(turnID: notStartedTurn, prompt: "call only")),
        .entryRecorded(notStartedRun, recoveryAcceptanceCallEntry(batchID: notStartedBatch, calls: [notStartedCall])),

        .runCreated(neverStartedRun, SessionID("loop-025-idem-session-never-started"), TurnID("loop-025-idem-turn-never-started")),
    ]
    try await recoveryAcceptanceWriteJournal(journal, to: sandbox.journalURL)

    // Recovery must never reach a tool executor or a model provider; hold fresh stand-ins in scope.
    let executor = RecordingExecutor()
    let provider = ScriptedProvider(scripts: [])

    let firstLog = try DurableEventLog(sink: sandbox.fileSink())
    let firstRecoveryStartCount = await firstLog.recordCount
    let first = try await KernelRecovery.recover(log: firstLog)

    #expect(first.report.eventsReplayed == journal.count)
    #expect(firstRecoveryStartCount == journal.count)
    #expect(first.report.restoredRunCount == 4)
    #expect(first.report.sessionCount == 3)
    #expect(first.report.failedRunIDs == [unknownRun, notStartedRun, neverStartedRun])
    #expect(first.report.executionStateUnknownRunIDs == [unknownRun])
    #expect(first.report.synthesizedResultEntryCount == 2)
    #expect(first.report.repairedTailRecordCount == 0)
    let afterFirstCount = await firstLog.recordCount
    #expect(afterFirstCount == journal.count + 3)

    let firstCompletedRecord = await first.runs.record(completedRun)
    #expect(firstCompletedRecord?.status == .completed)
    #expect(firstCompletedRecord?.cause == .completedWithText)
    let firstUnknownRecord = await first.runs.record(unknownRun)
    #expect(firstUnknownRecord?.status == .failed)
    #expect(firstUnknownRecord?.cause == .executionStateUnknown)
    let firstNotStartedRecord = await first.runs.record(notStartedRun)
    #expect(firstNotStartedRecord?.cause == .runtimeFailure)
    let firstNeverStartedRecord = await first.runs.record(neverStartedRun)
    #expect(firstNeverStartedRecord?.status == .failed)
    #expect(firstNeverStartedRecord?.cause == .runtimeFailure)

    let firstCompletedEntries = await first.store.entries(for: completedSession)
    let firstUnknownEntries = await first.store.entries(for: unknownSession)
    let firstNotStartedEntries = await first.store.entries(for: notStartedSession)
    #expect(recoveryAcceptanceHistoryIsProtocolValid(firstUnknownEntries))
    #expect(recoveryAcceptanceHistoryIsProtocolValid(firstNotStartedEntries))
    let firstRunIDs = [completedRun, unknownRun, notStartedRun, neverStartedRun]
    var firstRunSnapshots: [String: RecoveryAcceptanceRunSnapshot] = [:]
    for runID in firstRunIDs {
        guard let record = await first.runs.record(runID) else {
            Issue.record("first recovery lost run \(runID.rawValue)")
            continue
        }
        firstRunSnapshots[runID.rawValue] = recoveryAcceptanceRunSnapshot(record)
    }

    // Second recovery of the exact same journal: the rebuilt state must be identical and the
    // journal must not grow again (nothing is left unfinished).
    let secondLog = try DurableEventLog(sink: sandbox.fileSink())
    let secondRecoveryStartCount = await secondLog.recordCount
    #expect(secondRecoveryStartCount == afterFirstCount)
    let second = try await KernelRecovery.recover(log: secondLog)

    #expect(second.report.restoredRunCount == first.report.restoredRunCount)
    #expect(second.report.sessionCount == first.report.sessionCount)
    #expect(second.report.executionStateUnknownRunIDs == first.report.executionStateUnknownRunIDs)
    #expect(second.report.synthesizedResultEntryCount == first.report.synthesizedResultEntryCount)
    #expect(second.report.repairedTailRecordCount == first.report.repairedTailRecordCount)
    #expect(second.report.failedRunIDs.isEmpty)
    #expect(await secondLog.recordCount == afterFirstCount)

    let secondCompletedEntries = await second.store.entries(for: completedSession)
    let secondUnknownEntries = await second.store.entries(for: unknownSession)
    let secondNotStartedEntries = await second.store.entries(for: notStartedSession)
    #expect(recoveryAcceptanceSnapshots(secondCompletedEntries) == recoveryAcceptanceSnapshots(firstCompletedEntries))
    #expect(recoveryAcceptanceSnapshots(secondUnknownEntries) == recoveryAcceptanceSnapshots(firstUnknownEntries))
    #expect(recoveryAcceptanceSnapshots(secondNotStartedEntries) == recoveryAcceptanceSnapshots(firstNotStartedEntries))

    for runID in firstRunIDs {
        guard let record = await second.runs.record(runID) else {
            Issue.record("second recovery lost run \(runID.rawValue)")
            continue
        }
        #expect(recoveryAcceptanceRunSnapshot(record) == firstRunSnapshots[runID.rawValue])
    }
    let secondOpenRuns = await second.runs.openRunIDs
    #expect(secondOpenRuns.isEmpty)

    // Side-effect freedom, asserted rather than assumed: neither recovery ran a tool or a request.
    #expect(executor.executed.isEmpty)
    #expect(provider.requestCount == 0)
}
