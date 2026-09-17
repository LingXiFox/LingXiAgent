import Foundation
import LingXiProtocol

/// E-Core 观测对象访问事件类型
public enum ECoreAccessEventType: String, Codable, Sendable {
    case objectStored = "object_stored"
    case objectRecalled = "object_recalled"
    case recallMiss = "recall_miss"
    case objectProjected = "object_projected" // Phase 0.6: 纯观测事件，记录转换为 Placeholder 的投影曝光
}

/// E-Core 轻量、Sendable、Codable 的访问遥测事件
public struct ECoreAccessEvent: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let objectID: ContextObjectID
    public let eventType: ECoreAccessEventType
    public let timestamp: Date
    public let offsetBytes: Int?
    public let requestedBytes: Int?
    public let returnedBytes: Int?
    public let toolCallID: ToolCallID?
    public let turnID: String?
    public let revision: Int?
    // Phase 0.6 新增纯观测字段
    public let projectionCount: Int?
    public let objectAge: Double?
    public let originalBytes: Int?

    public init(
        sessionID: SessionID,
        objectID: ContextObjectID,
        eventType: ECoreAccessEventType,
        timestamp: Date = .now,
        offsetBytes: Int? = nil,
        requestedBytes: Int? = nil,
        returnedBytes: Int? = nil,
        toolCallID: ToolCallID? = nil,
        turnID: String? = nil,
        revision: Int? = nil,
        projectionCount: Int? = nil,
        objectAge: Double? = nil,
        originalBytes: Int? = nil
    ) {
        self.sessionID = sessionID
        self.objectID = objectID
        self.eventType = eventType
        self.timestamp = timestamp
        self.offsetBytes = offsetBytes
        self.requestedBytes = requestedBytes
        self.returnedBytes = returnedBytes
        self.toolCallID = toolCallID
        self.turnID = turnID
        self.revision = revision
        self.projectionCount = projectionCount
        self.objectAge = objectAge
        self.originalBytes = originalBytes
    }
}

/// 候选冷热区分类（仅属于 E-Core 内部存储与检索优化，绝对禁止与 P-Core 或 ContextCacheController L1/L2 缓存生命周期联动）
public enum ECoreCandidateZone: String, Codable, Sendable {
    case hot
    case cold
}

/// 扩展 ECoreHeatWeightPolicy 以依据事件类型解析权重
extension ECoreHeatWeightPolicy {
    public func weight(for eventType: ECoreAccessEventType) -> Double {
        switch eventType {
        case .objectStored:
            return storedWeight
        case .objectRecalled:
            return recalledWeight
        case .recallMiss:
            return recallMissWeight
        case .objectProjected:
            // Phase 0.6 红线：纯观测事件，绝对不计入热度权重，零贡献
            return 0.0
        }
    }
}

/// E-Core 对象运行时派生热度状态（Derived State，不属于权威 Source of Truth）
public struct ECoreHeatState: Codable, Sendable, Equatable {
    public let objectID: ContextObjectID
    public var accessCount: Int
    public var recallCount: Int
    public var lastAccessedAt: Date
    public var rawHeatScore: Double
    public var percentile: Double
    public var robustZScore: Double
    public var candidateZone: ECoreCandidateZone

    public init(
        objectID: ContextObjectID,
        accessCount: Int = 1,
        recallCount: Int = 0,
        lastAccessedAt: Date = .now,
        rawHeatScore: Double = 1.0,
        percentile: Double = 0.5,
        robustZScore: Double = 0.0,
        candidateZone: ECoreCandidateZone = .cold
    ) {
        self.objectID = objectID
        self.accessCount = accessCount
        self.recallCount = recallCount
        self.lastAccessedAt = lastAccessedAt
        self.rawHeatScore = (rawHeatScore.isFinite && rawHeatScore >= 0) ? rawHeatScore : 0.0
        self.percentile = percentile
        self.robustZScore = robustZScore
        self.candidateZone = candidateZone
    }
}

/// 确定性热度衰减累加评分器（Decayed Accumulator: H_new = H_old * 0.5^(Δt / T_half) + eventWeight）
/// 彻底解决“历史高频对象在长时间沉寂后，因一次新访问导致全部历史热度被复活”的严重缺陷
public struct ECoreHeatScorer: Sendable {
    /// 计算经历 elapsedSeconds 时间后的衰减热度（纯时间流逝，无新事件）
    public static func decayedScore(
        currentScore: Double,
        elapsedSeconds: Double,
        halfLifeSeconds: Double = 3600.0
    ) -> Double {
        guard currentScore.isFinite && currentScore > 0 else { return 0.0 }
        // 时间倒退或非正流逝安全保护：Δt < 0 时视为 0
        let elapsed = max(0.0, elapsedSeconds)
        guard elapsed > 0 else { return currentScore }
        let halfLife = max(1.0, halfLifeSeconds)
        let decayFactor = pow(0.5, elapsed / halfLife)
        let result = currentScore * decayFactor
        return result.isFinite ? max(0.0, result) : 0.0
    }

