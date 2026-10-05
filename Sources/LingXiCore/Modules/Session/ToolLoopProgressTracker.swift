import Foundation
import LingXiPlatform

/// Turn-local observations. Repetition is evidence for a warning, never authority to stop a model.
struct ToolLoopProgressTracker: Sendable, Equatable {
    struct CallOutcome: Sendable, Equatable {
        enum Evidence: String, Sendable, Equatable { case none, mutation, attestation }
        let callKey: String
        let succeeded: Bool
        let errorMessage: String?
        var exitCode: Int? = nil
        var evidence: Evidence = .none
    }

    struct Blocker: Sendable, Equatable {
        var fingerprints: Set<String> = []
        var lastSeenStep: Int
        var repeats = 0
        var strategies: Set<String> = []
        var shapes: Set<String> = []
        var warned = false
    }

    enum Verdict: Sendable, Equatable {
        case progress(strategyChanged: Bool)
        case neutral(reason: NeutralReason)
        case exactDuplicate(count: Int)
        case failureCluster(distinctStrategies: Int)
        case softWarning(distinctStrategies: Int, message: String)
        enum NeutralReason: String, Sendable, Equatable { case clean, noObjectiveSignal }
    }

    // ponytail: eight recent blockers, eight identities each, and 256 projected tokens per turn.
    // This is advisory state; retaining an unbounded failure history would add no execution evidence.
    static let maximumBlockers = 8
    static let maximumProjectionTokens = 256
    static let heading = "[Orchestrator observations]"
    private(set) var blockers: [String: Blocker] = [:]
    private(set) var step = 0
    private var lastMutationStep: Int?
    private var lastBatchKey: String?
    private var identicalBatches = 0
    private var emptyBatches = 0

    var openBlockerCount: Int { blockers.count }
    var distinctStrategies: Int { blockers.values.map(\.strategies.count).max() ?? 0 }
    var monotonicRepeats: Int { blockers.values.map(\.repeats).max() ?? 0 }
    var exactFingerprintCount: Int { blockers.values.reduce(0) { $0 + $1.fingerprints.count } }

    mutating func record(_ batch: [CallOutcome], emptyResults: Bool = false) -> Verdict {
        step += 1
        if batch.contains(where: { $0.evidence == .mutation }) { lastMutationStep = step }
        let batchKey = PlatformCrypto.sha256Hex(batch.map(\.callKey).joined(separator: "\n"))
        identicalBatches = batchKey == lastBatchKey ? identicalBatches + 1 : 1
        lastBatchKey = batchKey
        emptyBatches = emptyResults ? emptyBatches + 1 : 0

        let failures = batch.filter { !$0.succeeded && $0.errorMessage != nil }
        let clusters = Set(failures.map { Self.cluster(of: $0) })
        let attempted = Set(failures.map { Self.shape(of: $0.callKey) })
        let succeeded = Set(batch.filter(\.succeeded).map { Self.shape(of: $0.callKey) })
        var resolved = false
        var changedStrategy = false
        for (cluster, blocker) in blockers where !clusters.contains(cluster) {
            let passed = !blocker.shapes.isDisjoint(with: succeeded)
            let changed = !blocker.shapes.isDisjoint(with: attempted)
                && (lastMutationStep ?? 0) > blocker.lastSeenStep
            if passed || changed {
                blockers[cluster] = nil
                resolved = true
                changedStrategy = changedStrategy || blocker.strategies.count > 1
            }
        }

        var warning: String?
        var worstRepeat = 0
        for outcome in failures {
            let cluster = Self.cluster(of: outcome)
            if blockers[cluster] == nil, blockers.count >= Self.maximumBlockers,
               let oldest = blockers.min(by: { $0.value.lastSeenStep < $1.value.lastSeenStep })?.key {
                blockers[oldest] = nil
            }
            var blocker = blockers[cluster] ?? Blocker(lastSeenStep: step)
            // Multiple failures in one batch are one repeated observation.
            if blocker.repeats == 0 || blocker.lastSeenStep != step { blocker.repeats += 1 }
            blocker.lastSeenStep = step
            Self.insert(PlatformCrypto.sha256Hex(outcome.callKey), into: &blocker.strategies)
            Self.insert(Self.shape(of: outcome.callKey), into: &blocker.shapes)
            Self.insert(Self.fingerprint(of: outcome), into: &blocker.fingerprints)
            if blocker.repeats >= 3 && !blocker.warned {
                blocker.warned = true
                warning = "A tool operation has failed in three or more batches."
            }
            if blocker.strategies.count == 1 { worstRepeat = max(worstRepeat, blocker.repeats) }
            blockers[cluster] = blocker
        }
        if emptyBatches == 2 { warning = "Two consecutive tool batches returned empty results." }
        if identicalBatches == 8 { warning = "Eight consecutive tool batches used identical calls." }
        if let warning { return .softWarning(distinctStrategies: distinctStrategies, message: warning) }
        if resolved { return .progress(strategyChanged: changedStrategy) }
        if failures.isEmpty { return .neutral(reason: blockers.isEmpty ? .clean : .noObjectiveSignal) }
        if worstRepeat >= 2 { return .exactDuplicate(count: worstRepeat) }
        return .failureCluster(distinctStrategies: distinctStrategies)
    }

