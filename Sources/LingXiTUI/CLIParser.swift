import Foundation
import LingXiProtocol

public enum CLIRoute: Equatable, Sendable {
    case tui(TUILaunchOptions)
    case auth([String])
    case mcp([String])
    case skills([String])
    case exec([String])
    case review([String])
    case doctor([String])
    case resume([String])
    case completion([String])
    case help
    case version
}

public struct CLIParser: Sendable {
    public static let version = "0.1.0"

    private static let authCommands: Set<String> = [
        "auth", "login", "logout", "status", "matrix", "compat", "models"
    ]

    public static func parse(arguments: [String]) -> CLIRoute {
        if arguments.isEmpty {
            return .tui(.default)
        }

        let first = arguments[0]

        // 帮助与版本
        if first == "-h" || first == "--help" || first == "help" {
            return .help
        }
        if first == "-v" || first == "--version" || first == "version" {
            return .version
        }

        // 子命令路由
        if authCommands.contains(first) {
            return .auth(arguments)
        }
        if first == "mcp" {
            return .mcp(arguments)
        }
        if first == "skills" || first == "skill" {
            return .skills(arguments)
        }
        if first == "exec" || first == "e" {
            return .exec(arguments)
        }
        if first == "review" {
            return .review(arguments)
        }
        if first == "doctor" {
            return .doctor(arguments)
        }
        if first == "resume" {
            return .resume(arguments)
        }
        if first == "completion" {
            return .completion(arguments)
        }

        var isYoloMode = false
        var initialModelID: String?
        var initialWorkingDir: String?
        var reasoningEffort: ReasoningEffort?
        var noAltScreen = false
        var mcpEnables: [String] = []
        var mcpDisables: [String] = []
        var skillEnables: [String] = []
        var skillDisables: [String] = []
        var promptWords: [String] = []

        var i = 0
        var stopFlagParsing = false

        while i < arguments.count {
            let arg = arguments[i]

            if stopFlagParsing {
                promptWords.append(arg)
                i += 1
                continue
            }

            if arg == "--" {
                stopFlagParsing = true
                i += 1
                continue
            }

            if arg == "-h" || arg == "--help" {
                return .help
            }

            if arg == "-v" || arg == "--version" {
                return .version
            }

            if arg == "-y" || arg == "--yolo" {
                isYoloMode = true
                i += 1
            } else if arg == "--no-alt-screen" {
                noAltScreen = true
                i += 1
            } else if arg == "-m" || arg == "--model" {
                if i + 1 < arguments.count {
                    initialModelID = arguments[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            } else if arg.hasPrefix("--model=") {
                initialModelID = String(arg.dropFirst("--model=".count))
                i += 1
            } else if arg == "-C" || arg == "--cd" {
                if i + 1 < arguments.count {
                    initialWorkingDir = arguments[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            } else if arg.hasPrefix("--cd=") {
                initialWorkingDir = String(arg.dropFirst("--cd=".count))
                i += 1
            } else if arg == "-e" || arg == "--effort" {
                if i + 1 < arguments.count {
                    let effortStr = arguments[i + 1].lowercased()
                    reasoningEffort = ReasoningEffort(rawValue: effortStr)
                    i += 2
                } else {
                    i += 1
                }
            } else if arg.hasPrefix("--effort=") {
                let effortStr = String(arg.dropFirst("--effort=".count)).lowercased()
                reasoningEffort = ReasoningEffort(rawValue: effortStr)
                i += 1
            } else if arg == "--enable-mcp" {
                if i + 1 < arguments.count {
                    mcpEnables.append(arguments[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            } else if arg.hasPrefix("--enable-mcp=") {
                mcpEnables.append(String(arg.dropFirst("--enable-mcp=".count)))
                i += 1
            } else if arg == "--disable-mcp" {
                if i + 1 < arguments.count {
                    mcpDisables.append(arguments[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            } else if arg.hasPrefix("--disable-mcp=") {
                mcpDisables.append(String(arg.dropFirst("--disable-mcp=".count)))
                i += 1
            } else if arg == "--enable-skill" {
                if i + 1 < arguments.count {
                    skillEnables.append(arguments[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            } else if arg.hasPrefix("--enable-skill=") {
                skillEnables.append(String(arg.dropFirst("--enable-skill=".count)))
                i += 1
            } else if arg == "--disable-skill" {
                if i + 1 < arguments.count {
                    skillDisables.append(arguments[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            } else if arg.hasPrefix("--disable-skill=") {
                skillDisables.append(String(arg.dropFirst("--disable-skill=".count)))
                i += 1
            } else if arg.hasPrefix("-") {
                // 未知 flag，安全略过
                i += 1
            } else {
                // 普通位置参数，归入 prompt
                promptWords.append(arg)
                i += 1
            }
        }

        let prompt = promptWords.isEmpty ? nil : promptWords.joined(separator: " ")
        let launchOptions = TUILaunchOptions(
            initialPrompt: prompt,
            initialModelID: initialModelID,
            initialWorkingDir: initialWorkingDir,
            isYoloMode: isYoloMode,
            reasoningEffort: reasoningEffort,
            noAltScreen: noAltScreen,
            mcpEnables: mcpEnables,
            mcpDisables: mcpDisables,
            skillEnables: skillEnables,
            skillDisables: skillDisables
        )
        return .tui(launchOptions)
    }

    public static func renderHelp() -> String {
        """
        LingXiAgent - Native Swift AI Coding Agent (v\(version))

        USAGE:
          lingxiagent [options] [prompt]
          lingxiagent <command> [options]

        OPTIONS:
          -y, --yolo                  全自动执行模式（自动放行所有权限与工具调用，无需人工确认）
          -m, --model <id>            指定启动模型（例如 gpt-5-5, deepseek-chat 等）
          -C, --cd <dir>              指定工作目录
          -e, --effort <effort>       设置推理思考深度 (auto | low | medium | high | max)
              --no-alt-screen         不使用终端备用屏幕（保留历史在终端滚动缓冲区）
              --enable-mcp <name>     在启动时启用指定的 MCP 服务
              --disable-mcp <name>    在启动时禁用指定的 MCP 服务
              --enable-skill <name>   在启动时启用指定的 Skill
              --disable-skill <name>  在启动时禁用指定的 Skill
          -h, --help                  显示帮助信息
          -v, --version               显示版本信息

        SUBCOMMANDS:
          auth <command>              Provider 鉴权与凭据管理 (login, logout, status, list, models, matrix)
          mcp <command>               MCP 服务器配置与连接管理 (list, status, enable, disable, auth, add, remove)
          skills <command>            扩展 Skills 发现与激活管理 (list, info, enable, disable)
          exec <prompt>               非交互方式无头运行 Agent 任务 (支持管道输入)
          review [options]            针对当前 Git 未提交变更执行严谨的代码审查
          doctor                      诊断系统环境、配置、凭据与扩展生态健康状况
          resume [sessionID]          恢复历史交互式会话 (或使用 --last 恢复最新会话)
          completion <shell>          生成 Shell 自动补全脚本 (zsh, bash, fish)

        EXAMPLES:
          lingxiagent                                 启动交互式 TUI
          lingxiagent "帮我分析当前项目结构"              启动 TUI 并自动发起首轮对话
          lingxiagent --yolo "运行测试并修复所有报错"       以 YOLO 自动放行模式启动并执行任务
          lingxiagent exec "查找所有未使用的公共方法"       在终端中直接运行无头任务
          git diff | lingxiagent exec "审查这批改动"       通过管道将上下文传给 Agent 执行
          lingxiagent review                          审查当前 Git 工作区改动
          lingxiagent doctor                          检查本地开发与凭据环境
          lingxiagent resume --last                   恢复上一次未完成的会话
          eval "$(lingxiagent completion zsh)"        启用 Zsh 命令行自动补全
        """
    }
}
