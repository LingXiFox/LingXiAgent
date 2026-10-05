import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

/// Phase 7.5 - a historical occurrence that does not fit is projected as a bounded range, and the
/// range is a durable fact rather than a per-assembly accident.
///
/// The invariant that makes this safe is the separation: the authoritative E-Core object is always
/// the complete payload, and `ref → authoritative object → full bytes` never changes. What a committed
/// admission records is which range of it is active in P-Core right now, so every later rebuild -
/// next turn, next assembly, next process - produces the same bounded projection instead of silently
/// re-expanding to full, and instead of the whole admission failing the way it used to.
private let tailMarker = "MIDDLE-MARKER-ZELDOX"

private func payload(_ bytes: Int, marker: String? = nil) -> String {
    guard let marker else { return String(repeating: "a", count: bytes) }
    let head = max(0, bytes / 2 - marker.utf8.count)
    return String(repeating: "h", count: head) + marker + String(repeating: "t", count: max(0, bytes - head - marker.utf8.count))
}

/// A multilingual payload: every 7-byte group carries a 3-byte CJK character and a 4-byte emoji.
private func utf8Payload(_ bytes: Int) -> String {
    var text = ""
    while text.utf8.count < bytes { text += "上下文🦊token " }
    return text
}

@Suite("Bounded occurrence projection", .serialized) struct BoundedOccurrenceProjectionTests {

    private func fabric(_ root: URL? = nil) -> ECoreObjectStore {
        guard let root else {
            return ECoreObjectStore(configuration: ContextObjectFabricConfiguration(eCorePersistenceEnabled: false))
        }
        return ECoreObjectStore(baseDirectory: root, configuration: ContextObjectFabricConfiguration())
    }

    private func workdir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lx-occ-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The occurrence projection the tool would have queued, with the caller's own range.
    private func requestRecall(_ store: ECoreObjectStore, _ sid: SessionID, _ referenceID: String,
                              offset: Int? = nil, limit: Int? = nil) async throws -> String {
        var arguments = "{\"id\":\"\(referenceID)\",\"admission\":\"occurrence\""
        if let offset { arguments += ",\"offset\":\(offset)" }
        if let limit { arguments += ",\"limit_bytes\":\(limit)" }
        return try await ContextRecallTool(ecoreStore: store, sessionID: sid)
            .execute(arguments: arguments + "}", profile: .workspace)
    }

    private func grant(_ store: ECoreObjectStore, _ compactor: ContextCompactor, _ sid: SessionID,
                       _ referenceID: String, hardInputLimit: Int,
                       offset: Int? = nil, limit: Int? = nil) async throws -> [ContextEntry] {
        _ = try await requestRecall(store, sid, referenceID, offset: offset, limit: limit)
        let entries = await compactor.admitRequestedRecalls(sessionID: sid, canonicalEntries: [], activeEntries: [], hardInputLimit: hardInputLimit)
        return entries
    }

    private func queue(_ store: ECoreObjectStore, _ sid: SessionID, _ referenceID: String) async -> RecallRequest? {
        await store.recallQueue(sessionID: sid).first { $0.referenceID == referenceID }
    }

    // MARK: - Case 1 / gate FULL_OCCURRENCE_WHEN_FITS_UNCHANGED

    @Test("an occurrence that fits is projected whole, exactly as before")
    func completeOccurrenceIsUnchanged() async throws {
        let sid = SessionID("fits")
        let store = fabric()
        let body = payload(8_000)
        let reference = await store.pageOut(sessionID: sid, content: body, origin: .toolCall,
            contextOccurrenceID: "occ-fits", evictionEpoch: 0, summary: "log", toolCallID: ToolCallID("c-1"), toolName: "shell")
        let entries = try await grant(store, ContextCompactor(ecoreStore: store), sid, reference.referenceID, hardInputLimit: 65_536)
        let content = ContextCompactor.content(of: try #require(entries.first).part)

        #expect(content == "[Restored session context]\n" + body, "a complete projection adds no label: \(content.prefix(120))")
        #expect(!content.contains("complete=false") && !content.contains("continuation_offset"))
        let committed = try #require(await queue(store, sid, reference.referenceID))
        #expect(committed.state == .admissionCommitted)
        #expect(committed.projection == nil || committed.projection?.isComplete == true,
            "no bounded range was resolved for something that fits: \(String(describing: committed.projection))")
    }

