import Foundation

/// 跨平台异步行解码流 (AsyncLineReader)
/// 替代 Linux 下不可用的 `FileHandle.bytes.lines`，支持 Darwin、Linux 与 Windows 全平台。
/// 采用高效定长缓冲区与换行符扫描，按块异步读取并流式输出完整文本行。
public enum AsyncLineReader: Sendable {
    /// 从 FileHandle 异步流式解码行
    public static func lines(from handle: FileHandle, bufferSize: Int = 4096) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            #if os(Windows)
            let useDirectRead = true
            #else
            var statBuf = stat()
            let isRegularFile = (fstat(handle.fileDescriptor, &statBuf) == 0) && ((statBuf.st_mode & S_IFMT) == S_IFREG)
            let useDirectRead = isRegularFile
            #endif

            if useDirectRead {
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
                                if lineData.last == cr {
                                    lineData.removeLast()
                                }
                                let line = String(decoding: lineData, as: UTF8.self)
                                continuation.yield(line)
                                leftover.removeSubrange(leftover.startIndex...newlineIndex)
                            }
                        }

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
            } else {
                #if !os(Windows)
                var leftover = Data()
                let newline = UInt8(ascii: "\n")
                let cr = UInt8(ascii: "\r")

                handle.readabilityHandler = { h in
                    let data = h.availableData
                    if data.isEmpty {
                        h.readabilityHandler = nil
                        if !leftover.isEmpty {
                            var lineData = leftover
                            if lineData.last == cr {
                                lineData.removeLast()
                            }
                            let line = String(decoding: lineData, as: UTF8.self)
                            if !line.isEmpty {
                                continuation.yield(line)
                            }
                            leftover.removeAll()
                        }
                        continuation.finish()
                        return
                    }

                    leftover.append(data)
                    while let newlineIndex = leftover.firstIndex(of: newline) {
                        var lineData = leftover.subdata(in: leftover.startIndex..<newlineIndex)
                        if lineData.last == cr {
                            lineData.removeLast()
                        }
                        let line = String(decoding: lineData, as: UTF8.self)
                        continuation.yield(line)
                        leftover.removeSubrange(leftover.startIndex...newlineIndex)
                    }
                }

                continuation.onTermination = { @Sendable _ in
                    handle.readabilityHandler = nil
                }
                #endif
            }
        }
    }
}
