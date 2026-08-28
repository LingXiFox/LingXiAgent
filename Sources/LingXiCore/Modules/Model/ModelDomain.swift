import Foundation
import LingXiProtocol

// LingXi 自己的模型领域模型。
// 这里没有任何 Provider 原生类型（choices / delta / finish_reason 等
// 只存在于 OpenAICompatibleProvider Adapter 内部）。

public struct ModelID: Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum ModelRole: String, Sendable {
    case system
    case user
    case assistant
    case tool
}

/// 模型输入的结构化部分；Provider Adapter 再转换为厂商消息格式。
public enum ModelContentPart: Sendable, Equatable {
    case text(String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
}

public struct ModelMessage: Sendable, Equatable {
    public let role: ModelRole
    public let parts: [ModelContentPart]

    public var content: String {
        parts.compactMap { if case let .text(text) = $0 { text } else { nil } }.joined()
    }

    public init(role: ModelRole, content: String) {
        self.init(role: role, parts: [.text(content)])
    }

    public init(role: ModelRole, parts: [ModelContentPart]) {
        self.role = role
        self.parts = parts
    }
}

public struct ModelRequest: Sendable, Equatable {
    public let model: ModelID
    public let system: String?
    public let messages: [ModelMessage]
    public let tools: [ToolDefinition]

    public init(model: ModelID, system: String? = nil, messages: [ModelMessage], tools: [ToolDefinition] = []) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
    }
}

/// 模型推理事件流。高频 delta 走 DMA，started/usage/completed/failed 由 Agent 分流到控制面。
public enum ModelEvent: Sendable, Equatable {
    /// Provider 连接建立、推理即将开始。
    case started
    case textDelta(String)
    /// 推理内容 delta；Provider 不支持时不会出现。
    case reasoningDelta(String)
    case toolCallStarted(callID: ToolCallID, toolID: ToolID)
    case toolCallDelta(callID: ToolCallID, arguments: String)
    case toolCallCompleted(ToolCall)
    case usage(ModelUsage)
    case completed(ModelFinishReason)
    /// 流中途失败（Model Stream Error）。
    case failed(CoreError)
}
