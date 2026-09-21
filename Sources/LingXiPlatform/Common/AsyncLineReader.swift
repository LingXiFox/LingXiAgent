import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows) || canImport(WinSDK)
import WinSDK
#if canImport(ucrt)
import ucrt
#endif
#endif

/// 跨平台异步行解码流 (AsyncLineReader)
/// 替代 Linux 下不可用的 `FileHandle.bytes.lines`，支持 Darwin、Linux 与 Windows 全平台。
/// 采用高效定长缓冲区与换行符扫描，按块异步读取并流式输出完整文本行。
public enum AsyncLineReader: Sendable {

    #if os(Windows) || canImport(WinSDK)
    @inline(__always)
    private static func getWindowsHandle(_ handle: FileHandle) -> HANDLE? {
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return nil }
        let osf = _get_osfhandle(fd)
        guard osf != -1 else { return nil }
        return HANDLE(bitPattern: osf)
    }
    #endif

    /// 从 FileHandle 异步流式读取 Data 数据块，支持 Darwin、Linux 与 Windows 全平台
    public static func dataChunks(from handle: FileHandle, bufferSize: Int = 4096) -> AsyncThrowingStream<Data, any Error> {
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
                    do {
                        while !Task.isCancelled {
                            #if os(Windows) || canImport(WinSDK)
                            if let hPipe = getWindowsHandle(handle) {
                                var bytesAvail: DWORD = 0
                                if PeekNamedPipe(hPipe, nil, 0, nil, &bytesAvail, nil) {
                                    if bytesAvail == 0 {
                                        try await Task.sleep(nanoseconds: 10_000_000)
                                        continue
                                    }
                                } else {
                                    let err = GetLastError()
                                    if err == DWORD(ERROR_BROKEN_PIPE) || err == DWORD(ERROR_HANDLE_EOF) || err == DWORD(ERROR_PIPE_NOT_CONNECTED) {
                                        break // EOF
                                    }
                                }
                            }
                            #endif

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
                }
            } else {
                #if !os(Windows)
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
                            #if os(Windows) || canImport(WinSDK)
                            if let hPipe = getWindowsHandle(handle) {
                                var bytesAvail: DWORD = 0
                                if PeekNamedPipe(hPipe, nil, 0, nil, &bytesAvail, nil) {
                                    if bytesAvail == 0 {
                                        try await Task.sleep(nanoseconds: 10_000_000)
                                        continue
                                    }
                                } else {
                                    let err = GetLastError()
                                    if err == DWORD(ERROR_BROKEN_PIPE) || err == DWORD(ERROR_HANDLE_EOF) || err == DWORD(ERROR_PIPE_NOT_CONNECTED) {
                                        break // EOF
                                    }
                                }
                            }
                            #endif

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
