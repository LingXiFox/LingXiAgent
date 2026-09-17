import Foundation
import LingXiProtocol
import LingXiTUIComponents

/// 无损优先 UI 事件调度器 (Lossless UI Event Pump)
/// 审计报告 Round 3 Phase D（问题 #30, #32）：
/// 彻底解耦用户输入通道（Lossless FIFO）与状态更新槽位（Merged Invalidation Slot），
/// 确保在流式状态暴风雨（State Storm）下用户击键 100% 零丢失且享有最高消费优先级。
public final class UIEventPump: @unchecked Sendable {
    public struct Batch: Sendable {
        public let inputs: [TUIInputEvent]
        public let commandResults: [TUITranscriptEntry]
        public let hasStateInvalidation: Bool

        public init(
            inputs: [TUIInputEvent],
            commandResults: [TUITranscriptEntry],
            hasStateInvalidation: Bool
        ) {
            self.inputs = inputs
            self.commandResults = commandResults
            self.hasStateInvalidation = hasStateInvalidation
        }
    }

    private let lock = NSLock()
    private var inputs: [TUIInputEvent] = []
    private var commandResults: [TUITranscriptEntry] = []
    private var stateInvalidated: Bool = false
    private var isFinished: Bool = false

    private var continuation: AsyncStream<Void>.Continuation?
    public let wakeupStream: AsyncStream<Void>

    public init() {
        var continuation: AsyncStream<Void>.Continuation?
        self.wakeupStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont in
            continuation = cont
        }
        self.continuation = continuation
    }

    /// 投递用户输入事件（无损排队，永不丢弃任何按键）
    public func postInput(_ event: TUIInputEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        inputs.append(event)
        continuation?.yield(())
    }

    /// 投递状态失效信号（折叠通知，避免状态暴风雨洪泛主循环）
    public func markStateInvalidated() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        if !stateInvalidated {
            stateInvalidated = true
            continuation?.yield(())
        }
    }

    /// 投递后台命令结果
    public func postCommandResult(_ entry: TUITranscriptEntry) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        commandResults.append(entry)
        continuation?.yield(())
    }

    /// 原子排空当前堆积的事件（按键无损排空，状态单次合并）
    public func drain() -> Batch {
        lock.lock()
        defer { lock.unlock() }
        let currentInputs = inputs
        inputs.removeAll(keepingCapacity: true)

        let currentResults = commandResults
        commandResults.removeAll(keepingCapacity: true)

        let currentStateInvalidation = stateInvalidated
        stateInvalidated = false

        return Batch(
            inputs: currentInputs,
            commandResults: currentResults,
            hasStateInvalidation: currentStateInvalidation
        )
    }

    /// 关闭事件通道
    public func finish() {
        lock.lock()
        defer { lock.unlock() }
        isFinished = true
        continuation?.finish()
    }
}
