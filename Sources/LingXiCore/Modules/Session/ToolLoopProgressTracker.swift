import Foundation

/// Decides, batch by batch, whether a tool loop is making progress.
///
/// The question it replaces was "did this batch fail with the same message as the last one?", which
/// cannot tell a model stuck repeating itself from a model doing exactly the right thing. The answer
/// that shipped next was "any successful call is progress", which is worse: `fail X → read ok →
/// fail X → rewrite the same bytes ok → fail X` was counted as progress four times over and could run
/// forever. Both mistakes come from judging the *batch* instead of judging the *blocker*.
///
/// TOOL SUCCESS IS NOT TASK PROGRESS. A blocker, not a batch, is the unit of judgment, and it has two
/// explicit layers:
///
/// - **ExactFailureFingerprint** - tool family + exit code + normalized message. `shell/exit1/…` and
///   `shell/exit2/…` are two different exact observations, and they stay distinct so a run can say
///   what was actually seen.
/// - **BlockerClusterIdentity** - tool family + normalized message class, with the exit code folded
///   away. Both observations above are one unresolved operation: the same thing keeps going wrong.
///   Changing strategy, changing an echoed counter or flipping an exit code moves *within* a cluster;
///   it cannot leave it.
///
/// Inside a cluster:
///
/// - **Neutral**: a successful read, a write of identical bytes, a background launch. It neither adds
///   a sighting nor clears the cluster; it only spends grace.
/// - **Exploration**: new strategies under the cluster. Counted, warned about once, given a grace
///   window - never a reset, so parameter churn cannot postpone a stop indefinitely.
/// - **Objective progress**, the only things that clear a cluster: the objective that failed now
///   succeeded (fail → pass), or the failure class genuinely moved to a *different cluster* after a
///   real workspace mutation, which is what proves the old blocker is gone.
///
/// A cleared cluster that comes back does not start from zero: repeats and strategies carry over, so
/// progress debt accumulates monotonically across the whole run.
///
/// A pure value so it can be tested without a model, a session or a tool runtime.
struct ToolLoopProgressTracker: Sendable, Equatable {
    struct CallOutcome: Sendable, Equatable {
        /// What a successful call actually attests to. Only `.mutation` says something changed in the
        /// world; `.attestation` says a process was launched; `.none` says nothing was proven.
        enum Evidence: String, Sendable, Equatable { case none, mutation, attestation }

        /// Tool id plus arguments: the same identity `failureKey(for:)` uses.
        let callKey: String
        let succeeded: Bool
        let errorMessage: String?
        var exitCode: Int? = nil
        var evidence: Evidence = .none
    }

    /// One unresolved operation, with every exact observation that met it.
    struct Blocker: Sendable, Equatable {
        let cluster: String
        /// Exact fingerprints seen under this cluster - kept distinct on purpose.
        var fingerprints: Set<String>
        var firstSeenStep: Int
        var lastSeenStep: Int
        /// Monotonic across clears: a resolved cluster that recurs keeps counting.
        var repeats: Int
        var strategies: Set<String>
        /// Normalized calls that produced this cluster, so a fail → pass retry is recognizable.
        var shapes: Set<String>
        var exactRepeats: [String: Int]
        var lastKey: String?
        var warned: Bool
        var batchesSinceWarning: Int
        var open: Bool
    }

    enum Verdict: Sendable, Equatable {
        /// A cluster was resolved by an objective signal.
        case progress(strategyChanged: Bool)
        /// Nothing resolved and nothing reproduced.
        case neutral(reason: NeutralReason)
        /// The same call failed into the same cluster again (`count` sightings).
        case exactDuplicate(count: Int)
        /// One cluster, several strategies, below the warning threshold.
        case failureCluster(distinctStrategies: Int)
        /// Inject `message` into what the model sees next. Issued once per cluster.
        case softWarning(distinctStrategies: Int, message: String)
        /// End the run. `kind` says which rule fired.
        case hardStop(kind: HardStopKind, message: String)

        enum NeutralReason: String, Sendable, Equatable {
            /// Nothing failed and nothing is outstanding.
            case clean
            /// Successes that prove nothing, while a cluster stays unresolved.
            case noObjectiveSignal
        }
    }

