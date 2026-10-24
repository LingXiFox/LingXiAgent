import Foundation
import LingXiPluginABI

/// Monotonic phase clock for one provider request. Every phase is milliseconds measured from the
/// invoke entry, so the reported numbers never go backwards; `totalMs` is the elapsed time when the
/// report itself is produced. Deliberately numbers only: no prompt, credential, header or request
/// content can enter this type.
final class MiMoTimingTracker: @unchecked Sendable {
    enum Phase: CaseIterable {
        /// Invoke entry to the wire body being built.
        case prepare
        /// Invoke entry to the HTTP request being handed to the transport.
        case send
        /// Invoke entry to the first response header.
        case firstResponse
        /// Invoke entry to the first SSE line.
        case firstSSE
        /// Invoke entry to the first reasoning delta.
        case firstReasoning
        /// Invoke entry to the first text delta.
        case firstText
        /// Invoke entry to the provider terminal event.
        case terminal
    }

    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    /// A cassette replay has no HTTP phases; it still reports the generation tail so offline PTY
    /// runs have a diagnostic instead of nothing.
    private let replay: Bool
    private let lock = NSLock()
    private var phases: [Phase: Int] = [:]
    private var finished = false

    init(replay: Bool) {
        self.replay = replay
        self.start = clock.now
    }

    /// Records the first time a phase is reached. Later marks for the same phase are ignored: the
    /// report describes the first byte/piece, not the last one.
    func mark(_ phase: Phase) {
        lock.lock()
        defer { lock.unlock() }
        guard phases[phase] == nil else { return }
        phases[phase] = elapsedLocked()
    }

    /// Produces the report exactly once, immediately before the request's terminal event. A second
    /// call returns nil, so one request can never emit two timing events.
    func finish() -> ProviderTiming? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        finished = true
        let total = elapsedLocked()
        guard !replay else { return ProviderTiming(totalMs: total) }
        return ProviderTiming(
            prepareMs: phases[.prepare],
            sendMs: phases[.send],
            firstResponseMs: phases[.firstResponse],
            firstSSEMs: phases[.firstSSE],
            firstReasoningMs: phases[.firstReasoning],
            firstTextMs: phases[.firstText],
            terminalMs: phases[.terminal],
            totalMs: total
        )
    }

    private func elapsedLocked() -> Int {
        let (seconds, attoseconds) = (clock.now - start).components
        let milliseconds = seconds * 1000 + attoseconds / 1_000_000_000_000_000
        return Int(max(0, milliseconds))
    }
}
