import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

/// Model repair attempts remain executable; only explicit safety/budget boundaries end the loop.
@Suite("Tool loop recovery", .serialized)
struct ToolLoopRecoveryTests {
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
        let (host, client) = try await makeClient(root: root, provider: provider)
        defer { await host.shutdown() }
        let sid = try await client.createSession()
        do {
            for try await _ in try await client.sendMessage(sessionID: sid, content: "Run the complete tests") {}
            Issue.record("Failed tests must not be reported as completed")
        } catch let error as CoreError { #expect(error.code == .toolExecutionFailed) }
        #expect(provider.recorder.requests.count == script.count)
    }

    // MARK: - End to end through SessionRuntime and the real shell tool

    private func makeClient(root: URL, provider: any ModelProvider, maxSteps: Int? = nil) async throws -> (CoreHost, LingXiClient) {
        let host = try CoreHost(
            startupPolicy: .unitTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")),
            configuration: maxSteps.map { CoreConfiguration(agent: AgentSettings(maxAgentLoopSteps: $0)) },
            workspaceRoot: try WorkspaceRoot(path: root.path),
            permissionDecision: .allow,
            interactive: false
        )
        await host.start()
        return (host, LingXiClient.inProcess(endpoint: host))
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
        let (host, client) = try await makeClient(root: root, provider: provider)
        defer { await host.shutdown() }
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
        let fourth = try #require(provider.recorder.requests.dropFirst(3).first)
        #expect(fourth.cachePlan?.volatileTail.ephemeralNotes?.contains(ToolLoopProgressTracker.heading) == true)
        #expect(fourth.messages.last?.segment == .orchestratorWarning)
        let results = snapshot.messages.flatMap(\.parts).compactMap { part -> ToolResult? in
            if case let .toolResult(result) = part { return result }; return nil
        }
        #expect(results.count == 3)
        #expect(results.allSatisfy { !$0.content.contains(ToolLoopProgressTracker.heading) })
    }

    @Test("ten identical failed commands all execute and let the model reach its report")
    func identicalCommandsReachReport() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var script = (1...10).map { shellStep("duplicate-\($0)", "exit 69") }
        script.append([.textDelta("The commands failed; the task is blocked."), .completed(.stop)])
        let provider = ScriptedFakeProvider(script: script)
        let (host, client) = try await makeClient(root: root, provider: provider)
        defer { await host.shutdown() }
        let sessionID = try await client.createSession()
        do {
            for try await _ in try await client.sendMessage(sessionID: sessionID, content: "Run the complete tests") {}
            Issue.record("A failure report must not be marked successful")
        } catch let error as CoreError { #expect(error.code == .toolExecutionFailed) }
        #expect(provider.recorder.requests.count == script.count)
        let snapshot = try await client.session(sessionID)
        #expect(snapshot.messages.last?.content.contains("task is blocked") == true)
    }

    @Test("Default orchestration completes real mutations beyond 32 model steps")
    func usefulWorkBeyond32StepsCompletes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CoreConfiguration().agent.maxAgentLoopSteps == 0,
            "The default must not impose a step ceiling")
        var script: [[ModelEvent]] = (1...35).map { i in
            let call = ToolCall(callID: ToolCallID("write-\(i)"), toolID: ToolID("write_file"),
                                arguments: "{\"path\":\"part\(i).txt\",\"content\":\"part \(i)\"}")
            return [.toolCallStarted(callID: call.callID, toolID: call.toolID),
                    .toolCallCompleted(call), .completed(.toolCalls)]
        }
        script.append([.textDelta("已写入并验证 35 个文件。"), .completed(.stop)])
        let provider = ScriptedFakeProvider(script: script)
        let (host, client) = try await makeClient(root: root, provider: provider)
        defer { await host.shutdown() }
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
        #expect(results.allSatisfy { !$0.fileMutations.isEmpty }, "35 批都必须是可验证的真实 mutation")
        #expect(results.allSatisfy { !$0.content.contains(ToolLoopProgressTracker.heading) })
        #expect(snapshot.messages.last?.content.contains("35 个文件") == true, "长运行必须正常完成")
    }

    @Test("changing failure observations can continue beyond 32 steps")
    func changingFailureObservationsReachReport() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var script = (1...35).map { shellStep("recover-\($0)", "echo attempt-\($0); exit \($0 % 2 + 1)") }
        script.append([.textDelta("The environment is still blocked."), .completed(.stop)])
        let provider = ScriptedFakeProvider(script: script)
        let (host, client) = try await makeClient(root: root, provider: provider)
        defer { await host.shutdown() }
        let sessionID = try await client.createSession()
        do {
            for try await _ in try await client.sendMessage(sessionID: sessionID, content: "Run the environment checks") {}
            Issue.record("Unsuccessful checks cannot complete the task")
        } catch let error as CoreError { #expect(error.code == .toolExecutionFailed) }
        #expect(provider.recorder.requests.count == script.count)
        let durable = try await client.session(sessionID)
        let results = durable.messages.flatMap(\.parts).compactMap { part -> ToolResult? in
            if case let .toolResult(result) = part { return result }; return nil
        }
        #expect(results.count == 35)
        #expect(Set(results.compactMap(\.exitCode)) == [1, 2])
        #expect(results.allSatisfy { $0.error?.code == CoreError.Code.commandFailed.rawValue })
        #expect(results.allSatisfy { $0.fileMutations.isEmpty && !$0.content.contains(ToolLoopProgressTracker.heading) })
    }

    @Test("ten identical empty results are advisory and all execute")
    func emptyResultsDoNotStop() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var script = (1...10).map { shellStep("empty-\($0)", "true") }
        script.append([.textDelta("The check produced no output."), .completed(.stop)])
        let provider = ScriptedFakeProvider(script: script)
        let (host, client) = try await makeClient(root: root, provider: provider)
        defer { await host.shutdown() }
        let sessionID = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: sessionID, content: "Run the empty-output check") {}
        #expect(provider.recorder.requests.count == script.count)
        #expect(provider.recorder.requests.last?.cachePlan?.volatileTail.ephemeralNotes?.contains("identical calls") == true)
    }

    // MARK: - Explicit budgets still hold

    @Test("maximumAgentSteps still ends a run that keeps exploring")
    func stepCeilingHolds() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        // Every step succeeds with different output, so no loop rule can fire; only the ceiling.
        let provider = ScriptedFakeProvider(script: (1...6).map { shellStep("s\($0)", "echo \($0)") })
        let (host, client) = try await makeClient(root: root, provider: provider, maxSteps: 4)
        defer { await host.shutdown() }
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
