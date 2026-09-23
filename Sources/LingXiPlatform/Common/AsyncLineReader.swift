import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 跨平台异步行解码流 (AsyncLineReader)
/// 替代 Linux 下不可用的 `FileHandle.bytes.lines`，支持 Darwin、Linux 与 Windows 全平台。
/// 采用高效定长缓冲区与换行符扫描，按块异步读取并流式输出完整文本行。
public enum AsyncLineReader: Sendable {

    #if os(Linux)
    /// One poll-guarded read from a descriptor: nil at end of stream, empty data when nothing
    /// arrived within the wait, otherwise a chunk.
    ///
    /// `FileHandle.readabilityHandler` is a dispatch source, and a source created after the
    /// descriptor already became readable is never delivered on Linux -- so for a child that writes
    /// and exits before the reader attaches, both its last bytes and the EOF go unseen and every
    /// consumer awaiting the stream waits forever. `poll` reports readiness at the moment of the
    /// call, so nothing can be missed, and its timeout is what lets the reading task notice
    /// cancellation: a thread parked in a plain `read` cannot be interrupted by closing the
    /// descriptor, which is why this path does not block.
    private static func polledRead(fd: Int32, bufferSize: Int) -> Data? {
        var waiting = pollfd(fd: fd, events: Int16(POLLIN.rawValue), revents: 0)
        let ready = poll(&waiting, 1, 200)
        if ready == 0 { return Data() }
        if ready < 0 {
            if errno == EINTR { return Data() }
            return nil // POLLNVAL: the descriptor is already gone.
        }

        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let bytesRead = Glibc.read(fd, &buffer, bufferSize)
        if bytesRead > 0 { return Data(buffer[0..<bytesRead]) }
        if bytesRead == 0 { return nil }
        let err = errno
        if err == EAGAIN || err == EWOULDBLOCK || err == EINTR { return Data() }
        return nil
    }
    #endif

    /// 从 FileHandle 异步流式读取 Data 数据块，支持 Darwin、Linux 与 Windows 全平台
    public static func dataChunks(from handle: FileHandle, bufferSize: Int = 4096) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            #if os(Windows)
            let useDirectRead = true
            #elseif os(Linux)
            // Read from a task that can be cancelled rather than from a dispatch source, whose
            // already-delivered events Linux drops.
            let useDirectRead = true
            #else
            var statBuf = stat()
            let isRegularFile = (fstat(handle.fileDescriptor, &statBuf) == 0) && ((statBuf.st_mode & S_IFMT) == S_IFREG)
            let useDirectRead = isRegularFile
            #endif

            if useDirectRead {
                let task = Task.detached {
                    do {
                        while !Task.isCancelled {
                            #if os(Linux)
                            guard let chunk = polledRead(fd: handle.fileDescriptor, bufferSize: bufferSize) else {
                                break // EOF
                            }
                            if !chunk.isEmpty { continuation.yield(chunk) }
                            #else
                            if #available(macOS 10.15.4, iOS 13.4, watchOS 6.2, tvOS 13.4, *) {
                                if let chunk = try handle.read(upToCount: bufferSize), !chunk.isEmpty {
                                    continuation.yield(chunk)
                                } else {
                                    break // EOF
                                }
                            } else {
                                let chunk = handle.readData(ofLength: bufferSize)
                                if chunk.isEmpty { break }
                                continuation.yield(chunk)
                            }
                            #endif
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                    #if os(Windows)
                    try? handle.close()
                    #endif
                }
            } else {
                #if !os(Windows)
                handle.readabilityHandler = { h in
                    #if os(Linux)
                    var buffer = [UInt8](repeating: 0, count: bufferSize)
                    let bytesRead = Glibc.read(h.fileDescriptor, &buffer, bufferSize)
                    if bytesRead > 0 {
                        continuation.yield(Data(buffer[0..<bytesRead]))
                    } else if bytesRead == 0 {
                        h.readabilityHandler = nil
                        continuation.finish()
                    } else {
                        let err = errno
                        if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                            return
                        }
                        h.readabilityHandler = nil
                        continuation.finish()
                    }
                    #else
                    let data = h.availableData
                    if data.isEmpty {
                        h.readabilityHandler = nil
                        continuation.finish()
                    } else {
                        continuation.yield(data)
                    }
                    #endif
                }
                continuation.onTermination = { @Sendable _ in
                    handle.readabilityHandler = nil
                }
                #endif
            }
        }
    }

    /// 从 FileHandle 异步流式解码行
    public static func lines(from handle: FileHandle, bufferSize: Int = 4096) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            #if os(Windows)
            let useDirectRead = true
            #elseif os(Linux)
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
                            #if os(Linux)
                            guard let polled = polledRead(fd: handle.fileDescriptor, bufferSize: bufferSize) else {
                                break // EOF
                            }
                            chunk = polled
                            #else
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
                            #endif
                            if chunk.isEmpty { continue }

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
                    #if os(Windows)
                    try? handle.close()
                    #endif
                }
            } else {
                #if !os(Windows)
                final class LineAccumulator: @unchecked Sendable {
                    var leftover = Data()
                }
                let accumulator = LineAccumulator()
                let newline = UInt8(ascii: "\n")
                let cr = UInt8(ascii: "\r")

                handle.readabilityHandler = { h in
                    #if os(Linux)
                    var buffer = [UInt8](repeating: 0, count: bufferSize)
                    let bytesRead = Glibc.read(h.fileDescriptor, &buffer, bufferSize)
                    let data: Data
                    if bytesRead > 0 {
                        data = Data(buffer[0..<bytesRead])
                    } else if bytesRead == 0 {
                        h.readabilityHandler = nil
                        if !accumulator.leftover.isEmpty {
                            var lineData = accumulator.leftover
                            if lineData.last == cr {
                                lineData.removeLast()
                            }
                            let line = String(decoding: lineData, as: UTF8.self)
                            if !line.isEmpty {
                                continuation.yield(line)
                            }
                            accumulator.leftover.removeAll()
                        }
                        continuation.finish()
                        return
                    } else {
                        let err = errno
                        if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                            return
                        }
                        h.readabilityHandler = nil
                        continuation.finish()
                        return
                    }
                    #else
                    let data = h.availableData
                    if data.isEmpty {
                        h.readabilityHandler = nil
                        if !accumulator.leftover.isEmpty {
                            var lineData = accumulator.leftover
                            if lineData.last == cr {
                                lineData.removeLast()
                            }
                            let line = String(decoding: lineData, as: UTF8.self)
                            if !line.isEmpty {
                                continuation.yield(line)
                            }
                            accumulator.leftover.removeAll()
                        }
                        continuation.finish()
                        return
                    }
                    #endif

                    accumulator.leftover.append(data)
                    while let newlineIndex = accumulator.leftover.firstIndex(of: newline) {
                        var lineData = accumulator.leftover.subdata(in: accumulator.leftover.startIndex..<newlineIndex)
                        if lineData.last == cr {
                            lineData.removeLast()
                        }
                        let line = String(decoding: lineData, as: UTF8.self)
                        continuation.yield(line)
                        accumulator.leftover.removeSubrange(accumulator.leftover.startIndex...newlineIndex)
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
