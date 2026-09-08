import Foundation

/// StreamKind 定义高频数据帧的流分类。
public enum StreamKind: String, Codable, Sendable, Equatable {
    case visibleReasoning
    case reasoningSummary
    case assistantText
    case stdout
    case stderr
    case toolLiveOutput
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = StreamKind(rawValue: raw) ?? .unknown
    }
}

/// StreamFrame：实时高频数据传输单元，属于 live transport optimization，非 durable truth。
public struct StreamFrame: Codable, Sendable, Equatable {
    public let streamID: StreamID
    public let owner: CausalContext
    public let index: UInt64
    public let kind: StreamKind
    public let payload: Data

    public init(
        streamID: StreamID,
        owner: CausalContext,
        index: UInt64,
        kind: StreamKind,
        payload: Data
    ) {
        self.streamID = streamID
        self.owner = owner
        self.index = index
        self.kind = kind
        self.payload = payload
    }

    public init(
        streamID: StreamID,
        owner: CausalContext,
        index: UInt64,
        kind: StreamKind,
        text: String
    ) {
        self.streamID = streamID
        self.owner = owner
        self.index = index
        self.kind = kind
        self.payload = Data(text.utf8)
    }

    public var textPayload: String? {
        String(data: payload, encoding: .utf8)
    }
}
