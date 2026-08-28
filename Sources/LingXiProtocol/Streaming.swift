/// 一条 Streaming 通道的标识。
public struct StreamID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Streaming DMA 数据面的一个连续数据块。
public struct StreamChunk: Sendable, Equatable, Codable {
    public let streamID: StreamID
    /// 单调递增序号，用于顺序校验。
    public let index: Int
    public let text: String

    public init(streamID: StreamID, index: Int, text: String) {
        self.streamID = streamID
        self.index = index
        self.text = text
    }
}
