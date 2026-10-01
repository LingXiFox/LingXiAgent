import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

/// 契约第四节：Context Value Eviction 的量化公式冻结实现。
/// 这些测试是契约的可执行副本 —— 权重、衰减、饱和、排序、Fail-Open 任一项被改动都会在这里失败，
/// 而不是等到真实 trace 校准时无据可查。
struct ContextValueEvictionTests {
    private func entry(_ id: String, role: ContextRole, source: ContextSource, content: String) -> ContextEntry {
        ContextEntry(messageID: MessageID(id), role: role, source: source, part: .text(content))
    }

    private func budget(hard: Int = 4_000, target: Int = 2_000, lowWater: Int = 1_200) -> ContextBudget {
        ContextBudget(hardInputLimit: hard, preferredActiveTokens: target, highWaterTokens: hard, lowWaterTokens: lowWater, reservedOutputTokens: 0, protocolOverheadTokens: 0, toolSchemaTokens: 0, safetyMarginTokens: 0)
    }

    /// 4.3 / 4.21：八项权重与三个系数逐字冻结，且权重之和恒为 1.00。
    @Test func frozenWeightsMatchTheContractExactly() {
        #expect(ContextValueWeights.taskAffinity == 0.24)
        #expect(ContextValueWeights.dependencyWeight == 0.18)
        #expect(ContextValueWeights.recency == 0.16)
        #expect(ContextValueWeights.relevance == 0.12)
        #expect(ContextValueWeights.frequency == 0.10)
        #expect(ContextValueWeights.activeFileAffinity == 0.10)
        #expect(ContextValueWeights.explicitReuse == 0.06)
        #expect(ContextValueWeights.irreplaceability == 0.04)
        #expect(ContextValueWeights.tokenCostPenalty == 0.35)
        #expect(ContextValueWeights.recencyTurnDecay == 8)
        #expect(ContextValueWeights.frequencySaturation == 8)
        #expect(abs(ContextValueWeights.retentionWeightSum - 1.0) < 1e-12)
    }

    /// 4.13：RetentionScore = R / (1 + 0.35 * C)，并按 4.6 / 4.7 / 4.12 归一化。
    @Test func retentionScoreMatchesHandComputedArithmetic() {
        let signals = ContextRetentionSignals(
            taskAffinity: 0.9,
            dependencyWeight: 0.6,
            deltaTurn: 4,
            relevance: 0.5,
            accessCount: 3,
            activeFileAffinity: 1.0,
            explicitReuse: 0.6,
            reconstructability: 0.7,
            tokenCost: 800
        )
        let estimate = ContextValueScorer.estimate(signals: signals, pCoreTarget: 2_000)
        let features = estimate.features

        let expectedRecency = exp(-4.0 / 8.0)
        let expectedFrequency = log(1 + 3.0) / log(1 + 8.0)
        let expectedCost = log2(801.0) / log2(2_001.0)
        let expectedValue =
            0.24 * 0.9 + 0.18 * 0.6 + 0.16 * expectedRecency + 0.12 * 0.5
            + 0.10 * expectedFrequency + 0.10 * 1.0 + 0.06 * 0.6 + 0.04 * (1 - 0.7)

        #expect(abs(features.recency - expectedRecency) < 1e-9)
        #expect(abs(features.frequency - expectedFrequency) < 1e-9)
        #expect(abs(features.normalizedTokenCost - expectedCost) < 1e-9)
        #expect(abs(features.irreplaceability - 0.3) < 1e-9)
        #expect(abs(estimate.retentionValue - expectedValue) < 1e-9)
        #expect(abs(estimate.retentionScore - expectedValue / (1 + 0.35 * expectedCost)) < 1e-9)
    }

