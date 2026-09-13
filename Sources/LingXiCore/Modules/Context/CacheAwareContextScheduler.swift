import Foundation
import LingXiProtocol

/// 缓存经济学决策策略配置
public struct EconomicCompactPolicy: Sendable, Equatable, Codable {
    /// 缓存读取单价与写入单价的比值（通常为 0.1，即读比写便宜 90%）
    public var cacheReadWriteRatio: Double
    /// 最小评估的剩余轮次 Horizon
    public var minHorizon: Int
    /// 默认预估的会话剩余轮数
    public var defaultHorizon: Int
    /// 最大允许积累的缓存债务（达到上限后禁止主动破坏性压缩）
    public var maxCacheDebt: Int
    /// 偿还 1 点缓存债务所需的连续缓存命中轮次
    public var debtRecoveryTurns: Int

    public init(
        cacheReadWriteRatio: Double = 0.1,
        minHorizon: Int = 2,
        defaultHorizon: Int = 5,
        maxCacheDebt: Int = 2,
        debtRecoveryTurns: Int = 2
    ) {
        self.cacheReadWriteRatio = cacheReadWriteRatio
        self.minHorizon = minHorizon
        self.defaultHorizon = defaultHorizon
        self.maxCacheDebt = maxCacheDebt
        self.debtRecoveryTurns = debtRecoveryTurns
    }
}

/// 缓存调度器压缩决策枚举
public enum CompactDecision: Sendable, Equatable {
    case skip(reason: String)
    case economicCompact(reason: String)
    case emergencyWindowProtection(reason: String)

    public var shouldCompact: Bool {
        switch self {
        case .skip: return false
        case .economicCompact, .emergencyWindowProtection: return true
        }
    }
}

/// 会话缓存债务与稳定性状态
public struct CacheDebtState: Sendable, Equatable {
    public var cacheDebt: Int = 0
    public var consecutiveHits: Int = 0
    public var totalBusts: Int = 0
    public var lastCompactStep: Int = 0

    public init() {}
}

