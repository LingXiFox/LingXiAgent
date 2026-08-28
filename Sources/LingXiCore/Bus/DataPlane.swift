import Foundation
import LingXiProtocol

/// Streaming DMA 数据面。
/// Chunk 由独立 pump 任务产生，不经过控制面命令与 Event 总线；
/// 控制面只负责"打开通道"，之后数据直接流向客户端。
public actor DataPlane {
    private var pumps: [StreamID: Task<Void, Never>] = [:]

    public init() {}

    /// 打开测试流：逐块产出固定文本。
    public func openTestStream() -> OpenedStream {
        let id = StreamID(UUID().uuidString)
        var continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation!
        let chunks = AsyncThrowingStream { continuation = $0 }

        let task = Task {
            let payload = ["Hello ", "LingXiAgent ", "Streaming ", "DMA"]
            for (index, text) in payload.enumerated() {
                if Task.isCancelled { break }
                continuation.yield(StreamChunk(streamID: id, index: index, text: text))
                try? await Task.sleep(for: .milliseconds(120))
            }
            continuation.finish()
        }
        pumps[id] = task

        return OpenedStream(id: id, chunks: chunks)
    }

    public func closeAll() {
        for pump in pumps.values { pump.cancel() }
        pumps.removeAll()
    }
}
