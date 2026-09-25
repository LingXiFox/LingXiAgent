import Foundation

/// Every Settings page, grouped as in the sidebar. One level only: a page is a
/// leaf, never another sidebar.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general, appearance, conversation, shortcuts
    case providers, models, agentDefaults, permissions, context, execution, codeIntelligence
    case mcp, extensions, computerUse
    case workspace
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .conversation: return "对话"
        case .shortcuts: return "快捷键"
        case .providers: return "Provider"
        case .models: return "模型"
        case .agentDefaults: return "Agent 默认"
        case .permissions: return "权限与沙箱"
        case .context: return "上下文"
        case .execution: return "执行与超时"
        case .codeIntelligence: return "代码智能"
        case .mcp: return "MCP"
        case .extensions: return "Skills 与插件"
        case .computerUse: return "Computer Use 与浏览器"
        case .workspace: return "工作区与 Worktree"
        case .diagnostics: return "诊断"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .conversation: return "text.bubble"
        case .shortcuts: return "keyboard"
        case .providers: return "server.rack"
        case .models: return "cpu"
        case .agentDefaults: return "person.crop.rectangle.stack"
        case .permissions: return "lock.shield"
        case .context: return "square.stack.3d.up"
        case .execution: return "timer"
        case .codeIntelligence: return "curlybraces"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .extensions: return "puzzlepiece.extension"
        case .computerUse: return "cursorarrow.rays"
        case .workspace: return "folder"
        case .diagnostics: return "stethoscope"
        }
    }

    /// Pages whose content only exists while a Core is connected.
    var needsCore: Bool {
        switch self {
        case .providers, .models, .mcp, .extensions, .workspace: return true
        default: return false
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case app = "应用", agent = "Agent", extensions = "扩展", workspace = "工作区", system = "系统"
        var id: String { rawValue }

        var pages: [SettingsPage] {
            switch self {
            case .app: return [.general, .appearance, .conversation, .shortcuts]
            case .agent: return [.providers, .models, .agentDefaults, .permissions, .context, .execution, .codeIntelligence]
            case .extensions: return [.mcp, .extensions, .computerUse]
            case .workspace: return [.workspace]
            case .system: return [.diagnostics]
            }
        }
    }
}

/// One searchable target. `anchor` is the id the page puts on the owning row,
/// so a result can scroll to and highlight it.
struct SettingsSearchItem: Identifiable, Hashable {
    let anchor: String
    let page: SettingsPage
    let title: String
    var keywords: [String] = []

    var id: String { "\(page.rawValue)/\(anchor)" }

    func matches(_ query: String) -> Bool {
        let haystack = ([title, page.title] + keywords).joined(separator: " ")
        return query.split(separator: " ").allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }
}

