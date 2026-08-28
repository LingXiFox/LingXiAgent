import Foundation
import LingXiProtocol

/// Streaming DMA 数据面。
/// Chunk 由独立 pump 任务产生，不经过控制面命令与 Event 总线；
/// 控制面只负责"打开通道"，之后数据直接流向客户端。
public actor DataPlane {
    private var pumps: [StreamID: Task<Void, Never>] = [:]

    public init() {}

    /// 打开内置测试流：逐块产出固定文本。
    public func openTestStream() -> OpenedStream {
        let (stream, sink) = makeStream()
        let id = stream.id

        let task = Task {
            let payload = ["Hello ", "LingXiAgent ", "Streaming ", "DMA"]
            for (index, text) in payload.enumerated() {
                if Task.isCancelled { break }
                sink.yield(StreamChunk(streamID: id, index: index, text: text, kind: .text))
                try? await Task.sleep(for: .milliseconds(120))
            }
            sink.finish()
        }
        pumps[id] = task

        return stream
    }

    /// 打开一条 Agent 驱动的流：返回通道与写入端。
    /// Agent 消费模型事件流后经此 sink 推送 chunk（DMA），结束时报控制面结果。
    public func openAgentStream() -> (stream: OpenedStream, sink: AsyncThrowingStream<StreamChunk, Error>.Continuation) {
        let (stream, sink) = makeStream()
        return (stream, sink)
    }

    public func closeAll() {
        for pump in pumps.values { pump.cancel() }
        pumps.removeAll()
    }

    private func makeStream() -> (OpenedStream, AsyncThrowingStream<StreamChunk, Error>.Continuation) {
        let id = StreamID(UUID().uuidString)
        var continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation!
        let chunks = AsyncThrowingStream { continuation = $0 }
        return (OpenedStream(id: id, chunks: chunks), continuation!)
    }
}
