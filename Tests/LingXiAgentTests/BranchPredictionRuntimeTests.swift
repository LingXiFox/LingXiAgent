import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

@Suite("Branch Prediction Runtime Feed Tests")
struct BranchPredictionRuntimeTests {

    @Test("A repeated action produces a hint, and the next identical action scores as a hit")
    func repeatedActionForecastsAndScores() async {
        let session = SessionID("predict-repeat-\(UUID().uuidString)")
        let runtime = BranchPredictionRuntime()

        let first = await runtime.record(sessionID: session, action: .tool(name: "shell"))
        #expect(first.abstained, "a single observation must not produce a forecast")
        #expect(first.steps == 0)

        _ = await runtime.record(sessionID: session, action: .tool(name: "shell"))
        _ = await runtime.record(sessionID: session, action: .tool(name: "shell"))
        // The third observation is the first with enough evidence, so it forecasts; the
        // fourth is what gets scored against that forecast.
        let fourth = await runtime.record(sessionID: session, action: .tool(name: "shell"))
        #expect(!fourth.abstained)
        #expect(fourth.hint == "tool:shell")
        #expect(fourth.matchedOrder >= 1)
        #expect(fourth.support >= 2)
        #expect(fourth.steps == 1)
        #expect(fourth.hits == 1)
        #expect(fourth.misses == 0)

        let diverted = await runtime.record(sessionID: session, action: .tool(name: "read_file"))
        #expect(diverted.steps == 2)
        #expect(diverted.hits == 1)
        #expect(diverted.misses == 1)
    }

    @Test("The order-0 prior fallback is never reported as a branch forecast")
    func priorFallbackStaysAbstained() async {
        let session = SessionID("predict-prior-\(UUID().uuidString)")
        let runtime = BranchPredictionRuntime()

        _ = await runtime.record(sessionID: session, action: .tool(name: "shell"))
        let flipped = await runtime.record(sessionID: session, action: .tool(name: "read_file"))
        #expect(flipped.abstained, "no matching context means no hint, even when priors are peaked")
        #expect(flipped.matchedOrder == 0)
        #expect(flipped.steps == 0, "nothing was forecast, so nothing may be scored")
    }

    @Test("Goal registry holds the anchor per session, counts steps, and clears on blank")
    func goalRegistryLifecycle() async {
        let session = SessionID("goal-\(UUID().uuidString)")
        let registry = SessionGoalRegistry()

        #expect(await registry.goal(session) == nil)
        #expect(await registry.set(session, goal: "  ship TUI  ") == "ship TUI")
        await registry.noteStep(session)
        await registry.noteStep(session)
        let progress = await registry.progress(session)
        #expect(progress?.text == "ship TUI")
        #expect(progress?.steps == 2)

        #expect(await registry.set(session, goal: "   ") == nil)
        #expect(await registry.progress(session) == nil)
    }
}
