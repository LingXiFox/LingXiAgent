import Foundation
import Testing
import LingXiProtocol
import LingXiClient
@testable import LingXiCore

@Suite(.serialized) struct PERecallContractTests {
    private let marker = "RECALL_MIDDLE_EVIDENCE_731"
    private var payload: String { String(repeating: "archived data ", count: 1500) + marker + "\n" + String(repeating: "remaining data ", count: 1500) }

    @Test func canonicalAssemblyRetainsRawSuccessfulToolResult() async throws {
        let result = ToolResult(callID: ToolCallID("large"), success: true, content: payload, toolName: "shell")
        let session = Session(id: SessionID("canonical"), createdAt: .now, messages: [
            Message(id: MessageID("result"), role: .tool, parts: [.toolResult(result)], createdAt: .now)])
        let entries = await PCoreContextEngine().entries(for: session)
        #expect(entries.first?.part == .toolResult(result))
    }

    @Test func explicitRecallSliceSurvivesEveryProviderWithoutSecondTruncation() async throws {
        let sid = SessionID("slice"), fabric = PEContextIntegrityTests().store()
        let ref = await fabric.pageOut(sessionID: sid, content: payload, origin: .message,
            contextOccurrenceID: "old", evictionEpoch: 0, summary: "middle evidence")
        let slice = try await ContextRecallTool(ecoreStore: fabric, sessionID: sid).execute(
            arguments: "{\"id\":\"\(ref.referenceID)\",\"offset\":15000}", profile: .workspace)
        #expect(slice.contains(marker))
        let call = ToolCall(callID: ToolCallID("slice"), toolID: ToolID("context_recall"), arguments: "{}")
        let result = ToolResult(callID: call.callID, success: true, content: slice, toolName: "context_recall")
        let request = ModelRequest(model: ModelID("replay"), messages: [
            .init(role: .assistant, parts: [.toolCall(call)]), .init(role: .tool, parts: [.toolResult(result)])])
        for wire in try PEContextIntegrityTests().wires(request) {
            #expect(wire.contains(marker))
            #expect(!wire.contains("characters truncated"))
        }
    }

