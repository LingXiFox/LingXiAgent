import Foundation
import LingXiKernel
import Testing

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

@Test("LOOP-002 a failed terminal write leaves the run non-terminal in memory")
func LOOP_002_terminalWriteFailureRollsBack() async throws {
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let sink = MemorySink()
    // runCreated, runStarted, user entry are the first three appends; the fourth is the terminal.
    sink.failOnAppendCount = 4
    let log = try DurableEventLog(sink: sink)
    let runs = RunRegistry()
    let request = runRequest("rollback")
    let loop = await makeLoop(
        provider: ScriptedProvider(scripts: [completed("done")]),
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

@Test("LOOP-002 every record of a half-written commit is truncated")
func LOOP_002_earlyWriteFailureLeavesNoRecords() async throws {
    let sink = MemorySink()
    sink.failOnAppendCount = 2
    let log = try DurableEventLog(sink: sink)
    let runs = RunRegistry()
    let request = runRequest("early-fault")
    let loop = await makeLoop(provider: ScriptedProvider(scripts: [completed("x")]), executor: RecordingExecutor(), log: log, runs: runs)

    let result = await loop.run(request, policy: LoopPolicy())

    #expect(result.status == .failed)
    #expect(result.terminalCommitted)
    #expect(sink.lineCount == 1)
    #expect(try await runs.record(request.runID)?.status == .failed)
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
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lxj-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sink = FileEventLogSink(url: directory.appendingPathComponent("events.jsonl"))

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
    #expect(entries.count == 3)
    let batchEntry = try #require(entries.first { $0.payload.toolOutcomes.count > 0 })
    #expect(batchEntry.payload.toolOutcomes.map(\.content) == ["echo<-c1"])
    #expect(batchEntry.unit == "run-round-trip-batch1")

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
    #expect(recorded.map(\.id.rawValue) == ["turn-persist", "call-run-persist-batch1", "result-run-persist-batch1"])
    #expect(try await store.entries(for: runRequest("persist").sessionID).count == 3)
}
