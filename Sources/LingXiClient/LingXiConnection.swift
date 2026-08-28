import Foundation
import LingXiProtocol

/// 客户端到 Core 的一条连接。
/// 实现方决定 Transport（进程内 / stdio 子进程 / 未来 IPC、远程），
/// 业务协议不变。
public protocol LingXiConnection: Sendable {
    /// 控制面：发送命令并等待响应。
    func send(_ command: ClientCommand) async throws -> CoreResponse

    /// 数据面：打开内置测试流。
    func openTestStream() async throws -> AsyncThrowingStream<StreamChunk, Error>

    /// 数据面：在 Session 中发起一轮对话，返回 Streaming DMA 通道。
    func sendMessage(sessionID: SessionID, content: String) async throws -> AsyncThrowingStream<StreamChunk, Error>

    /// 控制面：订阅语义事件。
    func events() async -> AsyncStream<CoreEvent>

    func close() async
}
