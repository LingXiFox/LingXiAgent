import Foundation
import Testing
@testable import LingXiCore
import LingXiProtocol

struct TraceEmitterWhiteBoxTests {

    @Test("TraceStore inserts, queries, tails and prunes traces.sqlite correctly")
    func traceStoreLifecycleAndQueries() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("trace_store_test_\(UUID().uuidString)")
        let dbURL = tempDir.appendingPathComponent("traces.sqlite")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try TraceStore(databaseURL: dbURL)

        let taskID = TaskID("task-test-p26")
        let sessionID = SessionID("sess-test-p26")

        // 1. Insert 5 events
        for i in 1...5 {
            let evt = RuntimeTraceEvent(
                traceID: "trace-\(i)",
                timestamp: Date.now.addingTimeInterval(Double(i)),
                kind: i % 2 == 0 ? .task : .provider,
                event: "event.\(i)",
                sessionID: sessionID,
                taskID: taskID,
                tokens: TraceTokenUsage(inputTokens: i * 100, outputTokens: i * 10),
                attributes: ["index": .int(i)]
            )
            try await store.insert(event: evt)
        }

        // 2. Query by taskID
        let taskQuery = TraceQueryRequest(taskID: taskID, limit: 10)
        let taskResults = try await store.query(request: taskQuery)
        #expect(taskResults.count == 5)
        #expect(taskResults.first?.traceID == "trace-1")
        #expect(taskResults.last?.traceID == "trace-5")

        // 3. Query by kind
        let kindQuery = TraceQueryRequest(taskID: taskID, kind: .task, limit: 10)
        let kindResults = try await store.query(request: kindQuery)
        #expect(kindResults.count == 2) // trace-2, trace-4

        // 4. Tail
        let tailResults = try await store.tail(limit: 3)
        #expect(tailResults.count == 3)
        #expect(tailResults.last?.traceID == "trace-5")

        // 5. Prune
        let trimmed = try await store.prune(retentionDays: 7, maxRows: 3)
        #expect(trimmed == 2) // trimmed 2 excess rows to reach maxRows 3
        let afterPrune = try await store.tail(limit: 10)
        #expect(afterPrune.count == 3)
    }

    @Test("TraceEmitter redaction invariant guarantees credentials and secrets never leak")
    func traceEmitterRedactionInvariant() async throws {
        let dirtyEvent = RuntimeTraceEvent(
            kind: .provider,
            event: "provider.request",
            attributes: [
                "api_key": .string("sk-secret-123456789"),
                "authorization": .string("Bearer sk-live-secret-token"),
                "token": .string("ghp_myPersonalAccessToken"),
                "password": .string("P@ssw0rd!"),
                "public_info": .string("Model=gpt-4o")
            ],
            metadata: [
                "cookie": "session=abcdef12345",
                "secret_key": "top-secret-val",
                "normal_header": "application/json"
            ]
        )

        let clean = TraceEmitter.redact(dirtyEvent)

        // Verify metadata redaction
        #expect(clean.metadata["cookie"] == "[redacted]")
        #expect(clean.metadata["secret_key"] == "[redacted]")
        #expect(clean.metadata["normal_header"] == "application/json")

        // Verify attributes redaction
        #expect(clean.attributes?["api_key"] == .string("[redacted]"))
        #expect(clean.attributes?["authorization"] == .string("[redacted]"))
        #expect(clean.attributes?["token"] == .string("[redacted]"))
        #expect(clean.attributes?["password"] == .string("[redacted]"))
        #expect(clean.attributes?["public_info"] == .string("Model=gpt-4o"))
    }

    @Test("TraceEmitter 5 adapters produce standard RuntimeTraceEvents")
    func traceEmitterAdapters() throws {
        let taskID = TaskID("task-adapt-1")
        let sessionID = SessionID("sess-adapt-1")
        let runID = AgentRunID("run-adapt-1")

        // 1. AgentTerminalTrace adapter
        let termTrace = AgentTerminalTrace(
            runID: runID,
            sessionID: sessionID,
            terminalTransition: "completed",
            terminalReason: .completed,
            transitionSource: "loop",
            explanation: "All criteria satisfied"
        )
        let termEvt = TraceEmitter.adapt(terminalTrace: termTrace, sessionID: sessionID, runID: runID, taskID: taskID)
        #expect(termEvt.kind == RuntimeTraceKind.agentRun)
        #expect(termEvt.event == "terminal.state")
        #expect(termEvt.taskID == taskID)
        #expect(termEvt.attributes?["terminalReason"] == TraceAttributeValue.string("completed"))

        // 2. StepPerformance adapter
        let stepPerf = StepPerformance(
            step: 1,
            contextRevision: 10,
            contextBuildMilliseconds: 15.0,
            modelDispatchMilliseconds: 25.0,
            streamMilliseconds: 100.0,
            toolCallCount: 1
        )
        let stepEvt = TraceEmitter.adapt(profilerStep: stepPerf, sessionID: sessionID, runID: runID, taskID: taskID)
        #expect(stepEvt.kind == RuntimeTraceKind.core)
        #expect(stepEvt.event == "step.performance")
        #expect(stepEvt.attributes?["step"] == TraceAttributeValue.int(1))

        // 3. ECoreAccessEvent adapter
        let ecoreEvent = ECoreAccessEvent(
            sessionID: sessionID,
            objectID: ContextObjectID(unchecked: "obj-1"),
            eventType: .objectStored
        )
        let ecoreEvt = TraceEmitter.adapt(ecoreEvent: ecoreEvent, taskID: taskID)
        #expect(ecoreEvt.kind == RuntimeTraceKind.core)
        #expect(ecoreEvt.event == "ecore.access")
        #expect(ecoreEvt.attributes?["objectID"] == TraceAttributeValue.string("obj-1"))

        // 4. RetrievalTelemetry adapter
        let retEvt = TraceEmitter.adapt(retrievalQuery: "search files", resultsCount: 4, durationMs: 12.5, sessionID: sessionID, taskID: taskID)
        #expect(retEvt.kind == .core)
        #expect(retEvt.event == "retrieval.query")
        #expect(retEvt.attributes?["resultsCount"] == .int(4))

        // 5. ProviderCallTrace adapter
        let provTrace = ProviderCallTrace(
            sessionID: sessionID,
            userTurnID: MessageID("msg-1"),
            providerRequestID: "req-call-1",
            sequence: 1,
            reason: "chat",
            model: "claude-3-5-sonnet",
            estimatedPromptTokens: 500,
            actualUsage: ModelUsage(inputTokens: 480, outputTokens: 120, cacheReadTokens: 1000),
            toolSchemaTokens: 0,
            toolCount: 0,
            l1Tokens: 0,
            systemPinnedTokens: 0,
            currentTurnTokens: 0,
            providerFramingTokens: 0
        )
        let provEvt = TraceEmitter.adapt(providerCall: provTrace, taskID: taskID)
        #expect(provEvt.kind == RuntimeTraceKind.provider)
        #expect(provEvt.event == "provider.call")
        #expect(provEvt.tokens?.inputTokens == 480)
        #expect(provEvt.tokens?.outputTokens == 120)
    }
}
