import Foundation

/// SSE 行缓冲解码器。
/// 网络字节按任意大小的块喂入，按完整行输出；
/// 不假设一个 TCP chunk 对应一个 SSE event，处理 \n 与 \r\n。
public struct SSEDecoder {
    private var buffer: [UInt8] = []

    public init() {}

    /// 喂入任意网络块，返回其中已完整到达的行（不含行终止符）。
    public mutating func feed(_ data: Data) -> [String] {
        data.withUnsafeBytes { raw in
            buffer.append(contentsOf: raw.bindMemory(to: UInt8.self))
        }
        return extractLines()
    }

    /// 流结束时调用：输出残留的最后一行（SSE 允许末行无换行）。
    public mutating func flushPending() -> [String] {
        guard !buffer.isEmpty else { return [] }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        return [line]
    }

    private mutating func extractLines() -> [String] {
        var lines: [String] = []
        var lineStart = buffer.startIndex
        var index = buffer.startIndex

        while index < buffer.endIndex {
            guard buffer[index] == UInt8(ascii: "\n") else {
                index += 1
                continue
            }
            var end = index
            if end > lineStart, buffer[end - 1] == UInt8(ascii: "\r") {
                end -= 1
            }
            lines.append(String(decoding: buffer[lineStart..<end], as: UTF8.self))
            index += 1
            lineStart = index
        }
        buffer.removeFirst(lineStart)
        return lines
    }
}
