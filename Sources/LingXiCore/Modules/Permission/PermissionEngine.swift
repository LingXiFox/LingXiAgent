import Foundation
import LingXiProtocol

public struct PermissionResolution: Sendable, Equatable {
    public let decision: PermissionDecision
    public let asked: Bool
}

/// 内存权限状态：ask 时暂停本轮 Tool，收到一次性答复后即释放。
public actor PermissionEngine {
    private var rules: [PermissionRule]
    private var resourceRules: [PermissionResourceRule]
    private var configuration: PermissionConfiguration
    private var legacyDefaultDecision: PermissionDecision?
    private var pending: [PermissionID: CheckedContinuation<PermissionDecision, Never>] = [:]

    public init(rules: [PermissionRule] = [], resourceRules: [PermissionResourceRule] = [], configuration: PermissionConfiguration = .strict) {
        self.rules = rules
        self.resourceRules = resourceRules
        self.configuration = configuration
        legacyDefaultDecision = nil
    }

    public init(rules: [PermissionRule] = [], resourceRules: [PermissionResourceRule] = [], defaultDecision: PermissionDecision) {
        self.rules = rules
        self.resourceRules = resourceRules
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
        action: PermissionAction? = nil,
        onAsk: @escaping @Sendable () async -> Void
    ) async -> PermissionResolution {
        // Explicit deny always wins; auto only removes an otherwise interactive ask.
        let matching = rules.filter { $0.toolID == request.toolID && ($0.capability == nil || request.capabilities.contains($0.capability!)) }
        let resourceMatching = action.map { action in
            resourceRules.filter { $0.action == action && Self.matches($0.resourcePattern, request.resource) }
        } ?? []
        let decision: PermissionDecision
        if matching.contains(where: { $0.decision == .deny }) || resourceMatching.contains(where: { $0.decision == .deny }) { decision = .deny }
        else { decision = resourceMatching.last?.decision ?? matching.first?.decision ?? legacyDefaultDecision ?? (configuration.policy == .auto ? .allow : .ask) }
        guard decision == .ask else { return PermissionResolution(decision: decision, asked: false) }

        let resolved = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: PermissionDecision.deny)
                    return
                }
                pending[request.permissionID] = continuation
                Task { await onAsk() }
            }
        } onCancel: {
            Task { await self.cancel(request.permissionID) }
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

    public func setResourceRules(_ rules: [PermissionResourceRule]) { resourceRules = rules }

    private func cancel(_ permissionID: PermissionID) {
        pending.removeValue(forKey: permissionID)?.resume(returning: .deny)
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
        return (try? NSRegularExpression(pattern: "^" + escaped + "$")).map {
            $0.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        } ?? false
    }
}
