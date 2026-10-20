import Foundation
import LingXiKernel
import Testing

private func temporaryJournal() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lxj-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("events.jsonl")
}

private func appendRaw(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.synchronize()
}

@Test("LOOP-001 only one attempt can terminalize a run")
func LOOP_001_singleTerminalizationWinner() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let runs = RunRegistry()
    let runID = newRunID("winner")
    try await runs.create(id: runID, sessionID: "s", turnID: "t")
    try await runs.markRunning(runID)

    let first = try await runs.terminalize(runID, status: .completed, cause: .completedWithText, detail: nil, via: log)
    let second = try await runs.terminalize(runID, status: .cancelled, cause: .cancelledByUser, detail: nil, via: log)

    #expect(first)
    #expect(!second)
    #expect(try await runs.record(runID)?.status == .completed)
}

@Test("LOOP-001 concurrent terminalization attempts produce exactly one winner")
func LOOP_001_concurrentTerminalizationWinner() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let runID = newRunID("race-winner")
    let runs = RunRegistry()
    try await runs.create(id: runID, sessionID: "s", turnID: "t")
    try await runs.markRunning(runID)

    async let completed = runs.terminalize(runID, status: .completed, cause: .completedWithText, detail: nil, via: log)
    async let cancelled = runs.terminalize(runID, status: .cancelled, cause: .cancelledByUser, detail: nil, via: log)
    let outcomes = try await [completed, cancelled]

    #expect(outcomes.filter { $0 }.count == 1)
    let events = try await log.events()
    #expect(events.filter { if case .runTerminal = $0 { true } else { false } }.count == 1)
}

@Test("LOOP-002 a failed terminal write leaves the run non-terminal in memory")
func LOOP_002_terminalWriteFailureRollsBack() async throws {
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let sink = MemorySink()
    // runCreated, runStarted, user entry are the first three appends; the fourth is the terminal
    // write (the reply is empty, so no assistant entry is recorded).
    sink.failOnAppendCount = 4
    let log = try DurableEventLog(sink: sink)
    let runs = RunRegistry()
    let request = runRequest("rollback")
    let loop = await makeLoop(
        provider: ScriptedProvider(scripts: [completed("")]),
        executor: RecordingExecutor(),
        registry: registry,
        log: log,
        runs: runs
    )

    let result = await loop.run(request, policy: LoopPolicy())

    #expect(!result.terminalCommitted)
    #expect(try await runs.record(request.runID)?.status == .running)
    #expect(sink.lineCount == 3)
}

@Test("STORE-010 a failed begin transaction leaves no orphan terminal record")
func STORE_010_beginFailureLeavesNoOrphanTerminal() async throws {
    let sink = MemorySink()
    sink.failOnAppendCount = 2
    let log = try DurableEventLog(sink: sink)
    let runs = RunRegistry()
    let request = runRequest("early-fault")
    let loop = await makeLoop(provider: ScriptedProvider(scripts: [completed("x")]), executor: RecordingExecutor(), log: log, runs: runs)

    let result = await loop.run(request, policy: LoopPolicy())

    #expect(result.status == .failed)
    #expect(!result.terminalCommitted)
    #expect(result.detail?.contains("run start failed") == true)
    // The begin transaction is rolled back completely: no runCreated and, crucially, no runTerminal
    // for a run that never existed in the journal.
    #expect(sink.lineCount == 0)
    #expect(try await runs.record(request.runID) == nil)

    // The in-memory record is discarded, and the journal is still usable for the next attempt.
    sink.failOnAppendCount = nil
    let retried = await loop.run(request, policy: LoopPolicy())
    #expect(retried.status == .completed)
    #expect(retried.terminalCommitted)
    #expect(sink.lineCount == 5)
}