/// Explicit registry of stable controls (search does not scrape views).
/// Dynamic entities — providers, models, extensions — are appended at query
/// time from the live store.
enum SettingsSearchIndex {
    static let staticItems: [SettingsSearchItem] = [
        .init(anchor: "core.link", page: .general, title: "Core 连接", keywords: ["connect", "进程", "stdio"]),
        .init(anchor: "core.workspace", page: .general, title: "工作区目录", keywords: ["workspace", "cwd", "目录"]),
        .init(anchor: "files", page: .general, title: "配置文件", keywords: ["config.json", "providers.json", "mcp.json", "finder"]),
        .init(anchor: "general.reopen", page: .general, title: "启动时打开上次的工作区", keywords: ["launch", "startup", "restore", "恢复"]),
        .init(anchor: "general.sleep", page: .general, title: "运行时阻止系统睡眠", keywords: ["sleep", "caffeinate", "睡眠"]),

        .init(anchor: "appearance.scheme", page: .appearance, title: "配色模式", keywords: ["dark", "light", "深色", "浅色", "theme"]),
        .init(anchor: "appearance.atmosphere", page: .appearance, title: "背景氛围", keywords: ["background", "glow", "渐变"]),
        .init(anchor: "appearance.panel", page: .appearance, title: "浮动面板材质", keywords: ["glass", "玻璃", "透明", "material"]),

        .init(anchor: "conversation.thinking", page: .conversation, title: "默认展开思考", keywords: ["thinking", "reasoning"]),
        .init(anchor: "conversation.tools", page: .conversation, title: "默认展开工具输出", keywords: ["tool", "output"]),
        .init(anchor: "conversation.sendKey", page: .conversation, title: "发送方式", keywords: ["return", "enter", "回车", "send"]),

        .init(anchor: "shortcuts.list", page: .shortcuts, title: "快捷键列表", keywords: ["shortcut", "hotkey", "⌘"]),

        .init(anchor: "providers.list", page: .providers, title: "Provider 账户", keywords: ["api key", "账户", "endpoint"]),
        .init(anchor: "providers.reload", page: .providers, title: "重新发现 Provider", keywords: ["discovery", "catalog", "刷新"]),
        .init(anchor: "models.default", page: .models, title: "默认模型", keywords: ["model", "selection"]),
        .init(anchor: "models.catalog", page: .models, title: "模型目录", keywords: ["context window", "上下文窗口", "reasoning"]),

        .init(anchor: ConfigKeys.behaviorProfile.id, page: .agentDefaults, title: "默认行为模式", keywords: ["build", "plan", "explore", "mode"]),
        .init(anchor: "agent.reasoning", page: .agentDefaults, title: "默认思考强度", keywords: ["reasoning", "effort", "think"]),
        .init(anchor: ConfigKeys.codeIntelligence.id, page: .codeIntelligence, title: "代码智能工具", keywords: ["code intelligence", "lsp", "symbol", "references"]),
        .init(anchor: "code.index", page: .codeIntelligence, title: "项目索引与代码图谱", keywords: ["index", "graph", "codebase", "索引"]),
        .init(anchor: ConfigKeys.maxAgentLoopSteps.id, page: .agentDefaults, title: "单轮最大步数", keywords: ["loop", "steps"]),
        .init(anchor: "agent.subagents", page: .agentDefaults, title: "子 Agent 并发与深度", keywords: ["subagent", "concurrency", "depth"]),
        .init(anchor: ConfigKeys.systemContext.id, page: .agentDefaults, title: "系统上下文", keywords: ["system prompt", "instructions"]),

        .init(anchor: ConfigKeys.permissionPolicy.id, page: .permissions, title: "审批策略", keywords: ["ask", "auto", "approval", "permission"]),
        .init(anchor: ConfigKeys.executionProfile.id, page: .permissions, title: "访问范围", keywords: ["sandbox", "readOnly", "fullAccess", "workspace", "沙箱"]),
        .init(anchor: "permissions.apply", page: .permissions, title: "应用到当前 Core", keywords: ["yolo"]),
        .init(anchor: "permissions.matrix", page: .permissions, title: "审批矩阵", keywords: ["safe read", "mutation", "process", "external", "sensitive"]),

        .init(anchor: "context.budget", page: .context, title: "上下文预算", keywords: ["budget", "reserve", "token"]),
        .init(anchor: "context.layers", page: .context, title: "L1 / L2 / L3 分层", keywords: ["l1", "l2", "l3", "cache"]),
        .init(anchor: ConfigKeys.economicThreshold.id, page: .context, title: "经济阈值", keywords: ["economic", "threshold", "272k"]),
        .init(anchor: "context.fabric", page: .context, title: "Context Fabric", keywords: ["e-core", "heat", "objectization"]),
        .init(anchor: "context.live", page: .context, title: "当前生效策略", keywords: ["policy", "snapshot"]),

        .init(anchor: ConfigKeys.foregroundShellSeconds.id, page: .execution, title: "前台命令超时", keywords: ["timeout", "shell", "命令"]),
        .init(anchor: "execution.budgets", page: .execution, title: "分类执行时限", keywords: ["build", "test", "mcp", "provider", "subagent"]),

        .init(anchor: "mcp.list", page: .mcp, title: "MCP 服务器", keywords: ["mcp", "server", "tools"]),
        .init(anchor: "mcp.reload", page: .mcp, title: "重新加载扩展", keywords: ["reload"]),
        .init(anchor: "extensions.list", page: .extensions, title: "Skills、插件、命令与 Hooks", keywords: ["skill", "plugin", "hook", "command"]),
        .init(anchor: "computer.permissions", page: .computerUse, title: "屏幕录制与辅助功能权限", keywords: ["screen recording", "accessibility", "computer use", "browser"]),

        .init(anchor: "workspace.summary", page: .workspace, title: "当前工作区", keywords: ["git", "index", "索引"]),
        .init(anchor: "workspace.worktrees", page: .workspace, title: "Worktree 列表", keywords: ["worktree", "branch", "prune"]),

        .init(anchor: "diagnostics.runtime", page: .diagnostics, title: "运行时状态", keywords: ["health", "version", "uptime"]),
        .init(anchor: "diagnostics.background", page: .diagnostics, title: "后台任务", keywords: ["background", "process", "kill"]),
        .init(anchor: "diagnostics.bundle", page: .diagnostics, title: "导出诊断包", keywords: ["bundle", "debug", "issue"]),
    ]
}