    /// 事件驱动热度累加：H_new = H_old * 0.5^(Δt / T_half) + eventWeight
    /// 每次新事件到来时，先根据距离上一次更新的时间衰减旧热度，再叠加本次事件权重
    public static func accumulate(
        currentScore: Double,
        lastUpdatedAt: Date,
        now: Date = .now,
        eventWeight: Double,
        halfLifeSeconds: Double = 3600.0
    ) -> Double {
        let elapsed = max(0.0, now.timeIntervalSince(lastUpdatedAt))
        let decayed = decayedScore(
            currentScore: currentScore,
            elapsedSeconds: elapsed,
            halfLifeSeconds: halfLifeSeconds
        )
        let validWeight = (eventWeight.isFinite && eventWeight > 0) ? eventWeight : 0.0
        let newScore = decayed + validWeight
        return newScore.isFinite ? max(0.0, newScore) : 0.0
    }
}

/// 稳健分布统计计算器（非正态假设：基于中位数与 Median Absolute Deviation）
public struct RobustDistributionCalculator: Sendable {
    /// 计算中位数
    public static func median(_ values: [Double]) -> Double {
        let clean = values.filter(\.isFinite)
        guard !clean.isEmpty else { return 0.0 }
        let sorted = clean.sorted()
        let count = sorted.count
        if count % 2 == 1 {
            return sorted[count / 2]
        } else {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
        }
    }

    /// 计算绝对中位差 (MAD = Median(|x_i - Median(X)|))
    public static func mad(_ values: [Double], median: Double) -> Double {
        let clean = values.filter(\.isFinite)
        guard clean.count > 1 else { return 0.0 }
        let deviations = clean.map { abs($0 - median) }
        return Self.median(deviations)
    }

    /// 计算稳健 Z-score（处理 MAD == 0 与极值边界）
    public static func robustZScore(value: Double, median: Double, mad: Double) -> Double {
        guard value.isFinite, median.isFinite, mad.isFinite else { return 0.0 }
        if mad > 1e-9 {
            // 1.4826 为标准正态分布一致性乘数
            let z = (value - median) / (1.4826 * mad)
            return z.isFinite ? z : 0.0
        }
        // 当所有或大多数数据相同时，MAD == 0
        if abs(value - median) < 1e-9 {
            return 0.0
        }
        // MAD == 0 且存在离群差异时，平滑赋有界符号差，杜绝除零崩溃
        let diff = value - median
        return diff > 0 ? min(10.0, 1.0 + diff) : max(-10.0, -1.0 + diff)
    }

    /// 计算分位数 (Percentile Rank 0.0 ~ 1.0)
    /// 采用统计学稳健的中点百分位等级公式：(count(x < v) + 0.5 * count(x == v)) / N
    /// 避免在重复值多或极端偏态分布下由于全部 <= 导致分位数虚高
    public static func percentileRank(value: Double, sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty, value.isFinite else { return 0.0 }
        var strictlyLess = 0
        var equal = 0
        for v in sortedValues {
            if v < value - 1e-9 {
                strictlyLess += 1
            } else if abs(v - value) <= 1e-9 {
                equal += 1
            }
        }
        let rank = (Double(strictlyLess) + 0.5 * Double(max(1, equal))) / Double(sortedValues.count)
        return min(1.0, max(0.0, rank))
    }

    /// 提取特定分位数值 (0.0 ~ 1.0)
    public static func quantile(_ p: Double, sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0.0 }
        let clampedP = min(1.0, max(0.0, p))
        let index = Double(sortedValues.count - 1) * clampedP
        let lower = Int(floor(index))
        let upper = Int(ceil(index))
        if lower == upper {
            return sortedValues[lower]
        }
        let weight = index - Double(lower)
        return sortedValues[lower] * (1.0 - weight) + sortedValues[upper] * weight
    }
}

/// E-Core 热度调试与可观测性快照
public struct ECoreHeatSnapshot: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let objectCount: Int
    public let hotCount: Int
    public let coldCount: Int
    public let medianHeat: Double
    public let madHeat: Double
    public let p50: Double
    public let p70: Double
    public let p80: Double
    public let p90: Double
    public let p95: Double
    public let topHottestObjects: [ECoreHeatState]

    public init(
        sessionID: SessionID,
        objectCount: Int,
        hotCount: Int,
        coldCount: Int,
        medianHeat: Double,
        madHeat: Double,
        p50: Double,
        p70: Double,
        p80: Double,
        p90: Double,
        p95: Double,
        topHottestObjects: [ECoreHeatState]
    ) {
        self.sessionID = sessionID
        self.objectCount = objectCount
        self.hotCount = hotCount
        self.coldCount = coldCount
        self.medianHeat = medianHeat
        self.madHeat = madHeat
        self.p50 = p50
        self.p70 = p70
        self.p80 = p80
        self.p90 = p90
        self.p95 = p95
        self.topHottestObjects = topHottestObjects
    }
}

