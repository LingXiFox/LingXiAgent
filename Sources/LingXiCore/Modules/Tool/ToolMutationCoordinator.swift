import Foundation

private actor MutationGate {
    private var acquired = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    func execute(_ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        try Task.checkCancellation()
        if acquired {
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append((id: waiterID, continuation: continuation))
                }
            } onCancel: {
                Task { [self] in
                    await self.cancelWaiter(id: waiterID)
                }
            }
        } else {
            acquired = true
        }

        do {
            try Task.checkCancellation()
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let item = waiters.remove(at: idx)
            item.continuation.resume(throwing: CancellationError())
        }
    }

    private func release() {
        if waiters.isEmpty {
            acquired = false
        } else {
            let item = waiters.removeFirst()
            item.continuation.resume()
        }
    }
}

/// Serializes workspace mutations and immediately refreshes project-backed indexes when configured.
public actor ToolMutationCoordinator {
    private let gate = MutationGate()
    private let pager: ContextPager?
    private let scanner: ProjectScanner?
    private var mutationHooks: [@Sendable () async -> Void] = []
    private var mutationRevision: UInt64 = 0
    private var reconciledRevision: UInt64 = 0
    private var isReconciling: Bool = false
    private var reconcileTask: Task<Void, Never>? = nil

    public init(pager: ContextPager? = nil, scanner: ProjectScanner? = nil) {
        self.pager = pager
        self.scanner = scanner
    }

    public var isDirty: Bool {
        mutationRevision > reconciledRevision
    }

    public var currentRevision: UInt64 {
        mutationRevision
    }

    public func addMutationHook(_ hook: @escaping @Sendable () async -> Void) {
        mutationHooks.append(hook)
    }

    public func reconcile() async throws {
        if let pager, let scanner { _ = try await pager.rebuildStaleFiles(using: scanner) }
        for hook in mutationHooks {
            await hook()
        }
    }

    public func execute(_ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        try await gate.execute { [self] in
            let result = try await operation()
            await self.triggerSingleFlightReconcile()
            return result
        }
    }

    private func triggerSingleFlightReconcile() {
        mutationRevision &+= 1
        guard !isReconciling else { return }
        isReconciling = true
        reconcileTask = Task { [weak self] in
            guard let self else { return }
            await self.drainReconciles()
        }
    }

    private func drainReconciles() async {
        defer {
            isReconciling = false
            reconcileTask = nil
        }
        while mutationRevision > reconciledRevision {
            let targetRevision = mutationRevision
            do {
                try await reconcile()
                reconciledRevision = targetRevision
            } catch {
                // Reconcile 失败时保持 dirty 状态，绝不伪造成功递增已同步版本 (Audit Round 9 Phase D)
                break
            }
        }
    }
}
