import Foundation
import LingXiProtocol

/// TUI 脏标记集合
public struct TUIDirtyFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let content   = TUIDirtyFlags(rawValue: 1 << 0) // stateUpdate / streaming delta
    public static let animation = TUIDirtyFlags(rawValue: 1 << 1) // spinner / elapsed tick (10fps)
    public static let input     = TUIDirtyFlags(rawValue: 1 << 2) // user input / composer
    public static let layout    = TUIDirtyFlags(rawValue: 1 << 3) // resize / overlay
}

/// 统一 TUI Frame Scheduler
/// 限制 streaming content 渲染帧率最多约 30~60fps，spinner 约 10fps，
/// 将多个 dirty source 合并到同一 frame，无 dirty 时不 render，
/// 禁止 token/status/animation 各自直接 present。
@MainActor
public final class TUIFrameScheduler {
    public private(set) var dirtyFlags: TUIDirtyFlags = []
    private var isFramePending: Bool = false
    private let targetFrameDurationNs: UInt64
    private var onFrame: (@MainActor (TUIDirtyFlags) -> Void)?
    private var lastRenderTime: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    public private(set) var renderedFrameCount: Int = 0
    public private(set) var skippedFrameCount: Int = 0

    public init(targetFps: Int = 60, onFrame: (@MainActor (TUIDirtyFlags) -> Void)? = nil) {
        let fps = max(1, min(120, targetFps))
        self.targetFrameDurationNs = UInt64(1_000_000_000 / fps)
        self.onFrame = onFrame
    }

    public func setFrameHandler(_ handler: @escaping @MainActor (TUIDirtyFlags) -> Void) {
        self.onFrame = handler
    }

    public func markDirty(_ flags: TUIDirtyFlags) {
        dirtyFlags.insert(flags)
        scheduleNextFrameIfNeeded()
    }

    private func scheduleNextFrameIfNeeded() {
        guard !isFramePending, !dirtyFlags.isEmpty else { return }
        isFramePending = true

        let now = clock.now
        let elapsedNs: UInt64
        if let last = lastRenderTime {
            let dur = last.duration(to: now)
            let c = dur.components
            let ns = UInt64(max(0, c.seconds)) * 1_000_000_000 + UInt64(max(0, c.attoseconds / 1_000_000_000))
            elapsedNs = ns
        } else {
            elapsedNs = targetFrameDurationNs
        }

        let delayNs = elapsedNs < targetFrameDurationNs ? (targetFrameDurationNs - elapsedNs) : 0

        Task { @MainActor [weak self] in
            if delayNs > 0 {
                try? await Task.sleep(nanoseconds: delayNs)
            }
            self?.executeFrame()
        }
    }

    private func executeFrame() {
        isFramePending = false
        guard !dirtyFlags.isEmpty else {
            skippedFrameCount += 1
            return
        }

        let flags = dirtyFlags
        dirtyFlags = []
        lastRenderTime = clock.now
        renderedFrameCount += 1

        onFrame?(flags)
    }

    /// 强制同步刷新
    public func flush() {
        guard !dirtyFlags.isEmpty else { return }
        executeFrame()
    }
}
