import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

/// Phase 8 §2-§6 — the production path, end to end, as a permanent gate.
///
/// Nothing new is designed here. This file runs, in one session on one workspace, the chain that each
/// earlier phase fixed one link of: a real executor produces more output than the preview allows, the
/// archive keeps the authoritative bytes, SessionStore keeps only a bounded preview, real context
/// pressure pages the occurrence out, the bounded retrieval projection shows the model a reference, the
/// model reads a range out of the middle and then asks for the occurrence itself, assembly commits the
/// admission, the provider body carries it, and a restart has to agree. Every step goes through
/// `CoreHost` and the real tools; no test-only hook stands in for a production hop. Each assertion
/// names the link it protects, so a regression identifies itself.
private let bigFile = "big.txt"
private let marker = "MIDDLE-MARKER-HELIX-42"
/// Assembled by `awk` from pieces, so the literal never appears in the command the model emitted.
private let middleMarker = "MID7F31END"
private let previewLimit = 16_384

/// A file whose middle is the only interesting part: neither head nor tail contains the marker, so a
/// projection that lost the requested range cannot pass by returning the beginning. ASCII so that one
/// bounded preview costs what the estimator actually charges for it, rather than tripling in bytes.
private func writeBigFile(_ root: URL) throws {
    let body = String(repeating: "a", count: 60_000) + marker + String(repeating: "z", count: 60_000)
    try body.write(to: root.appendingPathComponent(bigFile), atomically: true, encoding: .utf8)
}

private func jsonString(_ value: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
}

private func callEvent(_ id: String, _ tool: String, _ arguments: [String: Any]) -> ModelEvent {
    .toolCallCompleted(ToolCall(callID: ToolCallID(id), toolID: ToolID(tool), arguments: jsonString(arguments)))
}

private func results(named toolName: String, in messages: [ModelMessage]) -> [ToolResult] {
    messages.flatMap(\.parts).compactMap { part -> ToolResult? in
        guard case let .toolResult(result) = part, result.toolName == toolName else { return nil }
        return result
    }
}

private func results(of session: Session, named toolName: String) -> [ToolResult] {
    session.messages.flatMap(\.parts).compactMap { part -> ToolResult? in
        guard case let .toolResult(result) = part, result.toolName == toolName else { return nil }
        return result
    }
}

/// `[Context Object Slice: ref] / Lines: … / Bytes: <start> - <end> of <total> / --- Content --- <body>`
private struct SliceHeader: Equatable {
    let start: Int
    let end: Int
    let total: Int
    let hasMore: Bool
    let body: String
    var length: Int { end - start }
}

private func parseSlice(_ answer: String) -> SliceHeader? {
    let lines = answer.components(separatedBy: "\n")
    guard let bytesLine = lines.first(where: { $0.hasPrefix("Bytes:") }),
          let contentIndex = lines.firstIndex(of: "--- Content ---") else { return nil }
    let groups = bytesLine.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
    guard groups.count >= 3, let start = Int(groups[0]), let end = Int(groups[1]), let total = Int(groups[2]) else { return nil }
    let hasMore = lines.first(where: { $0.hasPrefix("Has More:") })?.contains("true") ?? false
    return SliceHeader(start: start, end: end, total: total, hasMore: hasMore,
                       body: lines.dropFirst(contentIndex + 1).joined(separator: "\n"))
}

/// `[Context Object Occurrence: ref bytes=<start>-<end>/<total> complete=false continuation_offset=n]`
private func parseOccurrence(_ body: String) -> OccurrenceProjection? {
    guard let line = body.components(separatedBy: "\n").first(where: { $0.contains("bytes=") }),
          let range = line.range(of: "bytes=") else { return nil }
    let pieces = line[range.upperBound...].prefix { $0.isNumber || $0 == "-" || $0 == "/" }
        .split(separator: "-", maxSplits: 1)
    guard pieces.count == 2, let start = Int(pieces[0]) else { return nil }
    let tail = pieces[1].split(separator: "/")
    guard tail.count == 2, let end = Int(tail[0]), let total = Int(tail[1]) else { return nil }
    return OccurrenceProjection(offsetBytes: start, lengthBytes: end - start, totalBytes: total)
}

