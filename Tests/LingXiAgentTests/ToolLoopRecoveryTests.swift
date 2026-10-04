import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

/// The tool loop must tell a stuck model from a model exploring.
///
/// Real smoke test, 2026-10-03: asked to compile a C++ file, the model tried `g++`, then `clang`,
/// then `gcc`. All three exited 69 (unaccepted Xcode licence), the old check compared error text
/// only, and the run was killed with `agentStepLimitReached` on the third — one step before the
/// model could report the blocker. These tests pin the distinction the fix draws.
@Suite("Tool loop recovery")
struct ToolLoopRecoveryTests {

    private typealias Outcome = ToolLoopProgressTracker.CallOutcome
    private static let status69 = "commandFailed:命令以状态 69 退出"

    private func failed(_ command: String, _ error: String = status69, exit: Int? = nil) -> [Outcome] {
        [Outcome(callKey: "shell|{\"command\":\"\(command)\"}", succeeded: false, errorMessage: error, exitCode: exit)]
    }

    @Test func successfulNoOpCannotEraseUnresolvedFailure() {
        var tracker = ToolLoopProgressTracker()
        var stopped = false
        for _ in 0..<3 {
            if case .hardStop = tracker.record(failed("test")) { stopped = true; break }
            _ = tracker.record([Outcome(callKey: "write_file|unchanged", succeeded: true, errorMessage: nil)])
        }
        #expect(stopped)
    }

    @Test func successfulSiblingCannotHideRepeatedFailure() {
        var tracker = ToolLoopProgressTracker()
        let batch = failed("test") + [Outcome(callKey: "read_file|helper", succeeded: true, errorMessage: nil)]
        _ = tracker.record(batch); _ = tracker.record(batch)
        guard case .hardStop = tracker.record(batch) else { Issue.record("A successful sibling cannot clear repeated failure evidence"); return }
    }

    @Test func realNoOpRewriteCannotMaskRepeatedTestFailure() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try "unchanged".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        var script: [[ModelEvent]] = []
        for n in 0..<3 {
            script.append(shellStep("failed-\(n)", "echo NameError: missing_symbol; exit 1"))
            let call = ToolCall(callID: ToolCallID("noop-\(n)"), toolID: ToolID("write_file"), arguments: "{\"path\":\"note.txt\",\"content\":\"unchanged\"}")
            script.append([.toolCallCompleted(call), .completed(.toolCalls)])
        }
        script.append([.textDelta("Still blocked"), .completed(.stop)])
        let provider = ScriptedFakeProvider(script: script)
        let client = try await makeClient(root: root, provider: provider)
        let sid = try await client.createSession()
        do {
            for try await _ in try await client.sendMessage(sessionID: sid, content: "Check the existing tests") {}
            Issue.record("Repeated no-progress failures must not complete")
        } catch let error as CoreError { #expect(error.code == .agentStepLimitReached) }
        #expect(provider.recorder.requests.count < script.count)
    }

    // MARK: - 11. Different strategies, one blocker

    @Test("g++ → clang → gcc failing alike is a cluster with a soft warning, not a stop")
    func differentCommandsSameErrorDoNotStop() {
        var tracker = ToolLoopProgressTracker()
        #expect(tracker.record(failed("g++ primes.cpp")) == .failureCluster(distinctStrategies: 1))
        #expect(tracker.record(failed("clang++ primes.cpp")) == .failureCluster(distinctStrategies: 2))
        guard case .softWarning(3, _) = tracker.record(failed("gcc primes.cpp")) else {
            Issue.record("第三个不同策略应只得到软提示，不得硬终止")
            return
        }
    }

    // MARK: - 12. Exact duplicates are still stopped

    @Test("the same command with the same arguments failing the same way is still stopped")
    func exactDuplicateStillStops() {
        var tracker = ToolLoopProgressTracker()
        _ = tracker.record(failed("g++ primes.cpp"))
        #expect(tracker.record(failed("g++ primes.cpp")) == .exactDuplicate(count: 2))
        guard case .hardStop(.exactDuplicate, _) = tracker.record(failed("g++ primes.cpp")) else {
            Issue.record("完全重复的失败调用必须被终止")
            return
        }
    }

    // MARK: - 13. What actually resets

