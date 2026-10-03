import Foundation
import LingXiProtocol

/// The debug telemetry bypass.
///
/// Structure is dictated by one constraint: turning this on must not change what the agent sends to
/// the model. So the hub holds no decision, is read by no decision, and its write path is O(1) with
/// no `await` and no disk I/O. `CoreHost` keeps it as an optional and sets it to nil while Developer
/// Debug Mode is off, which makes the disabled cost a single nil check at every call site — cheaper
/// than a flag read that somebody then has to reason about.
///
/// A ring buffer rather than an array with `removeFirst`: at the append rate a several-hundred-turn
/// run produces, shifting the whole buffer per event would be the most expensive thing this object
/// does, and it has no business being expensive. Reads are rare (a poll from the Observatory), so
/// they may scan.
///
/// Encoding and writing leave the lock entirely. `record` stores the value; one scheduled drain task
/// serialises to JSON and hands it to the recorder, so at most one such task is ever in flight and
/// disk latency never lands between two model steps.
public final class DebugTelemetryHub: @unchecked Sendable {
    /// Fixed slot count. Sized for a few hundred turns at several events per turn, with room to
    /// scroll backwards through what just happened.
    public static let defaultCapacity = 4096

    public static let schemaVersion = 1

    private let lock = NSLock()
    private var slots: [DebugTelemetryEvent?]
    /// Next write position; also the read position for the oldest event once the ring is full.
    private var head = 0
    private var filled = 0
    private var nextSequence: UInt64 = 1
    private var droppedCount = 0
    private var recordedCount = 0
    /// Sequence of the oldest event still held, so a reader can tell a gap from a quiet period.
    private var oldestRetainedSequence: UInt64 = 1

    private var pendingDrain: [DebugTelemetryEvent] = []
    private var drainScheduled = false
    private var recorder: DebugRunRecorder?
    private var archiveWriteFailures = 0
    private var recording = false
    private var runName: String?
    private let capacity: Int

    /// Per-session debug view, guarded by the same lock as the ring.
    var sessionStates: [SessionID: DebugSessionState] = [:]

    /// Mutates one session's state under the lock, creating it if absent.
    ///
    /// Lives here rather than in the session-state extension because the lock is private to this
    /// type: nothing outside this file may hold it, which is the only reason the ring and the
    /// per-session table cannot drift out of agreement.
    func mutateSessionState(_ sessionID: SessionID, _ body: (inout DebugSessionState) -> Void) {
        withLock {
            var state = sessionStates[sessionID] ?? DebugSessionState()
            body(&state)
            sessionStates[sessionID] = state
        }
    }

    /// Reads one session's state under the lock. Nil when the hub has never heard of it — which the
    /// callers must keep distinct from "known, and currently zero".
    func readSessionState<T>(_ sessionID: SessionID, _ body: (DebugSessionState) -> T) -> T? {
        withLock {
            guard let state = sessionStates[sessionID] else { return nil }
            return body(state)
        }
    }

    /// Removes a session's entry entirely, so the table does not grow by one per session ever seen.
    func removeSessionKey(_ sessionID: SessionID) {
        withLock { sessionStates.removeValue(forKey: sessionID) }
    }

    func knownSessionKeys() -> [SessionID] {
        withLock { Array(sessionStates.keys) }
    }

    public init(capacity: Int = DebugTelemetryHub.defaultCapacity) {
        let capacity = max(16, capacity)
        self.capacity = capacity
        self.slots = Array(repeating: nil, count: capacity)
    }

    // MARK: - Recording

    /// Appends one event and returns it with the sequence the hub assigned.
    ///
    /// The caller's `sequence` is ignored: ordering is only meaningful if the hub decides it, since
    /// events arrive from several actors and a caller-side counter would be per-object, not global.
    @discardableResult
    public func record(_ event: DebugTelemetryEvent) -> DebugTelemetryEvent {
        let stored = withLock { () -> DebugTelemetryEvent in
            var stamped = event
            stamped.sequence = nextSequence
            nextSequence &+= 1

            if filled == capacity {
                let slotIndex = head
                if let displaced = slots[slotIndex] {
                    // Something fell out of the ring. The reader must know, because a missing
                    // page-out looks exactly like a turn in which no page-out happened.
                    droppedCount += 1
                    oldestRetainedSequence = displaced.sequence + 1
                }
                slots[slotIndex] = stamped
                head = (head + 1) % capacity
            } else {
                slots[head] = stamped
                head += 1
                filled += 1
                // Wrap on the way in, not only on the way out: without this, `head` reaches
                // `capacity` exactly when the ring fills and the first eviction indexes past the
                // end of the buffer.
                if head == capacity { head = 0 }
            }
            recordedCount += 1
            if recorder != nil {
                pendingDrain.append(stamped)
            }
            return stamped
        }
        scheduleDrainIfNeeded()
        return stored
    }

