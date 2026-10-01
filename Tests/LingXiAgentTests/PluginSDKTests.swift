import Foundation
import Testing
import LingXiProtocol
import LingXiPlatform
import LingXiPluginSDK
import LingXiClient
import LingXiApplication
@testable import LingXiCore

// Core / Application 侧的插件集成测试。SDK 自身的线格式、握手、快照与存储行为由
// Tests/LingXiPluginSDKTests 覆盖 —— 那些是插件 SDK 的契约,重复一份只会漂移。
// 这里只留下需要整条 Agent 链路才能验证的部分:插件命令如何进入应用命令注册表、
// Core 的自定义命令引擎如何解析插件贡献的命令。
struct TestEchoPlugin: LingXiPlugin {
    init() {}

    var manifest: LingXiPluginSDK.PluginManifest {
        LingXiPluginSDK.PluginManifest(
            id: "echo-fixture",
            name: "Echo Fixture Plugin",
            version: "1.0.0",
            description: "Test fixture plugin for verifying LingXiPluginSDK",
            capabilities: [.projectRead]
        )
    }

    func activate(context: PluginContext) async throws {
        context.registerTool(EchoTool())
        context.registerCommand(EchoCommand())
        context.registerCommand(PromptCommand())
        context.on(.sessionStart) { payload in
            context.logger.info("Session started: \(payload.subjectID)")
        }
    }
}

struct EchoTool: PluginTool {
    let name = "test_echo"
    let description = "Echo back input argument"

    func execute(arguments: String, context: LingXiPluginSDK.ToolExecutionContext) async throws -> String {
        return "Echo: \(arguments)"
    }
}

struct EchoCommand: PluginCommand {
    let name = "test-cmd"
    let aliases = ["tcmd"]
    let description = "Local message command"

    func execute(args: [String], context: CommandExecutionContext) async throws -> PluginCommandResult {
        return .message("Executed with: \(args.joined(separator: ", "))")
    }
}

struct PromptCommand: PluginCommand {
    let name = "test-prompt"
    let description = "Prompt generator command"

    func execute(args: [String], context: CommandExecutionContext) async throws -> PluginCommandResult {
        let ws = try await context.info.getWorkspaceInfo()
        return .prompt("Please inspect workspace: \(ws.rootPath) with args: \(args.joined(separator: " "))")
    }
}

struct PluginSDKTests {

    @Test func customCommandEngineParsesMarkdownAndInterpolatesVariables() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("custom-cmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("review.md")
        let markdown = """
        ---
        description: Review staged files
        category: CodeReview
        arguments: [target]
        type: prompt
        ---
        Please review: $ARGUMENTS in $WORKSPACE.
        First target: $1, Second target: $2.
        """
        try markdown.write(to: file, atomically: false, encoding: .utf8)

        let parsed = CustomCommandEngine.parse(fileURL: file, isProjectScope: true)
        #expect(parsed != nil)
        #expect(parsed?.name == "review")
        #expect(parsed?.description == "Review staged files")
        #expect(parsed?.category == "CodeReview")
        #expect(parsed?.type == .prompt)

        let interpolated = CustomCommandEngine.interpolate(
            template: parsed!.template,
            arguments: ["Package.swift", "Sources/"],
            workspaceRoot: "/project"
        )
        #expect(interpolated.contains("Please review: Package.swift Sources/ in /project."))
        #expect(interpolated.contains("First target: Package.swift, Second target: Sources/."))
    }

    @Test func applicationCommandRegistryAggregatesBuiltinPluginAndCustomCommands() async throws {
        // 创建隔离的临时自定义命令 fixture，保证测试 100% Hermetic
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-cmd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let auditFixtureURL = tempDir.appendingPathComponent("audit.md")
        let auditContent = """
        ---
        description: 对当前代码仓或指定路径进行架构合规性审查
        category: Custom
        arguments: "[file-or-dir]"
        type: prompt
        ---
        🦊 [自定义提示词宏 /audit] 已展开：审查 $ARGUMENTS
        """
        try auditContent.write(to: auditFixtureURL, atomically: false, encoding: .utf8)

        let registry = ApplicationCommandRegistry(customRoots: [tempDir])
        registry.register(ApplicationCommand(name: "test-builtin", description: "Builtin test", category: "General") { _ in
            ApplicationCommandResult(output: "builtin-ok")
        })

        // 1. 同步插件扩展
        let coreHost = try CoreHost()
        let client = try await LingXiClientVNext(transport: InProcessTransport(service: coreHost))
        let pluginExt = ExtensionInfo(
            id: "fox-info",
            version: "1.0.0",
            kind: .command,
            scope: "project",
            enabled: true,
            lifecycleState: "enabled",
            summary: "Fox diagnostic info"
        )

        registry.syncPluginCommands(from: [pluginExt], client: client)

        // 2. 检查 allCommands
        let commands = registry.allCommands
        #expect(commands.contains(where: { $0.name == "test-builtin" }))
        #expect(commands.contains(where: { $0.name == "fox-info" }))

        let foxCmd = registry.command(named: "fox-info")
        #expect(foxCmd != nil)
        #expect(foxCmd?.category == "Plugin")
        #expect(foxCmd?.description == "Fox diagnostic info")

        // 3. 测试执行自定义指令 /audit
        let state = ApplicationState()
        let auditRes = try await registry.execute(
            input: "/audit Sources/LingXiPluginSDK",
            sessionID: nil,
            client: client,
            state: state
        )
        #expect(auditRes.output.contains("自定义提示词宏"))
        #expect(auditRes.revertedComposerText?.contains("Sources/LingXiPluginSDK") == true)

        // 4. 测试执行 /plugins
        for cmd in BuiltinCommands.createAll() {
            registry.register(cmd)
        }
        let pluginsRes = try await registry.execute(
            input: "/plugins",
            sessionID: nil,
            client: client,
            state: state
        )
        #expect(!pluginsRes.output.isEmpty)
    }

    @Test func backwardCompatibleDecodingWithoutPresentationField() throws {
        // 验证旧插件或报文中不含 presentation 字段时，PluginCommandCallResult 正确降级为 "modal"
        let legacyCallResultJSON = """
        {
            "isPrompt": false,
            "text": "Hello legacy plugin",
            "title": "Legacy Title"
        }
        """.data(using: .utf8)!

        let callResult = try JSONDecoder().decode(PluginCommandCallResult.self, from: legacyCallResultJSON)
        #expect(callResult.isPrompt == false)
        #expect(callResult.text == "Hello legacy plugin")
        #expect(callResult.presentation == "modal")
        #expect(callResult.title == "Legacy Title")

        // 验证 ExtensionCommandExecutionResult 同样平滑容错
        let legacyExecResultJSON = """
        {
            "name": "fox-info",
            "output": "Some legacy output",
            "isPrompt": false
        }
        """.data(using: .utf8)!

        let execResult = try JSONDecoder().decode(ExtensionCommandExecutionResult.self, from: legacyExecResultJSON)
        #expect(execResult.name == "fox-info")
        #expect(execResult.output == "Some legacy output")
        #expect(execResult.isPrompt == false)
        #expect(execResult.presentation == "modal")
        #expect(execResult.title == nil)
    }
}



