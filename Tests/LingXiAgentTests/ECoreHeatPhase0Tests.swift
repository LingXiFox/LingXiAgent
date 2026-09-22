import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

@Suite struct ECoreHeatPhase0Tests {

    // 1. 正常 recall 触发 objectRecalled 事件
    @Test func testNormalRecallTriggersObjectRecalledEvent() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            objectizationThreshold: 100,
            heatTrackingEnabled: true
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sID = SessionID("s-heat-recall-normal")
        let content = String(repeating: "Recall Content Line\n", count: 20)

        guard let meta = await store.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_norm_1"),
            toolName: "read_file",
            content: content
        ) else {
            Issue.record("Failed to store object")
            return
        }

        let chunk = try await store.recall(
            sessionID: sID,
            objectID: meta.objectID,
            offsetBytes: 0,
            limitBytes: 50
        )
        #expect(chunk != nil)

        let events = try await PortableFixture.eventually(
            { await store.telemetryLogger.readEvents(for: sID) },
            enough: { $0.count >= 2 }
        )
        try #require(events.count == 2)
        #expect(events[0].eventType == .objectStored)
        #expect(events[0].objectID == meta.objectID)

        #expect(events[1].eventType == .objectRecalled)
        #expect(events[1].objectID == meta.objectID)
        #expect(events[1].returnedBytes == chunk?.lengthBytes)
        #expect(events[1].offsetBytes == 0)
    }

    // 2. recall miss 触发 recallMiss 事件
    @Test func testRecallMissTriggersRecallMissEvent() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            heatTrackingEnabled: true
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sID = SessionID("s-heat-recall-miss")
        let nonExistentID = try ContextObjectID("obj_test_call_missing")

        let chunk = try await store.recall(
            sessionID: sID,
            objectID: nonExistentID,
            offsetBytes: 10,
            limitBytes: 100
        )
        #expect(chunk == nil)

        let events = try await PortableFixture.eventually(
            { await store.telemetryLogger.readEvents(for: sID) },
            enough: { $0.count >= 1 }
        )
        try #require(events.count == 1)
        #expect(events[0].eventType == .recallMiss)
        #expect(events[0].objectID == nonExistentID)
        #expect(events[0].offsetBytes == 10)
        #expect(events[0].requestedBytes == 100)
    }

    // 3. 高频对象 Heat 上升
    @Test func testHighFrequencyAccessIncreasesHeat() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            objectizationThreshold: 10,
            heatTrackingEnabled: true
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sID = SessionID("s-heat-frequency")

        guard let metaA = await store.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_a"),
            toolName: "test_a",
            content: "Alpha Content Repeated Many Times\n"
        ),
        let metaB = await store.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_b"),
            toolName: "test_b",
            content: "Beta Content Repeated Many Times\n"
        ) else {
            Issue.record("Failed to store objects in testHighFrequencyAccessIncreasesHeat")
            return
        }

        // 对 A 进行多次召回
        for _ in 1...5 {
            _ = try await store.recall(sessionID: sID, objectID: metaA.objectID)
        }

        let stateA = await store.heatState(sessionID: sID, objectID: metaA.objectID)
        let stateB = await store.heatState(sessionID: sID, objectID: metaB.objectID)

        #expect(stateA != nil)
        #expect(stateB != nil)
        #expect((stateA?.recallCount ?? 0) == 5)
        #expect((stateB?.recallCount ?? 0) == 0)
        #expect((stateA?.rawHeatScore ?? 0) > (stateB?.rawHeatScore ?? 0))

        // 快照验证
        let snapshot = await store.heatSnapshot(sessionID: sID, topN: 2)
        #expect(snapshot != nil)
        #expect(snapshot?.topHottestObjects.first?.objectID == metaA.objectID)
    }

    // 4. 长期未访问对象衰减（Decayed Accumulator 纯时间流逝验证）
    @Test func testInactiveObjectHeatDecaysOverTime() {
        let halfLife: Double = 3600.0 // 1 hour
        let initialScore = 12.0

        // 经过 1 个半衰期 (3600s)
        let heat1 = ECoreHeatScorer.decayedScore(
            currentScore: initialScore,
            elapsedSeconds: 3600.0,
            halfLifeSeconds: halfLife
        )

        // 经过 2 个半衰期 (7200s)
        let heat2 = ECoreHeatScorer.decayedScore(
            currentScore: initialScore,
            elapsedSeconds: 7200.0,
            halfLifeSeconds: halfLife
        )

        #expect(abs(heat1 - initialScore * 0.5) < 1e-4)
        #expect(abs(heat2 - initialScore * 0.25) < 1e-4)
        #expect(heat2 < heat1)
        #expect(heat1 < initialScore)
    }

    // 5. percentile 与 quantile 计算正确性
    @Test func testPercentileAndQuantileCalculation() {
        let values = [10.0, 20.0, 30.0, 40.0, 50.0]

        let median = RobustDistributionCalculator.median(values)
        #expect(median == 30.0)

        let q0 = RobustDistributionCalculator.quantile(0.0, sortedValues: values)
        #expect(q0 == 10.0)

        let q50 = RobustDistributionCalculator.quantile(0.5, sortedValues: values)
        #expect(q50 == 30.0)

        let q100 = RobustDistributionCalculator.quantile(1.0, sortedValues: values)
        #expect(q100 == 50.0)

        let q75 = RobustDistributionCalculator.quantile(0.75, sortedValues: values)
        #expect(q75 == 40.0)

        // 中点百分位排名检验
        let rank10 = RobustDistributionCalculator.percentileRank(value: 10.0, sortedValues: values)
        let rank30 = RobustDistributionCalculator.percentileRank(value: 30.0, sortedValues: values)
        let rank50 = RobustDistributionCalculator.percentileRank(value: 50.0, sortedValues: values)

        #expect(rank10 == 0.1) // (0 + 0.5) / 5 = 0.1
        #expect(rank30 == 0.5) // (2 + 0.5) / 5 = 0.5
        #expect(rank50 == 0.9) // (4 + 0.5) / 5 = 0.9
    }

    // 6. MAD == 0 时的稳健退化处理与非正态极度偏态分布测试
    @Test func testMadZeroRobustDegradationAndSkewedDistribution() {
        // 场景 A: 所有元素相同，MAD == 0
        let identicalValues = [4.0, 4.0, 4.0, 4.0, 4.0]
        let med = RobustDistributionCalculator.median(identicalValues)
        #expect(med == 4.0)

        let mad = RobustDistributionCalculator.mad(identicalValues, median: med)
        #expect(mad == 0.0)

        // 正常相同值计算 robustZScore
        let zSame = RobustDistributionCalculator.robustZScore(value: 4.0, median: med, mad: mad)
        #expect(zSame == 0.0)

        // 出现离群值时的有界退化保护
        let zOutlierHigh = RobustDistributionCalculator.robustZScore(value: 10.0, median: med, mad: mad)
        #expect(zOutlierHigh > 0.0)
        #expect(zOutlierHigh.isFinite)
        #expect(zOutlierHigh <= 10.0)

        let zOutlierLow = RobustDistributionCalculator.robustZScore(value: 0.0, median: med, mad: mad)
        #expect(zOutlierLow < 0.0)
        #expect(zOutlierLow.isFinite)
        #expect(zOutlierLow >= -10.0)

        // 场景 B: 极度偏态分布（99 个 0.0，1 个 100.0）
        var skewedValues = Array(repeating: 0.0, count: 99)
        skewedValues.append(100.0)
        skewedValues.sort()

        let medSkew = RobustDistributionCalculator.median(skewedValues)
        #expect(medSkew == 0.0)

        let madSkew = RobustDistributionCalculator.mad(skewedValues, median: medSkew)
        #expect(madSkew == 0.0)

        let rankZero = RobustDistributionCalculator.percentileRank(value: 0.0, sortedValues: skewedValues)
        let rankHundred = RobustDistributionCalculator.percentileRank(value: 100.0, sortedValues: skewedValues)

        // 99 个 0.0 的中点百分位为 49.5%，绝不虚高为 99% 或 100%
        #expect(rankZero < 0.55 && rankZero > 0.45)
        #expect(rankHundred > 0.99)

        // 场景 C: 边界处理（空集合与单元素集合）
        #expect(RobustDistributionCalculator.median([]) == 0.0)
        #expect(RobustDistributionCalculator.mad([], median: 0.0) == 0.0)
        #expect(RobustDistributionCalculator.percentileRank(value: 1.0, sortedValues: []) == 0.0)
        #expect(RobustDistributionCalculator.quantile(0.5, sortedValues: []) == 0.0)

        let single = [42.0]
        #expect(RobustDistributionCalculator.median(single) == 42.0)
        #expect(RobustDistributionCalculator.mad(single, median: 42.0) == 0.0)
        #expect(RobustDistributionCalculator.percentileRank(value: 42.0, sortedValues: single) == 0.5)
        #expect(RobustDistributionCalculator.quantile(0.5, sortedValues: single) == 42.0)
    }

    // 7. 遥测写入异常时不影响 recall 结果（Fail-Open）
    @Test func testTelemetryWriteFailureFailOpen() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            objectizationThreshold: 10,
            heatTrackingEnabled: true
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sID = SessionID("s-heat-fail-open")
        let content = "Critical Content That Must Be Recalled Safely\n"

        guard let meta = await store.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_fail_open"),
            toolName: "test_tool",
            content: content
        ) else {
            Issue.record("Store failed")
            return
        }

        // store 已经成功！现在我们把 telemetry 日志路径设置成不可写（0o444 只读文件，阻断 FileHandle 追加）
        let logURL = await store.telemetryLogger.eventLogURL(for: sID)
        let telemetryDir = logURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: telemetryDir, withIntermediateDirectories: true)
        try "".write(to: logURL, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: logURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: logURL.path)
        }

        // 执行 recall，即使 telemetry 写入受阻，recall 必须坚固如常，绝不抛出崩溃
        let chunk = try await store.recall(sessionID: sID, objectID: meta.objectID)
        #expect(chunk != nil)
        #expect(chunk?.content == content)
        #expect(chunk?.totalBytes == content.utf8.count)
    }

    // 8. telemetry 关闭时完全静默，零额外开销
    @Test func testTelemetryDisabledSilent() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            objectizationThreshold: 10,
            heatTrackingEnabled: false // 禁用 Heat 遥测跟踪
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sID = SessionID("s-heat-disabled")
        let content = "Disabled Heat Tracking Content\n"

        guard let meta = await store.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_silent"),
            toolName: "test_tool",
            content: content
        ) else {
            Issue.record("Store failed")
            return
        }

        let chunk = try await store.recall(sessionID: sID, objectID: meta.objectID)
        #expect(chunk != nil)

        try await Task.sleep(for: .milliseconds(50))

        // 验证日志完全没有生成
        let events = await store.telemetryLogger.readEvents(for: sID)
        #expect(events.isEmpty)

        // 验证内存状态为空
        let state = await store.heatState(sessionID: sID, objectID: meta.objectID)
        #expect(state == nil)

        // 快照亦返回 nil
        let snapshot = await store.heatSnapshot(sessionID: sID)
        #expect(snapshot == nil)
    }

    // 9. 验证 context_recall 返回值与未引入 Heat 前 100% 一致
    @Test func testContextRecallOutputIdentical() async throws {
        let tempDir1 = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let tempDir2 = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: tempDir1)
            try? FileManager.default.removeItem(at: tempDir2)
        }

        let configWithHeat = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            objectizationThreshold: 10,
            heatTrackingEnabled: true
        )
        let configWithoutHeat = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            objectizationThreshold: 10,
            heatTrackingEnabled: false
        )

        let storeWithHeat = ECoreObjectStore(baseDirectory: tempDir1, configuration: configWithHeat)
        let storeWithoutHeat = ECoreObjectStore(baseDirectory: tempDir2, configuration: configWithoutHeat)
        let sID = SessionID("s-recall-verify")
        let content = "Line 1: Alpha\nLine 2: Beta\nLine 3: Gamma\n"

        guard let meta1 = await storeWithHeat.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_identical"),
            toolName: "read_file",
            content: content
        ),
        let meta2 = await storeWithoutHeat.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_identical"),
            toolName: "read_file",
            content: content
        ) else {
            Issue.record("Store failed")
            return
        }

        // 直接通过 ContextRecallTool 执行调用
        let recallToolWithHeat = ContextRecallTool(ecoreStore: storeWithHeat, sessionID: sID)
        let recallToolWithoutHeat = ContextRecallTool(ecoreStore: storeWithoutHeat, sessionID: sID)

        let args = "{\"id\": \"\(meta1.objectID.rawValue)\", \"offset\": 0, \"limitBytes\": 100}"
        let outputWithHeat = try await recallToolWithHeat.execute(arguments: args, profile: .fullAccess)
        let outputWithoutHeat = try await recallToolWithoutHeat.execute(arguments: args, profile: .fullAccess)

        #expect(outputWithHeat == outputWithoutHeat)

        let chunkWithHeat = try await storeWithHeat.recall(sessionID: sID, objectID: meta1.objectID)
        let chunkWithoutHeat = try await storeWithoutHeat.recall(sessionID: sID, objectID: meta2.objectID)
        #expect(chunkWithHeat == chunkWithoutHeat)
    }

    // 10. 高频历史对象长时间沉寂后热度正确衰减
    @Test func testHistoricalHighFrequencyObjectDecaysOverTime() {
        let halfLife: Double = 3600.0 // 1 hour
        let historicalHighHeat = 100.0 // 经历大量访问后的高热度

        // 沉寂 10 个半衰期 (36000s)
        let decayed = ECoreHeatScorer.decayedScore(
            currentScore: historicalHighHeat,
            elapsedSeconds: 36_000.0,
            halfLifeSeconds: halfLife
        )

        // 100 * 0.5^10 = 100 / 1024 ≈ 0.09765
        #expect(abs(decayed - (100.0 / 1024.0)) < 1e-4)
        #expect(decayed < 0.1)
    }

    // 11. 沉寂对象发生一次新 recall 时，只增加本次事件贡献，不恢复全部历史热度
    @Test func testInactiveObjectNewRecallDoesNotReviveHistoricalHeat() {
        let halfLife: Double = 3600.0
        let historicalHighHeat = 100.0
        let baseDate = Date(timeIntervalSince1970: 1_000_000)

        // 经过 15 个半衰期（长时间沉寂，历史热度已衰减至几乎为 0）
        let elapsed = 15.0 * halfLife
        let newEventTime = baseDate.addingTimeInterval(elapsed)
        let recallWeight = 2.0

        let updatedScore = ECoreHeatScorer.accumulate(
            currentScore: historicalHighHeat,
            lastUpdatedAt: baseDate,
            now: newEventTime,
            eventWeight: recallWeight,
            halfLifeSeconds: halfLife
        )

        // 衰减后的历史热度: 100 * (0.5^15) ≈ 0.00305
        // 新热度 = 0.00305 + 2.0 = 2.00305
        #expect(updatedScore > 2.0)
        #expect(updatedScore < 2.01)
        // 关键断言：绝对不能复活到旧的 100.0 或者 50+！
        #expect(updatedScore < 5.0)
    }

    // 12. 连续短时间 recall 正确累积
    @Test func testConsecutiveShortTimeRecallsAccumulateCorrectly() {
        let halfLife: Double = 3600.0
        var score = 1.0 // 初始 storedWeight
        var currentTime = Date(timeIntervalSince1970: 1_000_000)

        // 连续 5 次 recall，每次间隔 0.5 秒
        for _ in 1...5 {
            let nextTime = currentTime.addingTimeInterval(0.5)
            score = ECoreHeatScorer.accumulate(
                currentScore: score,
                lastUpdatedAt: currentTime,
                now: nextTime,
                eventWeight: 2.0,
                halfLifeSeconds: halfLife
            )
            currentTime = nextTime
        }

        // 0.5 秒衰减微乎其微 (0.5 / 3600 ≈ 0.000138)，5 次累计热度应非常接近 1.0 + 5 * 2.0 = 11.0
        #expect(score > 10.95 && score <= 11.0)
    }

    // 13. 不同半衰期行为正确
    @Test func testDifferentHalfLifeBehaviors() {
        let initialScore = 10.0
        let elapsed = 3600.0

        let halfLifeFast = 1800.0  // 3600s 经过 2 个半衰期 -> 25%
        let halfLifeStandard = 3600.0 // 3600s 经过 1 个半衰期 -> 50%
        let halfLifeSlow = 7200.0  // 3600s 经过 0.5 个半衰期 -> ~70.71%

        let scoreFast = ECoreHeatScorer.decayedScore(currentScore: initialScore, elapsedSeconds: elapsed, halfLifeSeconds: halfLifeFast)
        let scoreStandard = ECoreHeatScorer.decayedScore(currentScore: initialScore, elapsedSeconds: elapsed, halfLifeSeconds: halfLifeStandard)
        let scoreSlow = ECoreHeatScorer.decayedScore(currentScore: initialScore, elapsedSeconds: elapsed, halfLifeSeconds: halfLifeSlow)

        #expect(abs(scoreFast - 2.5) < 1e-4)
        #expect(abs(scoreStandard - 5.0) < 1e-4)
        #expect(abs(scoreSlow - 10.0 * sqrt(0.5)) < 1e-4)
        #expect(scoreFast < scoreStandard)
        #expect(scoreStandard < scoreSlow)
    }

    // 14. 时间倒退 / Δt < 0 时安全处理
    @Test func testTimeReversalAndNegativeDeltaTSafeHandling() {
        let baseDate = Date(timeIntervalSince1970: 1_000_000)
        let pastDate = Date(timeIntervalSince1970: 999_900) // 时间倒退 100 秒

        let score = 5.0
        // 测试 decayedScore 在负流逝下的保护
        let decayed = ECoreHeatScorer.decayedScore(
            currentScore: score,
            elapsedSeconds: -100.0,
            halfLifeSeconds: 3600.0
        )
        #expect(decayed == score)

        // 测试 accumulate 在倒退时间下的保护
        let accumulated = ECoreHeatScorer.accumulate(
            currentScore: score,
            lastUpdatedAt: baseDate,
            now: pastDate,
            eventWeight: 2.0,
            halfLifeSeconds: 3600.0
        )
        // 倒退视为 Δt = 0，衰减因子为 1.0，新热度 = 5.0 + 2.0 = 7.0
        #expect(accumulated == 7.0)
    }

    // 15. NaN / Infinity 不得进入 Heat State
    @Test func testNanAndInfinityRejectedFromHeatState() {
        let nan = Double.nan
        let inf = Double.infinity
        let negInf = -Double.infinity

        // Scorer 防御
        #expect(ECoreHeatScorer.decayedScore(currentScore: nan, elapsedSeconds: 10) == 0.0)
        #expect(ECoreHeatScorer.decayedScore(currentScore: inf, elapsedSeconds: 10) == 0.0)
        #expect(ECoreHeatScorer.decayedScore(currentScore: negInf, elapsedSeconds: 10) == 0.0)

        #expect(ECoreHeatScorer.accumulate(currentScore: 1.0, lastUpdatedAt: .now, now: .now, eventWeight: nan) == 1.0)
        #expect(ECoreHeatScorer.accumulate(currentScore: nan, lastUpdatedAt: .now, now: .now, eventWeight: 2.0) == 2.0)

        // HeatState 初始化防御
        let id = try! ContextObjectID("obj_test_defense")
        let stateNan = ECoreHeatState(objectID: id, rawHeatScore: nan)
        #expect(stateNan.rawHeatScore == 0.0)

        let stateInf = ECoreHeatState(objectID: id, rawHeatScore: inf)
        #expect(stateInf.rawHeatScore == 0.0)

        let stateNeg = ECoreHeatState(objectID: id, rawHeatScore: -5.0)
        #expect(stateNeg.rawHeatScore == 0.0)
    }

    // 16. 观测期分析器在重尾分布与 Pareto 分析下的计算准确性
    @Test func testObservationAnalyzerWithSyntheticWorkload() {
        let baseDate = Date(timeIntervalSince1970: 1_000_000)
        var metadataList: [ObservationMetadata] = []
        var events: [ECoreAccessEvent] = []

        // 构造 100 个对象：
        // 90 个从未被召回 (never recalled)
        // 5 个各被召回 1 次 (共 5 次)
        // 5 个高频对象各被召回 15 次 (共 75 次)
        // 总召回数 = 80 次，Top 5% 对象 (5个) 贡献 75 次 = 93.75% 召回，呈现极其显著的 Pareto 重尾
        let totalCount = 100
        for i in 1...totalCount {
            let objID = try! ContextObjectID("obj_synthetic_\(i)")
            let meta = ObservationMetadata(
                objectID: objID,
                toolCallID: ToolCallID("call_\(i)"),
                toolName: "read_file",
                contentType: "text/plain",
                totalLines: 10,
                totalBytes: 1000,
                createdAt: baseDate,
                contentHash: "hash_\(i)"
            )
            metadataList.append(meta)
            events.append(ECoreAccessEvent(sessionID: SessionID("s_synth"), objectID: objID, eventType: .objectStored, timestamp: baseDate))

            if i <= 5 {
                // Top 5% 高频对象
                for r in 1...15 {
                    let recallTime = baseDate.addingTimeInterval(Double(r * 60))
                    events.append(ECoreAccessEvent(
                        sessionID: SessionID("s_synth"),
                        objectID: objID,
                        eventType: .objectRecalled,
                        timestamp: recallTime,
                        returnedBytes: 500
                    ))
                }
            } else if i <= 10 {
                // 低频对象 (1次)
                let recallTime = baseDate.addingTimeInterval(300.0)
                events.append(ECoreAccessEvent(
                    sessionID: SessionID("s_synth"),
                    objectID: objID,
                    eventType: .objectRecalled,
                    timestamp: recallTime,
                    returnedBytes: 500
                ))
            }
        }

        let metrics = ECoreObservationAnalyzer.analyze(
            events: events,
            metadataList: metadataList,
            now: baseDate.addingTimeInterval(3600.0)
        )

        #expect(metrics.totalObjects == 100)
        #expect(metrics.neverRecalledObjectsCount == 90)
        #expect(abs(metrics.neverRecalledRatio - 0.90) < 1e-4)
        #expect(metrics.totalRecalledEvents == 80)

        // 验证 Pareto 分布表
        let top5Bucket = metrics.paretoDistribution.first(where: { $0.topPercentileLabel == "Top 5%" })
        #expect(top5Bucket != nil)
        #expect(top5Bucket?.objectCount == 5)
        #expect(top5Bucket?.recallCount == 75)
        // 75 / 80 = 93.75%
        #expect(abs((top5Bucket?.recallContributionRatio ?? 0) - (75.0 / 80.0)) < 1e-4)

        let top10Bucket = metrics.paretoDistribution.first(where: { $0.topPercentileLabel == "Top 10%" })
        #expect(top10Bucket?.recallCount == 80)
        #expect(top10Bucket?.recallContributionRatio == 1.0)

        // 验证时延
        #expect(metrics.timeToFirstRecallSecondsMin == 60.0)
        #expect(metrics.heatRecallCorrelation > 0.8) // 强正相关
    }

    // 17. 真实工作区 ~/.lingxiagent/sessions 观测期指标实采
    @Test func testRealWorldECoreDataObservation() {
        let home: URL
        if let customHome = ProcessInfo.processInfo.environment["HOME"], !customHome.isEmpty {
            home = URL(fileURLWithPath: customHome)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        let sessionsDir = home.appendingPathComponent(".lingxiagent", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            return
        }

        let metrics = ECoreObservationAnalyzer.analyzeDirectory(baseDirectory: sessionsDir)
        #expect(metrics.totalObjects >= 0)
    }

    // 18. Phase 0.6: ContextProjection 触发 objectProjected 旁路事件且递增 projectionCount
    @Test func testContextProjectionTriggersObjectProjectedEvent() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            observationProjectionEnabled: true,
            objectizationThreshold: 1000,
            fullSendCount: 2,
            heatTrackingEnabled: true
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let projector = ContextProjection(configuration: config)

        let sessionID = SessionID("s-proj-opportunity-test")
        let toolCallID = ToolCallID("call_large_proj_1")
        let largeContent = String(repeating: "Line of important tool output to be projected.\n", count: 50) // > 2KB
        let toolName = "execute_command"

        // 构造会话：包含 2 个 assistant 消息（满足 fullSendCount >= 2 门槛）
        let toolMsgID = MessageID("msg_tool_1")
        let toolResult = ToolResult(callID: toolCallID, success: true, content: largeContent, toolName: toolName)
        let messages: [Message] = [
            Message(id: toolMsgID, role: .tool, parts: [.toolResult(toolResult)], createdAt: .now),
            Message(id: MessageID("msg_asst_1"), role: .assistant, parts: [.text("first response")], createdAt: .now),
            Message(id: MessageID("msg_asst_2"), role: .assistant, parts: [.text("second response")], createdAt: .now)
        ]
        let session = Session(id: sessionID, createdAt: .now, messages: messages)

        let entry = ContextEntry(
            messageID: toolMsgID,
            role: .tool,
            source: .toolResult,
            part: .toolResult(toolResult)
        )

        // 第一次调用 project
        let projectedEntries = await projector.project(entries: [entry], session: session, ecoreStore: store)
        #expect(projectedEntries.count == 1)

        guard case let .toolResult(res) = projectedEntries[0].part else {
            Issue.record("Expected toolResult part")
            return
        }
        #expect(res.content.contains("[Context Object:"))
        #expect(res.metadata["projected"] == "true")

        var events = try await PortableFixture.eventually(
            { await store.telemetryLogger.readEvents(for: sessionID) },
            enough: { found in found.filter { $0.eventType == .objectProjected }.count >= 1 }
        )
        let projEvents = events.filter { $0.eventType == .objectProjected }
        try #require(projEvents.count == 1)
        #expect(projEvents[0].projectionCount == 1)
        #expect(projEvents[0].originalBytes == largeContent.utf8.count)
        #expect(projEvents[0].objectAge != nil && (projEvents[0].objectAge ?? -1) >= 0)

        // 第二次调用 project（模拟下一轮对话同一对象的再次暴露）
        _ = await projector.project(entries: [entry], session: session, ecoreStore: store)
        events = try await PortableFixture.eventually(
            { await store.telemetryLogger.readEvents(for: sessionID) },
            enough: { found in found.filter { $0.eventType == .objectProjected }.count >= 2 }
        )
        let updatedProjEvents = events.filter { $0.eventType == .objectProjected }
        try #require(updatedProjEvents.count == 2)
        #expect(updatedProjEvents[1].projectionCount == 2)
    }

    // 19. Phase 0.6: objectProjected 事件绝不增加热度权重（Weight 为 0.0）
    @Test func testObjectProjectedEventDoesNotAffectHeatScore() async throws {
        let policy = ECoreHeatWeightPolicy(storedWeight: 1.0, recalledWeight: 2.0, recallMissWeight: 0.0)
        #expect(policy.weight(for: .objectProjected) == 0.0)

        // 模拟事件流：只有 stored，然后多次 projected
        let objID = try ContextObjectID("obj_test_call_zerow_content")
        let sID = SessionID("s-zero-weight")
        let t0 = Date.now.addingTimeInterval(-100)
        let t1 = Date.now.addingTimeInterval(-50)
        let t2 = Date.now

        let events: [ECoreAccessEvent] = [
            ECoreAccessEvent(sessionID: sID, objectID: objID, eventType: .objectStored, timestamp: t0),
            ECoreAccessEvent(sessionID: sID, objectID: objID, eventType: .objectProjected, timestamp: t1, projectionCount: 1),
            ECoreAccessEvent(sessionID: sID, objectID: objID, eventType: .objectProjected, timestamp: t2, projectionCount: 2)
        ]

        let metrics = ECoreObservationAnalyzer.analyze(events: events, metadataList: [], now: t2, halfLifeSeconds: 3600.0, weightPolicy: policy)
        #expect(metrics.totalObjects == 1)
        #expect(metrics.totalStoredEvents == 1)
        #expect(metrics.totalRecalledEvents == 0)
        #expect(metrics.projectedObjectsCount == 1)
        #expect(metrics.totalProjectionExposures == 2)

        // 热度应该只等于 storedWeight (1.0) 经历 100 秒衰减后的分值，projected 事件并未增加任何热度
        let expectedScore = ECoreHeatScorer.decayedScore(currentScore: 1.0, elapsedSeconds: 100.0, halfLifeSeconds: 3600.0)
        #expect(abs(metrics.medianHeat - expectedScore) < 1e-4)
    }

    // 20. Phase 0.6: 区分生命周期三阶段 (Stored -> Projected -> Recalled) 漏斗指标
    @Test func testLifecycleFunnelObservationMetrics() throws {
        let sID = SessionID("s-funnel-test")
        let now = Date.now

        let objA = try ContextObjectID("obj_test_call_a_funnel")
        let objB = try ContextObjectID("obj_test_call_b_funnel")
        let objC = try ContextObjectID("obj_test_call_c_funnel")

        // Obj A: Stored -> Projected -> Recalled
        // Obj B: Stored -> Projected (Never Recalled)
        // Obj C: Stored only (Never Projected)
        let events: [ECoreAccessEvent] = [
            // Obj A
            ECoreAccessEvent(sessionID: sID, objectID: objA, eventType: .objectStored, timestamp: now.addingTimeInterval(-300)),
            ECoreAccessEvent(sessionID: sID, objectID: objA, eventType: .objectProjected, timestamp: now.addingTimeInterval(-200), projectionCount: 1),
            ECoreAccessEvent(sessionID: sID, objectID: objA, eventType: .objectRecalled, timestamp: now.addingTimeInterval(-100)),
            // Obj B
            ECoreAccessEvent(sessionID: sID, objectID: objB, eventType: .objectStored, timestamp: now.addingTimeInterval(-400)),
            ECoreAccessEvent(sessionID: sID, objectID: objB, eventType: .objectProjected, timestamp: now.addingTimeInterval(-250), projectionCount: 1),
            ECoreAccessEvent(sessionID: sID, objectID: objB, eventType: .objectProjected, timestamp: now.addingTimeInterval(-150), projectionCount: 2),
            // Obj C
            ECoreAccessEvent(sessionID: sID, objectID: objC, eventType: .objectStored, timestamp: now.addingTimeInterval(-500))
        ]

        let metrics = ECoreObservationAnalyzer.analyze(events: events, metadataList: [], now: now)

        #expect(metrics.storedObjectsCount == 3)
        #expect(metrics.projectedObjectsCount == 2)
        #expect(metrics.recalledObjectsCount == 1)

        // 转化率
        #expect(abs(metrics.projectionRate - (2.0 / 3.0)) < 1e-4) // 66.7%
        #expect(abs(metrics.recallConversionRate - (1.0 / 2.0)) < 1e-4) // 50.0%

        // 曝光次数与比率
        #expect(metrics.totalProjectionExposures == 3) // Obj A: 1, Obj B: 2
        #expect(metrics.averageProjectionExposuresPerObject == 1.5)
        #expect(abs(metrics.recallPerProjectionExposure - (1.0 / 3.0)) < 1e-4)

        // 未经历投影比例
        #expect(abs(metrics.neverProjectedRatio - (1.0 / 3.0)) < 1e-4) // 33.3%
        #expect(abs(metrics.projectedButNeverRecalledRatio - (1.0 / 2.0)) < 1e-4) // 50.0%

        // 时延验证
        // Obj A: store -300 to proj -200 = 100s; Obj B: store -400 to proj -250 = 150s. Median = (100 + 150)/2 = 125s
        #expect(metrics.timeToFirstProjectionSecondsMedian == 125.0)
        // Obj A: proj -200 to recall -100 = 100s
        #expect(metrics.firstProjectionToFirstRecallSecondsMedian == 100.0)

        // 漏斗描述与结论存在
        #expect(metrics.funnelAnalysis.contains("Stored (3) -> Projected (2"))
        #expect(metrics.opportunityVerdict.contains("已产生召回转化"))
    }
}