    /// Convenience for categories that carry correlation ids and nothing else.
    public func record(
        _ category: DebugTelemetryCategory,
        sessionID: SessionID? = nil,
        runID: AgentRunID? = nil,
        turnID: TurnID? = nil,
        objectID: String? = nil,
        referenceID: String? = nil,
        toolCallID: ToolCallID? = nil,
        timestamp: Date = .now
    ) {
        record(DebugTelemetryEvent(
            sequence: 0,
            timestamp: timestamp,
            category: category,
            categoryRaw: category.rawValue,
            sessionID: sessionID,
            runID: runID,
            turnID: turnID,
            objectID: objectID,
            referenceID: referenceID,
            toolCallID: toolCallID
        ))
    }

    // MARK: - Reads

    /// Events with `sequence > after`, oldest first.
    public func events(after: UInt64 = 0, limit: Int = 500) -> [DebugTelemetryEvent] {
        withLock {
            var collected: [DebugTelemetryEvent] = []
            collected.reserveCapacity(min(max(1, limit), filled))
            // Start at the oldest occupied slot so the walk yields sequence order without a sort.
            let start = filled == capacity ? head : 0
            for offset in 0..<filled {
                guard let event = slots[(start + offset) % capacity] else { continue }
                if event.sequence > after {
                    collected.append(event)
                    if collected.count >= max(1, limit) { break }
                }
            }
            return collected
        }
    }

    public func latestSequence() -> UInt64 {
        withLock { nextSequence &- 1 }
    }

    /// True when the ring has already discarded something the caller's `after` still wants.
    public func hasGap(before after: UInt64) -> Bool {
        withLock { after.addingReportingOverflow(1).overflow ? true : after + 1 < oldestRetainedSequence }
    }

    public func status() -> DebugObservatoryStatus {
        withLock {
            DebugObservatoryStatus(
                enabled: true,
                recording: recording,
                runName: runName,
                ringCapacity: capacity,
                eventsBuffered: filled,
                eventsDropped: droppedCount,
                archiveWriteFailures: archiveWriteFailures,
                hubSchemaVersion: DebugTelemetryHub.schemaVersion
            )
        }
    }

    /// Discards the ring and every derived per-session panel. The on-disk archive is left alone:
    /// clearing live telemetry and erasing the evidence of a run are different requests, and only
    /// the first is implied here.
    public func clear() {
        withLock {
            slots = Array(repeating: nil, count: capacity)
            head = 0
            filled = 0
            droppedCount = 0
            oldestRetainedSequence = nextSequence
            pendingDrain.removeAll(keepingCapacity: true)
            sessionStates.removeAll()
        }
    }

    /// Events accepted since construction, including ones the ring has since evicted.
    public func totalRecorded() -> Int {
        withLock { recordedCount }
    }

    // MARK: - Recorder

    /// Attaches an archive, or detaches and closes the current one when passed nil.
    public func setRecorder(_ replacement: DebugRunRecorder?, runName: String?) {
        let replaced: DebugRunRecorder?
        if let replacement {
            replaced = withLock { () -> DebugRunRecorder? in
                let old = self.recorder
                self.recorder = replacement
                self.recording = true
                self.runName = runName
                return old
            }
        } else {
            replaced = withLock { () -> DebugRunRecorder? in
                let old = self.recorder
                self.recorder = nil
                self.recording = false
                self.runName = nil
                return old
            }
        }
        if let replaced {
            Task { await replaced.stop() }
        }
    }

    public func isRecording() -> Bool {
        withLock { recording }
    }

    /// The attached archive, for a caller that must flush it before reading it back off disk.
    public func activeRecorder() -> DebugRunRecorder? {
        withLock { recorder }
    }

    /// Folds recorder-reported faults into the hub status, so one line covers both "the ring
    /// dropped events" and "the archive fell behind".
    public func noteArchiveFailures(_ count: Int) {
        withLock { archiveWriteFailures = count }
    }

    // MARK: - Drain

    private func scheduleDrainIfNeeded() {
        let shouldSchedule = withLock { () -> Bool in
            guard !drainScheduled, !pendingDrain.isEmpty else { return false }
            drainScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task.detached(priority: .utility) { [weak self] in
            await self?.drainOnce()
        }
    }

    /// Encodes and hands off outside the lock. Loops so a burst that arrived mid-encode still
    /// flushes on this task rather than waiting for a new one.
    private func drainOnce() async {
        while true {
            let batch: [DebugTelemetryEvent] = withLock {
                let taken = self.pendingDrain
                self.pendingDrain.removeAll(keepingCapacity: true)
                return taken
            }
            if batch.isEmpty {
                withLock { drainScheduled = false }
                // Re-check: something may have queued between emptying and clearing the flag.
                if withLock({ !self.pendingDrain.isEmpty }) {
                    scheduleDrainIfNeeded()
                }
                return
            }
            guard let recorder = withLock({ self.recorder }) else { continue }
            await recorder.appendBatch(Self.encode(batch))
            let failures = await recorder.snapshot().failures
            noteArchiveFailures(failures)
        }
    }

    private static func encode(_ events: [DebugTelemetryEvent]) -> [Data] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // One JSON object per line, so a run still being written — or one killed mid-turn — stays
        // readable up to its last complete line.
        var lines: [Data] = []
        lines.reserveCapacity(events.count)
        for event in events {
            guard let data = try? encoder.encode(event) else { continue }
            var line = data
            line.append(0x0A)
            lines.append(line)
        }
        return lines
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
