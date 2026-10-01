import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiProtocol
import LingXiModelSDK
import LingXiPluginSDK
@testable import LingXiCore

/// 远程 SwiftPM 依赖 → LingXiAgent target → `import` → Core 消费,整条链路的集成契约。
///
/// 这里刻意不重复 SDK 仓库自己的单测（解码、缓存、线格式那些归它们）。要证明的只有一件
/// 事：Agent 用的就是第三方拿得到的那份构件,而且 Core 只通过公共 API 使用它。
@Suite("Public SDK integration", .serialized)
struct LingXiAgentPublicModelSDKIntegrationTests {

    private static let document = """
    {
      "schemaVersion": "2.0", "catalogRevision": "agent-integration-1",
      "catalogHash": "sha256:aaaa", "generatedAt": "2026-09-30T00:00:00Z",
      "source": "models.dev", "sourceURL": "https://models.dev/api.json",
      "sourceHash": "sha256:bbbb", "totalProviders": 1, "totalModels": 2,
      "providers": {
        "deepseek": {
          "id": "deepseek", "name": "DeepSeek", "api": "https://api.deepseek.com",
          "baseURL": "https://api.deepseek.com", "env": ["DEEPSEEK_API_KEY"],
          "doc": "https://api.deepseek.com/docs", "modelCount": 2,
          "models": {
            "deepseek-v4": { "id": "deepseek-v4", "name": "DeepSeek V4", "family": "deepseek",
              "release_date": "2026-03-01", "reasoning": true, "tool_call": true, "attachment": true,
              "structured_output": true, "modalities": { "input": ["text", "image"], "output": ["text"] },
              "limit": { "context": 1000000, "output": 640000 }, "cost": { "input": 0.14, "output": 0.28 } },
            "deepseek-v3": { "id": "deepseek-v3", "name": "DeepSeek V3", "status": "deprecated",
              "modalities": { "input": ["text"], "output": ["text"] },
              "limit": { "context": 64000, "output": 8000 }, "cost": { "input": 0.14, "output": 0.28 } }
          }
        }
      }
    }
    """

    private struct Stub: ModelCatalogTransport {
        func respond(to request: URLRequest) async throws -> (Data, URLResponse) {
            (Data(Self.body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                  httpVersion: nil, headerFields: ["ETag": "\"t\""])!)
        }
        static let body = LingXiAgentPublicModelSDKIntegrationTests.document
    }

    private func client() async -> PublicModelCatalogClient {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-sdk-\(UUID().uuidString)", isDirectory: true)
        let injected = PublicModelCatalogClient(
            endpoint: URL(string: "https://models.test/models.json")!,
            cacheDirectory: directory,
            transport: Stub()
        )
        _ = await injected.refresh(force: true)
        try? FileManager.default.removeItem(at: directory)
        return injected
    }

    @Test("Core consumes the published catalog through the public SDK surface only")
    func coreConsumesPublicAPI() async throws {
        let catalog = try LingXiModelCatalog.decoded(from: Data(Stub.body.utf8))
        // Core-facing 答案全部来自 SDK 的公共类型，Agent 不再自解 JSON。
        #expect(catalog.revision.schemaVersion == "2.0")
        #expect(catalog.model(provider: "deepseek", id: "deepseek-v4")?.contextWindow == 1_000_000)
        #expect(catalog.sortedProviders().map(\.id) == ["deepseek"])

        let client = await client()
        let records = await client.publishedRecords(forProduct: "deepseek-api")
        #expect(records.map(\.id) == ["deepseek-v4", "deepseek-v3"])
        // 产品 id 与厂商 id 靠显式别名桥接：deepseek-api → deepseek。
        #expect(records.allSatisfy { $0.productID == "deepseek-api" })
        #expect(records.first { $0.id == "deepseek-v4" }?.capabilities.contextWindow == 1_000_000)
        // 状态由公共目录供给，运行时据此抑制过期模型。
        #expect(records.first { $0.id == "deepseek-v3" }?.modelStatus == .deprecated)
        #expect(records.first { $0.id == "deepseek-v3" }?.modelStatus.isSelectable == false)

        let discovered = await client.discoveredModels(forProduct: "deepseek-api")
        #expect(discovered.map(\.id) == ["deepseek-v4", "deepseek-v3"])
        #expect(discovered.first?.vision == true)
    }

