/// 控制面命令的响应。
public enum CoreResponse: Sendable, Equatable {
    case pong
    case info(CoreInfo)
    case state(CoreState)
    case streamOpened(StreamID)
    case providerStatus(ProviderStatus)
    case sessionCreated(SessionInfo)
    case sessionList([SessionInfo])
    case sessionDetail(SessionSnapshot)
    case permissionReplyAccepted(PermissionID)
    case error(CoreError)
}

/// 协议层错误。
public struct CoreError: Sendable, Equatable, Error {
    public enum Code: String, Sendable {
        case unsupportedCommand
        case notReady
        case streamNotFound
        case sessionNotFound
        /// 同一 Session 已有进行中的 turn（Session Lane 串行保护）。
        case turnAlreadyRunning
        case transport
        /// Provider HTTP / API 错误（Provider Error）。
        case provider
        /// 推理已开始但流中途失败（Model Stream Error）。
        case modelStream
        case toolNotFound
        case toolArgumentInvalid
        case toolExecutionFailed
        case permissionDenied
        case permissionCancelled
        case workspaceViolation
        case agentStepLimitReached
    }

    public let code: Code
    public let message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}
