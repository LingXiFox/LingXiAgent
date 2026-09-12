import Foundation
import LingXiProtocol

/// 高性能流式增量合并器 (LiveDeltaBuffer)
/// 在 16~33ms (约 30~60fps) 的时间窗口内将同一流、同一语义类型的连续文本 delta 进行合并，
/// 避免每个逐字 token 触发完整 State 广播与 UI 重排。
/// 核心原则：绝不人为等待尚未到达的 token；若流结束或主动 flush，立即派发。
public final class LiveDeltaBuffer: @unchecked Sendable {
    private let windowNanoseconds: UInt64
    private let lock = NSLock()
    private var pendingFrames: [StreamFrame] = []
    private var flushTask: Task<Void, Never>?
    private var onFlush: (@Sendable ([StreamFrame]) async -> Void)?
    private var synchronousFlush: (@Sendable ([StreamFrame]) -> Void)?
    private var isTerminated: Bool = false

    public init(windowMs: UInt64 = 16, onFlush: (@Sendable ([StreamFrame]) async -> Void)? = nil) {
        self.windowNanoseconds = windowMs * 1_000_000
        self.onFlush = onFlush
    }

    private init(windowMs: UInt64, synchronousFlush: @escaping @Sendable ([StreamFrame]) -> Void) {
        self.windowNanoseconds = windowMs * 1_000_000
        self.synchronousFlush = synchronousFlush
    }

    deinit {
        flushTask?.cancel()
    }

    /// 设定 flush 回调
    public func setFlushHandler(_ handler: @escaping @Sendable ([StreamFrame]) async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.onFlush = handler
    }

    /// 追加新的 StreamFrame
    public func append(_ frame: StreamFrame) {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminated else { return }

        // 尝试与末尾可合并的帧进行合并
        if let last = pendingFrames.last, canCoalesce(last, frame) {
            let merged = coalesce(last, frame)
            pendingFrames[pendingFrames.count - 1] = merged
        } else {
            pendingFrames.append(frame)
        }

        // 若当前无活跃的定时调度任务，立即启动一个 16~33ms 窗口的 flush 计时器
        if flushTask == nil {
            let delayNs = self.windowNanoseconds
            flushTask = Task { [weak self] in
                if delayNs > 0 {
                    do { try await Task.sleep(nanoseconds: delayNs) }
                    catch { return }
                }
                await self?.flush()
            }
        }
    }