    @Test func recalledOccurrenceRemainsExactAcrossNextAssemblyAndProjection() async throws {
        let sid = SessionID("success"), fabric = PEContextIntegrityTests().store(), compactor = ContextCompactor(ecoreStore: fabric)
        let call = ToolCall(callID: ToolCallID("large"), toolID: ToolID("shell"), arguments: "{}")
        let raw = ToolResult(callID: call.callID, success: true, content: payload, toolName: "shell")
        let a = Message(id: MessageID("a"), role: .assistant, parts: [.toolCall(call)], createdAt: .now)
        let r = Message(id: MessageID("r"), role: .tool, parts: [.toolResult(raw)], createdAt: .now)
        var session = Session(id: sid, createdAt: .now, messages: [a,r])
        let batch = ToolExchangeBatch(batchID: "raw-batch", sessionID: sid, assistantMessageID: a.id,
            resultMessageID: r.id, toolCalls: [call], toolResults: [raw], providerStep: 1, state: .consumed, estimatedTokens: 15000)
        let canonical = await PCoreContextEngine().entries(for: session)
        _ = try await compactor.compact(sessionID: sid, entries: canonical, budget: PEContextIntegrityTests().budget, batches: [batch], trigger: .manual)
        let ref = try #require(await fabric.references(sessionID: sid).first)
        _ = try await ContextRecallTool(ecoreStore: fabric, sessionID: sid).execute(arguments: "{\"id\":\"\(ref.referenceID)\",\"offset\":15000}", profile: .workspace)
        let admitted = await compactor.admitRequestedRecalls(sessionID: sid, canonicalEntries: canonical, activeEntries: [], hardInputLimit: 65536)
        #expect(admitted.contains { $0.part == .toolResult(raw) && $0.segment == .recalledOccurrence })
        // Enough later assistants to exercise placeholder eligibility on the next assembly.
        session = Session(id: sid, createdAt: session.createdAt, messages: session.messages + (0..<10).map { Message(id: MessageID("later-\($0)"), role: .assistant, content: "continue", createdAt: .now) })
        let next = await compactor.activeEntries(sessionID: sid, canonicalEntries: await PCoreContextEngine().entries(for: session))
        #expect(next.contains { $0.messageID == r.id && $0.segment == .recalledOccurrence })
        let projected = await ContextProjection().project(entries: next, session: session, ecoreStore: fabric)
        #expect(projected.contains { $0.part == .toolResult(raw) && $0.segment == .recalledOccurrence })
        let request = ModelRequest(model: ModelID("replay"), messages: await PCoreContextEngine().snapshot(for: session, activeEntries: projected).modelMessages())
        for wire in try PEContextIntegrityTests().wires(request) { #expect(wire.contains(marker)) }
        #expect(await fabric.lifecycleSnapshot(sessionID: sid).recallAdmitted == 1)
        print("SUCCESS_RECALL_NEXT_STEP originalChars=\(payload.count) admittedMarker=\(projected.contains { ContextCompactor.content(of: $0.part).contains(marker) }) providers=3")
    }

    @Test func realSessionReadAfterShellMutationReturnsFreshContent() async throws {
        try await replayReads(mutate: true, pageOutRead: false)
    }

    @Test func realSessionReadOfECoreOnlyResultReturnsPayloadInsteadOfReminder() async throws {
        try await replayReads(mutate: false, pageOutRead: true)
    }

    private func replayReads(mutate: Bool, pageOutRead: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "OLD".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let provider = ReadContractReplayProvider(root: root, mutate: mutate)
        let host = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: .init(provider: provider, modelID: ModelID("replay"), contextProfile: .init(contextWindowTokens: 65536)),
            workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: root.appendingPathComponent("core"), permissionDecision: .allow)
        await host.start()
        defer { await host.shutdown() }
        provider.host = pageOutRead ? host : nil
        let client = LingXiClient.inProcess(endpoint: host)
        let sid = try await client.createSession()
        provider.sessionID = sid
        for try await _ in try await client.sendMessage(sessionID: sid, content: "Inspect note.txt and verify its current contents") {}
        let durable = try await host.sessionStore.session(sid)
        let last = try #require(durable.messages.flatMap(\.parts).compactMap { if case let .toolResult(r) = $0 { r } else { nil } }.last)
        #expect(last.success)
        #expect(last.content == (mutate ? "NEW" : "OLD"))
        #expect(!last.content.contains("already present"))
        if pageOutRead { #expect(await host.ecoreStoreRef.references(sessionID: sid).count > 0) }
        print("READ_CONTRACT mutation=\(mutate) pageOut=\(pageOutRead) returned=\(last.content)")
    }
}

private final class ReadContractReplayProvider: ModelProvider, @unchecked Sendable {
    let root: URL
    let mutate: Bool
    var host: CoreHost?
    var sessionID: SessionID?
    let recorder = RequestRecorder()
    init(root: URL, mutate: Bool) { self.root = root; self.mutate = mutate }
    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        recorder.record(request)
        let step = recorder.requests.count
        if let host, step == 2 {
            let sid = try #require(sessionID)
            let session = try await host.sessionStore.session(sid)
            let toolMessage = try #require(session.messages.first { $0.role == .tool })
            let ref = await host.ecoreStoreRef.pageOut(sessionID: sid, content: "OLD", origin: .toolCall,
                contextOccurrenceID: toolMessage.id.rawValue, evictionEpoch: 0, summary: "old read")
            let assistant = try #require(session.messages.first { $0.role == .assistant })
            let ids = Set([assistant.id, toolMessage.id])
            let old = await host.compactor.unitStates(sessionID: sid)
            await host.compactor.restoreResidencies(sessionID: sid, values: old.filter { !ids.contains($0.messageID) } + ids.map {
                .init(messageID: $0, residency: .derived, derivedPageID: ref.referenceID) })
        }
        let events: [ModelEvent]
        if step <= 3 {
            let call: ToolCall
            if step == 2 && mutate {
                let args = try JSONSerialization.data(withJSONObject: ["command": "printf NEW > '\(root.path)/note.txt'"])
                call = .init(callID: ToolCallID("mutate"), toolID: ToolID("shell"), arguments: String(decoding: args, as: UTF8.self))
            } else { call = .init(callID: ToolCallID("read-\(step)"), toolID: ToolID("read_file"), arguments: "{\"path\":\"note.txt\"}") }
            events = [.toolCallCompleted(call), .completed(.toolCalls)]
        } else { events = [.textDelta("Read verified"), .completed(.stop)] }
        return AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }
}
