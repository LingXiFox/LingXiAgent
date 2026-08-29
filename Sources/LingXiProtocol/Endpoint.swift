/// 一次打开 Stream 的结果。
public struct OpenedStream: Sendable {
    public let id: StreamID
    public let chunks: AsyncThrowingStream<StreamChunk, Error>

    public init(id: StreamID, chunks: AsyncThrowingStream<StreamChunk, Error>) {
        self.id = id
        self.chunks = chunks
    }
}

/// Core 对外暴露的端点契约。
/// LingXiCore 实现它；LingXiClient 的连接层消费它。
/// 未来 SwiftUI GUI 与远程客户端都通过同一契约访问 Core。
public protocol CoreEndpoint: Sendable {
    /// 控制面：执行一条命令，返回一个响应。
    func handle(_ command: ClientCommand) async throws -> CoreResponse

    /// 数据面：按数据面命令（openTestStream / chat）打开 Streaming DMA 通道。
    /// Chunk 不经过控制面事件，直接从该独立通道流出。
    func openDataStream(_ command: ClientCommand) async throws -> OpenedStream

    /// 数据面：订阅高频 Tool stdout/stderr；不经 CoreEvent 广播。
    func toolOutputEvents() async -> AsyncStream<ToolOutputChunk>

    /// 控制面：订阅语义事件（如状态变化、模型流结果）。
    func events() async -> AsyncStream<CoreEvent>
}
