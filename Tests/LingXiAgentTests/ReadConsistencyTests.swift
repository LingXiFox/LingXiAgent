import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

/// Phase 5 — read consistency.
///
/// A read-only ToolResult is only true for the instant it was taken. Core may share one execution
/// between identical reads, but it may never carry a read across a mutation of the same resource:
/// the stale value would then be persisted into SessionStore and handed to the model as the current
/// file. Every case drives the real `SessionRuntime` batch scheduler through a real `CoreHost` over
/// a real workspace, and checks four independent things: what is on disk, what each
/// `ToolResult.content` says, how many times the executor actually ran, and what the durable
/// session recorded.
private let staleMarker = "OLDVALUE"
private let freshMarker = "NEWVALUE"
private let evidenceFile = "a.txt"
private let unrelatedFile = "b.txt"

/// Counts real executor invocations per resolved path — independent of the scheduling metadata under
/// test, so "it really ran" is never inferred from the field that claims it ran.
private final class ReadCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var hits: [String: Int] = [:]
    func hit(_ path: String) { lock.lock(); hits[path, default: 0] += 1; lock.unlock() }
    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return hits[path] ?? 0 }
}

/// The built-in read, unchanged, with a counter around it.
private struct CountingReadFileTool: ToolExecutor {
    private let inner: ReadFileTool
    private let counts: ReadCounts

    init(workspace: WorkspaceRoot, counts: ReadCounts) {
        inner = ReadFileTool(workspace: workspace)
        self.counts = counts
    }

    var definition: ToolDefinition { inner.definition }

    func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        try inner.resource(for: arguments, profile: profile)
    }

    func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        try inner.capabilities(for: arguments, profile: profile)
    }

    func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        if let path = try? inner.resource(for: arguments, profile: profile) { counts.hit(path) }
        return try await inner.execute(arguments: arguments, profile: profile)
    }
}

/// The version token a read exposed on its stamp line, if any.
private func versionToken(of content: String) -> String? {
    let head = content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? content
    guard let range = head.range(of: "version=") else { return nil }
    let tail = head[range.upperBound...]
    return tail.components(separatedBy: "]").first.flatMap { $0.isEmpty ? nil : $0 }
}

private func callEvent(_ id: String, _ tool: String, _ arguments: [String: Any]) -> ModelEvent {
    let json = String(data: try! JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), encoding: .utf8)!
    return .toolCallCompleted(ToolCall(callID: ToolCallID(id), toolID: ToolID(tool), arguments: json))
}

private func batch(_ events: [ModelEvent]) -> [ModelEvent] { events + [.completed(.toolCalls)] }
private let answerStep: [ModelEvent] = [.textDelta("done"), .completed(.stop)]

/// The sha256 a read exposed on its stamp line, if any.
private func stamp(of content: String) -> String? {
    let head = content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? content
    guard let range = head.range(of: "sha256=") else { return nil }
    let tail = head[range.upperBound...].prefix(64)
    return tail.count == 64 ? String(tail) : nil
}

/// Any scripted provider whose requests the test can read back.
private protocol RecordingProvider: ModelProvider { var recorder: RequestRecorder { get } }
extension ScriptedFakeProvider: RecordingProvider {}

private struct Lab {
    let host: CoreHost
    let sessionID: SessionID
    let workspace: URL
    let counts: ReadCounts
    let provider: any RecordingProvider

    var evidencePath: String { workspace.appendingPathComponent(evidenceFile).path }

    func disk(_ name: String) -> String {
        (try? String(contentsOf: workspace.appendingPathComponent(name), encoding: .utf8)) ?? "<missing>"
    }

    func persisted() async throws -> [String: ToolResult] {
        let session = try await host.sessionStore.session(sessionID)
        return session.messages.flatMap(\.parts).compactMap { part -> (String, ToolResult)? in
            guard case let .toolResult(result) = part else { return nil }
            return (result.callID.rawValue, result)
        }.reduce(into: [:]) { $0[$1.0] = $1.1 }
    }

    func send(_ content: String) async throws {
        for try await _ in try await LingXiClient.inProcess(endpoint: host).sendMessage(sessionID: sessionID, content: content) {}
    }
}

