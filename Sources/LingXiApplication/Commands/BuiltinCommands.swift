import Foundation
import LingXiProtocol
import LingXiClient

/// 内建 20 个正式业务命令实现。
public enum BuiltinCommands {

    public static var all: [ApplicationCommand] {
        createAll()
    }

    public static func createAll() -> [ApplicationCommand] {
        [
            // 1. /model
            ApplicationCommand(
                name: "model",
                aliases: ["m"],
                description: "查看或切换当前模型",
                category: "Provider",
                argumentSchema: "[provider/model]"
            ) { ctx in
                if ctx.arguments.isEmpty {
                    let selection = try? await ctx.client.model.getSelection()
                    let selectedID = (selection?.modelID.isEmpty == false) ? selection?.modelID : nil
                    let current = selectedID ?? ctx.state.currentModelID ?? "未选择"
                    let effort = ctx.state.effectiveReasoningEffort.rawValue
                    let output = CLIFormatter.renderCard(
                        title: "当前模型 (/model)",
                        fields: [
                            ("当前活动模型", current),
                            ("当前思考等级", effort)
                        ],
                        footer: "切换模型: /model <provider/model> · 切换思考等级: /reasoning <effort> 或 Ctrl+t",
                        borderStyle: .rounded
                    )
                    return ApplicationCommandResult(output: output)
                } else {
                    let modelName = ctx.arguments[0]
                    do {
                        _ = try await ctx.client.model.select(model: modelName)
                    } catch let error as CoreError where error.message.contains("not authenticated") {
                        return ApplicationCommandResult(output: error.message)
                    } catch {
                        let msg = error.localizedDescription
                        if msg.contains("not authenticated") {
                            return ApplicationCommandResult(output: msg)
                        }
                        throw error
                    }

                    let currentEffort = ctx.state.effectiveReasoningEffort
                    var effectiveEffort = currentEffort
                    var noteMessage: String? = nil
                    let caps = try? await ctx.client.model.getCapabilities(modelID: modelName)
                    if let cap = caps?.reasoningCapability {
                        let resolved = cap.resolveEffort(currentEffort)
                        effectiveEffort = resolved.effective
                        noteMessage = resolved.message
                    }

                    if let sessionID = ctx.sessionID, effectiveEffort != currentEffort {
                        _ = try? await ctx.client.session.setReasoningEffort(sessionID: sessionID, effort: effectiveEffort)
                    }

                    var supportedText = "auto, off, low, medium, high, max"
                    if let cap = caps?.reasoningCapability, !cap.supportedEfforts.isEmpty {
                        supportedText = cap.supportedEfforts.map(\.rawValue).joined(separator: ", ")
                    }

                    var fields: [(String, String)] = [
                        ("当前活动模型", modelName),
                        ("当前思考等级", effectiveEffort.rawValue),
                        ("支持思考等级", supportedText)
                    ]
                    if let note = noteMessage {
                        fields.append(("等级适配提示", note))
                    }

                    let output = CLIFormatter.renderCard(
                        title: "模型已切换 (/model)",
                        fields: fields,
                        footer: "显式设置思考等级: /reasoning <effort> · 或按 Ctrl+t 快捷切换",
                        borderStyle: .rounded
                    )
                    return ApplicationCommandResult(output: output, nextTurnReasoningEffort: effectiveEffort)
                }
            },

            // 2. /providers
            ApplicationCommand(
                name: "providers",
                aliases: [],
                description: "查看 Provider 列表与状态",
                category: "Provider"
            ) { ctx in
                let list = (try? await ctx.client.provider.list()) ?? []
                let pStatus = try? await ctx.client.provider.status()
                let statusVal = pStatus?.configured == true ? "✓ 已就绪 (\(pStatus?.model ?? "-"))" : "○ 未就绪"
                let accountLines = list.map { "  • [\($0.productID)] \($0.displayName) (\($0.availability))" }
                let output = CLIFormatter.renderCard(
                    title: "Provider 状态 (/providers)",
                    fields: [("网关状态", statusVal)],
                    sections: [("已配置账号 (\(list.count))", accountLines.isEmpty ? ["  (无已配置账号)"] : accountLines)],
                    footer: "配置 Provider: lingxiagent auth login <provider>",
                    borderStyle: .rounded
                )
                return ApplicationCommandResult(
                    output: output,
                    presentation: .modal,
                    modalTitle: "Provider 状态 (/providers)"
                )
            },

            // 3. /connect
            ApplicationCommand(
                name: "connect",
                aliases: [],
                description: "连接或配置 Provider",
                category: "Provider",
                argumentSchema: "[provider]"
            ) { ctx in
                let accounts = (try? await ctx.client.provider.list()) ?? []
                let accountLines = accounts.map { "  • [\($0.productID)] \($0.displayName)" }
                let output = CLIFormatter.renderCard(
                    title: "已接入 Provider (/connect)",
                    sections: [("已接入账号 (\(accounts.count))", accountLines.isEmpty ? ["  (无已接入账号)"] : accountLines)],
                    footer: "添加新 Provider: lingxiagent auth login <provider>",
                    borderStyle: .rounded
                )
                return ApplicationCommandResult(
                    output: output,
                    presentation: .modal,
                    modalTitle: "已接入 Provider (/connect)"
                )
            },

            // 4. /new
            ApplicationCommand(
                name: "new",
                aliases: [],
                description: "新建 Session",
                category: "Session"
            ) { ctx in
                let receipt = try await ctx.client.session.create(defaultMode: .build)
                guard let newID = receipt.result?.sessionID else {
                    throw ApplicationCommandError.executionFailed("创建会话未返回 SessionID")
                }
                return ApplicationCommandResult(
                    output: "已创建新会话: \(newID.rawValue)",
                    sessionIDToSwitch: newID
                )
            },

            // 5. /resume
            ApplicationCommand(
                name: "resume",
                aliases: [],
                description: "恢复历史会话 (按工作目录分类)",
                category: "Session",
                argumentSchema: "[sessionID]"
            ) { ctx in
                let sessions = try await ctx.client.session.listAll()
                let currentCwd = ctx.state.currentWorkspace?.rootPath ?? FileManager.default.currentDirectoryPath

                if let target = ctx.arguments.first {
                    // 支持短 ID / 前缀匹配
                    let matched = sessions.first { $0.sessionID.rawValue == target }
                        ?? sessions.first { $0.sessionID.rawValue.lowercased().hasPrefix(target.lowercased()) }
                    let targetID = matched?.sessionID ?? SessionID(target)
                    let targetDir = matched?.workingDirectory ?? currentCwd
                    var msg = "已切换到会话: \(targetID.rawValue)"
                    if targetDir != currentCwd {
                        msg += "\n🔄 已自动切换工作目录至: \(targetDir)"
                    }
                    return ApplicationCommandResult(
                        output: msg,
                        sessionIDToSwitch: targetID
                    )
                } else {
                    if sessions.isEmpty {
                        return ApplicationCommandResult(output: "暂无可恢复的历史会话。")
                    }

                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "MM-dd HH:mm"

                    var sections: [String] = []
                    sections.append("可用历史会话 (按时间分块，共 \(sessions.count) 个):")
                    for group in SessionCatalog.timeGroups(sessions) {
                        var lines = ["[\(group.title)]"]
                        for s in group.sessions {
                            let title = (s.title ?? "未命名会话").components(separatedBy: .newlines).joined(separator: " ")
                            lines.append("  • \(s.sessionID.rawValue.prefix(8)) · \(dateFormatter.string(from: s.updatedAt)) · \(s.messageCount)条 · \(title)")
                        }
                        sections.append(lines.joined(separator: "\n"))
                    }
                    sections.append("提示: 输入 /resume <sessionID> 恢复指定会话；恢复非当前目录会话将自动切换工作文件夹。")
                    return ApplicationCommandResult(output: sections.joined(separator: "\n\n"))
                }
            },

            // 6. /rename
            ApplicationCommand(
                name: "rename",
                aliases: [],
                description: "重命名当前 Session",
                category: "Session",
                argumentSchema: "<title>"
            ) { ctx in
                guard let sessionID = ctx.sessionID else {
                    throw ApplicationCommandError.invalidArguments("当前无活动会话")
                }
                guard !ctx.arguments.isEmpty else {
                    throw ApplicationCommandError.invalidArguments("必须提供新标题")
                }
                let title = ctx.arguments.joined(separator: " ")
                _ = try await ctx.client.session.rename(sessionID: sessionID, title: title)
                return ApplicationCommandResult(output: "会话 \(sessionID.rawValue) 重命名为: \(title)")
            },

            // 6.5 /undo
            ApplicationCommand(
                name: "undo",
                aliases: ["rewind", "pop"],
                description: "撤回上一轮会话消息与回答",
                category: "Session",
                argumentSchema: ""
            ) { ctx in
                guard let sessionID = ctx.sessionID else {
                    return ApplicationCommandResult(output: "当前无活动会话。")
                }
                let res = try await ctx.client.session.revertLastTurn(sessionID: sessionID)
                if let prompt = res.revertedPrompt {
                    return ApplicationCommandResult(
                        output: "✓ 已撤回上一轮会话（共清理 \(res.removedCount) 条消息），原内容已填回输入框。",
                        revertedComposerText: prompt,
                        snapshot: res.snapshot
                    )
                } else {
                    return ApplicationCommandResult(output: "当前会话没有可以撤回的消息。")
                }
            },

            // 7. /status
            ApplicationCommand(
                name: "status",
                aliases: [],
                description: "查看全局与当前会话运行状态",
                category: "Runtime"
            ) { ctx in
                let s = ctx.state
                let sessionInfo = s.activeSessionID?.rawValue ?? "无活动会话"
                let statusStr = s.status.rawValue
                let modelStr = s.currentModelID ?? "未选择"
                let connStr = "\(s.connectionState)"
                let pendingCount = s.activeSessionState?.pendingInteractions.count ?? 0
                let output = CLIFormatter.renderCard(
                    title: "系统运行状态 (/status)",
                    fields: [
                        ("产品状态", statusStr),
                        ("连接状态", connStr),
                        ("活动模型", modelStr),
                        ("活动会话", sessionInfo),
                        ("待决交互", "\(pendingCount)")
                    ],
                    borderStyle: .rounded
                )
                return ApplicationCommandResult(
                    output: output,
                    presentation: .modal,
                    modalTitle: "系统运行状态 (/status)"
                )
            },

            // 8. /context
            ApplicationCommand(
                name: "context",
                aliases: [],
                description: "查看当前会话上下文分层与 Token 统计",
                category: "Runtime"
            ) { ctx in
                guard let sessionID = ctx.sessionID else {
                    throw ApplicationCommandError.invalidArguments("当前无活动会话")
                }
                let snapshot = try await ctx.client.context.getState(sessionID: sessionID)
                let output = CLIFormatter.renderCard(
                    title: "P-Core / E-Core 双核心上下文状态 (/context)",
                    fields: [
                        ("P-Core 活跃投影", "\(snapshot.activePCoreTokens) tokens"),
                        ("E-Core 观测对象", "\(snapshot.eCoreObjectCount ?? 0) objs (\(TokenFormatter.formatBytes(snapshot.eCoreTotalBytes ?? 0)))"),
                        ("前缀缓存命中", "\(snapshot.cacheReadTokens ?? 0) tokens (\(snapshot.cacheStatus ?? "active"))"),
                        ("缓存债务 (Debt)", "\(snapshot.cacheDebt ?? 0)")
                    ],
                    footer: "压缩上下文: /compact",
                    borderStyle: .rounded
                )
                return ApplicationCommandResult(
                    output: output,
                    presentation: .modal,
                    modalTitle: "双核心上下文状态 (/context)"
                )
            },

            // 9. /compact
            ApplicationCommand(
                name: "compact",
                aliases: [],
                description: "压缩当前会话上下文",
                category: "Runtime"
            ) { ctx in
                guard let sessionID = ctx.sessionID else {
                    throw ApplicationCommandError.invalidArguments("当前无活动会话")
                }
                _ = try await ctx.client.context.compact(sessionID: sessionID)
                return ApplicationCommandResult(output: "已对会话 \(sessionID.rawValue) 触发上下文压缩")
            },

            // 10. /perf
            ApplicationCommand(
                name: "perf",
                aliases: [],
                description: "查看运行性能报告与诊断数据",
                category: "Runtime"
            ) { ctx in
                if let sessionID = ctx.sessionID, let perfReport = try? await ctx.client.diagnostics.getPerformanceMetrics(sessionID: sessionID) {
                    let output = """
                    会话性能诊断报告:
                      • Session: \(perfReport.sessionID.rawValue)
                      • Total Time: \(String(format: "%.2f ms", perfReport.totalMilliseconds))
                      • Steps: \(perfReport.stepCount)
                      • Characters/sec: \(String(format: "%.1f", perfReport.textCharactersPerSecond ?? 0))
                    """
                    return ApplicationCommandResult(
                        output: output,
                        presentation: .modal,
                        modalTitle: "会话性能诊断报告 (/perf)"
                    )
                } else if let bundle = try? await ctx.client.diagnostics.getBundle() {
                    let output = """
                    全局诊断摘要:
                      • Runtime: \(bundle.runtimeVersion)
                      • Protocol: \(bundle.protocolVersion)
                      • Trace Count: \(bundle.trace.count)
                      • Error Count: \(bundle.recentErrors.count)
                    """
                    return ApplicationCommandResult(
                        output: output,
                        presentation: .modal,
                        modalTitle: "全局诊断摘要 (/perf)"
                    )
                }
                return ApplicationCommandResult(
                    output: "暂无性能诊断数据",
                    presentation: .modal,
                    modalTitle: "性能诊断报告 (/perf)"
                )
            },

            // 11. /mode
            ApplicationCommand(
                name: "mode",
                aliases: [],
                description: "查看或切换 Agent 行为模式 (build|plan|explore)",
                category: "Runtime",
                argumentSchema: "[build|plan|explore]"
            ) { ctx in
                if let arg = ctx.arguments.first {
                    let lower = arg.lowercased()
                    let mode: AgentMode
                    switch lower {
                    case "build": mode = .build
                    case "plan": mode = .plan
                    case "explore": mode = .explore
                    default:
                        return ApplicationCommandResult(output: "未知模式: \(arg)。支持: build | plan | explore")
                    }
                    return ApplicationCommandResult(
                        output: "模式已切换为: \(mode.displayName)",
                        nextTurnMode: mode
                    )
                } else {
                    let current = ctx.state.nextTurnMode?.displayName ?? ctx.state.activeSessionState?.mode.displayName ?? "Build"
                    return ApplicationCommandResult(output: "当前模式: \(current)")
                }
            },

            // 12. /permissions
            ApplicationCommand(
                name: "permissions",
                aliases: ["permission"],
                description: "查看或配置权限策略",
                category: "Runtime",
                argumentSchema: "[ask|auto|yolo]"
            ) { ctx in
                if let arg = ctx.arguments.first {
                    let lower = arg.lowercased()
                    let perm: PermissionConfiguration
                    switch lower {
                    case "yolo", "yolo_full", "full":
                        perm = .yoloFullAccess
                    case "auto", "auto_workspace":
                        perm = .autoWorkspace
                    case "ask", "ask_workspace":
                        perm = .askWorkspace
                    case "ask_full":
                        perm = .askFullAccess
                    default:
                        return ApplicationCommandResult(output: "未知权限策略: \(arg)。支持: ask | auto | yolo")
                    }
                    UserPreferencesStore.shared.update(permissionConfiguration: lower)
                    return ApplicationCommandResult(
                        output: "权限策略已更新为: \(lower)",
                        nextTurnPermission: perm
                    )
                } else {
                    let current = ctx.state.nextTurnPermission?.profile.rawValue
                        ?? ctx.state.activeSessionState?.permissionConfiguration.profile.rawValue
                        ?? "ask"
                    return ApplicationCommandResult(output: "当前权限策略: \(current)")
                }
            },

            // 13. /subagents
            ApplicationCommand(
                name: "subagents",
                aliases: [],
                description: "查看当前会话的子 Agent 树",
                category: "Execution"
            ) { ctx in
                guard let session = ctx.state.activeSessionState else {
                    throw ApplicationCommandError.invalidArguments("当前无活动会话")
                }
                if session.subagents.isEmpty {
                    return ApplicationCommandResult(output: "当前会话无子 Agent")
                }
                var output = "子 Agent 列表 (\(session.subagents.count)):"
                for (runID, sub) in session.subagents {
                    output += "\n  • [\(runID.rawValue)] status: \(sub.status) (parent: \(sub.parentRunID.rawValue))"
                }
                return ApplicationCommandResult(
                    output: output,
                    presentation: .modal,
                    modalTitle: "子 Agent 树 (/subagents)"
                )
            },

            // 14. /mcp
            ApplicationCommand(
                name: "mcp",
                aliases: [],
                description: "查看 MCP 服务器与可用工具状态",
                category: "Execution"
            ) { ctx in
                let mcpExts = (try? await ctx.client.extensionDomain.list(kind: .mcp)) ?? []
                var output = "MCP 扩展服务 (\(mcpExts.count)):"
                for m in mcpExts {
                    output += "\n  • [\(m.id)] v\(m.version) (enabled: \(m.enabled))"
                }
                return ApplicationCommandResult(
                    output: output,
                    presentation: .modal,
                    modalTitle: "MCP 扩展服务 (/mcp)"
                )
            },

            // 15. /skills
            ApplicationCommand(
                name: "skills",
                aliases: [],
                description: "查看已加载 Skills",
                category: "Extensions"
            ) { ctx in
                let skills = (try? await ctx.client.extensionDomain.list(kind: .skill)) ?? []
                var output = "可用 Skills (\(skills.count)):"
                for sk in skills {
                    output += "\n  • \(sk.id) v\(sk.version) (enabled: \(sk.enabled))"
                }
                return ApplicationCommandResult(
                    output: output,
                    presentation: .modal,
                    modalTitle: "可用 Skills 列表 (/skills)"
                )
            },

            // 16. /plugins
            ApplicationCommand(
                name: "plugins",
                aliases: [],
                description: "管理与查看外部 Swift 插件",
                category: "Extensions",
                argumentSchema: "[list|reload|enable <id>|disable <id>]"
            ) { ctx in
                let subcmd = ctx.arguments.first?.lowercased() ?? "list"
                switch subcmd {
                case "reload":
                    _ = try? await ctx.client.extensionDomain.reload()
                    let list = (try? await ctx.client.extensionDomain.list(kind: .plugin)) ?? []
                    return ApplicationCommandResult(output: "✓ 插件目录重新扫描完成，当前就绪插件: \(list.count) 个")
                case "enable":
                    guard ctx.arguments.count > 1 else {
                        return ApplicationCommandResult(output: "用法: /plugins enable <plugin_id>")
                    }
                    let targetID = ctx.arguments[1]
                    _ = try? await ctx.client.extensionDomain.enable(id: targetID)
                    return ApplicationCommandResult(output: "✓ 插件 '\(targetID)' 已启用")
                case "disable":
                    guard ctx.arguments.count > 1 else {
                        return ApplicationCommandResult(output: "用法: /plugins disable <plugin_id>")
                    }
                    let targetID = ctx.arguments[1]
                    _ = try? await ctx.client.extensionDomain.disable(id: targetID)
                    return ApplicationCommandResult(output: "○ 插件 '\(targetID)' 已禁用")
                default:
                    let extensions = (try? await ctx.client.extensionDomain.list(kind: .plugin)) ?? []
                    if extensions.isEmpty {
                        return ApplicationCommandResult(
                            output: "当前暂无已加载插件。\n\n提示: 将基于 LingXiPluginSDK 编译后的 Swift 插件二进制\n直接复制进 ~/.lingxiagent/plugins/ 或 .lingxi/plugins/ 即可自动加载！",
                            presentation: .modal,
                            modalTitle: "已加载外部插件 (/plugins)"
                        )
                    }
                    var fields: [(String, String)] = []
                    for ext in extensions {
                        let statusIcon = ext.enabled ? "✓" : "○"
                        fields.append(("\(statusIcon) [\(ext.id)]", "v\(ext.version) (\(ext.scope)) [\(ext.lifecycleState)]"))
                    }
                    let output = CLIFormatter.renderCard(
                        title: "已加载外部插件 (/plugins)",
                        fields: fields,
                        footer: "重新扫描: /plugins reload · 启停: /plugins enable|disable <id>",
                        borderStyle: .rounded
                    )
                    return ApplicationCommandResult(
                        output: output,
                        presentation: .modal,
                        modalTitle: "已加载外部插件 (/plugins)"
                    )
                }
            },

            // 16.5 /commands
            ApplicationCommand(
                name: "commands",
                aliases: ["cmds"],
                description: "查看当前所有可用命令（内建、自定义与插件）",
                category: "General"
            ) { ctx in
                let builtins = BuiltinCommands.all.map { cmd -> String in
                    let aliasText = cmd.aliases.isEmpty ? "" : " (别名: \(cmd.aliases.joined(separator: ", ")))"
                    return "/\(cmd.name)\(aliasText) - \(cmd.description)"
                }
                let extCmds = ctx.state.extensions.filter { $0.kind == .command }.map { "/\($0.id) (\($0.scope))" }

                var fields: [(String, String)] = [
                    ("内建核心命令 (\(builtins.count))", builtins.prefix(12).joined(separator: "\n") + (builtins.count > 12 ? "\n... 更多输入 / 查看" : ""))
                ]
                if !extCmds.isEmpty {
                    fields.append(("自定义/插件命令 (\(extCmds.count))", extCmds.joined(separator: "\n")))
                }

                let output = CLIFormatter.renderCard(
                    title: "可用命令总览 (/commands)",
                    fields: fields,
                    footer: "输入 / 触发交互式自动补全",
                    borderStyle: .rounded
                )
                return ApplicationCommandResult(
                    output: output,
                    presentation: .modal,
                    modalTitle: "可用命令总览 (/commands)"
                )
            },

            // 17. /hooks
            ApplicationCommand(
                name: "hooks",
                aliases: [],
                description: "查看已注册生命周期 Hooks",
                category: "Extensions"
            ) { ctx in
                let hooks = (try? await ctx.client.extensionDomain.list(kind: .hook)) ?? []
                var output = "系统 Hooks (\(hooks.count)):"
                for h in hooks {
                    output += "\n  • [\(h.id)] \(h.lifecycleState) (enabled: \(h.enabled))"
                }
                return ApplicationCommandResult(
                    output: output,
                    presentation: .modal,
                    modalTitle: "已注册生命周期 Hooks (/hooks)"
                )
            },

            // 18. /diff
            ApplicationCommand(
                name: "diff",
                aliases: [],
                description: "查看当前工作区变更",
                category: "Workspace"
            ) { ctx in
                if let diffSummary = try? await ctx.client.workspace.diff() {
                    return ApplicationCommandResult(
                        output: diffSummary.diff.isEmpty ? "工作区无未提交变更" : diffSummary.diff,
                        presentation: .modal,
                        modalTitle: "工作区变更审查 (/diff)"
                    )
                }
                return ApplicationCommandResult(
                    output: "无活动工作区变更",
                    presentation: .modal,
                    modalTitle: "工作区变更审查 (/diff)"
                )
            },

            // 19. /ps
            ApplicationCommand(
                name: "ps",
                aliases: [],
                description: "查看活动与排队中的 AgentRun",
                category: "Execution"
            ) { ctx in
                guard let session = ctx.state.activeSessionState else {
                    throw ApplicationCommandError.invalidArguments("当前无活动会话")
                }
                var output = "活动 Root Run: \(session.activeRootRunID?.rawValue ?? "无")"
                output += "\n活动 Subagent Runs: \(session.activeSubagentRunIDs.count)"
                output += "\n排队中的 Turns: \(session.queuedTurns.count)"
                return ApplicationCommandResult(
                    output: output,
                    presentation: .modal,
                    modalTitle: "活动进程与任务队列 (/ps)"
                )
            },

            // 20. /stop
            ApplicationCommand(
                name: "stop",
                aliases: [],
                description: "停止当前活动运行",
                category: "Execution",
                argumentSchema: "[runID]"
            ) { ctx in
                let targetRunID = ctx.arguments.first.map { RunID(rawValue: $0) } ?? ctx.state.activeSessionState?.activeRootRunID
                guard let runID = targetRunID else {
                    return ApplicationCommandResult(output: "当前无活动运行可停止")
                }
                guard let sessionID = ctx.sessionID else {
                    throw ApplicationCommandError.invalidArguments("当前无活动会话")
                }
                _ = try await ctx.client.run.cancelRun(sessionID: sessionID, runID: runID, reason: "User requested stop")
                return ApplicationCommandResult(output: "已向 Run \(runID.rawValue) 发送停止信号")
            },

            // 21. /reasoning
            ApplicationCommand(
                name: "reasoning",
                aliases: [],
                description: "查看或设置当前会话的思考等级",
                category: "Session",
                argumentSchema: "[effort]"
            ) { ctx in
                try await handleReasoningEffort(ctx: ctx)
            },

            // 22. /think
            ApplicationCommand(
                name: "think",
                aliases: ["thought"],
                description: "查看或设置当前会话的思考等级",
                category: "Session",
                argumentSchema: "[effort]"
            ) { ctx in
                try await handleReasoningEffort(ctx: ctx)
            },

            // 23. /config
            ApplicationCommand(
                name: "config",
                aliases: ["preference", "set"],
                description: "查看或修改 TUI 偏好配置 (如思考折叠、工具详情、侧边栏)",
                category: "General",
                argumentSchema: "[key] [value]"
            ) { ctx in
                try await handleConfig(ctx: ctx)
            },

            // 24. /tasks
            ApplicationCommand(
                name: "tasks",
                aliases: ["task", "bg"],
                description: "查看后台任务列表与运行状态 (正在完成、已完成、执行错误)",
                category: "Execution",
                argumentSchema: "[task_id | kill <task_id>]"
            ) { ctx in
                try await handleTasks(ctx: ctx)
            },

            // 25. /goal
            ApplicationCommand(
                name: "goal",
                aliases: ["target", "focus"],
                description: "查看或设定目标收敛模式，强制模型向交付物单向收敛，防止发散",
                category: "Execution",
                argumentSchema: "[task_goal]"
            ) { ctx in
                try await handleGoal(ctx: ctx)
            }
        ]
    }

