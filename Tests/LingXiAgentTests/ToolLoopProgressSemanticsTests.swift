import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

/// Phase 6 — TOOL SUCCESS != TASK PROGRESS.
///
/// The loop rule that shipped before this phase reset its blocker state whenever a batch contained
/// any successful call. A model stuck on one failure could therefore be kept alive forever by
/// reading a file, or by rewriting the same bytes: `fail X → read ok → fail X → no-op write ok →
/// fail X` was reported as progress three times over. These cases pin the mechanical rule set that
/// replaces it: a blocker is tracked per normalized failure fingerprint, it accumulates monotonically
/// across interleaved successes and across strategy changes, and only an objective signal - the same
/// objective succeeding, or a genuine failure-class change after a real workspace mutation - clears it.
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

    // MARK: - Case 1: a read between two identical failures is not progress

    @Test("a successful read between repeated failures neither clears nor softens the blocker")
    func readSuccessDoesNotClearBlocker() {
        var tracker = ToolLoopProgressTracker()
        var verdicts: [ToolLoopProgressTracker.Verdict] = []
        for _ in 0..<3 {
            verdicts += [tracker.record(failShell("g++ app.cpp")), tracker.record(readOK)]
        }
        #expect(verdicts.allSatisfy { if case .progress = $0 { return false } else { return true } },
            "a read attests to nothing about a compile blocker: \(verdicts)")
        #expect(verdicts.contains { if case .hardStop = $0 { return true } else { return false } },
            "三次同样失败之间穿插读，必须已经硬终止：\(verdicts)")
    }

    // MARK: - Case 2: rewriting the same bytes is a no-op, not progress

    @Test("a no-op write between repeated failures does not clear the blocker")
    func noopWriteDoesNotClearBlocker() {
        var tracker = ToolLoopProgressTracker()
        var verdicts: [ToolLoopProgressTracker.Verdict] = []
        for _ in 0..<3 {
            verdicts += [tracker.record(failShell("npm test")), tracker.record(noopWriteOK)]
        }
        #expect(verdicts.allSatisfy { if case .progress = $0 { return false } else { return true } },
            "相同字节写回是 neutral：\(verdicts)")
        #expect(verdicts.contains { if case .hardStop = $0 { return true } else { return false } },
            "no-op 写不能把三次同样失败洗成进展：\(verdicts)")
    }

    // MARK: - Case 3: a real mutation of something unrelated is still not progress

    @Test("an unrelated real mutation does not clear the blocker")
    func unrelatedMutationDoesNotClearBlocker() {
        var tracker = ToolLoopProgressTracker()
        var verdicts: [ToolLoopProgressTracker.Verdict] = []
        for _ in 0..<3 {
            verdicts += [tracker.record(failShell("pytest tests/test_login.py")), tracker.record(realWriteOK)]
        }
        #expect(verdicts.allSatisfy { if case .progress = $0 { return false } else { return true } },
            "文件变了本身不是进展，只有原目标不再复现才是：\(verdicts)")
        #expect(tracker.openBlockerCount == 1)
        #expect(verdicts.contains { if case .hardStop = $0 { return true } else { return false } },
            "无关改动不得把 blocker 洗白：\(verdicts)")
    }

    // MARK: - Case 4: changing strategy is exploration, and exploration is not resolution

    @Test("different strategies under one blocker warn once, keep accumulating, then stop")
    func strategyChangeDoesNotResetBlocker() {
        var tracker = ToolLoopProgressTracker()
        var warnings = 0
        var verdicts: [ToolLoopProgressTracker.Verdict] = []
        for command in ["g++ a.cpp", "clang++ a.cpp", "gcc a.cpp", "cc a.cpp", "c++ a.cpp", "zig c++ a.cpp"] {
            verdicts.append(tracker.record(failShell(command)))
            if case .softWarning = verdicts.last { warnings += 1 }
        }
        #expect(warnings == 1, "同一 blocker 只提示一次：\(verdicts)")
        guard case let .hardStop(kind, message) = verdicts.last else {
            Issue.record("策略变化不得无限续期")
            return
        }
        #expect(kind == .clusterAfterWarning)
        #expect(tracker.distinctStrategies >= 6, "策略数应如实记录：\(tracker.distinctStrategies)")
        #expect(message.contains("69"), "终止原因要带上 fingerprint：\(message)")
    }

    @Test("the same failure keeps counting even when other strategies succeed alongside it")
    func successfulSiblingDoesNotClearBlocker() {
        var tracker = ToolLoopProgressTracker()
        let batch = failShell("make check") + readOK + noopWriteOK
        _ = tracker.record(batch)
        _ = tracker.record(batch)
        guard case .hardStop = tracker.record(batch) else {
            Issue.record("同批次的成功 sibling 不能抹掉未解决的失败")
            return
        }
    }

    // MARK: - Case 5: what really is progress

    @Test("the same objective passing after failing is objective progress")
    func verificationPassClearsBlocker() {
        var tracker = ToolLoopProgressTracker()
        _ = tracker.record(failShell("npm test"))
        _ = tracker.record(readOK)
        let pass = tracker.record([Outcome(callKey: "shell|{\"command\":\"npm test\"}", succeeded: true, errorMessage: nil, evidence: .none)])
        guard case .progress = pass else {
            Issue.record("同一目标 fail → pass 是唯一能证明阻塞消失的强信号：\(pass)")
            return
        }
        #expect(tracker.openBlockerCount == 0)
    }

    @Test("a failure-class change after a real mutation clears the old blocker")
    func genuineFixChangesFailureClass() {
        var tracker = ToolLoopProgressTracker()
        _ = tracker.record(failShell("pytest tests/test_login.py", "commandFailed:NameError: name 'session' is not defined", exit: 1))
        _ = tracker.record(realWriteOK)
        let next = tracker.record(failShell("pytest tests/test_login.py", "commandFailed:AssertionError: expected 200 got 500", exit: 1))
        #expect(tracker.openBlockerCount == 1, "旧 blocker 已被证明消失：\(next)")
        if case .progress = next {} else { Issue.record("修改后失败类别实质变化应记为进展：\(next)") }
    }

    @Test("two exit codes on one objective are two observations of one unresolved cluster")
    func alternationWithoutMutationDoesNotClear() {
        var tracker = ToolLoopProgressTracker()
        var verdicts: [ToolLoopProgressTracker.Verdict] = []
        var warnings = 0
        for index in 0..<9 {
            let message = index % 2 == 0
                ? "commandFailed:命令以状态 1 退出"
                : "commandFailed:命令以状态 2 退出"
            verdicts.append(tracker.record(failShell("echo attempt-\(index)", message, exit: index % 2 + 1)))
            if case .softWarning = verdicts.last { warnings += 1 }
        }
        // 1. observations changed, so strategies grew...
        #expect(tracker.distinctStrategies >= 3, "换命令文本应记为策略变化：\(tracker.distinctStrategies)")
        // 2. ...and the two exit codes stay distinct exact fingerprints...
        #expect(tracker.exactFingerprintCount == 2, "exit1 / exit2 必须保留为两个不同 exact fingerprint：\(tracker.exactFingerprintCount)")
        // 3. ...yet they belong to ONE unresolved cluster.
        #expect(tracker.openBlockerCount == 1, "两个观察属于同一个未解决 cluster：\(tracker.openBlockerCount)")
        // 4. progress debt accumulates monotonically.
        #expect(tracker.monotonicRepeats >= 5, "cluster  sighting 应单调累计：\(tracker.monotonicRepeats)")
        // 5. one warning only, 6. then a stop once the grace window is spent with the cluster still
        // reproducing.
        #expect(warnings == 1, "同一 cluster 只提示一次：\(warnings)")
        #expect(verdicts.allSatisfy { if case .progress = $0 { return false } else { return true } },
            "换 exit code 而不改任何东西不是进展：\(verdicts)")
        #expect(verdicts.contains { if case .hardStop = $0 { return true } else { return false } },
            "交替失败必须最终停止：\(verdicts)")
    }

    @Test("exact fingerprint and cluster identity are different layers")
    func fingerprintAndClusterLayers() {
        func outcome(_ exit: Int) -> Outcome {
            Outcome(callKey: "shell|{\"command\":\"npm test\"}", succeeded: false,
                    errorMessage: "commandFailed:命令以状态 \(exit) 退出", exitCode: exit)
        }
        #expect(ToolLoopProgressTracker.fingerprint(of: outcome(1)) != ToolLoopProgressTracker.fingerprint(of: outcome(2)),
            "exit code 参与 exact 观察身份")
        #expect(ToolLoopProgressTracker.cluster(of: outcome(1)) == ToolLoopProgressTracker.cluster(of: outcome(2)),
            "但它们是同一个未解决操作")
        let differentClass = Outcome(callKey: "shell|{\"command\":\"npm test\"}", succeeded: false,
                                     errorMessage: "commandFailed:AssertionError: expected 200", exitCode: 1)
        #expect(ToolLoopProgressTracker.cluster(of: outcome(1)) != ToolLoopProgressTracker.cluster(of: differentClass),
            "错误类真的变了才算是另一个 cluster")
    }

    @Test("a warned blocker that is never reproduced again does not end a run doing other work")
    func warnedBlockerWithoutRecurrenceDoesNotStop() {
        var tracker = ToolLoopProgressTracker()
        for command in ["g++ a.cpp", "clang++ a.cpp", "gcc a.cpp"] { _ = tracker.record(failShell(command)) }
        var verdicts: [ToolLoopProgressTracker.Verdict] = []
        for index in 0..<6 {
            verdicts.append(tracker.record([Outcome(callKey: "write_file|p\(index).txt", succeeded: true,
                                                   errorMessage: nil, evidence: .mutation)]))
        }
        #expect(!verdicts.contains { if case .hardStop = $0 { return true } else { return false } },
            "提示后不再复现的 blocker 不该在别的任务上把运行掐掉：\(verdicts)")
        #expect(tracker.openBlockerCount == 1, "blocker 仍在记录中，只是没有证据说明它还存在")
    }

    // MARK: - Background success is a launch receipt, nothing more

    @Test("a background command that merely launched does not clear the blocker")
    func backgroundSuccessIsNotProgress() {
        var tracker = ToolLoopProgressTracker()
        var verdicts: [ToolLoopProgressTracker.Verdict] = []
        for _ in 0..<3 {
            verdicts += [tracker.record(failShell("make test")), tracker.record(backgroundOK)]
        }
        #expect(verdicts.allSatisfy { if case .progress = $0 { return false } else { return true } },
            "run_background_command 的成功只证明进程被启动：\(verdicts)")
        #expect(verdicts.contains { if case .hardStop = $0 { return true } else { return false } },
            "后台启动不得洗白同一 blocker：\(verdicts)")
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
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")),
            workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow, interactive: false)
        await host.start()
        return (host, LingXiClient.inProcess(endpoint: host), provider)
    }

    private func step(_ id: String, _ tool: String, _ arguments: [String: Any]) -> [ModelEvent] {
        let json = String(data: try! JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), encoding: .utf8)!
        return [.toolCallCompleted(ToolCall(callID: ToolCallID(id), toolID: ToolID(tool), arguments: json)), .completed(.toolCalls)]
    }

    @Test("a real session that repeats one blocker while doing neutral work stops after one warning")
    func productionReplayWarnsOnceThenStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-loop6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "helper\n".write(to: root.appendingPathComponent("helper.txt"), atomically: true, encoding: .utf8)
        try "same\n".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        // Twelve batches offered: the same compile blocker with a new strategy each time, interleaved
        // with reads and no-op rewrites of identical bytes.
        var script: [[ModelEvent]] = []
        for index in 1...12 {
            script.append(step("x\(index)", "shell", ["command": "g++ app\(index).cpp -o app 2>&1 | tail -3; exit 69"]))
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
        #expect(termination.code == .agentStepLimitReached)
        #expect(termination.message.contains("同一阻塞") || termination.message.contains("完全重复"),
            "终止原因必须说明是哪条规则：\(termination.message)")
        #expect(provider.recorder.requests.count < script.count, "绝不能一路跑到 script 结束：\(provider.recorder.requests.count) requests")

        let durable = try await host.sessionStore.session(sid)
        let results = durable.messages.flatMap(\.parts).compactMap { part -> ToolResult? in
            if case let .toolResult(result) = part { return result } else { return nil }
        }
        let warnings = results.filter { $0.content.contains(ToolLoopProgressTracker.softWarningText) }
        #expect(warnings.count == 1, "软提示应恰好出现一次：\(warnings.count)")
        let failures = results.filter { !$0.success }
        #expect(failures.count >= 3, "同样失败至少重复了三次：\(failures.count)")
        #expect(failures.allSatisfy { $0.exitCode == 69 }, "重复的是同一个阻塞")
        #expect(results.count < script.count, "tool call 总量应远小于可用 script 批次")
        print("LOOP_REPLAY churn=blocked requests=\(provider.recorder.requests.count) offered=\(script.count) "
            + "toolCalls=\(results.count) failures=\(failures.count) warnings=\(warnings.count) "
            + "reason=\(termination.message.prefix(60))")
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
        #expect(results.allSatisfy { !$0.content.contains(ToolLoopProgressTracker.softWarningText) },
            "同一目标已被证明可通过，不应再发出阻塞提示")
        #expect(try String(contentsOf: root.appendingPathComponent("app.cpp"), encoding: .utf8).contains("return 0"))
    }

}
