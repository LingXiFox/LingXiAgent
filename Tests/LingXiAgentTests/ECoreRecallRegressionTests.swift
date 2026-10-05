import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

@Suite(.serialized) struct ECoreRecallRegressionTests {
    @Test func failedOccurrenceSurvivesAdmissionIndexAndEveryProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: .init(provider: ObservatoryFakeProvider(), modelID: ModelID("replay"), contextProfile: .init(contextWindowTokens: 65536)),
            workspaceRoot: WorkspaceRoot(path: root.path), dataRoot: root.appendingPathComponent("core"), permissionDecision: .allow)
        await host.start()
        defer { await host.shutdown() }
        let sid = try await host.sessionStore.create().id
        let raw = try PEContextIntegrityTests().failedResult()
        let call = ToolCall(callID: raw.callID, toolID: ToolID("shell"), arguments: "{}")
        let a = try await host.sessionStore.appendMessage(sid, role: .assistant, parts: [.toolCall(call)])
        let r = try await host.sessionStore.appendMessage(sid, role: .tool, parts: [.toolResult(raw)])
        let session = try await host.sessionStore.session(sid)
        let canonical = await PCoreContextEngine().entries(for: session)
        let fabric = await host.ecoreStoreRef
        let compactor = await host.compactor
        let batch = ToolExchangeBatch(batchID: "failed", sessionID: sid, assistantMessageID: a.id,
            resultMessageID: r.id, toolCalls: [call], toolResults: [raw], providerStep: 1, state: .consumed, estimatedTokens: 15000)
        _ = try await compactor.compact(sessionID: sid, entries: canonical, budget: PEContextIntegrityTests().budget, batches: [batch], trigger: .manual)
        let ref = try #require(await fabric.references(sessionID: sid).first)
        let recall = ContextRecallTool(ecoreStore: fabric, sessionID: sid)
        let ack = try await recall.execute(arguments: "{\"id\":\"\(ref.referenceID)\",\"admission\":\"occurrence\"}", profile: .workspace)
        #expect(ack.contains("pending") && !ack.contains("Payload: granted"))
        let active = await compactor.activeEntries(sessionID: sid, canonicalEntries: canonical)
        let admitted = await compactor.admitRequestedRecalls(sessionID: sid, canonicalEntries: canonical, activeEntries: active, hardInputLimit: 65536)
        let indexed = await compactor.projectIndex(sessionID: sid, entries: admitted, hardInputLimit: 65536, query: "test select")
        #expect(!indexed.filter { $0.segment == .eCoreRetrievalProjection }.contains { ContextCompactor.content(of: $0.part).contains(ref.referenceID) })
        let projection = await ContextProjection().project(entries: indexed, session: session, ecoreStore: fabric)
        let request = ModelRequest(model: ModelID("replay"), messages: await PCoreContextEngine().snapshot(for: session, activeEntries: projection).modelMessages())
        let projected = ModelToolResultProjection.project(raw, segment: .recalledOccurrence)
        #expect(projected.content.contains(raw.content))
        #expect(projected.content.contains("exitCode"))
        for body in [try OpenAICompatibleProvider.makeRequestBody(request), try OpenAIResponsesProvider.makeRequestBody(request), try AnthropicMessagesProvider.makeRequestBody(request)] {
            // Compare decoded string values, rather than JSON escaping or a single diagnostic marker.
            let json = try JSONSerialization.jsonObject(with: body)
            #expect(Self.strings(json).contains { $0.contains(raw.content) })
        }
        await compactor.noteProviderVisibleRecalls(sessionID: sid, activeEntries: projection, request: request)
        #expect(await fabric.lifecycleSnapshot(sessionID: sid).recallProviderVisible == 1)
        let next = await compactor.activeEntries(sessionID: sid, canonicalEntries: canonical)
        #expect(next.contains { $0.messageID == r.id && $0.segment == .recalledOccurrence })
        #expect(try await host.sessionStore.session(sid).messages.count == 2)
        let snapshot = await host.contextStateSnapshot(sessionID: sid)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        #expect(json["modelWindowTokens"] as? Int == 65536)
        #expect(try JSONDecoder().decode(ContextStateSnapshot.self, from: JSONEncoder().encode(snapshot)).modelWindowTokens == 65536)
    }

    @Test func lookupFailuresAreFailuresAndRetainRecoveryInformation() async throws {
        let fabric = PEContextIntegrityTests().store(), sid = SessionID("lookup")
        let ref = await fabric.pageOut(sessionID: sid, content: "payload", origin: .message, contextOccurrenceID: "old", evictionEpoch: 0, summary: "available")
        let runtime = ToolRuntime(registry: ToolRegistry([ContextRecallTool(ecoreStore: fabric, sessionID: sid)]), permissions: PermissionEngine(defaultDecision: .allow))
        for id in ["ref_missing", "obj_missing", "../invalid"] {
            let result = await runtime.execute(ToolCall(callID: ToolCallID(id), toolID: ToolID("context_recall"), arguments: "{\"id\":\"\(id)\"}"), sessionID: sid)
            #expect(!result.success && result.outcome != .success)
            #expect(result.error != nil)
            #expect((result.error?.message ?? "").contains(ref.referenceID))
        }
        let wrong = await runtime.execute(ToolCall(callID: ToolCallID("wrong"), toolID: ToolID("context_recall"), arguments: "{\"id\":\"\(ref.referenceID)\",\"session_id\":\"wrong-session\"}"), sessionID: sid)
        #expect(!wrong.success && (wrong.error?.message ?? "").contains("not found"))
        #expect(try await fabric.restore(sessionID: sid, referenceID: ref.referenceID) == "payload")
    }

    @Test func rejectedAdmissionIsReportedWithinIndexBudget() async throws {
        let fabric = PEContextIntegrityTests().store(), sid = SessionID("rejection"), compactor = ContextCompactor(ecoreStore: fabric)
        let ref = await fabric.pageOut(sessionID: sid, content: String(repeating: "payload ", count: 1000), origin: .message, contextOccurrenceID: "old", evictionEpoch: 0, summary: "large")
        let ack = try await ContextRecallTool(ecoreStore: fabric, sessionID: sid).execute(arguments: "{\"id\":\"\(ref.referenceID)\",\"admission\":\"occurrence\"}", profile: .workspace)
        #expect(ack.contains("pending") && !ack.contains("Payload: granted"))
        let admitted = await compactor.admitRequestedRecalls(sessionID: sid, canonicalEntries: [], activeEntries: [], hardInputLimit: 1)
        #expect(admitted.isEmpty)
        let indexed = await compactor.projectIndex(sessionID: sid, entries: [], hardInputLimit: 65536, query: "large")
        let text = indexed.map { ContextCompactor.content(of: $0.part) }.joined()
        #expect(text.contains("rejected") && text.contains("insufficientProjectionBudget"))
        #expect(ConservativeTokenEstimator().estimate(entries: indexed) <= ContextCompactor.eCoreIndexTokenAllowance(hardInputLimit: 65536))
    }

    @Test func persistedDebugOnRecordsWarningsImmediately() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = DebugModeStore(layout: CoreStorageLayout(root: root)).save(enabled: true)
        let host = try CoreHost(startupPolicy: .unitTest, providerAssembly: .init(provider: ObservatoryFakeProvider(), modelID: ModelID("replay")),
            workspaceRoot: WorkspaceRoot(path: root.path), dataRoot: root, permissionDecision: .allow)
        await host.start()
        defer { await host.shutdown() }
        let hub = try #require(await host.debugHub)
        let recorder = DebugRunRecorder(directory: root.appendingPathComponent("archive"))
        #expect(await recorder.start(runName: "startup-warning", manifest: nil))
        hub.setRecorder(recorder, runName: "startup-warning")
        await host.diagnosticsStoreForDebug.record(kind: .agentRun, event: "agent.loop.soft_warning", sessionID: SessionID("debug"))
        #expect(hub.status().eventsBuffered == 1)
        await hub.detachRecorder()
        let jsonl = try String(contentsOf: root.appendingPathComponent("archive/telemetry.jsonl"), encoding: .utf8)
        #expect(jsonl.contains("agent.loop.soft_warning"))
        #expect(hub.status().archiveWriteFailures == 0)
    }

    @Test func partialOccurrenceStaysDiscoverableWithHonestResidency() async throws {
        let fabric = PEContextIntegrityTests().store(), sid = SessionID("partial"), compactor = ContextCompactor(ecoreStore: fabric)
        let payload = String(repeating: "middle payload ", count: 1000)
        let ref = await fabric.pageOut(sessionID: sid, content: payload, origin: .message, contextOccurrenceID: "old", evictionEpoch: 0, summary: "partial")
        _ = try await ContextRecallTool(ecoreStore: fabric, sessionID: sid).execute(arguments: "{\"id\":\"\(ref.referenceID)\",\"admission\":\"occurrence\",\"limit_bytes\":1024}", profile: .workspace)
        let active = await compactor.admitRequestedRecalls(sessionID: sid, canonicalEntries: [], activeEntries: [], hardInputLimit: 2200)
        #expect(!active.isEmpty)
        let indexed = await compactor.projectIndex(sessionID: sid, entries: active, hardInputLimit: 2200, query: "partial")
        let index = indexed.filter { $0.segment == .eCoreRetrievalProjection }
        let text = index.map { ContextCompactor.content(of: $0.part) }.joined()
        #expect(text.contains(ref.referenceID) && text.contains("state=activeSlice"))
        #expect(!text.contains("以下内容已移出当前上下文"))
        #expect(try await fabric.restore(sessionID: sid, referenceID: ref.referenceID) == payload)
        #expect(ConservativeTokenEstimator().estimate(entries: indexed) <= 2200)
    }

    @Test func visibilityDoesNotCertifyResultsThatEncodingSummarizes() async throws {
        let fabric = PEContextIntegrityTests().store(), sid = SessionID("visibility"), compactor = ContextCompactor(ecoreStore: fabric)
        let raw = try PEContextIntegrityTests().failedResult()
        let ref = await fabric.pageOut(sessionID: sid, content: raw.content, origin: .toolCall, contextOccurrenceID: "old", evictionEpoch: 0, summary: "failure")
        let entry = ContextEntry(messageID: MessageID(ref.referenceID), role: .tool, source: .toolResult, part: .toolResult(raw), segment: .recalledOccurrence)
        let request = ModelRequest(model: ModelID("replay"), messages: [.init(role: .tool, parts: [.toolResult(raw)])])
        await compactor.noteProviderVisibleRecalls(sessionID: sid, activeEntries: [entry], request: request)
        #expect(await fabric.lifecycleSnapshot(sessionID: sid).recallProviderVisible == 0)
    }

    private static func strings(_ value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.flatMap(strings) }
        if let dictionary = value as? [String: Any] { return dictionary.values.flatMap(strings) }
        return []
    }
}