    private static func handleConfig(ctx: ApplicationCommandContext) async throws -> ApplicationCommandResult {
        let prefs = UserPreferencesStore.shared.load()
        if ctx.arguments.isEmpty {
            let fields: [(String, String)] = [
                ("思考过程默认展开 (think)", (prefs.expandThinking ?? false) ? "开启 (on)" : "折叠 (off)"),
                ("工具调用详情默认展开 (tools)", (prefs.expandTools ?? false) ? "开启 (on)" : "折叠 (off)"),
                ("监控侧边栏显示 (sidebar)", (prefs.showSidebar ?? true) ? "显示 (on)" : "隐藏 (off)")
            ]
            let card = CLIFormatter.renderCard(
                title: "TUI 偏好配置 (/config)",
                fields: fields,
                footer: "修改示例: /config think on · /config tools on · /config sidebar off",
                borderStyle: .rounded
            )
            return ApplicationCommandResult(output: card)
        }

        let key = ctx.arguments[0].lowercased()
        let val = ctx.arguments.count > 1 ? ctx.arguments[1].lowercased() : "toggle"

        guard ctx.arguments.count <= 2 else {
            throw ApplicationCommandError.executionFailed("用法: /config <think|tools|sidebar> [on|off|toggle]")
        }
        let parseBool = UserPreferences.parseToggle

        var msg = ""
        switch key {
        case "think", "thinking", "expand_thinking":
            let newVal = try parseBool(val, prefs.expandThinking ?? false)
            guard UserPreferencesStore.shared.update(expandThinking: newVal) else {
                throw ApplicationCommandError.executionFailed("无法保存偏好配置，请检查数据目录的写入权限。")
            }
            msg = "思考过程默认展开已设为: \(newVal ? "开启 (on)" : "折叠 (off)")"
        case "tool", "tools", "expand_tools":
            let newVal = try parseBool(val, prefs.expandTools ?? false)
            guard UserPreferencesStore.shared.update(expandTools: newVal) else {
                throw ApplicationCommandError.executionFailed("无法保存偏好配置，请检查数据目录的写入权限。")
            }
            msg = "工具详情默认展开已设为: \(newVal ? "开启 (on)" : "折叠 (off)")"
        case "sidebar", "side":
            let newVal = try parseBool(val, prefs.showSidebar ?? true)
            guard UserPreferencesStore.shared.update(showSidebar: newVal) else {
                throw ApplicationCommandError.executionFailed("无法保存偏好配置，请检查数据目录的写入权限。")
            }
            msg = "监控侧边栏已设为: \(newVal ? "显示 (on)" : "隐藏 (off)")"
        default:
            msg = "未知的配置项: \(key)。可用配置: think, tools, sidebar\n示例: /config think on"
        }
        return ApplicationCommandResult(output: msg)
    }