/// Cache-Aware Context Scheduler
/// 负责依据经济学 Break-even 计算、Cache Debt 门禁以及 Window Protection 硬限制，
/// 决定当前轮次是否应当执行上下文压缩，摆脱盲目高水位压缩对 Prompt Cache 的反复破坏。
public actor CacheAwareContextScheduler {
    public let policy: EconomicCompactPolicy
    private var debtStatesBySession: [SessionID: CacheDebtState] = [:]

    public init(policy: EconomicCompactPolicy = EconomicCompactPolicy()) {
        self.policy = policy
    }

    /// 获取或初始化会话的缓存债务状态
    public func debtState(for sessionID: SessionID) -> CacheDebtState {
        debtStatesBySession[sessionID] ?? CacheDebtState()
    }

    /// 恢复会话的缓存债务状态（用于持久化水合）
    public func restoreDebtState(sessionID: SessionID, debt: Int) {
        var state = debtStatesBySession[sessionID] ?? CacheDebtState()
        state.cacheDebt = min(policy.maxCacheDebt, max(0, debt))
        debtStatesBySession[sessionID] = state
    }

    /// 记录一次 Cache Hit（偿还债务）
    public func recordHit(sessionID: SessionID) {
        var state = debtStatesBySession[sessionID] ?? CacheDebtState()
        state.consecutiveHits += 1
        if state.consecutiveHits >= policy.debtRecoveryTurns {
            state.cacheDebt = max(0, state.cacheDebt - 1)
            state.consecutiveHits = 0
        }
        debtStatesBySession[sessionID] = state
    }

    /// 记录一次 Cache Bust（积累债务）
    public func recordBust(sessionID: SessionID) {
        var state = debtStatesBySession[sessionID] ?? CacheDebtState()
        state.cacheDebt = min(policy.maxCacheDebt, state.cacheDebt + 1)
        state.consecutiveHits = 0
        state.totalBusts += 1
        debtStatesBySession[sessionID] = state
    }

    /// 记录发生了一次压缩
    public func recordCompactionOccurred(sessionID: SessionID, step: Int) {
        var state = debtStatesBySession[sessionID] ?? CacheDebtState()
        state.lastCompactStep = step
        state.cacheDebt = min(policy.maxCacheDebt, state.cacheDebt + 1)
        state.consecutiveHits = 0
        debtStatesBySession[sessionID] = state
    }

    /// 核心决策函数：决定当前是否执行压缩
    /// - Parameters:
    ///   - currentTokens: 当前准备发送给 Provider 的总估计 Tokens
    ///   - hardLimit: 模型上下文窗口硬限制（必须保证不超出）
    ///   - economicThreshold: 经济学起征点（低于此门槛绝不主动压缩破坏缓存）
    ///   - estimatedEvictionTokens: 预估压缩能削减的 Tokens
    ///   - stablePrefixTokens: 被破坏的前缀中原本可复用的 Tokens
    ///   - remainingHorizon: 预估会话剩余请求轮次
    public func evaluate(
        sessionID: SessionID,
        currentTokens: Int,
        hardLimit: Int,
        economicThreshold: Int,
        estimatedEvictionTokens: Int,
        stablePrefixTokens: Int,
        remainingHorizon: Int?
    ) -> CompactDecision {
        // 1. 最高优先级：Window Protection（硬窗口保护）
        // 哪怕在经济上严重亏损，也必须保证绝对不能突破 Provider hardInputLimit 导致 400 失败！
        if currentTokens > hardLimit {
            return .emergencyWindowProtection(
                reason: "Context exceeds hard limit: current \(currentTokens) > hardLimit \(hardLimit)"
            )
        }

        // 2. 检查经济学起征点：低于起征点绝不压缩，保护前缀缓存
        if currentTokens <= economicThreshold {
            return .skip(
                reason: "Context below economic threshold: current \(currentTokens) <= threshold \(economicThreshold)"
            )
        }

        let state = debtStatesBySession[sessionID] ?? CacheDebtState()

        // 3. 检查 Cache Debt 门禁：债务过高说明近期缓存击穿过于频繁，禁止主动压缩
        if state.cacheDebt >= policy.maxCacheDebt {
            return .skip(
                reason: "Blocked by Cache Debt: current debt \(state.cacheDebt) >= max \(policy.maxCacheDebt)"
            )
        }

        // 4. Break-even 经济学公式计算
        // 设 C_write = 1.0, C_read = cacheReadWriteRatio (例如 0.1)
        // 成本 = stablePrefixTokens * 1.0
        // 收益 = horizon * estimatedEvictionTokens * cacheReadWriteRatio
        let horizon = max(policy.minHorizon, remainingHorizon ?? policy.defaultHorizon)
        guard estimatedEvictionTokens > 0 else {
            return .skip(reason: "Estimated eviction tokens is 0 or negative")
        }

        let neededHorizonDouble = Double(stablePrefixTokens) / (Double(estimatedEvictionTokens) * policy.cacheReadWriteRatio)
        let neededHorizon = max(1, Int(ceil(neededHorizonDouble)))

        if horizon < neededHorizon {
            return .skip(
                reason: "Economically unviable: need horizon >= \(neededHorizon) turns to break even, but actual horizon is \(horizon)"
            )
        }

        let expectedSavings = Int(Double(horizon * estimatedEvictionTokens) * policy.cacheReadWriteRatio) - stablePrefixTokens
        return .economicCompact(
            reason: "Break-even achieved: horizon \(horizon) >= \(neededHorizon), expected net savings ~\(expectedSavings) tokens"
        )
    }

    /// 重置会话状态
    public func reset(sessionID: SessionID) {
        debtStatesBySession.removeValue(forKey: sessionID)
    }
}
