import Foundation
import Testing
import LingXiProtocol
import LingXiClient
@testable import LingXiCore

@Suite(.serialized) struct BranchPredictionSessionFeedTests {
    @Test func hostShutdownClearsOwnedPredictionStates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(providerAssembly: .init(provider: ScriptedFakeProvider(script: [[.textDelta("status"), .completed(.stop)]]), modelID: ModelID("lifecycle")), workspaceRoot: try WorkspaceRoot(path: root.path))
        await host.start()
        let client = LingXiClient.inProcess(endpoint: host)
        let sid = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sid, content: "Describe status")
        for try await _ in stream {}
        #expect(await BranchPredictionRuntime.shared.snapshot(sid) != nil)
        let other = try CoreHost(providerAssembly: .init(provider: ScriptedFakeProvider(script: [[.textDelta("other status"), .completed(.stop)]]), modelID: ModelID("other")), workspaceRoot: try WorkspaceRoot(path: root.path))
        await other.start()
        let otherClient = LingXiClient.inProcess(endpoint: other)
        let otherSID = try await otherClient.createSession()
        for try await _ in try await otherClient.sendMessage(sessionID: otherSID, content: "Describe status") {}
        await host.shutdown()
        #expect(await BranchPredictionRuntime.shared.snapshot(sid) == nil)
        #expect(await BranchPredictionRuntime.shared.snapshot(otherSID) != nil)
        await other.shutdown()
        #expect(await BranchPredictionRuntime.shared.snapshot(otherSID) == nil)
    }

    @Test func realSessionRuntimeTrajectoryLearnsScoresAndPublishesToObservatory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var script: [[ModelEvent]] = []
        for cycle in 0..<6 {
            try "needle-\(cycle)\n".write(to: root.appendingPathComponent("input\(cycle).txt"), atomically: true, encoding: .utf8)
            let tools = [("read_file", "{\"path\":\"input\(cycle).txt\"}"), ("grep", "{\"pattern\":\"needle-\(cycle)\",\"path\":\".\"}"), ("write_file", "{\"path\":\"output\(cycle).txt\",\"content\":\"edited-\(cycle)\"}"), ("shell", "{\"command\":\"test 4 -eq 4 && printf 'test passed\\n'\"}")]
            for (name,args) in tools {
                let call = ToolCall(callID: ToolCallID("trajectory-\(script.count)"), toolID: ToolID(name), arguments: args)
                script.append([.toolCallCompleted(call), .completed(.toolCalls)])
            }
        }
        script.append([.textDelta("Trajectory complete"), .completed(.stop)])
        let capture = PredictionFeedCapture()
        let provider = PredictionTrajectoryProvider(base: ScriptedFakeProvider(script: script), capture: capture)
        let host = try CoreHost(providerAssembly: .init(provider: provider, modelID: ModelID("trajectory")), workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: root.appendingPathComponent("core"), permissionDecision: .allow)
        await host.start()
        let client = LingXiClient.inProcess(endpoint: host)
        let sid = try await client.createSession()
        await capture.select(sid)
        _ = try await host.debugModeUpdate(envelope: .init(payload: .init(action: .setEnabled, enabled: true)))
        let stream = try await client.sendMessage(sessionID: sid, content: "Execute the local trajectory")
        do { for try await _ in stream {} }
        catch {
            let failedSession = try await client.session(sid)
            print("BRANCH_FEED_FAILURE_RESULTS " + failedSession.messages.flatMap { $0.parts.compactMap { if case let .toolResult(r) = $0 { return "\(r.toolName ?? "unknown") success=\(r.success) error=\(r.error?.message ?? "") content=\(r.content.prefix(1000))" }; return nil } }.joined(separator: "\n"))
            await host.shutdown()
            throw error
        }
        let snapshots = await capture.snapshots
        let forecast = try #require(snapshots.compactMap { $0 }.first { !$0.abstained })
        #expect(forecast.confidence >= 0.25 && forecast.support >= 2 && forecast.matchedOrder >= 1)
        #expect(snapshots.compactMap { $0 }.contains { !$0.abstained && $0.hint == "tool:write_file" })
        let final = try #require(await BranchPredictionRuntime.shared.snapshot(sid))
        #expect(final.hits > 0 && final.misses > 0)
        #expect(final.steps == final.hits + final.misses)
        let session = try await client.session(sid)
        let results = session.messages.flatMap { $0.parts.compactMap { if case let .toolResult(r) = $0 { r } else { nil } } }
        #expect(results.count == 24)
        #expect(results.allSatisfy { $0.success })
        let state = await host.contextStateSnapshot(sessionID: sid)
        #expect(state.prediction == final)
        let observatory = try await host.debugSnapshot(envelope: .init(payload: .init(sessionID: sid)))
        #expect(observatory.payload.prediction == final)
        if let path = ProcessInfo.processInfo.environment["LINGXI_PE_INTEGRITY_EVIDENCE"] {
            let root = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshots).write(to: root.appendingPathComponent("branch-trajectory-snapshots.json"), options: .atomic)
            try JSONEncoder().encode(observatory.payload).write(to: root.appendingPathComponent("branch-observatory.json"), options: .atomic)
        }
        print("BRANCH_REAL_FEED actions=24+directAnswer firstHint=\(forecast.hint) confidence=\(forecast.confidence) support=\(forecast.support) order=\(forecast.matchedOrder) final=\(final)")
        // Ending a turn must retain learning; deleting a session must release it.
        #expect(await BranchPredictionRuntime.shared.snapshot(sid) != nil)
        _ = try await host.deleteSession(envelope: .init(payload: .init(sessionID: sid)))
        #expect(await BranchPredictionRuntime.shared.snapshot(sid) == nil)
        await host.shutdown()
    }
}

private actor PredictionFeedCapture {
    var snapshots: [PredictionRuntimeSnapshot?] = []
    var sessionID: SessionID?
    func select(_ sessionID: SessionID) { self.sessionID = sessionID }
    func append(_ snapshot: PredictionRuntimeSnapshot?) { snapshots.append(snapshot) }
}
private struct PredictionTrajectoryProvider: ModelProvider {
    let base: ScriptedFakeProvider
    let capture: PredictionFeedCapture
    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let sid = await capture.sessionID
        await capture.append(sid == nil ? nil : await BranchPredictionRuntime.shared.snapshot(sid!))
        return try await base.stream(request)
    }
}
