import Foundation
import LingXiProtocol

public struct PermissionResolution: Sendable, Equatable {
    public let decision: PermissionDecision
    public let asked: Bool
}

/// 内存权限状态：ask 时暂停本轮 Tool，收到一次性答复后即释放。
public actor PermissionEngine {
    private var rules: [ToolID: PermissionDecision]
    private var configuration: PermissionConfiguration
    private var legacyDefaultDecision: PermissionDecision?
    private var pending: [PermissionID: CheckedContinuation<PermissionDecision, Never>] = [:]

    public init(rules: [PermissionRule] = [], configuration: PermissionConfiguration = .strict) {
        self.rules = Dictionary(uniqueKeysWithValues: rules.map { ($0.toolID, $0.decision) })
        self.configuration = configuration
        legacyDefaultDecision = nil
    }

    public init(rules: [PermissionRule] = [], defaultDecision: PermissionDecision) {
        self.rules = Dictionary(uniqueKeysWithValues: rules.map { ($0.toolID, $0.decision) })
        configuration = defaultDecision == .allow ? .agent : .strict
        legacyDefaultDecision = defaultDecision
    }

    public func request(
        _ request: PermissionRequest,
        onAsk: @escaping @Sendable () async -> Void
    ) async -> PermissionDecision {
        await resolve(request, onAsk: onAsk).decision
    }

    public func resolve(
        _ request: PermissionRequest,
        onAsk: @escaping @Sendable () async -> Void
    ) async -> PermissionResolution {
        // Explicit deny always wins; auto only removes an otherwise interactive ask.
        let decision = rules[request.toolID] ?? legacyDefaultDecision ?? (configuration.policy == .auto ? .allow : .ask)
        guard decision == .ask else { return PermissionResolution(decision: decision, asked: false) }

        let resolved = await withCheckedContinuation { continuation in
            pending[request.permissionID] = continuation
            Task { await onAsk() }
        }
        return PermissionResolution(decision: resolved, asked: true)
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

    public func currentConfiguration() -> PermissionConfiguration { configuration }

    public func setConfiguration(_ configuration: PermissionConfiguration) {
        self.configuration = configuration
        legacyDefaultDecision = nil
    }
}
