import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

/// Objective progress clears observations; observations do not choose or terminate model actions.
private typealias Outcome = ToolLoopProgressTracker.CallOutcome
private typealias Evidence = ToolLoopProgressTracker.CallOutcome.Evidence
private let blocker69 = "commandFailed:命令以状态 69 退出"

@Suite("Tool loop progress semantics", .serialized) struct ToolLoopProgressSemanticsTests {

    private func failShell(_ command: String, _ error: String = blocker69, exit: Int? = 69) -> [Outcome] {
        [Outcome(callKey: "shell|{\"command\":\"\(command)\"}", succeeded: false, errorMessage: error, exitCode: exit)]
    }
    private let readOK = [Outcome(callKey: "read_file|{\"path\":\"helper.swift\"}", succeeded: true, errorMessage: nil)]
    private let noopWriteOK = [Outcome(callKey: "write_file|{\"path\":\"a.txt\"}", succeeded: true, errorMessage: nil, evidence: .none)]
    private let realWriteOK = [Outcome(callKey: "write_file|{\"path\":\"b.txt\"}", succeeded: true, errorMessage: nil, evidence: .mutation)]
    private let backgroundOK = [Outcome(callKey: "run_background_command|{\"command\":\"make test\"}", succeeded: true, errorMessage: nil, evidence: .attestation)]

    // MARK: - §8 TOOL_LOOP_PROGRESS_MATRIX

