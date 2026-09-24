import Foundation

public struct PlatformAsyncIOCompletion<T: Sendable>: Sendable {
    public let value: Result<T, Error>
    public let durationSeconds: Double

    public init(value: Result<T, Error>, durationSeconds: Double) {
        self.value = value
        self.durationSeconds = durationSeconds
    }
}

/// 跨平台异步非阻塞 I/O 契约（Windows Overlapped I/O / POSIX Non-blocking）
public protocol PlatformAsyncIOProtocol: Sendable {
    func submit<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) -> AsyncStream<PlatformAsyncIOCompletion<T>>
    func readAsync(handle: PlatformPipeHandle, into buffer: inout [UInt8], minBytes: Int, deadlineSeconds: Double?) async throws -> Int
    func writeAsync(handle: PlatformPipeHandle, data: Data) async throws -> Int
    func cancel(handle: PlatformPipeHandle) throws
    func close(handle: PlatformPipeHandle, force: Bool) throws
}

public extension PlatformAsyncIOProtocol {
    func submit<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) -> AsyncStream<PlatformAsyncIOCompletion<T>> {
        AsyncStream { continuation in
            Task {
                let start = Date()
                do {
                    let result = try await operation()
                    let elapsed = Date().timeIntervalSince(start)
                    continuation.yield(PlatformAsyncIOCompletion(value: .success(result), durationSeconds: elapsed))
                } catch {
                    let elapsed = Date().timeIntervalSince(start)
                    continuation.yield(PlatformAsyncIOCompletion(value: .failure(error), durationSeconds: elapsed))
                }
                continuation.finish()
            }
        }
    }

    func readAsync(handle: PlatformPipeHandle, into buffer: inout [UInt8], minBytes: Int, deadlineSeconds: Double?) async throws -> Int {
        #if !os(Windows)
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return 0 }
        let bytesRead = buffer.withUnsafeMutableBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            #if canImport(Darwin)
            return Darwin.read(fd, base, ptr.count)
            #elseif canImport(Glibc)
            return Glibc.read(fd, base, ptr.count)
            #else
            return 0
            #endif
        }
        return max(0, bytesRead)
        #else
        return 0
        #endif
    }

    func writeAsync(handle: PlatformPipeHandle, data: Data) async throws -> Int {
        #if !os(Windows)
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return 0 }
        let bytesWritten = data.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            #if canImport(Darwin)
            return Darwin.write(fd, base, ptr.count)
            #elseif canImport(Glibc)
            return Glibc.write(fd, base, ptr.count)
            #else
            return 0
            #endif
        }
        return max(0, bytesWritten)
        #else
        return 0
        #endif
    }

    func cancel(handle: PlatformPipeHandle) throws {}
    func close(handle: PlatformPipeHandle, force: Bool) throws {
        #if !os(Windows)
        #if canImport(Darwin)
        _ = Darwin.close(handle.fileDescriptor)
        #elseif canImport(Glibc)
        _ = Glibc.close(handle.fileDescriptor)
        #endif
        #endif
    }
}