    // MARK: - Case 2 / gates LARGE_OCCURRENCE_BOUNDED_PROJECTION, BOUNDED_PROJECTION_USES_TOKEN_BUDGET,
    //              BOUNDED_PROJECTION_EXPLICITLY_MARKS_PARTIAL

    @Test("an occurrence too large for the window is admitted as a bounded, labelled projection")
    func largeOccurrenceIsBoundedAndLabelled() async throws {
        let sid = SessionID("large")
        let store = fabric()
        let body = payload(60_000, marker: tailMarker)
        let reference = await store.pageOut(sessionID: sid, content: body, origin: .toolCall,
            contextOccurrenceID: "occ-large", evictionEpoch: 0, summary: "big log", toolCallID: ToolCallID("c-2"), toolName: "shell")
        let hardInputLimit = 4_096
        let compactor = ContextCompactor(ecoreStore: store)
        let entries = try await grant(store, compactor, sid, reference.referenceID, hardInputLimit: hardInputLimit)
        let entry = try #require(entries.first)
        let content = ContextCompactor.content(of: entry.part)
        let committed = try #require(await queue(store, sid, reference.referenceID))
        let projection = try #require(committed.projection)

        // The admission succeeded where the whole payload would have been refused.
        #expect(committed.state == .admissionCommitted, "bounded projection must replace all-or-nothing")
        #expect(!content.contains(body), "the active context carries a range, not the object: \(content.utf8.count) of \(body.utf8.count) bytes")
        // Budget is measured with the estimator Core actually uses, not a bytes-per-token guess.
        let estimator = ConservativeTokenEstimator()
        #expect(estimator.estimate(entries: [entry]) <= hardInputLimit,
            "tokens=\(estimator.estimate(entries: [entry])) over hard=\(hardInputLimit)")
        // It is labelled, and the label is true.
        #expect(content.contains("complete=false") && content.contains("continuation_offset=\(projection.endBytes)"),
            "a partial occurrence may never look complete: \(content.prefix(200))")
        #expect(content.contains("bytes=\(projection.offsetBytes)-\(projection.endBytes)/\(projection.totalBytes)"))
        #expect(projection.totalBytes == body.utf8.count && !projection.isComplete)
        #expect(projection.offsetBytes == 0)
        // The bytes that were projected are exactly the payload's own prefix, so the projection is a
        // range of the authoritative object rather than a re-encoding of it.
        // The committed range must describe the emitted bytes exactly: same offset, same length, same
        // content, resolved again from the authoritative object.
        let emitted = content.components(separatedBy: "\n").dropFirst(2).joined(separator: "\n")
        #expect(emitted.utf8.count == projection.lengthBytes,
            "labelled \(projection.lengthBytes) bytes but emitted \(emitted.utf8.count): \(content.prefix(160))")
        #expect(Array(Array(body.utf8)[projection.offsetBytes..<projection.endBytes]) == Array(emitted.utf8),
            "the range is a slice of the authoritative payload, not a re-encoding of it")
        #expect(entry.segment == .recalledOccurrence, "still recalled data, never an instruction")
    }

    // MARK: - Case 3 / gate BOUNDED_PROJECTION_RESPECTS_REQUESTED_RANGE

    @Test("an explicit offset anchors the projection on the range the model asked for")
    func requestedRangeIsHonoured() async throws {
        let sid = SessionID("anchor")
        let store = fabric()
        let body = payload(60_000, marker: tailMarker)
        let reference = await store.pageOut(sessionID: sid, content: body, origin: .toolCall,
            contextOccurrenceID: "occ-anchor", evictionEpoch: 0, summary: "big log", toolCallID: ToolCallID("c-3"), toolName: "shell")
        let markerOffset = body.range(of: tailMarker).map { body.utf8.distance(from: body.startIndex, to: $0.lowerBound) } ?? 0
        #expect(markerOffset > 0)
        let compactor = ContextCompactor(ecoreStore: store)
        let entries = try await grant(store, compactor, sid, reference.referenceID, hardInputLimit: 4_096,
                                      offset: markerOffset, limit: 32_000)
        let content = ContextCompactor.content(of: try #require(entries.first).part)
        let projection = try #require((await queue(store, sid, reference.referenceID))?.projection)

        #expect(projection.offsetBytes <= markerOffset && projection.endBytes >= markerOffset + tailMarker.utf8.count,
            "the projection must contain what was asked for, not the payload's first bytes: \(projection)")
        #expect(content.contains(tailMarker), "the marker the model pointed at is in the active context")
        #expect(!content.contains(body))
    }

    // MARK: - Case 4 / gate BOUNDED_PROJECTION_DOES_NOT_REEXPAND_NEXT_TURN

    @Test("the next assembly re-projects the committed range instead of re-expanding to full")
    func committedRangeSurvivesTheNextAssembly() async throws {
        let root = try workdir("nextturn")
        defer { try? FileManager.default.removeItem(at: root) }
        let sid = SessionID("nextturn")
        let store = fabric(root)
        let body = payload(60_000, marker: tailMarker)
        let reference = await store.pageOut(sessionID: sid, content: body, origin: .toolCall,
            contextOccurrenceID: "occ-next", evictionEpoch: 0, summary: "log", toolCallID: ToolCallID("call-next"), toolName: "shell")
        let occurrence = ContextEntry(messageID: MessageID("m-next"), role: .tool, source: .toolResult,
            part: .toolResult(ToolResult(callID: ToolCallID("call-next"), success: true, content: String(body.prefix(60)),
                                         toolName: "shell", output: ToolOutputMetadata(truncated: true, artifactObjectID: reference.objectID.rawValue))))
        let compactor = ContextCompactor(ecoreStore: store)
        await compactor.restoreResidencies(sessionID: sid, values: [
            ContextUnitDebugSnapshot(messageID: MessageID("m-next"), residency: .derived, derivedPageID: reference.referenceID)
        ])
        _ = try await requestRecall(store, sid, reference.referenceID)
        let admitted = await compactor.admitRequestedRecalls(sessionID: sid, canonicalEntries: [occurrence],
                                                            activeEntries: [occurrence], hardInputLimit: 4_096)
        let projection = try #require((await queue(store, sid, reference.referenceID))?.projection)
        let committedContent = ContextCompactor.content(of: try #require(admitted.first { $0.messageID == MessageID("m-next") }).part)

        // Several later assemblies: the same range, never the full object.
        for turn in 0..<3 {
            let again = await compactor.activeEntries(sessionID: sid, canonicalEntries: [occurrence])
            let text = ContextCompactor.content(of: try #require(again.first { $0.messageID == MessageID("m-next") }).part)
            #expect(text == committedContent, "turn \(turn) re-expanded the projection")
            #expect(text.contains("complete=false") && text.contains("continuation_offset=\(projection.endBytes)"))
            #expect(!text.contains(body))
        }
    }

    // MARK: - Case 5 / gate BOUNDED_PROJECTION_SURVIVES_RESTART

    @Test("a restart restores the same bounded range, and the next request shows only it")
    func committedRangeSurvivesARestart() async throws {
        let root = try workdir("restart")
        defer { try? FileManager.default.removeItem(at: root) }
        let body = payload(60_000, marker: tailMarker)
        let provider = ScriptedFakeProvider(script: [[.textDelta("ok"), .completed(.stop)]])

        let first = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")),
            workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: root.appendingPathComponent("core"),
            permissionDecision: .allow, interactive: false)
        await first.start()
        let sid = try await first.sessionStore.create().id
        let store = await first.ecoreStoreRef
        let reference = await store.pageOut(sessionID: sid, content: body, origin: .toolCall,
            contextOccurrenceID: "occ-restart", evictionEpoch: 0, summary: "log", toolCallID: ToolCallID("call-restart"), toolName: "shell")
        let occurrence = ContextEntry(messageID: MessageID("m-restart"), role: .tool, source: .toolResult,
            part: .toolResult(ToolResult(callID: ToolCallID("call-restart"), success: true, content: String(body.prefix(60)),
                                         toolName: "shell", output: ToolOutputMetadata(truncated: true, artifactObjectID: reference.objectID.rawValue))))
        await first.compactor.restoreResidencies(sessionID: sid, values: [
            ContextUnitDebugSnapshot(messageID: MessageID("m-restart"), residency: .derived, derivedPageID: reference.referenceID)
        ])
        _ = try await requestRecall(store, sid, reference.referenceID)
        _ = await first.compactor.admitRequestedRecalls(sessionID: sid, canonicalEntries: [occurrence],
                                                        activeEntries: [occurrence], hardInputLimit: 4_096)
        let before = try #require((await queue(store, sid, reference.referenceID))?.projection)
        await first.shutdown()

        let reopened = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")),
            workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: root.appendingPathComponent("core"),
            permissionDecision: .allow, interactive: false)
        await reopened.start()
        defer { await reopened.shutdown() }
        let compactor = await reopened.compactor
        await compactor.restoreResidencies(sessionID: sid, values: [
            ContextUnitDebugSnapshot(messageID: MessageID("m-restart"), residency: .active, derivedPageID: reference.referenceID)
        ])
        await compactor.restoreRecallState(sessionID: sid)
        let restored = await compactor.activeEntries(sessionID: sid, canonicalEntries: [occurrence])
        let text = ContextCompactor.content(of: try #require(restored.first { $0.messageID == MessageID("m-restart") }).part)
        let after = try #require(await reopened.ecoreStoreRef.recallQueue(sessionID: sid).first { $0.referenceID == reference.referenceID }?.projection)

        #expect(after.offsetBytes == before.offsetBytes && after.lengthBytes == before.lengthBytes
                && after.totalBytes == before.totalBytes && after.isComplete == before.isComplete,
            "a restart must recover the same resolved range: \(before) → \(after)")
        #expect(text.contains("bytes=\(after.offsetBytes)-\(after.endBytes)/\(after.totalBytes) complete=false"))
        #expect(!text.contains(body), "no re-expansion after a restart")
    }

    // MARK: - Case 6

    @Test("the continuation offset reads the rest of the object and the ref round-trips")
    func continuationReadsTheRest() async throws {
        let sid = SessionID("continuation")
        let store = fabric()
        let body = payload(60_000, marker: tailMarker)
        let reference = await store.pageOut(sessionID: sid, content: body, origin: .toolCall,
            contextOccurrenceID: "occ-cont", evictionEpoch: 0, summary: "log", toolCallID: ToolCallID("c-6"), toolName: "shell")
        _ = try await grant(store, ContextCompactor(ecoreStore: store), sid, reference.referenceID, hardInputLimit: 4_096)
        let projection = try #require((await queue(store, sid, reference.referenceID))?.projection)
        let continuation = try #require(projection.continuationOffset)

        let slice = try await ContextRecallTool(ecoreStore: store, sessionID: sid).execute(
            arguments: "{\"id\":\"\(reference.referenceID)\",\"offset\":\(continuation),\"limit_bytes\":4096}", profile: .workspace)
        #expect(projection.endBytes < body.utf8.count, "the range must really be partial")
        let all = Array(body.utf8)
        let rest = String(decoding: all[projection.endBytes..<min(projection.endBytes + 64, all.count)], as: UTF8.self)
        #expect(slice.contains(rest), "continuation_offset must read on from where the projection stopped: \(slice.prefix(160))")
        #expect(try #require(await store.restore(sessionID: sid, referenceID: reference.referenceID)) == body,
            "the authoritative object is still the complete payload")
    }

    // MARK: - Case 7 / gate INSUFFICIENT_HEADROOM_REJECTS_CLEANLY

    @Test("a window too small for a meaningful projection is rejected with a named reason")
    func insufficientHeadroomRejectsCleanly() async throws {
        let sid = SessionID("tiny")
        let store = fabric()
        let body = payload(60_000, marker: tailMarker)
        let reference = await store.pageOut(sessionID: sid, content: body, origin: .toolCall,
            contextOccurrenceID: "occ-tiny", evictionEpoch: 0, summary: "log", toolCallID: ToolCallID("c-7"), toolName: "shell")
        let compactor = ContextCompactor(ecoreStore: store)
        _ = try await requestRecall(store, sid, reference.referenceID)
        let admitted = await compactor.admitRequestedRecalls(sessionID: sid, canonicalEntries: [], activeEntries: [], hardInputLimit: 120)
        let request = try #require(await queue(store, sid, reference.referenceID))

        #expect(admitted.isEmpty, "nothing may enter active context when no real projection fits")
        #expect(request.state == .rejected)
        #expect(request.reason?.contains("insufficientProjectionBudget") == true, "\(request.reason ?? "nil")")
        #expect(ContextCompactor.minimumOccurrenceProjectionTokens == 256, "the threshold is a named policy, not a scattered literal")
    }

    // MARK: - Case 8 / gate BOUNDED_PROJECTION_UTF8_SAFE

    @Test("a bounded projection of multilingual bytes is always valid UTF-8 inside its budget")
    func utf8BoundariesAreRespected() async throws {
        let sid = SessionID("utf8")
        let store = fabric()
        let body = utf8Payload(60_000)
        let reference = await store.pageOut(sessionID: sid, content: body, origin: .toolCall,
            contextOccurrenceID: "occ-utf8", evictionEpoch: 0, summary: "log", toolCallID: ToolCallID("c-8"), toolName: "shell")
        let hardInputLimit = 4_096
        let entries = try await grant(store, ContextCompactor(ecoreStore: store), sid, reference.referenceID, hardInputLimit: hardInputLimit)
        let content = ContextCompactor.content(of: try #require(entries.first).part)
        let projection = try #require((await queue(store, sid, reference.referenceID))?.projection)
        let bytes = Array(body.utf8)
        let slice = Array(bytes[projection.offsetBytes..<projection.endBytes])

        #expect(String(data: Data(slice), encoding: .utf8) != nil, "the committed range must be a whole character sequence")
        #expect(content.hasSuffix(String(decoding: slice, as: UTF8.self)))
        #expect(!content.contains("\u{FFFD}"), "no replacement characters may appear in a projection")
        #expect(ConservativeTokenEstimator().estimate(entries: entries) <= hardInputLimit)
    }

    // MARK: - Case 9 / gates BOUNDED_PROJECTION_PROVIDER_VISIBLE, BOUNDED_PROJECTION_REMAINS_UNPRIVILEGED

    @Test("the bounded projection is the projection the request carries, and it stays untrusted data")
    func providerVisibleMatchesTheBoundedRange() async throws {
        let sid = SessionID("visible")
        let store = fabric()
        let body = payload(60_000, marker: tailMarker)
        let reference = await store.pageOut(sessionID: sid, content: body, origin: .toolCall,
            contextOccurrenceID: "occ-visible", evictionEpoch: 0, summary: "log", toolCallID: ToolCallID("c-9"), toolName: "shell")
        let compactor = ContextCompactor(ecoreStore: store)
        let admitted = try await grant(store, compactor, sid, reference.referenceID, hardInputLimit: 4_096)
        let projection = try #require((await queue(store, sid, reference.referenceID))?.projection)

        let messages = await PCoreContextEngine()
            .snapshot(for: Session(id: sid, createdAt: .now, messages: []), activeEntries: admitted)
            .modelMessages()
        let body0 = ContextCompactor.content(of: try #require(admitted.first).part)
        let provider = AnthropicMessagesProvider(config: ProviderConfig(baseURL: URL(string: "https://example.invalid/v1")!,
                                                                       apiKey: nil, model: "replay", wireProtocol: .anthropicMessages))
        let request = ModelRequest(model: ModelID("replay"), system: "Stable instructions", messages: messages)
        let wire = String(decoding: try #require(provider.makeURLRequest(request).httpBody), as: UTF8.self)

        // Privilege: a bounded projection is recalled data on the wire, never an instruction channel.
        for entry in admitted where entry.segment == .recalledOccurrence {
            #expect(entry.segment.isUntrustedRetrievedData)
            #expect(!entry.segment.carriesPrivilegedInstructions)
        }
        let systemChannel = wire.range(of: "\"system\":[").flatMap { range in
            wire[range.upperBound...].components(separatedBy: "]").first
        } ?? ""
        #expect(!systemChannel.contains("complete=false") && !systemChannel.contains(tailMarker),
            "the top-level system array must not receive projected payload: \(systemChannel.prefix(160))")
        #expect(wire.contains(body0.components(separatedBy: "\n").last?.prefix(48) ?? ""),
            "the projected bytes are in a data channel of the same request")

        // Provider visibility is proven against the committed range, not against the whole object.
        await compactor.noteProviderVisibleRecalls(sessionID: sid, activeEntries: admitted,
                                                   request: ModelRequest(model: ModelID("replay"), messages: messages))
        let telemetry = await store.lifecycleSnapshot(sessionID: sid)
        #expect(telemetry.recallAdmitted >= 1 && telemetry.recallProviderVisible == 1,
            "a bounded projection that is really in the request is visible: \(telemetry.recallAdmitted)/\(telemetry.recallProviderVisible)")
    }
}
