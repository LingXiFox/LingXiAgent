import Foundation
import Testing
import LingXiClient
import LingXiCore
import LingXiProtocol

struct ProductionProjectionTests {
    @Test func contextProjectionIsProducedByCoreWithIndependentLayers() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = try CoreHost(
            providerAssembly: ModelRuntimeAssembly(
                provider: ProjectionProvider(),
                modelID: ModelID("projection-model"),
                contextProfile: ModelContextProfile(contextWindowTokens: 10_000)
            ),
            workspaceRoot: try WorkspaceRoot(path: root.path),
            permissionDecision: .allow
        )
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "projection")
        for try await _ in stream {}

        let projection = try #require(try await client.contextProjection(sessionID))
        #expect(projection.l1.layer == .l1)
        #expect(projection.l1.capacity == 10_000)
        #expect(projection.l1.percent != nil)
        #expect(projection.l2.layer == .l2)
        #expect(projection.l3.layer == .l3)
        #expect(projection.l1 != projection.l2)
    }

    @Test func extensionProjectionDiscoversProjectSkills() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".lingxi/skills/projection/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Projection skill".utf8).write(to: skill)
        let host = try CoreHost(workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let values = try await LingXiClient.inProcess(endpoint: host).listExtensions(kind: .skill)
        #expect(values.contains { $0.id == "projection" && $0.kind == .skill })
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-production-projection-\(UUID().uuidString)", isDirectory: true)
    }
}

private struct ProjectionProvider: ModelProvider {
    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("ok"))
            continuation.yield(.completed(.stop))
            continuation.finish()
        }
    }
}
