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
    // ponytail: global lock, use per-workspace gates only if independent workspaces become throughput-bound.
    private static let gate = MutationGate()
    private let pager: ContextPager?
    private let scanner: ProjectScanner?

    public init(pager: ContextPager? = nil, scanner: ProjectScanner? = nil) {
        self.pager = pager
        self.scanner = scanner
    }

    public func reconcile() async throws {
        if let pager, let scanner { _ = try await pager.rebuildStaleFiles(using: scanner) }
    }

    public func execute(_ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        try await Self.gate.execute {
            let result = try await operation()
            try await self.reconcile()
            return result
        }
    }
}
