/// stdio JSON-lines 通道上的消息信封。
/// 每条消息标注所属 plane：控制面（request/response/event）与数据面（chunk/streamEnd）。
/// 两条 plane 共用同一物理通道但逻辑独立，数据面 chunk 不进入控制面事件流。
public enum WireMessage: Sendable, Equatable {
    case request(id: String, command: ClientCommand)
    case response(id: String, response: CoreResponse)
    case event(CoreEvent)
    case chunk(StreamChunk)
    case streamEnd(StreamID)
}

extension WireMessage: Codable {
    private enum Kind: String, Codable {
        case request, response, event, chunk, streamEnd
    }

    private enum CodingKeys: String, CodingKey {
        case kind, id, command, response, event, chunk, streamID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .request:
            self = .request(
                id: try container.decode(String.self, forKey: .id),
                command: try container.decode(ClientCommand.self, forKey: .command)
            )
        case .response:
            self = .response(
                id: try container.decode(String.self, forKey: .id),
                response: try container.decode(CoreResponse.self, forKey: .response)
            )
        case .event:
            self = .event(try container.decode(CoreEvent.self, forKey: .event))
        case .chunk:
            self = .chunk(try container.decode(StreamChunk.self, forKey: .chunk))
        case .streamEnd:
            self = .streamEnd(try container.decode(StreamID.self, forKey: .streamID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .request(id, command):
            try container.encode(Kind.request, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(command, forKey: .command)
        case let .response(id, response):
            try container.encode(Kind.response, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(response, forKey: .response)
        case let .event(event):
            try container.encode(Kind.event, forKey: .kind)
            try container.encode(event, forKey: .event)
        case let .chunk(chunk):
            try container.encode(Kind.chunk, forKey: .kind)
            try container.encode(chunk, forKey: .chunk)
        case let .streamEnd(streamID):
            try container.encode(Kind.streamEnd, forKey: .kind)
            try container.encode(streamID, forKey: .streamID)
        }
    }
}

extension ClientCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .ping: self = .ping
        case .getInfo: self = .getInfo
        case .getState: self = .getState
        case .openTestStream: self = .openTestStream
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
    }
}

extension CoreResponse: Codable {
    private enum TypeKey: String, Codable {
        case pong, info, state, streamOpened, error
    }

    private enum CodingKeys: String, CodingKey {
        case type, info, state, streamID, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(TypeKey.self, forKey: .type) {
        case .pong:
            self = .pong
        case .info:
            self = .info(try container.decode(CoreInfo.self, forKey: .info))
        case .state:
            self = .state(try container.decode(CoreState.self, forKey: .state))
        case .streamOpened:
            self = .streamOpened(try container.decode(StreamID.self, forKey: .streamID))
        case .error:
            self = .error(try container.decode(CoreError.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pong:
            try container.encode(TypeKey.pong, forKey: .type)
        case let .info(info):
            try container.encode(TypeKey.info, forKey: .type)
            try container.encode(info, forKey: .info)
        case let .state(state):
            try container.encode(TypeKey.state, forKey: .type)
            try container.encode(state, forKey: .state)
        case let .streamOpened(streamID):
            try container.encode(TypeKey.streamOpened, forKey: .type)
            try container.encode(streamID, forKey: .streamID)
        case let .error(error):
            try container.encode(TypeKey.error, forKey: .type)
            try container.encode(error, forKey: .error)
        }
    }
}

extension CoreError: Codable {
    private enum CodingKeys: String, CodingKey {
        case code, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = Code(rawValue: try container.decode(String.self, forKey: .code)) ?? .transport
        message = try container.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code.rawValue, forKey: .code)
        try container.encode(message, forKey: .message)
    }
}

extension CoreEvent: Codable {
    private enum TypeKey: String, Codable {
        case stateChanged
    }

    private enum CodingKeys: String, CodingKey {
        case type, state
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(TypeKey.self, forKey: .type) {
        case .stateChanged:
            self = .stateChanged(try container.decode(CoreState.self, forKey: .state))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .stateChanged(state):
            try container.encode(TypeKey.stateChanged, forKey: .type)
            try container.encode(state, forKey: .state)
        }
    }
}
