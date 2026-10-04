import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

/// Phase 3 — Recall durability.
///
/// Every case runs a real `CoreHost` against real SQLite and a real on-disk E-Core, then shuts it
/// down and builds a second host over the same directory. Nothing simulates a restart by
/// re-newing one in-memory object, and telemetry is never used as evidence of durable state.
private let middleMarker = "MIDDURABLE7"

/// The evidence file is 16,420 single-line characters: just past the 16,384 preview limit, so a real
/// preview/payload gap exists while the complete payload stays small enough to fit the headroom a
/// converged P-Core actually has. A short command reading a long file keeps the tool-call entry
/// itself cheap, which is what makes the restored occurrence fit rather than be refused.
private let evidenceName = "evidence.txt"
private var evidenceText: String { String(repeating: "x", count: 16_390) + middleMarker + String(repeating: "y", count: 10) }
/// Distinct content per artifact, so a batch of three really yields three objects and three refs.
private var evidenceNames: [String] { ["evidence.txt", "evidence2.txt", "evidence3.txt"] }
private func padName(_ step: Int) -> String { "pad\(step).txt" }

@Suite(.serialized) struct RecallDurabilityTests {

    // MARK: - fixture

    /// Real session with several truncated artifacts so that eviction, not padding volume, is what
    /// fills P-Core; that leaves the headroom a legitimate occurrence projection needs.
    private struct Live {
        let host: CoreHost
        let sessionID: SessionID
        let workspace: URL
        let references: [ECoreReference]
    }

    private func launch(calls: Int, pads: Int, window: Int = 24_000) async throws -> (CoreHost, SessionID, URL, ScriptedLoopProvider) {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("lx-durable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        for name in evidenceNames {
            try evidenceText.replacingOccurrences(of: middleMarker, with: middleMarker + name)
                .write(to: workspace.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // Distinct padding files: identical repeated commands would be blocked as a no-progress
        // loop, which is a different rule and would mask the durability behaviour under test.
        for step in 1...24 {
            let body = (0..<60).map { "PAD\(step)-\($0)-abcdefghijklmnopqrstuvwxyz0123456789" }.joined(separator: "\n")
            try body.write(to: workspace.appendingPathComponent(padName(step)), atomically: true, encoding: .utf8)
        }
        let provider = ScriptedLoopProvider(calls: calls, pads: pads)
        let host = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake"),
                contextProfile: ModelContextProfile(contextWindowTokens: window)),
            workspaceRoot: try WorkspaceRoot(path: workspace.path),
            dataRoot: workspace.appendingPathComponent("core"),
            permissionDecision: .allow, interactive: false)
        await host.start()
        let sid = try await host.sessionStore.create().id
        provider.sessionID = sid
        return (host, sid, workspace, provider)
    }

    private func sendTurn(_ host: CoreHost, _ sid: SessionID, _ content: String) async throws {
        for try await _ in try await LingXiClient.inProcess(endpoint: host).sendMessage(sessionID: sid, content: content) {}
    }

    private func references(_ host: CoreHost, _ sid: SessionID) async -> [ECoreReference] {
        await (await host.ecoreStoreRef).references(sessionID: sid)
    }

    /// The reference whose authoritative payload is the evidence artifact — the only one whose
    /// restored occurrence can be recognised by the marker past the preview limit.
    private func evidenceReference(_ host: CoreHost, _ sid: SessionID) async -> ECoreReference? {
        let fabric = await host.ecoreStoreRef
        for reference in await fabric.references(sessionID: sid) {
            if let payload = try? await fabric.fetch(sessionID: sid, objectID: reference.objectID),
               payload.contains(middleMarker) { return reference }
        }
        return nil
    }

    // MARK: - Case 1: intent survives a crash before admission

