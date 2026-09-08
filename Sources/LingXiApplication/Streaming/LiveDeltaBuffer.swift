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
    private var isTerminated: Bool = false

    public init(windowMs: UInt64 = 16, onFlush: (@Sendable ([StreamFrame]) async -> Void)? = nil) {
        self.windowNanoseconds = windowMs * 1_000_000
        self.onFlush = onFlush
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
                    try? await Task.sleep(nanoseconds: delayNs)
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
            let buffer = LiveDeltaBuffer(windowMs: windowMs) { frames in
                for f in frames {
                    continuation.yield(f)
                }
            }

            Task {
                for await frame in upstream {
                    buffer.append(frame)
                }
                await buffer.finish()
                continuation.finish()
            }
        }
    }
}
