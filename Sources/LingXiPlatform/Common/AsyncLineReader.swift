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
        // glibc imports POLLIN as Int32 in one toolchain and as an enum in another, and both spellings
        // break the other. The value is 0x0001 on every Linux ABI, so name it instead of importing it.
        let pollIn: Int16 = 0x0001
        var waiting = pollfd(fd: fd, events: pollIn, revents: 0)
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

    /// Runs `polledRead` on a thread of its own until end of stream or stop, and hands back the
    /// stopper.
    ///
    /// Deliberately not a `Task`: a loop that spends its life inside `poll` holds whatever executor
    /// runs it, and on a two-core CI runner four idle readers are enough to starve the cooperative
    /// pool -- the work that would resume the caller never gets scheduled, which is a wedge with a
    /// different cause than the one `poll` just fixed. The census of such a chunk shows
    /// `wchan=poll_schedule_timeout` with the 200 ms timeout still in the register dump.
    private static func startPollingReader(
        fd: Int32,
        bufferSize: Int,
        onChunk: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void {
        let flag = StopFlag()
        let thread = Thread {
            while !flag.stopped {
                guard let chunk = polledRead(fd: fd, bufferSize: bufferSize) else { break }
                if !chunk.isEmpty { onChunk(chunk) }
            }
            onEnd()
        }
        thread.start()
        return { flag.stop() }
    }

    /// `Task.isCancelled` means nothing to a Foundation thread, so stopping needs a flag of its own.
    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _stopped = false

        var stopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _stopped
        }

        func stop() {
            lock.lock()
            _stopped = true
            lock.unlock()
        }
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
                #if os(Linux)
                let stop = startPollingReader(
                    fd: handle.fileDescriptor,
                    bufferSize: bufferSize,
                    onChunk: { continuation.yield($0) },
                    onEnd: { continuation.finish() }
                )
                continuation.onTermination = { _ in stop() }
                #else
                let task = Task.detached {
                    do {
                        while !Task.isCancelled {
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
                #endif
            } else {
                #if !os(Windows) && !os(Linux)
                handle.readabilityHandler = { h in
                    let data = h.availableData
                    if data.isEmpty {
                        h.readabilityHandler = nil
                        continuation.finish()
                    } else {
                        continuation.yield(data)
                    }
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
                #if os(Linux)
                // Consume dataChunks, whose reader is already a thread of its own. This task only
                // ever suspends, so an idle stream holds no cooperative-pool worker -- which is the
                // point, because the poll loop must not be sitting on one.
                let source = dataChunks(from: handle, bufferSize: bufferSize)
                let task = Task.detached {
                    var leftover = Data()
                    let newline = UInt8(ascii: "\n")
                    let cr = UInt8(ascii: "\r")
                    do {
                        for try await chunk in source {
                            leftover.append(chunk)
                            while let newlineIndex = leftover.firstIndex(of: newline) {
                                var lineData = leftover.subdata(in: leftover.startIndex..<newlineIndex)
                                if lineData.last == cr {
                                    lineData.removeLast()
                                }
                                continuation.yield(String(decoding: lineData, as: UTF8.self))
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
                #else
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
                    #if os(Windows)
                    try? handle.close()
                    #endif
                }
                #endif
            } else {
                #if !os(Windows) && !os(Linux)
                final class LineAccumulator: @unchecked Sendable {
                    var leftover = Data()
                }
                let accumulator = LineAccumulator()
                let newline = UInt8(ascii: "\n")
                let cr = UInt8(ascii: "\r")

                handle.readabilityHandler = { h in
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