    @Test("a queued occurrence request survives a restart and is still processed")
    func queuedIntentSurvivesRestart() async throws {
        let (host, sid, workspace, provider) = try await launch(calls: 3, pads: 10)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await sendTurn(host, sid, "Collect the build evidence")
        guard let target = await evidenceReference(host, sid) else { Issue.record("fixture produced no paged-out evidence reference"); await host.shutdown(); return }

        // The production tool resolves the reference and records the intent durably...
        let queued = try await ContextRecallTool(ecoreStore: await host.ecoreStoreRef, sessionID: sid)
            .execute(arguments: "{\"id\":\"\(target.referenceID)\",\"admission\":\"occurrence\"}", profile: .workspace)
        #expect(queued.hasPrefix(RecallOutput.occurrence))
        // ...then the process dies before any assembly can act on it.
        await host.shutdown()

        let reopened = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake"),
                contextProfile: ModelContextProfile(contextWindowTokens: 24_000)),
            workspaceRoot: try WorkspaceRoot(path: workspace.path),
            dataRoot: workspace.appendingPathComponent("core"),
            permissionDecision: .allow, interactive: false)
        await reopened.start()
        defer { await reopened.shutdown() }
        defer { provider.reset(forRestart: true) }

        let queue = await (await reopened.ecoreStoreRef).recallQueue(sessionID: sid)
        #expect(queue.contains { $0.referenceID == target.referenceID && $0.admissionMode == .occurrenceProjection },
            "a crash between the tool and the next assembly must not lose the request")

        provider.scriptAnswer()
        try await sendTurn(reopened, sid, "Now show me that occurrence")
        let after = await (await reopened.ecoreStoreRef).recallQueue(sessionID: sid)
        let processed = after.first { $0.referenceID == target.referenceID }
        #expect(processed?.state == .admissionCommitted || processed?.state == .rejected,
            "the restored request must reach a recorded terminal state, never vanish: \(String(describing: processed?.state)) \(String(describing: processed?.reason))")
    }

    // MARK: - Case 2: no half-committed state

    @Test("a failure inside the commit leaves no half-applied grant")
    func failedCommitLeavesNoHalfState() async throws {
        let (host, sid, workspace, provider) = try await launch(calls: 3, pads: 10)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await sendTurn(host, sid, "Collect the build evidence")
        let target = try #require(await evidenceReference(host, sid))
        let residencyBefore = await host.compactor.unitStates(sessionID: sid)

        provider.scriptRecall(id: target.referenceID, admission: "occurrence")
        await host.persistence?.armFailpoint(.beforeRecallCommit)
        try? await sendTurn(host, sid, "Restore that occurrence")   // commit is injected to fail

        let states = await host.compactor.unitStates(sessionID: sid)
        #expect(states.map(\.messageID) == residencyBefore.map(\.messageID),
            "residency must not move when the transaction did not land")
        let queue = await (await host.ecoreStoreRef).recallQueue(sessionID: sid)
        let stuck = queue.first { $0.referenceID == target.referenceID }
        #expect(stuck?.state == .admissionPrepared, "the request must stay reprocessable, not consumed")
        let live = provider.requestsAfterRecall.last
        #expect(live?.messages.contains { $0.segment == .recalledOccurrence } != true,
            "an uncommitted grant must not appear in the model request")
        await host.shutdown()

        let reopened = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake"),
                contextProfile: ModelContextProfile(contextWindowTokens: 24_000)),
            workspaceRoot: try WorkspaceRoot(path: workspace.path),
            dataRoot: workspace.appendingPathComponent("core"),
            permissionDecision: .allow, interactive: false)
        await reopened.start()
        defer { await reopened.shutdown() }
        provider.reset(forRestart: true)
        provider.scriptRecall(id: target.referenceID, admission: "occurrence")
        try await sendTurn(reopened, sid, "Retry that occurrence")
        let committed = await (await reopened.ecoreStoreRef).recallQueue(sessionID: sid).first { $0.referenceID == target.referenceID }
        #expect(committed?.state == .admissionCommitted || committed?.state == .rejected,
            "a restarted prepared request resolves to a recorded outcome")
    }

    // MARK: - Case 3: a committed grant is provider-visible after a restart

    @Test("a committed occurrence is still restored into the next model request after restart")
    func committedOccurrenceSurvivesRestart() async throws {
        let (host, sid, workspace, provider) = try await launch(calls: 3, pads: 10)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await sendTurn(host, sid, "Collect the build evidence")
        let target = try #require(await evidenceReference(host, sid), "fixture must page out the evidence artifact")
        let payload = try #require(await (await host.ecoreStoreRef).fetch(sessionID: sid, objectID: target.objectID))
        let markerStart = try #require(payload.range(of: middleMarker)?.lowerBound, "the marker must exist in the payload")
        let middleOffset = String(payload[..<markerStart]).utf8.count
        #expect(middleOffset > 16_384, "the marker has to live past the preview limit")

        provider.scriptRecall(id: target.referenceID, admission: "occurrence")
        try await sendTurn(host, sid, "Restore that occurrence")
        let committed = await (await host.ecoreStoreRef).recallQueue(sessionID: sid).first { $0.referenceID == target.referenceID }
        #expect(committed?.state == .admissionCommitted,
            "expected a committed grant to test against, got \(String(describing: committed?.state)) \(String(describing: committed?.reason))")
        await host.shutdown()

        let reopened = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake"),
                contextProfile: ModelContextProfile(contextWindowTokens: 24_000)),
            workspaceRoot: try WorkspaceRoot(path: workspace.path),
            dataRoot: workspace.appendingPathComponent("core"),
            permissionDecision: .allow, interactive: false)
        await reopened.start()
        defer { await reopened.shutdown() }
        provider.reset(forRestart: true)
        provider.scriptAnswer()
        try await sendTurn(reopened, sid, "Continue")

        let request = try #require(provider.recorder.requests.last)
        let restored = request.messages.filter { $0.segment == .recalledOccurrence }
        #expect(!restored.isEmpty, "a committed occurrence must still be active after a restart")
        #expect(restored.contains { $0.parts.contains { part in
            if case let .toolResult(result) = part { return result.content.contains(middleMarker) }
            if case let .text(text) = part { return text.contains(middleMarker) }
            return false
        } }, "the restored occurrence carries the authoritative payload, not the preview")
        let chat = String(decoding: try OpenAICompatibleProvider.makeRequestBody(request), as: UTF8.self)
        let responses = String(decoding: try OpenAIResponsesProvider.makeRequestBody(request), as: UTF8.self)
        let anthropic = String(decoding: try AnthropicMessagesProvider.makeRequestBody(request), as: UTF8.self)
        for wire in [chat, responses, anthropic] {
            #expect(wire.contains(middleMarker), "the marker has to reach the provider wire")
        }
    }

    // MARK: - Case 4: every artifact of a batch resolves after restart

    @Test("each reference of a multi-artifact batch maps back to its unit after restart")
    func multiArtifactOccurrenceMappingIsDurable() async throws {
        let (host, sid, workspace, provider) = try await launch(calls: 1, pads: 10, window: 24_000)
        defer { try? FileManager.default.removeItem(at: workspace) }
        provider.tripleBatch = true
        try await sendTurn(host, sid, "Run three big commands in one batch")

        let paged = await references(host, sid)
        let artifactRefs = paged.filter { $0.summary.contains("evidence") }
        #expect(artifactRefs.count >= 2, "one batch holding two truncated artifacts must yield one reference each, got \(artifactRefs.count)")

        let persisted = try #require(await host.persistence?.recallOccurrences(sessionID: sid))
        for reference in artifactRefs {
            #expect(persisted[reference.referenceID]?.isEmpty == false,
                "reference \(reference.referenceID) lost its occurrence mapping")
        }
        let units = Set(persisted[artifactRefs[0].referenceID] ?? [])
        #expect(!units.isEmpty)
        await host.shutdown()

        // A brand new compactor over the same directory is the only way to prove the mapping is not
        // a memory leftover.
        let reopened = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake"),
                contextProfile: ModelContextProfile(contextWindowTokens: 24_000)),
            workspaceRoot: try WorkspaceRoot(path: workspace.path),
            dataRoot: workspace.appendingPathComponent("core"),
            permissionDecision: .allow, interactive: false)
        await reopened.start()
        defer { await reopened.shutdown() }
        let afterRestart = try #require(await reopened.persistence?.recallOccurrences(sessionID: sid))
        for reference in artifactRefs {
            #expect(afterRestart[reference.referenceID] == persisted[reference.referenceID],
                "every reference, not just the primary one, must resolve its unit after a restart")
        }
        #expect(Set(afterRestart.values.flatMap { $0 }) == units.union(Set(afterRestart.values.flatMap { $0 })))
    }

    // MARK: - Case 5: a range read is never upgraded by a restart

    @Test("a consumed slice read does not come back as an occurrence grant")
    func sliceOnlyIsNeverUpgraded() async throws {
        let (host, sid, workspace, provider) = try await launch(calls: 3, pads: 10)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await sendTurn(host, sid, "Collect the build evidence")
        let target = try #require(await evidenceReference(host, sid))

        provider.scriptRecall(id: target.referenceID, admission: nil)   // plain range read
        try await sendTurn(host, sid, "Read the middle of that log")
        let queue = await (await host.ecoreStoreRef).recallQueue(sessionID: sid)
        #expect(queue.allSatisfy { $0.admissionMode == .sliceOnly || $0.admissionMode != .occurrenceProjection })
        #expect(!queue.contains { $0.referenceID == target.referenceID && $0.isCommitted },
            "a range read must not leave a committed grant behind")
        #expect(provider.requestsAfterRecall.last?.messages.contains { $0.segment == .recalledOccurrence } != true)
        await host.shutdown()

        let reopened = try CoreHost(startupPolicy: .unitTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake"),
                contextProfile: ModelContextProfile(contextWindowTokens: 24_000)),
            workspaceRoot: try WorkspaceRoot(path: workspace.path),
            dataRoot: workspace.appendingPathComponent("core"),
            permissionDecision: .allow, interactive: false)
        await reopened.start()
        defer { await reopened.shutdown() }
        provider.reset(forRestart: true)
        provider.scriptAnswer()
        try await sendTurn(reopened, sid, "Continue")
        let after = await (await reopened.ecoreStoreRef).recallQueue(sessionID: sid)
        #expect(!after.contains { $0.referenceID == target.referenceID && $0.isCommitted },
            "restart must not turn a finished slice read into an occurrence admission")
        #expect(provider.recorder.requests.last?.messages.contains { $0.segment == .recalledOccurrence && $0.content.contains(target.referenceID) } != true)
    }
}

