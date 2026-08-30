import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

private actor ParentChildProvider: ModelProvider {
    private let spawn = ToolCall(callID: ToolCallID("spawn-child"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"inspect child","title":"Child"}"#)

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let firstUser = request.messages.first(where: { $0.role == .user })?.content
        let events: [ModelEvent]
        if firstUser == "inspect child" {
            events = [.textDelta("child result"), .completed(.stop)]
        } else if request.messages.contains(where: { $0.role == .tool }) {
            events = [.textDelta("parent result"), .completed(.stop)]
        } else {
            events = [.toolCallCompleted(spawn), .completed(.toolCalls)]
        }
        let stream = AsyncThrowingStream<ModelEvent, Error>(bufferingPolicy: .unbounded) { continuation in
            for event in events { _ = continuation.yield(event) }
            continuation.finish()
        }
        return stream
    }
}

struct SubagentRuntimeTests {
    @Test func spawnCreatesIndependentChildSessionAndRunResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: ParentChildProvider(), modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let primary = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: primary, content: "parent task")
        for try await _ in stream {}

        let deadline = Date().addingTimeInterval(2)
        var tree = try await client.getAgentTree(primary)
        while tree.children.first?.latestRun?.status != .completed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            tree = try await client.getAgentTree(primary)
        }
        let child = try #require(tree.children.first)
        let childRun = try #require(child.latestRun)
        #expect(child.session.kind == .subagent)
        #expect(child.session.parentSessionID == primary)
        #expect(child.session.rootSessionID == primary)
        #expect(childRun.sessionID == child.session.id)
        #expect(childRun.status == .completed)
        #expect(try await client.subagentResult(childRun.runID).finalText == "child result")
        #expect((try await client.session(primary)).messages.allSatisfy { !$0.content.contains("child result") })
    }

    @Test func modelResolverRejectsUnallowedChildModel() async {
        let resolver = SubagentModelResolver(defaultRuntime: ModelRuntimeAssembly(provider: ParentChildProvider(), modelID: ModelID("luna")), allowedModels: ["luna"])
        await #expect(throws: CoreError.self) {
            try await resolver.resolve(ModelSelection(modelID: "terra"))
        }
    }
}
