import Foundation
import LingXiProtocol

/// P-Core Context Value Eviction 的量化实现。
///
/// 权重、衰减、饱和点与成本惩罚系数全部冻结在
/// `Docs/Decisions/PE-Core-Git-Semantics-Freeze-2026-09-30.md` 第 4.21 节。
/// 后续调参只允许基于真实 trace 单独提交校准变更，不得在实现过程中自行重新分配。
public enum ContextValueWeights {
    public static let taskAffinity = 0.24
    public static let dependencyWeight = 0.18
    public static let recency = 0.16
    public static let relevance = 0.12
    public static let frequency = 0.10
    public static let activeFileAffinity = 0.10
    public static let explicitReuse = 0.06
    public static let irreplaceability = 0.04
    public static let tokenCostPenalty = 0.35
    public static let recencyTurnDecay = 8.0
    public static let frequencySaturation = 8.0

    /// 八项基础权重之和必须恒为 1.00（契约 4.3）。
    public static var retentionWeightSum: Double {
        taskAffinity + dependencyWeight + recency + relevance + frequency + activeFileAffinity + explicitReuse + irreplaceability
    }
}

/// 归一化到 [0, 1] 之后的八个保留价值特征，加上次级成本因素。
public struct ContextRetentionFeatures: Sendable, Equatable {
    public let taskAffinity: Double
    public let dependencyWeight: Double
    public let recency: Double
    public let relevance: Double
    public let frequency: Double
    public let activeFileAffinity: Double
    public let explicitReuse: Double
    public let irreplaceability: Double
    public let normalizedTokenCost: Double
}

/// 打分输入：调用方提供原始信号，归一化规则由本文件独占（避免各处再长第二套口径）。
public struct ContextRetentionSignals: Sendable, Equatable {
    public let taskAffinity: Double
    public let dependencyWeight: Double
    public let deltaTurn: Int
    public let relevance: Double
    public let accessCount: Int
    public let activeFileAffinity: Double
    public let explicitReuse: Double
    public let reconstructability: Double
    public let tokenCost: Int

    public init(
        taskAffinity: Double,
        dependencyWeight: Double,
        deltaTurn: Int,
        relevance: Double,
        accessCount: Int,
        activeFileAffinity: Double,
        explicitReuse: Double,
        reconstructability: Double,
        tokenCost: Int
    ) {
        self.taskAffinity = taskAffinity
        self.dependencyWeight = dependencyWeight
        self.deltaTurn = deltaTurn
        self.relevance = relevance
        self.accessCount = accessCount
        self.activeFileAffinity = activeFileAffinity
        self.explicitReuse = explicitReuse
        self.reconstructability = reconstructability
        self.tokenCost = tokenCost
    }
}

public struct ContextRetentionEstimate: Sendable, Equatable {
    public let features: ContextRetentionFeatures
    public let retentionValue: Double
    public let retentionScore: Double

    /// Fail-Open 路径不参与 RetentionScore 排序，但可观测性记录仍要有可辨识的值。
    public static let legacyFallback = ContextRetentionEstimate(features: .zero, retentionValue: 0, retentionScore: 0)
}

extension ContextRetentionFeatures {
    public static let zero = ContextRetentionFeatures(
        taskAffinity: 0,
        dependencyWeight: 0,
        recency: 0,
        relevance: 0,
        frequency: 0,
        activeFileAffinity: 0,
        explicitReuse: 0,
        irreplaceability: 0,
        normalizedTokenCost: 0
    )
}

/// 一次 eviction 事件的完整可观测记录（契约 4.20）。
/// 正式 UI 不展示，Debug / Runtime Inspector 必须能看到，否则权重只能凭感觉调。
public struct ContextEvictionTraceEntry: Sendable, Equatable {
    public let objectKey: String
    public let objectType: String
    public let tokenCost: Int
    public let features: ContextRetentionFeatures
    public let retentionValue: Double
    public let retentionScore: Double
    public let evictionRank: Int?
    public let evictionReason: String?
}

public enum ContextValueScorer {
    public static func clamp(_ value: Double) -> Double {
        if value.isNaN || value.isInfinite { return 0 }
        return min(1, max(0, value))
    }

    /// 归一化 tokenCost 需要 P-Core 目标值；`pCoreTarget <= 0` 时成本项退化为 0（只剩价值排序），
    /// 调用方应改用 `canScore` 判断并 fallback 到既有确定性顺序（契约 4.19）。
    public static func canScore(pCoreTarget: Int) -> Bool { pCoreTarget > 0 }

