import Foundation
import LingXiProtocol

/// 进程内连接：把任意 CoreEndpoint 包装为 LingXiConnection。
/// 用于测试与未来同进程嵌入场景。
public struct InProcessConnection: LingXiConnection {
    private let endpoint: any CoreEndpoint

    public init(endpoint: any CoreEndpoint) {
        self.endpoint = endpoint
    }

    public func send(_ command: ClientCommand) async throws -> CoreResponse {
        // 数据面命令不走控制面 send。
        guard !command.isDataPlane else {
            return .error(CoreError(
                code: .unsupportedCommand,
                message: "openTestStream 属于数据面，请使用 openTestStream()"
            ))
        }
        return try await endpoint.handle(command)
    }

    public func openTestStream() async throws -> AsyncThrowingStream<StreamChunk, Error> {
        try await endpoint.openTestStream().chunks
    }

    public func events() async -> AsyncStream<CoreEvent> {
        await endpoint.events()
    }

    public func close() async {}
}
