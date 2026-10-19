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

@Test("LOOP-006 a provider failure is not rewritten by a concurrent cancel")
func LOOP_006_failureSurvivesCancel() async throws {
    let arrival = Gate()
    let proceed = Gate()
    let provider = ScriptedProvider(scripts: [[.started, .failed(ModelFailure(kind: .rateLimited, message: "429 too many requests"))]])
    provider.arrivalGate = arrival
    provider.proceedGate = proceed
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: try DurableEventLog(sink: MemorySink()))
    let request = runRequest("race")

    let task = Task { await loop.run(request, policy: LoopPolicy()) }
    #expect(await arrival.wait())
    task.cancel()
    proceed.fire()
    let result = await task.value

    #expect(result.status == .failed)
    #expect(result.cause == .providerFailure)
    #expect(result.detail?.contains("429") == true)
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

@Test("DEADLINE an overall timeout terminates the run")
func DEADLINE_overallTimeout() async throws {
    let clock = ManualClock()
    let registry = ToolRegistry()
    try await registerEchoTool(registry)
    let provider = ScriptedProvider(scripts: [toolBatch([makeCall("c1")]), completed("x")])
    provider.onStream = { index in if index == 0 { clock.advance(.seconds(30)) } }
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), registry: registry, log: try! DurableEventLog(sink: MemorySink()), clock: clock)

    let result = await loop.run(runRequest("slow"), policy: LoopPolicy(overallTimeout: .seconds(10)))

    #expect(result.status == .deadlineExceeded)
    #expect(result.cause == .deadlineExceeded)
}
