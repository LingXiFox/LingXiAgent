/// 客户端发给 Core 的控制面命令。
public enum ClientCommand: Sendable, Equatable {
    case ping
    case getInfo
    case getState
    case openTestStream
}

extension ClientCommand {
    /// 命令种类，用于控制面路由与 wire 编码。
    public enum Kind: String, Codable, Sendable {
        case ping
        case getInfo
        case getState
        case openTestStream
    }

    public var kind: Kind {
        switch self {
        case .ping: .ping
        case .getInfo: .getInfo
        case .getState: .getState
        case .openTestStream: .openTestStream
        }
    }

    /// 数据面命令：由连接层路由到 Streaming DMA 通路，而非控制面。
    public var isDataPlane: Bool {
        self == .openTestStream
    }
}
