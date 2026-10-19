public struct TypedID<Tag>: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { "\(Tag.self) \(rawValue)" }
}

extension TypedID: Codable {
    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }
}

public enum SessionTag: Sendable {}
public enum TurnTag: Sendable {}
public enum RunTag: Sendable {}
public enum RequestTag: Sendable {}
public enum ExecutionTag: Sendable {}
public enum BatchTag: Sendable {}
public enum ToolCallTag: Sendable {}
public enum EntryTag: Sendable {}
public enum ModelTag: Sendable {}
public enum ProviderTag: Sendable {}

public typealias SessionID = TypedID<SessionTag>
public typealias TurnID = TypedID<TurnTag>
public typealias RunID = TypedID<RunTag>
public typealias RequestID = TypedID<RequestTag>
public typealias ExecutionID = TypedID<ExecutionTag>
public typealias BatchID = TypedID<BatchTag>
public typealias ToolCallID = TypedID<ToolCallTag>
public typealias EntryID = TypedID<EntryTag>
public typealias ModelID = TypedID<ModelTag>
public typealias ProviderID = TypedID<ProviderTag>