    @Test("the catalog answers the per-model defaults Core applies to user config")
    func catalogDefaultsFlow() async throws {
        let defaults = await ModelCatalogDefaults.resolve(providerID: "deepseek", modelID: "deepseek-v4",
                                                 catalogClient: await client())
        #expect(defaults.contextWindow == 1_000_000)
        #expect(defaults.maxOutputTokens == 640_000)
        #expect(defaults.reasoning == true)
        #expect(defaults.vision == true)
        #expect(defaults.structuredOutput == true)
        // 没有任何公共来源会声明速限与重试策略：保持未设，由用户覆盖或 Core 兜底。
        #expect(defaults.tokensPerMinute == nil)
        #expect(defaults.maxRetries == nil)
    }

    @Test("the ordering the SDK publishes is what the agent renders")
    func orderingIsShared() throws {
        let catalog = try LingXiModelCatalog.decoded(from: Data(Stub.body.utf8))
        // 发布日期新的在前；无日期的不挤掉有日期的。
        #expect(catalog.models(provider: "deepseek").map(\.id) == ["deepseek-v4", "deepseek-v3"])
        let reSorted = LingXiModelCatalog.modelsInStableOrder(catalog.providers[0].models)
        #expect(reSorted.map(\.id) == catalog.providers[0].models.map(\.id),
                "发布顺序必须已经等于 SDK 的排序规则，否则两端各排一套")
    }
}

/// 插件侧的集成契约：Core 产生的快照必须能被公共 SDK 的 DTO 承载，且缺席段落以
/// 类型化错误呈现 —— 不许有第三种"看起来合理"的默认值。
struct PluginSDKIntegrationTests {

    @Test("Core's snapshot type round-trips through the published SDK codec")
    func snapshotCrossesTheProcessBoundary() async throws {
        let produced = PluginRuntimeSnapshot(
            peCore: PluginPECoreInfo(eCoreObjects: 5, eCoreReferences: 3,
                                      reasoningEffort: "high", backgroundTaskCount: 1),
            workspace: PluginWorkspaceInfo(rootPath: "/repo", isGitRepository: true,
                                           currentGitBranch: "main", dirtyFileCount: 2,
                                           coreVersion: CoreHost.coreVersion))
        // Core 侧写、插件进程侧读：这条线就是 host.snapshot 的真实路径。
        let decoded = try JSONDecoder().decode(PluginRuntimeSnapshot.self,
                                              from: JSONEncoder().encode(produced))
        #expect(decoded == produced)
        #expect(decoded.ipcVersion == PluginIPC.currentVersion)

        let hub = DefaultPluginInfoHub()
        await hub.apply(decoded)
        #expect(try await hub.getWorkspaceInfo().currentGitBranch == "main")
        #expect(try await hub.getPECoreInfo().eCoreObjects == 5)
        // Core 没发布的段落，插件读到的仍然是显式不可用，而不是 0。
        await #expect(throws: (any Error).self) { _ = try await hub.getPerformanceInfo() }
    }

    @Test("Core publishes only the sections it actually knows")
    func coreSnapshotIsHonest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-plugin-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConfigurationStore(dataRoot: root)
        _ = try await store.load()
        let host = try CoreHost(configurationStore: store)

