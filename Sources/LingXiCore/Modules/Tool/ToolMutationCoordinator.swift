import Foundation

/// Serializes workspace mutations and immediately refreshes the project-backed indexes.
public actor ToolMutationCoordinator {
    private let pager: ContextPager
    private let scanner: ProjectScanner

    public init(pager: ContextPager, scanner: ProjectScanner) {
        self.pager = pager
        self.scanner = scanner
    }

    public func reconcile() async throws {
        _ = try await pager.rebuildStaleFiles(using: scanner)
    }

    public func execute(_ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        let result = try await operation()
        try await reconcile()
        return result
    }
}
