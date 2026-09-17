import Foundation
import LingXiProtocol

/// Low-overhead performance metrics collector for LingXiTUI.
/// Active only when `LINGXI_TUI_PERF=1` environment variable is set or `isEnabled` is set to true.
public final class TUIPerformanceMetrics: @unchecked Sendable {
    public static let shared = TUIPerformanceMetrics()

    private let lock = NSLock()
    public var isEnabled: Bool

    // MARK: - Aggregated Counters
    public private(set) var totalFrames: Int = 0
    public private(set) var fullRefreshCount: Int = 0
    public private(set) var incrementalRefreshCount: Int = 0
    public private(set) var sidebarRebuildCount: Int = 0
    public private(set) var inputEventCount: Int = 0
    public private(set) var skippedFrameCount: Int = 0

    // MARK: - Last Instant / Values
    public private(set) var lastTimelineNodeCount: Int = 0
    public private(set) var lastTranscriptEntryCount: Int = 0
    public private(set) var lastChangedRows: Int = 0
    public private(set) var lastChangedCells: Int = 0

    // MARK: - Duration Samples (in nanoseconds)
    private var refreshViewTotalSamples: [UInt64] = []
    private var transcriptProjectionSamples: [UInt64] = []
    private var sidebarProjectionSamples: [UInt64] = []
    private var viewRenderSamples: [UInt64] = []
    private var terminalPresentSamples: [UInt64] = []
    private var frameTotalSamples: [UInt64] = []
    private var stateUpdateToScheduledSamples: [UInt64] = []

    private let maxSamples = 2000

    @inline(__always)
    public static func durationNs(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant = ContinuousClock.now) -> UInt64 {
        let dur = start.duration(to: end)
        let c = dur.components
        return UInt64(max(0, c.seconds)) * 1_000_000_000 + UInt64(max(0, c.attoseconds / 1_000_000_000))
    }

    private init() {
        let envVal = ProcessInfo.processInfo.environment["LINGXI_TUI_PERF"]
        self.isEnabled = (envVal == "1" || envVal?.lowercased() == "true")
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        totalFrames = 0
        fullRefreshCount = 0
        incrementalRefreshCount = 0
        sidebarRebuildCount = 0
        inputEventCount = 0
        skippedFrameCount = 0
        lastTimelineNodeCount = 0
        lastTranscriptEntryCount = 0
        lastChangedRows = 0
        lastChangedCells = 0
        refreshViewTotalSamples.removeAll(keepingCapacity: true)
        transcriptProjectionSamples.removeAll(keepingCapacity: true)
        sidebarProjectionSamples.removeAll(keepingCapacity: true)
        viewRenderSamples.removeAll(keepingCapacity: true)
        terminalPresentSamples.removeAll(keepingCapacity: true)
        frameTotalSamples.removeAll(keepingCapacity: true)
        stateUpdateToScheduledSamples.removeAll(keepingCapacity: true)
    }

    @inline(__always)
    public func recordInputEvent() {
        guard isEnabled else { return }
        lock.lock()
        inputEventCount += 1
        lock.unlock()
    }

    @inline(__always)
    public func recordRefresh(isFull: Bool, nodesCount: Int, entriesCount: Int) {
        guard isEnabled else { return }
        lock.lock()
        if isFull {
            fullRefreshCount += 1
        } else {
            incrementalRefreshCount += 1
        }
        lastTimelineNodeCount = nodesCount
        lastTranscriptEntryCount = entriesCount
        lock.unlock()
    }

    @inline(__always)
    public func recordSidebarRebuild() {
        guard isEnabled else { return }
        lock.lock()
        sidebarRebuildCount += 1
        lock.unlock()
    }

    @inline(__always)
    public func recordFramePresent(changedRows: Int, changedCells: Int) {
        guard isEnabled else { return }
        lock.lock()
        totalFrames += 1
        lastChangedRows = changedRows
        lastChangedCells = changedCells
        lock.unlock()
    }

    @inline(__always)
    public func recordSkippedFrame() {
        guard isEnabled else { return }
        lock.lock()
        skippedFrameCount += 1
        lock.unlock()
    }

    @inline(__always)
    public func recordRefreshViewTotal(durationNs: UInt64) {
        guard isEnabled else { return }
        lock.lock()
        appendSample(&refreshViewTotalSamples, durationNs)
        lock.unlock()
    }

    @inline(__always)
    public func recordTranscriptProjection(durationNs: UInt64) {
        guard isEnabled else { return }
        lock.lock()
        appendSample(&transcriptProjectionSamples, durationNs)
        lock.unlock()
    }

    @inline(__always)
    public func recordSidebarProjection(durationNs: UInt64) {
        guard isEnabled else { return }
        lock.lock()
        appendSample(&sidebarProjectionSamples, durationNs)
        lock.unlock()
    }

    @inline(__always)
    public func recordViewRender(durationNs: UInt64) {
        guard isEnabled else { return }
        lock.lock()
        appendSample(&viewRenderSamples, durationNs)
        lock.unlock()
    }

    @inline(__always)
    public func recordTerminalPresent(durationNs: UInt64) {
        guard isEnabled else { return }
        lock.lock()
        appendSample(&terminalPresentSamples, durationNs)
        lock.unlock()
    }

    @inline(__always)
    public func recordFrameTotal(durationNs: UInt64) {
        guard isEnabled else { return }
        lock.lock()
        appendSample(&frameTotalSamples, durationNs)
        lock.unlock()
    }