    private static func handleReasoningEffort(ctx: ApplicationCommandContext) async throws -> ApplicationCommandResult {
        let currentEffort = ctx.state.effectiveReasoningEffort
        let modelID = ctx.state.currentModelID ?? "当前模型"
        let caps = try? await ctx.client.model.getCapabilities(modelID: modelID)
        let supported = caps?.reasoningCapability?.supportedEfforts.map(\.rawValue).joined(separator: ", ")
            ?? "auto, off, low, medium, high, max"

        if ctx.arguments.isEmpty {
            let output = CLIFormatter.renderCard(
                title: "思考等级 (/reasoning)",
                fields: [
                    ("当前生效等级", currentEffort.rawValue),
                    ("当前活动模型", modelID),
                    ("支持等级选项", supported)
                ],
                footer: "切换等级: /reasoning <effort> 或 /think <effort> · 快捷键: Ctrl+t",
                borderStyle: .rounded
            )
            return ApplicationCommandResult(output: output)
        }

        let rawArg = ctx.arguments[0].lowercased()
        guard let targetEffort = ReasoningEffort(rawValue: rawArg) else {
            return ApplicationCommandResult(output: "无效的思考等级: \(rawArg)\n支持的等级: auto, off, minimal, low, medium, high, max")
        }

        var effectiveTarget = targetEffort
        var noteMessage: String? = nil
        if let cap = caps?.reasoningCapability {
            let resolved = cap.resolveEffort(targetEffort)
            effectiveTarget = resolved.effective
            noteMessage = resolved.message
        }

        if let sessionID = ctx.sessionID {
            _ = try? await ctx.client.session.setReasoningEffort(sessionID: sessionID, effort: effectiveTarget)
        }

        var output = "思考等级已切换为: \(effectiveTarget.rawValue)"
        if let note = noteMessage {
            output += "\n\(note)"
        }
        return ApplicationCommandResult(output: output, nextTurnReasoningEffort: effectiveTarget)
    }

