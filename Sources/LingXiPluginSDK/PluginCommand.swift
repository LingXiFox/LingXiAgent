import Foundation

/// 插件命令或结果在终端中的展示方式。
public enum PluginPresentationStyle: String, Codable, Sendable {
    /// 弹出式窗口展示（类似 Model Picker / Preferences 弹窗），支持键盘上下滚动与按 Esc 关闭
    case modal
    /// 行内展示（作为消息追加到时间轴/Transcript）
    case inline
}

/// 插件命令执行结果。
public enum PluginCommandResult: Sendable, Equatable {
    /// 本地直接向终端输出富文本/卡片（不消耗 LLM Token）
    /// - Parameters:
    ///   - text: 输出文本或卡片内容
    ///   - presentation: 展示形态，默认为 `.modal` 居中弹窗，可选 `.inline` 行内流式输出
    ///   - title: 当 presentation 为 `.modal` 时的弹窗标题（可选，默认使用插件或命令名）
    case message(String, presentation: PluginPresentationStyle = .modal, title: String? = nil)
    /// 构造提示词指令注入会话，触发 Agent 思考与工具循环
    case prompt(String)
}

/// 插件命令执行上下文。
public struct CommandExecutionContext: Sendable {
    public let sessionID: String?
    public let info: PluginInfoHub
    public let logger: PluginLogger

    public init(sessionID: String?, info: PluginInfoHub, logger: PluginLogger) {
        self.sessionID = sessionID
        self.info = info
        self.logger = logger
    }
}

/// 外部插件声明的 Slash Command 协议。
public protocol PluginCommand: Sendable {
    var name: String { get }
    var aliases: [String] { get }
    var description: String { get }
    var category: String { get }
    var argumentHint: String { get }

    func execute(args: [String], context: CommandExecutionContext) async throws -> PluginCommandResult
}

public extension PluginCommand {
    var aliases: [String] { [] }
    var category: String { "Plugin" }
    var argumentHint: String { "" }
}
