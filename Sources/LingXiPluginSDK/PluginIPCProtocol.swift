import Foundation

/// LingXi Plugin IPC 的版本与方法表。
///
/// 这是 newline-delimited JSON(每行一个请求/响应),不是标准 JSON-RPC 2.0:
/// 线格式里没有 `jsonrpc` 字段,也没有 batch 与 notification 语义。文档、网页与
/// README 一律称 `LingXi Plugin IPC / JSON Lines IPC`。
///
/// 协议兼容性由 `ipcVersion` 判定,不靠比较 Core 的版本字符串。
public enum PluginIPC {
    /// 本 SDK 实现并支持的协议版本。
    public static let currentVersion = 1

    /// 本 SDK 自身版本,随握手上报。插件作者不需要维护它;它的作用是让 Core 在
    /// 排障时知道某个插件是用哪一版 SDK 编译的。
    public static let sdkVersion = "0.1.0"

    /// 本 SDK 能对话的版本集合。不在其中的对端必须被明确拒绝,而不是等到某个
    /// command 解码失败才炸。
    public static let supportedVersions: Set<Int> = [1]

    /// 兼容判定:两端是否有共同版本。
    public static func isCompatible(_ peerVersion: Int) -> Bool {
        supportedVersions.contains(peerVersion)
    }

    /// 协议方法名。Core、SDK 与文档共用这一张表,避免 `tool.call` / `tool.execute`
    /// 这类文档与代码各说各话。
    public enum Method: String, Codable, Sendable, CaseIterable {
        /// Core → Plugin:推送权威运行快照。
        case snapshot = "host.snapshot"
        /// Core → Plugin:握手,返回 manifest / 版本 / tools / commands。
        case initialize = "plugin.initialize"
        /// Core → Plugin:执行插件 Tool。
        case toolExecute = "tool.execute"
        /// Core → Plugin:执行插件 Command。
        case commandExecute = "command.execute"
        /// Core → Plugin:广播生命周期 Hook。
        case hookEmit = "hook.emit"
    }
}

/// 握手请求参数:Core 先声明自己的协议版本,插件据此判断能否对话。
public struct PluginInitializeParams: Codable, Sendable, Equatable {
    public let hostIPCVersion: Int
    public let coreVersion: String

    public init(hostIPCVersion: Int = PluginIPC.currentVersion, coreVersion: String) {
        self.hostIPCVersion = hostIPCVersion
        self.coreVersion = coreVersion
    }
}

/// 插件端 IPC 消息类型与载荷。
public struct PluginIPCRequest: Codable, Sendable {
    public let id: String
    public let method: String
    public let params: Data?

    public init(id: String = UUID().uuidString, method: String, params: Data? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// 以协议方法枚举构造,避免拼写漂移。
    public init(id: String = UUID().uuidString, method: PluginIPC.Method, params: Data? = nil) {
        self.id = id
        self.method = method.rawValue
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
///
/// `ipcVersion` 是插件(经由本 SDK)实际使用的协议版本;Core 在加载阶段就据此判定
/// 兼容,不兼容则明确失败并终止进程,而不是等到某次调用解码失败。
public struct PluginHandshakeResult: Codable, Sendable, Equatable {
    public let manifest: PluginManifest
    public let ipcVersion: Int
    /// 插件链接的 SDK 版本,便于诊断「插件用旧 SDK 编译」这类问题。
    public let sdkVersion: String?
    public let tools: [PluginToolDescriptor]
    public let commands: [PluginCommandDescriptor]
    /// 插件声明会处理的 Hook 事件;为空数组表示不处理任何 Hook。
    public let supportedHooks: [String]?

    public init(
        manifest: PluginManifest,
        ipcVersion: Int = PluginIPC.currentVersion,
        sdkVersion: String? = PluginIPC.sdkVersion,
        tools: [PluginToolDescriptor],
        commands: [PluginCommandDescriptor],
        supportedHooks: [String]? = nil
    ) {
        self.manifest = manifest
        self.ipcVersion = ipcVersion
        self.sdkVersion = sdkVersion
        self.tools = tools
        self.commands = commands
        self.supportedHooks = supportedHooks
    }

    /// 老版本握手包没有 `ipcVersion` / `sdkVersion` / `supportedHooks`。缺失不等于
    /// 版本 1:那是插件没声明,必须显式拒绝,否则一个说另一种协议的插件会被当成
    /// 说本协议的一路放行到运行期才失败。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.manifest = try container.decode(PluginManifest.self, forKey: .manifest)
        self.ipcVersion = try container.decode(Int.self, forKey: .ipcVersion)
        self.sdkVersion = try container.decodeIfPresent(String.self, forKey: .sdkVersion)
        self.tools = try container.decode([PluginToolDescriptor].self, forKey: .tools)
        self.commands = try container.decode([PluginCommandDescriptor].self, forKey: .commands)
        self.supportedHooks = try container.decodeIfPresent([String].self, forKey: .supportedHooks)
    }

    enum CodingKeys: String, CodingKey {
        case manifest, ipcVersion, sdkVersion, tools, commands, supportedHooks
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

    enum CodingKeys: String, CodingKey {
        case isPrompt
        case text
        case presentation
        case title
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isPrompt = try container.decode(Bool.self, forKey: .isPrompt)
        self.text = try container.decode(String.self, forKey: .text)
        self.presentation = try container.decodeIfPresent(String.self, forKey: .presentation) ?? "modal"
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
    }
}
