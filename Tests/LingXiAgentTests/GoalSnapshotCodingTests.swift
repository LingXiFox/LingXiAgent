import Foundation
import Testing
import LingXiProtocol

@Suite("Goal snapshot wire shape")
struct GoalSnapshotCodingTests {
    @Test("A snapshot written before pause existed decodes as a running goal")
    func legacySnapshotDecodes() throws {
        let since = Date(timeIntervalSinceReferenceDate: 1_000)
        let legacy = #"{"text":"ship it","since":1000,"steps":3}"#
        let goal = try JSONDecoder().decode(GoalRuntimeSnapshot.self, from: Data(legacy.utf8))
        #expect(goal.text == "ship it" && goal.steps == 3 && !goal.paused)
        #expect(goal.resumedAt == since)
        #expect(goal.runningSeconds(at: since.addingTimeInterval(90)) == 90)
    }

    @Test("Paused time is not counted")
    func pausedClockStops() {
        let goal = GoalRuntimeSnapshot(text: "g", since: Date(), steps: 0, paused: true, activeSeconds: 42)
        #expect(goal.resumedAt == nil)
        #expect(goal.runningSeconds(at: Date().addingTimeInterval(1_000)) == 42)
    }
}
