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

    private func failed(_ command: String, _ error: String = status69) -> [Outcome] {
        [Outcome(callKey: "shell|{\"command\":\"\(command)\"}", succeeded: false, errorMessage: error)]
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

    // MARK: - 13. Progress resets

    @Test("a success, or a different failure, resets the cluster and re-arms the warning")
    func progressResets() {
        var tracker = ToolLoopProgressTracker()
        _ = tracker.record(failed("g++ a.cpp"))
        _ = tracker.record(failed("clang++ a.cpp"))
        #expect(tracker.record([Outcome(callKey: "write_file|x", succeeded: true, errorMessage: nil)]) == .progress(strategyChanged: true))
        #expect(tracker.record(failed("gcc a.cpp")) == .failureCluster(distinctStrategies: 1), "成功之后应从零计数")
        // A new failure class is new information.
        #expect(tracker.record(failed("cc a.cpp", "commandFailed:命令以状态 1 退出")) == .progress(strategyChanged: true))
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

    @Test("Default orchestration completes real mutations beyond 32 model steps")
    func usefulWorkBeyond32StepsCompletes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
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
    }

    @Test("Changing failure observations beyond 32 steps can reach the model's report")
    func recoveryBeyond32StepsReachesReport() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var script = (1...35).map { shellStep("recover-\($0)", "echo attempt-\($0); exit \($0 % 2 + 1)") }
        script.append([.textDelta("检查结束，环境问题仍未解决。"), .completed(.stop)])
        let provider = ScriptedFakeProvider(script: script)
        let client = try await makeClient(root: root, provider: provider)
        let sessionID = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: sessionID, content: "检查环境") {}
        #expect(provider.recorder.requests.count == 36)
        let snapshot = try await client.session(sessionID)
        #expect(snapshot.messages.last?.content.contains("环境问题仍未解决") == true)
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
