import Foundation

/// EventCursor 定义 Event Log 的因果点与 replay 边界。
public struct EventCursor: Codable, Sendable, Equatable, Hashable, Comparable {
    public let generationID: EventLogGenerationID
    public let sequence: UInt64

    public init(generationID: EventLogGenerationID, sequence: UInt64) {
        self.generationID = generationID
        self.sequence = sequence
    }

    public static func < (lhs: EventCursor, rhs: EventCursor) -> Bool {
        if lhs.generationID == rhs.generationID {
            return lhs.sequence < rhs.sequence
        }
        return lhs.generationID.rawValue < rhs.generationID.rawValue
    }
}

/// EventStreamScope 标识事件流的作用域，消除裸 EventCursor 的归属歧义。
public enum EventStreamScope: Codable, Sendable, Equatable, Hashable {
    case runtime
    case session(SessionID)
    case unknown(String)

    private enum CodingKeys: String, CodingKey {
        case type, sessionID, rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "runtime":
            self = .runtime
        case "session":
            let id = try container.decode(SessionID.self, forKey: .sessionID)
            self = .session(id)
        default:
            let raw = (try? container.decode(String.self, forKey: .rawValue)) ?? type
            self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .runtime:
            try container.encode("runtime", forKey: .type)
        case let .session(id):
            try container.encode("session", forKey: .type)
            try container.encode(id, forKey: .sessionID)
        case let .unknown(raw):
            try container.encode("unknown", forKey: .type)
            try container.encode(raw, forKey: .rawValue)
        }
    }
}

/// EventWatermark 包含作用域与游标，用于 Command Receipt 和同步状态确认。
public struct EventWatermark: Codable, Sendable, Equatable, Hashable {
    public let scope: EventStreamScope
    public let cursor: EventCursor

    public init(scope: EventStreamScope, cursor: EventCursor) {
        self.scope = scope
        self.cursor = cursor
    }
}
