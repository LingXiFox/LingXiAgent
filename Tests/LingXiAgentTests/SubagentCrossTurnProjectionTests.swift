import Foundation
import Testing
import LingXiApplication
import LingXiClient
import LingXiProtocol

/// A child run that terminates after its originating turn has ended must still land in the
/// owning session's transcript — including when the client attached too late to see the
/// creation event.
@Suite("Subagent cross-turn projection")
struct SubagentCrossTurnProjectionTests {
    private let sessionID = SessionID("session-1")
    private let generationID = EventLogGenerationID(rawValue: "generation-1")
    private let connection = ConnectionState(status: .connected)
    private let runID = RunID("child-run-1")
    private let parentRunID = RunID("parent-run-1")
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ sequence: UInt64, _ payload: SessionEventPayload) -> SessionEventEnvelope {
        SessionEventEnvelope(
            cursor: EventCursor(generationID: generationID, sequence: sequence),
            timestamp: timestamp,
            causal: CausalContext(sessionID: sessionID),
            payload: payload
        )
    }

    private func subagentRows(_ state: SessionViewState) -> [SubagentNode] {
        state.timelineNodes.compactMap { node in
            if case let .subagent(payload) = node.kind { return payload }
            return nil
        }
    }

    @Test("terminal outcome without a preceding created event still renders")
    func orphanTerminalStillRenders() {
        var state = SessionViewState(sessionID: sessionID)
        SessionReducer.reduce(
            state: &state,
            event: event(1, .subagentTerminal(runID: runID, terminalReason: .completed, resultPreview: "CHILD-7F3A")),
            connectionState: connection
        )

        let rows = subagentRows(state)
        #expect(rows.count == 1)
        #expect(rows.first?.resultPreview == "CHILD-7F3A")
        #expect(state.activeSubagentRunIDs.contains(runID) == false)
    }

    @Test("created then terminal updates one row in place and keeps the result")
    func lifecycleUpdatesInPlace() {
        var state = SessionViewState(sessionID: sessionID)
        SessionReducer.reduce(state: &state, event: event(1, .subagentCreated(runID: runID, parentRunID: parentRunID)), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(2, .subagentStateChanged(runID: runID, status: "running")), connectionState: connection)
        SessionReducer.reduce(state: &state, event: event(3, .subagentTerminal(runID: runID, terminalReason: .completed, resultPreview: "all done")), connectionState: connection)

        #expect(state.timelineNodes.filter { $0.id.rawValue == "subagent:child-run-1" }.count == 1)
        #expect(subagentRows(state).count == 1)
        #expect(state.subagents[runID]?.status == "completed")
        #expect(state.subagents[runID]?.terminalReason == .completed)
        #expect(state.subagents[runID]?.resultPreview == "all done")
        #expect(state.activeSubagentRunIDs.isEmpty)
    }

    @Test("resultPreview survives the wire codec, and pre-extension bytes still decode")
    func payloadCodec() throws {
        let withPreview = SessionEventPayload.subagentTerminal(
            runID: runID, terminalReason: .runtimeFailure, resultPreview: "boom: provider 500"
        )
        let encoded = try JSONEncoder().encode(withPreview)
        #expect(try JSONDecoder().decode(SessionEventPayload.self, from: encoded) == withPreview)

        let legacy = SessionEventPayload.subagentTerminal(
            runID: runID, terminalReason: .completed, resultPreview: nil
        )
        let legacyData = try JSONEncoder().encode(legacy)
        let object = try #require(try JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        #expect(object["resultPreview"] == nil)
        #expect(try JSONDecoder().decode(SessionEventPayload.self, from: legacyData) == legacy)
    }
}