/// 独立后台 Actor：以 append-only 格式异步持久化 E-Core 遥测事件日志
/// 绝不阻塞主 Agent Loop，Fail-Open 安全兜底
public actor ECoreTelemetryLogger {
    private let baseDirectory: URL
    private let encoder: JSONEncoder

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.baseDirectory = home.appendingPathComponent(".lingxiagent", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    /// 获取特定 Session 的 telemetry 日志路径
    public func eventLogURL(for sessionID: SessionID) -> URL {
        let safeSessionID = sessionID.rawValue.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return baseDirectory
            .appendingPathComponent(safeSessionID, isDirectory: true)
            .appendingPathComponent("telemetry", isDirectory: true)
            .appendingPathComponent("ecore-events.jsonl", isDirectory: false)
    }

    /// 异步追加事件（Fail-Open，任何 IO 异常均静默捕获，绝不抛出打断主流程）
    public func appendEvent(_ event: ECoreAccessEvent) {
        do {
            let logURL = eventLogURL(for: event.sessionID)
            let dir = logURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            var data = try encoder.encode(event)
            data.append(contentsOf: [10]) // '\n'

            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logURL)
            }
        } catch {
            // Fail-open: 遥测失败静默吞并，绝不破坏业务流或污染控制台
        }
    }

    /// 读取指定 Session 的历史遥测事件（供测试与分析）
    public func readEvents(for sessionID: SessionID) -> [ECoreAccessEvent] {
        let logURL = eventLogURL(for: sessionID)
        guard let data = try? Data(contentsOf: logURL),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [ECoreAccessEvent] = []
        let lines = content.components(separatedBy: "\n")
        for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let lineData = line.data(using: .utf8),
               let ev = try? decoder.decode(ECoreAccessEvent.self, from: lineData) {
                events.append(ev)
            }
        }
        return events
    }
}

/// Pareto 分布分桶
public struct ECoreParetoBucket: Codable, Sendable, Equatable {
    public let topPercentileLabel: String
    public let objectCount: Int
    public let recallCount: Int
    public let recallContributionRatio: Double

    public init(topPercentileLabel: String, objectCount: Int, recallCount: Int, recallContributionRatio: Double) {
        self.topPercentileLabel = topPercentileLabel
        self.objectCount = objectCount
        self.recallCount = recallCount
        self.recallContributionRatio = recallContributionRatio
    }
}

/// 观测期统计指标聚合结构（只读，完全旁路）
public struct ECoreObservationMetrics: Codable, Sendable, Equatable {
    public let totalObjects: Int
    public let totalStoredEvents: Int
    public let totalRecalledEvents: Int
    public let totalRecallMissEvents: Int
    public let neverRecalledObjectsCount: Int
    public let neverRecalledRatio: Double

    public let recallCountDistribution: [String: Int]

    public let medianHeat: Double
    public let madHeat: Double
    public let p50: Double
    public let p70: Double
    public let p80: Double
    public let p90: Double
    public let p95: Double

    public let paretoDistribution: [ECoreParetoBucket]

    public let timeToFirstRecallSecondsMedian: Double?
    public let timeToFirstRecallSecondsMin: Double?
    public let timeToFirstRecallSecondsMax: Double?
    public let timeToFirstRecallSecondsP90: Double?

    public let recencySinceLastRecallSecondsMedian: Double?
    public let recencySinceLastRecallSecondsMin: Double?
    public let recencySinceLastRecallSecondsMax: Double?

    public let heatRecallCorrelation: Double

    public let storedWeightAnalysis: String
    public let halfLifeAnalysis: String
    public let sampleSufficiencyVerdict: String

    // === Phase 0.6: Recall Opportunity & Lifecycle Funnel ===
    public let storedObjectsCount: Int
    public let projectedObjectsCount: Int
    public let recalledObjectsCount: Int
    public let projectionRate: Double
    public let recallConversionRate: Double

    public let totalProjectionExposures: Int
    public let averageProjectionExposuresPerObject: Double
    public let recallPerProjectionExposure: Double

    public let timeToFirstProjectionSecondsMedian: Double?
    public let timeToFirstProjectionSecondsMin: Double?
    public let timeToFirstProjectionSecondsMax: Double?
    public let timeToFirstProjectionSecondsP90: Double?

    public let firstProjectionToFirstRecallSecondsMedian: Double?
    public let firstProjectionToFirstRecallSecondsMin: Double?
    public let firstProjectionToFirstRecallSecondsMax: Double?
    public let firstProjectionToFirstRecallSecondsP90: Double?

    public let neverProjectedRatio: Double
    public let projectedButNeverRecalledRatio: Double
    public let sessionEndedBeforeFirstProjectionRatio: Double

    public let funnelAnalysis: String
    public let opportunityVerdict: String

