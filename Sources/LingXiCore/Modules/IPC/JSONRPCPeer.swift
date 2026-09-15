import Foundation

public enum JSONRPCError: Error, Sendable, Equatable {
    case connectionClosed
    case invalidMessage
    case remoteError(code: Int, message: String)
    case requestFailed(String)
}

/// JSON-RPC 2.0 端点对等端（Peer）。
/// 组合底层的 Stdio 传输流与指定的消息分帧器，提供结构化的 RPC 调用与通知能力。
public final class JSONRPCPeer: @unchecked Sendable {
    private let transport: StdioTransport
    private let framer: any MessageFramer
    private let lock = NSLock()

    public init(transport: StdioTransport, framer: any MessageFramer) {
        self.transport = transport
        self.framer = framer
    }

    /// 启动连接
    public func start() throws {
        try transport.connect()
    }

    /// 关闭连接与子进程
    public func stop() {
        transport.close()
    }

    /// 发送单向通知（Notification，不带 ID）
    public func notify(method: String, parameters: Data? = nil) throws {
        let paramObj: Any = {
            if let parameters, let obj = try? JSONSerialization.jsonObject(with: parameters) {
                return obj
            }
            return [String: Any]()
        }()
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": paramObj
        ]
        let payload = try JSONSerialization.data(withJSONObject: message)
        let framed = framer.frame(payload: payload)
        try transport.write(framed)
    }

    /// 同步发送请求并轮询等待对应 ID 的响应（单线程阻塞式模型，用于 LSP 与同步 Host）
    public func request(id: Int, method: String, parameters: Data? = nil) throws -> Data {
        let paramObj: Any = {
            if let parameters, let obj = try? JSONSerialization.jsonObject(with: parameters) {
                return obj
            }
            return [String: Any]()
        }()
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": paramObj
        ]
        let payload = try JSONSerialization.data(withJSONObject: message)
        let framed = framer.frame(payload: payload)

        lock.lock()
        defer { lock.unlock() }

        try transport.write(framed)

        while let responsePayload = try framer.readNextPayload(from: transport) {
            guard let object = try? JSONSerialization.jsonObject(with: responsePayload) as? [String: Any] else {
                continue
            }
            // 匹配请求 ID
            guard let respID = (object["id"] as? NSNumber)?.intValue, respID == id else {
                continue
            }

            if let errorObj = object["error"] as? [String: Any] {
                let code = (errorObj["code"] as? NSNumber)?.intValue ?? -1
                let msg = (errorObj["message"] as? String) ?? "Unknown remote error"
                throw JSONRPCError.remoteError(code: code, message: msg)
            }

            guard let result = object["result"] else {
                return Data("null".utf8)
            }
            return try JSONSerialization.data(withJSONObject: result)
        }

        throw JSONRPCError.connectionClosed
    }

    /// 读取下一个原始消息体（供异步事件监听循环消费）
    public func readNextRawMessage() throws -> Data? {
        try framer.readNextPayload(from: transport)
    }
}