    /// 4.12：tokenCost 用对数归一化，800 相对 200 不会被放大成 4 倍差距；
    /// 4.14：但大块低价值内容仍然应当比小块高价值内容更早离开 P-Core。
    @Test func tokenCostIsLogarithmicAndNotTheDominantSignal() {
        func cost(_ tokens: Int) -> Double {
            ContextValueScorer.estimate(
                signals: ContextRetentionSignals(taskAffinity: 0, dependencyWeight: 0, deltaTurn: 0, relevance: 0, accessCount: 0, activeFileAffinity: 0, explicitReuse: 0, reconstructability: 1, tokenCost: tokens),
                pCoreTarget: 20_000
            ).features.normalizedTokenCost
        }
        #expect(cost(800) / cost(200) < 2.0)
        #expect(cost(20_000) > cost(10_000))

        let editingLarge = ContextValueScorer.estimate(signals: ContextRetentionSignals(
            taskAffinity: 1.0, dependencyWeight: 1.0, deltaTurn: 0, relevance: 0.8, accessCount: 4,
            activeFileAffinity: 1.0, explicitReuse: 1.0, reconstructability: 0.7, tokenCost: 8_000
        ), pCoreTarget: 20_000)
        let finishedNoise = ContextValueScorer.estimate(signals: ContextRetentionSignals(
            taskAffinity: 0.0, dependencyWeight: 0.0, deltaTurn: 40, relevance: 0.0, accessCount: 0,
            activeFileAffinity: 0.0, explicitReuse: 0.0, reconstructability: 1.0, tokenCost: 300
        ), pCoreTarget: 20_000)

        // 4.14 的三个结论：正在编辑的大源码留下；已完成阶段的大日志先走；
        // 300 token 的无关旧状态不会因为"小"自动留下。
        #expect(editingLarge.retentionScore > finishedNoise.retentionScore)

        let staleTiny = ContextValueScorer.estimate(signals: ContextRetentionSignals(
            taskAffinity: 0.0, dependencyWeight: 0.0, deltaTurn: 60, relevance: 0.0, accessCount: 0,
            activeFileAffinity: 0.0, explicitReuse: 0.0, reconstructability: 1.0, tokenCost: 40
        ), pCoreTarget: 20_000)
        let hugeButEssential = ContextValueScorer.estimate(signals: ContextRetentionSignals(
            taskAffinity: 0.7, dependencyWeight: 1.0, deltaTurn: 1, relevance: 0.4, accessCount: 2,
            activeFileAffinity: 0.3, explicitReuse: 0.0, reconstructability: 0.3, tokenCost: 18_000
        ), pCoreTarget: 20_000)
        #expect(hugeButEssential.retentionScore > staleTiny.retentionScore)
    }

    /// 4.16：同分时的五级 tie-break，且不依赖输入顺序。
    @Test func tieBreakOrderIsDeterministicRegardlessOfInputOrder() {
        func candidate(key: String, score: Double, cost: Int, lastUsed: Int, created: Int) -> ContextEvictionCandidate {
            ContextEvictionCandidate(
                key: key,
                tokenCost: cost,
                lastUsedTurn: lastUsed,
                createdTurn: created,
                estimate: ContextRetentionEstimate(features: .zero, retentionValue: 0, retentionScore: score),
                unitIndices: [0]
            )
        }
        let inputs = [
            candidate(key: "b", score: 0.1, cost: 500, lastUsed: 3, created: 1),
            candidate(key: "a", score: 0.1, cost: 900, lastUsed: 3, created: 1),
            candidate(key: "c", score: 0.1, cost: 900, lastUsed: 1, created: 1),
            candidate(key: "d", score: 0.1, cost: 900, lastUsed: 1, created: 0),
            candidate(key: "e", score: 0.05, cost: 100, lastUsed: 9, created: 9),
        ]
        // score 升序 → tokenCost 降序 → lastUsedTurn 升序 → createdTurn 升序 → key 字典序。
        let expected = ["e", "d", "c", "a", "b"]
        #expect(ContextValueScorer.evictionOrder(inputs).map(\.key) == expected)
        #expect(ContextValueScorer.evictionOrder(inputs.reversed()).map(\.key) == expected)
        #expect(ContextValueScorer.evictionOrder([inputs[2], inputs[4], inputs[0], inputs[3], inputs[1]]).map(\.key) == expected)
    }

    /// 4.2 / 4.15：pinned 对象完全不进入评分与排序，不是"给一个高分"。
    @Test func pinnedObjectsNeverEnterEvictionScoring() async throws {
        let sessionID = SessionID("pinned-never-scored")
        let compactor = ContextCompactor()
        let hugeSystem = entry("constraint", role: .system, source: .system, content: String(repeating: "operational constraint text ", count: 120))
        let pending = ToolExchangeBatch(
            batchID: "pending-batch",
            sessionID: sessionID,
            assistantMessageID: MessageID("pending-assistant"),
            toolCalls: [ToolCall(callID: ToolCallID("pending-call"), toolID: ToolID("shell"), arguments: "{\"command\":\"make test\"}")],
            providerStep: 1,
            state: .pending,
            estimatedTokens: 10
        )
        let pendingEntries = [
            ContextEntry(messageID: MessageID("pending-assistant"), role: .assistant, source: .assistantMessage, part: .toolCall(ToolCall(callID: ToolCallID("pending-call"), toolID: ToolID("shell"), arguments: "{\"command\":\"make test\"}"))),
        ]
        let entries = [
            hugeSystem,
            entry("old", role: .assistant, source: .assistantMessage, content: String(repeating: "stale unrelated history ", count: 60)),
            entry("current", role: .user, source: .userMessage, content: "current question"),
        ] + pendingEntries

        let result = try await compactor.compact(
            sessionID: sessionID,
            entries: entries,
            budget: budget(hard: 4_000, target: 1_000, lowWater: 600),
            batches: [pending],
            trigger: .manual,
            currentTurn: 5
        )
        let trace = await compactor.evictionTrace(sessionID: sessionID)
        let scoredKeys = Set(trace.map(\.objectKey))

        #expect(result.entries.contains { $0.messageID == hugeSystem.messageID }, "pinned 的大对象不得因 token 大而移出")
        #expect(result.entries.contains { $0.messageID == MessageID("pending-assistant") }, "pending Tool Call 不参与 eviction")
        #expect(!scoredKeys.contains("constraint"), "pinned 对象不进入候选集，而不是被赋予高分数")
        #expect(!scoredKeys.contains("pending-assistant"))
        #expect(scoredKeys.contains("old"))
    }

