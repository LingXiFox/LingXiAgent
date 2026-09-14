import Foundation

/// 插件工具执行上下文。
public struct ToolExecutionContext: Sendable {
    public let sessionID: String
    public let toolCallID: String
    public let logger: PluginLogger

    public init(sessionID: String, toolCallID: String, logger: PluginLogger) {
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.logger = logger
    }
}

/// 外部插件声明的原生 Tool 协议。
public protocol PluginTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: String { get }

    func execute(arguments: String, context: ToolExecutionContext) async throws -> String
}

public extension PluginTool {
    var inputSchema: String {
        "{\"type\": \"object\", \"properties\": {}}"
    }
}