private func openLab(workspace root: URL, counts: ReadCounts, provider: any RecordingProvider) async throws -> Lab {
    let workspace = try WorkspaceRoot(path: root.path)
    let host = try CoreHost(startupPolicy: .unitTest,
        providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")),
        workspaceRoot: workspace,
        dataRoot: root.appendingPathComponent("core"),
        permissionDecision: .allow,
        toolRegistry: ToolRegistry([
            CountingReadFileTool(workspace: workspace, counts: counts),
            WriteFileTool(workspace: workspace),
            EditFileTool(workspace: workspace),
            ListDirectoryTool(workspace: workspace),
            ShellTool(workspace: workspace)
        ]),
        interactive: false)
    await host.start()
    return Lab(host: host, sessionID: try await host.sessionStore.create().id, workspace: root,
               counts: counts, provider: provider)
}

@Suite(.serialized) struct ReadConsistencyTests {

    private func lab(script: [[ModelEvent]], body: String = staleMarker + "\n") async throws -> Lab {
        let counts = ReadCounts()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try body.write(to: root.appendingPathComponent(evidenceFile), atomically: true, encoding: .utf8)
        return try await openLab(workspace: root, counts: counts, provider: ScriptedFakeProvider(script: script))
    }

    // MARK: - Case 1: sharing is allowed while nothing has changed the resource

