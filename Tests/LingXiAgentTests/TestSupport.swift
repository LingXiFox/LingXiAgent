import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

/// Structured async test resource helper to guarantee zero orphaned tasks and deterministic teardown.
public func withTestCoreHost<T: Sendable>(
    workspaceRoot: URL,
    providerAssembly: ModelRuntimeAssembly? = nil,
    storageLayout: CoreStorageLayout? = nil,
    _ operation: @Sendable (CoreHost) async throws -> T
) async throws -> T {
    let isCallerOwned = storageLayout != nil
    let layout = storageLayout ?? CoreStorageLayout.temporarySandbox()
    try layout.ensureDirectoriesExist()
    let host = try CoreHost(
        startupPolicy: .unitTest,
        providerAssembly: providerAssembly,
        workspaceRoot: WorkspaceRoot(path: workspaceRoot.path),
        dataRoot: layout.root,
        storageLayout: layout
    )
    await host.start()
    do {
        let result = try await operation(host)
        await host.shutdown()
        if !isCallerOwned {
            try? FileManager.default.removeItem(at: layout.root)
        }
        return result
    } catch {
        await host.shutdown()
        if !isCallerOwned {
            try? FileManager.default.removeItem(at: layout.root)
        }
        throw error
    }
}
