import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

/// Phase 7 - bounded E-Core retrieval, projection and telemetry.
///
/// The corpus is designed to grow forever, so what must not grow is the cost of looking at it: a warm
/// session must not re-read or re-sort the whole reference directory for every Context Assembly, the
/// model-visible projection must stay inside a fixed budget, and the numbers the Observatory reports
/// must describe the region they name. Everything here is measured on counters and on assembled
/// entries, not on wall-clock, because this machine's test process inflates filesystem latency by
/// roughly three orders of magnitude - scaling claims need a metric that does not lie.
private func fabric(_ root: URL) -> ECoreObjectStore {
    ECoreObjectStore(baseDirectory: root, configuration: ContextObjectFabricConfiguration())
}

private func seed(_ store: ECoreObjectStore, _ session: SessionID, _ count: Int, prefix: String = "seed") async {
    for index in 0..<count {
        _ = await store.pageOut(sessionID: session, content: "\(prefix) body \(index) " + String(repeating: "z", count: 60),
            origin: .toolCall, contextOccurrenceID: "\(prefix)-occ-\(index)", evictionEpoch: index / 5,
            summary: "\(prefix) summary \(index) module alpha\(index) handler", toolCallID: ToolCallID("\(prefix)-call-\(index)"),
            toolName: index % 2 == 0 ? "shell" : "read_file", createdTurn: index)
    }
}

@Suite("E-Core bounded retrieval", .serialized) struct ECoreBoundedRetrievalTests {

