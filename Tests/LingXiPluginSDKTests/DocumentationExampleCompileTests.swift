import Foundation
import Testing
@testable import LingXiPluginSDK

/// §38 的文档示例门禁:README 与 agent.lingxifox.cn/sdk.html 里出现的每一种写法,
/// 都必须在这里以同样的形态编译通过。文档先发明 API、代码事后追,是这套 SDK 上一轮
/// 最大的问题(`tool.call`、`LingXiAgent.model(...)` 都曾只活在网页里)。
struct DocumentationExampleCompileTests {

    /// README 的 5 分钟上手示例,逐字对应的形态。
    private struct MyPlugin: LingXiPlugin {
        init() {}

        var manifest: PluginManifest {
            PluginManifest(
                id: "com.example.my-plugin",
                name: "My Plugin",
                version: "0.1.0",
                description: "Example LingXiAgent plugin"
            )
        }

        func activate(context: PluginContext) async throws {
            context.registerTool(EchoTool())
            context.registerCommand(StatusCommand())
            context.on(.sessionStart) { payload in
                context.logger.info("session started: \(payload.subjectID)")
            }
            context.logger.info("Plugin activated")
        }
    }

    private struct EchoTool: PluginTool {
        var name: String { "echo" }
        var description: String { "Echoes its argument back." }
        func execute(arguments: String, context: ToolExecutionContext) async throws -> String {
            context.logger.info("echo from session \(context.sessionID)")
            return arguments
        }
    }

    private struct StatusCommand: PluginCommand {
        var name: String { "status" }
        var description: String { "Reports what the host published." }
        var argumentHint: String { "" }

        func execute(args: [String], context: CommandExecutionContext) async throws -> PluginCommandResult {
            guard let workspace = try? await context.info.getWorkspaceInfo() else {
                // 宿主没推快照时,示例也不假装知道:文档里的错误文案与之一致。
                return .message("运行时信息尚未由宿主推送", presentation: .inline)
            }
            return .message("工作区 \(workspace.rootPath)（\(workspace.currentGitBranch ?? "非 Git")）")
        }
    }

    @Test("the documented plugin, tool, command and hook wiring compiles and registers")
    func quickStart() async throws {
        let hub = DefaultPluginInfoHub()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-plugin-sdk-doc-\(UUID().uuidString)", isDirectory: true)
        let context = PluginContext(
            pluginID: "com.example.my-plugin",
            info: hub,
            storage: FilePluginStorage(directory: directory),
            logger: PluginLogger(pluginID: "com.example.my-plugin", writeHandler: { _, _ in })
        )
        let plugin = MyPlugin()
        try await plugin.activate(context: context)

        #expect(context.allTools.map(\.name) == ["echo"])
        #expect(context.allCommands.map(\.name) == ["status"])
        #expect(context.registeredHookEvents == [.sessionStart])

        let output = try await context.allTools[0].execute(
            arguments: "hello", context: ToolExecutionContext(sessionID: "s-1", toolCallID: "c-1", logger: context.logger))
        #expect(output == "hello")

        let withoutSnapshot = try await context.allCommands[0].execute(
            args: [], context: CommandExecutionContext(sessionID: nil, info: hub, logger: context.logger))
        switch withoutSnapshot {
        case let .message(text, presentation, _):
            #expect(text.contains("尚未由宿主推送"))
            #expect(presentation == .inline)
        case .prompt:
            Issue.record("示例命令不该产出 prompt")
        }

        await hub.apply(PluginRuntimeSnapshot(
            workspace: PluginWorkspaceInfo(rootPath: "/repo", isGitRepository: true,
                                          currentGitBranch: "main", coreVersion: "1.1.0")))
        let withSnapshot = try await context.allCommands[0].execute(
            args: [], context: CommandExecutionContext(sessionID: nil, info: hub, logger: context.logger))
        if case let .message(text, _, _) = withSnapshot {
            #expect(text == "工作区 /repo（main）")
        } else {
            Issue.record("期望 message 结果")
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// 握手包的文档形态:字段名一旦变化,网页上的 JSON 示例就是假的。
    @Test("the documented handshake and payload shapes are the real Codable shapes")
    func wireShapesMatchTheDocs() throws {
        let manifest = PluginManifest(id: "com.example.my-plugin", name: "My Plugin",
                                      version: "0.1.0", description: "Example LingXiAgent plugin")
        let handshake = PluginHandshakeResult(manifest: manifest, tools: [], commands: [], supportedHooks: [])
        let data = try JSONEncoder().encode(handshake)
        let text = String(decoding: data, as: UTF8.self)
        for documented in ["\"ipcVersion\"", "\"sdkVersion\"", "\"supportedHooks\"", "\"manifest\""] {
            #expect(text.contains(documented), "握手包缺少文档承诺的字段 \(documented)")
        }

        let manifestData = try JSONEncoder().encode(manifest)
        let decodedManifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        #expect(decodedManifest == manifest)
        #expect(decodedManifest.capabilities.isEmpty)
        // 能力是权限申请,不是协议协商:两套字段各自独立存在。
        #expect(Set(PluginCapability.allCases.map(\.rawValue))
                == Set(["projectRead", "projectWrite", "processExecution", "networkAccess"]))
    }

    /// `PluginStorage` 的说明必须与实现一致:它是 SDK 托管的插件私有 KV,
    /// 不是操作系统级沙箱。
    @Test("the documented plugin-local storage abstraction really stores per plugin")
    func storageContract() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-plugin-sdk-store-\(UUID().uuidString)", isDirectory: true)
        let storage = FilePluginStorage(directory: directory)
        try await storage.set(key: "greeting", value: "hello")
        #expect(try await storage.get(key: "greeting") == "hello")
        try await storage.remove(key: "greeting")
        #expect(try await storage.get(key: "greeting") == nil)
        #expect(try await storage.get(key: "never-written") == nil)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// 文档里 `DefaultPluginStorage` 会把数据放在 `~/.lingxiagent/plugin-data/<plugin-id>`,
/// 测试需要一个可注入目录的同协议实现来避免污染真实宿主数据。
private struct FilePluginStorage: PluginStorage {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func get(key: String) async throws -> String? {
        guard let data = try? Data(contentsOf: file(key)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(key: String, value: String) async throws {
        try Data(value.utf8).write(to: file(key), options: .atomic)
    }

    func remove(key: String) async throws {
        try? FileManager.default.removeItem(at: file(key))
    }

    private func file(_ key: String) -> URL { directory.appendingPathComponent(key) }
}