    enum HardStopKind: String, Sendable, Equatable {
        case exactDuplicate
        case clusterAfterWarning
    }

    static let softWarningText = "多个不同策略均遇到同一个环境级阻塞。不要继续无意义更换同类命令。"
        + "请换执行路径、请求用户处理环境问题，或明确报告 blocker。"

    var exactDuplicateLimit = 3
    var clusterWarningAt = 3
    var clusterGraceAfterWarning = 2

    private(set) var blockers: [String: Blocker] = [:]
    private(set) var step = 0
    private var lastMutationStep: Int?

    init(exactDuplicateLimit: Int = 3, clusterWarningAt: Int = 3, clusterGraceAfterWarning: Int = 2) {
        self.exactDuplicateLimit = exactDuplicateLimit
        self.clusterWarningAt = clusterWarningAt
        self.clusterGraceAfterWarning = clusterGraceAfterWarning
    }

    var openBlockerCount: Int { blockers.values.filter(\.open).count }
    var distinctStrategies: Int { blockers.values.map(\.strategies.count).max() ?? 0 }
    var monotonicRepeats: Int { blockers.values.map(\.repeats).max() ?? 0 }
    /// How many distinct exact observations the unresolved clusters have collected.
    var exactFingerprintCount: Int { blockers.values.reduce(0) { $0 + $1.fingerprints.count } }

    // MARK: - Judgment

    mutating func record(_ batch: [CallOutcome]) -> Verdict {
        step += 1
        // Grace is spent by every batch, including neutral ones: waiting is not making progress.
        for key in blockers.keys where blockers[key]?.open == true && blockers[key]?.warned == true {
            blockers[key]!.batchesSinceWarning += 1
        }
        if batch.contains(where: { $0.evidence == .mutation }) { lastMutationStep = step }

        // Group this batch's failures by cluster, and remember the exact fingerprints under it.
        var clusterShapes: [String: Set<String>] = [:]
        var clusterKeys: [String: Set<String>] = [:]
        var clusterFingerprints: [String: Set<String>] = [:]
        var attemptedShapes: Set<String> = []
        for outcome in batch where !outcome.succeeded && outcome.errorMessage != nil {
            let shape = Self.shape(of: outcome.callKey)
            let cluster = Self.cluster(of: outcome)
            clusterShapes[cluster, default: []].insert(shape)
            clusterKeys[cluster, default: []].insert(outcome.callKey)
            clusterFingerprints[cluster, default: []].insert(Self.fingerprint(of: outcome))
            attemptedShapes.insert(shape)
        }

        // 1. Resolve clusters an objective signal has disproved.
        let successShapes = Set(batch.filter(\.succeeded).map { Self.shape(of: $0.callKey) })
        var resolved = 0
        for (cluster, blocker) in blockers where blocker.open {
            if !blocker.shapes.isDisjoint(with: successShapes) {
                blockers[cluster]!.open = false
                resolved += 1
                continue
            }
            // The objective was attempted and no longer fails this way at all. That only means
            // something once the workspace really changed after the cluster was last seen; otherwise
            // it is the same broken operation wearing a different exit code.
            let attempted = !blocker.shapes.isDisjoint(with: attemptedShapes)
            let reproduced = clusterShapes[cluster] != nil
            if attempted, !reproduced, let mutationStep = lastMutationStep, mutationStep > blocker.lastSeenStep {
                blockers[cluster]!.open = false
                resolved += 1
            }
        }

        // 2. Accumulate what this batch reproduced. A sighting never resets a count, and a resolved
        //    cluster that comes back reopens with its history intact.
        var worstExact = 0
        var exactStop: (cluster: String, count: Int)?
        for (cluster, shapes) in clusterShapes {
            var blocker = blockers[cluster] ?? Blocker(cluster: cluster, fingerprints: [], firstSeenStep: step,
                                                       lastSeenStep: step, repeats: 0, strategies: [], shapes: [],
                                                       exactRepeats: [:], lastKey: nil, warned: false,
                                                       batchesSinceWarning: 0, open: false)
            blocker.repeats += 1
            blocker.lastSeenStep = step
            blocker.strategies.formUnion(clusterKeys[cluster] ?? [])
            blocker.shapes.formUnion(shapes)
            blocker.fingerprints.formUnion(clusterFingerprints[cluster] ?? [])
            blocker.open = true
            let key = clusterKeys[cluster]?.first
            if let key, key == blocker.lastKey {
                blocker.exactRepeats[key, default: 1] += 1
            } else {
                blocker.lastKey = key
                if let key { blocker.exactRepeats[key, default: 1] = 1 }
            }
            if let count = blocker.exactRepeats.values.max() {
                worstExact = max(worstExact, count)
                if count >= exactDuplicateLimit { exactStop = (cluster, count) }
            }
            blockers[cluster] = blocker
        }

        // 3. Stops, then the one-time warning, then plain accumulation.
        if let stop = exactStop {
            return .hardStop(kind: .exactDuplicate,
                             message: "连续 \(stop.count) 次以完全相同的 ToolCall 遇到相同失败：\(observations(stop.cluster))")
        }
        // A warned cluster only ends the run when it is *still* reproduced after the grace window.
        // A cluster nobody has hit again is not evidence of a stuck model, and stopping on it would
        // punish a model that moved on to other work.
        for cluster in clusterShapes.keys {
            guard let blocker = blockers[cluster], blocker.open, blocker.warned,
                  blocker.batchesSinceWarning > clusterGraceAfterWarning else { continue }
            return .hardStop(kind: .clusterAfterWarning,
                             message: "\(blocker.strategies.count) 个不同策略在提示后仍持续遇到同一阻塞：\(observations(cluster))")
        }
        if resolved > 0 {
            return .progress(strategyChanged: blockers.values.contains { $0.strategies.count > 1 })
        }
        for (cluster, blocker) in blockers where blocker.open && !blocker.warned
            && blocker.strategies.count >= clusterWarningAt {
            blockers[cluster]!.warned = true
            return .softWarning(distinctStrategies: blocker.strategies.count, message: Self.softWarningText)
        }
        if clusterShapes.isEmpty {
            return .neutral(reason: openBlockerCount == 0 ? .clean : .noObjectiveSignal)
        }
        if worstExact >= 2 { return .exactDuplicate(count: worstExact) }
        let open = clusterShapes.keys.compactMap { blockers[$0] }.filter(\.open)
        return .failureCluster(distinctStrategies: open.map(\.strategies.count).max() ?? 1)
    }

