import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

private actor ManualWatchdogClock {
    private var instant = ContinuousClock().now
    private var waiters: [(ContinuousClock.Instant, CheckedContinuation<Void, Error>)] = []

    func now() -> ContinuousClock.Instant { instant }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        guard instant < deadline else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if instant >= deadline { continuation.resume() }
                else { waiters.append((deadline, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiters() }
        }
    }

    func advance(by duration: Duration) {
        instant = instant.advanced(by: duration)
        let ready = waiters.filter { $0.0 <= instant }
        waiters.removeAll { $0.0 <= instant }
        for (_, continuation) in ready { continuation.resume() }
    }

    private func cancelWaiters() {
        let pending = waiters
        waiters.removeAll()
        for (_, continuation) in pending { continuation.resume(throwing: CancellationError()) }
    }
}

struct ExecutionWatchdogTests {
    @Test func streamIdleTimeoutReturnsTerminalFailure() async {
        let clock = ManualWatchdogClock()
        var sourceContinuation: AsyncThrowingStream<ModelEvent, Error>.Continuation?
        let source = AsyncThrowingStream<ModelEvent, Error> { sourceContinuation = $0 }
        let deadline = ExecutionDeadline(category: .provider, timeout: .seconds(1), idleTimeout: .milliseconds(20))
        let stream = ExecutionWatchdog.stream(source, deadline: deadline, clock: ExecutionWatchdogClock(now: { await clock.now() }, sleep: { try await clock.sleep(until: $0) }))
        await clock.advance(by: .milliseconds(50))
        var events: [ModelEvent] = []
        do {
            for try await event in stream { events.append(event) }
        } catch {
            Issue.record("watchdog stream 不应把 typed timeout 抛出: \(error)")
        }
        sourceContinuation?.finish()
        #expect(events.contains { if case let .failed(error) = $0 { error.code == .idleTimedOut } else { false } })
    }

    @Test func streamActivityRefreshesIdleWatchdog() async throws {
        let clock = ManualWatchdogClock()
        var continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation?
        let source = AsyncThrowingStream<ModelEvent, Error> { continuation = $0 }
        let deadline = ExecutionDeadline(category: .provider, timeout: .milliseconds(150), idleTimeout: .milliseconds(30))
        let stream = ExecutionWatchdog.stream(source, deadline: deadline, clock: ExecutionWatchdogClock(now: { await clock.now() }, sleep: { try await clock.sleep(until: $0) }))
        var iterator = stream.makeAsyncIterator()
        var count = 0
        for _ in 0..<3 {
            continuation?.yield(.textDelta("x"))
            let event = try #require(await iterator.next())
            if case .textDelta = event { count += 1 }
            await clock.advance(by: .milliseconds(10))
        }
        continuation?.finish()
        #expect(try await iterator.next() == nil)
        #expect(count == 3)
    }
}
