import Foundation

/// 插件 IPC 消息类型与载荷。
public struct PluginIPCRequest: Codable, Sendable {
    public let id: String
    public let method: String
    public let params: Data?

    public init(id: String = UUID().uuidString, method: String, params: Data? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct PluginIPCResponse: Codable, Sendable {
    public let id: String
    public let result: Data?
    public let error: String?

    public init(id: String, result: Data? = nil, error: String? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }
}

/// 插件向 Core 宣告的 Tool 描述。
public struct PluginToolDescriptor: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: String

    public init(name: String, description: String, inputSchema: String) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// 插件向 Core 宣告的 Command 描述。
public struct PluginCommandDescriptor: Codable, Sendable, Equatable {
    public let name: String
    public let aliases: [String]
    public let description: String
    public let category: String
    public let argumentHint: String

    public init(name: String, aliases: [String] = [], description: String, category: String = "Plugin", argumentHint: String = "") {
        self.name = name
        self.aliases = aliases
        self.description = description
        self.category = category
        self.argumentHint = argumentHint
    }
}

/// 握手结果。
public struct PluginHandshakeResult: Codable, Sendable, Equatable {
    public let manifest: PluginManifest
    public let tools: [PluginToolDescriptor]
    public let commands: [PluginCommandDescriptor]

    public init(manifest: PluginManifest, tools: [PluginToolDescriptor], commands: [PluginCommandDescriptor]) {
        self.manifest = manifest
        self.tools = tools
        self.commands = commands
    }
}

/// Tool 执行参数。
public struct PluginToolCallParams: Codable, Sendable {
    public let toolName: String
    public let arguments: String
    public let sessionID: String
    public let toolCallID: String

    public init(toolName: String, arguments: String, sessionID: String, toolCallID: String) {
        self.toolName = toolName
        self.arguments = arguments
        self.sessionID = sessionID
        self.toolCallID = toolCallID
    }
}

/// Command 执行参数。
public struct PluginCommandCallParams: Codable, Sendable {
    public let commandName: String
    public let arguments: [String]
    public let sessionID: String?

    public init(commandName: String, arguments: [String], sessionID: String?) {
        self.commandName = commandName
        self.arguments = arguments
        self.sessionID = sessionID
    }
}

/// Command 执行回包。
public struct PluginCommandCallResult: Codable, Sendable, Equatable {
    public let isPrompt: Bool
    public let text: String
    public let presentation: String
    public let title: String?

    public init(isPrompt: Bool, text: String, presentation: String = "modal", title: String? = nil) {
        self.isPrompt = isPrompt
        self.text = text
        self.presentation = presentation
        self.title = title
    }
}
