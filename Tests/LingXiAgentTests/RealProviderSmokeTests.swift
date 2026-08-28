import Foundation
import Testing
import LingXiProtocol
import LingXiCore
import LingXiClient

/// 真实 Provider smoke test。
/// 仅当 LINGXI_PROVIDER_BASE_URL 与 LINGXI_PROVIDER_MODEL 同时存在时执行；
/// 否则静默跳过，CI / swift test 永不因缺 Key 失败。
struct RealProviderSmokeTests {
    @Test func realInferenceSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment[ProviderSetup.baseURLKey], !base.isEmpty,
              let model = environment[ProviderSetup.modelKey], !model.isEmpty
        else {
            print("[smoke] 跳过：未设置 LINGXI_PROVIDER_BASE_URL / LINGXI_PROVIDER_MODEL")
            return
        }

        let (assembly, missing) = ProviderSetup.resolve(environment)
        #expect(missing.isEmpty)
        let host = CoreHost(providerAssembly: assembly)
        await host.start()
        let client = LingXiClient.inProcess(endpoint: host)

        do {
            let sessionID = try await client.createSession()
            let prompts = [
                "记住：我叫 LingXiFox。只回复：记住了。",
                "我刚才说我叫什么？只回复名字。",
                "请用一句话总结我们前两轮对话。",
            ]
            var replies: [String] = []

            for (index, prompt) in prompts.enumerated() {
                let stream = try await client.sendMessage(sessionID: sessionID, content: prompt)
                var text = ""
                var reasoningChunks = 0
                for try await chunk in stream {
                    switch chunk.kind {
                    case .text: text += chunk.text
                    case .reasoning: reasoningChunks += 1
                    }
                }
                replies.append(text)
                print("[smoke] turn=\(index + 1) reasoningChunks=\(reasoningChunks) assistant=\(text)")

                let snapshot = try await client.session(sessionID)
                #expect(snapshot.messages.count == (index + 1) * 2)
                #expect(snapshot.messages.last?.role == .assistant)
                #expect(snapshot.messages.last?.content == text)
            }

            #expect(replies[1].lowercased().contains("lingxifox"), "第二轮应记住第一轮给出的名字")
            #expect(replies[2].lowercased().contains("lingxifox"), "第三轮总结应引用前两轮上下文")
            await host.shutdown()
        } catch {
            await host.shutdown()
            throw error
        }
    }
}
