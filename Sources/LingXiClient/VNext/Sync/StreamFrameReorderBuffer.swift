import Foundation
import LingXiProtocol

public enum StreamFrameBarrierError: Error, Sendable, Equatable {
    case timeout(streamID: StreamID, expectedFinalIndex: UInt64, deliveredThrough: UInt64?)
    case missingFrames(streamID: StreamID, expected: UInt64, actual: UInt64)
}

/// StreamFrameReorderBuffer：负责高频 StreamFrame 的保序、去重、短期回放缓存与 terminal finalIndex delivery barrier。
///
/// 具备有界内存生命周期管理：
/// - 活跃流：保持保序窗口、接收 raw delta 并向订阅者广播；
/// - 终态流（Terminal stream）：在达到 finalIndex 或发生 canonical resync 后转入终态；
/// - 宽限期与容量驱逐：仅保留最近 N 个终态流的 raw deliveredFrames，超出的终态流自动清空 raw delta payload，
///   避免在长会话（如 100 轮长回答）下造成客户端双重内存膨胀；
/// - 终态元数据淘汰：超过最大容量的最旧终态流元数据自动从字典中完全驱逐。
public actor StreamFrameReorderBuffer {
    public struct StreamState: Sendable {
        public var nextExpectedIndex: UInt64 = 0
        public var bufferedFrames: [UInt64: StreamFrame] = [:]
        public var deliveredFrames: [StreamFrame] = []
        public var barrierWaiters: [UUID: (finalIndex: UInt64, continuation: CheckedContinuation<Void, Error>)] = [:]
        public var subscribers: [UUID: AsyncStream<StreamFrame>.Continuation] = [:]
        public var canonicalCommittedContent: String?
        public var isCanonicalResynced: Bool = false
        public var isTerminal: Bool = false
        public var finalIndex: UInt64?
        public var terminatedAt: Date?
        public var isPayloadEvicted: Bool = false

        public init() {}
    }

    private var streams: [StreamID: StreamState] = [:]
    private var terminalStreamOrder: [StreamID] = []

    /// 最多保留多少个终态流的 raw delivered frames 供短期重放（默认 8 个）
    public var maxRetainedTerminalStreamsWithFrames: Int = 8
    /// 最多保留多少个终态流的元数据记录（默认 64 个）
    public var maxRetainedTerminalStreamMetadata: Int = 64

    public init(
        maxRetainedTerminalStreamsWithFrames: Int = 8,
        maxRetainedTerminalStreamMetadata: Int = 64
    ) {
        self.maxRetainedTerminalStreamsWithFrames = maxRetainedTerminalStreamsWithFrames
        self.maxRetainedTerminalStreamMetadata = maxRetainedTerminalStreamMetadata
    }

    /// 接收一个 StreamFrame，按 index 保序、去重、缓存并向上层分发
    public func pushFrame(_ frame: StreamFrame) {
        let streamID = frame.streamID
        var state = streams[streamID] ?? StreamState()

        // 去重：如果该 frame 小于下一个期望输出的 index，说明已经递交过，直接丢弃
        if frame.index < state.nextExpectedIndex {
            return
        }
        // 如果该 frame 已经在缓存中，去重丢弃
        if state.bufferedFrames[frame.index] != nil {
            return
        }

        // 缓存该帧
        state.bufferedFrames[frame.index] = frame

        // 顺序释放连续到达的帧
        while let nextFrame = state.bufferedFrames.removeValue(forKey: state.nextExpectedIndex) {
            state.deliveredFrames.append(nextFrame)
            for subscriber in state.subscribers.values {
                subscriber.yield(nextFrame)
            }
            state.nextExpectedIndex += 1
        }

        streams[streamID] = state

        // 检查 barrier 等待者
        checkBarrierWaiters(for: streamID)
    }

    /// 订阅某个 StreamID 的有序去重数据流
    public func subscribe(streamID: StreamID) -> AsyncStream<StreamFrame> {
        let (stream, continuation) = AsyncStream.makeStream(of: StreamFrame.self)
        let subID = UUID()

        var state = streams[streamID] ?? StreamState()
        // 先重放已经递交的历史帧
        for frame in state.deliveredFrames {
            continuation.yield(frame)
        }

        if state.isTerminal {
            // 如果该流已经处于终态，回放已有帧后立即 finish，不永久挂起
            continuation.finish()
            return stream
        }

        state.subscribers[subID] = continuation
        streams[streamID] = state

        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeSubscriber(streamID: streamID, subscriberID: subID)
            }
        }

        return stream
    }

    /// 绑定底层数据源至排序缓冲区
    public func bindSource(streamID: StreamID, source: AsyncStream<StreamFrame>) {
        Task { [weak self] in
            for await frame in source {
                guard let self else { return }
                await self.pushFrame(frame)
            }
        }
    }

    /// 封装一个从原始流读取并保序去重的流
    public func orderedStream(streamID: StreamID, source: AsyncStream<StreamFrame>) -> AsyncStream<StreamFrame> {
        bindSource(streamID: streamID, source: source)
        return subscribe(streamID: streamID)
    }

    /// Terminal finalIndex delivery barrier：
    /// 确保在返回前，0...finalIndex 的所有帧已经全部递交完成。
    public func awaitFinalIndex(streamID: StreamID, finalIndex: UInt64, timeout: TimeInterval = 10.0) async throws {
        let state = streams[streamID] ?? StreamState()
        // 如果下一个期望 index 已经大于 finalIndex，说明 0...finalIndex 均已完整递交
        if state.nextExpectedIndex > finalIndex {
            markStreamTerminal(streamID: streamID, finalIndex: finalIndex)
            return
        }

        let waiterID = UUID()
        try await withCheckedThrowingContinuation { continuation in
            self.addBarrierWaiter(streamID: streamID, waiterID: waiterID, finalIndex: finalIndex, continuation: continuation)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeoutBarrierWaiter(streamID: streamID, waiterID: waiterID, finalIndex: finalIndex)
            }
        }
    }

    /// 标记流已终结并执行有界终态流淘汰
    public func markStreamTerminal(streamID: StreamID, finalIndex: UInt64) {
        var state = streams[streamID] ?? StreamState()
        guard !state.isTerminal else { return }

        state.isTerminal = true
        state.finalIndex = finalIndex
        state.terminatedAt = Date()

        // 结束并清空该流已有的 subscribers
        for subscriber in state.subscribers.values {
            subscriber.finish()
        }
        state.subscribers.removeAll()

        streams[streamID] = state

        if !terminalStreamOrder.contains(streamID) {
            terminalStreamOrder.append(streamID)
        }

        pruneTerminalStreams()
    }

    /// 当数据帧丢失且重放不可用时，执行 canonical committed-content resync：
    /// 记录已提交的权威内容，严禁伪造原始 StreamFrame identity（不伪造 frame index、kind 或 payload）。
    /// 解除 terminal finalIndex delivery barrier，结束对应 stream 的增量订阅，并交由有界生命周期淘汰。
    public func resyncWithCanonicalCommittedContent(
        streamID: StreamID,
        canonicalContent: String,
        finalIndex: UInt64
    ) {
        var state = streams[streamID] ?? StreamState()
        state.canonicalCommittedContent = canonicalContent
        state.isCanonicalResynced = true
        state.isTerminal = true
        state.finalIndex = finalIndex
        state.terminatedAt = Date()

        // 结束所有活跃 subscribers，表明原始高频流已由服务端终态事件裁定完结，不向流注入伪造 StreamFrame
        for subscriber in state.subscribers.values {
            subscriber.finish()
        }
        state.subscribers.removeAll()

        // 推进 nextExpectedIndex 以解除 delivery barrier，使等待终态语义事件递交的调用方正常向下继续
        state.nextExpectedIndex = max(state.nextExpectedIndex, finalIndex + 1)
        streams[streamID] = state

        if !terminalStreamOrder.contains(streamID) {
            terminalStreamOrder.append(streamID)
        }

        checkBarrierWaiters(for: streamID)
        pruneTerminalStreams()
    }

    /// 别名：执行 canonical committed-content resync，解除 delivery barrier
    @discardableResult
    public func recoverWithCommittedContent(
        streamID: StreamID,
        text: String,
        finalIndex: UInt64
    ) -> Bool {
        resyncWithCanonicalCommittedContent(streamID: streamID, canonicalContent: text, finalIndex: finalIndex)
        return true
    }

    /// 查询某 stream 是否执行过 canonical committed-content resync
    public func isCanonicalResynced(for streamID: StreamID) -> Bool {
        streams[streamID]?.isCanonicalResynced ?? false
    }

    /// 获取 canonical committed content（若已 resync）
    public func canonicalContent(for streamID: StreamID) -> String? {
        streams[streamID]?.canonicalCommittedContent
    }

    /// 获取该 stream 实际通过 wire 接收并递交的原始真实数据帧列表（绝不含伪造帧）
    public func deliveredFrames(for streamID: StreamID) -> [StreamFrame] {
        streams[streamID]?.deliveredFrames ?? []
    }

    public func highestDeliveredIndex(for streamID: StreamID) -> UInt64? {
        guard let state = streams[streamID], state.nextExpectedIndex > 0 else { return nil }
        return state.nextExpectedIndex - 1
    }

    /// 显式释放指定终态流的 raw deliveredFrames payload
    public func releasePayload(for streamID: StreamID) {
        if var state = streams[streamID] {
            state.deliveredFrames.removeAll(keepingCapacity: false)
            state.isPayloadEvicted = true
            streams[streamID] = state
        }
    }

    /// 修剪并释放超过保留限制的已终结流 raw payload 与最老元数据
    public func pruneTerminalStreams(forceEvictPayload: Bool = false) {
        // 1. 修剪 deliveredFrames raw payload
        var terminalWithPayloadCount = 0

        for streamID in terminalStreamOrder.reversed() {
            guard var state = streams[streamID] else { continue }
            guard state.isTerminal && !state.isPayloadEvicted else { continue }

            if forceEvictPayload || terminalWithPayloadCount >= maxRetainedTerminalStreamsWithFrames {
                state.deliveredFrames.removeAll(keepingCapacity: false)
                state.isPayloadEvicted = true
                streams[streamID] = state
            } else {
                terminalWithPayloadCount += 1
            }
        }

        // 2. 修剪多余的元数据记录
        if terminalStreamOrder.count > maxRetainedTerminalStreamMetadata {
            let excess = terminalStreamOrder.count - maxRetainedTerminalStreamMetadata
            let toRemove = terminalStreamOrder.prefix(excess)
            for streamID in toRemove {
                streams.removeValue(forKey: streamID)
            }
            terminalStreamOrder.removeFirst(excess)
        }
    }

    private func addBarrierWaiter(streamID: StreamID, waiterID: UUID, finalIndex: UInt64, continuation: CheckedContinuation<Void, Error>) {
        var state = streams[streamID] ?? StreamState()
        if state.nextExpectedIndex > finalIndex {
            markStreamTerminal(streamID: streamID, finalIndex: finalIndex)
            continuation.resume()
            return
        }
        state.barrierWaiters[waiterID] = (finalIndex: finalIndex, continuation: continuation)
        streams[streamID] = state
    }

    private func timeoutBarrierWaiter(streamID: StreamID, waiterID: UUID, finalIndex: UInt64) {
        guard var state = streams[streamID], let waiter = state.barrierWaiters.removeValue(forKey: waiterID) else { return }
        let delivered = state.nextExpectedIndex > 0 ? state.nextExpectedIndex - 1 : nil
        streams[streamID] = state
        waiter.continuation.resume(throwing: StreamFrameBarrierError.timeout(streamID: streamID, expectedFinalIndex: finalIndex, deliveredThrough: delivered))
    }

    private func removeSubscriber(streamID: StreamID, subscriberID: UUID) {
        if var state = streams[streamID] {
            state.subscribers.removeValue(forKey: subscriberID)
            streams[streamID] = state
        }
    }

    private func checkBarrierWaiters(for streamID: StreamID) {
        guard var state = streams[streamID] else { return }
        var resolvedAny = false
        var resolvedFinalIndex: UInt64?

        for (id, waiter) in state.barrierWaiters {
            if state.nextExpectedIndex > waiter.finalIndex {
                waiter.continuation.resume()
                state.barrierWaiters.removeValue(forKey: id)
                resolvedAny = true
                resolvedFinalIndex = max(resolvedFinalIndex ?? 0, waiter.finalIndex)
            }
        }
        streams[streamID] = state

        if resolvedAny, let finalIdx = resolvedFinalIndex {
            markStreamTerminal(streamID: streamID, finalIndex: finalIdx)
        }
    }

    // MARK: - Inspection Metrics for Tests & Diagnostics

    /// 客户端保留的 raw delivered frames 总数
    public var retainedDeliveredFrameCount: Int {
        streams.values.reduce(0) { $0 + $1.deliveredFrames.count }
    }

    /// 当前记录的流总数
    public var totalStreamsCount: Int {
        streams.count
    }

    /// 当前终态流数量
    public var terminalStreamsCount: Int {
        streams.values.filter { $0.isTerminal }.count
    }

    /// 已经释放 raw payload 的终态流数量
    public var evictedStreamsCount: Int {
        streams.values.filter { $0.isPayloadEvicted }.count
    }
}
