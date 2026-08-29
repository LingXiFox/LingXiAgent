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
        case type, sessionID, content, permissionReply, permissionConfiguration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .ping: self = .ping
        case .getInfo: self = .getInfo
        case .getState: self = .getState
        case .openTestStream: self = .openTestStream
        case .createSession: self = .createSession
        case .listSessions: self = .listSessions
        case .getSession:
            self = .getSession(sessionID: try container.decode(SessionID.self, forKey: .sessionID))
        case .getContext:
            self = .getContext(sessionID: try container.decode(SessionID.self, forKey: .sessionID))
        case .getPerformance:
            self = .getPerformance(sessionID: try container.decode(SessionID.self, forKey: .sessionID))
        case .getProviderStatus: self = .getProviderStatus
        case .getPermissionConfiguration: self = .getPermissionConfiguration
        case .setPermissionConfiguration:
            self = .setPermissionConfiguration(try container.decode(PermissionConfiguration.self, forKey: .permissionConfiguration))
        case .getProjectCache: self = .getProjectCache
        case .compactSession: self = .compactSession(sessionID: try container.decode(SessionID.self, forKey: .sessionID))
        case .replyPermission:
            self = .replyPermission(try container.decode(PermissionReply.self, forKey: .permissionReply))
        case .sendMessage:
            self = .sendMessage(
                sessionID: try container.decode(SessionID.self, forKey: .sessionID),
                content: try container.decode(String.self, forKey: .content)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case let .getSession(sessionID):
            try container.encode(sessionID, forKey: .sessionID)
        case let .getContext(sessionID), let .getPerformance(sessionID), let .compactSession(sessionID):
            try container.encode(sessionID, forKey: .sessionID)
        case let .sendMessage(sessionID, content):
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(content, forKey: .content)
        case let .replyPermission(reply):
            try container.encode(reply, forKey: .permissionReply)
        case let .setPermissionConfiguration(configuration):
            try container.encode(configuration, forKey: .permissionConfiguration)
        default:
            break
        }
    }
}

extension CoreResponse: Codable {
    private enum TypeKey: String, Codable {
        case pong, info, state, streamOpened, providerStatus
        case sessionCreated, sessionList, sessionDetail, permissionReplyAccepted, context, performance, permissionConfiguration, projectCache, compactSession, error
    }

    private enum CodingKeys: String, CodingKey {
        case type, info, state, streamID, providerStatus, session, sessions, permissionID, context, performance, permissionConfiguration, projectCache, compactSession, error
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
        case .providerStatus:
            self = .providerStatus(try container.decode(ProviderStatus.self, forKey: .providerStatus))
        case .sessionCreated:
            self = .sessionCreated(try container.decode(SessionInfo.self, forKey: .session))
        case .sessionList:
            self = .sessionList(try container.decode([SessionInfo].self, forKey: .sessions))
        case .sessionDetail:
            self = .sessionDetail(try container.decode(SessionSnapshot.self, forKey: .session))
        case .permissionReplyAccepted:
            self = .permissionReplyAccepted(try container.decode(PermissionID.self, forKey: .permissionID))
        case .context:
            self = .context(try container.decodeIfPresent(ContextDebugSnapshot.self, forKey: .context))
        case .performance:
            self = .performance(try container.decodeIfPresent(TurnPerformanceReport.self, forKey: .performance))
        case .permissionConfiguration:
            self = .permissionConfiguration(try container.decode(PermissionConfiguration.self, forKey: .permissionConfiguration))
        case .projectCache:
            self = .projectCache(try container.decode(ProjectCacheDebugSnapshot.self, forKey: .projectCache))
        case .compactSession:
            self = .compactSession(try container.decode(CompactSessionResponse.self, forKey: .compactSession))
        case .error:
            self = .error(try container.decode(CoreError.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kindKey, forKey: .type)
        switch self {
        case .pong:
            break
        case let .info(info):
            try container.encode(info, forKey: .info)
        case let .state(state):
            try container.encode(state, forKey: .state)
        case let .streamOpened(streamID):
            try container.encode(streamID, forKey: .streamID)
        case let .providerStatus(status):
            try container.encode(status, forKey: .providerStatus)
        case let .sessionCreated(info):
            try container.encode(info, forKey: .session)
        case let .sessionList(infos):
            try container.encode(infos, forKey: .sessions)
        case let .sessionDetail(snapshot):
            try container.encode(snapshot, forKey: .session)
        case let .permissionReplyAccepted(permissionID):
            try container.encode(permissionID, forKey: .permissionID)
        case let .context(snapshot):
            try container.encodeIfPresent(snapshot, forKey: .context)
        case let .performance(report):
            try container.encodeIfPresent(report, forKey: .performance)
        case let .permissionConfiguration(configuration):
            try container.encode(configuration, forKey: .permissionConfiguration)
        case let .projectCache(snapshot):
            try container.encode(snapshot, forKey: .projectCache)
        case let .compactSession(response):
            try container.encode(response, forKey: .compactSession)
        case let .error(error):
            try container.encode(error, forKey: .error)
        }
    }

