/// Rough, deliberately conservative token estimate. It is only good for budgeting and local rate
/// prediction; cost reporting must use upstream usage (never this).
public struct TokenEstimator: Sendable {
    public static let entryOverheadTokens = 4

    public init() {}

    public func estimate(_ text: String) -> Int {
        max(1, text.utf8.count / 4)
    }

    public func estimate(_ entry: ContextEntry) -> Int {
        estimate(entry.renderedText) + Self.entryOverheadTokens
    }
}

public struct BudgetLimits: Sendable {
    public let preferredTokens: Int
    public let hardTokens: Int

    public init(preferredTokens: Int, hardTokens: Int) {
        self.preferredTokens = preferredTokens
        self.hardTokens = hardTokens
    }
}

public enum BudgetError: Error, Equatable {
    case mandatoryFloorExceedsHardLimit(pinnedTokens: Int, hardTokens: Int)
    /// The eviction reference line itself does not fit under the hard limit; failing closed is
    /// better than silently omitting the recoverable ids or exceeding the hard limit.
    case referenceExceedsHardLimit(estimatedTokens: Int, hardTokens: Int)
}

public struct BudgetPlan: Sendable {
    public let selected: [ContextEntry]
    public let evicted: [ContextEntry]
    /// Tokens of `selected`, including the eviction reference line.
    public let estimatedTokens: Int
    public let highWaterTokens: Int
    public let lowWaterTokens: Int
}

/// Water marks plus a mandatory floor, and eviction that stops the moment the low water mark is
/// reached. No value scoring: nothing in 1.x calibrated a scorer (E-05, CTX-008).
public struct ContextBudgetPlanner: Sendable {
    private let estimator = TokenEstimator()

    public init() {}

    public func plan(_ entries: [ContextEntry], limits: BudgetLimits) throws -> BudgetPlan {
        let highWater = limits.preferredTokens * 115 / 100
        let lowWater = limits.preferredTokens * 80 / 100
        let perEntry = entries.map { estimator.estimate($0) }

        let pinned = zip(entries, perEntry).filter { $0.0.segment.isMandatory }.reduce(0) { $0 + $1.1 }
        guard pinned <= limits.hardTokens else {
            throw BudgetError.mandatoryFloorExceedsHardLimit(pinnedTokens: pinned, hardTokens: limits.hardTokens)
        }

        var keep = Array(repeating: true, count: entries.count)
        var running = perEntry.reduce(0, +)

        let candidates = entries.indices
            .filter { !entries[$0].segment.isMandatory }
            .sorted { lhs, rhs in
                let left = entries[lhs].segment.evictionPriority
                let right = entries[rhs].segment.evictionPriority
                return left == right ? lhs < rhs : left < right
            }

        if running > highWater {
            for index in candidates {
                if running <= lowWater { break }
                evictUnit(at: index, entries: entries, keep: &keep, running: &running, perEntry: perEntry)
            }
        }

        var reference: ContextEntry?
        if keep.contains(false) {
            let referenceEntry = makeReference(entries: entries, keep: keep)
            let referenceTokens = estimator.estimate(referenceEntry)
            if running + referenceTokens > limits.hardTokens {
                // The reference line is part of the request too: make room for it instead of
                // exceeding the hard limit, and fail closed if even the mandatory floor plus the
                // reference cannot fit.
                for index in candidates {
                    if running + referenceTokens <= limits.hardTokens { break }
                    evictUnit(at: index, entries: entries, keep: &keep, running: &running, perEntry: perEntry)
                }
            }
            guard running + referenceTokens <= limits.hardTokens else {
                throw BudgetError.referenceExceedsHardLimit(
                    estimatedTokens: running + referenceTokens,
                    hardTokens: limits.hardTokens
                )
            }
            reference = referenceEntry
            running += referenceTokens
        }

        let evicted = entries.indices.filter { !keep[$0] }.map { entries[$0] }
        var selected = entries.indices.filter { keep[$0] }.map { entries[$0] }
        if let reference { selected.append(reference) }

        return BudgetPlan(
            selected: selected,
            evicted: evicted,
            estimatedTokens: running,
            highWaterTokens: highWater,
            lowWaterTokens: lowWater
        )
    }

    private func evictUnit(
        at index: Int,
        entries: [ContextEntry],
        keep: inout [Bool],
        running: inout Int,
        perEntry: [Int]
    ) {
        guard keep[index] else { return }
        for member in unitMembers(of: index, entries: entries, keep: keep) {
            keep[member] = false
            running -= perEntry[member]
        }
    }

    /// A causal batch leaves together or not at all, otherwise the surviving half fails validation.
    private func unitMembers(of index: Int, entries: [ContextEntry], keep: [Bool]) -> [Int] {
        guard let unit = entries[index].unit else { return [index] }
        return entries.indices.filter { entries[$0].unit == unit && keep[$0] }
    }

    /// Derived content goes on the data channel: `role: .system` is reserved for the immutable
    /// instruction block (CTX-001, CTX-018).
    private func makeReference(entries: [ContextEntry], keep: [Bool]) -> ContextEntry {
        let ids = entries.indices.filter { !keep[$0] }.map { entries[$0].id.rawValue }
        return ContextEntry(
            id: "eviction-reference",
            segment: .derivedPage,
            role: .user,
            payload: .text("Evicted for budget; recoverable by entry id: " + ids.joined(separator: ", "))
        )
    }
}
