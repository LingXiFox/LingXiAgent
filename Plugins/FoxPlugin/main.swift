import Foundation
import LingXiPluginSDK

@main
struct FoxPlugin: LingXiPlugin {
    init() {}

    var manifest: LingXiPluginSDK.PluginManifest {
        LingXiPluginSDK.PluginManifest(
            id: "fox-plugin",
            name: "灵犀小狐狸健康管家",
            version: "1.0.0",
            description: "灵犀官方参考插件：提供双核运行指标诊断与 /fox-info 交互命令",
            author: "LingXiFox",
            capabilities: [.projectRead]
        )
    }

    func activate(context: PluginContext) async throws {
        // 1. 注册供终端用户敲击的交互命令: /fox-info
        context.registerCommand(FoxInfoCommand())

        // 2. 注册供大模型调用的自主 Tool: fox_ping
        context.registerTool(FoxPingTool())

        // 3. 注册生命周期钩子
        context.on(.sessionStart) { payload in
            context.logger.info("🦊 灵犀小狐狸插件感知到新会话启动: \(payload.subjectID)")
        }
    }
}

/// 用户交互命令：/fox-info
struct FoxInfoCommand: PluginCommand {
    let name = "fox-info"
    let aliases = ["fox", "fox-health"]
    let description = "查看小狐狸插件状态、双核指标与当前工作区详情"
    let category = "Plugin"

    func execute(args: [String], context: CommandExecutionContext) async throws -> PluginCommandResult {
        let ws = try await context.info.getWorkspaceInfo()
        let pe = try await context.info.getPECoreInfo()
        let ctx = try await context.info.getContextState()
        let perf = try await context.info.getPerformanceInfo()

        let info = """
          • 插件 ID     : fox-plugin v1.0.0 (进程物理隔离运行)
          • 当前工作区   : \(ws.rootPath)
          • Git 分支     : \(ws.currentGitBranch ?? "非 Git 仓库") (未提交文件: \(ws.dirtyFileCount) 个)
          • 核心版本     : \(ws.coreVersion)
          • 双核分工     : P-Core=\(pe.pCoreRole) · E-Core=\(pe.eCoreRole)
          • 思考深度     : \(pe.reasoningEffort) (双核耗时比: \(String(format: "%.2f", pe.pCoreToECoreTimeRatio)))
          • 活跃模型     : \(ctx.activeModelID) (窗口占比: \(String(format: "%.1f%%", ctx.contextWindowPercentage * 100)))
          • 首字延迟     : \(perf.timeToFirstTokenMs) ms
          • 附加参数     : \(args.isEmpty ? "无" : args.joined(separator: " "))

        🐾 恭喜主人！外部二进制插件已成功通过 IPC 沙箱在 LingXiAgent 跑通！
        """
        return .message(info, presentation: .modal, title: "小狐狸健康管家 (/fox-info)")
    }
}

/// 模型自主调用工具：fox_ping
struct FoxPingTool: PluginTool {
    let name = "fox_ping"
    let description = "小狐狸探针工具：返回插件进程的心跳与当前系统时间戳"
    let inputSchema = """
    {
      "type": "object",
      "properties": {
        "message": { "type": "string", "description": "要发送给小狐狸的问候语" }
      }
    }
    """

    func execute(arguments: String, context: LingXiPluginSDK.ToolExecutionContext) async throws -> String {
        context.logger.info("fox_ping 被调用，参数: \(arguments)")
        return "🦊 Pong! 小狐狸收到你的消息: \(arguments)，插件进程运行正常！"
    }
}
