public protocol MonotonicClock: Sendable {
    func now() -> Duration
}

public struct SystemMonotonicClock: MonotonicClock {
    private let origin = SuspendingClock.Instant.now

    public init() {}

    public func now() -> Duration {
        origin.duration(to: SuspendingClock.Instant.now)
    }
}