    public init(
        totalObjects: Int,
        totalStoredEvents: Int,
        totalRecalledEvents: Int,
        totalRecallMissEvents: Int,
        neverRecalledObjectsCount: Int,
        neverRecalledRatio: Double,
        recallCountDistribution: [String: Int],
        medianHeat: Double,
        madHeat: Double,
        p50: Double,
        p70: Double,
        p80: Double,
        p90: Double,
        p95: Double,
        paretoDistribution: [ECoreParetoBucket],
        timeToFirstRecallSecondsMedian: Double?,
        timeToFirstRecallSecondsMin: Double?,
        timeToFirstRecallSecondsMax: Double?,
        timeToFirstRecallSecondsP90: Double?,
        recencySinceLastRecallSecondsMedian: Double?,
        recencySinceLastRecallSecondsMin: Double?,
        recencySinceLastRecallSecondsMax: Double?,
        heatRecallCorrelation: Double,
        storedWeightAnalysis: String,
        halfLifeAnalysis: String,
        sampleSufficiencyVerdict: String,
        storedObjectsCount: Int = 0,
        projectedObjectsCount: Int = 0,
        recalledObjectsCount: Int = 0,
        projectionRate: Double = 0.0,
        recallConversionRate: Double = 0.0,
        totalProjectionExposures: Int = 0,
        averageProjectionExposuresPerObject: Double = 0.0,
        recallPerProjectionExposure: Double = 0.0,
        timeToFirstProjectionSecondsMedian: Double? = nil,
        timeToFirstProjectionSecondsMin: Double? = nil,
        timeToFirstProjectionSecondsMax: Double? = nil,
        timeToFirstProjectionSecondsP90: Double? = nil,
        firstProjectionToFirstRecallSecondsMedian: Double? = nil,
        firstProjectionToFirstRecallSecondsMin: Double? = nil,
        firstProjectionToFirstRecallSecondsMax: Double? = nil,
        firstProjectionToFirstRecallSecondsP90: Double? = nil,
        neverProjectedRatio: Double = 0.0,
        projectedButNeverRecalledRatio: Double = 0.0,
        sessionEndedBeforeFirstProjectionRatio: Double = 0.0,
        funnelAnalysis: String = "",
        opportunityVerdict: String = ""
    ) {
        self.totalObjects = totalObjects
        self.totalStoredEvents = totalStoredEvents
        self.totalRecalledEvents = totalRecalledEvents
        self.totalRecallMissEvents = totalRecallMissEvents
        self.neverRecalledObjectsCount = neverRecalledObjectsCount
        self.neverRecalledRatio = neverRecalledRatio
        self.recallCountDistribution = recallCountDistribution
        self.medianHeat = medianHeat
        self.madHeat = madHeat
        self.p50 = p50
        self.p70 = p70
        self.p80 = p80
        self.p90 = p90
        self.p95 = p95
        self.paretoDistribution = paretoDistribution
        self.timeToFirstRecallSecondsMedian = timeToFirstRecallSecondsMedian
        self.timeToFirstRecallSecondsMin = timeToFirstRecallSecondsMin
        self.timeToFirstRecallSecondsMax = timeToFirstRecallSecondsMax
        self.timeToFirstRecallSecondsP90 = timeToFirstRecallSecondsP90
        self.recencySinceLastRecallSecondsMedian = recencySinceLastRecallSecondsMedian
        self.recencySinceLastRecallSecondsMin = recencySinceLastRecallSecondsMin
        self.recencySinceLastRecallSecondsMax = recencySinceLastRecallSecondsMax
        self.heatRecallCorrelation = heatRecallCorrelation
        self.storedWeightAnalysis = storedWeightAnalysis
        self.halfLifeAnalysis = halfLifeAnalysis
        self.sampleSufficiencyVerdict = sampleSufficiencyVerdict
        self.storedObjectsCount = storedObjectsCount
        self.projectedObjectsCount = projectedObjectsCount
        self.recalledObjectsCount = recalledObjectsCount
        self.projectionRate = projectionRate
        self.recallConversionRate = recallConversionRate
        self.totalProjectionExposures = totalProjectionExposures
        self.averageProjectionExposuresPerObject = averageProjectionExposuresPerObject
        self.recallPerProjectionExposure = recallPerProjectionExposure
        self.timeToFirstProjectionSecondsMedian = timeToFirstProjectionSecondsMedian
        self.timeToFirstProjectionSecondsMin = timeToFirstProjectionSecondsMin
        self.timeToFirstProjectionSecondsMax = timeToFirstProjectionSecondsMax
        self.timeToFirstProjectionSecondsP90 = timeToFirstProjectionSecondsP90
        self.firstProjectionToFirstRecallSecondsMedian = firstProjectionToFirstRecallSecondsMedian
        self.firstProjectionToFirstRecallSecondsMin = firstProjectionToFirstRecallSecondsMin
        self.firstProjectionToFirstRecallSecondsMax = firstProjectionToFirstRecallSecondsMax
        self.firstProjectionToFirstRecallSecondsP90 = firstProjectionToFirstRecallSecondsP90
        self.neverProjectedRatio = neverProjectedRatio
        self.projectedButNeverRecalledRatio = projectedButNeverRecalledRatio
        self.sessionEndedBeforeFirstProjectionRatio = sessionEndedBeforeFirstProjectionRatio
        self.funnelAnalysis = funnelAnalysis
        self.opportunityVerdict = opportunityVerdict
    }
}

