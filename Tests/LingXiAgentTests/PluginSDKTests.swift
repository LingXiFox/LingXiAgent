import Foundation
import Testing
import LingXiProtocol
import LingXiPlatform
import LingXiPluginSDK
import LingXiClient
import LingXiApplication
@testable import LingXiCore

// 模拟测试插件
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

    @Test func pluginDriverHandlesHandshakeAndToolExecutionInProcess() async throws {
        let plugin = TestEchoPlugin()
        let driver = PluginDriver(plugin: plugin)

        // 1. 测试握手
        let initReq = PluginIPCRequest(id: "1", method: "plugin.initialize")
        let initResp = await driver.handleRequest(initReq)
        #expect(initResp.error == nil)
        guard let data = initResp.result else {
            Issue.record("Missing handshake result")
            return
        }
        let handshake = try JSONDecoder().decode(PluginHandshakeResult.self, from: data)
        #expect(handshake.manifest.id == "echo-fixture")
        #expect(handshake.tools.count == 1)
        #expect(handshake.tools.first?.name == "test_echo")
        #expect(handshake.commands.count == 2)

        // 2. 测试工具执行
        let toolParams = PluginToolCallParams(toolName: "test_echo", arguments: "Hello Swift", sessionID: "s1", toolCallID: "tc1")
        let toolData = try JSONEncoder().encode(toolParams)
        let toolReq = PluginIPCRequest(id: "2", method: "tool.execute", params: toolData)
        let toolResp = await driver.handleRequest(toolReq)
        #expect(toolResp.error == nil)
        let toolOutput = try JSONDecoder().decode(String.self, from: toolResp.result!)
        #expect(toolOutput == "Echo: Hello Swift")
    }

    @Test func pluginDriverHandlesCommandExecutionBothMessageAndPrompt() async throws {
        let plugin = TestEchoPlugin()
        let driver = PluginDriver(plugin: plugin)

        // 1. 本地 message 命令测试
        let cmdParams = PluginCommandCallParams(commandName: "test-cmd", arguments: ["foo", "bar"], sessionID: "s1")
        let cmdReq = PluginIPCRequest(id: "3", method: "command.execute", params: try JSONEncoder().encode(cmdParams))
        let cmdResp = await driver.handleRequest(cmdReq)
        #expect(cmdResp.error == nil)
        let callRes = try JSONDecoder().decode(PluginCommandCallResult.self, from: cmdResp.result!)
        #expect(callRes.isPrompt == false)
        #expect(callRes.text == "Executed with: foo, bar")
        #expect(callRes.presentation == "modal")

        // 2. Prompt 命令测试
        let promptParams = PluginCommandCallParams(commandName: "test-prompt", arguments: ["deep-scan"], sessionID: "s1")
        let promptReq = PluginIPCRequest(id: "4", method: "command.execute", params: try JSONEncoder().encode(promptParams))
        let promptResp = await driver.handleRequest(promptReq)
        #expect(promptResp.error == nil)
        let promptRes = try JSONDecoder().decode(PluginCommandCallResult.self, from: promptResp.result!)
        #expect(promptRes.isPrompt == true)
        #expect(promptRes.text.contains("Please inspect workspace"))
        #expect(promptRes.text.contains("deep-scan"))
    }

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
        try markdown.write(to: file, atomically: true, encoding: .utf8)

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

    @Test func readOnlyInfoHubProvidesAccurateMetrics() async throws {
        let infoHub = DefaultPluginInfoHub(
            contextState: PluginContextStateInfo(
                activeModelID: "gpt-4o",
                totalTokenUsage: 15400,
                contextWindowPercentage: 0.12,
                isCompacted: false,
                messageCount: 8
            ),
            peCore: PluginPECoreInfo(
                pCoreRole: "reasoning",
                eCoreRole: "executingTool",
                reasoningEffort: "high",
                pCoreToECoreTimeRatio: 2.5,
                cacheDebt: 0.05,
                backgroundTaskCount: 2
            ),
            performance: PluginPerformanceInfo(
                timeToFirstTokenMs: 320,
                reasoningDurationMs: 1400,
                toolExecutionDurationMs: 250,
                providerLatencyAverageMs: 120,
                isRateLimited: false
            )
        )

        let ctxState = try await infoHub.getContextState()
        #expect(ctxState.activeModelID == "gpt-4o")
        #expect(ctxState.totalTokenUsage == 15400)
        #expect(ctxState.contextWindowPercentage == 0.12)

        let pe = try await infoHub.getPECoreInfo()
        #expect(pe.pCoreRole == "reasoning")
        #expect(pe.reasoningEffort == "high")
        #expect(pe.pCoreToECoreTimeRatio == 2.5)

        let perf = try await infoHub.getPerformanceInfo()
        #expect(perf.timeToFirstTokenMs == 320)
        #expect(perf.isRateLimited == false)
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
        try auditContent.write(to: auditFixtureURL, atomically: true, encoding: .utf8)

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