    /// Re-written in Phase 6. Its first half used to assert the rule this phase replaced: that a
    /// successful call resets the cluster. A success that proves nothing about the blocker only spends
    /// grace, so the assertions now follow the objective signals.
    @Test("neutral work spends grace, while the objective passing or a proven failure-class change resets")
    func progressResets() {
        var tracker = ToolLoopProgressTracker()
        _ = tracker.record(failed("g++ a.cpp"))
        _ = tracker.record(failed("clang++ a.cpp"))
        #expect(tracker.record([Outcome(callKey: "write_file|x", succeeded: true, errorMessage: nil)]) == .neutral(reason: .noObjectiveSignal),
            "写回相同内容不证明编译阻塞消失了")
        guard case .softWarning = tracker.record(failed("gcc a.cpp")) else {
            Issue.record("第三个策略应得到一次性提示，而不是把计数清零")
            return
        }
        // fail → pass on the same objective is the strong signal.
        let pass = tracker.record([Outcome(callKey: "shell|{\"command\":\"g++ a.cpp\"}", succeeded: true, errorMessage: nil)])
        #expect(pass == .progress(strategyChanged: true), "\(pass)")
        #expect(tracker.openBlockerCount == 0)
        // A failure-class change after a real mutation proves the old blocker moved on.
        _ = tracker.record(failed("pytest t.py", "commandFailed:NameError: session undefined", exit: 1))
        _ = tracker.record([Outcome(callKey: "write_file|t.py", succeeded: true, errorMessage: nil, evidence: .mutation)])
        guard case .progress = tracker.record(failed("pytest t.py", "commandFailed:AssertionError: expected 200", exit: 1)) else {
            Issue.record("真实修改后失败类别实质变化应记为进展")
            return
        }
        #expect(tracker.openBlockerCount == 1, "只剩新的 blocker")
    }

    // MARK: - 14. The warning is issued once and is bounded

    @Test("the soft warning fires once per cluster, then the run stops if nothing changes")
    func warningOnceThenBounded() {
        var tracker = ToolLoopProgressTracker()
        var warnings = 0
        var stopped = false
        for (index, command) in ["g++", "clang++", "gcc", "cc", "c++", "zig c++", "tcc"].enumerated() {
            switch tracker.record(failed("\(command) a.cpp")) {
            case .softWarning: warnings += 1
            case .hardStop(.clusterAfterWarning, _):
                stopped = true
                #expect(index == 5, "提示后应恰好再给两批机会：在第 \(index + 1) 批停止")
            case .hardStop: Issue.record("不应以完全重复为由停止")
            default: break
            }
            if stopped { break }
        }
        #expect(warnings == 1, "软提示必须只出现一次")
        #expect(stopped, "提示后仍无进展必须最终终止")
    }

    @Test("a model-repeated call that the runtime already blocked counts as an exact duplicate")
    func blockedRepeatIsDuplicate() {
        var tracker = ToolLoopProgressTracker()
        _ = tracker.record(failed("read_file x", "resourceNotFound:missing"))
        // The blocked repeat carries the original signature (see SessionRuntime).
        #expect(tracker.record(failed("read_file x", "resourceNotFound:missing")) == .exactDuplicate(count: 2))
    }

    // MARK: - End to end through SessionRuntime and the real shell tool

    private func makeClient(root: URL, provider: any ModelProvider, maxSteps: Int? = nil) async throws -> LingXiClient {
        let host = try CoreHost(
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")),
            configuration: maxSteps.map { CoreConfiguration(agent: AgentSettings(maxAgentLoopSteps: $0)) },
            workspaceRoot: try WorkspaceRoot(path: root.path),
            permissionDecision: .allow,
            interactive: false
        )
        await host.start()
        return LingXiClient.inProcess(endpoint: host)
    }

    private func shellStep(_ id: String, _ command: String) -> [ModelEvent] {
        let call = ToolCall(callID: ToolCallID(id), toolID: ToolID("shell"),
                            arguments: "{\"command\":\"\(command)\"}")
        return [.toolCallStarted(callID: call.callID, toolID: call.toolID), .toolCallCompleted(call), .completed(.toolCalls)]
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lx-loop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("three different commands exiting 69 let the model reach its report")
    func threeStrategiesReachReport() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFakeProvider(script: [
            shellStep("c1", "exit 69"),
            shellStep("c2", "true && exit 69"),
            shellStep("c3", "false || exit 69"),
            [.textDelta("编译器都因 Xcode 许可未接受而退出 69，需要你先运行 sudo xcodebuild -license。"), .completed(.stop)],
        ])
        let client = try await makeClient(root: root, provider: provider)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "编译 primes.cpp")
        do {
            for try await _ in stream {}
            Issue.record("A blocked compilation must not complete the turn")
        } catch let error as CoreError {
            #expect(error.code == .toolExecutionFailed)
        }

        let snapshot = try await client.session(sessionID)
        #expect(snapshot.messages.last?.content.contains("xcodebuild -license") == true, "模型应能报告真实 blocker")
        // The fourth request carries the soft warning, attached to the third result.
        let fourth = try #require(provider.recorder.requests.dropFirst(3).first)
        let toolTexts = fourth.messages.flatMap(\.parts).compactMap { part -> String? in
            if case let .toolResult(result) = part { return result.content } else { return nil }
        }
        #expect(toolTexts.last?.contains("多个不同策略均遇到同一个环境级阻塞") == true, "软提示应随第三个结果送达模型")
        #expect(toolTexts.filter { $0.contains("多个不同策略均遇到同一个环境级阻塞") }.count == 1)
    }

    @Test("the same command failing three times is still stopped end to end")
    func identicalCommandStopsEndToEnd() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFakeProvider(script: [
            shellStep("d1", "exit 69"), shellStep("d2", "exit 69"), shellStep("d3", "exit 69"),
            [.textDelta("不应到达"), .completed(.stop)],
        ])
        let client = try await makeClient(root: root, provider: provider)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "loop")
        do {
            for try await _ in stream {}
            Issue.record("完全重复的失败必须终止")
        } catch let error as CoreError {
            #expect(error.code == .agentStepLimitReached)
            #expect(error.message.contains("完全重复的失败调用"), "终止原因应说明是哪条规则：\(error.message)")
        }
    }

    /// 方案 A of the LONG RUN != LOOP pair: more than 32 steps that each carry an objective signal must
    /// run to completion, and the default configuration must not smuggle a fixed step ceiling back in.
    /// Its counterpart is `changingFailureObservationsDoNotEvadeNoProgressStop`.
    @Test("Default orchestration completes real mutations beyond 32 model steps")
    func usefulWorkBeyond32StepsCompletes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CoreConfiguration().agent.maxAgentLoopSteps == 0,
            "默认不得存在固定 step 上限，长运行由进展判定负责")
        var script: [[ModelEvent]] = (1...35).map { i in
            let call = ToolCall(callID: ToolCallID("write-\(i)"), toolID: ToolID("write_file"),
                                arguments: "{\"path\":\"part\(i).txt\",\"content\":\"part \(i)\"}")
            return [.toolCallStarted(callID: call.callID, toolID: call.toolID),
                    .toolCallCompleted(call), .completed(.toolCalls)]
        }
        script.append([.textDelta("已写入并验证 35 个文件。"), .completed(.stop)])
        let provider = ScriptedFakeProvider(script: script)
        let client = try await makeClient(root: root, provider: provider)
        let sessionID = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: sessionID, content: "创建这些文件") {}
        #expect(provider.recorder.requests.count == 36)
        for i in 1...35 {
            #expect(try String(contentsOf: root.appendingPathComponent("part\(i).txt"), encoding: .utf8) == "part \(i)")
        }
        let snapshot = try await client.session(sessionID)
        let results = snapshot.messages.flatMap(\.parts).compactMap { part -> ToolResult? in
            if case let .toolResult(result) = part { return result }
            return nil
        }
        #expect(results.count == 35)
        #expect(results.allSatisfy { $0.success })
        // Every batch really changed workspace bytes: that is the progress the loop rule asks for.
        #expect(results.allSatisfy { !$0.fileMutations.isEmpty }, "35 批都必须是可验证的真实 mutation")
        #expect(results.allSatisfy { !$0.content.contains(ToolLoopProgressTracker.softWarningText) })
        #expect(snapshot.messages.last?.content.contains("35 个文件") == true, "长运行必须正常完成")
    }

    /// Renamed and re-signed in Phase 6 under 方案 B. Its old expectation - "keep changing the
    /// observation and the run gets to reach step 36" - is the exact hole the frozen progress
    /// semantics close: command text, an echoed counter and the exit code all moved, while nothing
    /// objective did: no attempt succeeded, no file changed, no blocker disappeared. The prohibition
    /// on a fixed low step ceiling is carried by `usefulWorkBeyond32StepsCompletes` instead, which
    /// runs 35 batches of real mutations to completion.
    @Test("changing failure observations do not evade the no-progress stop")
    func changingFailureObservationsDoNotEvadeNoProgressStop() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var script = (1...35).map { shellStep("recover-\($0)", "echo attempt-\($0); exit \($0 % 2 + 1)") }
        script.append([.textDelta("检查结束，环境问题仍未解决。"), .completed(.stop)])
        let provider = ScriptedFakeProvider(script: script)
        let client = try await makeClient(root: root, provider: provider)
        let sessionID = try await client.createSession()
        var reason: CoreError?
        do {
            for try await _ in try await client.sendMessage(sessionID: sessionID, content: "检查环境") {}
            Issue.record("零客观进展的形式变化必须被无进展规则终止")
        } catch let error as CoreError { reason = error }

        let termination = try #require(reason)
        let requests = provider.recorder.requests.count
        #expect(termination.code == .agentStepLimitReached)
        // 7. the reason is a no-progress / repeated-blocker rule...
        #expect(termination.message.contains("无进展死循环") && termination.message.contains("同一阻塞"),
            "终止原因必须是未进展/重复阻塞类规则：\(termination.message)")
        // 8. ...and specifically not a step ceiling.
        #expect(!termination.message.contains("超过上限"), "不得由固定 step 上限承担：\(termination.message)")
        // 9. far short of running the script out.
        #expect(requests < 36, "不能跑到第 36 次 provider request 才结束：\(requests)")

        let durable = try await client.session(sessionID)
        let results = durable.messages.flatMap(\.parts).compactMap { part -> ToolResult? in
            if case let .toolResult(result) = part { return result } else { return nil }
        }
        let failures = results.filter { !$0.success }
        // 1. observations did change, and the stop record says so in strategy terms.
        #expect(termination.message.contains("个不同策略"), "策略变化应被记录：\(termination.message)")
        // 2. the two exit codes stayed distinct exact observations...
        #expect(Set(failures.compactMap(\.exitCode)).count == 2, "exit1/exit2 都是被如实记录的观察：\(failures.compactMap(\.exitCode))")
        // 3. ...under one message class, i.e. one cluster - every failure carries the same signature
        // shape, and 4. they accumulated monotonically until the limit.
        #expect(failures.allSatisfy { $0.error?.code == CoreError.Code.commandFailed.rawValue })
        #expect(failures.count >= 3, "同一 cluster 的重复必须累计到阈值：\(failures.count)")
        // 5. the soft warning appeared exactly once, 6. and the stop came after it.
        #expect(results.filter { $0.content.contains(ToolLoopProgressTracker.softWarningText) }.count == 1)
        // No workspace mutation happened anywhere in the run.
        #expect(results.allSatisfy { $0.fileMutations.isEmpty }, "零 mutation 的运行不可能被算作有进展")
        print("LOOP_REPLAY churn=requests=\(requests) offered=\(script.count) failures=\(failures.count) "
            + "reason=\(termination.message.prefix(70))")
    }

    // MARK: - Explicit budgets still hold

    @Test("maximumAgentSteps still ends a run that keeps exploring")
    func stepCeilingHolds() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        // Every step succeeds with different output, so no loop rule can fire; only the ceiling.
        let provider = ScriptedFakeProvider(script: (1...6).map { shellStep("s\($0)", "echo \($0)") })
        let client = try await makeClient(root: root, provider: provider, maxSteps: 4)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "go")
        do {
            for try await _ in stream {}
            Issue.record("超过步数上限必须终止")
        } catch let error as CoreError {
            #expect(error.code == .agentStepLimitReached)
            #expect(error.message.contains("超过上限"))
        }
    }
}