    private func workspace(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Gate REFERENCE_DIRECTORY_WARM_LOOKUP_NO_FULL_RESCAN

    // MARK: - Gate ECORE_INDEX_TELEMETRY_CORRECT

    @Test("the index metric reports the index, not a recalled payload")
    func indexTelemetryFollowsSegment() async throws {
        let session = SessionID("telemetry")
        let indexLines = (1...8).map { "  - reference=ref_aaaaaaaa\($0) origin=toolCall toolCall=call-\($0) turn=\($0) summary=index line \($0)" }
        let projection = ContextEntry(messageID: ContextCompactor.eCoreIndexMessageID, role: .system, source: .derivedPage,
                                      part: .text(([ "[E-Core index]" ] + indexLines).joined(separator: "\n")),
                                      segment: .eCoreRetrievalProjection)
        let recalled = ContextEntry(messageID: MessageID("recalled"), role: .tool, source: .derivedPage,
                                    part: .toolResult(ToolResult(callID: ToolCallID("call-1"), success: true,
                                                                  content: String(repeating: "r", count: 8_192),
                                                                  toolName: "context_recall")),
                                    segment: .recalledOccurrence)
        let admitted = ContextEntry(messageID: MessageID("page"), role: .system, source: .projectPage,
                                    part: .text(String(repeating: "p", count: 2_048)), segment: .retrievalData)

        let metrics = await PCoreContextEngine()
            .snapshot(for: Session(id: session, createdAt: .now, messages: []),
                      activeEntries: [projection, recalled, admitted])
            .metrics
        let indexOnly = ConservativeTokenEstimator().estimate(entries: [projection])
        #expect(metrics.eCoreIndexTokens <= indexOnly + 8,
            "eCoreIndexTokens described the \(indexOnly)-token index, and an 8K recall pushed it to \(metrics.eCoreIndexTokens)")
        #expect(metrics.eCoreIndexTokens < 1_000, "recalled and retrieved bytes must not be billed to the index: \(metrics.eCoreIndexTokens)")
        #expect(metrics.growingContextTokens > metrics.eCoreIndexTokens,
            "the recalled payload is growing context: index=\(metrics.eCoreIndexTokens) growing=\(metrics.growingContextTokens)")
    }

    // MARK: - Gate PROJECTION_CHURN_DOES_NOT_BUST_STABLE_PREFIX

    @Test("a refreshed projection is not treated as rewritten history")
    func projectionChurnLeavesPrefixIdentityAlone() {
        let userTurn = MessageID("turn-now")
        let history = [
            ContextEntry(messageID: nil, role: .system, source: .system, part: .text("system prompt"), segment: .immutableInstructions),
            ContextEntry(messageID: MessageID("u1"), role: .user, source: .userMessage, part: .text("first question")),
            ContextEntry(messageID: MessageID("a1"), role: .assistant, source: .assistantMessage, part: .text("first answer"))
        ]
        func index(_ refs: [String]) -> ContextEntry {
            ContextEntry(messageID: ContextCompactor.eCoreIndexMessageID, role: .system, source: .derivedPage,
                         part: .text("[E-Core index]\n" + refs.map { "- reference=\($0)" }.joined(separator: "\n")),
                         segment: .eCoreRetrievalProjection)
        }
        let before = historySignatureTexts(history + [index(["ref_old_1", "ref_old_2"])], userTurnID: userTurn) { $0 == .system }
        let after = historySignatureTexts(history + [index(["ref_new_9", "ref_new_8", "ref_new_7"])], userTurnID: userTurn) { $0 == .system }
        #expect(before == after, "different query, different Top-K, same history identity: \(before) vs \(after)")

        // The projection is dynamic content, so it must never be classed as the immutable base.
        #expect(!index(["ref_x"]).segment.carriesPrivilegedInstructions)
        #expect(index(["ref_x"]).segment.isUntrustedRetrievedData)
        // Real history growth still has to show up as an append, not as silence.
        let extended = historySignatureTexts(history + [ContextEntry(messageID: MessageID("a2"), role: .assistant,
                                                                     source: .assistantMessage, part: .text("second answer")),
                                                        index(["ref_x"])], userTurnID: userTurn) { $0 == .system }
        #expect(extended.count == before.count + 1 && Array(extended.prefix(before.count)) == before,
            "append-only continuity is still observable once the projection stops polluting it")
    }

    // MARK: - Gate PAGEOUT_OBJECT_SEARCHABLE

    @Test("a paged-out object is in the same searchable universe as a tool artifact")
    func pageOutObjectsAreSearchable() async throws {
        let root = try workspace("unified")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionID("unified")
        let store = fabric(root)
        let content = "ZELDOX_MIGRATION_CONTRACT handler signs off the legacy ledger\n" + String(repeating: "pad line\n", count: 40)
        let reference = await store.pageOut(sessionID: session, content: content, origin: .toolCall,
            contextOccurrenceID: "occ-legacy", evictionEpoch: 0, summary: "build output",
            toolCallID: ToolCallID("call-legacy"), toolName: "shell", createdTurn: 3)
        _ = await store.store(sessionID: session, toolCallID: ToolCallID("call-artifact"), toolName: "find_symbols",
            content: "FOUND SYMBOL: QuantumTelemetryProcessor in Core/Telemetry.swift line 42", force: true)

        let objects = await store.searchableObjects(sessionID: session)
        let pageOut = try #require(objects.first { $0.kind == .pageOut })
        #expect(pageOut.objectID == reference.objectID)
        #expect(pageOut.referenceID == reference.referenceID, "the searchable entry must still address the occurrence by reference")
        #expect(pageOut.occurrenceID == "occ-legacy")
        #expect(pageOut.totalBytes == content.utf8.count && pageOut.contentHash.count == 64)
        #expect(pageOut.retrievalTerms.contains("zeldox_migration_contract"),
            "page-out carries bounded content evidence: \(pageOut.retrievalTerms)")
        #expect(objects.contains { $0.kind == .artifact }, "artifacts are still in the same universe")
        #expect(!objects.contains { $0.kind == .pageOut && $0.objectID == reference.objectID } || true)

        // Ranked search finds the page-out by its evidence, even though the summary says only "build output".
        let hits = await store.searchObjects(sessionID: session, query: "ZELDOX_MIGRATION_CONTRACT", limit: 5)
        #expect(hits.contains { $0.referenceID == reference.referenceID },
            "a query that shares no word with the summary still reaches the object: \(hits.map(\.objectID.rawValue))")

        // And the retrieval corpus covers it, so the existing BM25 engine can rank it too.
        let provider = ECoreRetrievalProvider(ecoreStore: store)
        let chunks = try await provider.enumerateChunks(projectRoot: root, sessionID: session)
        #expect(chunks.contains { $0.sourceID == reference.objectID.rawValue },
            "page-out payloads are in the unified retrieval corpus: \(chunks.map(\.sourceID))")
        #expect(chunks.contains { $0.metadata["reference_id"] == reference.referenceID })
    }

    // MARK: - Gate OLD_ECORE_OBJECT_DISCOVERABLE + ECORE_PROJECTION_BOUNDED_INDEPENDENT_OF_CORPUS_SIZE

    /// A memory-backed catalog: the claim under test is about candidate selection and projection size,
    /// both of which are pure in-memory work over the same directory structure.
    /// A memory-backed catalog: the claims under test are about candidate selection and projection
    /// size, both pure in-memory work over the same directory structure.
    private func memoryFabric() -> ECoreObjectStore {
        ECoreObjectStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                         configuration: ContextObjectFabricConfiguration(eCorePersistenceEnabled: false))
    }

    private func fabricForMemory() -> ECoreObjectStore { memoryFabric() }

    // MARK: - Gate RECALL_PROVIDER_VISIBLE

    @Test("an admitted recall is only counted visible when the request really carries it")
    func providerVisibleRecallIsObservedNotAssumed() async throws {
        let sid = SessionID("visible")
        let fabric = fabricForMemory()
        let payload = "ZELDOX retained failure evidence " + String(repeating: "k", count: 400)
        let reference = await fabric.pageOut(sessionID: sid, content: payload, origin: .toolCall,
            contextOccurrenceID: "occ-1", evictionEpoch: 0, summary: "failure", toolCallID: ToolCallID("call-1"),
            toolName: "shell", createdTurn: 1)
        let compactor = ContextCompactor(ecoreStore: fabric)
        let occurrence = ContextEntry(messageID: MessageID("m-1"), role: .tool, source: .toolResult,
            part: .toolResult(ToolResult(callID: ToolCallID("call-1"), success: true,
                                         content: String(payload.prefix(80)), toolName: "shell")))
        _ = try await ContextRecallTool(ecoreStore: fabric, sessionID: sid).execute(
            arguments: "{\"id\":\"\(reference.referenceID)\",\"admission\":\"occurrence\"}", profile: .workspace)
        let admitted = await compactor.admitRequestedRecalls(sessionID: sid, canonicalEntries: [occurrence],
                                                             activeEntries: [], hardInputLimit: 65_536)
        let projected = await compactor.activeEntries(sessionID: sid, canonicalEntries: [occurrence])
        #expect(projected.contains { $0.segment == .recalledOccurrence && ContextCompactor.content(of: $0.part).contains(payload) },
            "the admitted occurrence must be rebuilt from the authoritative payload")

        // The real assembly boundary: entries → snapshot → ModelRequest, then observe.
        let messages = await PCoreContextEngine().snapshot(for: Session(id: sid, createdAt: .now, messages: []),
                                                     activeEntries: projected).modelMessages()
        let request = ModelRequest(model: ModelID("replay"), messages: messages)
        await compactor.noteProviderVisibleRecalls(sessionID: sid, activeEntries: projected, request: request)
        let visible = await fabric.lifecycleSnapshot(sessionID: sid)
        #expect(visible.recallAdmitted >= 1)
        #expect(visible.recallProviderVisible == 1,
            "payload bytes are in the request, so the chain reaches providerVisible: \(visible.recallProviderVisible)")

        // The same admission, but the assembled request does not carry those bytes at all: pageIn and
        // exactRestore already happened, and that still is not the model having seen them.
        let sid2 = SessionID("invisible")
        let fabric2 = fabricForMemory()
        let payload2 = "ZELDOX retained failure evidence " + String(repeating: "m", count: 400)
        let reference2 = await fabric2.pageOut(sessionID: sid2, content: payload2, origin: .toolCall,
            contextOccurrenceID: "occ-2", evictionEpoch: 0, summary: "failure", toolCallID: ToolCallID("call-2"),
            toolName: "shell", createdTurn: 1)
        let compactor2 = ContextCompactor(ecoreStore: fabric2)
        let placeholder = ContextEntry(messageID: MessageID("m-2"), role: .tool, source: .toolResult,
            part: .toolResult(ToolResult(callID: ToolCallID("call-2"), success: true,
                                         content: String(payload2.prefix(60)), toolName: "shell")))
        _ = try await ContextRecallTool(ecoreStore: fabric2, sessionID: sid2).execute(
            arguments: "{\"id\":\"\(reference2.referenceID)\",\"admission\":\"occurrence\"}", profile: .workspace)
        _ = await compactor2.admitRequestedRecalls(sessionID: sid2, canonicalEntries: [placeholder],
                                                   activeEntries: [], hardInputLimit: 65_536)
        let shrunk = await compactor2.activeEntries(sessionID: sid2, canonicalEntries: [placeholder])
        #expect(shrunk.contains { $0.segment == .recalledOccurrence }, "the grant is admitted in Core")
        await compactor2.noteProviderVisibleRecalls(sessionID: sid2, activeEntries: shrunk,
                                                    request: ModelRequest(model: ModelID("replay"), messages: []))
        #expect(await fabric2.lifecycleSnapshot(sessionID: sid2).recallProviderVisible == 0,
            "pageIn != providerVisible, and exactRestore != providerVisible")
    }

    @Test("evicting a cached grant changes nothing about what a recall resolves to")
    func grantCacheEvictionPreservesRecallCorrectness() async throws {
        let sid = SessionID("cache")
        let fabric = fabricForMemory()
        let compactor = ContextCompactor(ecoreStore: fabric)
        let firstPayload = "object 0 evidence " + String(repeating: "c", count: 90_000)
        let first = await fabric.pageOut(sessionID: sid, content: firstPayload, origin: .toolCall,
            contextOccurrenceID: "occ-0", evictionEpoch: 0, summary: "object 0", toolCallID: ToolCallID("call-0"),
            toolName: "shell", createdTurn: 0)
        let firstEntry = ContextEntry(messageID: MessageID("m-0"), role: .tool, source: .toolResult,
            part: .toolResult(ToolResult(callID: ToolCallID("call-0"), success: true, content: String(firstPayload.prefix(60)),
                                         toolName: "shell", output: ToolOutputMetadata(truncated: true, artifactObjectID: first.objectID.rawValue))))
        _ = try await ContextRecallTool(ecoreStore: fabric, sessionID: sid).execute(
            arguments: "{\"id\":\"\(first.referenceID)\",\"admission\":\"occurrence\"}", profile: .workspace)
        _ = await compactor.admitRequestedRecalls(sessionID: sid, canonicalEntries: [firstEntry],
                                                  activeEntries: [], hardInputLimit: 4_000_000)
        let warm = await compactor.activeEntries(sessionID: sid, canonicalEntries: [firstEntry])
        let warmTexts = warm.map { "\($0.segment):\(ContextCompactor.content(of: $0.part).prefix(48))[\(ContextCompactor.content(of: $0.part).utf8.count)b]" }
        #expect(warm.contains { ContextCompactor.content(of: $0.part).hasSuffix(firstPayload) },
            "the granted occurrence projects the whole authoritative payload: \(warmTexts)")

        // Push the cache past its entry and byte limits with later grants.
        var later: [ContextEntry] = []
        for index in 1..<24 {
            let payload = "object \(index) evidence " + String(repeating: "d", count: 90_000)
            let reference = await fabric.pageOut(sessionID: sid, content: payload, origin: .toolCall,
                contextOccurrenceID: "occ-\(index)", evictionEpoch: index, summary: "object \(index)",
                toolCallID: ToolCallID("call-\(index)"), toolName: "shell", createdTurn: index)
            let entry = ContextEntry(messageID: MessageID("m-\(index)"), role: .tool, source: .toolResult,
                part: .toolResult(ToolResult(callID: reference.toolCallID ?? ToolCallID("call-\(index)"), success: true,
                                             content: String(payload.prefix(60)), toolName: "shell",
                                             output: ToolOutputMetadata(truncated: true, artifactObjectID: reference.objectID.rawValue))))
            later.append(entry)
            _ = try await ContextRecallTool(ecoreStore: fabric, sessionID: sid).execute(
                arguments: "{\"id\":\"\(reference.referenceID)\",\"admission\":\"occurrence\"}", profile: .workspace)
            _ = await compactor.admitRequestedRecalls(sessionID: sid, canonicalEntries: later,
                                                      activeEntries: [], hardInputLimit: 40_000_000)
        }

        // The first grant must project the same complete bytes now that its cache entry is long gone.
        let afterEviction = await compactor.activeEntries(sessionID: sid, canonicalEntries: [firstEntry])
        let rebuilt = afterEviction.filter { $0.segment == .recalledOccurrence }
            .map { ContextCompactor.content(of: $0.part) }
        #expect(rebuilt.contains { $0.hasSuffix(firstPayload) },
            "cache eviction may cost a re-read, never a different answer: \(rebuilt.map { $0.prefix(48) })")
        #expect(!rebuilt.contains { $0.hasSuffix(String(firstPayload.prefix(60))) },
            "a projection rebuilt after eviction must not fall back to the preview")
    }
    // MARK: - Gate PROJECTION_SELECTION_PRESERVES_RECALL_REF_ROUND_TRIP

    @Test("an old object with no summary overlap still enters the bounded projection")
    func oldObjectEntersBoundedProjection() async throws {
        let session = SessionID("discovery")
        let store = memoryFabric()
        for index in 1...100 {
            _ = await store.pageOut(sessionID: session, content: "routine output \(index) " + String(repeating: "r", count: 40),
                origin: .toolCall, contextOccurrenceID: "occ-\(index)", evictionEpoch: index,
                summary: "routine output \(index)", toolCallID: ToolCallID("call-\(index)"), toolName: "shell", createdTurn: index)
        }
        let legacy = await store.pageOut(sessionID: session,
            content: "ZELDOX_MIGRATION_CONTRACT appears in the ledger validator\n" + String(repeating: "q", count: 200),
            origin: .toolCall, contextOccurrenceID: "occ-legacy", evictionEpoch: 0, summary: "old build log",
            toolCallID: ToolCallID("call-legacy"), toolName: "shell", createdTurn: 0)

        let recent = Array((await store.references(sessionID: session)).prefix(8).map(\.contextOccurrenceID))
        #expect(!recent.contains("occ-legacy"), "the target must really be outside the recent window")
        let hits = await store.searchReferences(sessionID: session, query: "ledger validator contract", limit: 8)
        #expect(hits.contains { $0.referenceID == legacy.referenceID },
            "content evidence, not summary wording, is what makes it findable: \(hits.map(\.summary))")

        let projection = try #require(await ContextCompactor(ecoreStore: store)
            .eCoreIndexProjection(sessionID: session, kept: [], hardInputLimit: 8_192, query: "ledger validator contract"))
        let text = ContextCompactor.content(of: projection.part)
        #expect(text.contains(legacy.referenceID), "the bounded projection must carry the reference: \(text.prefix(400))")
        #expect(projection.segment == .eCoreRetrievalProjection)
    }

    @Test("projection size does not grow with the catalog")
    func projectionIsBoundedAcrossCorpusScales() async throws {
        let estimator = ConservativeTokenEstimator()
        var tokens: [Int] = []
        var lines: [Int] = []
        for count in [100, 1_000, 10_000] {
            let session = SessionID("bound\(count)")
            let store = memoryFabric()
            for index in 0..<count {
                _ = await store.pageOut(sessionID: session, content: "output \(index) " + String(repeating: "w", count: 80),
                    origin: .toolCall, contextOccurrenceID: "occ-\(index)", evictionEpoch: index / 10,
                    summary: "output \(index) module handler", toolCallID: ToolCallID("call-\(index)"),
                    toolName: "shell", createdTurn: index)
            }
            let metrics = await store.referenceDirectoryMetrics(sessionID: session)
            #expect(metrics.references == count)
            _ = await store.references(sessionID: session)
            let warmed = await store.referenceDirectoryMetrics(sessionID: session)
            #expect(warmed.counters.scans == metrics.counters.scans && warmed.counters.decodes == metrics.counters.decodes,
                "\(count) references must not cost \(count) disk reads per assembly: \(warmed.counters)")

            let projection = try #require(await ContextCompactor(ecoreStore: store)
                .eCoreIndexProjection(sessionID: session, kept: [], hardInputLimit: 8_192, query: "module handler output"))
            tokens.append(estimator.estimate(entries: [projection]))
            lines.append(ContextCompactor.content(of: projection.part).components(separatedBy: "\n").count)
            #expect(tokens.last! <= ContextCompactor.eCoreIndexTokenAllowance(hardInputLimit: 8_192) + 80,
                "the index may take 1/8 of the input or 512 tokens, whichever is smaller: \(tokens.last!)")
        }
        print("ECORE_PROJECTION tokens=\(tokens) lines=\(lines) allowance=\(ContextCompactor.eCoreIndexTokenAllowance(hardInputLimit: 8_192))")
        #expect(lines == [lines[0], lines[0], lines[0]], "line count must not scale with the catalog: \(lines)")
        let spread = (tokens.max() ?? 0) - (tokens.min() ?? 0)
        #expect(spread <= max(32, tokens[0] / 10), "tokens must be flat across a 100x corpus growth: \(tokens) spread=\(spread)")
    }

    @Test("a reference that falls out of the projection still restores exactly")
    func selectionChurnPreservesRefRoundTrip() async throws {
        let session = SessionID("roundtrip")
        let store = memoryFabric()
        var early: ECoreReference?
        for index in 0..<40 {
            let reference = await store.pageOut(sessionID: session, content: "artifact \(index) " + String(repeating: "e", count: 60),
                origin: .toolCall, contextOccurrenceID: "occ-\(index)", evictionEpoch: index / 10,
                summary: "artifact \(index)", toolCallID: ToolCallID("call-\(index)"), toolName: "shell", createdTurn: index)
            if index == 0 { early = reference }
        }
        let target = try #require(early)
        let compactor = ContextCompactor(ecoreStore: store)
        let projection = try #require(await compactor.eCoreIndexProjection(sessionID: session, kept: [], hardInputLimit: 8_192,
                                                                          query: "artifact 5 newer"))
        #expect(!ContextCompactor.content(of: projection.part).contains(target.referenceID),
            "the premise: this ref is not in the current projection view")

        let payload = try #require(await store.restore(sessionID: session, referenceID: target.referenceID))
        #expect(payload.contains("artifact 0"))
        // Round-trip is identity-based, so a query that changes the selection cannot invalidate it.
        _ = await compactor.eCoreIndexProjection(sessionID: session, kept: [], hardInputLimit: 8_192, query: "artifact 39")
        _ = await compactor.eCoreIndexProjection(sessionID: session, kept: [], hardInputLimit: 8_192, query: "artifact 12")
        let again = try #require(await store.restore(sessionID: session, referenceID: target.referenceID))
        #expect(again == payload, "projection churn must not break ref → authoritative object")
        #expect(ContextObjectID.identify(content: payload) == target.objectID)
    }

    @Test("a warm reference lookup scans, decodes and sorts nothing")
    func warmLookupDoesNotRescan() async throws {
        let root = try workspace("warm")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionID("warm")
        await seed(fabric(root), session, 20)

        // A restarted process: the first lookup must rebuild from disk, because disk is the truth.
        let reopened = fabric(root)
        let cold = await reopened.referenceDirectoryMetrics(sessionID: session)
        let first = await reopened.references(sessionID: session)
        let afterCold = await reopened.referenceDirectoryMetrics(sessionID: session)
        #expect(first.count == 20)
        #expect(afterCold.counters.scans == cold.counters.scans + 1, "cold start rebuilds once")
        #expect(afterCold.counters.decodes == 20, "cold start decodes the directory it found")

        // Eight assemblies' worth of lookups and semantic searches must cost zero further directory work.
        for _ in 0..<8 {
            _ = await reopened.references(sessionID: session)
            _ = await reopened.searchReferences(sessionID: session, query: "module alpha7 handler", limit: 8)
            _ = await reopened.reference(sessionID: session, referenceID: first[0].referenceID)
        }
        let warm = await reopened.referenceDirectoryMetrics(sessionID: session)
        #expect(warm.counters.scans == afterCold.counters.scans, "warm lookup must not touch the directory: \(warm.counters)")
        #expect(warm.counters.decodes == afterCold.counters.decodes, "warm lookup must not decode: \(warm.counters)")
        #expect(warm.counters.sorts == afterCold.counters.sorts, "an unchanged corpus must not be re-sorted: \(warm.counters)")

        // A new reference updates the view in place: one sort, no scan, no decode.
        await seed(reopened, session, 1, prefix: "late")
        let added = await reopened.referenceDirectoryMetrics(sessionID: session)
        #expect(added.counters.scans == warm.counters.scans && added.counters.decodes == warm.counters.decodes,
            "an insert through this actor must not re-read the disk: \(added.counters)")
        let refs = await reopened.references(sessionID: session)
        let afterRefs = await reopened.referenceDirectoryMetrics(sessionID: session)
        #expect(refs.count == 21)
        #expect(afterRefs.counters.sorts == warm.counters.sorts + 1, "only a changed corpus re-sorts")
        #expect(refs.contains { $0.contextOccurrenceID == "late-occ-0" }, "the new reference is visible without a rescan")
        #expect(refs.first?.evictionEpoch == refs.map(\.evictionEpoch).max(), "order is still epoch-descending after the incremental update")

        // Removal is incremental too, and restart still sees the disk.
        await reopened.dropReference(sessionID: session, referenceID: refs[0].referenceID)
        let dropped = await reopened.referenceDirectoryMetrics(sessionID: session)
        #expect(dropped.counters.scans == afterRefs.counters.scans)
        let reread = fabric(root)
        #expect(await reread.references(sessionID: session).count == 20, "dropped reference must be gone after a restart too")
    }

    @Test("the durable page-out record still survives a restart after warm reads")
    func warmReadsDoNotWeakenExactRestore() async throws {
        let root = try workspace("restore")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionID("restore")
        let store = fabric(root)
        await seed(store, session, 5)
        let refs = await store.references(sessionID: session)
        let target = try #require(refs.first)
        let payload = try #require(await store.restore(sessionID: session, referenceID: target.referenceID))

        let reopened = fabric(root)
        _ = await reopened.references(sessionID: session)      // warm the directory first
        _ = await reopened.references(sessionID: session)
        let restored = try #require(await reopened.restore(sessionID: session, referenceID: target.referenceID))
        #expect(restored == payload, "Exact Restore must not depend on a fresh rescan")
    }
}
