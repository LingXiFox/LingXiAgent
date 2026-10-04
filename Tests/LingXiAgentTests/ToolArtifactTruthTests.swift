import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

/// Phase 1 — Authoritative Tool Artifact truth.
///
/// Everything here is produced by the real executor, the real SessionRuntime, the real
/// Context Assembly and the real on-disk E-Core. No `ToolResult(content: hugePayload)`.
///
/// The contract under test (Docs/Decisions/PE-Core-Git-Semantics-Freeze-2026-09-30.md §8/§9):
/// page-out writes the *complete* payload into E-Core, gets a stable ECoreObjectID, and
/// Exact Restore resolves reference → that object. A model-facing reference must therefore
/// point at the authoritative raw output, never at a re-derived copy of the bounded preview.
private let headTag = "HEAD_ARTIFACT_LINE"
private let middleMarker = "MID7F31END"
private let bigCommand = #"awk 'BEGIN{for(i=0;i<800;i++)printf "\#(headTag)-%04d-abcdefghijklmnopqrstuvwxyz0123456789\n",i; printf "\#(middleMarker)\n"; for(i=0;i<80;i++)printf "TAIL-%04d-abcdefghijklmnopqrstuvwxyz0123456789\n",i}'"#
private let padCommand = #"awk 'BEGIN{for(i=0;i<70;i++)printf "PADLINE-%02d-abcdefghijklmnopqrstuvwxyz0123456789\n",i}'"#

@Suite("Tool artifact authoritative truth") struct ToolArtifactTruthTests {

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lx-artifact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("model-facing ref resolves to the full raw payload, one object per artifact")
    func authoritativeArtifactRefServesMiddleEvidence() async throws {
        let workspace = try root()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let provider = ArtifactReplayProvider()
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
        let client = LingXiClient.inProcess(endpoint: host)
        for try await _ in try await client.sendMessage(sessionID: sid, content: "Analyse the build log and recall the middle of the first log") {}

        // 1. The durable ToolResult is a bounded preview; the authoritative bytes live behind it.
        let durable = try await host.sessionStore.session(sid)
        let preview = try #require(durable.messages.flatMap(\.parts).compactMap { part -> ToolResult? in
            if case let .toolResult(result) = part, result.toolName == "shell", result.success,
               result.content.contains(headTag) { return result } else { return nil }
        }.first)
        #expect(preview.output.truncated, "raw output exceeds the preview limit, so it must be marked truncated")
        let blobRef = try #require(preview.continuation ?? preview.output.outputBlobRef)
        let raw = try #require(await host.toolRuntimeRef.archivedOutput(blobRef))
        #expect(raw.utf8.count > preview.content.utf8.count)
        let declaredID = try #require(preview.output.artifactObjectID,
            "a truncated result must name the authoritative payload it is only a preview of")
        #expect(declaredID == ContextObjectID.identify(content: raw).rawValue,
            "authoritative identity is content-addressed over the raw payload")
        let artifactID = try ContextObjectID(declaredID)

        // 2. A model-facing reference must resolve to the authoritative payload.
        let fabric = await host.ecoreStoreRef
        let refs = await fabric.references(sessionID: sid)
        let exact = try #require(refs.first { $0.objectID == artifactID },
            "an occurrence-facing reference must be bound to the content-addressed raw payload")
        let restored = try #require(await fabric.restore(sessionID: sid, referenceID: exact.referenceID))
        #expect(restored.utf8.count == raw.utf8.count,
            "Exact Restore must return the authoritative payload, not an envelope re-derived from the preview")

        // 3. The middle evidence is reachable through that reference at its real raw offset.
        let markerRange = try #require(raw.range(of: middleMarker))
        let middleOffset = String(raw[..<markerRange.lowerBound]).utf8.count
        #expect(middleOffset > preview.content.utf8.count, "the marker must sit past the preview")
        let slice = try #require(await fabric.recall(sessionID: sid, objectID: exact.objectID,
            offsetBytes: middleOffset, limitBytes: 8_192))
        #expect(slice.content.contains(middleMarker), "recall of the middle range must return what the preview dropped")

        // 4. No competing recall truth: the bounded preview must never become a second payload.
        let previewDerivedID = ContextObjectID.generate(toolName: "shell", callID: preview.callID, content: preview.content)
        #expect(await fabric.hasObject(sessionID: sid, objectID: previewDerivedID) == false,
            "the bounded preview must never be objectized as a second E-Core truth")
        #expect(refs.filter { $0.objectID == previewDerivedID }.isEmpty)

        // 5. One artifact, one object: nothing else in E-Core holds the same bytes.
        let objectsDir = await fabric.baseDirectory.appendingPathComponent(sid.rawValue).appendingPathComponent("objects")
        let payloadFiles = ((try? FileManager.default.contentsOfDirectory(at: objectsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" }
        #expect(payloadFiles.contains { $0.deletingPathExtension().lastPathComponent == artifactID.rawValue },
            "the authoritative payload is stored under its content-addressed id")
        let sameSizeObjects = payloadFiles.filter { url in
            ((try? url.resourceValues(forKeys: [URLResourceKey.fileSizeKey]))?.fileSize ?? -1) == raw.utf8.count
        }
        #expect(sameSizeObjects.count == 1, "a single artifact must not be stored twice under two identities")

        // 6. Canonical history is untouched.
        let after = try await host.sessionStore.session(sid)
        #expect(after.messages.contains { $0.parts.contains(.toolResult(preview)) },
            "recall must not rewrite canonical history")
    }
}

private extension String {
    var utf8Count: Int { utf8.count }
}

/// Scripts only the model's decisions. Everything between the calls is production code.
private final class ArtifactReplayProvider: ModelProvider, @unchecked Sendable {
    let recorder = RequestRecorder()
    var sessionID: SessionID?
    var count: Int { recorder.requests.count }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        recorder.record(request)
        let step = recorder.requests.count
        let events: [ModelEvent]
        if step == 1 {
            events = [.toolCallCompleted(shell("big-1", bigCommand)), .completed(.toolCalls)]
        } else if step <= 14 {
            let pad = padCommand.replacingOccurrences(of: "PADLINE-%02d", with: "PADLINE\(step)-%02d")
            events = [.toolCallCompleted(shell("pad-\(step)", pad)), .completed(.toolCalls)]
        } else {
            events = [.textDelta("done"), .completed(.stop)]
        }
        return AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }

    private func shell(_ id: String, _ command: String) -> ToolCall {
        ToolCall(callID: ToolCallID(id), toolID: ToolID("shell"),
                 arguments: try! String(decoding: JSONEncoder().encode(["command": command]), as: UTF8.self))
    }
}
