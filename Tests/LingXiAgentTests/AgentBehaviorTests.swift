import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

struct AgentBehaviorTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func call(_ id: String, _ tool: String, _ arguments: String) -> ToolCall {
        ToolCall(callID: ToolCallID(id), toolID: ToolID(tool), arguments: arguments)
    }

    private func client(root: URL, provider: any ModelProvider, profile: AgentBehaviorProfile) async throws -> LingXiClient {
        let configuration = CoreConfiguration(agent: AgentSettings(permissionPolicy: .auto, executionProfile: .workspace, behaviorProfile: profile))
        let host = try CoreHost(
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")),
            configuration: configuration,
            workspaceRoot: try WorkspaceRoot(path: root.path)
        )
        await host.start()
        return LingXiClient.inProcess(endpoint: host)
    }

    @Test func buildRecoversFromFailedVerificationAndCompletes() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "source".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let read = call("read", "read_file", #"{"path":"README.md"}"#)
        let broken = call("broken", "write_file", #"{"path":"output.txt","content":"broken"}"#)
        let test = call("test", "shell", #"{"command":"test \"$(cat output.txt)\" = fixed"}"#)
        let fixed = call("fixed", "write_file", #"{"path":"output.txt","content":"fixed","overwrite":true}"#)
        let verify = call("verify", "read_file", #"{"path":"output.txt"}"#)
        let provider = ScriptedFakeProvider(script: [
            [.toolCallCompleted(read), .completed(.toolCalls)],
            [.toolCallCompleted(broken), .completed(.toolCalls)],
            [.toolCallCompleted(test), .completed(.toolCalls)],
            [.toolCallCompleted(fixed), .completed(.toolCalls)],
            [.toolCallCompleted(test), .completed(.toolCalls)],
            [.toolCallCompleted(verify), .completed(.toolCalls)],
            [.textDelta("完成并已验证。"), .completed(.stop)],
        ])
        let client = try await client(root: root, provider: provider, profile: .build)
        let session = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: session, content: "修复 output.txt 并验证") {}

        let snapshot = try await client.session(session)
        let results = snapshot.messages.flatMap { $0.parts.compactMap { if case let .toolResult(result) = $0 { result } else { nil } } }
        #expect(provider.recorder.requests.count == 7)
        #expect(results.map(\.success) == [true, true, false, true, true, true])
        #expect(try String(contentsOf: root.appendingPathComponent("output.txt"), encoding: .utf8) == "fixed")
        #expect(snapshot.messages.last?.content == "完成并已验证。")
        #expect(provider.recorder.requests[0].messages.first?.parts.contains(.text("Build profile: inspect before editing; after every mutation, run the narrowest relevant verification. On tool failure or timeout, use returned diagnostics to change strategy or report the blocker. Before completion, inspect the diff and verification result. Do not repeat an identical failed action.")) == true)
    }

    @Test func planAndExploreRejectMutationAtRuntime() async throws {
        for profile in [AgentBehaviorProfile.plan, .explore] {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let write = call("write", "write_file", #"{"path":"blocked.txt","content":"no"}"#)
            let provider = ScriptedFakeProvider(script: [
                [.toolCallCompleted(write), .completed(.toolCalls)],
                [.textDelta("只读报告。"), .completed(.stop)],
            ])
            let client = try await client(root: root, provider: provider, profile: profile)
            let session = try await client.createSession()
            for try await _ in try await client.sendMessage(sessionID: session, content: "调查后写入") {}

            let snapshot = try await client.session(session)
            let result = snapshot.messages.flatMap { $0.parts }.compactMap { if case let .toolResult(result) = $0 { result } else { nil } }.first
            #expect(result?.error?.code == CoreError.Code.permissionDenied.rawValue)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("blocked.txt").path))
            #expect(!provider.recorder.requests[0].tools.contains { $0.id == ToolID("write_file") })
        }
    }

    @Test func nestedAgentInstructionsHaveScopedPrecedenceAndProvenance() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: globalRoot) }
        let global = globalRoot.appendingPathComponent("AGENTS.md")
        try FileManager.default.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "global rule".write(to: global, atomically: true, encoding: .utf8)
        try "root rule".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let nested = root.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "nested rule".write(to: nested.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let instructions = try AgentInstructionSet.load(workspace: root, globalInstructionsURL: global)

        let applicable = instructions.applicable(to: nested.appendingPathComponent("Code.swift"))
        #expect(applicable.map(\.source) == ["~/.lingxiagent/AGENTS.md", "AGENTS.md", "Sources/Feature/AGENTS.md"])
        #expect(applicable.map(\.content) == ["global rule", "root rule", "nested rule"])
        #expect(instructions.applicable(to: root.appendingPathComponent("Other.swift")).map(\.content) == ["global rule", "root rule"])
        let rendered = try #require(instructions.rendered())
        #expect(rendered.contains("source=~/.lingxiagent/AGENTS.md scope=global priority=1"))
        #expect(rendered.contains("source=AGENTS.md scope=. priority=2"))
        #expect(rendered.contains("source=Sources/Feature/AGENTS.md scope=Sources/Feature priority=3"))
        #expect(rendered.contains("higher priority (closer scope) overrides"))
    }
}
