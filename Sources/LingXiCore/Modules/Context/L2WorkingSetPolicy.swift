import Foundation

public struct L2WorkingSetEntry: Sendable {
    public var page: ContextPage
    public var lastUsed: UInt64
    public var useCount: UInt64
    public var queryRelevance: Double
    public var taskAffinity: Double
    public var explicitPin: Bool
}

/// L2 的淘汰决策独立于存储；第一版只接收确定性本地信号。
public struct L2WorkingSetPolicy: Sendable {
    public struct Weights: Sendable {
        public let recentUse: Double
        public let frequency: Double
        public let queryRelevance: Double
        public let taskAffinity: Double
        public let explicitPin: Double

        public init(recentUse: Double = 1, frequency: Double = 0.25, queryRelevance: Double = 0.5, taskAffinity: Double = 0.25, explicitPin: Double = 1_000_000) {
            self.recentUse = recentUse
            self.frequency = frequency
            self.queryRelevance = queryRelevance
            self.taskAffinity = taskAffinity
            self.explicitPin = explicitPin
        }
    }

    public let weights: Weights
    public init(weights: Weights = Weights()) { self.weights = weights }

    public func evictionCandidate(in entries: [String: L2WorkingSetEntry], clock: UInt64) -> String? {
        entries.min { lhs, rhs in
            let left = score(lhs.value, clock: clock)
            let right = score(rhs.value, clock: clock)
            return left == right ? lhs.key < rhs.key : left < right
        }?.key
    }

    public func score(_ entry: L2WorkingSetEntry, clock: UInt64) -> Double {
        Double(entry.lastUsed) / Double(max(1, clock)) * weights.recentUse
            + Double(entry.useCount) * weights.frequency
            + entry.queryRelevance * weights.queryRelevance
            + entry.taskAffinity * weights.taskAffinity
            + (entry.explicitPin ? weights.explicitPin : 0)
    }
}
