import Foundation

/// ACP (Agent Client Protocol) JSON-RPC 2.0 基础标识符。
public enum ACPID: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case integer(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .integer(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else {
            throw DecodingError.typeMismatch(ACPID.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected Int or String for ACP ID"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(str):
            try container.encode(str)
        case let .integer(int):
            try container.encode(int)
        }
    }
}

/// JSON-RPC 2.0 错误结构。
public struct ACPError: Codable, Sendable, Equatable, Error {
    public let code: Int
    public let message: String
    public let data: String?

    public init(code: Int, message: String, data: String? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// ACP 基础 JSON-RPC 2.0 报文请求。
public struct ACPRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: ACPID?
    public let method: String
    public let params: JSONValue?

    public init(id: ACPID?, method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    public init<T: Encodable>(id: ACPID?, method: String, paramsPayload: T) throws {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        let data = try JSONEncoder().encode(paramsPayload)
        self.params = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func decodeParams<T: Decodable>(as type: T.Type) throws -> T? {
        guard let params else { return nil }
        let data = try JSONEncoder().encode(params)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// ACP 基础 JSON-RPC 2.0 报文响应。
public struct ACPResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: ACPID?
    public let result: JSONValue?
    public let error: ACPError?

    public init(id: ACPID?, result: JSONValue? = nil, error: ACPError? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }

    public init<T: Encodable>(id: ACPID?, resultPayload: T) throws {
        self.jsonrpc = "2.0"
        self.id = id
        let data = try JSONEncoder().encode(resultPayload)
        self.result = try JSONDecoder().decode(JSONValue.self, from: data)
        self.error = nil
    }
}

/// 客户端信息。
public struct ACPClientInfo: Codable, Sendable, Equatable {
    public let name: String
    public let version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

/// Agent 信息。
public struct ACPAgentInfo: Codable, Sendable, Equatable {
    public let name: String
    public let version: String

    public init(name: String = "LingXiAgent", version: String = "1.0.0") {
        self.name = name
        self.version = version
    }
}

/// Agent Capabilities 声明。
public struct ACPAgentCapabilities: Codable, Sendable, Equatable {
    public let modes: [String]
    public let loadSession: Bool
    public let streaming: Bool

    public init(modes: [String] = ["default", "architect", "code"], loadSession: Bool = true, streaming: Bool = true) {
        self.modes = modes
        self.loadSession = loadSession
        self.streaming = streaming
    }
}

/// initialize 请求参数。
public struct ACPInitializeParams: Codable, Sendable {
    public let clientInfo: ACPClientInfo?
    public let protocolVersion: String?

    public init(clientInfo: ACPClientInfo? = nil, protocolVersion: String? = ACPSpecRevision.modern) {
        self.clientInfo = clientInfo
        self.protocolVersion = protocolVersion
    }
}

/// initialize 响应结果。
public struct ACPInitializeResult: Codable, Sendable, Equatable {
    public let agentInfo: ACPAgentInfo
    public let capabilities: ACPAgentCapabilities
    public let protocolVersion: String

    public init(agentInfo: ACPAgentInfo = ACPAgentInfo(), capabilities: ACPAgentCapabilities = ACPAgentCapabilities(), protocolVersion: String = ACPSpecRevision.modern) {
        self.agentInfo = agentInfo
        self.capabilities = capabilities
        self.protocolVersion = protocolVersion
    }
}

/// session/new 请求参数。
public struct ACPSessionNewParams: Codable, Sendable {
    public let cwd: String
    public let mcpServers: [String]?
    public let mode: String?

    public init(cwd: String, mcpServers: [String]? = nil, mode: String? = nil) {
        self.cwd = cwd
        self.mcpServers = mcpServers
        self.mode = mode
    }
}

/// session/new 响应结果。
public struct ACPSessionNewResult: Codable, Sendable, Equatable {
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

/// session/prompt 请求参数。
public struct ACPSessionPromptParams: Codable, Sendable {
    public let sessionId: String
    public let prompt: String

    public init(sessionId: String, prompt: String) {
        self.sessionId = sessionId
        self.prompt = prompt
    }
}

/// session/prompt 响应结果。
public struct ACPSessionPromptResult: Codable, Sendable, Equatable {
    public let status: String

    public init(status: String = "completed") {
        self.status = status
    }
}

/// session/cancel 请求参数。
public struct ACPSessionCancelParams: Codable, Sendable {
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

/// session/update 单向流式通知内容。
public struct ACPSessionUpdatePayload: Codable, Sendable, Equatable {
    public let type: String // agent_message_chunk, thought_chunk, tool_call, tool_result, state_change
    public let content: String?
    public let toolCallId: String?
    public let name: String?
    public let arguments: String?
    public let output: String?

    public init(
        type: String,
        content: String? = nil,
        toolCallId: String? = nil,
        name: String? = nil,
        arguments: String? = nil,
        output: String? = nil
    ) {
        self.type = type
        self.content = content
        self.toolCallId = toolCallId
        self.name = name
        self.arguments = arguments
        self.output = output
    }
}

/// session/update 顶层参数。
public struct ACPSessionUpdateParams: Codable, Sendable, Equatable {
    public let sessionId: String
    public let update: ACPSessionUpdatePayload

    public init(sessionId: String, update: ACPSessionUpdatePayload) {
        self.sessionId = sessionId
        self.update = update
    }
}
