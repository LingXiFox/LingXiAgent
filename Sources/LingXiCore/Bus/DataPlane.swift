import Foundation
import LingXiProtocol

/// Streaming DMA 数据面。
/// Chunk 由独立 pump 任务产生，不经过控制面命令与 Event 总线；
/// 控制面只负责"打开通道"，之后数据直接流向客户端。
public actor DataPlane {
    private var pumps: [StreamID: Task<Void, Never>] = [:]
    private var agentSinks: [StreamID: AsyncThrowingStream<StreamChunk, Error>.Continuation] = [:]
    private var toolOutputContinuations: [UUID: AsyncStream<ToolOutputChunk>.Continuation] = [:]

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
        agentSinks[stream.id] = sink
        return (stream, sink)
    }

    public func trackAgent(_ task: Task<Void, Never>, streamID: StreamID) {
        pumps[streamID] = task
    }

    public func finishAgentStream(_ streamID: StreamID) {
        pumps.removeValue(forKey: streamID)
        agentSinks.removeValue(forKey: streamID)?.finish()
    }

    public func closeAll() {
        for pump in pumps.values { pump.cancel() }
        pumps.removeAll()
        agentSinks.values.forEach { $0.finish() }
        agentSinks.removeAll()
        toolOutputContinuations.values.forEach { $0.finish() }
        toolOutputContinuations.removeAll()
    }

    /// Tool stdout/stderr 的独立事件通道，绝不复用 CoreEvent。
    public func toolOutputEvents() -> AsyncStream<ToolOutputChunk> {
        AsyncStream { continuation in
            let key = UUID()
            toolOutputContinuations[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeToolOutputContinuation(key) }
            }
        }
    }

    public func emit(_ chunk: ToolOutputChunk) {
        toolOutputContinuations.values.forEach { $0.yield(chunk) }
    }

    private func makeStream() -> (OpenedStream, AsyncThrowingStream<StreamChunk, Error>.Continuation) {
        let id = StreamID(UUID().uuidString)
        var continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation!
        let chunks = AsyncThrowingStream { continuation = $0 }
        return (OpenedStream(id: id, chunks: chunks), continuation!)
    }

    private func removeToolOutputContinuation(_ key: UUID) {
        toolOutputContinuations.removeValue(forKey: key)
    }
}