    /// Built after residency/recall admission. Never reserves space or asks compaction to make room.
    /// Stable until an observation appears or clears; counters do not rewrite the tail every step.
    func projection(availableTokens: Int) -> String? {
        var facts: [String] = []
        if let blocker = blockers.values.filter(\.warned).max(by: { $0.lastSeenStep < $1.lastSeenStep }),
           let fingerprint = blocker.fingerprints.sorted().first {
            facts.append("A tool operation has failed in three or more batches: " + String(fingerprint.prefix(100)))
        }
        if emptyBatches >= 2 { facts.append("Two or more consecutive tool batches returned empty results.") }
        if identicalBatches >= 8 { facts.append("Eight or more consecutive tool batches used identical calls.") }
        guard !facts.isEmpty else { return nil }
        let text = Self.heading + "\n" + facts.joined(separator: "\n")
        let tokens = ConservativeTokenEstimator().estimate(text: text) + 4
        guard tokens <= min(Self.maximumProjectionTokens, availableTokens) else { return nil }
        return text
    }

    private static func insert(_ value: String, into set: inout Set<String>) {
        if set.count < 8 { set.insert(value) }
    }

    // MARK: - Mechanical identity

    /// Evidence from the facts a result carries, never from what the tool was called.
    ///
    /// A background command reports success the moment its process is launched; counting that as
    /// progress would let a model restart a failing build forever. Writing identical bytes changes
    /// nothing and must not look like an attempt either.
    static func evidence(toolName: String, success: Bool, mutatedPaths: [String], exitCode: Int?) -> CallOutcome.Evidence {
        guard success else { return .none }
        switch toolName {
        case "run_background_command", "manage_background_command": return .attestation
        default: return mutatedPaths.isEmpty ? .none : .mutation
        }
    }

    /// Exact observation: tool family, exit code, and the message with incidental noise folded away.
    /// Line numbers, ids and paths must not mint a "new" failure every run, while exit code and error
    /// class stay distinct enough that two different problems never merge into one observation.
    static func fingerprint(of outcome: CallOutcome) -> String {
        let family = outcome.callKey.split(separator: "|", maxSplits: 1).first ?? ""
        var parts = [String(decoding: family.utf8.prefix(64), as: UTF8.self)]
        if let exitCode = outcome.exitCode { parts.append("exit\(exitCode)") }
        parts.append(fold(outcome.errorMessage ?? "", paths: true))
        return parts.joined(separator: ":")
    }

    /// The unresolved operation: the same identity without the exit code. Flipping 1 ↔ 2 while the
    /// message class and the tool family stay the same is a new observation of one old blocker.
    static func cluster(of outcome: CallOutcome) -> String {
        let family = outcome.callKey.split(separator: "|", maxSplits: 1).first ?? ""
        var parts = [String(decoding: family.utf8.prefix(64), as: UTF8.self)]
        parts.append(fold(outcome.errorMessage ?? "", paths: true))
        return parts.joined(separator: ":")
    }

    /// Only success of the same objective clears its warning; different files/arguments are distinct.
    static func shape(of callKey: String) -> String {
        PlatformCrypto.sha256Hex(callKey)
    }

    private static func fold(_ text: String, paths: Bool) -> String {
        var out = String(decoding: text.utf8.prefix(256), as: UTF8.self)
        if paths { out = replace(out, #"/[^\s"']+"#, "<path>") }
        out = replace(out, "[0-9a-fA-F]{12,}", "<id>")
        out = replace(out, "[0-9]+", "#")
        return replace(out, "\\s+", " ")
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
