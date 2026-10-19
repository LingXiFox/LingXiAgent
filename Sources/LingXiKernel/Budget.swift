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
}

public struct BudgetPlan: Sendable {
    public let selected: [ContextEntry]
    public let evicted: [ContextEntry]
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

        if running > highWater {
            let candidates = entries.indices
                .filter { !entries[$0].segment.isMandatory }
                .sorted { lhs, rhs in
                    let left = entries[lhs].segment.evictionPriority
                    let right = entries[rhs].segment.evictionPriority
                    return left == right ? lhs < rhs : left < right
                }
            for index in candidates {
                if running <= lowWater { break }
                guard keep[index] else { continue }
                for member in unitMembers(of: index, entries: entries, keep: keep) {
                    keep[member] = false
                    running -= perEntry[member]
                }
            }
        }

        guard running <= limits.hardTokens else {
            throw BudgetError.mandatoryFloorExceedsHardLimit(pinnedTokens: running, hardTokens: limits.hardTokens)
        }

        let evicted = entries.indices.filter { !keep[$0] }.map { entries[$0] }
        var selected = entries.indices.filter { keep[$0] }.map { entries[$0] }

        if !evicted.isEmpty {
            let reference = ContextEntry(
                id: "eviction-reference",
                segment: .derivedPage,
                role: .system,
                payload: .text("Evicted for budget; recoverable by entry id: " + evicted.map(\.id.rawValue).joined(separator: ", "))
            )
            selected.append(reference)
            running += estimator.estimate(reference)
        }

        return BudgetPlan(
            selected: selected,
            evicted: evicted,
            estimatedTokens: running,
            highWaterTokens: highWater,
            lowWaterTokens: lowWater
        )
    }

    /// A causal batch leaves together or not at all, otherwise the surviving half fails validation.
    private func unitMembers(of index: Int, entries: [ContextEntry], keep: [Bool]) -> [Int] {
        guard let unit = entries[index].unit else { return [index] }
        return entries.indices.filter { entries[$0].unit == unit && keep[$0] }
    }
}