    /// What a stop is about, named precisely: the folded cluster plus the exact observations that
    /// were seen under it, so the exit codes a model kept cycling through survive into the reason.
    private func observations(_ cluster: String) -> String {
        guard let blocker = blockers[cluster] else { return cluster }
        let seen = blocker.fingerprints.sorted()
        guard !seen.isEmpty, seen != [cluster] else { return cluster }
        let shown = seen.prefix(3).joined(separator: " / ")
        return seen.count > 3 ? "\(cluster)（观察 \(shown)，另有 \(seen.count - 3) 项）" : "\(cluster)（观察 \(shown)）"
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
        let family = outcome.callKey.split(separator: "|").first
        var parts = [family.map(String.init) ?? outcome.callKey]
        if let exitCode = outcome.exitCode { parts.append("exit\(exitCode)") }
        parts.append(fold(outcome.errorMessage ?? "", paths: true))
        return parts.joined(separator: ":")
    }

    /// The unresolved operation: the same identity without the exit code. Flipping 1 ↔ 2 while the
    /// message class and the tool family stay the same is a new observation of one old blocker.
    static func cluster(of outcome: CallOutcome) -> String {
        let family = outcome.callKey.split(separator: "|").first
        var parts = [family.map(String.init) ?? outcome.callKey]
        parts.append(fold(outcome.errorMessage ?? "", paths: true))
        return parts.joined(separator: ":")
    }

    /// Objective identity: the same call with its numbers folded and its paths kept. Retrying
    /// `g++ app1.cpp` is the same objective as retrying `g++ app2.cpp`; reading `a.txt` is not an
    /// attempt at `b.txt`, so a successful read can never look like a resolved build.
    static func shape(of callKey: String) -> String {
        let parts = callKey.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let tool = String(parts.first ?? "")
        let arguments = parts.count > 1 ? String(parts[1]) : ""
        return tool + "|" + fold(arguments, paths: false)
    }

    private static func fold(_ text: String, paths: Bool) -> String {
        var out = text
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