    private var kindKey: TypeKey {
        switch self {
        case .pong: .pong
        case .info: .info
        case .state: .state
        case .streamOpened: .streamOpened
        case .providerStatus: .providerStatus
        case .sessionCreated: .sessionCreated
        case .sessionList: .sessionList
        case .sessionDetail: .sessionDetail
        case .permissionReplyAccepted: .permissionReplyAccepted
        case .context: .context
        case .performance: .performance
        case .permissionConfiguration: .permissionConfiguration
        case .projectCache: .projectCache
        case .compactSession: .compactSession
        case .error: .error
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
        case stateChanged, sessionCreated, turnStarted, turnCompleted, turnFailed
        case toolCallCompleted, toolResult, permissionAsked
    }

    private enum CodingKeys: String, CodingKey {
        case type, state, sessionID, handle, result, failure, toolCall, toolResult, permissionRequest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(TypeKey.self, forKey: .type) {
        case .stateChanged:
            self = .stateChanged(try container.decode(CoreState.self, forKey: .state))
        case .sessionCreated:
            self = .sessionCreated(try container.decode(SessionID.self, forKey: .sessionID))
        case .turnStarted:
            self = .turnStarted(try container.decode(TurnHandle.self, forKey: .handle))
        case .turnCompleted:
            self = .turnCompleted(try container.decode(TurnResult.self, forKey: .result))
        case .turnFailed:
            self = .turnFailed(try container.decode(TurnFailure.self, forKey: .failure))
        case .toolCallCompleted:
            self = .toolCallCompleted(try container.decode(ToolCall.self, forKey: .toolCall))
        case .toolResult:
            self = .toolResult(try container.decode(ToolResult.self, forKey: .toolResult))
        case .permissionAsked:
            self = .permissionAsked(try container.decode(PermissionRequest.self, forKey: .permissionRequest))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .stateChanged(state):
            try container.encode(TypeKey.stateChanged, forKey: .type)
            try container.encode(state, forKey: .state)
        case let .sessionCreated(sessionID):
            try container.encode(TypeKey.sessionCreated, forKey: .type)
            try container.encode(sessionID, forKey: .sessionID)
        case let .turnStarted(handle):
            try container.encode(TypeKey.turnStarted, forKey: .type)
            try container.encode(handle, forKey: .handle)
        case let .turnCompleted(result):
            try container.encode(TypeKey.turnCompleted, forKey: .type)
            try container.encode(result, forKey: .result)
        case let .turnFailed(failure):
            try container.encode(TypeKey.turnFailed, forKey: .type)
            try container.encode(failure, forKey: .failure)
        case let .toolCallCompleted(call):
            try container.encode(TypeKey.toolCallCompleted, forKey: .type)
            try container.encode(call, forKey: .toolCall)
        case let .toolResult(result):
            try container.encode(TypeKey.toolResult, forKey: .type)
            try container.encode(result, forKey: .toolResult)
        case let .permissionAsked(request):
            try container.encode(TypeKey.permissionAsked, forKey: .type)
            try container.encode(request, forKey: .permissionRequest)
        }
    }
}
