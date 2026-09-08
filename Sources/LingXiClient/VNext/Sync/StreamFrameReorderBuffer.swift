import Foundation
import LingXiProtocol

public enum StreamFrameBarrierError: Error, Sendable, Equatable {
    case timeout(streamID: StreamID, expectedFinalIndex: UInt64, deliveredThrough: UInt64?)
    case missingFrames(streamID: StreamID, expected: UInt64, actual: UInt64)
}

/// StreamFrameReorderBuffer：负责高频 StreamFrame 的保序、去重、缓存与 terminal finalIndex delivery barrier。
public actor StreamFrameReorderBuffer {
    private struct StreamState {
        var nextExpectedIndex: UInt64 = 0
        var bufferedFrames: [UInt64: StreamFrame] = [:]
        var deliveredFrames: [StreamFrame] = []
        var barrierWaiters: [UUID: (finalIndex: UInt64, continuation: CheckedContinuation<Void, Error>)] = [:]
        var subscribers: [UUID: AsyncStream<StreamFrame>.Continuation] = [:]
        var canonicalCommittedContent: String?
        var isCanonicalResynced: Bool = false
    }

    private var streams: [StreamID: StreamState] = [:]

    public init() {}

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

    /// 当数据帧丢失且重放不可用时，执行 canonical committed-content resync：
    /// 记录已提交的权威内容，严禁伪造原始 StreamFrame identity（不伪造 frame index、kind 或 payload）。
    /// 解除 terminal finalIndex delivery barrier，结束对应 stream 的增量订阅。
    public func resyncWithCanonicalCommittedContent(
        streamID: StreamID,
        canonicalContent: String,
        finalIndex: UInt64
    ) {
        var state = streams[streamID] ?? StreamState()
        state.canonicalCommittedContent = canonicalContent
        state.isCanonicalResynced = true

        // 结束所有活跃 subscribers，表明原始高频流已由服务端终态事件裁定完结，不向流注入伪造 StreamFrame
        for subscriber in state.subscribers.values {
            subscriber.finish()
        }
        state.subscribers.removeAll()

        // 推进 nextExpectedIndex 以解除 delivery barrier，使等待终态语义事件递交的调用方正常向下继续
        state.nextExpectedIndex = max(state.nextExpectedIndex, finalIndex + 1)
        streams[streamID] = state

        checkBarrierWaiters(for: streamID)
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

    private func addBarrierWaiter(streamID: StreamID, waiterID: UUID, finalIndex: UInt64, continuation: CheckedContinuation<Void, Error>) {
        var state = streams[streamID] ?? StreamState()
        if state.nextExpectedIndex > finalIndex {
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
        for (id, waiter) in state.barrierWaiters {
            if state.nextExpectedIndex > waiter.finalIndex {
                waiter.continuation.resume()
                state.barrierWaiters.removeValue(forKey: id)
            }
        }
        streams[streamID] = state
    }
}