    private static func handleTasks(ctx: ApplicationCommandContext) async throws -> ApplicationCommandResult {
        // 1. 终止子命令: /tasks kill <task_id> 或 /tasks stop <task_id>
        if let first = ctx.arguments.first?.lowercased(), (first == "kill" || first == "stop") {
            guard ctx.arguments.count > 1 else {
                throw ApplicationCommandError.invalidArguments("用法: /tasks kill <task_id>")
            }
            let targetID = ctx.arguments[1]
            let success = (try? await ctx.client.runtime.terminateBackgroundTask(id: targetID)) ?? false
            if success {
                return ApplicationCommandResult(output: "✓ 已向后台任务 [\(targetID)] 发送终止信号。")
            } else {
                return ApplicationCommandResult(output: "⚠️ 终止后台任务 [\(targetID)] 请求未能成功处理。")
            }
        }

        // 2. 拉取所有后台任务快照
        let allTasks = (try? await ctx.client.diagnostics.getBackgroundTasks()) ?? []

        // 3. 单任务详情模式: /tasks <task_id>
        if let targetID = ctx.arguments.first, targetID != "all" && targetID != "list" {
            guard let matched = allTasks.first(where: { $0.id == targetID || $0.id.hasPrefix(targetID) }) else {
                return ApplicationCommandResult(output: "未找到 ID 为 [\(targetID)] 的后台任务。\n输入 /tasks 查看所有后台任务。")
            }

            var statusStr = ""
            switch matched.status {
            case .running:
                statusStr = "🚀 正在运行 (剩余 \(String(format: "%.1f", matched.remainingTimeoutSeconds))s / 限时 \(matched.timeoutSeconds)s)"
            case .exited:
                statusStr = (matched.exitCode == 0) ? "✅ 已完成 (exit: 0)" : "❌ 异常退出 (exit: \(matched.exitCode ?? -1))"
            case .timedOut:
                statusStr = "⚠️ 超时强杀 (已超 \(matched.timeoutSeconds)s 强制上限)"
            case .terminated:
                statusStr = "⏹ 手动终止"
            }

            var fields: [(String, String)] = [
                ("任务 ID", matched.id),
                ("当前状态", statusStr),
                ("执行命令", matched.command),
                ("工作目录", matched.cwd),
                ("超时上限", "\(matched.timeoutSeconds) 秒"),
                ("耗时统计", String(format: "%.2f 秒", matched.elapsedSeconds))
            ]
            if let pid = matched.pid {
                fields.append(("进程 PID", "\(pid)"))
            }
            if let exitCode = matched.exitCode {
                fields.append(("退出代码", "\(exitCode)"))
            }
            if let desc = matched.description, !desc.isEmpty {
                fields.append(("任务描述", desc))
            }

            var sections: [(String, [String])] = []
            let stdoutLines = matched.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
            if !stdoutLines.isEmpty {
                let tail = stdoutLines.suffix(20).map { "  \($0)" }
                sections.append(("标准输出 (最近 \(tail.count) 行)", tail))
            }
            let stderrLines = matched.stderr.components(separatedBy: "\n").filter { !$0.isEmpty }
            if !stderrLines.isEmpty {
                let tail = stderrLines.suffix(20).map { "  \($0)" }
                sections.append(("标准错误 (最近 \(tail.count) 行)", tail))
            }

            let card = CLIFormatter.renderCard(
                title: "后台任务详情 (/tasks)",
                fields: fields,
                sections: sections,
                footer: (matched.status == .running) ? "终止任务: /tasks kill \(matched.id)" : nil,
                borderStyle: .rounded
            )
            return ApplicationCommandResult(output: card)
        }

        // 4. 空任务处理
        if allTasks.isEmpty {
            let card = CLIFormatter.renderCard(
                title: "后台命令任务状态 (/tasks)",
                fields: [
                    ("后台任务总数", "0 (暂无后台任务)"),
                    ("系统看门狗", "已就绪 (强制超时保护生效中)")
                ],
                sections: [
                    ("提示说明", [
                        "  • 模型可调用 run_background_command 移交耗时指令到后台运行",
                        "  • 所有后台指令均被强制要求超时时间 (timeout_seconds)，杜绝卡死",
                        "  • 任务执行结束或超时，系统将主动巡检并提醒模型与用户"
                    ])
                ],
                footer: "运行指令时模型可使用 run_background_command",
                borderStyle: .rounded
            )
            return ApplicationCommandResult(output: card)
        }

        // 5. 分类归纳: 正在完成、已完成、执行错误
        var runningLines: [String] = []
        var completedLines: [String] = []
        var failedLines: [String] = []

        for task in allTasks {
            let cmdShort = task.command.count > 36 ? String(task.command.prefix(33)) + "..." : task.command
            switch task.status {
            case .running:
                let pidStr = task.pid.map { "PID: \($0)" } ?? "PID: -"
                let timeStr = "\(String(format: "%.1f", task.elapsedSeconds))s/\(task.timeoutSeconds)s"
                runningLines.append("  • [\(task.id)] \(pidStr) · 耗时 \(timeStr) · `\(cmdShort)`")
            case .exited:
                if (task.exitCode ?? 0) == 0 {
                    let timeStr = String(format: "%.1f", task.elapsedSeconds) + "s"
                    completedLines.append("  • [\(task.id)] 耗时 \(timeStr) · exit: 0 · `\(cmdShort)`")
                } else {
                    let code = task.exitCode.map(String.init) ?? "unknown"
                    failedLines.append("  • [\(task.id)] 退出码: \(code) · `\(cmdShort)`")
                }
            case .timedOut:
                failedLines.append("  • [\(task.id)] ⚠️ 超时强杀 (\(task.timeoutSeconds)s) · `\(cmdShort)`")
            case .terminated:
                failedLines.append("  • [\(task.id)] ⏹ 手动终止 · `\(cmdShort)`")
            }
        }

        var sections: [(String, [String])] = []
        if !runningLines.isEmpty {
            sections.append(("🚀 正在完成 (\(runningLines.count))", runningLines))
        } else {
            sections.append(("🚀 正在完成 (0)", ["  (暂无运行中的任务)"]))
        }

        if !completedLines.isEmpty {
            sections.append(("✅ 已完成 (\(completedLines.count))", completedLines))
        }

        if !failedLines.isEmpty {
            sections.append(("❌ 执行错误 / 终止 (\(failedLines.count))", failedLines))
        }

        let fields: [(String, String)] = [
            ("正在完成", "\(runningLines.count) 个"),
            ("已完成", "\(completedLines.count) 个"),
            ("执行错误/终止", "\(failedLines.count) 个")
        ]

        let card = CLIFormatter.renderCard(
            title: "后台命令任务状态 (/tasks)",
            fields: fields,
            sections: sections,
            footer: "查看任务详情: /tasks <task_id> · 终止任务: /tasks kill <task_id>",
            borderStyle: .rounded
        )
        return ApplicationCommandResult(output: card)
    }

