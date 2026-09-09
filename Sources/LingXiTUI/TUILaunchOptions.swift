import Foundation
import LingXiProtocol

/// TUI 启动配置参数（由 CLI 统一入口传入）。
public struct TUILaunchOptions: Sendable, Equatable {
    /// 启动时直接提交的首轮 Prompt（若有）
    public var initialPrompt: String?
    /// 启动时覆盖的模型 ID（例如 gpt-5-5, bai/deepseek-v4-flash）
    public var initialModelID: String?
    /// 初始工作目录覆盖路径
    public var initialWorkingDir: String?
    /// 是否开启 YOLO 模式（全自动执行，跳过所有人工确认）
    public var isYoloMode: Bool
    /// 推理思考强度
    public var reasoningEffort: ReasoningEffort?
    /// 是否禁用终端 Alternate Screen
    public var noAltScreen: Bool
    /// 启动时启用的 MCP 服务
    public var mcpEnables: [String]
    /// 启动时禁用的 MCP 服务
    public var mcpDisables: [String]
    /// 启动时启用的 Skills
    public var skillEnables: [String]
    /// 启动时禁用的 Skills
    public var skillDisables: [String]
    /// 恢复的历史会话 ID
    public var resumeSessionID: String?

    public init(
        initialPrompt: String? = nil,
        initialModelID: String? = nil,
        initialWorkingDir: String? = nil,
        isYoloMode: Bool = false,
        reasoningEffort: ReasoningEffort? = nil,
        noAltScreen: Bool = false,
        mcpEnables: [String] = [],
        mcpDisables: [String] = [],
        skillEnables: [String] = [],
        skillDisables: [String] = [],
        resumeSessionID: String? = nil
    ) {
        self.initialPrompt = initialPrompt
        self.initialModelID = initialModelID
        self.initialWorkingDir = initialWorkingDir
        self.isYoloMode = isYoloMode
        self.reasoningEffort = reasoningEffort
        self.noAltScreen = noAltScreen
        self.mcpEnables = mcpEnables
        self.mcpDisables = mcpDisables
        self.skillEnables = skillEnables
        self.skillDisables = skillDisables
        self.resumeSessionID = resumeSessionID
    }

    public static let `default` = TUILaunchOptions()
}
