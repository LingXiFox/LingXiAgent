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
                return ApplicationCommandResult(output: output)
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
                return ApplicationCommandResult(output: output)
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
                let sessions = (try? await ctx.client.session.list())?.items ?? []
                let currentCwd = FileManager.default.currentDirectoryPath

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

                    // 按工作目录分组：当前目录置顶
                    var groups: [String: [SessionSummary]] = [:]
                    for s in sessions {
                        let dir = s.workingDirectory ?? currentCwd
                        groups[dir, default: []].append(s)
                    }

                    let sortedDirs = groups.keys.sorted { d1, d2 in
                        let isCurrent1 = (d1 == currentCwd)
                        let isCurrent2 = (d2 == currentCwd)
                        if isCurrent1 != isCurrent2 { return isCurrent1 }
                        let latest1 = groups[d1]?.map(\.updatedAt).max() ?? Date.distantPast
                        let latest2 = groups[d2]?.map(\.updatedAt).max() ?? Date.distantPast
                        return latest1 > latest2
                    }

                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "MM-dd HH:mm"

                    var sections: [String] = []
                    sections.append("可用历史会话 (按工作目录分类展示，共 \(sessions.count) 个):")

                    for dir in sortedDirs {
                        let dirSessions = (groups[dir] ?? []).sorted(by: { $0.updatedAt > $1.updatedAt })
                        let isCurrent = (dir == currentCwd)
                        let header = isCurrent ? "📂 [当前工作目录] \(dir)" : "📂 \(dir)"
                        var lines: [String] = [header]
                        for s in dirSessions.prefix(6) {
                            let shortID = String(s.sessionID.rawValue.prefix(8))
                            let dateStr = dateFormatter.string(from: s.updatedAt)
                            let title = s.title ?? "未命名会话"
                            lines.append("  • \(shortID) · \(dateStr) (\(s.messageCount)条消息) · \(title)")
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
                return ApplicationCommandResult(output: output)
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
                    title: "上下文分层状态 (/context)",
                    fields: [
                        ("预估总 Token", "\(snapshot.estimatedTokens)"),
                        ("L1 缓存层", "\(snapshot.l1Tokens) tokens"),
                        ("L2 工作集", "\(snapshot.l2Tokens) tokens"),
                        ("L3 存储层", "\(snapshot.l3Tokens) tokens")
                    ],
                    footer: "压缩上下文: /compact",
                    borderStyle: .rounded
                )
                return ApplicationCommandResult(output: output)
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
                    return ApplicationCommandResult(output: output)
                } else if let bundle = try? await ctx.client.diagnostics.getBundle() {
                    let output = """
                    全局诊断摘要:
                      • Runtime: \(bundle.runtimeVersion)
                      • Protocol: \(bundle.protocolVersion)
                      • Trace Count: \(bundle.trace.count)
                      • Error Count: \(bundle.recentErrors.count)
                    """
                    return ApplicationCommandResult(output: output)
                }
                return ApplicationCommandResult(output: "暂无性能诊断数据")
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
                return ApplicationCommandResult(output: output)
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
                return ApplicationCommandResult(output: output)
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
                return ApplicationCommandResult(output: output)
            },

            // 16. /plugins
            ApplicationCommand(
                name: "plugins",
                aliases: [],
                description: "查看已安装 Plugins",
                category: "Extensions"
            ) { ctx in
                let extensions = (try? await ctx.client.extensionDomain.list(kind: .plugin)) ?? []
                var output = "插件列表 (\(extensions.count)):"
                for ext in extensions {
                    output += "\n  • [\(ext.id)] v\(ext.version)"
                }
                return ApplicationCommandResult(output: output)
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
                return ApplicationCommandResult(output: output)
            },

            // 18. /diff
            ApplicationCommand(
                name: "diff",
                aliases: [],
                description: "查看当前工作区变更",
                category: "Workspace"
            ) { ctx in
                if let diffSummary = try? await ctx.client.workspace.diff() {
                    return ApplicationCommandResult(output: diffSummary.diff.isEmpty ? "工作区无未提交变更" : diffSummary.diff)
                }
                return ApplicationCommandResult(output: "无活动工作区变更")
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
                return ApplicationCommandResult(output: output)
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
            }
        ]
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
}
