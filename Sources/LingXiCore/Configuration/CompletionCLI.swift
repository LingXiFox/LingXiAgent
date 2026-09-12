import Foundation

public enum CompletionCLI {

    public static func run(arguments: [String]) -> String {
        var args = arguments
        if args.first == "completion" {
            args.removeFirst()
        }

        let shell = args.first?.lowercased() ?? "zsh"

        switch shell {
        case "zsh":
            return generateZsh()
        case "bash":
            return generateBash()
        case "fish":
            return generateFish()
        default:
            return """
            Error: Unsupported shell '\(shell)'.
            Supported shells: zsh, bash, fish
            Usage:
              lingxiagent completion zsh
              lingxiagent completion bash
              lingxiagent completion fish
            """
        }
    }

    private static func generateZsh() -> String {
        """
        #compdef lingxiagent

        _lingxiagent() {
            local curcontext="$curcontext" state line
            typeset -A opt_args

            _arguments -C \\
                '(-y --yolo)'{-y,--yolo}'[全自动执行模式（自动放行所有工具与修改）]' \\
                '(-m --model)'{-m,--model}'[指定启动模型]:model:_lingxiagent_models' \\
                '(-C --cd)'{-C,--cd}'[指定工作区路径]:directory:_directories' \\
                '(-e --effort)'{-e,--effort}'[推理深度强度]:effort:(auto low medium high max)' \\
                '--no-alt-screen[禁用终端备用屏幕（保留历史在滚动缓冲）]' \\
                '--enable-mcp[启用指定的 MCP 服务]:mcp_server:' \\
                '--disable-mcp[禁用指定的 MCP 服务]:mcp_server:' \\
                '--enable-skill[启用指定的 Skill]:skill:' \\
                '--disable-skill[禁用指定的 Skill]:skill:' \\
                '(-h --help)'{-h,--help}'[显示帮助信息]' \\
                '(-v --version)'{-v,--version}'[显示版本信息]' \\
                '1: :->cmd' \\
                '*:: :->args'

            case $state in
            cmd)
                local commands; commands=(
                    'auth:Provider 鉴权与账号凭据管理'
                    'mcp:MCP 服务器配置与连接管理'
                    'skills:扩展 Skills 发现与激活管理'
                    'exec:以非交互方式无头运行 Agent 任务'
                    'review:审查当前 git 工作区改动并给出审查报告'
                    'doctor:系统运行环境与健康度诊断'
                    'resume:恢复历史会话'
                    'completion:生成 Shell 自动补全脚本'
                    'help:查看帮助'
                    'version:查看版本'
                )
                _describe 'command' commands
                ;;
            args)
                case $line[1] in
                auth)
                    local subcmds; subcmds=(
                        'login:登录 Provider'
                        'logout:注销 Provider 凭据'
                        'status:查看 Provider 连接状态'
                        'list:列出可用 Provider'
                        'models:列出模型目录'
                        'matrix:查看特性兼容矩阵'
                    )
                    _describe 'auth command' subcmds
                    ;;
                mcp)
                    local subcmds; subcmds=(
                        'list:列出已配置的 MCP 服务器'
                        'status:检测 MCP 服务连通性与工具'
                        'enable:启用 MCP 服务'
                        'disable:禁用 MCP 服务'
                        'auth:配置 MCP 认证凭据'
                        'add:添加新的 MCP 服务'
                        'remove:删除 MCP 服务'
                    )
                    _describe 'mcp command' subcmds
                    ;;
                skills)
                    local subcmds; subcmds=(
                        'list:列出项目与全局已发现 Skills'
                        'info:查看指定 Skill 详情'
                        'enable:启用 Skill'
                        'disable:禁用 Skill'
                    )
                    _describe 'skills command' subcmds
                    ;;
                esac
                ;;
            esac
        }

        _lingxiagent_models() {
            # Model IDs are discovered against the account, so the list is read
            # live rather than baked into this script. A static roster here
            # would go stale the moment a vendor ships a new model.
            local models
            models=(${(f)"$(lingxiagent models --ids 2>/dev/null)"})
            (( ${#models} )) && _describe 'models' models
        }

        compdef _lingxiagent lingxiagent
        """
    }

    private static func generateBash() -> String {
        """
        _lingxiagent_completion() {
            local cur prev opts
            COMPREPLY=()
            cur="${COMP_WORDS[COMP_CWORD]}"
            prev="${COMP_WORDS[COMP_CWORD-1]}"

            opts="auth mcp skills exec review doctor resume completion help version --yolo --model --cd --effort --no-alt-screen --enable-mcp --disable-mcp --enable-skill --disable-skill --help --version"

            case "$prev" in
                auth)
                    COMPREPLY=( $(compgen -W "login logout status list models matrix" -- "$cur") )
                    return 0
                    ;;
                mcp)
                    COMPREPLY=( $(compgen -W "list status enable disable auth add remove help" -- "$cur") )
                    return 0
                    ;;
                skills)
                    COMPREPLY=( $(compgen -W "list info enable disable help" -- "$cur") )
                    return 0
                    ;;
                --effort)
                    COMPREPLY=( $(compgen -W "auto low medium high max" -- "$cur") )
                    return 0
                    ;;
            esac

            COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
            return 0
        }
        complete -F _lingxiagent_completion lingxiagent
        """
    }

    private static func generateFish() -> String {
        """
        complete -c lingxiagent -n "__fish_use_subcommand" -a "auth" -d "Provider 鉴权与账号管理"
        complete -c lingxiagent -n "__fish_use_subcommand" -a "mcp" -d "MCP 服务器管理"
        complete -c lingxiagent -n "__fish_use_subcommand" -a "skills" -d "Skills 技能管理"
        complete -c lingxiagent -n "__fish_use_subcommand" -a "exec" -d "非交互无头执行"
        complete -c lingxiagent -n "__fish_use_subcommand" -a "review" -d "代码审查"
        complete -c lingxiagent -n "__fish_use_subcommand" -a "doctor" -d "环境诊断"
        complete -c lingxiagent -n "__fish_use_subcommand" -a "resume" -d "恢复会话"
        complete -c lingxiagent -n "__fish_use_subcommand" -a "completion" -d "自动补全生成"

        complete -c lingxiagent -s y -l yolo -d "YOLO 自动放行模式"
        complete -c lingxiagent -s m -l model -d "指定模型"
        complete -c lingxiagent -s C -l cd -d "指定工作目录"
        complete -c lingxiagent -s e -l effort -d "推理强度 (auto, low, medium, high, max)"
        complete -c lingxiagent -l no-alt-screen -d "禁用终端备用屏幕"
        """
    }
}
