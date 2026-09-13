import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

@Suite struct CacheAwareSchedulerTests {

    @Test func windowProtectionAlwaysTrumpsEconomics() async {
        let policy = EconomicCompactPolicy(maxCacheDebt: 2)
        let scheduler = CacheAwareContextScheduler(policy: policy)
        let sID = SessionID("s-window-protection")

        // 积累最高债务
        await scheduler.recordBust(sessionID: sID)
        await scheduler.recordBust(sessionID: sID)

        let state = await scheduler.debtState(for: sID)
        #expect(state.cacheDebt == 2)

        // 虽然债务已满且经济不划算，但当前 Token 超出 hardLimit (105_000 > 100_000)
        let decision = await scheduler.evaluate(
            sessionID: sID,
            currentTokens: 105_000,
            hardLimit: 100_000,
            economicThreshold: 50_000,
            estimatedEvictionTokens: 20_000,
            stablePrefixTokens: 10_000,
            remainingHorizon: 1
        )

        // 安全优先：必须触发紧急窗口保护
        #expect(decision.shouldCompact == true)
        if case let .emergencyWindowProtection(reason) = decision {
            #expect(reason.contains("Context exceeds hard limit"))
        } else {
            Issue.record("Expected emergencyWindowProtection, got \(decision)")
        }
    }

    @Test func belowEconomicThresholdSkipsCompaction() async {
        let scheduler = CacheAwareContextScheduler()
        let sID = SessionID("s-below-threshold")

        let decision = await scheduler.evaluate(
            sessionID: sID,
            currentTokens: 25_000,
            hardLimit: 100_000,
            economicThreshold: 50_000,
            estimatedEvictionTokens: 5_000,
            stablePrefixTokens: 3_000,
            remainingHorizon: 10
        )

        #expect(decision.shouldCompact == false)
        if case let .skip(reason) = decision {
            #expect(reason.contains("below economic threshold"))
        } else {
            Issue.record("Expected skip")
        }
    }

    @Test func breakEvenDecisionBasedOnHorizon() async {
        let policy = EconomicCompactPolicy(
            cacheReadWriteRatio: 0.1, // 读单价 0.1，写单价 1.0
            minHorizon: 2,
            maxCacheDebt: 2
        )
        let scheduler = CacheAwareContextScheduler(policy: policy)
        let sID = SessionID("s-breakeven")

        // 假设施加压缩能削减 2,000 tokens，但会破坏 4,000 tokens 的 Stable Prefix
        // 成本: 4,000 * 1.0 = 4,000
        // 每轮收益: 2,000 * 0.1 = 200 tokens
        // Break-even 所需轮数 H = 4,000 / 200 = 20 轮！

        // 1. Horizon 只有 5 轮 -> 净亏损，必须跳过
        let decisionShort = await scheduler.evaluate(
            sessionID: sID,
            currentTokens: 80_000,
            hardLimit: 100_000,
            economicThreshold: 50_000,
            estimatedEvictionTokens: 2_000,
            stablePrefixTokens: 4_000,
            remainingHorizon: 5
        )
        #expect(decisionShort.shouldCompact == false)
        if case let .skip(reason) = decisionShort {
            #expect(reason.contains("Economically unviable"))
            #expect(reason.contains(">= 20 turns"))
        } else {
            Issue.record("Expected skip due to short horizon")
        }

        // 2. Horizon 有 25 轮 -> 产生正向收益，允许压缩
        let decisionLong = await scheduler.evaluate(
            sessionID: sID,
            currentTokens: 80_000,
            hardLimit: 100_000,
            economicThreshold: 50_000,
            estimatedEvictionTokens: 2_000,
            stablePrefixTokens: 4_000,
            remainingHorizon: 25
        )
        #expect(decisionLong.shouldCompact == true)
        if case let .economicCompact(reason) = decisionLong {
            #expect(reason.contains("Break-even achieved"))
        } else {
            Issue.record("Expected economicCompact")
        }
    }

    @Test func cacheDebtAccumulationAndBlocking() async {
        let policy = EconomicCompactPolicy(
            cacheReadWriteRatio: 0.1,
            maxCacheDebt: 2,
            debtRecoveryTurns: 3
        )
        let scheduler = CacheAwareContextScheduler(policy: policy)
        let sID = SessionID("s-debt")

        // 初始状态：债务为 0
        var state = await scheduler.debtState(for: sID)
        #expect(state.cacheDebt == 0)

        // 发生 2 次 Cache Bust，债务积累到上限 2
        await scheduler.recordBust(sessionID: sID)
        await scheduler.recordBust(sessionID: sID)
        state = await scheduler.debtState(for: sID)
        #expect(state.cacheDebt == 2)

        // 即使 Break-even 成立，也因债务阻断
        let blockedDecision = await scheduler.evaluate(
            sessionID: sID,
            currentTokens: 80_000,
            hardLimit: 100_000,
            economicThreshold: 50_000,
            estimatedEvictionTokens: 10_000,
            stablePrefixTokens: 1_000,
            remainingHorizon: 10
        )
        #expect(blockedDecision.shouldCompact == false)
        if case let .skip(reason) = blockedDecision {
            #expect(reason.contains("Blocked by Cache Debt"))
        } else {
            Issue.record("Expected skip blocked by debt")
        }

        // 连续 3 轮 Hit，偿还 1 点债务
        await scheduler.recordHit(sessionID: sID)
        await scheduler.recordHit(sessionID: sID)
        await scheduler.recordHit(sessionID: sID)
        state = await scheduler.debtState(for: sID)
        #expect(state.cacheDebt == 1)

        // 债务降为 1 < 2，重新允许经济学压缩
        let unblockedDecision = await scheduler.evaluate(
            sessionID: sID,
            currentTokens: 80_000,
            hardLimit: 100_000,
            economicThreshold: 50_000,
            estimatedEvictionTokens: 10_000,
            stablePrefixTokens: 1_000,
            remainingHorizon: 10
        )
        #expect(unblockedDecision.shouldCompact == true)
    }
}
