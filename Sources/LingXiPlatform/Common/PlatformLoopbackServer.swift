import Foundation
import LingXiProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows) || canImport(WinSDK)
import WinSDK
#endif

#if os(Windows) || canImport(WinSDK)
private typealias PlatformSocket = SOCKET
private let kInvalidSocket: SOCKET = INVALID_SOCKET
#else
private typealias PlatformSocket = Int32
private let kInvalidSocket: Int32 = -1
#endif

/// 跨平台本地回环回调服务器 (PlatformLoopbackServer)。
/// 负责在本地分配短暂或首选端口并监听 OAuth/SSO 授权重定向，
/// 将底层 POSIX / 系统 Socket 细节完全隔离在 LingXiPlatform 内，
/// 具备三平台兼容、poll 超时控制与安全的资源生命周期释放。
public final class PlatformLoopbackServer: @unchecked Sendable {
    private var serverSock: PlatformSocket = kInvalidSocket
    public private(set) var port: UInt16 = 0
    private var isClosed = false
    private let lock = NSLock()

    public init(preferredPort: UInt16 = 54321) throws {
        #if canImport(Darwin)
        let sockType = SOCK_STREAM
        #elseif canImport(Glibc)
        let sockType = Int32(SOCK_STREAM.rawValue)
        #elseif os(Windows) || canImport(WinSDK)
        var wsaData = WSADATA()
        _ = WSAStartup(WORD(0x0202), &wsaData)
        let sockType = SOCK_STREAM
        #endif

        #if canImport(Darwin) || canImport(Glibc) || os(Windows) || canImport(WinSDK)
        let sock: PlatformSocket = socket(AF_INET, sockType, 0)
        #if os(Windows) || canImport(WinSDK)
        guard sock != INVALID_SOCKET else {
            throw CoreError(code: .transport, message: "Failed to allocate socket for loopback server")
        }
        #else
        guard sock >= 0 else {
            throw CoreError(code: .transport, message: "Failed to allocate socket for loopback server")
        }
        #endif

        var reuse: Int32 = 1
        #if os(Windows) || canImport(WinSDK)
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, withUnsafePointer(to: &reuse) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { $0 } }, socklen_t(MemoryLayout<Int32>.size))
        #else
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var addr = sockaddr_in()
        #if os(Windows) || canImport(WinSDK)
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        addr.sin_addr.S_un.S_addr = inet_addr("127.0.0.1")
        #else
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        #endif
        addr.sin_port = preferredPort.bigEndian

        var bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindResult != 0 {
            // Port in use, bind to ephemeral port (0)
            addr.sin_port = 0
            bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard bindResult == 0 else {
            Self.closeSocket(sock)
            throw CoreError(code: .transport, message: "Failed to bind loopback socket")
        }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var actualAddr = sockaddr_in()
        withUnsafeMutablePointer(to: &actualAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(sock, $0, &len)
            }
        }
        self.port = UInt16(bigEndian: actualAddr.sin_port)
        self.serverSock = sock

        listen(sock, 1)
        #else
        throw CoreError(code: .transport, message: "Loopback socket is not supported on this platform")
        #endif
    }

    deinit {
        closeServer()
    }

    public func closeServer() {
        lock.lock()
        defer { lock.unlock() }
        #if os(Windows) || canImport(WinSDK)
        if !isClosed && serverSock != INVALID_SOCKET {
            Self.closeSocket(serverSock)
            serverSock = INVALID_SOCKET
            isClosed = true
        }
        #else
        if !isClosed && serverSock >= 0 {
            Self.closeSocket(serverSock)
            serverSock = -1
            isClosed = true
        }
        #endif
    }

    private static func closeSocket(_ sock: PlatformSocket) {
        #if canImport(Darwin) || canImport(Glibc)
        close(sock)
        #elseif os(Windows) || canImport(WinSDK)
        closesocket(sock)
        #endif
    }

    public func waitForCallback(expectedState: String, timeoutSeconds: Double = 180.0) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CoreError(code: .commandTimedOut, message: "Callback server deallocated"))
                    return
                }

                self.lock.lock()
                let sock = self.serverSock
                self.lock.unlock()

                #if os(Windows) || canImport(WinSDK)
                guard sock != INVALID_SOCKET else {
                    continuation.resume(throwing: CoreError(code: .commandTimedOut, message: "Socket already closed"))
                    return
                }
                #else
                guard sock >= 0 else {
                    continuation.resume(throwing: CoreError(code: .commandTimedOut, message: "Socket already closed"))
                    return
                }
                #endif

                #if canImport(Darwin) || canImport(Glibc)
                // 使用 poll 实施严格超时控制，防止无限阻塞
                var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
                let timeoutMs = Int32(max(1.0, timeoutSeconds * 1000.0))
                let pollRes = poll(&pfd, 1, timeoutMs)

                if pollRes == 0 {
                    continuation.resume(throwing: CoreError(code: .commandTimedOut, message: "OAuth callback timed out after \(timeoutSeconds) seconds"))
                    return
                } else if pollRes < 0 {
                    continuation.resume(throwing: CoreError(code: .transport, message: "Poll failed on loopback socket: \(errno)"))
                    return
                }

                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientSock = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(sock, $0, &clientLen)
                    }
                }

                guard clientSock >= 0 else {
                    continuation.resume(throwing: CoreError(code: .transport, message: "Failed to accept loopback connection"))
                    return
                }

                var buf = [CChar](repeating: 0, count: 4096)
                let bytesRead = read(clientSock, &buf, 4095)
                guard bytesRead > 0 else {
                    close(clientSock)
                    continuation.resume(throwing: CoreError(code: .transport, message: "Empty loopback request"))
                    return
                }

                let uint8Bytes = buf.prefix(bytesRead).map { UInt8(bitPattern: $0) }
                let reqStr = String(decoding: uint8Bytes, as: UTF8.self)
                guard let firstLine = reqStr.components(separatedBy: "\r\n").first,
                      let urlPart = firstLine.components(separatedBy: " ").dropFirst().first,
                      let comp = URLComponents(string: "http://127.0.0.1\(urlPart)") else {
                    close(clientSock)
                    continuation.resume(throwing: CoreError(code: .toolArgumentInvalid, message: "Invalid callback HTTP request"))
                    return
                }

                let state = comp.queryItems?.first(where: { $0.name == "state" })?.value
                let code = comp.queryItems?.first(where: { $0.name == "code" })?.value
                let error = comp.queryItems?.first(where: { $0.name == "error" })?.value

                let responseHTML = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Connection: close\r
                \r
                <!DOCTYPE html>
                <html>
                <head><title>LingXiAgent · 授权成功</title><meta charset="utf-8"></head>
                <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; background: #0f172a; color: #f8fafc;">
                    <div style="text-align: center; padding: 2rem; border-radius: 12px; background: #1e293b; box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1); max-width: 400px;">
                        <h2 style="color: #38bdf8; margin-bottom: 0.5rem;">授权成功！</h2>
                        <p style="color: #94a3b8; font-size: 0.875rem;">LingXiAgent 已成功接收授权凭证，您可以关闭此浏览器窗口并返回终端。</p>
                    </div>
                </body>
                </html>
                """

                let errorHTML = """
                HTTP/1.1 400 Bad Request\r
                Content-Type: text/html; charset=utf-8\r
                Connection: close\r
                \r
                <!DOCTYPE html>
                <html>
                <head><title>LingXiAgent · 授权失败</title><meta charset="utf-8"></head>
                <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; background: #0f172a; color: #f8fafc;">
                    <div style="text-align: center; padding: 2rem; border-radius: 12px; background: #1e293b; box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1); max-width: 400px;">
                        <h2 style="color: #f87171; margin-bottom: 0.5rem;">授权失败</h2>
                        <p style="color: #94a3b8; font-size: 0.875rem;">状态校验不一致或服务提供方拒绝了授权请求。</p>
                    </div>
                </body>
                </html>
                """

                if let error = error {
                    _ = errorHTML.withCString { ptr in
                        write(clientSock, ptr, errorHTML.utf8.count)
                    }
                    close(clientSock)
                    continuation.resume(throwing: CoreError(code: .permissionDenied, message: "OAuth callback returned error: \(error)"))
                    return
                }

                guard state == expectedState else {
                    _ = errorHTML.withCString { ptr in
                        write(clientSock, ptr, errorHTML.utf8.count)
                    }
                    close(clientSock)
                    continuation.resume(throwing: CoreError(code: .permissionDenied, message: "OAuth callback state mismatch (CSRF protection)"))
                    return
                }

                guard let authCode = code, !authCode.isEmpty else {
                    _ = errorHTML.withCString { ptr in
                        write(clientSock, ptr, errorHTML.utf8.count)
                    }
                    close(clientSock)
                    continuation.resume(throwing: CoreError(code: .toolArgumentInvalid, message: "Missing code parameter in OAuth callback"))
                    return
                }

                _ = responseHTML.withCString { ptr in
                    write(clientSock, ptr, responseHTML.utf8.count)
                }
                close(clientSock)
                continuation.resume(returning: authCode)
                #else
                continuation.resume(throwing: CoreError(code: .transport, message: "Unsupported platform for loopback callback"))
                #endif
            }
        }
    }
}
