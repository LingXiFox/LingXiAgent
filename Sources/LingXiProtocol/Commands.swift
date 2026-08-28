/// 客户端发给 Core 的控制面命令。
public enum ClientCommand: Sendable, Equatable {
    case ping
    case getInfo
    case getState
    case openTestStream
    case createSession
    case listSessions
    case getSession(sessionID: SessionID)
    case getProviderStatus
    case replyPermission(PermissionReply)
    case getContext(sessionID: SessionID)
    case getPerformance(sessionID: SessionID)
    case getPermissionConfiguration
    case setPermissionConfiguration(PermissionConfiguration)
    case getProjectCache
    /// 数据面命令：在 Session 中发起一轮对话。
    case sendMessage(sessionID: SessionID, content: String)
}

extension ClientCommand {
    /// 命令种类，用于控制面路由与 wire 编码。
    public enum Kind: String, Codable, Sendable {
        case ping
        case getInfo
        case getState
        case openTestStream
        case createSession
        case listSessions
        case getSession
        case getProviderStatus
        case replyPermission
        case getContext
        case getPerformance
        case getPermissionConfiguration
        case setPermissionConfiguration
        case getProjectCache
        case sendMessage
    }

    public var kind: Kind {
        switch self {
        case .ping: .ping
        case .getInfo: .getInfo
        case .getState: .getState
        case .openTestStream: .openTestStream
        case .createSession: .createSession
        case .listSessions: .listSessions
        case .getSession: .getSession
        case .getProviderStatus: .getProviderStatus
        case .replyPermission: .replyPermission
        case .getContext: .getContext
        case .getPerformance: .getPerformance
        case .getPermissionConfiguration: .getPermissionConfiguration
        case .setPermissionConfiguration: .setPermissionConfiguration
        case .getProjectCache: .getProjectCache
        case .sendMessage: .sendMessage
        }
    }

    /// 数据面命令：由连接层路由到 Streaming DMA 通路，而非控制面。
    public var isDataPlane: Bool {
        switch self {
        case .openTestStream, .sendMessage: true
        default: false
        }
    }
}
