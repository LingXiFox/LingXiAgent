import Foundation

private actor MutationGate {
    private var acquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func execute(_ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        if acquired {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            acquired = true
        }
        do {
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func release() {
        if waiters.isEmpty { acquired = false }
        else { waiters.removeFirst().resume() }
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
            } catch {
                // Reconcile errors are logged/swallowed so mutation callers aren't disrupted
            }
            reconciledRevision = targetRevision
        }
    }
}
