import Foundation
import LingXiProtocol

/// StreamReplayState：统一管理 Session 内的高频 StreamFrame 生命周期、有序回放与终端资源释放。
/// 
/// 遵循端到端有界内存设计：
/// 1. Active 流：接收帧、保留 frames、通知活跃 subscribers；
/// 2. Closed 流：记录 finalIndex，进入短期回放宽限期（保留最近 N 个已关闭流的 raw frames）；
/// 3. Evicted 流：超过保留窗口或宽限期的已关闭流，彻底释放 raw frame payload，
///    仅保留 finalIndex 元数据用于边界校验与防重入；
/// 4. Terminal Metadata 淘汰：当记录的已关闭流总数超过上限时，从字典中完全驱逐最老的流元数据。
public struct StreamReplayState: Sendable {
    public enum LifecycleStatus: Sendable, Equatable {
        case active
        case closed(finalIndex: UInt64)
        case evicted(finalIndex: UInt64)

        public var finalIndex: UInt64? {
            switch self {
            case .active: return nil
            case let .closed(idx), let .evicted(idx): return idx
            }
        }

        public var isTerminal: Bool {
            switch self {
            case .active: return false
            case .closed, .evicted: return true
            }
        }
    }

    public struct StreamEntry: Sendable {
        public let streamID: StreamID
        public var status: LifecycleStatus
        public var frames: [StreamFrame]
        public var closedAt: Date?

        public init(streamID: StreamID, status: LifecycleStatus = .active, frames: [StreamFrame] = [], closedAt: Date? = nil) {
            self.streamID = streamID
            self.status = status
            self.frames = frames
            self.closedAt = closedAt
        }
    }

    private var entries: [StreamID: StreamEntry] = [:]
    private var closedStreamOrder: [StreamID] = []
    private var subscribers: [StreamID: [UUID: AsyncStream<StreamFrame>.Continuation]] = [:]

    /// 最多保留多少个已关闭流的 raw frames 供短期重放（默认 8 个）
    public var maxRetainedClosedStreamsWithFrames: Int
    /// 已关闭流保留 raw frames 的时间宽限期（默认 60 秒）
    public var replayGracePeriod: TimeInterval
    /// 最多保留多少个已终结流的元数据（默认 128 个）
    public var maxRetainedTerminalMetadata: Int

    public init(
        maxRetainedClosedStreamsWithFrames: Int = 8,
        replayGracePeriod: TimeInterval = 60.0,
        maxRetainedTerminalMetadata: Int = 128
    ) {
        self.maxRetainedClosedStreamsWithFrames = maxRetainedClosedStreamsWithFrames
        self.replayGracePeriod = replayGracePeriod
        self.maxRetainedTerminalMetadata = maxRetainedTerminalMetadata
    }

    // MARK: - Lifecycle Operations

    /// 登记一个已知流 ID
    public mutating func recordKnownStream(_ streamID: StreamID) {
        if entries[streamID] == nil {
            entries[streamID] = StreamEntry(streamID: streamID, status: .active)
        }
    }

    /// 查询是否存在某流
    public func hasStream(_ streamID: StreamID) -> Bool {
        entries[streamID] != nil
    }

    /// 查询某流的终结索引（若已关闭）
    public func terminalIndex(for streamID: StreamID) -> UInt64? {
        entries[streamID]?.status.finalIndex
    }

    /// 发射一个 StreamFrame 并推送到活跃 subscribers
    @discardableResult
    public mutating func emitFrame(_ frame: StreamFrame) throws -> StreamFrame {
        let streamID = frame.streamID
        var entry = entries[streamID] ?? StreamEntry(streamID: streamID, status: .active)

        if let terminal = entry.status.finalIndex {
            if frame.index > terminal {
                throw RuntimeError(
                    category: .runtime,
                    code: "streamAlreadyTerminated",
                    message: "Stream \(frame.streamID.rawValue) 已在 finalIndex \(terminal) 结束",
                    retryability: .none,
                    source: .core
                )
            }
        }

        entry.frames.append(frame)
        entries[streamID] = entry

        if let activeSubs = subscribers[streamID] {
            for sub in activeSubs.values {
                sub.yield(frame)
            }
        }

        return frame
    }

