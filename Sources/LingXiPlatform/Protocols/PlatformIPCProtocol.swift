import Foundation

public struct PlatformIPCChannelPair: Sendable {
    public let channelA: PlatformPipeHandle
    public let channelB: PlatformPipeHandle

    public init(channelA: PlatformPipeHandle, channelB: PlatformPipeHandle) {
        self.channelA = channelA
        self.channelB = channelB
    }
}

/// 跨平台 IPC、命名管道与进程间通讯抽象
public protocol PlatformIPCProtocol: Sendable {
    func spawnSocketPair() throws -> PlatformIPCChannelPair
    func namedPipe(name: String) -> String
    func unixDomainSocket(path: String) -> String
    func deadline<R: Sendable>(_ seconds: Double, operation: @Sendable @escaping () async throws -> R) async throws -> R
    func handshake(transport: StdioTransport, expectedVersion: String) async throws -> Bool
}

public extension PlatformIPCProtocol {
    func namedPipe(name: String) -> String {
        #if os(Windows)
        return "\\\\.\\pipe\\\(name)"
        #else
        return "/tmp/lingxi-\(name).sock"
        #endif
    }

    func unixDomainSocket(path: String) -> String {
        #if os(Windows)
        let safeName = path.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        return "\\\\.\\pipe\\\(safeName)"
        #else
        return path
        #endif
    }

    func deadline<R: Sendable>(_ seconds: Double, operation: @Sendable @escaping () async throws -> R) async throws -> R {
        try await withThrowingTaskGroup(of: R.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func handshake(transport: StdioTransport, expectedVersion: String) async throws -> Bool {
        true
    }
}
