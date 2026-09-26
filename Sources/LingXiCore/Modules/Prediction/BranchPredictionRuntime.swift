import Foundation
import LingXiProtocol

/// Feeds the Branch Prediction Fabric from the real agent loop and scores it.
///
/// Observation only: `record` returns a snapshot nobody in the loop reads, and nothing here
/// is passed back into model selection, so prediction cannot steer the agent.
public actor BranchPredictionRuntime {
    public static let shared = BranchPredictionRuntime()

    /// A single live session rarely repeats one context three times, so the gate has to be
    /// reachable: two observations of the same transition. Below it the forecast is noise.
    static let abstainConfidence = 0.25
    static let abstainSupport = 2

    private struct State {
        var predictor = VariableOrderMarkovPredictor(maxOrder: 3)
        var history: [ActionToken] = []
        var expected: ActionToken?
        var snapshot = PredictionRuntimeSnapshot()
    }

    private var states: [SessionID: State] = [:]

    /// Notes the action the agent actually took, scores the outstanding prediction, then
    /// predicts the next action from the observed sequence.
    @discardableResult
    public func record(sessionID: SessionID, action: ActionToken) -> PredictionRuntimeSnapshot {
        var state = states[sessionID] ?? State()
        var snap = state.snapshot

        if let expected = state.expected {
            snap.steps += 1
            if expected == action {
                snap.hits += 1
            } else {
                snap.misses += 1
            }
        }
        state.expected = nil

        state.history.append(action)
        state.predictor.train(sequences: [Array(state.history.suffix(4))])
        let result = forecast(for: state)

        snap.confidence = result.topConfidence
        snap.support = result.support
        snap.matchedOrder = result.matchedOrder
        if let top = result.top1,
           result.matchedOrder >= 1,
           result.topConfidence >= Self.abstainConfidence,
           result.support >= Self.abstainSupport {
            snap.hint = top.description
            snap.abstained = false
            state.expected = top
        } else {
            snap.hint = "—"
            snap.abstained = true
        }

        state.snapshot = snap
        states[sessionID] = state
        return snap
    }

    /// Longest context first, but only where the match actually has evidence: the fabric backs
    /// off to the longest known context regardless of how rarely it was seen, and in a live
    /// session the longest match is almost always a one-off.
    private func forecast(for state: State) -> PredictionResult {
        let ceiling = min(3, state.history.count)
        var shortest: PredictionResult?
        for order in stride(from: ceiling, through: 1, by: -1) {
            let result = state.predictor.predictNext(context: Array(state.history.suffix(order)))
            shortest = result
            guard let top = result.top1,
                  result.matchedOrder >= 1,
                  result.topConfidence >= Self.abstainConfidence,
                  result.support >= Self.abstainSupport else { continue }
            return result
        }
        return shortest ?? PredictionResult(top1: nil, topConfidence: 0, support: 0, matchedOrder: 0, candidates: [])
    }

    public func snapshot(_ sessionID: SessionID) -> PredictionRuntimeSnapshot? {
        states[sessionID]?.snapshot
    }

    public func clear(_ sessionID: SessionID) {
        states[sessionID] = nil
    }
}