    /// 4.19 Fail-Open：scorer 拿不到可靠输入时退回确定性顺序，Agent Loop 不因此失败。
    @Test func failOpenFallsBackToDeterministicLegacyOrder() async throws {
        let compactor = ContextCompactor()
        // preferredActiveTokens == 0 → 无法归一化 tokenCost，必须退回旧顺序。
        let zeroTarget = ContextBudget(hardInputLimit: 4_000, preferredActiveTokens: 0, highWaterTokens: 4_000, lowWaterTokens: 600, reservedOutputTokens: 0, protocolOverheadTokens: 0, toolSchemaTokens: 0, safetyMarginTokens: 0)
        let entries = [
            entry("old-a", role: .assistant, source: .assistantMessage, content: String(repeating: "legacy order candidate ", count: 80)),
            entry("old-b", role: .tool, source: .toolResult, content: String(repeating: "tool noise ", count: 80)),
            entry("current", role: .user, source: .userMessage, content: "current question"),
        ]

        let first = try await compactor.compact(sessionID: SessionID("fail-open"), entries: entries, budget: zeroTarget, trigger: .manual)
        let second = try await compactor.compact(sessionID: SessionID("fail-open"), entries: entries, budget: zeroTarget, trigger: .manual)

        #expect(first.pagedOut > 0, "scorer 不可用不能让整个 compaction 失败")
        #expect(first.entries.map(\.messageID) == second.entries.map(\.messageID), "fallback 本身必须确定性")
        #expect(await compactor.evictionScoringActive(sessionID: SessionID("fail-open")) == false)
        // 禁止的退路：不淘汰最新对象（current 是 mandatory，始终在）。
        #expect(first.entries.contains { $0.messageID == MessageID("current") })
    }