@Test("LOOP-003 a started run without a terminal record is failed on restart, never re-run")
func LOOP_003_crashRecovery() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let runs = RunRegistry()
    let runID = newRunID("orphan")
    try await runs.create(id: runID, sessionID: "s", turnID: "t")
    try await log.append(.runCreated(runID, "s", "t"))
    try await log.append(.runStarted(runID))
    try await runs.markRunning(runID)

    let recovered = try await runs.recoverUnfinishedRuns(via: log)

    #expect(recovered == [runID])
    #expect(try await runs.record(runID)?.status == .failed)
    #expect(try await runs.record(runID)?.cause == .runtimeFailure)
    #expect(try await runs.recoverUnfinishedRuns(via: log).isEmpty)

    let events = try await log.events()
    #expect(events.contains { if case .runTerminal = $0 { true } else { false } })
}

@Test("LOOP-004 runCreated is recorded exactly once per run")
func LOOP_004_runCreatedExactlyOnce() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let loop = await makeLoop(provider: ScriptedProvider(scripts: [completed("done")]), executor: RecordingExecutor(), log: log)

    let result = await loop.run(runRequest("created-once"), policy: LoopPolicy())
    let events = try await log.events()

    #expect(result.status == .completed)
    #expect(events.filter { if case .runCreated = $0 { true } else { false } }.count == 1)
    #expect(events.filter { if case .runTerminal = $0 { true } else { false } }.count == 1)
}

@Test("STORE-001 a journal on disk survives reopening and decodes back into the same entries")
func STORE_001_fileJournalRoundTrip() async throws {
    let url = try temporaryJournal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let sink = FileEventLogSink(url: url)

    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let store = SessionStore()
    let runs = RunRegistry()
    let provider = ScriptedProvider(scripts: [toolBatch([makeCall("c1")]), completed("done")])
    let request = runRequest("round-trip")
    let first = await makeLoop(
        provider: provider,
        executor: RecordingExecutor(),
        registry: registry,
        log: try DurableEventLog(sink: sink),
        runs: runs,
        store: store
    )

    let result = await first.run(request, policy: LoopPolicy())
    #expect(result.status == .completed)

    // Reopen the journal the way a restarted process would.
    let reopenedLog = try DurableEventLog(sink: sink)
    let events = try await reopenedLog.events()
    #expect(await reopenedLog.recordCount == events.count)

    let entries = events.compactMap { event -> ContextEntry? in
        if case .entryRecorded(_, let entry) = event { entry } else { nil }
    }
    #expect(entries.count == 4)
    let batchEntry = try #require(entries.first { !$0.payload.toolOutcomes.isEmpty })
    #expect(batchEntry.payload.toolOutcomes.map(\.content) == ["echo<-c1"])
    #expect(batchEntry.unit == "run-round-trip-batch1")
    let assistantEntry = try #require(entries.last)
    #expect(assistantEntry.renderedText == "done")
    #expect(assistantEntry.role == .assistant)

    // Nothing was left mid-flight, so a restart must not fail any run.
    let freshRuns = RunRegistry()
    #expect(try await freshRuns.recoverUnfinishedRuns(via: reopenedLog).isEmpty)
}

@Test("STORE-001 entries reach the store only after their record was written")
func STORE_001_durableBeforeMemory() async throws {
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let sink = MemorySink()
    let log = try DurableEventLog(sink: sink)
    let store = SessionStore()
    let runs = RunRegistry()
    let loop = await makeLoop(
        provider: ScriptedProvider(scripts: [toolBatch([makeCall("c1")]), completed("done")]),
        executor: RecordingExecutor(),
        registry: registry,
        log: log,
        runs: runs,
        store: store
    )

    let result = await loop.run(runRequest("persist"), policy: LoopPolicy())
    let events = try await log.events()

    #expect(result.status == .completed)
    #expect(events.count == sink.lineCount)
    let recorded = events.compactMap { event -> ContextEntry? in
        if case .entryRecorded(_, let entry) = event { entry } else { nil }
    }
    #expect(
        recorded.map(\.id.rawValue)
            == ["turn-persist", "call-run-persist-batch1", "result-run-persist-batch1", "assistant-run-persist"]
    )
    #expect(try await store.entries(for: runRequest("persist").sessionID).count == 4)
}

