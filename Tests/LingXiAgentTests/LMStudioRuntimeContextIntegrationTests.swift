import Foundation
import Testing
import LingXiProtocol
import LingXiClient
@testable import LingXiCore

/// Real discovery, real inference and real file/shell tools in a disposable workspace.
/// Opt in with LINGXI_LMSTUDIO_BASE_URL and LINGXI_LMSTUDIO_MODEL.
@Suite("Live LM Studio runtime context policy", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["LINGXI_LMSTUDIO_BASE_URL"] != nil))
struct LMStudioRuntimeContextIntegrationTests {
    @Test func real64KWriteAndShellKeepPolicyAndPrefixConsistent() async throws {
        let env = ProcessInfo.processInfo.environment
        let baseURL = try #require(env["LINGXI_LMSTUDIO_BASE_URL"])
        let model = try #require(env["LINGXI_LMSTUDIO_MODEL"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-live-runtime-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dataRoot = root.appendingPathComponent("data")
        let store = try ConfigurationStore(dataRoot: dataRoot)
        try await store.saveCore(CoreConfiguration(agent: AgentSettings(maxAgentLoopSteps: 8)))
        try await store.saveProviders(ProvidersConfiguration(model: "lmstudio/\(model)", providers: [
            "lmstudio": PublicProviderConfiguration(name: "Live runtime test", options: PublicProviderOptions(
                baseURL: baseURL, localRuntime: LocalRuntimeOptions(backend: .lmStudio)), models: [
                    model: PublicModelConfiguration(name: model, reasoning: true,
                        limit: PublicModelLimit(context: 262_144, output: 8_192), toolCalling: true)])]))
        let host = try CoreHost(startupPolicy: .integrationTest, workspaceRoot: WorkspaceRoot(path: root.path),
            dataRoot: dataRoot, permissionDecision: .allow, configurationStore: store)
        defer { await host.shutdown() }
        await host.start()
        let legacy = LingXiClient.inProcess(endpoint: host)
        let client = try await LingXiClientVNext.inProcess(service: host)
        let sid = try await legacy.createSession()
        _ = try await client.debug.setEnabled(true)
        let initial = await host.runtimeContextSnapshot
        let policy = initial.policy
        #expect(initial.assembly?.contextProfile.contextWindowTokens == 65_536)
        #expect(policy.modelWindow == 65_536)
        #expect(policy.pCoreTarget <= policy.pCoreSoftLimit && policy.pCoreSoftLimit <= policy.pCoreHardLimit)
        #expect(policy.pCoreHardLimit + policy.reserve <= 65_536)
        #expect(await host.cacheController.policy == policy)
        print("LIVE_POLICY window=\(policy.modelWindow) target=\(policy.pCoreTarget) soft=\(policy.pCoreSoftLimit) hard=\(policy.pCoreHardLimit) reserve=\(policy.reserve)")

        let stream = await legacy.events()
        let capture = Task { () -> [CoreEvent] in
            var events: [CoreEvent] = []
            for await event in stream {
                events.append(event)
                if case .turnCompleted = event { return events }
                if case .turnFailed = event { return events }
            }
            return events
        }
        defer { capture.cancel() }
        var modelOutput = ""
        do {
            for try await chunk in try await legacy.sendMessage(sessionID: sid, content:
                "在当前工作区创建 runtime_budget_smoke.c，写入一个 C 程序，运行时输出 RUNTIME_CONTEXT_SMOKE_OK。然后用 shell 调用 cc 编译成 runtime_budget_smoke 并运行它。必须实际调用 write_file 和 shell，完成后简短报告。") {
                if modelOutput.utf8.count < 12_000 { modelOutput += chunk.text }
            }
        } catch {
            let events = await capture.value
            let calls = events.compactMap { event -> String? in
                if case let .toolCallCompleted(call) = event { return call.toolName }; return nil
            }
            print("LIVE_SMOKE_FAILURE calls=\(calls) output=\(modelOutput) error=\(error)")
            throw error
        }
        let events = await capture.value
        let results = events.compactMap { event -> ToolResult? in
            if case let .toolResult(result) = event { return result }; return nil
        }
        #expect(events.contains { if case .turnCompleted = $0 { return true }; return false })
        #expect(results.contains { $0.success && $0.toolName == "write_file" && !$0.fileMutations.isEmpty })
        #expect(results.contains { $0.success && $0.toolName == "shell" && $0.exitCode == 0 && $0.content.contains("RUNTIME_CONTEXT_SMOKE_OK") })
        #expect(results.flatMap(\.fileMutations).contains { $0.kind == .created && $0.unifiedDiff.contains("RUNTIME_CONTEXT_SMOKE_OK") })
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime_budget_smoke.c").path))
        let before = try await client.debug.snapshot(sessionID: sid)
        let context = try #require(before.runtimeContextPolicy)
        #expect(context.isConsistent)
        #expect(context.runtimeModelWindow == 65_536)
        let native = try #require(before.localRuntime)
        #expect(native.runtimeContextTokens == 65_536 && native.modelMaxContextTokens == 262_144)
        #expect(native.mtpEnabled == true)
        #expect((native.lastSpeculative?.draftedTokens ?? 0) > 0)
        for _ in 0..<5 { await host.refreshLocalRuntimeIfStale(maxAge: -1) }
        let after = try await client.debug.snapshot(sessionID: sid)
        #expect(after.runtimeContextPolicy == before.runtimeContextPolicy)
        #expect(after.cache?.cacheEpoch == before.cache?.cacheEpoch)
        #expect(after.cache?.stablePrefixHash == before.cache?.stablePrefixHash)
        #expect(after.cache?.clientCausedBusts == before.cache?.clientCausedBusts)
        #expect(await host.cacheController.policy == policy)
        print("LIVE_SMOKE tools=\(results.map { $0.toolName ?? "unknown" }.joined(separator: ",")) MTP=\(native.mtpEnabled == true) drafted=\(native.lastSpeculative?.draftedTokens ?? 0) epoch=\(after.cache?.cacheEpoch ?? -1) prefix=\(after.cache?.stablePrefixHash ?? "unknown") unchanged_refreshes=5")
    }
}
