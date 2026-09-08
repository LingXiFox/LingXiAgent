import Foundation

/// 8 阶段端到端流式延迟追踪阶段
public enum StreamingLatencyStage: String, Sendable, CaseIterable {
    case providerFrameReceived
    case adapterDecoded
    case canonicalDeltaEmitted
    case coreCommitted
    case applicationProjected
    case tuiUpdateReceived
    case frameScheduled
    case openTUIPresented
}

/// 单个流式 Delta 的时间戳记录
public struct StreamingDeltaRecord: Sendable {
    public let id: String
    public var timestamps: [StreamingLatencyStage: ContinuousClock.Instant] = [:]

    public init(id: String) {
        self.id = id
    }

    public mutating func record(_ stage: StreamingLatencyStage, at instant: ContinuousClock.Instant) {
        timestamps[stage] = instant
    }

    public func duration(from: StreamingLatencyStage, to: StreamingLatencyStage) -> Duration? {
        guard let t0 = timestamps[from], let t1 = timestamps[to] else { return nil }
        return t0.duration(to: t1)
    }

    public func milliseconds(from: StreamingLatencyStage, to: StreamingLatencyStage) -> Double? {
        guard let dur = duration(from: from, to: to) else { return nil }
        let c = dur.components
        return Double(c.seconds) * 1000.0 + Double(c.attoseconds) / 1_000_000_000_000_000.0
    }
}

/// 延迟统计数据模型
public struct StreamingLatencyStats: Sendable {
    public let sampleCount: Int
    public let p50Ms: Double
    public let p95Ms: Double
    public let p99Ms: Double
    public let maxMs: Double
    public let maxStallMs: Double
    public let stageBreakdown: [String: (p50: Double, p95: Double, max: Double)]
    public let slowestStage: String

    public init(
        sampleCount: Int,
        p50Ms: Double,
        p95Ms: Double,
        p99Ms: Double,
        maxMs: Double,
        maxStallMs: Double,
        stageBreakdown: [String: (p50: Double, p95: Double, max: Double)],
        slowestStage: String
    ) {
        self.sampleCount = sampleCount
        self.p50Ms = p50Ms
        self.p95Ms = p95Ms
        self.p99Ms = p99Ms
        self.maxMs = maxMs
        self.maxStallMs = maxStallMs
        self.stageBreakdown = stageBreakdown
        self.slowestStage = slowestStage
    }
}

/// 全链路 Monotonic Streaming Latency Tracker
public final class StreamingLatencyTracker: @unchecked Sendable {
    public static let shared = StreamingLatencyTracker()

    private let lock = NSLock()
    private let clock = ContinuousClock()
    private var records: [String: StreamingDeltaRecord] = [:]
    private var presentationTimestamps: [ContinuousClock.Instant] = []
    public var isEnabled: Bool = true

    public init() {}

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll(keepingCapacity: true)
        presentationTimestamps.removeAll(keepingCapacity: true)
    }

    public func record(_ id: String, stage: StreamingLatencyStage, at instant: ContinuousClock.Instant? = nil) {
        guard isEnabled else { return }
        let t = instant ?? clock.now
        lock.lock()
        defer { lock.unlock() }
        if records[id] == nil {
            records[id] = StreamingDeltaRecord(id: id)
        }
        records[id]?.record(stage, at: t)
        if stage == .openTUIPresented {
            presentationTimestamps.append(t)
        }
    }

    public func calculateStats() -> StreamingLatencyStats {
        lock.lock()
        let currentRecords = Array(records.values)
        let presentationTimes = presentationTimestamps
        lock.unlock()

        var endToEndLatencies: [Double] = []
        let stages = StreamingLatencyStage.allCases
        var stageIntervals: [String: [Double]] = [:]

        for i in 0..<(stages.count - 1) {
            let key = "\(stages[i].rawValue) -> \(stages[i + 1].rawValue)"
            stageIntervals[key] = []
        }

        for r in currentRecords {
            if let e2e = r.milliseconds(from: .providerFrameReceived, to: .openTUIPresented) {
                endToEndLatencies.append(e2e)
            }
            for i in 0..<(stages.count - 1) {
                let from = stages[i]
                let to = stages[i + 1]
                let key = "\(from.rawValue) -> \(to.rawValue)"
                if let diff = r.milliseconds(from: from, to: to) {
                    stageIntervals[key]?.append(diff)
                }
            }
        }

        endToEndLatencies.sort()

        func percentile(_ values: [Double], p: Double) -> Double {
            guard !values.isEmpty else { return 0.0 }
            let idx = min(values.count - 1, max(0, Int(Double(values.count) * p)))
            return values[idx]
        }

        var breakdown: [String: (p50: Double, p95: Double, max: Double)] = [:]
        var slowestStageName = "none"
        var maxStageP95 = -1.0

        for (stageKey, vals) in stageIntervals {
            let sortedVals = vals.sorted()
            let p50 = percentile(sortedVals, p: 0.50)
            let p95 = percentile(sortedVals, p: 0.95)
            let mx = sortedVals.last ?? 0.0
            breakdown[stageKey] = (p50, p95, mx)
            if p95 > maxStageP95 {
                maxStageP95 = p95
                slowestStageName = stageKey
            }
        }

        // 计算最大 stall (两次呈现之间的最大时间差)
        var maxStall: Double = 0.0
        if presentationTimes.count >= 2 {
            for i in 1..<presentationTimes.count {
                let d = presentationTimes[i - 1].duration(to: presentationTimes[i])
                let c = d.components
                let ms = Double(c.seconds) * 1000.0 + Double(c.attoseconds) / 1_000_000_000_000_000.0
                if ms > maxStall {
                    maxStall = ms
                }
            }
        }

        return StreamingLatencyStats(
            sampleCount: endToEndLatencies.count,
            p50Ms: percentile(endToEndLatencies, p: 0.50),
            p95Ms: percentile(endToEndLatencies, p: 0.95),
            p99Ms: percentile(endToEndLatencies, p: 0.99),
            maxMs: endToEndLatencies.last ?? 0.0,
            maxStallMs: maxStall,
            stageBreakdown: breakdown,
            slowestStage: slowestStageName
        )
    }

    public func summaryReport() -> String {
        let stats = calculateStats()
        var report = """
        === Streaming Latency Trace Report (Samples: \(stats.sampleCount)) ===
        End-to-End Latency (providerFrameReceived -> openTUIPresented):
          p50: \(String(format: "%.2f", stats.p50Ms)) ms
          p95: \(String(format: "%.2f", stats.p95Ms)) ms
          p99: \(String(format: "%.2f", stats.p99Ms)) ms
          max: \(String(format: "%.2f", stats.maxMs)) ms
          max stall between frames: \(String(format: "%.2f", stats.maxStallMs)) ms

        Stage-by-Stage Breakdown:
        """
        for (stage, values) in stats.stageBreakdown.sorted(by: { $0.key < $1.key }) {
            report += "\n  \(stage.padding(toLength: 48, withPad: " ", startingAt: 0)) p50=\(String(format: "%.2f", values.p50))ms  p95=\(String(format: "%.2f", values.p95))ms  max=\(String(format: "%.2f", values.max))ms"
        }
        report += "\nBottleneck stage: \(stats.slowestStage)\n"
        return report
    }
}