@Test("STORE-008 replay rebuilds fresh registries from the journal")
func STORE_008_replayRebuildsFreshObjects() async throws {
    let url = try temporaryJournal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let executor = RecordingExecutor()
    let sessionID = SessionID("session-replay")
    let request = RunRequest(
        sessionID: sessionID,
        turnID: "turn-1",
        runID: "run-replay",
        executionID: "exec-replay",
        model: "test-model",
        prompt: "prompt"
    )
    let firstProcess = await makeLoop(
        provider: ScriptedProvider(scripts: [toolBatch([makeCall("c1")]), completed("done")]),
        executor: executor,
        registry: registry,
        log: try DurableEventLog(sink: FileEventLogSink(url: url))
    )
    let result = await firstProcess.run(request, policy: LoopPolicy())
    #expect(result.status == .completed)

    // A new process: brand-new log instance, RunRegistry and SessionStore. Nothing is reused.
    let recovered = try await KernelRecovery.recover(log: try DurableEventLog(sink: FileEventLogSink(url: url)))

    #expect(recovered.report.eventsReplayed == 10)
    #expect(recovered.report.restoredRunCount == 1)
    #expect(recovered.report.failedRunIDs.isEmpty)
    #expect(recovered.report.executionStateUnknownRunIDs.isEmpty)
    #expect(recovered.report.repairedTailRecordCount == 0)
    #expect(recovered.report.sessionCount == 1)
    // Recovery is read-only with respect to side effects: the tool ran exactly once, in the first
    // process, and no model request was repeated.
    #expect(executor.executed.count == 1)

    let entries = await recovered.store.entries(for: sessionID)
    #expect(
        entries.map(\.id.rawValue)
            == ["turn-turn-1", "call-run-replay-batch1", "result-run-replay-batch1", "assistant-run-replay"]
    )
    #expect(entries.first?.segment == .currentUser)
    #expect(entries.last?.renderedText == "done")
    #expect(entries.last?.role == .assistant)

    let restoredRun = await recovered.runs.record(RunID("run-replay"))
    let runRecord = try #require(restoredRun)
    #expect(runRecord.status == .completed)
    #expect(runRecord.cause == .completedWithText)

    // Replaying again is idempotent.
    let again = try await KernelRecovery.recover(log: try DurableEventLog(sink: FileEventLogSink(url: url)))
    #expect(again.report.failedRunIDs.isEmpty)
    #expect(await again.store.entries(for: sessionID).map(\.id.rawValue) == entries.map(\.id.rawValue))
}

@Test("STORE-009 a torn journal tail is repaired on open without losing committed records")
func STORE_009_tornTailIsRepaired() async throws {
    let url = try temporaryJournal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let log = try DurableEventLog(sink: FileEventLogSink(url: url))
    try await log.append(.runCreated(RunID("run-torn"), SessionID("s"), TurnID("t")))
    try await log.append(.runStarted(RunID("run-torn")))
    // Simulate a crash halfway through writing the last record: no trailing newline.
    try appendRaw("{\"runTerminal\":{\"_0\":{\"rawValue\":\"run-torn\"}", to: url)

    let reopened = try DurableEventLog(sink: FileEventLogSink(url: url))
    #expect(await reopened.repairedTailRecordCount == 1)
    #expect(await reopened.recordCount == 2)
    #expect(try await reopened.events().count == 2)

    // The repaired journal accepts new records and is clean on the next open.
    try await reopened.append(.runTerminal(RunID("run-torn"), .failed, .runtimeFailure))
    let second = try DurableEventLog(sink: FileEventLogSink(url: url))
    #expect(await second.repairedTailRecordCount == 0)
    #expect(await second.recordCount == 3)
}

@Test("STORE-009 corruption in the middle of the journal refuses to open")
func STORE_009_middleCorruptionRefused() async throws {
    let url = try temporaryJournal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let log = try DurableEventLog(sink: FileEventLogSink(url: url))
    try await log.append(.runCreated(RunID("run-bad"), SessionID("s"), TurnID("t")))
    try appendRaw("this-is-not-a-record\n", to: url)
    try await log.append(.runStarted(RunID("run-bad")))

    do {
        _ = try DurableEventLog(sink: FileEventLogSink(url: url))
        Issue.record("a non-tail corrupt record must prevent the journal from opening")
    } catch let error as EventLogError {
        guard case .undecodableLine(let index, _) = error else {
            Issue.record("unexpected error: \(error)")
            return
        }
        #expect(index == 1)
    }
}

