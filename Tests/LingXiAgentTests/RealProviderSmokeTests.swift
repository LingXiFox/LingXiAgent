import Foundation
import Testing
import LingXiProtocol
import LingXiCore
import LingXiClient

/// 真实 Provider smoke test。
/// 仅当 LINGXI_PROVIDER_BASE_URL、LINGXI_PROVIDER_MODEL 与 LINGXI_WORKSPACE_ROOT 同时存在时执行；
/// 否则静默跳过，CI / swift test 永不因缺 Key 失败。
struct RealProviderSmokeTests {
    @Test func realInferenceSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment[ProviderSetup.baseURLKey], !base.isEmpty,
              let model = environment[ProviderSetup.modelKey], !model.isEmpty,
              let workspacePath = environment["LINGXI_WORKSPACE_ROOT"], !workspacePath.isEmpty
        else {
            print("[smoke] 跳过：未设置 Provider 或 LINGXI_WORKSPACE_ROOT")
            return
        }

        let (assembly, missing) = ProviderSetup.resolve(environment)
        #expect(missing.isEmpty)
        let host = try CoreHost(
            providerAssembly: assembly,
            workspaceRoot: try WorkspaceRoot(path: workspacePath),
            permissionDecision: .allow
        )
        await host.start()
        let client = LingXiClient.inProcess(endpoint: host)

        do {
            let sessionID = try await client.createSession()
            let stream = try await client.sendMessage(
                sessionID: sessionID,
                content: "请读取当前项目的 README.md，然后告诉我这个项目叫什么。"
            )
            var text = ""
            for try await chunk in stream {
                if chunk.kind == .text { text += chunk.text }
            }
            let snapshot = try await client.session(sessionID)
            #expect(snapshot.messages.contains { $0.parts.contains { if case .toolCall = $0 { true } else { false } } })
            #expect(snapshot.messages.contains { $0.parts.contains { if case let .toolResult(result) = $0 { result.success } else { false } } })
            #expect(text.lowercased().contains("lingxiagent"), "模型应根据 README 回答项目名称")
            print("[smoke] model=\(assembly.modelID.rawValue) assistant=\(text)")
            await host.shutdown()
        } catch {
            await host.shutdown()
            throw error
        }
    }
}
