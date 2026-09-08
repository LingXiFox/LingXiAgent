import Foundation
import LingXiProtocol

/// ClientTransport：客户端传输层抽象接口。
/// 直接遵循并提供 LingXiProtocolService 冻结契约，支持 InProcessTransport、LocalIPCTransport 与 RemoteTransport。
public protocol ClientTransport: LingXiProtocolService, Sendable {
    var connectionState: ConnectionState { get async }
    var stateStream: AsyncStream<ConnectionState> { get }
    var authorizationContext: ContentAuthorizationContext { get }

    func connect() async throws
    func disconnect() async
}