/// The instruction channel of each provider wire, read out of the JSON rather than by string search:
/// the channel the model is told to obey is what recalled bytes may never enter. Each protocol names
/// it differently - `system` message, `instructions`/developer item, top-level `system` block.
private func privilegedText(protocol name: String, wire: String) -> String {
    guard let json = try? JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any] else { return "" }
    func text(_ value: Any?) -> String {
        switch value {
        case let string as String: return string
        case let blocks as [[String: Any]]: return blocks.map { text($0["text"]) }.joined(separator: "\n")
        case let array as [Any]: return array.map(text).joined(separator: "\n")
        default: return ""
        }
    }
    switch name {
    case "chat":
        return (json["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "system" }
            .map { text($0["content"]) }.joined(separator: "\n")
    case "responses":
        let items = (json["input"] as? [[String: Any]] ?? []).filter {
            ["system", "developer"].contains($0["role"] as? String)
        }.map { text($0["content"]) }
        return ([text(json["instructions"])] + items).joined(separator: "\n")
    default:
        return text(json["system"])
    }
}

private func summary(_ request: ModelRequest) -> String {
    request.messages.map { message in
        "\(message.role):" + message.parts.map { part in
            switch part {
            case let .text(text): "text(\(text.utf8.count))"
            case .image, .imageFile: "image"
            case let .toolCall(call): "call(\(call.toolID.rawValue))"
            case let .toolResult(result): "result(\(result.toolName ?? "?") \(result.content.utf8.count))"
            }
        }.joined(separator: ",")
    }.joined(separator: " | ")
}

@Suite("Production recall round trip", .serialized) struct ProductionRecallRoundTripTests {

    // MARK: - §1 the probe chain, permanent: a real shell producing more than the preview allows

    /// Audit probe 1 ran this chain and printed what it found; the print is now the assertion. The
    /// executor is the real `ShellTool`, so the bytes under test are stdout as the process wrote it -
    /// not a string a test handed to the archive.
    @Test("real shell stdout is archived whole, recalled byte-exact, and never re-truncated on the wire")
    func realShellOutputIsArchivedWholeAndRecallable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-p8-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 800 log lines, then a marker the command text never contains literally, then a tail.
        let bigCommand = #"awk 'BEGIN{for(i=0;i<800;i++)printf "BUILDLOG-LINE-%04d-abcdefghijklmnopqrstuvwxyz0123456789\n",i; printf "MID%s%sEND\n","7F","31"; for(i=0;i<80;i++)printf "TAIL-%04d-abcdefghijklmnopqrstuvwxyz0123456789\n",i}'"#
        let provider = ShellEvidenceProvider(bigCommand: bigCommand)
        let host = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("replay"),
                contextProfile: ModelContextProfile(contextWindowTokens: 65_536)),
            workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: root.appendingPathComponent("core"),
            permissionDecision: .allow, interactive: false)
        await host.start()
        defer { await host.shutdown() }
        let client = LingXiClient.inProcess(endpoint: host)
        let sid = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: sid, content: "帮我在日志输出里找到中间那段标记") {}

        let fabric = await host.ecoreStoreRef
        let durable = try await host.sessionStore.session(sid)
        let shell = try #require(results(of: durable, named: "shell").first { $0.success })
        #expect(shell.output.truncated, "55KB of stdout cannot fit the preview")
        let raw = shell.content

        // The archive holds the executor's own bytes, and they are the same bytes on both backends.
        let artifactID = try #require(shell.output.artifactObjectID, "a truncated result must name its artifact")
        let objectID = try ContextObjectID(artifactID)
        let archived = try #require(await fabric.fetch(sessionID: sid, objectID: objectID))
        let blob = await host.toolRuntimeRef.archivedOutput(shell.output.outputBlobRef ?? artifactID)
        #expect(archived.utf8.count > raw.utf8.count, "the durable record is a preview of something larger")
        #expect(archived == blob || blob == nil, "the archive blob and the E-Core object must be the same bytes")
        #expect(archived.contains("BUILDLOG-LINE-0000") && archived.contains("TAIL-0079"),
            "the whole output: head and tail both present")
        #expect(archived.contains(middleMarker), "the middle survived, which is the part being asked for")
        #expect(!raw.contains(middleMarker), "the preview stops before the middle: that is the point of the artifact")
        let payloadFile = await fabric.baseDirectory.appendingPathComponent(sid.rawValue)
            .appendingPathComponent("objects").appendingPathComponent("\(artifactID).txt")
        #expect((try? Data(contentsOf: payloadFile).count) == archived.utf8.count,
            "the physical object on disk is the authoritative payload")

        // The recall is byte-exact against that object, and the wire does not cut it again.
        let sent = try #require(provider.requestCarryingSlice, "the model never saw its own recall result")
        let slices = results(named: "context_recall", in: sent.messages)
        #expect(slices.count == 1)
        let slice = try #require(slices.first)
        #expect(slice.content.contains(middleMarker), "a range that covers the middle must return the middle")
        let page = try #require(parseSlice(slice.content))
        #expect(page.total == archived.utf8.count)
        #expect(page.body == String(decoding: Array(archived.utf8)[page.start..<page.end], as: UTF8.self))
        #expect(page.length <= previewLimit)
        #expect(archived.contains(page.body), "a slice of the object is contained in the object")
        // A result Core already bounded must not be cut a second time on the way to the model.
        let projectedSlice = ModelToolResultProjection.project(slice, segment: .conversation)
        #expect(projectedSlice.content == slice.content && projectedSlice.truncated != true,
            "the wire projection re-truncated a bounded recall: \(projectedSlice.content.prefix(200))")
        for (name, wire) in zip(["chat", "responses", "anthropic"], try PEContextIntegrityTests().wires(sent)) {
            // Nothing else in this request can contain the marker, so seeing it here is the proof that
            // the recalled range reached the model on this protocol.
            #expect(wire.contains(middleMarker), "\(name) never showed the model the recalled middle")
            let privileged = privilegedText(protocol: name, wire: wire)
            #expect(!privileged.contains(middleMarker), "\(name) put recalled bytes in its instruction channel")
        }
    }

    // MARK: - §2 PRODUCTION_PATH_RECALL_ROUND_TRIP + §3 PRODUCTION_PROVIDER_PARITY

    @Test("one large artifact survives executor → archive → page-out → recall → provider → restart")
    func productionPathRecallRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-p8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeBigFile(root)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = LargeReadReplayProvider()
        let host = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("replay"),
                contextProfile: ModelContextProfile(contextWindowTokens: 18_000)),
            workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: root.appendingPathComponent("core"),
            permissionDecision: .allow, interactive: false)
        await host.start()
        provider.host = host
        let sid = try await host.sessionStore.create().id
        provider.sessionID = sid
        let client = LingXiClient.inProcess(endpoint: host)
        let fabric = await host.ecoreStoreRef
        #expect(await fabric.persistenceEnabled, "this replay must run on the real disk/SQLite backend")

        // Four turns that each read the same oversized file. One read fits the window; a run that
        // keeps producing output does not, and it is that accumulation - not a test hook - which has
        // to push the earlier occurrence out of P-Core.
        for turn in 1...4 {
            provider.beginTurn()
            for try await _ in try await client.sendMessage(sessionID: sid,
                                                             content: "第 \(turn) 次把 \(bigFile) 读出来") {}
        }
        let paged = await fabric.references(sessionID: sid)
        #expect(!paged.isEmpty, "repeated oversized reads must be paged out under real pressure")
        provider.beginTurn()
        for try await _ in try await client.sendMessage(sessionID: sid,
                                                        content: "找到中间的标记，先读它附近，然后把它恢复成上下文") {}

        // 1. A real executor produced more than the preview allows; the archive holds the whole thing.
        let durable = try await host.sessionStore.session(sid)
        let reads = results(of: durable, named: "read_file")
        #expect(!reads.isEmpty, "the replay should have read the file")
        let read = try #require(reads.first { $0.output.artifactObjectID != nil })
        #expect(read.output.truncated == true, "a 60KB read must be recorded as truncated")
        #expect(read.content.utf8.count <= previewLimit + 512, "the durable preview stays bounded: \(read.content.utf8.count)")
        let objectID = try ContextObjectID(read.output.artifactObjectID ?? "")
        let authoritative = try #require(await fabric.fetch(sessionID: sid, objectID: objectID),
            "the archive must hold the authoritative bytes behind artifactObjectID")
        #expect(authoritative.contains(marker), "the authoritative object is the whole output, marker included")
        #expect(authoritative.utf8.count > read.content.utf8.count, "SessionStore keeps a preview, not the truth")
        let fileBytes = Array((try String(contentsOf: root.appendingPathComponent(bigFile), encoding: .utf8)).utf8)
        #expect(authoritative.contains(String(decoding: fileBytes[0..<64], as: UTF8.self)),
            "the archived bytes are the file's own, not a re-encoding")

        // 2. Real context pressure paged the occurrence out; the reference still addresses it exactly.
        let references = await fabric.references(sessionID: sid)
        #expect(!references.isEmpty, "the replay never reached page-out under pressure")
        let target = try #require(references.first { $0.referenceID == provider.chosenReferenceID },
            "the reference the model actually used must be one Core handed it: \(references.map(\.referenceID))")
        #expect(target.objectID == objectID, "the model reached the archived artifact through that reference")
        #expect(try #require(await fabric.restore(sessionID: sid, referenceID: target.referenceID)) == authoritative,
            "ref → authoritative object → complete bytes is the round trip")

        // 3. Each range read the model made is byte-exact against the authoritative object.
        let slices = provider.sliceAnswers.compactMap(parseSlice)
        #expect(slices.count == 2, "the model read two ranges, and got back: \(slices.count)")
        for page in slices {
            #expect(page.total == authoritative.utf8.count, "the header describes the object, not the page")
            #expect(page.length > 0 && page.length <= previewLimit)
            #expect(page.body == String(decoding: Array(authoritative.utf8)[page.start..<page.end], as: UTF8.self),
                "the declared range must be exactly the bytes returned")
            #expect(page.body.utf8.count == page.length, "the label may not over- or under-count")
        }
        #expect(slices.contains { $0.body.contains(marker) }, "a range aimed at the marker must return it")

        // 4. The occurrence grant reached the provider body, in the request Core really assembled.
        let sent = try #require(provider.finalRequest, "the model never got a request after the grant")
        let recalled = sent.messages.flatMap(\.parts).compactMap { part -> ToolResult? in
            guard case let .toolResult(result) = part, result.content.contains(marker),
                  // A restored occurrence, not one of the model's own range reads: it either carries
                  // the occurrence header, or it is larger than any slice the tool is allowed to return.
                  result.content.contains("[Context Object Occurrence:") || result.content.utf8.count > previewLimit + 512
                else { return nil }
            return result
        }
        let projected = try #require(recalled.first { $0.output.artifactObjectID == objectID.rawValue } ?? recalled.first,
            "the recalled occurrence must appear in the request: \(summary(sent))")
        #expect(projected.content.utf8.count <= authoritative.utf8.count,
            "the active context may never exceed the object it stands for")
        let committed = try #require(await fabric.recallQueue(sessionID: sid).first { $0.referenceID == target.referenceID })
        #expect(committed.state == .admissionCommitted, "the model asked for the occurrence: \(committed.state.rawValue)")
        let body = projected.content
        if let range = committed.projection, !range.isComplete {
            let declared = try #require(parseOccurrence(body), "a bounded projection must say so: \(body.prefix(200))")
            #expect(declared == range, "the label must be the committed range: \(declared) vs \(range)")
            #expect(body.utf8.count < authoritative.utf8.count, "the active context carries a range, not the object")
            #expect(body.hasSuffix(String(decoding: Array(authoritative.utf8)[range.offsetBytes..<range.endBytes], as: UTF8.self)),
                "a projection must end in the bytes its label declares")
        } else {
            #expect(body.contains(marker))
            #expect(!body.contains("complete=false"), "what fits is not labelled partial")
        }

        // 5. Telemetry proves the last hop separately from the grant.
        let telemetry = await fabric.lifecycleSnapshot(sessionID: sid)
        #expect(telemetry.recallResolved >= 1, "\(telemetry.recallResolved)")
        #expect(telemetry.recallAdmitted >= 1, "\(telemetry.recallAdmitted)")
        #expect(telemetry.recallProviderVisible >= 1,
            "granted is not the same as visible: admitted=\(telemetry.recallAdmitted) visible=\(telemetry.recallProviderVisible)")

        // 6. §3 PRODUCTION_PROVIDER_PARITY — the same occurrence on all three real wires.
        var instructions: [String] = []
        if let system = sent.system, !system.isEmpty { instructions.append(system) }
        instructions += sent.messages.filter { $0.role == .system && $0.segment.carriesPrivilegedInstructions }
            .map(\.content).filter { !$0.isEmpty }
        #expect(!instructions.isEmpty, "a real assembly must still carry its instructions")
        let parity = try PEContextIntegrityTests().wires(sent)
        #expect(parity.count == 3)
        for (name, wire) in zip(["chat", "responses", "anthropic"], parity) {
            #expect(wire.contains(marker), "the recalled bytes must be visible on \(name)")
            #expect(!wire.contains("characters truncated"), "\(name) must not re-truncate what Core already bounded")
            let privileged = privilegedText(protocol: name, wire: wire)
            for text in instructions {
                #expect(privileged.contains(text.prefix(64)), "\(name) must still carry its instructions: \(privileged.prefix(120))")
            }
            #expect(!privileged.contains(marker),
                "recalled bytes may not enter \(name)'s instruction channel: \(privileged.prefix(200))")
            #expect(!privileged.contains("complete=false"), "a projection label is data, never an instruction")
            #expect(!privileged.contains("Restored session context"), "restored data stays out of the privileged prefix")
        }
        // Structurally, on the way in: no recalled byte ever rode a privileged segment.
        for message in sent.messages where message.content.contains(marker) {
            #expect(!message.segment.carriesPrivilegedInstructions,
                "segment \(message.segment) must not carry instructions")
            #expect(message.segment.isUntrustedRetrievedData, "recalled data stays marked as such: \(message.segment)")
        }

        // 7. A §11 PE_STABLE_PREFIX_INVARIANT sample: the projection is not part of the prefix.
        if let first = provider.earlyCachePlan, let last = provider.finalCachePlan {
            #expect(first.immutableBase == last.immutableBase,
                "recall churn must not bust the stable prefix: \(first.immutableBase) → \(last.immutableBase)")
        }

        // 8. A restart agrees about identity, grant and range.
        await host.shutdown()
        let reopened = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("replay"),
                contextProfile: ModelContextProfile(contextWindowTokens: 18_000)),
            workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: root.appendingPathComponent("core"),
            permissionDecision: .allow, interactive: false)
        await reopened.start()
        defer { await reopened.shutdown() }
        let afterStore = await reopened.ecoreStoreRef
        let after = try #require(await afterStore.recallQueue(sessionID: sid).first { $0.referenceID == target.referenceID })
        #expect(try #require(await afterStore.restore(sessionID: sid, referenceID: target.referenceID)) == authoritative,
            "the authoritative object is the same bytes after a restart")
        #expect(after.state == committed.state, "the admission state must survive: \(committed.state) → \(after.state)")
        #expect(after.projection == committed.projection,
            "a restart must not re-resolve a range: \(String(describing: committed.projection)) → \(String(describing: after.projection))")
        #expect(await afterStore.reference(sessionID: sid, referenceID: target.referenceID)?.objectID == objectID,
            "the reference keeps addressing the same object")
    }

    // MARK: - §4 MULTI_ARTIFACT_PROJECTION_RANGE_ISOLATION

    @Test("one artifact's bounded range never touches its batch siblings")
    func multiArtifactProjectionRangesStayIsolated() async throws {
        let sid = SessionID("multi")
        let store = ECoreObjectStore(configuration: ContextObjectFabricConfiguration(eCorePersistenceEnabled: false))
        let compactor = ContextCompactor(ecoreStore: store)
        // Three artifacts in one batch, each truncated: the preview is shorter than its own
        // authoritative object, so a range that leaked from one sibling onto another shows up as
        // content, not just as a label.
        let payloads = ["small artifact " + String(repeating: "s", count: 4_000),
                        "large artifact " + String(repeating: "L", count: 60_000),
                        "medium artifact " + String(repeating: "M", count: 8_000)]
        let objectIDs = payloads.map { ContextObjectID.identify(content: $0) }
        for (index, payload) in payloads.enumerated() {
            _ = await store.store(sessionID: sid, toolCallID: ToolCallID("call-\(index)"), toolName: "shell",
                                  content: payload, force: true)
        }
        let records = payloads.enumerated().map { index, payload in
            ToolResult(callID: ToolCallID("call-\(index)"), success: true, content: String(payload.prefix(600)),
                       toolName: "shell", output: ToolOutputMetadata(truncated: true, totalCharacters: payload.count,
                                                                     artifactObjectID: objectIDs[index].rawValue))
        }
        let calls = records.map { ToolCall(callID: $0.callID, toolID: ToolID("shell"), arguments: "{}") }
        let assistant = Message(id: MessageID("a-multi"), role: .assistant, parts: calls.map { .toolCall($0) }, createdAt: .now)
        let toolMessage = Message(id: MessageID("r-multi"), role: .tool, parts: records.map { .toolResult($0) }, createdAt: .now)
        let session = Session(id: sid, createdAt: .now, messages: [assistant, toolMessage])
        let batch = ToolExchangeBatch(batchID: "batch-multi", sessionID: sid, assistantMessageID: assistant.id,
            resultMessageID: toolMessage.id, toolCalls: calls, toolResults: records, providerStep: 1,
            state: .consumed, estimatedTokens: 40_000)
        let canonical = await PCoreContextEngine().entries(for: session, systemContext: nil)
        _ = try await compactor.compact(sessionID: sid, entries: canonical, budget: ContextBudget(
            hardInputLimit: 3_000, preferredActiveTokens: 100, highWaterTokens: 100, lowWaterTokens: 80,
            reservedOutputTokens: 0, protocolOverheadTokens: 0, toolSchemaTokens: 0, safetyMarginTokens: 0),
            batches: [batch], trigger: .manual)

        let references = await store.references(sessionID: sid)
        #expect(references.count == 3, "one batch of three artifacts pages out three references: \(references.count)")
        let largeRef = try #require(references.first { $0.objectID == objectIDs[1] },
            "the large artifact must have its own reference: \(references.map(\.objectID.rawValue))")
        let largePayload = try #require(await store.restore(sessionID: sid, referenceID: largeRef.referenceID))
        #expect(largePayload.utf8.count == payloads[1].utf8.count, "the authoritative object is complete")

        _ = try await ContextRecallTool(ecoreStore: store, sessionID: sid).execute(
            arguments: "{\"id\":\"\(largeRef.referenceID)\",\"admission\":\"occurrence\",\"offset\":0,\"limit_bytes\":60000}",
            profile: .workspace)
        let admitted = await compactor.admitRequestedRecalls(sessionID: sid, canonicalEntries: canonical,
                                                            activeEntries: [], hardInputLimit: 3_000)
        let committed = try #require(await store.recallQueue(sessionID: sid).first { $0.referenceID == largeRef.referenceID })
        #expect(committed.state == .admissionCommitted, "a bounded projection replaces all-or-nothing")
        let range = try #require(committed.projection)
        #expect(!range.isComplete && range.offsetBytes == 0 && range.lengthBytes < range.totalBytes)
        #expect(range.totalBytes == largePayload.utf8.count)

        // The next assembly is where a range can leak: `activeEntries` re-projects every entry of the
        // causal unit that holds the grant, and each entry has its own authoritative object.
        let bodies = { (view: [ContextEntry]) -> [String: String] in
            var map: [String: String] = [:]
            for entry in view {
                guard case let .toolResult(result) = entry.part, let artifact = result.output.artifactObjectID else { continue }
                map[artifact] = ContextCompactor.content(of: entry.part)
            }
            return map
        }
        for (label, view) in [("admission", admitted), ("next assembly", await compactor.activeEntries(sessionID: sid, canonicalEntries: canonical))] {
            let byArtifact = bodies(view)
            #expect(byArtifact.count == 3, "\(label): every artifact of the unit must still be there: \(byArtifact.count)")
            #expect(byArtifact.values.filter { $0.contains("complete=false") }.count == 1,
                "\(label): exactly the recalled artifact may be bounded: \(byArtifact.values.filter { $0.contains("complete=false") }.count)")
            #expect(byArtifact.values.filter { $0.contains("bytes=\(range.offsetBytes)-\(range.endBytes)") }.count == 1,
                "\(label): the large artifact's byte range may not appear on a sibling")
            for index in [0, 2] {
                let text = try #require(byArtifact[objectIDs[index].rawValue], "\(label): sibling \(index) disappeared")
                #expect(text == String(payloads[index].prefix(600)),
                    "\(label): sibling \(index) must keep its own body, untouched: \(text.utf8.count) bytes")
            }
            let large = try #require(byArtifact[objectIDs[1].rawValue])
            let declared = try #require(parseOccurrence(large), "\(label): the projection must declare its range: \(large.prefix(200))")
            #expect(declared == range, "\(label): the label must be the committed range: \(declared) vs \(range)")
            #expect(large.hasSuffix(String(decoding: Array(largePayload.utf8)[range.offsetBytes..<range.endBytes], as: UTF8.self)),
                "\(label): a projection must end in the bytes its label declares")
        }
    }

    // MARK: - §5 RECALL_PAGINATION_BYTE_EXACT

    @Test("paging a >64KB multilingual payload rebuilds it byte for byte")
    func recallPaginationIsByteExact() async throws {
        let sid = SessionID("paging")
        let store = ECoreObjectStore(configuration: ContextObjectFabricConfiguration(eCorePersistenceEnabled: false))
        var payload = ""
        while payload.utf8.count <= 70 * 1024 { payload += "行\(payload.utf8.count % 997) 上下文🦊token αβγ omega\n" }
        let bytes = Array(payload.utf8)
        #expect(bytes.count > 64 * 1024, "the fixture must really exceed one 64KB window: \(bytes.count)")
        let reference = await store.pageOut(sessionID: sid, content: payload, origin: .toolCall,
            contextOccurrenceID: "occ-page", evictionEpoch: 0, summary: "paged log",
            toolCallID: ToolCallID("call-page"), toolName: "shell")
        let tool = ContextRecallTool(ecoreStore: store, sessionID: sid)
        #expect(await store.configuration.recallMaxBytes == previewLimit,
            "byte-exact paging must be proven against the production bound, not a raised one")

        var assembled = ""
        var offset = 0
        var pages = 0
        var widest = 0
        while offset < bytes.count {
            let answer = try await tool.execute(
                arguments: "{\"id\":\"\(reference.referenceID)\",\"offset\":\(offset),\"limit_bytes\":\(previewLimit)}",
                profile: .workspace)
            let page = try #require(parseSlice(answer), "page at \(offset) has no header: \(answer.prefix(200))")
            #expect(page.total == bytes.count, "the header describes the object, not the page")
            #expect(page.start >= offset, "a page may align inward onto a scalar boundary, never outward")
            #expect(assembled.utf8.count == page.start, "pages must be gapless and non-overlapping at \(offset)")
            #expect(page.length > 0, "an offset inside the object must return bytes")
            #expect(page.length <= previewLimit, "the tool may not exceed its own bound: \(page.length)")
            #expect(page.hasMore == (page.end < bytes.count), "Has More must agree with the range it declares")
            #expect(page.body == String(decoding: bytes[page.start..<page.end], as: UTF8.self),
                "the declared range must be exactly the bytes returned")
            #expect(!page.body.contains("\u{FFFD}"), "no replacement characters at a page boundary")
            assembled += page.body
            widest = max(widest, page.length)
            offset = page.end
            pages += 1
            #expect(pages <= 96, "pagination must terminate")
        }
        #expect(assembled == payload, "\(pages) pages must rebuild the payload exactly")
        #expect(pages >= 4 && widest > 4_096, "and it must actually page: \(pages) pages, widest \(widest)")
    }

    // MARK: - §6 RECALL_CRASH_MATRIX

    @Test("no crash window loses a recall or half-commits one")
    func recallCrashMatrix() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-p8-crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFakeProvider(script: [[.textDelta("ok"), .completed(.stop)]])
        func open() throws -> CoreHost {
            try CoreHost(startupPolicy: .unitTest,
                providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("replay"),
                    contextProfile: ModelContextProfile(contextWindowTokens: 12_000)),
                workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: root.appendingPathComponent("core"),
                permissionDecision: .allow, interactive: false)
        }
        func row(_ store: ECoreObjectStore, _ sid: SessionID, _ referenceID: String) async -> RecallRequest? {
            await store.recallQueue(sessionID: sid).first { $0.referenceID == referenceID }
        }
        func nothingGranted(_ host: CoreHost, _ sid: SessionID) async -> Bool {
            !(await host.compactor.activeEntries(sessionID: sid, canonicalEntries: []))
                .contains { $0.segment == .recalledOccurrence }
        }
        let sid: SessionID
        do {
            let opener = try open()
            await opener.start()
            sid = try await opener.sessionStore.create().id
            await opener.shutdown()
        }
        let wide = "wide projection " + String(repeating: "W", count: 60_000)

        // Window 1: the intent is written, then the process dies before assembly.
        var host = try open(); await host.start()
        var fabric = await host.ecoreStoreRef
        let big = await fabric.pageOut(sessionID: sid, content: wide, origin: .toolCall,
            contextOccurrenceID: "occ-crash", evictionEpoch: 0, summary: "wide",
            toolCallID: ToolCallID("call-crash"), toolName: "shell")
        _ = try await ContextRecallTool(ecoreStore: fabric, sessionID: sid).execute(
            arguments: "{\"id\":\"\(big.referenceID)\",\"admission\":\"occurrence\"}", profile: .workspace)
        await host.shutdown()
        host = try open(); await host.start()
        fabric = await host.ecoreStoreRef
        let pending = try #require(await row(fabric, sid, big.referenceID),
            "a crash between the tool and assembly must not lose the request")
        #expect(pending.isAwaitingAdmission, "the intent must still be owed work: \(pending.state)")
        #expect(pending.state == .requested, "nothing may look prepared before assembly ran: \(pending.state)")
        #expect(await nothingGranted(host, sid), "an uncommitted grant may not reach active context")

        // Window 2: assembly decided, the commit transaction fails. Nothing is applied anywhere.
        await host.persistence?.armFailpoint(.beforeRecallCommit)
        let lost = await host.compactor.admitRequestedRecalls(sessionID: sid, canonicalEntries: [],
                                                             activeEntries: [], hardInputLimit: 3_000)
        let prepared = try #require(await row(fabric, sid, big.referenceID))
        #expect(lost.isEmpty, "a failed transaction may not serve a grant")
        #expect(prepared.state == .admissionPrepared, "prepared work is re-run, not lost: \(prepared.state)")
        #expect(prepared.projection == nil, "no range may be recorded for a grant that never committed")
        #expect(await nothingGranted(host, sid), "the in-memory view must not lead the transaction")
        await host.shutdown()
        host = try open(); await host.start()
        fabric = await host.ecoreStoreRef
        #expect((await row(fabric, sid, big.referenceID))?.isAwaitingAdmission == true,
            "a failed commit must survive a restart as owed work")

        // Window 3: the retry commits a bounded range, then the process dies.
        let granted = await host.compactor.admitRequestedRecalls(sessionID: sid, canonicalEntries: [],
                                                                activeEntries: [], hardInputLimit: 3_000)
        let committed = try #require(await row(fabric, sid, big.referenceID))
        #expect(committed.state == .admissionCommitted)
        let range = try #require(committed.projection, "60KB into a 3K window must be projected as a range")
        #expect(!range.isComplete && range.totalBytes == wide.utf8.count)
        #expect(ContextCompactor.content(of: try #require(granted.first).part).contains("complete=false"))
        await host.shutdown()
        host = try open(); await host.start()
        defer { await host.shutdown() }
        fabric = await host.ecoreStoreRef
        let recovered = try #require(await row(fabric, sid, big.referenceID))
        #expect(recovered.state == committed.state && recovered.projection == range,
            "restart must recover the same range: \(String(describing: recovered.projection)) → \(range)")
        #expect(try #require(await fabric.restore(sessionID: sid, referenceID: big.referenceID)) == wide,
            "the authoritative object is still the complete payload")
        let compactor = await host.compactor
        await compactor.restoreRecallState(sessionID: sid)
        let rebuilt = ContextCompactor.content(of: try #require(await compactor
            .activeEntries(sessionID: sid, canonicalEntries: []).first { $0.segment == .recalledOccurrence }).part)
        #expect(parseOccurrence(rebuilt) == range, "the rebuilt context re-projects the committed range: \(rebuilt.prefix(200))")
        #expect(!rebuilt.contains(wide), "and never re-expands to the whole object")

        // Window 4: a range read after a committed grant neither re-opens nor upgrades it.
        _ = try await ContextRecallTool(ecoreStore: fabric, sessionID: sid).execute(
            arguments: "{\"id\":\"\(big.referenceID)\",\"offset\":40,\"limit_bytes\":256}", profile: .workspace)
        let afterSlice = try #require(await row(fabric, sid, big.referenceID))
        #expect(afterSlice.state == .admissionCommitted && afterSlice.projection == range,
            "a range read must not re-open or upgrade a committed grant: \(String(describing: afterSlice.projection))")
        #expect(afterSlice.admissionMode == .occurrenceProjection,
            "the mode of the grant is the mode that was asked for: \(afterSlice.admissionMode.rawValue)")
    }
}