    /// 关闭一个流并设置 terminal finalIndex
    public mutating func closeStream(streamID: StreamID, finalIndex: UInt64) {
        var entry = entries[streamID] ?? StreamEntry(streamID: streamID, status: .active)
        entry.status = .closed(finalIndex: finalIndex)
        entry.closedAt = Date()
        entries[streamID] = entry

        // 结束所有活跃订阅者
        if let activeSubs = subscribers.removeValue(forKey: streamID) {
            for sub in activeSubs.values {
                sub.finish()
            }
        }

        if !closedStreamOrder.contains(streamID) {
            closedStreamOrder.append(streamID)
        }

        pruneClosedStreams()
    }

    /// 订阅某个流的有界增量与历史回放
    public mutating func subscribeStream(
        streamID: StreamID,
        afterIndex: UInt64?,
        removeSubscriberHandler: @escaping @Sendable (UUID) -> Void
    ) -> AsyncStream<StreamFrame> {
        let key = UUID()
        let entry = entries[streamID]
        let cached = entry?.frames ?? []
        let replay = cached.filter { frame in
            if let afterIndex { return frame.index > afterIndex }
            return true
        }
        let isTerminal = entry?.status.isTerminal ?? false

        return AsyncStream { continuation in
            for frame in replay {
                continuation.yield(frame)
            }

            if isTerminal {
                // 已终结流回放现有有效帧后立即 finish，严禁悬挂或产生死锁
                continuation.finish()
                return
            }

            self.subscribers[streamID, default: [:]][key] = continuation
            continuation.onTermination = { @Sendable _ in
                removeSubscriberHandler(key)
            }
        }
    }

    /// 移除特定的 subscriber
    public mutating func removeSubscriber(streamID: StreamID, key: UUID) {
        subscribers[streamID]?.removeValue(forKey: key)
        if subscribers[streamID]?.isEmpty == true {
            subscribers.removeValue(forKey: streamID)
        }
    }

    /// 修剪并释放超过保留限制的已关闭流 raw payload 及最老元数据
    public mutating func pruneClosedStreams(now: Date = Date(), forceEvictAllPayloads: Bool = false) {
        // 1. 宽限期检查与淘汰超额 payload
        var closedWithPayloadCount = 0

        // 从最新的向最旧的倒序统计
        for streamID in closedStreamOrder.reversed() {
            guard var entry = entries[streamID] else { continue }
            guard case let .closed(finalIndex) = entry.status else { continue }

            let isExpired = if let closedAt = entry.closedAt {
                now.timeIntervalSince(closedAt) > replayGracePeriod
            } else {
                false
            }

            if forceEvictAllPayloads || isExpired || closedWithPayloadCount >= maxRetainedClosedStreamsWithFrames {
                // 淘汰 raw payload，释放内存
                entry.frames.removeAll(keepingCapacity: false)
                entry.status = .evicted(finalIndex: finalIndex)
                entries[streamID] = entry
            } else {
                closedWithPayloadCount += 1
            }
        }

        // 2. 淘汰过量的 terminal 元数据
        if closedStreamOrder.count > maxRetainedTerminalMetadata {
            let excess = closedStreamOrder.count - maxRetainedTerminalMetadata
            let toRemove = closedStreamOrder.prefix(excess)
            for streamID in toRemove {
                entries.removeValue(forKey: streamID)
                subscribers.removeValue(forKey: streamID)
            }
            closedStreamOrder.removeFirst(excess)
        }
    }

    /// 彻底清空所有流状态与订阅（用于 revert/undo 重置）
    public mutating func reset() {
        for subs in subscribers.values {
            for sub in subs.values {
                sub.finish()
            }
        }
        subscribers.removeAll()
        entries.removeAll()
        closedStreamOrder.removeAll()
    }

    // MARK: - Inspection Metrics for Tests & Diagnostics

    /// 当前所有流持有的 raw frames 总数
    public var retainedFrameCount: Int {
        entries.values.reduce(0) { $0 + $1.frames.count }
    }

    /// 当前活跃流数量
    public var activeStreamCount: Int {
        entries.values.filter { $0.status == .active }.count
    }

    /// 当前仍保留 raw frames 的已关闭流数量
    public var closedStreamsWithPayloadCount: Int {
        entries.values.filter {
            if case .closed = $0.status { return true }
            return false
        }.count
    }

    /// 已驱逐 raw payload 的已终结流数量
    public var evictedStreamsCount: Int {
        entries.values.filter {
            if case .evicted = $0.status { return true }
            return false
        }.count
    }
}