    @Test("identical reads in one batch share a single execution")
    func duplicateReadsShareWhenNothingChanged() async throws {
        let lab = try await lab(script: [
            batch([callEvent("r1", "read_file", ["path": evidenceFile]),
                   callEvent("r2", "read_file", ["path": evidenceFile])]),
            answerStep
        ])
        defer { try? FileManager.default.removeItem(at: lab.workspace) }
        try await lab.send("read it twice")
        let results = try await lab.persisted()
        let first = try #require(results["r1"]), second = try #require(results["r2"])

        #expect(lab.counts.count(lab.evidencePath) == 1,
            "no mutation sits between them, so one execution must serve both: \(lab.counts.count(lab.evidencePath)) runs")
        #expect(second.metadata["sharedRead"] == "true")
        #expect(first.content.contains(staleMarker) && second.content.contains(staleMarker))
    }

    // MARK: - Case 2: a file mutation must end the read's epoch

    @Test("a read after write_file of the same file really re-executes and returns the new bytes")
    func writeFileInvalidatesEarlierRead() async throws {
        let lab = try await lab(script: [
            batch([callEvent("r1", "read_file", ["path": evidenceFile]),
                   callEvent("w1", "write_file", ["path": evidenceFile, "content": freshMarker + "\n", "overwrite": true]),
                   callEvent("r2", "read_file", ["path": evidenceFile])]),
            answerStep
        ])
        defer { try? FileManager.default.removeItem(at: lab.workspace) }
        try await lab.send("read, replace, read again")
        let results = try await lab.persisted()
        let before = try #require(results["r1"]), after = try #require(results["r2"])

        #expect(lab.counts.count(lab.evidencePath) == 2,
            "the second read must be a real execution, not the first one's copy: \(lab.counts.count(lab.evidencePath)) runs")
        #expect(after.metadata["sharedRead"] == nil, "a result behind a mutation may not be labelled a shared read: \(after.metadata)")
        #expect(before.content.contains(staleMarker), "the read taken before the write must still see the old bytes")
        #expect(after.content.contains(freshMarker) && !after.content.contains(staleMarker),
            "the read after the write must see the new bytes: \(after.content.prefix(200))")
        #expect(lab.disk(evidenceFile) == freshMarker + "\n")
    }

    // MARK: - Case 3: a mutation Core cannot attribute to a path

    @Test("a read after a shell command that rewrote the file really re-executes")
    func shellMutationInvalidatesEarlierRead() async throws {
        let lab = try await lab(script: [
            batch([callEvent("r1", "read_file", ["path": evidenceFile]),
                   callEvent("s1", "shell", ["command": "printf '\(freshMarker)\\n' > \(evidenceFile)"]),
                   callEvent("r2", "read_file", ["path": evidenceFile])]),
            answerStep
        ])
        defer { try? FileManager.default.removeItem(at: lab.workspace) }
        try await lab.send("read, rewrite by shell, read again")
        let results = try await lab.persisted()
        let after = try #require(results["r2"])

        #expect(lab.counts.count(lab.evidencePath) == 2,
            "an opaque mutation ends the read epoch: \(lab.counts.count(lab.evidencePath)) executions")
        #expect(after.metadata["sharedRead"] == nil)
        #expect(after.content.contains(freshMarker) && !after.content.contains(staleMarker),
            "the read after the shell rewrite must be the disk truth: \(after.content.prefix(200))")
        #expect(lab.disk(evidenceFile) == freshMarker + "\n")
    }

    // MARK: - Case 4: invalidation is scoped to the resource

    @Test("a mutation of an unrelated file does not force a repeat read to run again")
    func unrelatedMutationKeepsSharing() async throws {
        let lab = try await lab(script: [
            batch([callEvent("r1", "read_file", ["path": evidenceFile]),
                   callEvent("w1", "write_file", ["path": unrelatedFile, "content": "unrelated\n"]),
                   callEvent("r2", "read_file", ["path": evidenceFile])]),
            answerStep
        ])
        defer { try? FileManager.default.removeItem(at: lab.workspace) }
        try await lab.send("read a, write b, read a")
        let results = try await lab.persisted()
        let write = try #require(results["w1"]), second = try #require(results["r2"])

        #expect(write.success, "the unrelated write must still run: \(write.error?.message ?? "")")
        #expect(lab.disk(unrelatedFile) == "unrelated\n")
        #expect(lab.counts.count(lab.evidencePath) == 1,
            "nothing touched a.txt, so sharing must survive: \(lab.counts.count(lab.evidencePath)) executions")
        #expect(second.metadata["sharedRead"] == "true")
        #expect(second.content.contains(staleMarker))
    }

    @Test("a directory listing is not shared across a write into that directory")
    func directoryReadIsInvalidatedByAWriteInsideIt() async throws {
        let lab = try await lab(script: [
            batch([callEvent("l1", "list_directory", ["path": "."]),
                   callEvent("w1", "write_file", ["path": "c.txt", "content": "new entry\n"]),
                   callEvent("l2", "list_directory", ["path": "."])]),
            answerStep
        ])
        defer { try? FileManager.default.removeItem(at: lab.workspace) }
        try await lab.send("list, add a file, list again")
        let results = try await lab.persisted()
        let first = try #require(results["l1"]), second = try #require(results["l2"])

        #expect(!first.content.contains("c.txt"), "the listing taken before the write cannot show the new file")
        #expect(second.content.contains("c.txt"), "a listing of a directory is a listing of everything under it: \(second.content.prefix(300))")
        #expect(second.metadata["sharedRead"] == nil, "the second listing must be its own execution")
    }

    // MARK: - Case 5: across model steps the same rule holds
    @Test("a read in a later step returns the bytes a previous step wrote")
    func readAcrossStepsReturnsDiskTruth() async throws {
        let lab = try await lab(script: [
            batch([callEvent("r1", "read_file", ["path": evidenceFile])]),
            batch([callEvent("w1", "write_file", ["path": evidenceFile, "content": freshMarker + "\n", "overwrite": true])]),
            batch([callEvent("r2", "read_file", ["path": evidenceFile])]),
            answerStep
        ])
        defer { try? FileManager.default.removeItem(at: lab.workspace) }
        try await lab.send("read, then replace, then read in a later step")
        let results = try await lab.persisted()
        let after = try #require(results["r2"])

        #expect(lab.counts.count(lab.evidencePath) == 2)
        #expect(after.content.contains(freshMarker) && !after.content.contains(staleMarker),
            "cross-step read must be disk truth: \(after.content.prefix(200))")
    }

    // MARK: - Case 6: no stale read may survive into what the model is next shown

    @Test("neither the durable record nor the next provider request carries a stale read")
    func noStaleReadIsPersisted() async throws {
        let lab = try await lab(script: [
            batch([callEvent("r1", "read_file", ["path": evidenceFile]),
                   callEvent("w1", "write_file", ["path": evidenceFile, "content": freshMarker + "\n", "overwrite": true]),
                   callEvent("r2", "read_file", ["path": evidenceFile])]),
            answerStep
        ])
        defer { try? FileManager.default.removeItem(at: lab.workspace) }
        try await lab.send("read, replace, read")
        let recorded = try #require((try await lab.persisted())["r2"])

        #expect(!recorded.content.contains(staleMarker), "durable history must not hold a stale read: \(recorded.content.prefix(200))")
        #expect(recorded.content.contains(freshMarker))

        // The wire the model was shown after the batch must agree with the durable record.
        let lastRequest = try #require(lab.provider.recorder.requests.last)
        let visible = lastRequest.messages.flatMap(\.parts).compactMap { part -> String? in
            if case let .toolResult(result) = part, result.callID == ToolCallID("r2") { return result.content } else { return nil }
        }
        let shown = try #require(visible.last)
        #expect(shown.contains(freshMarker) && !shown.contains(staleMarker),
            "the model must not be handed the pre-mutation bytes as the current file: \(shown.prefix(200))")
    }

    // MARK: - Case 7: a whole-file read must expose a stamp write_file accepts

    @Test("read_file's stamp is accepted by write_file as expected_hash")
    func wholeFileReadExposesWriteVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try (staleMarker + "\n").write(to: root.appendingPathComponent(evidenceFile), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let lab = try await openLab(workspace: root, counts: ReadCounts(), provider: StampFollowingProvider(next: freshMarker + "\n"))
        try await lab.send("read the file, then rewrite it using the stamp you were given")
        let results = try await lab.persisted()
        let read = try #require(results["read-1"])

        #expect(read.success)
        #expect(stamp(of: read.content) != nil,
            "a whole-file read must expose a version/hash the model can quote: \(read.content.prefix(200))")
        // What the model is actually shown must carry the same stamp: projection sits between the tool
        // and the wire, and a hash mangled on the way is a guard the model cannot use.
        let shownToModel = try #require(lab.provider.recorder.requests.dropFirst().first)
            .messages.flatMap(\.parts).compactMap { part -> String? in
                if case let .toolResult(result) = part, result.callID == ToolCallID("read-1") { return result.content } else { return nil }
            }.first
        #expect(shownToModel.flatMap(stamp(of:)) == sha256Hex(staleMarker + "\n"),
            "the stamp must survive Context Assembly: \(shownToModel?.prefix(200) ?? "no read result on the wire")")
        let write = try #require(results["write-1"])
        #expect(write.success, "quoting the read's stamp must satisfy write_file: \(write.error?.message ?? "no error")")
        #expect(lab.disk(evidenceFile) == freshMarker + "\n")
    }

    // MARK: - Case 8: the guard stays a guard

    @Test("read_file's version token is accepted by edit_file as expected_version")
    func wholeFileReadExposesVersionToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-stamp3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try (staleMarker + "\n").write(to: root.appendingPathComponent(evidenceFile), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let lab = try await openLab(workspace: root, counts: ReadCounts(), provider: VersionGuardProvider())
        try await lab.send("read the file, then edit it using the version you were given")
        let results = try await lab.persisted()
        let read = try #require(results["read-1"])

        #expect(versionToken(of: read.content) != nil,
            "the stamp must carry a version the model can quote: \(read.content.prefix(200))")
        let edit = try #require(results["edit-1"])
        #expect(edit.success, "quoting the read's version must satisfy edit_file: \(edit.error?.message ?? "no error")")
        #expect(lab.disk(evidenceFile) == freshMarker + "\n")
    }

    @Test("a stamp that no longer matches is still refused, and a rejected write leaves the disk alone")
    func optimisticConcurrencyGuardStaysEnforced() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-stamp2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try (staleMarker + "\n").write(to: root.appendingPathComponent(evidenceFile), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let lab = try await openLab(workspace: root, counts: ReadCounts(), provider: StampSequenceProvider())
        try await lab.send("read, write with the stamp, then write again with that same stamp")
        let results = try await lab.persisted()
        let firstWrite = try #require(results["write-1"]), staleWrite = try #require(results["write-2"])

        #expect(firstWrite.success, "the stamp the read returned must be accepted: \(firstWrite.error?.message ?? "")")
        #expect(!staleWrite.success && staleWrite.error?.code == CoreError.Code.contentChanged.rawValue,
            "a stamp that no longer describes the file must still be refused: \(String(describing: staleWrite.error))")
        #expect(lab.disk(evidenceFile) == freshMarker + "\n", "a rejected write must not touch the disk")
    }

    // MARK: - The wave rules, stated once as data

    @Test("read sharing follows the resource, not the tool name")
    func waveRules() {
        let fileA = "/ws/a.txt", fileB = "/ws/b.txt", dir = "/ws"
        func r(_ resource: String) -> ToolRuntime.ToolBatchEffect { .readOnly(resource: resource) }
        func w(_ targets: String...) -> ToolRuntime.ToolBatchEffect { .mutation(targets: targets) }
        func waves(_ effects: [ToolRuntime.ToolBatchEffect]) -> [Int] { SessionRuntime.readSharingWaves(for: effects) }

        #expect(waves([r(fileA), r(fileA)]) == [0, 0], "identical reads with nothing between them share")
        #expect(waves([r(fileA), w(fileA), r(fileA)]) == [0, 1, 2], "a write of the same file ends the epoch for both sides")
        #expect(waves([r(fileA), w(fileB), r(fileA)]) == [0, 0, 0], "an unrelated write must not over-invalidate")
        #expect(waves([r(fileA), .opaqueMutation, r(fileB)]) == [0, 1, 2], "an unattributable mutation is a barrier")
        #expect(waves([r(fileA), r(fileB), .opaqueMutation]) == [0, 0, 1], "a trailing barrier costs nothing")
        #expect(waves([r(dir), w(fileA), r(dir)]) == [0, 1, 2], "a directory read covers everything under it")
        #expect(waves([.neutral, w(fileA), .neutral]) == [0, 0, 0], "a read with no workspace resource has no file epoch")
        #expect(waves([w(fileA), w(fileA)]) == [0, 1], "two writes of one file keep the model's order")
    }
}

