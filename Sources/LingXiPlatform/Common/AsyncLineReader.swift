import Foundation

/// 跨平台异步行解码流 (AsyncLineReader)
/// 替代 Linux 下不可用的 `FileHandle.bytes.lines`，支持 Darwin、Linux 与 Windows 全平台。
/// 采用高效定长缓冲区与换行符扫描，按块异步读取并流式输出完整文本行。
public enum AsyncLineReader: Sendable {
    /// 从 FileHandle 异步流式解码行
    public static func lines(from handle: FileHandle, bufferSize: Int = 4096) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                var leftover = Data()
                let newline = UInt8(ascii: "\n")
                let cr = UInt8(ascii: "\r")

                do {
                    while !Task.isCancelled {
                        let chunk: Data
                        if #available(macOS 10.15.4, iOS 13.4, watchOS 6.2, tvOS 13.4, *) {
                            if let data = try handle.read(upToCount: bufferSize), !data.isEmpty {
                                chunk = data
                            } else {
                                break // EOF
                            }
                        } else {
                            let data = handle.readData(ofLength: bufferSize)
                            if data.isEmpty { break }
                            chunk = data
                        }

                        leftover.append(chunk)

                        while let newlineIndex = leftover.firstIndex(of: newline) {
                            var lineData = leftover.subdata(in: leftover.startIndex..<newlineIndex)
                            // 兼容剔除 Windows \r\n 中的 \r
                            if lineData.last == cr {
                                lineData.removeLast()
                            }
                            let line = String(decoding: lineData, as: UTF8.self)
                            continuation.yield(line)
                            leftover.removeSubrange(leftover.startIndex...newlineIndex)
                        }
                    }

                    // Flush residual line without trailing newline at EOF
                    if !leftover.isEmpty {
                        var lineData = leftover
                        if lineData.last == cr {
                            lineData.removeLast()
                        }
                        let line = String(decoding: lineData, as: UTF8.self)
                        if !line.isEmpty {
                            continuation.yield(line)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