@Test("STORE-009 an append failure requires a rollback and leaves the journal usable")
func STORE_009_appendFailureRequiresRollback() async throws {
    let sink = MemorySink()
    sink.failOnAppendCount = 2
    let log = try DurableEventLog(sink: sink)
    try await log.append(.runStarted(RunID("a")))
    let marker = await log.beginMarker()

    do {
        try await log.append(.runStarted(RunID("b")))
        Issue.record("expected the injected append failure")
    } catch {
        // expected
    }
    do {
        try await log.append(.runStarted(RunID("c")))
        Issue.record("a failed append must require a rollback before more writes")
    } catch let error as EventLogError {
        guard case .repairRequired = error else {
            Issue.record("unexpected error: \(error)")
            return
        }
    }

    sink.failOnAppendCount = nil
    try await log.rollBack(to: marker)
    #expect(await log.recordCount == 1)
    try await log.append(.runStarted(RunID("c")))
    #expect(await log.recordCount == 2)
}

@Test("STORE-009 a failed rollback poisons the journal instead of pretending to recover")
func STORE_009_rollbackFailurePoisonsJournal() async throws {
    let sink = MemorySink()
    let log = try DurableEventLog(sink: sink)
    let marker = await log.beginMarker()
    try await log.append(.runStarted(RunID("a")))
    sink.failOnTruncate = true

    do {
        try await log.rollBack(to: marker)
        Issue.record("expected the injected rollback failure")
    } catch let error as EventLogError {
        guard case .rollbackFailed = error else {
            Issue.record("unexpected error: \(error)")
            return
        }
    }
    #expect(await log.isUsable == false)

    do {
        try await log.append(.runStarted(RunID("b")))
        Issue.record("a poisoned journal must reject writes")
    } catch let error as EventLogError {
        guard case .unavailable = error else {
            Issue.record("unexpected error: \(error)")
            return
        }
    }
}

@Test("LOOP-025 recovery never replays an uncertain tool batch")
func LOOP_025_recoveryNeverReplaysUnknownBatch() async throws {
    let url = try temporaryJournal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let executor = GatingExecutor()
    let request = runRequest("unknown")
    let loop = await makeLoop(
        provider: ScriptedProvider(scripts: [toolBatch([makeCall("c1")])]),
        executor: executor,
        registry: registry,
        log: try DurableEventLog(sink: FileEventLogSink(url: url))
    )

    let task = Task { await loop.run(request, policy: LoopPolicy()) }
    #expect(await executor.arrivalGate.wait())
    // The side effect landed and `batchStarted` is durable; the crash is simulated by rebuilding
    // all memory from the journal on disk.
    #expect(executor.executedCount == 1)

    let recovered = try await KernelRecovery.recover(log: try DurableEventLog(sink: FileEventLogSink(url: url)))

    #expect(recovered.report.executionStateUnknownRunIDs == [request.runID])
    #expect(recovered.report.failedRunIDs == [request.runID])
    #expect(executor.executedCount == 1, "recovery must never re-run a tool")

    let restoredRun = await recovered.runs.record(request.runID)
    let record = try #require(restoredRun)
    #expect(record.status == .failed)
    #expect(record.cause == .executionStateUnknown)
    #expect(record.detail?.contains("executionStateUnknown") == true)

    let entries = await recovered.store.entries(for: request.sessionID)
    let resultEntry = try #require(entries.first { $0.id.rawValue == "result-run-unknown-batch1" })
    #expect(resultEntry.role == .tool)
    #expect(resultEntry.renderedText.contains("executionStateUnknown"))
    // The repaired history is a valid request payload again (call + error result pair).
    try ContextRequestValidator.validate(
        [ContextEntry(id: "instructions", segment: .immutableInstructions, role: .system, payload: .text("sys"))] + entries,
        placement: .anywhereInHistory
    )

    // Unblock and stop the "crashed" run so the test leaves no dangling task behind.
    executor.proceedGate.fire()
    task.cancel()
    _ = await task.value
}
