import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

@Suite(.serialized) struct PEContextIntegrityTests {
    func failedResult() throws -> ToolResult {
        let url = try #require(Bundle.module.url(forResource: "T011-failed-tool", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(ToolResult.self, from: Data(contentsOf: url))
    }
    func store(_ root: URL? = nil) -> ECoreObjectStore {
        ECoreObjectStore(baseDirectory: root, configuration: ContextObjectFabricConfiguration(eCorePersistenceEnabled: root != nil, heatTrackingEnabled: false))
    }
    var budget: ContextBudget { .init(hardInputLimit: 2000, preferredActiveTokens: 100, highWaterTokens: 100, lowWaterTokens: 80, reservedOutputTokens: 0, protocolOverheadTokens: 0, toolSchemaTokens: 0, safetyMarginTokens: 0) }
    func wires(_ request: ModelRequest) throws -> [String] {
        try [OpenAICompatibleProvider.makeRequestBody(request), OpenAIResponsesProvider.makeRequestBody(request), AnthropicMessagesProvider.makeRequestBody(request)].map { String(decoding: $0, as: UTF8.self) }
    }
    func evidence(_ name: String, data: Data) throws {
        guard let path = ProcessInfo.processInfo.environment["LINGXI_PE_INTEGRITY_EVIDENCE"] else { return }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(name), options: .atomic)
    }

    @Test func coldProjectionRepairsLegacyRevertBaselineWithoutModelExecution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFakeProvider(script: [])
        let host = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: .init(provider: provider, modelID: ModelID("replay"), contextProfile: .init(contextWindowTokens: 65536)),
            workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: root.appendingPathComponent("core"), permissionDecision: .allow)
        await host.start()
        defer { await host.shutdown() }
        let sid = try await host.sessionStore.create().id
        _ = try await host.sessionStore.appendMessage(sid, role: .user, content: "Old durable task")
        let old = try await host.sessionStore.appendMessage(sid, role: .assistant,
            content: String(repeating: "Historical context retained on disk. ", count: 14000))
        _ = try await host.sessionStore.appendMessage(sid, role: .user, content: "Continue the same task")
        let fabric = await host.ecoreStoreRef
        let dir = await fabric.baseDirectory.appendingPathComponent(sid.rawValue)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["cachedTokens": 0, "promptTokens": 231000,
            "previousPromptTokens": 231000, "status": "coldNewEpoch", "epoch": 2, "epochReason": "revert_turn"])
            .write(to: dir.appendingPathComponent("telemetry.json"))
        let projection = try #require(try await LingXiClient.inProcess(endpoint: host).contextProjection(sid))
        #expect(projection.pCore.usedTokens < 65536)
        let residentTokens = await host.cacheController.pCoreResidentTokens(for: sid)
        #expect(projection.pCore.usedTokens == residentTokens)
        #expect(await host.cacheController.lastProviderCacheRecord(for: sid) == nil)
        #expect(await host.cacheController.lastProviderInputTokens(for: sid) == nil)
        #expect(provider.recorder.requests.isEmpty)
        #expect(try await host.sessionStore.session(sid).messages.contains { $0.id == old.id && $0.content == old.content })
        let firstStates = await host.compactor.unitStates(sessionID: sid)
        let firstRefs = await fabric.references(sessionID: sid)
        _ = try await LingXiClient.inProcess(endpoint: host).contextProjection(sid)
        #expect(await host.compactor.unitStates(sessionID: sid) == firstStates)
        #expect(await fabric.references(sessionID: sid) == firstRefs)
        print("COLD_REVERT_REPAIR legacyTokens=231000 activeTokens=\(projection.pCore.usedTokens) requests=\(provider.recorder.requests.count)")
    }

    @Test func revertPreservesPagedOutHistoryAndReportsOnlyResidentContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: .init(provider: ObservatoryFakeProvider(), modelID: ModelID("replay"), contextProfile: .init(contextWindowTokens: 65536)),
            workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: root.appendingPathComponent("core"), permissionDecision: .allow)
        await host.start()
        defer { await host.shutdown() }
        let sid = try await host.sessionStore.create().id
        let user = try await host.sessionStore.appendMessage(sid, role: .user, content: "Keep this task")
        let old = try await host.sessionStore.appendMessage(sid, role: .assistant,
            content: String(repeating: "Historical failure evidence must remain durable. ", count: 14000))
        _ = try await host.sessionStore.appendMessage(sid, role: .user, content: "Revert this turn")
        let removed = try await host.sessionStore.appendMessage(sid, role: .assistant, content: "Reverted answer")
        let fabric = await host.ecoreStoreRef
        let ref = await fabric.pageOut(sessionID: sid, content: old.content, origin: .message,
            contextOccurrenceID: old.id.rawValue, evictionEpoch: 1, summary: "historical failure evidence")
        let states = [ContextUnitDebugSnapshot(messageID: user.id, residency: .active),
            ContextUnitDebugSnapshot(messageID: old.id, residency: .derived, derivedPageID: ref.referenceID),
            ContextUnitDebugSnapshot(messageID: removed.id, residency: .active)]
        await host.compactor.restoreResidencies(sessionID: sid, values: states)
        let persistence = try #require(await host.persistence)
        try await persistence.saveCompaction(sessionID: sid, generation: 7, residencies: states)
        let receipt = try await host.revertLastTurn(envelope: .init(payload: .init(sessionID: sid)))
        let snapshot = try #require(receipt.result?.snapshot)
        let durable = try await host.sessionStore.session(sid)
        #expect(durable.messages.map(\.id) == [user.id, old.id])
        #expect(durable.messages.last?.content == old.content)
        let tokens = try #require(snapshot.contextState.pCore?.usedTokens)
        #expect(tokens < 65536, "Durable history is not active provider input")
        let residentTokens = await host.cacheController.pCoreResidentTokens(for: sid)
        let targetTokens = await host.effectiveContextPolicy.pCoreTarget
        #expect(tokens == residentTokens)
        #expect(tokens < targetTokens)
        #expect(await host.compactor.unitStates(sessionID: sid).first { $0.messageID == old.id }?.residency == .derived)
        #expect(await host.compactor.unitStates(sessionID: sid).allSatisfy { $0.messageID != removed.id })
        #expect(try await fabric.restore(sessionID: sid, referenceID: ref.referenceID) == old.content)
        #expect(await host.cacheController.lastProviderInputTokens(for: sid) == nil)
        #expect(await host.cacheController.lastProviderCacheRecord(for: sid) == nil)
        let persisted = try #require(try await persistence.compaction(sessionID: sid))
        #expect(persisted.generation == 7)
        #expect(persisted.residencies.first { $0.messageID == old.id }?.residency == .derived)
        let reopened = ContextCompactor(ecoreStore: fabric)
        await reopened.restoreResidencies(sessionID: sid, values: persisted.residencies)
        let entries = await PCoreContextEngine().entries(for: durable)
        let active = await reopened.activeEntries(sessionID: sid, canonicalEntries: entries)
        #expect(!active.contains { $0.messageID == old.id })
        print("REVERT_RESIDENCY durableTokens=\(ConservativeTokenEstimator().estimate(entries: entries)) activeTokens=\(tokens) survivingObjects=\(await fabric.storageMetrics(for: sid).count)")
    }

    @Test func failureEvidenceSurvivesRealT011WireEncoding() throws {
        let failure = try failedResult()
        #expect(failure.content.count == 9864)
        let call = ToolCall(callID: failure.callID, toolID: ToolID("shell"), arguments: "{}")
        let request = ModelRequest(model: ModelID("replay"), messages: [.init(role: .assistant, parts: [.toolCall(call)]), .init(role: .tool, parts: [.toolResult(failure)])])
        for wire in try wires(request) {
            #expect(wire.contains("NameError: name 'select' is not defined"))
            #expect(wire.contains("test_select_preserves_order"))
            #expect(wire.contains("exitCode"))
            #expect(wire.contains("test_baseline.py"))
            #expect(wire.contains("line 198"))
        }
        try evidence("T011-failure-projection.json", data: Data(ModelToolResultProjection.project(failure).content.utf8))
    }

    @Test func failureEvidenceSurvivesPreProjectionAndRepeatedEncodingWithoutStreams() throws {
        let real = try failedResult()
        let withoutStreams = ToolResult(callID: real.callID, success: false, content: real.content, error: real.error, toolName: "shell", exitCode: real.exitCode)
        let normalized = ModelToolResultProjection.projectToolResult(withoutStreams)
        #expect(normalized.content.count < 5000)
        #expect(normalized.content.contains("NameError"))
        let twice = ModelToolResultProjection.projectToolResult(normalized)
        #expect(twice.content.contains("NameError"))
        let call = ToolCall(callID: real.callID, toolID: ToolID("shell"), arguments: "{}")
        for wire in try wires(ModelRequest(model: ModelID("replay"), messages: [.init(role: .assistant, parts: [.toolCall(call)]), .init(role: .tool, parts: [.toolResult(twice)])])) {
            #expect(wire.contains("NameError: name 'select' is not defined"))
            #expect(wire.contains("line 198"))
        }
    }

    @Test func eCoreIndexSurvivesAllProvidersWithCachePlan() async throws {
        let sid = SessionID("index-parity"), fabric = store()
        let ref = await fabric.pageOut(sessionID: sid, content: "archived failure", origin: .message, contextOccurrenceID: "old", evictionEpoch: 0, summary: "failure")
        let compactor = ContextCompactor(ecoreStore: fabric)
        let old = ContextEntry(messageID: MessageID("old"), role: .assistant, source: .assistantMessage, part: .text(String(repeating: "failure ", count: 100)))
        let current = ContextEntry(messageID: MessageID("current"), role: .user, source: .userMessage, part: .text("repair failure"))
        let compacted = try await compactor.compact(sessionID: sid, entries: [old,current], budget: budget, trigger: .manual)
        let context = await PCoreContextEngine().snapshot(for: Session(id: sid, createdAt: .now), activeEntries: compacted.entries)
        let messages = context.modelMessages()
        let plan = CanonicalCachePlan(epochIdentity: .init(epoch: 1), immutableBase: .init(systemPrompt: "Stable instructions"), appendOnlyContext: .init(messages: messages), structuralHealth: .init(stablePrefixHash: "fixed"))
        for wire in try wires(ModelRequest(model: ModelID("replay"), system: "Stable instructions", messages: messages, cachePlan: plan)) {
            #expect(wire.contains(ref.referenceID))
        }
    }

    @Test func recallRefRoundTripsThroughPublicTool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sid = SessionID("reference"), fabric = store(root)
        let payload = "NameError: retained payload"
        let ref = await fabric.pageOut(sessionID: sid, content: payload, origin: .toolCall, contextOccurrenceID: "batch", evictionEpoch: 0, summary: "failure")
        let restarted = store(root)
        let output = try await ContextRecallTool(ecoreStore: restarted, sessionID: sid).execute(arguments: "{\"id\":\"\(ref.referenceID)\"}", profile: .workspace)
        #expect(output.contains(payload))
    }

    @Test func responsesRemoteContinuationCannotDiscardOrDuplicateECoreSegments() throws {
        let call = ToolCall(callID: ToolCallID("tail-call"), toolID: ToolID("context_recall"), arguments: "{}")
        let messages: [ModelMessage] = [.init(role: .system, content: "Previously restored evidence: NameError"), .init(role: .assistant, parts: [.toolCall(call)]), .init(role: .tool, parts: [.toolResult(.init(callID: call.callID, success: true, content: "slice", toolName: "context_recall"))]), .init(role: .system, content: "reference=ref_remote", segment: .eCoreRetrievalProjection)]
        let provider = OpenAIResponsesProvider(config: ProviderConfig(baseURL: URL(string: "https://example.invalid/v1")!, apiKey: nil, model: "replay", wireProtocol: .responses, remoteStateEnabled: true))
        let body = try #require(provider.makeURLRequest(ModelRequest(model: ModelID("replay"), messages: messages), previousResponseID: "response-before-pageout").httpBody)
        let wire = String(decoding: body, as: UTF8.self)
        #expect(wire.components(separatedBy: "reference=ref_remote").count == 2)
        #expect(wire.contains("NameError"))
        #expect(!wire.contains("previous_response_id"))
    }

    @Test func residencyPreventsRepeatedCanonicalPageOut() async throws {
        let sid = SessionID("repageout"), fabric = store(), engine = PCoreContextEngine()
        let compactor = ContextCompactor(ecoreStore: fabric)
        let old = Message(id: MessageID("old"), role: .assistant, content: String(repeating: "historical evidence ", count: 100), createdAt: .now)
        let session = Session(id: sid, createdAt: .now, messages: [old, Message(id: MessageID("current"), role: .user, content: "repair", createdAt: .now)])
        for step in 0..<8 {
            _ = try await compactor.compact(sessionID: sid, entries: await engine.entries(for: session), budget: budget, trigger: .manual, evictionEpoch: step)
        }
        #expect(await fabric.references(sessionID: sid).count == 1)
        #expect(session.messages.count == 2)
        let telemetry = await fabric.lifecycleSnapshot(sessionID: sid)
        #expect(telemetry.pageOutAttempt == 1 && telemetry.pageOutNew == 1)
        print("PE_RESIDENCY N=8 attempts=\(telemetry.pageOutAttempt) new=\(telemetry.pageOutNew) canonicalMessages=2")
    }

    @Test func structuredFailureSurvivesToolBatchArchive() async throws {
        let sid = SessionID("structured-failure"), fabric = store()
        let realCompactor = ContextCompactor(ecoreStore: fabric)
        let call = ToolCall(callID: ToolCallID("failure"), toolID: ToolID("shell"), arguments: String(repeating: "x", count: 1200))
        let failure = ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: "commandFailed", message: "AUDIT_EXCEPTION_EVIDENCE"), toolName: "shell", exitCode: 1)
        let batch = ToolExchangeBatch(batchID: "batch", sessionID: sid, assistantMessageID: MessageID("a"), resultMessageID: MessageID("r"), toolCalls: [call], toolResults: [failure], providerStep: 1, state: .consumed, estimatedTokens: 500)
        let entries = [ContextEntry(messageID: MessageID("a"),role: .assistant,source: .toolCall,part: .toolCall(call)),ContextEntry(messageID: MessageID("r"),role: .tool,source: .toolResult,part: .toolResult(failure)),ContextEntry(messageID: MessageID("u"),role: .user,source: .userMessage,part: .text("repair"))]
        _ = try await realCompactor.compact(sessionID: sid, entries: entries, budget: budget, batches: [batch], trigger: .manual)
        let ref = try #require(await fabric.references(sessionID: sid).first)
        let payload = try #require(try await fabric.restore(sessionID: sid, referenceID: ref.referenceID))
        #expect(payload.contains("AUDIT_EXCEPTION_EVIDENCE"))
        #expect(payload.contains("commandFailed"))
        #expect(payload.contains("exitCode"))
    }

    @Test func pageOutRetryIsDeduplicatedAndFailureMemoryFallbackIsRecallable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("I/O obstruction".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let fabric = store(root), sid = SessionID("fail-open")
        let first = await fabric.pageOut(sessionID: sid, content: "preserved failure", origin: .message, contextOccurrenceID: "old", evictionEpoch: 0, summary: "failure")
        let second = await fabric.pageOut(sessionID: sid, content: "preserved failure", origin: .message, contextOccurrenceID: "old", evictionEpoch: 0, summary: "failure")
        #expect(first == second)
        #expect(try await fabric.restore(sessionID: sid, referenceID: first.referenceID) == "preserved failure")
        let telemetry = await fabric.lifecycleSnapshot(sessionID: sid)
        #expect(telemetry.pageOutAttempt == 2 && telemetry.pageOutNew == 1 && telemetry.pageOutDeduplicated == 1)
    }

    @Test func residencySurvivesRestartAndOnlyExplicitRecallReadmits() async throws {
        let fabric = store(), sid = SessionID("residency-restart"), first = ContextCompactor(ecoreStore: fabric)
        let old = ContextEntry(messageID: MessageID("old"), role: .assistant, source: .assistantMessage, part: .text(String(repeating: "archived ", count: 100)))
        let current = ContextEntry(messageID: MessageID("user"), role: .user, source: .userMessage, part: .text("current"))
        _ = try await first.compact(sessionID: sid, entries: [old,current], budget: budget, trigger: .manual)
        let states = await first.unitStates(sessionID: sid)
        let next = ContextCompactor(ecoreStore: fabric)
        await next.restoreResidencies(sessionID: sid, values: states)
        #expect(await next.activeEntries(sessionID: sid, canonicalEntries: [old,current]) == [current])
        let ref = try #require(await fabric.references(sessionID: sid).first)
        _ = try await ContextRecallTool(ecoreStore: fabric, sessionID: sid).execute(arguments: "{\"id\":\"\(ref.referenceID)\"}", profile: .workspace)
        let active = await next.admitRequestedRecalls(sessionID: sid, canonicalEntries: [old,current], activeEntries: [current], hardInputLimit: 2000)
        #expect(active.contains { $0.messageID == old.messageID && $0.part == old.part && $0.segment == .recalledOccurrence })
        #expect(await next.activeEntries(sessionID: sid, canonicalEntries: [old,current]).contains { $0.messageID == old.messageID && $0.part == old.part && $0.segment == .recalledOccurrence })
    }

    @Test func boundedIndexGrowthAndQueryChangesPreserveExactMapping() async throws {
        let fabric = store(), sid = SessionID("scale"), compactor = ContextCompactor(ecoreStore: fabric)
        let entries = [ContextEntry(messageID: MessageID("user"), role: .user, source: .userMessage, part: .text("search"))]
        var first: ECoreReference?, last: ECoreReference?, hidden: ECoreReference?
        var measurements: [Int: Int] = [:]
        for n in 0..<2000 {
            let topic = n == 0 ? "crimsonneedle" : (n == 1999 ? "silverneedle" : (n == 500 ? "emeraldneedle" : "unrelated-\(n)"))
            let ref = await fabric.pageOut(sessionID: sid, content: "\(topic) payload \(n)", origin: .message, contextOccurrenceID: "m\(n)", evictionEpoch: n, summary: topic)
            if n == 0 { first = ref }
            if n == 500 { hidden = ref }
            last = ref
            if [9,99,999,1999].contains(n) {
                let projected = await compactor.projectIndex(sessionID: sid, entries: entries, hardInputLimit: 65536, query: "crimsonneedle")
                let index = projected.filter { $0.segment == .eCoreRetrievalProjection }
                let tokens = ConservativeTokenEstimator().estimate(entries: index)
                measurements[n + 1] = tokens
                #expect(tokens <= 512)
                #expect(ConservativeTokenEstimator().estimate(entries: projected) <= 512 + ConservativeTokenEstimator().estimate(entries: entries))
                #expect(index.count == 1)
                #expect(ContextCompactor.content(of: index[0].part).contains(first!.referenceID))
            }
        }
        #expect(await fabric.storageMetrics(for: sid).count == 2000)
        let earlier = try #require(first), later = try #require(last)
        let previouslyHidden = try #require(hidden)
        let currentProjection = await compactor.projectIndex(sessionID: sid, entries: entries, hardInputLimit: 65536, query: "crimsonneedle")
        #expect(!currentProjection.contains { ContextCompactor.content(of: $0.part).contains(previouslyHidden.referenceID) })
        let hiddenProjection = await compactor.projectIndex(sessionID: sid, entries: entries, hardInputLimit: 65536, query: "emeraldneedle")
        #expect(hiddenProjection.contains { ContextCompactor.content(of: $0.part).contains(previouslyHidden.referenceID) })
        #expect(try await fabric.restore(sessionID: sid, referenceID: previouslyHidden.referenceID) == "emeraldneedle payload 500")
        let newProjection = await compactor.projectIndex(sessionID: sid, entries: entries, hardInputLimit: 65536, query: "silverneedle")
        #expect(newProjection.contains { ContextCompactor.content(of: $0.part).contains(later.referenceID) })
        #expect(try await fabric.restore(sessionID: sid, referenceID: earlier.referenceID) == "crimsonneedle payload 0")
        #expect(try await fabric.restore(sessionID: sid, referenceID: later.referenceID) == "silverneedle payload 1999")
        let tiny = await compactor.projectIndex(sessionID: sid, entries: [], hardInputLimit: 300, query: "crimsonneedle")
        #expect(ConservativeTokenEstimator().estimate(entries: tiny) <= ContextCompactor.eCoreIndexTokenAllowance(hardInputLimit: 300))
        print("PE_INDEX_SCALE tokens=\(measurements.sorted { $0.key < $1.key }) objects=2000 hard=512")
    }

    @Test func recallBudgetRejectionIsExplicitAndDoesNotReadmitHistory() async throws {
        let fabric = store(), sid = SessionID("reject"), compactor = ContextCompactor(ecoreStore: fabric)
        let ref = await fabric.pageOut(sessionID: sid, content: String(repeating: "payload ", count: 1000), origin: .message, contextOccurrenceID: "old", evictionEpoch: 0, summary: "large")
        let output = try await ContextRecallTool(ecoreStore: fabric, sessionID: sid).execute(arguments: "{\"id\":\"\(ref.referenceID)\"}", profile: .workspace)
        #expect(output.contains("payload"))
        let active = await compactor.admitRequestedRecalls(sessionID: sid, canonicalEntries: [], activeEntries: [], hardInputLimit: 100)
        #expect(active.isEmpty)
        let telemetry = await fabric.lifecycleSnapshot(sessionID: sid)
        #expect(telemetry.recallResolved == 1)
        #expect(telemetry.recallAdmitted == 0)
        #expect(telemetry.recallRejected == 1)
        #expect(telemetry.events.last?.reason?.contains("inputBudgetExceeded") == true)
    }

    @Test func realPersistentSessionRuntimeReplaysPToERecallActiveFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecallReplayProvider()
        let host = try CoreHost(providerAssembly: .init(provider: provider, modelID: ModelID("replay"), contextProfile: .init(contextWindowTokens: 65536)), workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: root.appendingPathComponent("core"), permissionDecision: .allow)
        await host.start()
        let client = LingXiClient.inProcess(endpoint: host)
        let sid = try await client.createSession()
        _ = try await host.debugModeUpdate(envelope: .init(payload: .init(action: .setEnabled, enabled: true)))
        let failure = try failedResult()
        let call = ToolCall(callID: failure.callID, toolID: ToolID("shell"), arguments: "{}")
        let a = try await host.sessionStore.appendMessage(sid, role: .assistant, parts: [.toolCall(call)])
        let r = try await host.sessionStore.appendMessage(sid, role: .tool, parts: [.toolResult(failure)])
        let batch = ToolExchangeBatch(batchID: "real-T011", sessionID: sid, assistantMessageID: a.id, resultMessageID: r.id, toolCalls: [call], toolResults: [failure], providerStep: 1, state: .consumed, estimatedTokens: 4000)
        let session = try await host.sessionStore.session(sid)
        let engine = PCoreContextEngine()
        let canonical = await engine.entries(for: session)
        _ = try await host.compactor.compact(sessionID: sid, entries: canonical, budget: budget, batches: [batch], trigger: .manual)
        let ref = try #require(await host.ecoreStoreRef.references(sessionID: sid).first)
        let stream = try await client.sendMessage(sessionID: sid, content: "Inspect historical test failure evidence")
        for try await _ in stream {}
        let requests = provider.recorder.requests
        #expect(requests.count == 2)
        #expect(requests[0].messages.contains { $0.segment == .eCoreRetrievalProjection && $0.content.contains(ref.referenceID) })
        #expect(requests[1].messages.contains { $0.segment == .recalledOccurrence })
        for wire in try wires(try #require(requests.last)) { #expect(wire.contains("NameError: name 'select' is not defined")) }
        for (index,request) in requests.enumerated() {
            for (providerIndex,wire) in try wires(request).enumerated() { try evidence("roundtrip-step\(index + 1)-provider\(providerIndex).json", data: Data(wire.utf8)) }
        }
        try evidence("roundtrip-durable-before.json", data: JSONEncoder().encode(session.messages.map(\.parts)))
        let restoredSession = try await client.session(sid)
        #expect(restoredSession.messages.contains { $0.id == a.id })
        #expect(restoredSession.messages.contains { $0.id == r.id && $0.parts.contains(.toolResult(failure)) })
        try evidence("roundtrip-durable-after.json", data: JSONEncoder().encode(restoredSession.messages))
        #expect(await host.compactor.unitStates(sessionID: sid).first { $0.messageID == r.id }?.residency == .active)
        let telemetry = await host.ecoreStoreRef.lifecycleSnapshot(sessionID: sid)
        #expect(telemetry.recallRequested == 1 && telemetry.recallResolved == 1 && telemetry.recallAdmitted == 1 && telemetry.recallRejected == 0)
        let events = try await host.debugEvents(envelope: .init(payload: .init(sessionID: sid)))
        let phases = events.payload.events.compactMap { $0.eCoreEvent?.lifecyclePhase }
        #expect(phases == ["pageOutAttempt", "pageOutNew", "recallRequested", "recallResolved", "recallAdmitted"])
        try evidence("roundtrip-telemetry.json", data: JSONEncoder().encode(events.payload))
        print("PE_REAL_ROUND_TRIP requests=\(requests.count) lifecycle=\(telemetry.events.map { $0.phase.rawValue }) failureEvidence=true durableMessages=\(restoredSession.messages.count)")
        await host.shutdown()
    }
}

/// Only model decisions are scripted; SessionStore, cache, disk E-Core, public
/// tool execution, Context Assembly and every wire encoder are production code.
private final class RecallReplayProvider: ModelProvider {
    let recorder = RequestRecorder()
    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        recorder.record(request)
        let events: [ModelEvent]
        if recorder.requests.count == 1 {
            let index = try #require(request.messages.first { $0.segment == .eCoreRetrievalProjection })
            let ref = try #require(index.content.components(separatedBy: "reference=").dropFirst().first?.split(whereSeparator: \.isWhitespace).first)
            let call = ToolCall(callID: ToolCallID("recall-T011"), toolID: ToolID("context_recall"), arguments: "{\"id\":\"\(ref)\"}")
            events = [.toolCallCompleted(call), .completed(.toolCalls)]
        } else { events = [.textDelta("Evidence restored"), .completed(.stop)] }
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }; continuation.finish()
        }
    }
}
