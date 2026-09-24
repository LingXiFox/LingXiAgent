import Foundation

public struct PlatformSocketAddress: Sendable, Equatable {
    public let ipAddress: String
    public let port: UInt16

    public init(ipAddress: String, port: UInt16) {
        self.ipAddress = ipAddress
        self.port = port
    }
}

public protocol PlatformStreamConnection: Sendable {
    func read(maxBytes: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close()
}

/// 跨平台网络连接、解析与端口探活协议
public protocol PlatformNetworkProtocol: Sendable {
    func resolve(host: String) throws -> [PlatformSocketAddress]
    func connectTCP(host: String, port: Int, timeoutSeconds: Double) async throws -> PlatformStreamConnection
    func listenTCP(port: Int) throws -> PlatformLoopbackServer
    func interfaceAddresses() -> [String]
    func isPortReachable(host: String, port: Int, timeoutSeconds: Double) async -> Bool
    func defaultGateway() -> String?
}

public extension PlatformNetworkProtocol {
    func listenTCP(port: Int) throws -> PlatformLoopbackServer {
        try PlatformLoopbackServer(preferredPort: UInt16(port))
    }

    func isPortReachable(host: String, port: Int, timeoutSeconds: Double) async -> Bool {
        do {
            let conn = try await connectTCP(host: host, port: port, timeoutSeconds: timeoutSeconds)
            conn.close()
            return true
        } catch {
            return false
        }
    }

    func defaultGateway() -> String? {
        nil
    }
}
