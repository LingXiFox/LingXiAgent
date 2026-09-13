import Foundation
import LingXiProtocol

/// Session-level mutation lock ensuring operations like submitTurn and revertLastTurn
/// on the same session execute in strict mutual exclusion.
public actor SessionMutationLock {
    public static let shared = SessionMutationLock()

    private var activeSessions: Set<SessionID> = []
    private var waiters: [SessionID: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func withExclusiveMutation<T: Sendable>(_ sessionID: SessionID, _ operation: () async throws -> T) async throws -> T {
        while activeSessions.contains(sessionID) {
            await withCheckedContinuation { continuation in
                waiters[sessionID, default: []].append(continuation)
            }
        }
        activeSessions.insert(sessionID)
        defer {
            activeSessions.remove(sessionID)
            if let next = waiters[sessionID]?.first {
                waiters[sessionID]?.removeFirst()
                if waiters[sessionID]?.isEmpty == true {
                    waiters.removeValue(forKey: sessionID)
                }
                next.resume()
            }
        }
        return try await operation()
    }
}
