import Foundation
import LingXiPluginSDK

@main
struct FoxPlugin: LingXiPlugin {
    init() {}

    var manifest: LingXiPluginSDK.PluginManifest {
        LingXiPluginSDK.PluginManifest(
            id: "fox-plugin",
            name: "LingXiAgent 诊断插件",
            version: "1.0.0",
            description: "LingXiAgent 官方参考插件：提供双核运行指标诊断与 /fox-info 交互命令",
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
            context.logger.info("LingXiAgent 诊断插件收到会话启动事件: \(payload.subjectID)")
        }
    }
}

/// 用户交互命令：/fox-info
struct FoxInfoCommand: PluginCommand {
    let name = "fox-info"
    let aliases = ["fox", "fox-health"]
    let description = "查看 LingXiAgent 诊断插件状态、双核指标与当前工作区详情"
    let category = "Plugin"

    func execute(args: [String], context: CommandExecutionContext) async throws -> PluginCommandResult {
        // 每一段都可能缺席。Core 没推送的段落显示「宿主未发布」，而不是 0 / idle /
        // unknown —— 那些值过去看起来像真数据，插件因此分不清「宿主闲着」和
        // 「宿主没告诉我」。
        func render(_ body: () async throws -> String) async -> String {
            do { return try await body() }
            catch is PluginInfoUnavailable { return "宿主未发布" }
            catch { return "读取失败" }
        }
        let workspaceLine = await render {
            let ws = try await context.info.getWorkspaceInfo()
            let dirty = ws.dirtyFileCount.map { "\($0) 个" } ?? "非 Git 仓库"
            return "\n  • 当前工作区   : \(ws.rootPath)\n"
                + "  • Git 分支     : \(ws.currentGitBranch ?? "非 Git 仓库") (未提交变更: \(dirty))\n"
                + "  • 核心版本     : \(ws.coreVersion)"
        }
        let contextLine = await render {
            let ctx = try await context.info.getContextState()
            var lines: [String] = []
            lines.append("  • 活跃模型     : \(ctx.activeModelID ?? "宿主未发布")")
            lines.append("  • 消息数       : \(ctx.messageCount.map(String.init) ?? "宿主未发布")")
            lines.append("  • 窗口占比     : \(ctx.contextWindowPercentage.map { String(format: "%.1f%%", $0 * 100) } ?? "宿主未发布")")
            return lines.joined(separator: "\n")
        }
        let peLine = await render {
            let pe = try await context.info.getPECoreInfo()
            return "  • P-Core       : \(pe.pCoreTokens.map { "\($0) tokens" } ?? "宿主未发布")\n"
                + "  • E-Core       : 对象 \(pe.eCoreObjects.map(String.init) ?? "宿主未发布") 个 / 引用 \(pe.eCoreReferences.map(String.init) ?? "宿主未发布") 条\n"
                + "  • 思考深度     : \(pe.reasoningEffort ?? "宿主未发布")"
                + "\n  • 后台任务     : \(pe.backgroundTaskCount.map(String.init) ?? "宿主未发布")"
        }
        let performanceLine = await render {
            let perf = try await context.info.getPerformanceInfo()
            return "  • 首字延迟     : \(perf.timeToFirstTokenMs.map { String(format: "%.0f ms", $0) } ?? "宿主未发布")"
        }

        let info = """
          • 插件 ID     : fox-plugin v1.0.0 (进程物理隔离运行)
        \(workspaceLine)
        \(contextLine)
        \(peLine)
        \(performanceLine)
          • 附加参数     : \(args.isEmpty ? "无" : args.joined(separator: " "))

        外部二进制插件经 JSON Lines IPC 连接 LingXiAgent；上面每一行都来自 Core 推送的权威快照，缺席的段落是宿主确实没有发布。
        """
        return .message(info, presentation: .modal, title: "LingXiAgent 诊断插件 (/fox-info)")
    }
}

/// 模型自主调用工具：fox_ping
struct FoxPingTool: PluginTool {
    let name = "fox_ping"
    let description = "LingXiAgent 诊断探针：返回插件进程的心跳与当前系统时间戳"
    let inputSchema = """
    {
      "type": "object",
      "properties": {
        "message": { "type": "string", "description": "发送给诊断插件的消息" }
      }
    }
    """

    func execute(arguments: String, context: LingXiPluginSDK.ToolExecutionContext) async throws -> String {
        context.logger.info("fox_ping 被调用，参数: \(arguments)")
        return "Pong! LingXiAgent 诊断插件收到消息: \(arguments)，插件进程运行正常！"
    }
}
