public protocol MonotonicClock: Sendable {
    func now() -> Duration
    /// Sleeps for the given duration. The loop uses this for its stream watchdog, so tests can drive
    /// time-outs from an injected clock instead of sleeping for real (QA-002).
    func sleep(for duration: Duration) async throws
}

public extension MonotonicClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public struct SystemMonotonicClock: MonotonicClock {
    private let origin = SuspendingClock.Instant.now

    public init() {}

    public func now() -> Duration {
        origin.duration(to: SuspendingClock.Instant.now)
    }
}