    @inline(__always)
    public func recordStateUpdateToScheduled(durationNs: UInt64) {
        guard isEnabled else { return }
        lock.lock()
        appendSample(&stateUpdateToScheduledSamples, durationNs)
        lock.unlock()
    }

    private func appendSample(_ array: inout [UInt64], _ val: UInt64) {
        if array.count < maxSamples {
            array.append(val)
        } else {
            let idx = Int.random(in: 0..<maxSamples)
            array[idx] = val
        }
    }

    // MARK: - Snapshot & Report
    public struct StageStats: Sendable {
        public let count: Int
        public let minMs: Double
        public let maxMs: Double
        public let avgMs: Double
        public let p50Ms: Double
        public let p95Ms: Double
        public let p99Ms: Double
    }

    public struct Snapshot: Sendable {
        public let totalFrames: Int
        public let fullRefreshCount: Int
        public let incrementalRefreshCount: Int
        public let sidebarRebuildCount: Int
        public let inputEventCount: Int
        public let skippedFrameCount: Int
        public let lastTimelineNodeCount: Int
        public let lastTranscriptEntryCount: Int
        public let lastChangedRows: Int
        public let lastChangedCells: Int

        public let refreshViewTotal: StageStats
        public let transcriptProjection: StageStats
        public let sidebarProjection: StageStats
        public let viewRender: StageStats
        public let terminalPresent: StageStats
        public let frameTotal: StageStats
        public let stateUpdateToScheduled: StageStats
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        return Snapshot(
            totalFrames: totalFrames,
            fullRefreshCount: fullRefreshCount,
            incrementalRefreshCount: incrementalRefreshCount,
            sidebarRebuildCount: sidebarRebuildCount,
            inputEventCount: inputEventCount,
            skippedFrameCount: skippedFrameCount,
            lastTimelineNodeCount: lastTimelineNodeCount,
            lastTranscriptEntryCount: lastTranscriptEntryCount,
            lastChangedRows: lastChangedRows,
            lastChangedCells: lastChangedCells,
            refreshViewTotal: computeStats(refreshViewTotalSamples),
            transcriptProjection: computeStats(transcriptProjectionSamples),
            sidebarProjection: computeStats(sidebarProjectionSamples),
            viewRender: computeStats(viewRenderSamples),
            terminalPresent: computeStats(terminalPresentSamples),
            frameTotal: computeStats(frameTotalSamples),
            stateUpdateToScheduled: computeStats(stateUpdateToScheduledSamples)
        )
    }

    private func computeStats(_ samples: [UInt64]) -> StageStats {
        guard !samples.isEmpty else {
            return StageStats(count: 0, minMs: 0, maxMs: 0, avgMs: 0, p50Ms: 0, p95Ms: 0, p99Ms: 0)
        }
        let sorted = samples.sorted()
        let count = sorted.count
        let sum = sorted.reduce(0, +)
        let toMs: (UInt64) -> Double = { Double($0) / 1_000_000.0 }

        let minMs = toMs(sorted.first!)
        let maxMs = toMs(sorted.last!)
        let avgMs = Double(sum) / Double(count) / 1_000_000.0
        let p50Ms = toMs(sorted[Int(Double(count - 1) * 0.50)])
        let p95Ms = toMs(sorted[Int(Double(count - 1) * 0.95)])
        let p99Ms = toMs(sorted[Int(Double(count - 1) * 0.99)])

        return StageStats(
            count: count,
            minMs: minMs,
            maxMs: maxMs,
            avgMs: avgMs,
            p50Ms: p50Ms,
            p95Ms: p95Ms,
            p99Ms: p99Ms
        )
    }

    public func generateReport() -> String {
        let snap = snapshot()
        var s = ""
        s += "============================================================\n"
        s += "📊 LINGXI TUI PERFORMANCE METRICS REPORT\n"
        s += "============================================================\n"
        s += "Frames: total=\(snap.totalFrames) skipped=\(snap.skippedFrameCount)\n"
        s += "Refreshes: full=\(snap.fullRefreshCount) incremental=\(snap.incrementalRefreshCount)\n"
        s += "Sidebar rebuilds: \(snap.sidebarRebuildCount) | Input events: \(snap.inputEventCount)\n"
        s += "Nodes: \(snap.lastTimelineNodeCount) | Entries: \(snap.lastTranscriptEntryCount)\n"
        s += "------------------------------------------------------------\n"
        s += formatStage("refreshView.total", snap.refreshViewTotal)
        s += formatStage("transcriptProjection", snap.transcriptProjection)
        s += formatStage("sidebarProjection", snap.sidebarProjection)
        s += formatStage("viewRender", snap.viewRender)
        s += formatStage("terminalPresent", snap.terminalPresent)
        s += formatStage("frameTotal", snap.frameTotal)
        s += formatStage("stateUpdateToScheduled", snap.stateUpdateToScheduled)
        s += "============================================================\n"
        return s
    }

    private func formatStage(_ name: String, _ stats: StageStats) -> String {
        guard stats.count > 0 else {
            return String(format: "%-24@ : count=0\n", name)
        }
        return String(
            format: "%-24@ : count=%-5d avg=%6.2fms p50=%6.2fms p95=%6.2fms p99=%6.2fms max=%6.2fms\n",
            name, stats.count, stats.avgMs, stats.p50Ms, stats.p95Ms, stats.p99Ms, stats.maxMs
        )
    }
}
