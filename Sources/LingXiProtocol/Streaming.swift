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
