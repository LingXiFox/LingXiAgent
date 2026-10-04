import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

/// Phase 2 — Reading a byte slice of an E-Core object and re-admitting a whole historical
/// occurrence are two different operations. Every case here drives the real executor, the real
/// SessionRuntime assembly and the real on-disk E-Core; no hand-built `ToolResult`.
///
/// The artifact is deliberately only ~19.7 KB: it must exceed the preview limit (so a real
/// preview/payload gap exists) while the complete payload still fits the input budget, otherwise
/// a successful occurrence projection could not be observed at all.
private let headTag = "HEAD_SLICE_LINE"
private let middleMarker = "MIDSLICE7"
private let bigCommand = #"awk 'BEGIN{for(i=0;i<350;i++)printf "\#(headTag)-%03d-abcdefghijklmnopqrstuvwxyz012345678\n",i; printf "\#(middleMarker)\n"; for(i=0;i<40;i++)printf "TAIL-%03d-abcdefghijklmnopqrstuvwxyz012345678\n",i}'"#
private let padCommandFormat = #"awk 'BEGIN{for(i=0;i<70;i++)printf "PADLINE-%03d-abcdefghijklmnopqrstuvwxyz012345678\n",i}'"#

@Suite("Recall slice and occurrence admission") struct RecallSemanticsTests {

    struct RecallObservation {
        let reference: ECoreReference
        let sliceResult: ToolResult
        let afterRecall: ModelRequest?
        let telemetry: ECoreLifecycleSnapshot
        let payloadBytes: Int
        let totalRequests: Int
        let requestsBefore: Int

