import Foundation
import LingXiProtocol

/// 内存权限状态：ask 时暂停本轮 Tool，收到一次性答复后即释放。
public actor PermissionEngine {
    private let rules: [ToolID: PermissionDecision]
    private let defaultDecision: PermissionDecision
    private var pending: [PermissionID: CheckedContinuation<PermissionDecision, Never>] = [:]

    public init(rules: [PermissionRule] = [], defaultDecision: PermissionDecision = .ask) {
        self.rules = Dictionary(uniqueKeysWithValues: rules.map { ($0.toolID, $0.decision) })
        self.defaultDecision = defaultDecision
    }

    public func request(
        _ request: PermissionRequest,
        onAsk: @escaping @Sendable () async -> Void
    ) async -> PermissionDecision {
        let decision = rules[request.toolID] ?? defaultDecision
        guard decision == .ask else { return decision }

        return await withCheckedContinuation { continuation in
            pending[request.permissionID] = continuation
            Task { await onAsk() }
        }
    }

    public func reply(_ reply: PermissionReply) throws {
        guard reply.decision != .ask else {
            throw CoreError(code: .permissionCancelled, message: "权限答复不能为 ask")
        }
        guard let continuation = pending.removeValue(forKey: reply.permissionID) else {
            throw CoreError(code: .permissionCancelled, message: "权限请求已失效: \(reply.permissionID.rawValue)")
        }
        continuation.resume(returning: reply.decision)
    }
}
