import Foundation
import Testing
import LingXiProtocol
import LingXiClient
@testable import LingXiCore

private actor DiagnosticsProvider: ModelProvider {
    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("verified"))
            continuation.yield(.completed(.stop))
            continuation.finish()
        }
    }
}

struct RuntimeDiagnosticsTests {
    @Test func diagnosticsStoreRedactsSensitiveMetadata() async throws {
        let store = RuntimeDiagnosticsStore()
        await store.record(kind: .provider, event: "provider.request", metadata: [
            "api_key": "secret-api-key",
            "authorization": "Bearer secret-token",
            "status": "ok"
        ])
        let event = try #require(await store.snapshot().first)
        #expect(event.metadata["api_key"] == "[redacted]")
        #expect(event.metadata["authorization"] == "[redacted]")
        #expect(event.metadata["status"] == "ok")
    }

    @Test func coreExportsTraceAndRecoveryStateWithoutSecrets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let host = try CoreHost(
            providerAssembly: ModelRuntimeAssembly(provider: DiagnosticsProvider(), modelID: ModelID("diagnostics-model")),
            workspaceRoot: try WorkspaceRoot(path: root.path),
            permissionDecision: .allow
        )
        await host.start()
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: sessionID, content: "run verification") {}
        try await Task.sleep(for: .milliseconds(10))
        let bundle = try await client.diagnostics()

        #expect(bundle.runtimeVersion == CoreHost.coreVersion)
        #expect(bundle.protocolVersion == CoreHost.protocolVersion)
        #expect(bundle.provider.model == "diagnostics-model")
        #expect(bundle.trace.contains { $0.event == "core.start.begin" })
        #expect(bundle.trace.contains { $0.event == "provider.stream.begin" && $0.sessionID == sessionID })
        #expect(bundle.trace.allSatisfy { !$0.metadata.values.contains(where: { $0.contains("secret") }) })
        #expect(AgentRunStatus.recoveryRequired.isTerminal == false)
        await host.shutdown()
    }
}
