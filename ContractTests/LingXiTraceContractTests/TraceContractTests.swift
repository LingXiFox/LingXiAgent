import Foundation
import Testing
import LingXiProtocol

struct TraceContractTests {

    @Test("RuntimeTraceEvent serialization round-trip retains mandatory fields")
    func traceEventSerialization() throws {
        let event = RuntimeTraceEvent(
            traceID: "trace-test-1",
            kind: .core,
            event: "test.step.completed",
            sessionID: SessionID("session-test-1"),
            runID: AgentRunID("run-test-1"),
            metadata: ["key": "val"]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let decoded = try JSONDecoder().decode(RuntimeTraceEvent.self, from: data)

        #expect(decoded.traceID == event.traceID)
        #expect(decoded.kind == event.kind)
        #expect(decoded.sessionID == event.sessionID)
        #expect(decoded.runID == event.runID)
        #expect(decoded.event == event.event)
        #expect(decoded.metadata == event.metadata)
    }
}