/// 旁路只读观测期数据分析器（Fail-Open，零前台阻塞）
public struct ECoreObservationAnalyzer: Sendable {
    public static func analyze(
        events: [ECoreAccessEvent],
        metadataList: [ObservationMetadata],
        now: Date = .now,
        halfLifeSeconds: Double = 3600.0,
        weightPolicy: ECoreHeatWeightPolicy = ECoreHeatWeightPolicy()
    ) -> ECoreObservationMetrics {
        var storedCount = 0
        var recalledCount = 0
        var missCount = 0
        var projectedEventsCount = 0

        var objectIDs = Set<ContextObjectID>()
        for m in metadataList {
            objectIDs.insert(m.objectID)
        }
        for e in events {
            objectIDs.insert(e.objectID)
            switch e.eventType {
            case .objectStored: storedCount += 1
            case .objectRecalled: recalledCount += 1
            case .recallMiss: missCount += 1
            case .objectProjected: projectedEventsCount += 1
            }
        }

        let totalObjs = objectIDs.count

        // 按 objectID 分组事件
        var eventsByObj: [ContextObjectID: [ECoreAccessEvent]] = [:]
        for e in events {
            eventsByObj[e.objectID, default: []].append(e)
        }

        var metadataByObj: [ContextObjectID: ObservationMetadata] = [:]
        for m in metadataList {
            metadataByObj[m.objectID] = m
        }

        var objectRecalls: [ContextObjectID: Int] = [:]
        var objectProjections: [ContextObjectID: Int] = [:]
        var objectHeatScores: [ContextObjectID: Double] = [:]
        var timeToFirstRecallList: [Double] = []
        var timeToFirstProjectionList: [Double] = []
        var firstProjectionToFirstRecallList: [Double] = []
        var recencyList: [Double] = []

        var neverRecalledCount = 0
        var neverProjectedCount = 0
        var projectedObjectIDs = Set<ContextObjectID>()
        var recalledObjectIDs = Set<ContextObjectID>()

        for objID in objectIDs {
            let objEvents = (eventsByObj[objID] ?? []).sorted(by: { $0.timestamp < $1.timestamp })
            let recalls = objEvents.filter { $0.eventType == .objectRecalled }
            let projections = objEvents.filter { $0.eventType == .objectProjected }
            let recallNum = recalls.count
            let projectionNum = projections.count
            objectRecalls[objID] = recallNum
            objectProjections[objID] = projectionNum

            if recallNum == 0 {
                neverRecalledCount += 1
            } else {
                recalledObjectIDs.insert(objID)
            }

            if projectionNum == 0 {
                neverProjectedCount += 1
            } else {
                projectedObjectIDs.insert(objID)
            }

            let createdAt = metadataByObj[objID]?.createdAt ?? objEvents.first?.timestamp

            // 计算时间到第一次 projection
            if let createdAt, let firstProj = projections.first {
                let diff = max(0.0, firstProj.timestamp.timeIntervalSince(createdAt))
                timeToFirstProjectionList.append(diff)
            }

            // 计算时间到第一次 recall
            if let createdAt, let firstRecall = recalls.first {
                let diff = max(0.0, firstRecall.timestamp.timeIntervalSince(createdAt))
                timeToFirstRecallList.append(diff)
            }

            // 计算第一次 projection 到第一次 recall 的延迟
            if let firstProj = projections.first, let firstRecall = recalls.first {
                let diff = max(0.0, firstRecall.timestamp.timeIntervalSince(firstProj.timestamp))
                firstProjectionToFirstRecallList.append(diff)
            }

            // 计算最后一次 recall 距今时间
            if let lastRecall = recalls.last {
                let recency = max(0.0, now.timeIntervalSince(lastRecall.timestamp))
                recencyList.append(recency)
            }

            // 回放累加器计算当前热度
            var score = 0.0
            var lastTime: Date? = nil

            if objEvents.isEmpty {
                // 若只有 metadata 而没有显式 eventLog（历史遗留对象），给予默认 storedWeight
                let weight = weightPolicy.weight(for: .objectStored)
                let cTime = metadataByObj[objID]?.createdAt ?? now
                score = ECoreHeatScorer.decayedScore(
                    currentScore: weight,
                    elapsedSeconds: max(0.0, now.timeIntervalSince(cTime)),
                    halfLifeSeconds: halfLifeSeconds
                )
            } else {
                for ev in objEvents {
                    let w = weightPolicy.weight(for: ev.eventType)
                    if let lt = lastTime {
                        score = ECoreHeatScorer.accumulate(
                            currentScore: score,
                            lastUpdatedAt: lt,
                            now: ev.timestamp,
                            eventWeight: w,
                            halfLifeSeconds: halfLifeSeconds
                        )
                    } else {
                        score = (w.isFinite && w >= 0) ? w : 0.0
                    }
                    lastTime = ev.timestamp
                }
                if let lt = lastTime {
                    score = ECoreHeatScorer.decayedScore(
                        currentScore: score,
                        elapsedSeconds: max(0.0, now.timeIntervalSince(lt)),
                        halfLifeSeconds: halfLifeSeconds
                    )
                }
            }
            objectHeatScores[objID] = score
        }

        let neverRatio = totalObjs > 0 ? Double(neverRecalledCount) / Double(totalObjs) : 0.0

        // recall 频次分布桶
        var dist: [String: Int] = [
            "0": 0,
            "1": 0,
            "2-5": 0,
            "6-10": 0,
            "11+": 0
        ]
        for (_, c) in objectRecalls {
            if c == 0 { dist["0"] = (dist["0"] ?? 0) + 1 }
            else if c == 1 { dist["1"] = (dist["1"] ?? 0) + 1 }
            else if c <= 5 { dist["2-5"] = (dist["2-5"] ?? 0) + 1 }
            else if c <= 10 { dist["6-10"] = (dist["6-10"] ?? 0) + 1 }
            else { dist["11+"] = (dist["11+"] ?? 0) + 1 }
        }

        // 当前 Heat 稳健分布
        let allScores = Array(objectHeatScores.values).sorted()
        let median = RobustDistributionCalculator.median(allScores)
        let mad = RobustDistributionCalculator.mad(allScores, median: median)
        let p50 = RobustDistributionCalculator.quantile(0.50, sortedValues: allScores)
        let p70 = RobustDistributionCalculator.quantile(0.70, sortedValues: allScores)
        let p80 = RobustDistributionCalculator.quantile(0.80, sortedValues: allScores)
        let p90 = RobustDistributionCalculator.quantile(0.90, sortedValues: allScores)
        let p95 = RobustDistributionCalculator.quantile(0.95, sortedValues: allScores)

        // Pareto 分析表
        let totalRecallSum = objectRecalls.values.reduce(0, +)
        let sortedByRecall = objectRecalls.sorted(by: { $0.value > $1.value })
        let topFractions: [(String, Double)] = [
            ("Top 1%", 0.01),
            ("Top 5%", 0.05),
            ("Top 10%", 0.10),
            ("Top 20%", 0.20),
            ("Top 30%", 0.30),
            ("Top 50%", 0.50)
        ]

        var paretoBuckets: [ECoreParetoBucket] = []
        for (label, frac) in topFractions {
            let count = max(1, Int(ceil(Double(totalObjs) * frac)))
            let slice = sortedByRecall.prefix(min(totalObjs, count))
            let sumRecall = slice.reduce(0) { $0 + $1.value }
            let ratio = totalRecallSum > 0 ? Double(sumRecall) / Double(totalRecallSum) : 0.0
            paretoBuckets.append(ECoreParetoBucket(
                topPercentileLabel: label,
                objectCount: min(totalObjs, count),
                recallCount: sumRecall,
                recallContributionRatio: min(1.0, max(0.0, ratio))
            ))
        }

        // 时延统计
        let tSorted = timeToFirstRecallList.sorted()
        let tMedian = tSorted.isEmpty ? nil : RobustDistributionCalculator.median(tSorted)
        let tMin = tSorted.first
        let tMax = tSorted.last
        let tP90 = tSorted.isEmpty ? nil : RobustDistributionCalculator.quantile(0.90, sortedValues: tSorted)

        let rSorted = recencyList.sorted()
        let rMedian = rSorted.isEmpty ? nil : RobustDistributionCalculator.median(rSorted)
        let rMin = rSorted.first
        let rMax = rSorted.last

        // Pearson 相关系数
        var corr = 0.0
        if totalObjs > 1 {
            let pairs: [(Double, Double)] = objectIDs.map { id in
                (objectHeatScores[id] ?? 0.0, Double(objectRecalls[id] ?? 0))
            }
            let meanX = pairs.map(\.0).reduce(0, +) / Double(pairs.count)
            let meanY = pairs.map(\.1).reduce(0, +) / Double(pairs.count)
            var num = 0.0
            var denX = 0.0
            var denY = 0.0
            for (x, y) in pairs {
                let dx = x - meanX
                let dy = y - meanY
                num += dx * dy
                denX += dx * dx
                denY += dy * dy
            }
            let denom = sqrt(denX * denY)
            if denom > 1e-9 {
                corr = num / denom
            }
        }

        // Phase 0.6: 漏斗指标与时间跨度计算
        let storedObjsCount = totalObjs
        let projectedObjsCount = projectedObjectIDs.count
        let recalledObjsCount = recalledObjectIDs.count

        let projectionRate = storedObjsCount > 0 ? Double(projectedObjsCount) / Double(storedObjsCount) : 0.0
        let recallConversionRate = projectedObjsCount > 0 ? Double(recalledObjsCount) / Double(projectedObjsCount) : 0.0

        let totalProjectionExposures = projectedEventsCount
        let avgExposures = projectedObjsCount > 0 ? Double(totalProjectionExposures) / Double(projectedObjsCount) : 0.0
        let recallPerExposure = totalProjectionExposures > 0 ? Double(recalledCount) / Double(totalProjectionExposures) : 0.0

        let neverProjectedRatio = storedObjsCount > 0 ? Double(neverProjectedCount) / Double(storedObjsCount) : 0.0
        let projectedButNeverRecalledRatio = projectedObjsCount > 0 ? Double(projectedObjsCount - recalledObjsCount) / Double(projectedObjsCount) : 0.0
        let sessionEndedBeforeFirstProjectionRatio = neverProjectedRatio

        let tpSorted = timeToFirstProjectionList.sorted()
        let tpMedian = tpSorted.isEmpty ? nil : RobustDistributionCalculator.median(tpSorted)
        let tpMin = tpSorted.first
        let tpMax = tpSorted.last
        let tpP90 = tpSorted.isEmpty ? nil : RobustDistributionCalculator.quantile(0.90, sortedValues: tpSorted)

        let prSorted = firstProjectionToFirstRecallList.sorted()
        let prMedian = prSorted.isEmpty ? nil : RobustDistributionCalculator.median(prSorted)
        let prMin = prSorted.first
        let prMax = prSorted.last
        let prP90 = prSorted.isEmpty ? nil : RobustDistributionCalculator.quantile(0.90, sortedValues: prSorted)

        let funnelAnalysis = "三阶段漏斗: Stored (\(storedObjsCount)) -> Projected (\(projectedObjsCount), \(String(format: "%.1f", projectionRate * 100))%) -> Recalled (\(recalledObjsCount), \(String(format: "%.1f", recallConversionRate * 100))%)"

        let opportunityVerdict: String
        if storedObjsCount == 0 {
            opportunityVerdict = "暂无 E-Core 对象。"
        } else if projectedObjsCount == 0 {
            opportunityVerdict = "【无召回机会】所有 \(storedObjsCount) 个对象在生命周期内均未经历过 ContextProjection 转换（Never Projected = 100%）。会话在 FULL_SENDS 阈值内结束，模型前台始终接收全文内联，从未见过 Placeholder 与 context_recall 提示。历史零召回的根因是'模型完全缺乏召回机会'，而非'有机会但不召回'。"
        } else if recalledObjsCount == 0 {
            opportunityVerdict = "【有暴露未转化】共有 \(projectedObjsCount) 个对象被投影为 Placeholder（总暴露 \(totalProjectionExposures) 次），但模型在后续轮次中均未触发 context_recall（转化率 0%）。模型已获知召回句柄，但决策无需深入召回。"
        } else {
            opportunityVerdict = "【已产生召回转化】在 \(projectedObjsCount) 个投影对象中，有 \(recalledObjsCount) 个被成功召回，转化率为 \(String(format: "%.1f", recallConversionRate * 100))%，每次投影暴露产生召回的概率为 \(String(format: "%.2f", recallPerExposure))。"
        }

        // 分析与诊断结论（统一标注 [Unvalidated Production Parameter]）
        let storedAnalysis: String
        if neverRatio > 0.6 {
            storedAnalysis = "[Unvalidated Production Parameter] 大量对象 (约 \(Int(neverRatio * 100))%) 存储后从未被 recall。当前 storedWeight=1.0 仅为初始化先验，尚未经真实生产环境召回回流校准。中点百分位等级公式有效避免了高分位虚高挤压。"
        } else {
            storedAnalysis = "[Unvalidated Production Parameter] 对象召回较为均匀，存储后未召回比例为 \(Int(neverRatio * 100))%，storedWeight=1.0 尚待进一步真实数据校准。"
        }

        let halfLifeDiag: String
        if recencyList.isEmpty {
            halfLifeDiag = "[Unvalidated Production Parameter] 当前会话内暂无充足重访事件，1小时半衰期（3600s）仅作为工程默认先验，尚未经多轮跨 Session 访问真实检验。"
        } else if let rMed = rMedian, rMed < 1800 {
            halfLifeDiag = "[Unvalidated Production Parameter] 召回重访集中在 30 分钟内 (中位数 \(Int(rMed))s)，1小时半衰期保留了适度余热，但仍属未经验证参数。"
        } else {
            halfLifeDiag = "[Unvalidated Production Parameter] 召回间隔分布广泛 (中位数 \(Int(rMedian ?? 0))s)，1小时半衰期仍需更多样本校准。"
        }

        let actualRecalls = totalRecallSum > 0 ? totalRecallSum : recalledCount
        let sufficiency: String
        if totalObjs < 30 || actualRecalls < 10 {
            sufficiency = "当前真实样本量偏少 (Objects: \(totalObjs), Recalls: \(actualRecalls))，统计置信度有限，禁止盲目固化 Hot Zone 参数，建议保持 Phase 0.5/0.6 继续长期观测。"
        } else {
            sufficiency = "样本量初具规模 (Objects: \(totalObjs), Recalls: \(actualRecalls))，展现出典型重尾分布趋势，可作为后续决策参考。"
        }

        return ECoreObservationMetrics(
            totalObjects: totalObjs,
            totalStoredEvents: storedCount,
            totalRecalledEvents: recalledCount,
            totalRecallMissEvents: missCount,
            neverRecalledObjectsCount: neverRecalledCount,
            neverRecalledRatio: neverRatio,
            recallCountDistribution: dist,
            medianHeat: median,
            madHeat: mad,
            p50: p50,
            p70: p70,
            p80: p80,
            p90: p90,
            p95: p95,
            paretoDistribution: paretoBuckets,
            timeToFirstRecallSecondsMedian: tMedian,
            timeToFirstRecallSecondsMin: tMin,
            timeToFirstRecallSecondsMax: tMax,
            timeToFirstRecallSecondsP90: tP90,
            recencySinceLastRecallSecondsMedian: rMedian,
            recencySinceLastRecallSecondsMin: rMin,
            recencySinceLastRecallSecondsMax: rMax,
            heatRecallCorrelation: corr,
            storedWeightAnalysis: storedAnalysis,
            halfLifeAnalysis: halfLifeDiag,
            sampleSufficiencyVerdict: sufficiency,
            storedObjectsCount: storedObjsCount,
            projectedObjectsCount: projectedObjsCount,
            recalledObjectsCount: recalledObjsCount,
            projectionRate: projectionRate,
            recallConversionRate: recallConversionRate,
            totalProjectionExposures: totalProjectionExposures,
            averageProjectionExposuresPerObject: avgExposures,
            recallPerProjectionExposure: recallPerExposure,
            timeToFirstProjectionSecondsMedian: tpMedian,
            timeToFirstProjectionSecondsMin: tpMin,
            timeToFirstProjectionSecondsMax: tpMax,
            timeToFirstProjectionSecondsP90: tpP90,
            firstProjectionToFirstRecallSecondsMedian: prMedian,
            firstProjectionToFirstRecallSecondsMin: prMin,
            firstProjectionToFirstRecallSecondsMax: prMax,
            firstProjectionToFirstRecallSecondsP90: prP90,
            neverProjectedRatio: neverProjectedRatio,
            projectedButNeverRecalledRatio: projectedButNeverRecalledRatio,
            sessionEndedBeforeFirstProjectionRatio: sessionEndedBeforeFirstProjectionRatio,
            funnelAnalysis: funnelAnalysis,
            opportunityVerdict: opportunityVerdict
        )
    }

