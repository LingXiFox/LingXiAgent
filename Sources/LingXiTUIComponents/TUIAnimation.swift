import Foundation

public struct TUIAnimationTick: Sendable, Equatable {
    public let sequence: UInt64
    public let timestamp: ContinuousClock.Instant

    public init(sequence: UInt64, timestamp: ContinuousClock.Instant) {
        self.sequence = sequence
        self.timestamp = timestamp
    }
}

public struct TUIAnimationTicker: Sendable {
    public let interval: Duration

    public init(interval: Duration = .milliseconds(100)) {
        self.interval = interval
    }

    public func stream() -> AsyncStream<TUIAnimationTick> {
        let (stream, continuation) = AsyncStream.makeStream(of: TUIAnimationTick.self)
        let task = Task.detached { [interval] in
            let clock = ContinuousClock()
            var deadline = clock.now
            var sequence: UInt64 = 0
            while !Task.isCancelled {
                deadline = deadline.advanced(by: interval)
                do {
                    try await Task.sleep(until: deadline, clock: clock)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                sequence += 1
                continuation.yield(TUIAnimationTick(sequence: sequence, timestamp: clock.now))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
