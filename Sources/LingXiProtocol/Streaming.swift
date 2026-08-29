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
    /// 单调递增序号，用于顺序校验。
    public let index: Int
    public let text: String
    public let kind: StreamChunkKind

    public init(streamID: StreamID, index: Int, text: String, kind: StreamChunkKind = .text) {
        self.streamID = streamID
        self.index = index
        self.text = text
        self.kind = kind
    }
}

/// High-volume stdout/stderr travels on the data plane, never through CoreEvent.
public struct ToolOutputChunk: Sendable, Equatable, Codable {
    public enum Stream: String, Sendable, Equatable, Codable {
        case stdout
        case stderr
    }

    public let toolCallID: ToolCallID?
    public let processID: String?
    public let stream: Stream
    public let sequence: Int
    public let payload: String

    public init(toolCallID: ToolCallID? = nil, processID: String? = nil, stream: Stream, sequence: Int, payload: String) {
        self.toolCallID = toolCallID
        self.processID = processID
        self.stream = stream
        self.sequence = sequence
        self.payload = payload
    }
}
