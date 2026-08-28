/// 控制面命令的响应。
public enum CoreResponse: Sendable, Equatable {
    case pong
    case info(CoreInfo)
    case state(CoreState)
    case streamOpened(StreamID)
    case error(CoreError)
}

/// 协议层错误。
public struct CoreError: Sendable, Equatable, Error {
    public enum Code: String, Sendable {
        case unsupportedCommand
        case notReady
        case streamNotFound
        case transport
    }

    public let code: Code
    public let message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}