    private static func handleGoal(ctx: ApplicationCommandContext) async throws -> ApplicationCommandResult {
        let goalDescription = ctx.arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let isSpecified = !goalDescription.isEmpty

        var fields: [(String, String)] = [
            ("收敛状态", "已激活 (Goal-Directed Mode: Active)"),
            ("反发散断路器", "强制开启 (连续探索上限: 2 次)"),
            ("推进策略", "单向收敛 · 最短直达路径 · 交付即停止"),
        ]

        if isSpecified {
            fields.append(("当前锚定目标", goalDescription))
        } else {
            fields.append(("当前目标", "就地执行最短路径交付物，禁止探索性发散"))
        }

        let sections: [(String, [String])] = [
            ("🎯 收敛法则 (Goal Convergence Rules)", [
                "  1. 目标唯一锚定: 每步工具调用必须直接为目标产生有效产物",
                "  2. 严禁源码流浪: 修改配置时不读编译器源码，改 Bug 时先跑最小单测",
                "  3. 异常即时收敛: 遇到工具报错或网络缺失，禁止横向排查，立刻切备选方案",
                "  4. 验证即时交付: 产物落地并通过校验后，立刻停止发散并向用户汇报"
            ])
        ]

        let card = CLIFormatter.renderCard(
            title: "🎯 目标收敛模式 (/goal)",
            fields: fields,
            sections: sections,
            footer: isSpecified ? "已锁定目标: \(goalDescription)" : "用法: /goal <具体交付目标>",
            borderStyle: .rounded
        )

        return ApplicationCommandResult(
            output: card,
            presentation: .modal,
            modalTitle: "🎯 目标收敛模式 (/goal)"
        )
    }
}
