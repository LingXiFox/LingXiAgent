import LingXiProtocol

/// 控制面命令路由。
/// ponytail: 单路由表；未来按多总线架构拆分（模型高速总线 / 核心服务总线）时，
/// 把各模块注册进各自的 bus，本类型保持 dispatch 契约不变。
public actor CommandBus {
    public typealias Handler = @Sendable (ClientCommand) async throws -> CoreResponse

    private var routes: [ClientCommand.Kind: Handler] = [:]

    public init() {}

    public func add(_ kind: ClientCommand.Kind, handler: @escaping Handler) {
        routes[kind] = handler
    }

    public func removeAll() {
        routes.removeAll()
    }

    public func dispatch(_ command: ClientCommand) async throws -> CoreResponse {
        guard let handler = routes[command.kind] else {
            return .error(CoreError(
                code: .unsupportedCommand,
                message: "控制面未注册命令: \(command.kind.rawValue)"
            ))
        }
        return try await handler(command)
    }
}