    /// Every signal the loop can see after a blocker is open, in one table. The columns are the frozen
    /// rule: TOOL SUCCESS != TASK PROGRESS, so a row may only clear the blocker on an objective fact
    /// about the world. Adding a signal means adding a row, and a row cannot be neutral by accident.
    @Test("each progress signal lands in exactly one column of the matrix")
    func progressSignalMatrix() {
        struct Row {
            let signal: String
            let batches: [[Outcome]]
            /// Whether the run is entitled to call this progress.
            let progress: Bool
            /// How many blockers are still unresolved once the sequence has run.
            let open: Int
        }
        let blocked = failShell("make check")
        let objectivePass: [Outcome] = [Outcome(callKey: "shell|{\"command\":\"make check\"}", succeeded: true, errorMessage: nil)]
        let movedFailureClass = failShell("make check", "commandFailed:syntax error near line 3", exit: 1)
        let otherExitCode = failShell("make check", blocker69, exit: 2)
        let rows: [Row] = [
            Row(signal: "a successful read of another file", batches: [blocked, readOK], progress: false, open: 1),
            Row(signal: "a write of identical bytes", batches: [blocked, noopWriteOK], progress: false, open: 1),
            Row(signal: "a background command that only launched", batches: [blocked, backgroundOK], progress: false, open: 1),
            Row(signal: "a real mutation of an unrelated file", batches: [blocked, realWriteOK], progress: false, open: 1),
            Row(signal: "the blocker reproduced beside successful siblings", batches: [blocked, blocked + readOK + noopWriteOK], progress: false, open: 1),
            Row(signal: "another strategy, same blocker", batches: [blocked, failShell("make -B check")], progress: false, open: 1),
            Row(signal: "the same exit code changed, nothing was fixed", batches: [blocked, otherExitCode], progress: false, open: 1),
            Row(signal: "the failed objective now passes", batches: [blocked, objectivePass], progress: true, open: 0),
            Row(signal: "a real mutation, then a different failure class",
                batches: [blocked, realWriteOK, movedFailureClass], progress: true, open: 1),
            Row(signal: "nothing failed at all", batches: [readOK], progress: false, open: 0),
        ]

        for row in rows {
            var tracker = ToolLoopProgressTracker()
            var progressed = false
            for batch in row.batches {
                if case .progress = tracker.record(batch) { progressed = true }
            }
            #expect(progressed == row.progress, "\(row.signal): progress flag disagrees — \(row.progress) expected")
            #expect(tracker.openBlockerCount == row.open,
                "\(row.signal): open blockers \(tracker.openBlockerCount), expected \(row.open)")

        }
    }

    @Test func repeatsWarnOnceAndNeverAcquireStopAuthority() {
        var tracker = ToolLoopProgressTracker()
        var warnings = 0
        for _ in 0..<40 {
            if case .softWarning = tracker.record(failShell("make check")) { warnings += 1 }
            _ = tracker.record(readOK)
            _ = tracker.record(noopWriteOK)
            _ = tracker.record(realWriteOK)
            _ = tracker.record(backgroundOK)
        }
        #expect(warnings == 1)
        #expect(tracker.monotonicRepeats == 40)
        let text = tracker.projection(availableTokens: 10_000)
        #expect(text?.contains("exit69") == true)
        #expect(tracker.projection(availableTokens: 0) == nil)
        let pass = Outcome(callKey: "shell|{\"command\":\"make check\"}", succeeded: true, errorMessage: nil)
        _ = tracker.record([pass])
        #expect(tracker.projection(availableTokens: 10_000) == nil)
    }

    @Test func boundedStateAndProjectionDoNotGrowWithFailureHistory() {
        var tracker = ToolLoopProgressTracker()
        for i in 0..<1_000 {
            for _ in 0..<3 {
                _ = tracker.record(failShell("command-\(i)", "errorClass\(UnicodeScalar(65 + i % 26)!)" + String(repeating: "x", count: 10_000)))
            }
            #expect(tracker.blockers.count <= ToolLoopProgressTracker.maximumBlockers)
            #expect(tracker.blockers.values.allSatisfy { $0.fingerprints.count <= 8 && $0.shapes.count <= 8 && $0.strategies.count <= 8 })
            if let text = tracker.projection(availableTokens: 10_000) {
                #expect(ConservativeTokenEstimator().estimate(text: text) + 4 <= ToolLoopProgressTracker.maximumProjectionTokens)
            } else { Issue.record("A repeated failure with headroom must remain observable") }
        }
    }

    @Test func unchangedFactsKeepTheSameTailAndEmptyFactsClear() {
        var tracker = ToolLoopProgressTracker()
        for _ in 0..<3 { _ = tracker.record(failShell("test")) }
        let warning = tracker.projection(availableTokens: 10_000)
        _ = tracker.record(failShell("test"))
        #expect(tracker.projection(availableTokens: 10_000) == warning)
        var empty = ToolLoopProgressTracker()
        _ = empty.record(readOK, emptyResults: true)
        #expect(empty.projection(availableTokens: 10_000) == nil)
        _ = empty.record(readOK, emptyResults: true)
        #expect(empty.projection(availableTokens: 10_000)?.contains("empty results") == true)
        _ = empty.record(realWriteOK)
        #expect(empty.projection(availableTokens: 10_000) == nil)
        #expect(ToolLoopProgressTracker().projection(availableTokens: 10_000) == nil)
    }

    @Test func fingerprintAndClusterLayersPreserveExitEvidence() {
        let one = failShell("test", exit: 1)[0]
        let two = failShell("test", exit: 2)[0]
        #expect(ToolLoopProgressTracker.fingerprint(of: one) != ToolLoopProgressTracker.fingerprint(of: two))
        #expect(ToolLoopProgressTracker.cluster(of: one) == ToolLoopProgressTracker.cluster(of: two))
    }

    @Test("evidence kinds come from objective facts about the result, not from the tool's name alone")
    func evidenceKindsAreMechanical() {
        #expect(ToolLoopProgressTracker.evidence(toolName: "read_file", success: true, mutatedPaths: [], exitCode: nil) == .none)
        #expect(ToolLoopProgressTracker.evidence(toolName: "write_file", success: true, mutatedPaths: [], exitCode: nil) == .none,
            "写回相同字节 = no-op")
        #expect(ToolLoopProgressTracker.evidence(toolName: "write_file", success: true, mutatedPaths: ["a.txt"], exitCode: nil) == .mutation)
        #expect(ToolLoopProgressTracker.evidence(toolName: "edit_file", success: true, mutatedPaths: ["a.txt"], exitCode: nil) == .mutation)
        #expect(ToolLoopProgressTracker.evidence(toolName: "run_background_command", success: true, mutatedPaths: [], exitCode: nil) == .attestation)
        #expect(ToolLoopProgressTracker.evidence(toolName: "shell", success: true, mutatedPaths: [], exitCode: 0) == .none)
        #expect(ToolLoopProgressTracker.evidence(toolName: "shell", success: false, mutatedPaths: [], exitCode: 1) == .none,
            "失败调用不贡献进展证据")
    }

    // MARK: - Fingerprints must be stable across noise, distinct across real differences

    @Test("fingerprints ignore line numbers, paths and ids but keep the failure class apart")
    func fingerprintNormalization() {
        func fp(_ message: String, exit: Int?, tool: String = "shell") -> String {
            ToolLoopProgressTracker.fingerprint(of: Outcome(callKey: "\(tool)|{}", succeeded: false, errorMessage: message, exitCode: exit))
        }
        #expect(fp("commandFailed:undefined reference at main.cpp:42", exit: 1)
                == fp("commandFailed:undefined reference at main.cpp:97", exit: 1), "行号不得生成新失败")
        #expect(fp("commandFailed:cannot find /tmp/lx-a1b2c3/x", exit: 1)
                == fp("commandFailed:cannot find /tmp/lx-998877/y", exit: 1), "随机路径不得生成新失败")
        #expect(fp("commandFailed:命令以状态 69 退出", exit: 69) != fp("commandFailed:命令以状态 1 退出", exit: 1),
            "退出码不同是不同失败")
        #expect(fp("permissionDenied:已拒绝 shell", exit: nil) != fp("commandFailed:已拒绝 shell", exit: nil),
            "error code 必须参与 fingerprint")
        #expect(fp("resourceNotFound:missing", exit: nil, tool: "read_file") != fp("resourceNotFound:missing", exit: nil, tool: "grep"),
            "tool family 是目标身份的一部分")
    }

    // MARK: - Real production replay through SessionRuntime

    private func host(_ root: URL, script: [[ModelEvent]]) async throws -> (CoreHost, LingXiClient, ScriptedFakeProvider) {
        let provider = ScriptedFakeProvider(script: script)
        let host = try CoreHost(startupPolicy: .unitTest, providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")),
            workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow, interactive: false)
        await host.start()
        return (host, LingXiClient.inProcess(endpoint: host), provider)
    }

    private func step(_ id: String, _ tool: String, _ arguments: [String: Any]) -> [ModelEvent] {
        let json = String(data: try! JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), encoding: .utf8)!
        return [.toolCallCompleted(ToolCall(callID: ToolCallID(id), toolID: ToolID(tool), arguments: json)), .completed(.toolCalls)]
    }

    @Test("a real session retains failure observations while continuing neutral work")
    func productionReplayWarnsAndContinues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-loop6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "helper\n".write(to: root.appendingPathComponent("helper.txt"), atomically: true, encoding: .utf8)
        try "same\n".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        // Twelve batches offered: the same compile blocker with a new strategy each time, interleaved
        // with reads and no-op rewrites of identical bytes.
        var script: [[ModelEvent]] = []
        for index in 1...12 {
            script.append(step("x\(index)", "shell", ["command": "echo attempt-\(index); exit 69"]))
            script.append(step("r\(index)", "read_file", ["path": "helper.txt"]))
        }
        script.append([.textDelta("全部失败"), .completed(.stop)])

        let (host, client, provider) = try await host(root, script: script)
        defer { await host.shutdown() }
        let sid = try await client.createSession()
        var reason: CoreError?
        do {
            for try await _ in try await client.sendMessage(sessionID: sid, content: "把 app.cpp 编译出来") {}
        } catch let error as CoreError { reason = error }

        let termination = try #require(reason)
        #expect(termination.code == .toolExecutionFailed)
        #expect(provider.recorder.requests.count == script.count)

        let durable = try await host.sessionStore.session(sid)
        let results = durable.messages.flatMap(\.parts).compactMap { part -> ToolResult? in
            if case let .toolResult(result) = part { return result } else { return nil }
        }
        #expect(results.count == 24)
        #expect(results.filter { !$0.success }.count == 12)
        #expect(results.allSatisfy { !$0.content.contains(ToolLoopProgressTracker.heading) })
        #expect(provider.recorder.requests.contains { $0.cachePlan?.volatileTail.ephemeralNotes != nil })

    }

    @Test("a real session that fixes the objective clears the blocker and keeps running")
    func productionReplayResolvesAndContinues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-loop6b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "int main(){ return syntax error here }\n".write(to: root.appendingPathComponent("app.cpp"), atomically: true, encoding: .utf8)

        // One objective, checked by the same command every time: it fails, the model really edits the
        // file, and the identical command then passes. That is the only transition allowed to clear a
        // blocker - fail → pass on the same objective.
        let check = ["command": "grep -q \"return 0\" app.cpp"]
        let script: [[ModelEvent]] = [
            step("f1", "shell", check),
            step("f2", "shell", check),
            step("w1", "write_file", ["path": "app.cpp", "content": "int main(){ return 0; }\n", "overwrite": true]),
            step("p1", "shell", check),
            step("p2", "shell", check),
            [.textDelta("目标已达成"), .completed(.stop)]
        ]
        let (host, client, provider) = try await host(root, script: script)
        defer { await host.shutdown() }
        let sid = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: sid, content: "修好 app.cpp 让它含 return 0") {}

        #expect(provider.recorder.requests.count == script.count, "正常修复不应被打断：\(provider.recorder.requests.count)")
        let durable = try await host.sessionStore.session(sid)
        let results = durable.messages.flatMap(\.parts).compactMap { part -> ToolResult? in
            if case let .toolResult(result) = part { return result } else { return nil }
        }
        #expect(results.filter { $0.success }.count >= 3)
        #expect(results.allSatisfy { !$0.content.contains(ToolLoopProgressTracker.heading) },
            "同一目标已被证明可通过，不应再发出阻塞提示")
        #expect(try String(contentsOf: root.appendingPathComponent("app.cpp"), encoding: .utf8).contains("return 0"))
    }

}