    public static func estimate(signals: ContextRetentionSignals, pCoreTarget: Int) -> ContextRetentionEstimate {
        let features = normalizedFeatures(signals: signals, pCoreTarget: pCoreTarget)
        let retentionValue =
            ContextValueWeights.taskAffinity * features.taskAffinity
            + ContextValueWeights.dependencyWeight * features.dependencyWeight
            + ContextValueWeights.recency * features.recency
            + ContextValueWeights.relevance * features.relevance
            + ContextValueWeights.frequency * features.frequency
            + ContextValueWeights.activeFileAffinity * features.activeFileAffinity
            + ContextValueWeights.explicitReuse * features.explicitReuse
            + ContextValueWeights.irreplaceability * features.irreplaceability
        let score = retentionValue / (1 + ContextValueWeights.tokenCostPenalty * features.normalizedTokenCost)
        return ContextRetentionEstimate(features: features, retentionValue: retentionValue, retentionScore: score)
    }

    public static func normalizedFeatures(signals: ContextRetentionSignals, pCoreTarget: Int) -> ContextRetentionFeatures {
        // turn-based 指数衰减：Agent Loop 的有效上下文以 turn 为单位变化，不用 wall-clock。
        let recency = clamp(exp(-Double(max(0, signals.deltaTurn)) / ContextValueWeights.recencyTurnDecay))
        // 对数饱和：访问 8 次之后不再继续加保留权重。
        let frequency = clamp(log(1 + Double(max(0, signals.accessCount))) / log(1 + ContextValueWeights.frequencySaturation))
        // tokenCost 用对数归一化，避免 200 与 800 因绝对大小被过度拉开。
        let normalizedCost = clamp(log2(1 + Double(max(0, signals.tokenCost))) / log2(1 + Double(pCoreTarget)))
        return ContextRetentionFeatures(
            taskAffinity: clamp(signals.taskAffinity),
            dependencyWeight: clamp(signals.dependencyWeight),
            recency: recency,
            relevance: clamp(signals.relevance),
            frequency: frequency,
            activeFileAffinity: clamp(signals.activeFileAffinity),
            explicitReuse: clamp(signals.explicitReuse),
            irreplaceability: clamp(1 - clamp(signals.reconstructability)),
            normalizedTokenCost: normalizedCost
        )
    }

    /// 契约 4.16 的确定性排序：分数升序 → tokenCost 降序 → lastUsedTurn 升序 → createdTurn 升序 → key 字典序。
    /// 禁止依赖 Dictionary / Set 迭代顺序，保证同输入同结果。
    public static func evictionOrder(_ candidates: [ContextEvictionCandidate]) -> [ContextEvictionCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.retentionScore != rhs.retentionScore { return lhs.retentionScore < rhs.retentionScore }
            if lhs.tokenCost != rhs.tokenCost { return lhs.tokenCost > rhs.tokenCost }
            if lhs.lastUsedTurn != rhs.lastUsedTurn { return lhs.lastUsedTurn < rhs.lastUsedTurn }
            if lhs.createdTurn != rhs.createdTurn { return lhs.createdTurn < rhs.createdTurn }
            return lhs.key < rhs.key
        }
    }
}

/// 排序所需的最小携带体：分数 + 四个 tie-break 维度 + 原始 unit 位置。
public struct ContextEvictionCandidate: Sendable {
    public let key: String
    public let tokenCost: Int
    public let lastUsedTurn: Int
    public let createdTurn: Int
    public let estimate: ContextRetentionEstimate
    public let unitIndices: [Int]

    public var retentionScore: Double { estimate.retentionScore }
}

/// 词法相关性：复用 `ContextQuery` 的 term 抽取（不再长第二套 relevance engine），
/// 输出命中比例作为连续值。任务与 query 各调一次，两者输入不同因此不构成重复计分。
public enum ContextLexicalAffinity {
    public static func terms(from text: String) -> [String] {
        Array(Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })).sorted()
    }

    public static func score(content: String, terms: [String]) -> Double {
        guard !terms.isEmpty else { return 0 }
        let haystack = content.lowercased()
        let matched = terms.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
        return ContextValueScorer.clamp(Double(matched) / Double(terms.count))
    }
}
