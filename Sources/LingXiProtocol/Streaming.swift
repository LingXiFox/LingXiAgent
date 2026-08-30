import Foundation

/// 一条 Streaming 通道的标识。
public struct StreamID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Streaming chunk 的内容类别。
public enum StreamChunkKind: String, Sendable, Equatable, Codable {
    case text
    case reasoning
}

/// Streaming DMA 数据面的一个连续数据块。
public struct StreamChunk: Sendable, Equatable, Codable {
    public let streamID: StreamID
    public let sessionID: SessionID?
    public let agentRunID: AgentRunID?
    /// 单调递增序号，用于顺序校验。
    public let index: Int
    public let text: String
    public let kind: StreamChunkKind
    public let timestamp: Date

    public init(streamID: StreamID, sessionID: SessionID? = nil, agentRunID: AgentRunID? = nil, index: Int, text: String, kind: StreamChunkKind = .text, timestamp: Date = .now) {
        self.streamID = streamID
        self.sessionID = sessionID
        self.agentRunID = agentRunID
        self.index = index
        self.text = text
        self.kind = kind
        self.timestamp = timestamp
    }
}

/// High-volume stdout/stderr travels on the data plane, never through CoreEvent.
public struct ToolOutputChunk: Sendable, Equatable, Codable {
    public enum Stream: String, Sendable, Equatable, Codable {
        case stdout
        case stderr
    }

    public let toolCallID: ToolCallID?
    public let sessionID: SessionID?
    public let agentRunID: AgentRunID?
    public let processID: String?
    public let stream: Stream
    public let sequence: Int
    public let payload: String

    public init(toolCallID: ToolCallID? = nil, sessionID: SessionID? = nil, agentRunID: AgentRunID? = nil, processID: String? = nil, stream: Stream, sequence: Int, payload: String) {
        self.toolCallID = toolCallID
        self.sessionID = sessionID
        self.agentRunID = agentRunID
        self.processID = processID
        self.stream = stream
        self.sequence = sequence
        self.payload = payload
    }
}