    /// 4.9 / 4.20：activeFileAffinity 必须由真实数据流驱动，且全部特征在 Inspector 可见。
    @Test func activeFileAffinityIsDrivenByRealSessionFileTraffic() async throws {
        let sessionID = SessionID("active-file-affinity")
        let compactor = ContextCompactor()
        let editedPath = "Sources/A.swift"
        let unrelatedPath = "Sources/Other/Unrelated.swift"

        func batch(_ id: String, path: String, changed: [String] = []) -> ToolExchangeBatch {
            ToolExchangeBatch(
                batchID: id,
                sessionID: sessionID,
                assistantMessageID: MessageID("\(id)-assistant"),
                resultMessageID: MessageID("\(id)-result"),
                toolCalls: [ToolCall(callID: ToolCallID("\(id)-call"), toolID: ToolID("read_file"), arguments: "{\"path\":\"\(path)\"}")],
                toolResults: [ToolResult(callID: ToolCallID("\(id)-call"), success: true, content: String(repeating: "body ", count: 40), changedFiles: changed)],
                providerStep: 1,
                state: .consumed,
                estimatedTokens: 40
            )
        }
        // read-other 落在最近 4 个批次之外，才能验证"无文件关系 → 0.0"这一档真实存在。
        let batches = [
            batch("read-other", path: unrelatedPath),
            batch("filler-a", path: "Sources/Filler/a.swift"),
            batch("filler-b", path: "Sources/Filler/b.swift"),
            batch("read-target", path: editedPath),
            batch("mutation", path: editedPath, changed: [editedPath]),
        ]

        var entries: [ContextEntry] = [entry("current", role: .user, source: .userMessage, content: "current question")]
        for candidateBatch in batches {
            for call in candidateBatch.toolCalls {
                entries.append(ContextEntry(messageID: candidateBatch.assistantMessageID, role: .assistant, source: .assistantMessage, part: .toolCall(call)))
            }
            for result in candidateBatch.toolResults {
                entries.append(ContextEntry(messageID: MessageID("\(candidateBatch.batchID)-result"), role: .tool, source: .toolResult, part: .toolResult(result)))
            }
        }

        _ = try await compactor.compact(
            sessionID: sessionID,
            entries: entries,
            budget: budget(hard: 4_000, target: 1_000, lowWater: 100),
            batches: batches,
            trigger: .manual,
            currentTurn: 9
        )
        let trace = await compactor.evictionTrace(sessionID: sessionID)
        let byKey = Dictionary(uniqueKeysWithValues: trace.map { ($0.objectKey, $0) })
        let target = try #require(byKey["read-target"])
        let other = try #require(byKey["read-other"])

        #expect(target.features.activeFileAffinity == 1.0, "当前正在编辑的文件的 read_file 必须是 1.0")
        #expect(other.features.activeFileAffinity == 0.0, "无文件关系必须落到 0.0，不能恒为同一个值")
        #expect(target.features.dependencyWeight == 1.0)
        #expect(target.retentionScore > other.retentionScore)
        // 4.20：Inspector 需要看到全部冻结字段，否则权重只能凭感觉调。
        for observation in trace {
            #expect(!observation.objectKey.isEmpty)
            #expect(observation.tokenCost > 0)
            let features = observation.features
            for value in [features.taskAffinity, features.dependencyWeight, features.recency, features.relevance, features.frequency, features.activeFileAffinity, features.explicitReuse, features.irreplaceability, features.normalizedTokenCost] {
                #expect(value >= 0 && value <= 1)
            }
        }
        let ranks = trace.compactMap(\.evictionRank)
        #expect(ranks == Array(1...ranks.count))
        // 无文件关系的旧读取先走，正在编辑文件的读取后走（或留下）：顺序即契约。
        let otherRank = try #require(byKey["read-other"]?.evictionRank)
        let targetRank = try #require(byKey["read-target"]?.evictionRank ?? ranks.count + 1)
        #expect(otherRank < targetRank)
    }

    /// 第六节：E-Core Heat 不是 P-Core eviction 的输入。
    /// compactor 记录的每一项必须仍然严格满足冻结恒等式 —— 一旦 heat 之类的额外信号混进
    /// retentionValue，等式就会破，所以这条不变式同时是边界守卫。
    @Test func recordedEvictionScoresSatisfyTheFrozenIdentity() async throws {
        let sessionID = SessionID("heat-independent")
        let compactor = ContextCompactor()
        let stale = entry("stale", role: .assistant, source: .assistantMessage, content: String(repeating: "completed phase log line ", count: 90))
        let fresh = entry("fresh", role: .assistant, source: .assistantMessage, content: String(repeating: "current question analysis ", count: 90))
        let entries = [
            entry("constraint", role: .system, source: .system, content: "constraint"),
            stale,
            fresh,
            entry("current", role: .user, source: .userMessage, content: "current question"),
        ]
        _ = try await compactor.compact(sessionID: sessionID, entries: entries, budget: budget(hard: 4_000, target: 1_000, lowWater: 300), trigger: .manual, currentTurn: 3)
        let trace = await compactor.evictionTrace(sessionID: sessionID)
        #expect(trace.count == 2)
        #expect(await compactor.evictionScoringActive(sessionID: sessionID))

        for observation in trace {
            let features = observation.features
            let expectedValue =
                ContextValueWeights.taskAffinity * features.taskAffinity
                + ContextValueWeights.dependencyWeight * features.dependencyWeight
                + ContextValueWeights.recency * features.recency
                + ContextValueWeights.relevance * features.relevance
                + ContextValueWeights.frequency * features.frequency
                + ContextValueWeights.activeFileAffinity * features.activeFileAffinity
                + ContextValueWeights.explicitReuse * features.explicitReuse
                + ContextValueWeights.irreplaceability * features.irreplaceability
            #expect(abs(observation.retentionValue - expectedValue) < 1e-12)
            #expect(abs(observation.retentionScore - observation.retentionValue / (1 + ContextValueWeights.tokenCostPenalty * features.normalizedTokenCost)) < 1e-12)
        }
        // 与当前 query 无关的历史日志必须比正在分析的上下文先离开 P-Core。
        let staleScore = try #require(trace.first { $0.objectKey == "stale" }).retentionScore
        let freshScore = try #require(trace.first { $0.objectKey == "fresh" }).retentionScore
        #expect(staleScore < freshScore)
    }
}
