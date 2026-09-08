import Foundation
import LingXiProtocol

public enum WatermarkSyncPolicy: Sendable, Equatable {
    /// 默认严格策略：必须同步全部 watermark scope；若存在未订阅 scope，明确抛出 cannotSynchronizeScope，不得静默跳过
    case requireAllScopes
    /// 显式策略：仅等待当前客户端已订阅建立 consumer 的 scope，显式跳过未订阅 scope
    case onlySubscribedScopes
}

public enum WatermarkSyncError: Error, Sendable, Equatable {
    case timeout(scope: EventStreamScope, target: EventCursor)
    case generationMismatch(expected: EventLogGenerationID, actual: EventLogGenerationID)
    case cannotSynchronizeScope(scope: EventStreamScope, reason: String)
}

/// WatermarkSynchronizer：负责 scoped EventWatermark 同步等待与游标观测。
/// 保证在 CommandReceipt 返回后，上层能够等待本地 consumer 观测到 observedThrough 中的事实。
public actor WatermarkSynchronizer {
    private var observedCursors: [EventStreamScope: EventCursor] = [:]
    private var subscribedScopes: Set<EventStreamScope> = []
    private var waiters: [UUID: Waiter] = [:]

    private struct Waiter {
        let id: UUID
        let scope: EventStreamScope
        let targetCursor: EventCursor
        let continuation: CheckedContinuation<Void, Error>
    }

    public init() {}

    /// 标记某个 scope 正在被本地 consumer 订阅
    public func markScopeSubscribed(_ scope: EventStreamScope) {
        subscribedScopes.insert(scope)
    }

    /// 标记某个 scope 停止订阅
    public func markScopeUnsubscribed(_ scope: EventStreamScope) {
        subscribedScopes.remove(scope)
    }

    /// 查询某个 scope 是否处于订阅状态
    public func isScopeSubscribed(_ scope: EventStreamScope) -> Bool {
        subscribedScopes.contains(scope)
    }

    /// 记录本地 consumer 已经观察到的事件游标
    public func recordObserved(scope: EventStreamScope, cursor: EventCursor) {
        if let current = observedCursors[scope] {
            if cursor > current {
                observedCursors[scope] = cursor
            }
        } else {
            observedCursors[scope] = cursor
        }
        checkWaiters(for: scope)
    }

    /// 获取当前指定作用域已观察到的最高游标
    public func currentCursor(for scope: EventStreamScope) -> EventCursor? {
        observedCursors[scope]
    }

    /// 重置或更新游标（例如 Snapshot fallback 之后）
    public func resetCursor(for scope: EventStreamScope, to cursor: EventCursor) {
        observedCursors[scope] = cursor
        checkWaiters(for: scope)
    }

    /// 等待指定作用域的事件游标被观察到（>= targetCursor）
    public func awaitWatermark(_ watermark: EventWatermark, timeout: TimeInterval = 10.0) async throws {
        let scope = watermark.scope
        let target = watermark.cursor

        if let current = observedCursors[scope], current >= target {
            return
        }

        let waiterID = UUID()
        try await withCheckedThrowingContinuation { continuation in
            self.addWaiter(id: waiterID, scope: scope, target: target, continuation: continuation)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeoutWaiter(id: waiterID, scope: scope, target: target)
            }
        }
    }

    /// 等待 CommandReceipt 中的全部 observedThrough 水位线被本地观察到。
    /// - Parameters:
    ///   - receipt: 命令回执。
    ///   - timeout: 超时时间。
    ///   - policy: 水位线同步策略。默认 .requireAllScopes（严禁静默跳过，若有未订阅 scope 则抛出 cannotSynchronizeScope）。
    public func awaitReceipt<T>(
        _ receipt: CommandReceipt<T>,
        timeout: TimeInterval = 10.0,
        policy: WatermarkSyncPolicy = .requireAllScopes
    ) async throws {
        if policy == .requireAllScopes {
            for watermark in receipt.observedThrough {
                if !subscribedScopes.contains(watermark.scope) {
                    throw WatermarkSyncError.cannotSynchronizeScope(
                        scope: watermark.scope,
                        reason: "Scope \(watermark.scope) is not subscribed and cannot be synchronized without an active consumer"
                    )
                }
            }
        }

        for watermark in receipt.observedThrough {
            let isSubscribed = subscribedScopes.contains(watermark.scope)
            if !isSubscribed {
                switch policy {
                case .onlySubscribedScopes:
                    // 显式 policy 指定仅等待已订阅 scope，跳过未订阅 scope
                    continue
                case .requireAllScopes:
                    throw WatermarkSyncError.cannotSynchronizeScope(
                        scope: watermark.scope,
                        reason: "Scope \(watermark.scope) is not subscribed and cannot be synchronized without an active consumer"
                    )
                }
            }
            try await awaitWatermark(watermark, timeout: timeout)
        }
    }

    private func addWaiter(id: UUID, scope: EventStreamScope, target: EventCursor, continuation: CheckedContinuation<Void, Error>) {
        if let current = observedCursors[scope], current >= target {
            continuation.resume()
            return
        }
        waiters[id] = Waiter(id: id, scope: scope, targetCursor: target, continuation: continuation)
    }

    private func timeoutWaiter(id: UUID, scope: EventStreamScope, target: EventCursor) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.continuation.resume(throwing: WatermarkSyncError.timeout(scope: scope, target: target))
        }
    }

    private func checkWaiters(for scope: EventStreamScope) {
        guard let current = observedCursors[scope] else { return }
        for (id, waiter) in waiters where waiter.scope == scope {
            if current >= waiter.targetCursor {
                waiter.continuation.resume()
                waiters.removeValue(forKey: id)
            }
        }
    }
}
