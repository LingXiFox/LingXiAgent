import Foundation
import Testing
import LingXiProtocol
import LingXiClient
import LingXiApplication

/// Goal is a projected Core fact, never a frontend memory: one set, one clear and one
/// reconnect have to carry the same value through the event wire, the state wire and the
/// reducer that rebuilds `SessionViewState`.
@Suite("GoalProjectionTests")
struct GoalProjectionTests {
    private let sessionID = SessionID("session-goal-1")
    private let connection = ConnectionState(status: .connected)
    private let generationID = EventLogGenerationID(rawValue: "gen-goal-1")

    private var goal: GoalRuntimeSnapshot {
        GoalRuntimeSnapshot(text: "ship V1.1.0",
                            since: Date(timeIntervalSince1970: 1_700_000_000),
                            steps: 7)
    }

    private func event(_ sequence: UInt64, _ payload: SessionEventPayload) -> SessionEventEnvelope {
        SessionEventEnvelope(
            cursor: EventCursor(generationID: generationID, sequence: sequence),
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            causal: CausalContext(sessionID: sessionID),
            payload: payload
        )
    }

    private func decodedJSON(_ payload: SessionEventPayload) throws -> [String: Any] {
        let data = try FrontendWire.makeEncoder().encode(payload)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Wire shape

    @Test("goalChanged wire shape is pinned: kind plus a goal object with text, steps and a numeric since")
    func wireShape() throws {
        let json = try decodedJSON(.goalChanged(goal))
        #expect(json["kind"] as? String == "goalChanged")
        let payload = try #require(json["goal"] as? [String: Any])
        #expect(payload["text"] as? String == "ship V1.1.0")
        #expect(payload["steps"] as? Int == 7)
        // Swift's default date strategy, i.e. one bare number. A browser that expects an
        // ISO string, or a `{rawValue}` object, would silently render nothing.
        #expect(payload["since"] is Double || payload["since"] is Int)
    }

    @Test("A cleared goal encodes with no goal key and decodes back as an explicit nil")
    func clearEncodesAsAbsence() throws {
        let json = try decodedJSON(.goalChanged(nil))
        #expect(json["kind"] as? String == "goalChanged")
        #expect(json["goal"] == nil)

        let roundTripped = try FrontendWire.makeDecoder().decode(
            SessionEventPayload.self, from: Data(#"{"kind":"goalChanged"}"#.utf8))
        #expect(roundTripped == .goalChanged(nil))
        // The negative case: an absent goal must not read back as an empty goal.
        if case let .goalChanged(restored) = roundTripped {
            #expect(restored == nil)
        } else {
            Issue.record("goalChanged did not survive decoding")
        }
    }

    @Test("A set goal round-trips through the event wire with every field intact")
    func setRoundTrips() throws {
        let data = try FrontendWire.makeEncoder().encode(SessionEventPayload.goalChanged(goal))
        #expect(try FrontendWire.makeDecoder().decode(SessionEventPayload.self, from: data)
                    == .goalChanged(goal))
    }

    // MARK: - State wire

    @Test("SessionViewState carries the goal across a state round-trip, and omits it when absent")
    func stateRoundTrip() throws {
        var projected = SessionViewState(sessionID: sessionID)
        #expect(projected.goal == nil)
        projected.goal = goal

        let data = try FrontendWire.makeEncoder().encode(projected)
        let restored = try FrontendWire.makeDecoder().decode(SessionViewState.self, from: data)
        #expect(restored.goal == goal)

        let bare = try FrontendWire.makeEncoder().encode(SessionViewState(sessionID: sessionID))
        let bareJSON = try #require(try FrontendWire.makeDecoder().decode(SessionViewState.self, from: bare))
        #expect(bareJSON.goal == nil)
    }

    // MARK: - Reducer

    @Test("The reducer projects a set, then a clear, and reports both as a context change")
    func reducerAppliesSetThenClear() {
        var state = SessionViewState(sessionID: sessionID)

        let setChanges = SessionReducer.reduce(state: &state, event: event(1, .goalChanged(goal)),
                                               connectionState: connection)
        #expect(state.goal == goal)
        #expect(setChanges.contextChanged)

        let clearChanges = SessionReducer.reduce(state: &state, event: event(2, .goalChanged(nil)),
                                                 connectionState: connection)
        #expect(state.goal == nil)
        #expect(clearChanges.contextChanged)
    }

    @Test("A snapshot resync restores the goal, and a goal-less snapshot clears a stale one")
    func snapshotResync() {
        let summary = SessionSummary(
            sessionID: sessionID,
            title: "Goal",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            turnCount: 0,
            mode: .build
        )
        let cursor = EventCursor(generationID: generationID, sequence: 3)
        let context = ContextStateSnapshot(sessionID: sessionID)

        var state = SessionViewState(sessionID: sessionID)
        _ = SessionReducer.reduce(state: &state, event: event(1, .goalChanged(goal)),
                                  connectionState: connection)

        let withGoal = SessionSnapshot(sessionID: sessionID, info: summary,
                                       contextState: context,
                                       eventCursor: cursor, goal: goal)
        SessionReducer.reduceSnapshot(state: &state, snapshot: withGoal, connectionState: connection)
        #expect(state.goal == goal)

        // The negative case, i.e. the session-switch guarantee: re-attaching to a session that
        // has no anchor must not leave the previous session's goal on screen.
        let withoutGoal = SessionSnapshot(sessionID: sessionID, info: summary,
                                          contextState: context, eventCursor: cursor)
        SessionReducer.reduceSnapshot(state: &state, snapshot: withoutGoal, connectionState: connection)
        #expect(state.goal == nil)
    }
}
