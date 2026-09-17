import Foundation

/// 前端状态更新合并器 (FrontendUpdateCoalescer)。
/// 彻底解决高频 Streaming 产生的无界状态事件堆积与输入优先级反转问题。
/// 核心特性：
/// 1. 最多保留 1 份常驻状态快照，消除异步事件队列中排队数百个历史 ApplicationState 导致的 COW 内存放大；
/// 2. 累积合并 ApplicationChangeSet，保证即使多次更新合并，所有变动的 Node、Session 和 Context 标志均不丢失；
/// 3. 提供带 `.bufferingNewest(1)` 背压限制的轻量失效信号流 (invalidationSignal)，队列深度恒为 1；
/// 4. 彻底解耦输入事件与状态失效，使用户键盘输入永远处于最高调度优先级。
public actor FrontendUpdateCoalescer {
    private var latestState: ApplicationState?
    private var accumulatedChanges: ApplicationChangeSet = .empty
    private var latestRevision: UInt64 = 0
    private var signalContinuation: AsyncStream<Void>.Continuation?

    public init() {}

    /// 轻量失效信号流（队列深度恒限制为 1，带背压合流保证）
    public var invalidationSignal: AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.signalContinuation = continuation
            if self.latestState != nil {
                continuation.yield(())
            }
        }
    }

    /// 接收并合流来自 Store / Runtime 的更新包
    public func ingest(update: ApplicationUpdate) {
        self.latestState = update.state
        self.latestRevision = update.revision
        self.accumulatedChanges.merge(with: update.changes)
        self.signalContinuation?.yield(())
    }

    /// 原子提取最新合并状态并重置累积变更集
    public func drain() -> (state: ApplicationState, changes: ApplicationChangeSet, revision: UInt64)? {
        guard let state = latestState else { return nil }
        let changes = accumulatedChanges
        let revision = latestRevision
        self.accumulatedChanges = .empty
        return (state, changes, revision)
    }

    /// 当前是否有待处理的未消费状态
    public var hasPendingUpdate: Bool {
        latestState != nil && !accumulatedChanges.isEmpty
    }

    /// 获取当前最新版本号
    public var currentRevision: UInt64 {
        latestRevision
    }

    /// 终止信号流
    public func finish() {
        signalContinuation?.finish()
    }
}
