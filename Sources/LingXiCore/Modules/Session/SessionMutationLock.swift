import Foundation
import LingXiProtocol

/// Session-level mutation lock ensuring operations like submitTurn and revertLastTurn
/// on the same session execute in strict mutual exclusion.
public actor SessionMutationLock {
    public static let shared = SessionMutationLock()

    private var activeSessions: Set<SessionID> = []
    private var waiters: [SessionID: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func acquire(_ sessionID: SessionID) async {
        if !activeSessions.contains(sessionID) && (waiters[sessionID]?.isEmpty ?? true) {
            activeSessions.insert(sessionID)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[sessionID, default: []].append(continuation)
        }
    }

    public func release(_ sessionID: SessionID) {
        if let next = waiters[sessionID]?.first {
            waiters[sessionID]?.removeFirst()
            if waiters[sessionID]?.isEmpty == true {
                waiters.removeValue(forKey: sessionID)
            }
            // Atomically hand over the lock to the next queued waiter.
            // activeSessions remains populated with sessionID to prevent incoming tasks from jumping the queue.
            next.resume()
        } else {
            activeSessions.remove(sessionID)
        }
    }

    public func withExclusiveMutation<T: Sendable>(_ sessionID: SessionID, _ operation: () async throws -> T) async throws -> T {
        await acquire(sessionID)
        defer { release(sessionID) }
        return try await operation()
    }
}