/// A scripted model that reads the same oversized file once per turn, then in the last turn pages
/// through the archived object and asks for the occurrence itself. Which step of which turn it is
/// comes from `beginTurn`, so the run reads as a conversation rather than as a step counter.
private final class LargeReadReplayProvider: ModelProvider, @unchecked Sendable {
    let recorder = RequestRecorder()
    weak var host: CoreHost?
    var sessionID: SessionID?
    private(set) var finalRequest: ModelRequest?
    private(set) var sliceAnswers: [String] = []
    private var turn = 0
    private var stepInTurn = 0
    private var seenSlices = Set<String>()
    private var chosen: (referenceID: String, markerOffset: Int)?
    private(set) var chosenReferenceID: String?

    var finalCachePlan: CanonicalCachePlan? { finalRequest?.cachePlan }
    var earlyCachePlan: CanonicalCachePlan? { recorder.requests.first?.cachePlan }

    func beginTurn() { turn += 1; stepInTurn = 0 }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        recorder.record(request)
        for result in results(named: "context_recall", in: request.messages)
        where result.content.hasPrefix("[Context Object Slice:") && seenSlices.insert(result.content).inserted {
            sliceAnswers.append(result.content)
        }
        stepInTurn += 1
        var events: [ModelEvent]
        switch (turn, stepInTurn) {
        case (_, 1) where turn <= 4:
            events = [callEvent("read-\(turn)", "read_file", ["path": bigFile]), .completed(.toolCalls)]
        case (5, 1), (5, 2):
            guard let target = await addressed() else {
                events = [.textDelta("还没有可寻址的对象"), .completed(.stop)]
                break
            }
            events = [callEvent("slice-\(stepInTurn)", "context_recall", ["id": target.referenceID,
                "offset": max(0, target.markerOffset + (stepInTurn == 1 ? -64 : 4_096)), "limit_bytes": 4_096]),
                .completed(.toolCalls)]
        case (5, 3):
            guard let target = await addressed() else {
                events = [.textDelta("还没有可寻址的对象"), .completed(.stop)]
                break
            }
            events = [callEvent("occurrence", "context_recall", ["id": target.referenceID,
                "admission": "occurrence", "offset": max(0, target.markerOffset - 64), "limit_bytes": 8_192]),
                .completed(.toolCalls)]
        case (5, 4):
            finalRequest = request
            events = [.textDelta("已恢复中间的标记。"), .completed(.stop)]
        default:
            events = [.textDelta("先看到这里。"), .completed(.stop)]
        }
        let script = events
        return AsyncThrowingStream { c in script.forEach { c.yield($0) }; c.finish() }
    }

    /// The model reads what the archive holds, so the reference is whatever addresses the marker - and
    /// a real model keeps the address it already has rather than re-resolving it every step.
    private func addressed() async -> (referenceID: String, markerOffset: Int)? {
        if let chosen { return chosen }
        guard let host, let sid = sessionID else { return nil }
        let store = await host.ecoreStoreRef
        for reference in await store.references(sessionID: sid) {
            guard let payload = try? await store.restore(sessionID: sid, referenceID: reference.referenceID),
                  payload.contains(marker), let found = payload.range(of: marker) else { continue }
            let target = (reference.referenceID, payload.utf8.distance(from: payload.startIndex, to: found.lowerBound))
            chosen = target
            chosenReferenceID = reference.referenceID
            return target
        }
        return nil
    }
}

