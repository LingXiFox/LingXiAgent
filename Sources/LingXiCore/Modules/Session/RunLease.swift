import Foundation
import LingXiProtocol

/// 统一运行凭证，用于在 Turn 的整个生命周期内标记并保护时间线版本。
public struct RunLease: Sendable, Equatable {
    public let sessionID: SessionID
    public let turnID: TurnID
    public let runID: RunID?
    public let revision: UInt64

    public init(sessionID: SessionID, turnID: TurnID, runID: RunID? = nil, revision: UInt64) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.runID = runID
        self.revision = revision
    }
}

/// 当尝试向已经过期/已被撤回的 Session 版本写入时抛出的标准阻断错误。
public struct StaleRunError: Error, Sendable, Equatable, LocalizedError {
    public let sessionID: SessionID
    public let expected: UInt64
    public let actual: UInt64

    public init(sessionID: SessionID, expected: UInt64, actual: UInt64) {
        self.sessionID = sessionID
        self.expected = expected
        self.actual = actual
    }

    public var errorDescription: String? {
        "Session \(sessionID.rawValue) revision mismatch: expected \(expected), actual \(actual) (stale run aborted)"
    }
}

/// 统一的 Session Revision 校验守卫契约。
public protocol SessionRevisionGuard: Sendable {
    func validate(_ lease: RunLease) async throws
    func currentRevision(_ sessionID: SessionID) async throws -> UInt64
}

public extension SessionRevisionGuard {
    func validate(_ lease: RunLease) async throws {
        let current = try await currentRevision(lease.sessionID)
        guard current == lease.revision else {
            throw StaleRunError(
                sessionID: lease.sessionID,
                expected: current,
                actual: lease.revision
            )
        }
    }
}

/// 基于 SessionStore 的标准 RevisionGuard 实现。
public struct StoreSessionRevisionGuard: SessionRevisionGuard {
    private let store: any SessionStore

    public init(store: any SessionStore) {
        self.store = store
    }

    public func currentRevision(_ sessionID: SessionID) async throws -> UInt64 {
        try await store.currentRevision(sessionID)
    }
}
