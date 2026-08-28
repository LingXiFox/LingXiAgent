import Foundation

/// LingXi 的 Tool 领域类型；不包含任何 Provider 原生 schema 或 DTO。
public struct ToolID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ToolCallID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum ToolInputType: String, Sendable, Equatable, Codable {
    case string
}

public struct ToolInputProperty: Sendable, Equatable, Codable {
    public let type: ToolInputType
    public let description: String

    public init(type: ToolInputType, description: String) {
        self.type = type
        self.description = description
    }
}

public struct ToolInputSchema: Sendable, Equatable, Codable {
    public let properties: [String: ToolInputProperty]
    public let required: [String]

    public init(properties: [String: ToolInputProperty], required: [String]) {
        self.properties = properties
        self.required = required
    }
}

public struct ToolCapability: Sendable, Equatable, Codable {
    public let readOnly: Bool

    public init(readOnly: Bool) {
        self.readOnly = readOnly
    }
}

public struct ToolDefinition: Sendable, Equatable, Codable {
    public let id: ToolID
    public let name: String
    public let description: String
    public let inputSchema: ToolInputSchema
    public let capability: ToolCapability

    public init(
        id: ToolID,
        name: String? = nil,
        description: String,
        inputSchema: ToolInputSchema,
        capability: ToolCapability
    ) {
        self.id = id
        self.name = name ?? id.rawValue
        self.description = description
        self.inputSchema = inputSchema
        self.capability = capability
    }
}

public struct ToolCall: Sendable, Equatable, Codable {
    public let callID: ToolCallID
    public let toolID: ToolID
    /// Provider Adapter 已聚合的完整 JSON object，Tool Runtime 负责解码并校验。
    public let arguments: String

    public var toolName: String { toolID.rawValue }

    public init(callID: ToolCallID, toolID: ToolID, arguments: String) {
        self.callID = callID
        self.toolID = toolID
        self.arguments = arguments
    }
}

public struct ToolError: Sendable, Equatable, Codable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ToolResult: Sendable, Equatable, Codable {
    public let callID: ToolCallID
    public let success: Bool
    public let content: String
    public let error: ToolError?

    public init(callID: ToolCallID, success: Bool, content: String, error: ToolError? = nil) {
        self.callID = callID
        self.success = success
        self.content = content
        self.error = error
    }
}