/// Drives the model's decisions only: N big shell calls (each truncated), a few tiny pads, and an
/// optional injected `context_recall`. `tripleBatch` puts three calls in one batch.
private final class ScriptedLoopProvider: ModelProvider, @unchecked Sendable {
    let recorder = RequestRecorder()
    private let callCount: Int
    private let padCount: Int
    var sessionID: SessionID?
    var tripleBatch = false
    private var pendingRecall: String?
    private var answerNext = false
    private(set) var requestsAfterRecall: [ModelRequest] = []
    private var sawRecall = false

    init(calls: Int, pads: Int) { callCount = calls; padCount = pads }

    func scriptRecall(id: String, admission: String?) {
        pendingRecall = "{\"id\":\"\(id)\"\(admission.map { ",\"admission\":\"\($0)\"" } ?? ",\"offset\":17000,\"limit_bytes\":8192")}"
        sawRecall = false
        requestsAfterRecall = []
    }

    func scriptAnswer() { pendingRecall = nil; answerNext = true }

    func reset(forRestart: Bool) {
        // A restart must be able to re-issue a recall for a reference it no longer has in view.
        pendingRecall = nil
        answerNext = false
        sawRecall = false
        requestsAfterRecall = []
    }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        if sawRecall { requestsAfterRecall.append(request) }
        recorder.record(request)
        let step = recorder.requests.count
        var events: [ModelEvent]
        if let arguments = pendingRecall, step > 1 {
            sawRecall = true
            events = [call("recall-1", "context_recall", arguments), .completed(.toolCalls)]
            pendingRecall = nil
        } else if tripleBatch && step == 1 {
            events = [readCall("multi-0", evidenceNames[0]), readCall("multi-1", evidenceNames[1]), .completed(.toolCalls)]
        } else if step <= callCount {
            events = [readCall("big-\(step)", evidenceNames[(step - 1) % evidenceNames.count]), .completed(.toolCalls)]
        } else if step <= callCount + padCount {
            events = [call("pad-\(step)", "shell", shellArguments("cat \(padName(step))")), .completed(.toolCalls)]
        } else {
            events = [.textDelta("done"), .completed(.stop)]
        }
        return AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }

    private func shellArguments(_ command: String) -> String {
        try! String(decoding: JSONEncoder().encode(["command": command]), as: UTF8.self)
    }

    /// A `read_file` result is not shrunk by the coding-tool projection the way shell output is, so
    /// its real preview size is what P-Core carries: that is what makes the artifact the unit
    /// eviction reaches for first, and what leaves genuine headroom for a restored occurrence.
    private func readCall(_ id: String, _ path: String) -> ModelEvent {
        call(id, "read_file", try! String(decoding: JSONEncoder().encode(["path": path]), as: UTF8.self))
    }

    private func call(_ id: String, _ tool: String, _ arguments: String) -> ModelEvent {
        .toolCallCompleted(ToolCall(callID: ToolCallID(id), toolID: ToolID(tool), arguments: arguments))
    }
}