    private func drainPendingFrames() -> ([StreamFrame], (@Sendable ([StreamFrame]) async -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        flushTask?.cancel()
        flushTask = nil
        let frames = pendingFrames
        pendingFrames.removeAll(keepingCapacity: true)
        // AsyncStream delivery is synchronous under the drain lock, so finish cannot overtake a flush.
        synchronousFlush?(frames)
        return (frames, onFlush)
    }

    /// 立即刷新当前缓冲中的所有帧（不等待定时器）
    public func flush() async {
        let (framesToFlush, handler) = drainPendingFrames()
        guard !framesToFlush.isEmpty, let handler else { return }
        await handler(framesToFlush)
    }

    private func markTerminated() {
        lock.lock()
        defer { lock.unlock() }
        isTerminated = true
    }

    /// 结束缓冲并执行最终的 flush
    public func finish() async {
        markTerminated()
        await flush()
    }

    // MARK: - 合并规则
    private func canCoalesce(_ a: StreamFrame, _ b: StreamFrame) -> Bool {
        guard a.streamID == b.streamID,
              a.kind == b.kind,
              a.owner.sessionID == b.owner.sessionID,
              a.owner.modelStepID == b.owner.modelStepID,
              a.owner.toolCallID == b.owner.toolCallID else {
            return false
        }
        switch a.kind {
        case .assistantText, .visibleReasoning, .reasoningSummary, .stdout, .stderr, .toolLiveOutput:
            return a.textPayload != nil && b.textPayload != nil
        default:
            return false
        }
    }

    private func coalesce(_ a: StreamFrame, _ b: StreamFrame) -> StreamFrame {
        let combinedText = (a.textPayload ?? "") + (b.textPayload ?? "")
        return StreamFrame(
            streamID: a.streamID,
            owner: b.owner,
            index: b.index,
            kind: b.kind,
            text: combinedText
        )
    }

    /// 将任意 AsyncStream<StreamFrame> 包装为经过 LiveDeltaBuffer coalesce 后的流
    public static func coalesceStream(
        _ upstream: AsyncStream<StreamFrame>,
        windowMs: UInt64 = 16
    ) -> AsyncStream<StreamFrame> {
        AsyncStream { continuation in
            let buffer = LiveDeltaBuffer(windowMs: windowMs, synchronousFlush: { frames in
                for frame in frames { continuation.yield(frame) }
            })
            let pump = Task {
                for await frame in upstream {
                    guard !Task.isCancelled else { break }
                    buffer.append(frame)
                }
                await buffer.finish()
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    /// 将任意 AsyncStream<StreamFrame> 包装为经过自适应平滑缓冲 (Fluid Pacing) 后的流，
    /// 彻底消除网络抖动导致的突冒与卡顿感。
    public static func fluidStream(
        _ upstream: AsyncStream<StreamFrame>,
        intervalMs: UInt64 = 16
    ) -> AsyncStream<StreamFrame> {
        AsyncStream { continuation in
            let pacer = AdaptiveFluidStreamPacer(intervalMs: intervalMs)
            pacer.setHandlers(
                onYield: { frame in
                    continuation.yield(frame)
                },
                onFinished: {
                    continuation.finish()
                }
            )

            Task {
                for await frame in upstream {
                    pacer.enqueue(frame)
                }
                await pacer.finish()
            }
        }
    }
}

/// 自适应平滑流式吐字缓冲区 (AdaptiveFluidStreamPacer)
/// 用于消除上游网络抖动与 batching 带来的“停顿后突然大块冒出”的视觉跳跃感。
/// 按照微时隙节奏 (~16ms, 约60fps) 平滑匀速吐字，在网络延迟波动时提供自然连续的打字体验。
/// 积压多时自适应平滑加速追赶，流结束时瞬间 flush 全部剩余内容，兼顾丝滑视觉与零最终延迟。
public final class AdaptiveFluidStreamPacer: @unchecked Sendable {
    private struct PendingTextItem {
        let frameTemplate: StreamFrame
        var characters: [Character]
    }

    private let intervalNanoseconds: UInt64
    private let lock = NSLock()
    private var pendingItems: [PendingTextItem] = []
    private var isFinished = false
    private var pacingTask: Task<Void, Never>?
    private var onYield: (@Sendable (StreamFrame) async -> Void)?
    private var onFinished: (@Sendable () async -> Void)?

    public init(intervalMs: UInt64 = 20) {
        self.intervalNanoseconds = intervalMs * 1_000_000
    }

    deinit {
        pacingTask?.cancel()
    }

    public func setHandlers(
        onYield: @escaping @Sendable (StreamFrame) async -> Void,
        onFinished: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.onYield = onYield
        self.onFinished = onFinished
    }

    public func enqueue(_ frame: StreamFrame) {
        guard let text = frame.textPayload, !text.isEmpty else {
            // 非文本帧或控制帧零延迟直通
            lock.lock()
            let handler = onYield
            lock.unlock()
            if let handler {
                Task { await handler(frame) }
            }
            return
        }

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        let chars = Array(text)
        if var last = pendingItems.last,
           last.frameTemplate.streamID == frame.streamID,
           last.frameTemplate.kind == frame.kind {
            last.characters.append(contentsOf: chars)
            pendingItems[pendingItems.count - 1] = last
        } else {
            pendingItems.append(PendingTextItem(frameTemplate: frame, characters: chars))
        }

        ensurePacingLoopRunningLocked()
        lock.unlock()
    }

    public func finish() async {
        let needsWait: Bool = {
            lock.lock()
            defer { lock.unlock() }
            isFinished = true
            guard !pendingItems.isEmpty else { return false }
            ensurePacingLoopRunningLocked()
            return true
        }()

        if needsWait {
            // 平滑排空：最多等待 200ms 让 pacer 自然匀速排空完毕，彻底避免瞬发砸出
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
            while ContinuousClock.now < deadline {
                let isEmpty = {
                    lock.lock()
                    defer { lock.unlock() }
                    return pendingItems.isEmpty
                }()
                if isEmpty { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        // 最终兜底：如极端超时仍有未排出项，做确定性 flush
        let (framesToFlush, finishHandler, yieldHandler) = {
            lock.lock()
            defer { lock.unlock() }
            pacingTask?.cancel()
            pacingTask = nil
            var frames: [StreamFrame] = []
            for item in pendingItems where !item.characters.isEmpty {
                let remainingText = String(item.characters)
                frames.append(StreamFrame(
                    streamID: item.frameTemplate.streamID,
                    owner: item.frameTemplate.owner,
                    index: item.frameTemplate.index,
                    kind: item.frameTemplate.kind,
                    text: remainingText
                ))
            }
            pendingItems.removeAll()
            let fin = onFinished
            onFinished = nil
            return (frames, fin, onYield)
        }()

        if let yieldHandler {
            for f in framesToFlush {
                await yieldHandler(f)
            }
        }
        if let finishHandler {
            await finishHandler()
        }
    }

    private func ensurePacingLoopRunningLocked() {
        guard pacingTask == nil else { return }
        pacingTask = Task { [weak self] in
            while true {
                guard let self else { break }
                let (nextFrame, shouldContinue, finishHandler, yieldHandler) = self.stepPacing()
                if let nextFrame, let yieldHandler {
                    await yieldHandler(nextFrame)
                }
                if !shouldContinue {
                    if let finishHandler {
                        await finishHandler()
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: self.intervalNanoseconds)
            }
        }
    }

    private func stepPacing() -> (
        nextFrame: StreamFrame?,
        shouldContinue: Bool,
        onFinished: (@Sendable () async -> Void)?,
        onYield: (@Sendable (StreamFrame) async -> Void)?
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard !pendingItems.isEmpty else {
            pacingTask = nil
            if isFinished {
                let fin = onFinished
                onFinished = nil
                return (nil, false, fin, onYield)
            } else {
                return (nil, false, nil, onYield)
            }
        }

        // 自适应自然微块步长
        let totalPending = pendingItems.reduce(0) { $0 + $1.characters.count }
        let paceSize: Int = {
            if isFinished {
                // 流已结束阶段：以微块自然排空，避免瞬发大块或过度拖延
                if totalPending <= 6 { return totalPending }
                if totalPending <= 18 { return max(3, totalPending / 2) }
                return max(6, totalPending / 3)
            }
            // 正常流式阶段：以自然微块（2~4字）平滑滑出，既保证丝滑感，又消除单字折行抽搐
            if totalPending <= 4 {
                return min(2, totalPending)
            } else if totalPending <= 12 {
                return 3
            } else if totalPending <= 25 {
                return 5
            } else if totalPending <= 60 {
                return 8
            } else {
                return max(10, totalPending / 5)
            }
        }()

        var item = pendingItems[0]
        let takeCount = min(paceSize, item.characters.count)
        let takenChars = item.characters.prefix(takeCount)
        item.characters.removeFirst(takeCount)

        if item.characters.isEmpty {
            pendingItems.removeFirst()
        } else {
            pendingItems[0] = item
        }

        let chunkText = String(takenChars)
        let outFrame = StreamFrame(
            streamID: item.frameTemplate.streamID,
            owner: item.frameTemplate.owner,
            index: item.frameTemplate.index,
            kind: item.frameTemplate.kind,
            text: chunkText
        )

        let hasMore = !pendingItems.isEmpty || !isFinished
        let fin: (@Sendable () async -> Void)? = {
            if hasMore { return nil }
            let f = onFinished
            onFinished = nil
            return f
        }()
        return (outFrame, hasMore, fin, onYield)
    }
}
