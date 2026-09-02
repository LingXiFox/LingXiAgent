import Foundation
import LingXiProtocol

public struct PermissionResolution: Sendable, Equatable {
    public let decision: PermissionDecision
    public let asked: Bool
}

/// 内存权限状态：ask 时暂停本轮 Tool，收到一次性答复后即释放。
public actor PermissionEngine {
    private struct Pending {
        let request: PermissionRequest
        let continuation: CheckedContinuation<PermissionDecision, Never>?
        let onReply: (@Sendable (PermissionReply) async -> Void)?
    }

    private var rules: [PermissionRule]
    private var resourceRules: [PermissionResourceRule]
    private var configuration: PermissionConfiguration
    private var legacyDefaultDecision: PermissionDecision?
    private var pending: [PermissionID: Pending] = [:]
    private var restoredReplies: [ToolCallID: PermissionDecision] = [:]

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
        let decision = decision(for: request, action: action)
        guard decision == .ask else { return PermissionResolution(decision: decision, asked: false) }
        if let restored = restoredReplies.removeValue(forKey: request.toolCallID) {
            return PermissionResolution(decision: restored, asked: true)
        }

        let resolved = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: PermissionDecision.deny)
                    return
                }
                pending[request.permissionID] = Pending(request: request, continuation: continuation, onReply: nil)
                Task { await onAsk() }
            }
        } onCancel: {
            Task { await self.cancel(request.permissionID) }
        }
        return PermissionResolution(decision: resolved, asked: true)
    }

    /// 非阻塞检查，供没有 HITL 通道的扩展控制面使用。`.ask` 不会创建 pending request。
    public func check(_ request: PermissionRequest, action: PermissionAction? = nil) -> PermissionResolution {
        let decision = decision(for: request, action: action)
        return PermissionResolution(decision: decision, asked: false)
    }

    /// Re-register a durable ask after restart. Its reply resumes the owning scheduler, not a lost continuation.
    public func register(_ request: PermissionRequest, onAsk: @escaping @Sendable () async -> Void, onReply: @escaping @Sendable (PermissionReply) async -> Void) {
        guard pending[request.permissionID] == nil else { return }
        pending[request.permissionID] = Pending(request: request, continuation: nil, onReply: onReply)
        Task { await onAsk() }
    }

    public func reply(_ reply: PermissionReply) async throws {
        guard reply.decision != .ask else {
            throw CoreError(code: .permissionCancelled, message: "权限答复不能为 ask")
        }
        guard let waiting = pending.removeValue(forKey: reply.permissionID) else {
            throw CoreError(code: .permissionCancelled, message: "权限请求已失效: \(reply.permissionID.rawValue)")
        }
        restoredReplies[waiting.request.toolCallID] = reply.decision
        if let continuation = waiting.continuation {
            continuation.resume(returning: reply.decision)
        } else {
            await waiting.onReply?(reply)
        }
    }

    public func currentConfiguration() -> PermissionConfiguration { configuration }

    public func setConfiguration(_ configuration: PermissionConfiguration) {
        self.configuration = configuration
        legacyDefaultDecision = nil
    }

    public func setResourceRules(_ rules: [PermissionResourceRule]) { resourceRules = rules }

    private func cancel(_ permissionID: PermissionID) {
        pending.removeValue(forKey: permissionID)?.continuation?.resume(returning: .deny)
    }

    private func decision(for request: PermissionRequest, action: PermissionAction?) -> PermissionDecision {
        let matching = rules.filter { $0.toolID == request.toolID && ($0.capability == nil || request.capabilities.contains($0.capability!)) }
        let resourceMatching = action.map { value in resourceRules.filter { $0.action == value && Self.matches($0.resourcePattern, request.resource) } } ?? []
        if matching.contains(where: { $0.decision == .deny }) || resourceMatching.contains(where: { $0.decision == .deny }) { return .deny }
        return resourceMatching.last?.decision ?? matching.first?.decision ?? legacyDefaultDecision ?? (configuration.policy == .auto ? .allow : .ask)
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
        return (try? NSRegularExpression(pattern: "^" + escaped + "$")).map {
            $0.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        } ?? false
    }
}