        var sliceEntries: [ModelMessage] {
            (afterRecall?.messages ?? []).filter { $0.segment == .recalledOccurrence }
        }
        var recallResultsInRequest: [String] {
            (afterRecall?.messages ?? []).flatMap(\.parts).compactMap { part in
                if case let .toolResult(result) = part, result.toolName == "context_recall" { return result.content } else { return nil }
            }
        }
        /// `Bytes: <start> - <end> of <total>` exactly as the tool reported it.
        var reportedRange: (start: Int, end: Int, total: Int)? {
            let text = sliceResult.content
            guard let expression = try? NSRegularExpression(pattern: "Bytes: (\\d+) - (\\d+) of (\\d+)"),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            func number(_ index: Int) -> Int? {
                guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text) else { return nil }
                return Int(text[range])
            }
            guard let start = number(1), let end = number(2), let total = number(3) else { return nil }
            return (start, end, total)
        }
        /// The payload exactly as the model receives it, after the fixed header.
        var payloadAfterHeader: String? {
            let needle = "--- Content ---\n"
            guard let found = sliceResult.content.range(of: needle) else { return nil }
            return String(sliceResult.content[found.upperBound...])
        }
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lx-recall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Turn 1 pages the big artifact out. Then the given `context_recall` fields are issued
    /// through the real tool executor, and the request assembled afterwards is captured.
    private func recallLab(fields: String, windowTokens: Int = 24_000, padSteps: Int = 15) async throws -> RecallObservation {
        let workspace = try root()
        let provider = PagedArtifactProvider(bigCommand: bigCommand, initialTurnSteps: padSteps)
        let host = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake"),
                contextProfile: ModelContextProfile(contextWindowTokens: windowTokens)),
            workspaceRoot: try WorkspaceRoot(path: workspace.path),
            dataRoot: workspace.appendingPathComponent("core"),
            permissionDecision: .allow, interactive: false)
        await host.start()
        defer {
            await host.shutdown()
            try? FileManager.default.removeItem(at: workspace)
        }
        let sid = try await host.sessionStore.create().id
        provider.sessionID = sid
        let client = LingXiClient.inProcess(endpoint: host)
        for try await _ in try await client.sendMessage(sessionID: sid, content: "Analyse the build log") {}

        let fabric = await host.ecoreStoreRef
        let refs = await fabric.references(sessionID: sid)
        let reference = try #require(refs.first { $0.summary.contains(headTag) },
            "the artifact must be paged out with an occurrence-facing reference")
        let payloadBytes = try #require(await fabric.fetch(sessionID: sid, objectID: reference.objectID)).utf8.count

        provider.recallArguments = "{\"id\":\"\(reference.referenceID)\",\(fields)}"
        provider.recallIssued = false
        let requestsBefore = provider.recorder.requests.count
        for try await _ in try await client.sendMessage(sessionID: sid, content: "Recall part of that log") {}

        let requests = provider.recorder.requests
        let afterRecall = requests.count > requestsBefore + 1 ? requests.last : nil
        let durable = try await host.sessionStore.session(sid)
        let sliceResult = durable.messages.flatMap(\.parts).reversed().compactMap { part -> ToolResult? in
            if case let .toolResult(result) = part, result.toolName == "context_recall" { return result } else { return nil }
        }.first
        let telemetry = await fabric.lifecycleSnapshot(sessionID: sid)
        return RecallObservation(reference: reference, sliceResult: try #require(sliceResult),
            afterRecall: afterRecall, telemetry: telemetry, payloadBytes: payloadBytes,
            totalRequests: requests.count, requestsBefore: requestsBefore)
    }

    // MARK: - Case: an explicitly requested wide slice must not be re-truncated downstream

    @Test("context_recall output keeps its whole payload range and reports it truthfully")
    func wideSliceIsNotGenericallyRetruncated() async throws {
        let observed = try await recallLab(fields: "\"offset\":0,\"limit_bytes\":32768")
        // The tool's own ceiling is recallMaxBytes; nothing may then eat bytes off the payload.
        #expect(observed.sliceResult.output.truncated == false,
            "a recall slice is already bounded by the recall contract, so it must not be marked truncated")
        let range = try #require(observed.reportedRange)
        let payload = try #require(observed.payloadAfterHeader)
        #expect(payload.utf8.count == range.end - range.start,
            "the header must describe exactly the payload the model received")
        #expect(observed.sliceResult.content.contains("Has More:"),
            "no generic policy may cut the tail of a recall result")
    }

    // MARK: - Case: a range read stays a range read

    @Test("a ranged slice does not re-admit the whole occurrence")
    func rangedSliceStaysSliceOnly() async throws {
        let observed = try await recallLab(fields: "\"offset\":17000,\"limit_bytes\":8192")
        #expect(observed.telemetry.recallAdmitted == 0,
            "requesting a byte range is not a request to restore the causal unit")
        #expect(observed.sliceEntries.isEmpty, "the occurrence must not enter active context unasked")
        #expect(observed.recallResultsInRequest.count == 1, "the slice appears exactly once")
        // A slice-only read must not even attempt an occurrence admission, so it can neither be
        // admitted nor rejected: a rejection here proves an unasked-for unit restore was queued.
        #expect(observed.telemetry.events.filter { $0.phase == .recallRejected }.isEmpty,
            "a range read must not queue an occurrence admission that can be rejected")
    }

    // MARK: - Case: a slice that fits must not be rejected because the occurrence does not

    @Test("a slice inside the budget is never rejected for the occurrence's cost")
    func sliceFitsEvenWhenOccurrenceDoesNot() async throws {
        let observed = try await recallLab(fields: "\"offset\":17000,\"limit_bytes\":8192")
        let budgetRejections = observed.telemetry.events.filter {
            $0.phase == .recallRejected && $0.reason?.contains("inputBudgetExceeded") == true
        }
        #expect(budgetRejections.isEmpty, "an 8 KB slice must not fail on the whole occurrence's budget")
        #expect(observed.telemetry.recallResolved == 1)
        #expect(observed.sliceResult.content.contains(middleMarker),
            "the requested middle range has to carry the evidence the preview dropped")
    }

    // MARK: - Case: an explicit occurrence projection uses the authoritative payload

    @Test("an explicit occurrence projection restores from the full payload, not the preview")
    func occurrenceProjectionUsesAuthoritativePayload() async throws {
        // Real paging, real recall tool, real compactor, real PCoreSnapshot, real wire encoders.
        // The budget is passed explicitly here because the live policy caps `hardInputLimit`
        // independently of the model window; whether a grant fits is Case 3's question, and this
        // case pins what a granted projection must be built from.
        let workspace = try root()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = PagedArtifactProvider(bigCommand: bigCommand, initialTurnSteps: 15)
        let host = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake"),
                contextProfile: ModelContextProfile(contextWindowTokens: 24_000)),
            workspaceRoot: try WorkspaceRoot(path: workspace.path),
            dataRoot: workspace.appendingPathComponent("core"),
            permissionDecision: .allow, interactive: false)
        await host.start()
        defer { await host.shutdown() }
        let sid = try await host.sessionStore.create().id
        provider.sessionID = sid
        for try await _ in try await LingXiClient.inProcess(endpoint: host).sendMessage(sessionID: sid, content: "Analyse the build log") {}

        let fabric = await host.ecoreStoreRef
        let reference = try #require(await fabric.references(sessionID: sid).first { $0.summary.contains(headTag) })
        let payload = try #require(await fabric.fetch(sessionID: sid, objectID: reference.objectID))
        let durable = try await host.sessionStore.session(sid)

        let ack = try await ContextRecallTool(ecoreStore: fabric, sessionID: sid)
            .execute(arguments: "{\"id\":\"\(reference.referenceID)\",\"admission\":\"occurrence\"}", profile: .workspace)
        #expect(ack.hasPrefix(RecallOutput.occurrence))
        #expect(!ack.contains(middleMarker), "an occurrence grant must not also ship the payload as a slice")

        let engine = PCoreContextEngine()
        let admitted = await host.compactor.admitRequestedRecalls(sessionID: sid,
            canonicalEntries: await engine.entries(for: durable), activeEntries: [], hardInputLimit: 65_536)
        #expect(await fabric.lifecycleSnapshot(sessionID: sid).recallAdmitted == 1)
        let projected = try #require(admitted.first { $0.segment == .recalledOccurrence },
            "the granted unit must be an active occurrence projection")
        let body = admitted.first { $0.segment == .recalledOccurrence }.map { ContextCompactor.content(of: $0.part) } ?? ""
        #expect(body.contains(middleMarker),
            "the projection is built from the authoritative payload, not from the canonical preview")

        let snapshot = await engine.snapshot(for: durable, activeEntries: admitted, estimatedTokens: 0)
        let messages = snapshot.modelMessages()
        #expect(messages.contains { message in
            message.segment == .recalledOccurrence && message.parts.contains { part in
                if case let .toolResult(result) = part { return result.content.contains(middleMarker) }
                if case let .text(text) = part { return text.contains(middleMarker) }
                return false
            }
        }, "the recalled-occurrence segment must survive into ModelMessage")
        let request = ModelRequest(model: ModelID("replay"), messages: messages)
        let wires = [
            try String(decoding: OpenAICompatibleProvider.makeRequestBody(request), as: UTF8.self),
            try String(decoding: OpenAIResponsesProvider.makeRequestBody(request), as: UTF8.self),
            try String(decoding: AnthropicMessagesProvider.makeRequestBody(request), as: UTF8.self),
        ]
        for wire in wires {
            #expect(wire.contains(middleMarker), "the provider request must carry the restored occurrence")
        }
        // The canonical durable record is untouched by the grant.
        #expect(try await host.sessionStore.session(sid) == durable)
    }
}