    /// 扫描会话根目录读取全部历史与实时数据（完全旁路、Fail-Open）
    public static func analyzeDirectory(
        baseDirectory: URL,
        now: Date = .now,
        halfLifeSeconds: Double = 3600.0,
        weightPolicy: ECoreHeatWeightPolicy = ECoreHeatWeightPolicy()
    ) -> ECoreObservationMetrics {
        var allEvents: [ECoreAccessEvent] = []
        var allMetadata: [ObservationMetadata] = []

        guard let sessionDirs = try? FileManager.default.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return analyze(events: [], metadataList: [], now: now, halfLifeSeconds: halfLifeSeconds, weightPolicy: weightPolicy)
        }

        let eventDecoder = JSONDecoder()
        eventDecoder.dateDecodingStrategy = .iso8601
        let metaDecoder = JSONDecoder()

        for sDir in sessionDirs {
            // 1. 读取 telemetry/ecore-events.jsonl
            let eventLogURL = sDir.appendingPathComponent("telemetry", isDirectory: true).appendingPathComponent("ecore-events.jsonl", isDirectory: false)
            if let data = try? Data(contentsOf: eventLogURL),
               let content = String(data: data, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n")
                for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let lineData = line.data(using: .utf8),
                       let ev = try? eventDecoder.decode(ECoreAccessEvent.self, from: lineData) {
                        allEvents.append(ev)
                    }
                }
            }

            // 2. 读取 objects/*.meta.json
            let objectsDir = sDir.appendingPathComponent("objects", isDirectory: true)
            if let objFiles = try? FileManager.default.contentsOfDirectory(at: objectsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for file in objFiles where file.lastPathComponent.hasSuffix(".meta.json") {
                    if let data = try? Data(contentsOf: file),
                       let meta = try? metaDecoder.decode(ObservationMetadata.self, from: data) {
                        allMetadata.append(meta)
                    }
                }
            }
        }

        return analyze(
            events: allEvents,
            metadataList: allMetadata,
            now: now,
            halfLifeSeconds: halfLifeSeconds,
            weightPolicy: weightPolicy
        )
    }
}