        // 没有会话：上下文与 P/E 段落应当缺席，而不是被填成 idle / 0。
        let withoutSession = await host.pluginRuntimeSnapshot(sessionID: nil)
        #expect(withoutSession.contextState == nil)
        #expect(withoutSession.peCore == nil)
        #expect(withoutSession.performance == nil)
        #expect(withoutSession.workspace?.isGitRepository == false,
                "宿主跑在非 Git 目录时必须照实说，而不是给一个假的分支名")
        #expect(withoutSession.workspace?.currentGitBranch == nil)
        #expect(withoutSession.workspace?.dirtyFileCount == nil)
        #expect(withoutSession.workspace?.coreVersion == CoreHost.coreVersion)
        #expect(withoutSession.ipcVersion == PluginIPC.currentVersion)

        // 插件读到这份快照后，未发布的段落必须抛错。
        let hub = DefaultPluginInfoHub()
        await hub.apply(withoutSession)
        let publishedRoot = try #require(withoutSession.workspace?.rootPath)
        #expect(try await hub.getWorkspaceInfo().rootPath == publishedRoot,
                "插件读到的工作区必须与 Core 发布的完全一致")
        #expect(try await hub.getWorkspaceInfo().isGitRepository == false)
        await #expect(throws: PluginInfoUnavailable(field: .contextState,
                                                    lastObservedAt: withoutSession.observedAt)) {
            _ = try await hub.getContextState()
        }
    }

    @Test("a plugin built against the public SDK registers tools and hooks the host can route")
    func pluginSurfaceReachesTheHost() async throws {
        let holder = HookRecorder()
        let driver = PluginDriver(plugin: IntegrationProbe(holder: holder))

        let snapshot = PluginRuntimeSnapshot(
            peCore: nil,
            workspace: PluginWorkspaceInfo(rootPath: "/workspace", isGitRepository: true,
                                           currentGitBranch: "topic", coreVersion: "1.1.0"))
        let snapshotData = try JSONEncoder().encode(snapshot)
        let snapshotResponse = await driver.handleRequest(
            PluginIPCRequest(id: "1", method: .snapshot, params: snapshotData))
        #expect(snapshotResponse.error == nil)

        let toolParams = try JSONEncoder().encode(PluginToolCallParams(
            toolName: "fox_report", arguments: "hi", sessionID: "s", toolCallID: "c"))
        let toolResponse = await driver.handleRequest(
            PluginIPCRequest(id: "2", method: .toolExecute, params: toolParams))
        #expect(try JSONDecoder().decode(String.self, from: try #require(toolResponse.result)) == "s:hi")

        // 命令经由 info 枢纽读到 Core 推送的工作区：快照确实落进了插件侧。
        let commandParams = try JSONEncoder().encode(PluginCommandCallParams(
            commandName: "fox-status", arguments: [], sessionID: nil))
        let commandResponse = await driver.handleRequest(
            PluginIPCRequest(id: "2b", method: .commandExecute, params: commandParams))
        let status = try JSONDecoder().decode(PluginCommandCallResult.self,
                                              from: try #require(commandResponse.result))
        #expect(status.text == "/workspace|topic")

        let hook = try JSONEncoder().encode(PluginHookPayload(event: .sessionStart, subjectID: "s-7"))
        let hookResponse = await driver.handleRequest(
            PluginIPCRequest(id: "3", method: .hookEmit, params: hook))
        #expect(hookResponse.error == nil)
        #expect(await holder.payload == "s-7")
    }
}

/// Core 里也有一个叫 `ToolExecutionContext` 的类型，所以插件侧的名字全部限定。
final class HookRecorder: @unchecked Sendable {
    private(set) var payload = ""
    func remember(_ value: String) { payload = value }
}

/// Tool 上下文只带 sessionID / toolCallID / logger：工具执行的是计算，
/// 读取宿主运行时状态是 command 侧 `CommandExecutionContext.info` 的职责。
private struct ProbeReport: LingXiPluginSDK.PluginTool {
    var name: String { "fox_report" }
    var description: String { "Echoes its argument back." }
    func execute(arguments: String, context: LingXiPluginSDK.ToolExecutionContext) async throws -> String {
        "\(context.sessionID):\(arguments)"
    }
}

private struct ProbeStatus: LingXiPluginSDK.PluginCommand {
    var name: String { "fox-status" }
    var description: String { "Reports what the host published." }
    func execute(args: [String], context: LingXiPluginSDK.CommandExecutionContext) async throws -> LingXiPluginSDK.PluginCommandResult {
        let info = try await context.info.getWorkspaceInfo()
        return .message("\(info.rootPath)|\(info.currentGitBranch ?? "-")")
    }
}

private struct IntegrationProbe: LingXiPluginSDK.LingXiPlugin {
    let holder: HookRecorder
    init() { fatalError("only the injected form is used") }
    init(holder: HookRecorder) { self.holder = holder }
    var manifest: LingXiPluginSDK.PluginManifest {
        LingXiPluginSDK.PluginManifest(id: "com.lingxi.integration-probe", name: "Probe",
                                        version: "0.1.0", description: "Integration probe",
                                        capabilities: [.projectRead])
    }
    func activate(context: LingXiPluginSDK.PluginContext) async throws {
        context.registerTool(ProbeReport())
        context.registerCommand(ProbeStatus())
        context.on(.sessionStart) { payload in self.holder.remember(payload.subjectID) }
    }
}