/// Turn 1 produces the artifact and enough batches to page it out; later turns issue one
/// model-decided `context_recall` and then answer, so the assembly after the recall is captured.
private final class PagedArtifactProvider: ModelProvider, @unchecked Sendable {
    let recorder = RequestRecorder()
    private let bigCommand: String
    private let initialTurnSteps: Int
    init(bigCommand: String, initialTurnSteps: Int) {
        self.bigCommand = bigCommand
        self.initialTurnSteps = initialTurnSteps
    }
    var recallArguments: String?
    var recallIssued = false
    var sessionID: SessionID?
    private var turnPhase = 0



    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        recorder.record(request)
        let step = recorder.requests.count
        let events: [ModelEvent]
        if turnPhase == 0 {
            if step == 1 {
                events = [shell("big-1", bigCommand), .completed(.toolCalls)]
            } else if step < initialTurnSteps {
                events = [shell("pad-\(step)", padCommandFormat.replacingOccurrences(of: "PADLINE-%03d", with: "PADLINE\(step)-%03d")), .completed(.toolCalls)]
            } else {
                events = [.textDelta("paged"), .completed(.stop)]
                turnPhase = 1
            }
        } else if !recallIssued, let arguments = recallArguments {
            recallIssued = true
            events = [.toolCallCompleted(ToolCall(callID: ToolCallID("recall-1"), toolID: ToolID("context_recall"), arguments: arguments)), .completed(.toolCalls)]
        } else {
            events = [.textDelta("done"), .completed(.stop)]
        }
        return AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }

    private func shell(_ id: String, _ command: String) -> ModelEvent {
        .toolCallCompleted(ToolCall(callID: ToolCallID(id), toolID: ToolID("shell"),
            arguments: try! String(decoding: JSONEncoder().encode(["command": command]), as: UTF8.self)))
    }
}