/// read a.txt, then write quoting the hash Core handed back.
private final class StampFollowingProvider: RecordingProvider, @unchecked Sendable {
    let recorder = RequestRecorder()
    private let content: String
    private var wrote = false

    init(next content: String) { self.content = content }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        recorder.record(request)
        var events: [ModelEvent]
        if recorder.requests.count == 1 {
            events = [callEvent("read-1", "read_file", ["path": evidenceFile]), .completed(.toolCalls)]
        } else if let hash = readHash(in: request), !wrote {
            wrote = true
            events = [callEvent("write-1", "write_file", ["path": evidenceFile, "content": content, "expected_hash": hash]), .completed(.toolCalls)]
        } else {
            events = answerStep
        }
        return AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }
}

/// read → write (stamp) → write again (the same, now stale stamp) → answer.
private final class StampSequenceProvider: RecordingProvider, @unchecked Sendable {
    let recorder = RequestRecorder()
    private var emitted = 0

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        recorder.record(request)
        emitted += 1
        let hash = readHash(in: request) ?? ""
        var events: [ModelEvent]
        switch emitted {
        case 1: events = [callEvent("read-1", "read_file", ["path": evidenceFile]), .completed(.toolCalls)]
        case 2: events = [callEvent("write-1", "write_file", ["path": evidenceFile, "content": freshMarker + "\n", "expected_hash": hash]), .completed(.toolCalls)]
        case 3: events = [callEvent("write-2", "write_file", ["path": evidenceFile, "content": "THIRDFILE\n", "expected_hash": hash]), .completed(.toolCalls)]
        default: events = answerStep
        }
        return AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }
}

/// The stamp of the read the model was shown. The second write quotes it deliberately: the file has
/// moved on since, which is exactly what optimistic concurrency must catch.
private func readContent(in request: ModelRequest) -> String? {
    for message in request.messages {
        for part in message.parts {
            if case let .toolResult(result) = part, result.toolName == "read_file" { return result.content }
        }
    }
    return nil
}

private func readHash(in request: ModelRequest) -> String? {
    readContent(in: request).flatMap(stamp(of:))
}

/// read a.txt, then edit it quoting the version token Core handed back.
private final class VersionGuardProvider: RecordingProvider, @unchecked Sendable {
    let recorder = RequestRecorder()
    private var edited = false

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        recorder.record(request)
        var events: [ModelEvent]
        if recorder.requests.count == 1 {
            events = [callEvent("read-1", "read_file", ["path": evidenceFile]), .completed(.toolCalls)]
        } else if let version = readContent(in: request).flatMap(versionToken(of:)), !edited {
            edited = true
            events = [callEvent("edit-1", "edit_file", [
                "path": evidenceFile, "old_string": staleMarker, "new_string": freshMarker, "expected_version": version
            ]), .completed(.toolCalls)]
        } else {
            events = answerStep
        }
        return AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }
}