/// A scripted model that runs one oversized build-log command, then asks for the byte range its
/// evidence lives in - by the artifact id Core itself published - and then reports.
private final class ShellEvidenceProvider: ModelProvider, @unchecked Sendable {
    let recorder = RequestRecorder()
    private let bigCommand: String
    private var step = 0
    private(set) var requestCarryingSlice: ModelRequest?

    init(bigCommand: String) { self.bigCommand = bigCommand }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        recorder.record(request)
        step += 1
        let artifact = request.messages.flatMap(\.parts).compactMap { part -> String? in
            guard case let .toolResult(result) = part, result.toolName == "shell" else { return nil }
            return result.output.artifactObjectID
        }.last
        let events: [ModelEvent]
        if step == 1 || artifact == nil {
            events = [callEvent("big", "shell", ["command": bigCommand]), .completed(.toolCalls)]
        } else if results(named: "context_recall", in: request.messages).isEmpty {
            events = [callEvent("mid", "context_recall",
                                ["id": artifact ?? "", "offset": 44_000, "limit_bytes": 4_096]), .completed(.toolCalls)]
        } else {
            requestCarryingSlice = request
            events = [.textDelta("找到 MID7F31END。"), .completed(.stop)]
        }
        let script = events
        return AsyncThrowingStream { c in script.forEach { c.yield($0) }; c.finish() }
    }
}
