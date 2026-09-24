import Foundation

public enum MessageFramerError: Error, Sendable, Equatable {
    case headerTooLarge
    case invalidHeader
    case streamClosed
    case framingFailed
}

/// 消息分帧协议。
/// 负责在无界的原始字节流与结构化的独立消息帧（Frame Payload）之间进行序列化与边界拆解。
public protocol MessageFramer: Sendable {
    /// 对待发送的消息体进行分帧打包（加上头部或尾部分隔符）
    func frame(payload: Data) -> Data

    /// 从原始 Stdio 传输层读取下一个完整消息帧的有效载荷（Payload）
    func readNextPayload(from transport: StdioTransport) throws -> Data?
}

/// 基于 LSP 规范的标准 Content-Length 头部协议分帧器。
/// 格式: Content-Length: <count>\r\n\r\n<payload>
public struct LSPContentLengthFramer: MessageFramer {
    private let maxHeaderLength: Int

    public init(maxHeaderLength: Int = 16 * 1024) {
        self.maxHeaderLength = maxHeaderLength
    }

    public func frame(payload: Data) -> Data {
        let header = "Content-Length: \(payload.count)\r\n\r\n"
        var data = Data(header.utf8)
        data.append(payload)
        return data
    }

    public func readNextPayload(from transport: StdioTransport) throws -> Data? {
        var headerData = Data()
        let delimiter = Data("\r\n\r\n".utf8)

        while headerData.suffix(4) != delimiter {
            guard let byte = try transport.readByte() else {
                if headerData.isEmpty { return nil }
                throw MessageFramerError.streamClosed
            }
            headerData.append(byte)
            if headerData.count > maxHeaderLength {
                throw MessageFramerError.headerTooLarge
            }
        }

        let headerText = String(decoding: headerData, as: UTF8.self)
        guard let line = headerText.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
              let length = Int(line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) else {
            throw MessageFramerError.invalidHeader
        }

        return try transport.readExact(count: length)
    }
}

/// 基于行分隔（Newline Delimited / JSONL）的流式分帧器。
/// 格式: <payload>\n
public struct LineDelimitedJSONFramer: MessageFramer {
    private let maxLineLength: Int

    public init(maxLineLength: Int = 10 * 1024 * 1024) {
        self.maxLineLength = maxLineLength
    }

    public func frame(payload: Data) -> Data {
        var data = payload
        if data.last != UInt8(ascii: "\n") {
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }

    public func readNextPayload(from transport: StdioTransport) throws -> Data? {
        try transport.readLine(maxBytes: maxLineLength)
    }
}
