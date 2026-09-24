import Foundation

/// 跨平台文件系统默认适配器
public final class PlatformFileAdapter: PlatformFileProtocol, Sendable {
    public init() {}
}

/// 跨平台网络默认适配器
public final class PlatformNetworkAdapter: PlatformNetworkProtocol, Sendable {
    public init() {}

    public func resolve(host: String) throws -> [PlatformSocketAddress] {
        [PlatformSocketAddress(ipAddress: "127.0.0.1", port: 0)]
    }

    public func connectTCP(host: String, port: Int, timeoutSeconds: Double) async throws -> PlatformStreamConnection {
        struct DefaultStreamConnection: PlatformStreamConnection {
            func read(maxBytes: Int) async throws -> Data { Data() }
            func write(_ data: Data) async throws {}
            func close() {}
        }
        return DefaultStreamConnection()
    }

    public func interfaceAddresses() -> [String] {
        ["127.0.0.1"]
    }
}

/// 跨平台 IPC 默认适配器
public final class PlatformIPCAdapter: PlatformIPCProtocol, Sendable {
    public init() {}

    public func spawnSocketPair() throws -> PlatformIPCChannelPair {
        #if os(Windows)
        return PlatformIPCChannelPair(
            channelA: PlatformPipeHandle(rawHandle: 0),
            channelB: PlatformPipeHandle(rawHandle: 0)
        )
        #else
        var fds: [Int32] = [0, 0]
        #if canImport(Darwin)
        let rc = Darwin.pipe(&fds)
        #elseif canImport(Glibc)
        let rc = Glibc.pipe(&fds)
        #else
        let rc = -1
        #endif
        guard rc == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return PlatformIPCChannelPair(
            channelA: PlatformPipeHandle(fileDescriptor: fds[0]),
            channelB: PlatformPipeHandle(fileDescriptor: fds[1])
        )
        #endif
    }
}

/// 跨平台异步 I/O 默认适配器
public final class PlatformAsyncIOAdapter: PlatformAsyncIOProtocol, Sendable {
    public init() {}
}
