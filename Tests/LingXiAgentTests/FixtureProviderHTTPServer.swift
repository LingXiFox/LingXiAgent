#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows) || canImport(WinSDK)
import WinSDK
#endif
import Foundation
@testable import LingXiCore

#if os(Windows) || canImport(WinSDK)
private typealias SocketHandle = SOCKET
private typealias SockLen = Int32
private let kInvalidSocket: SOCKET = INVALID_SOCKET
private let kShutdownBoth: Int32 = SD_BOTH
#else
private typealias SocketHandle = Int32
private typealias SockLen = socklen_t
private let kInvalidSocket: Int32 = -1
private let kShutdownBoth: Int32 = Int32(SHUT_RDWR)
#endif

/// Test-only localhost Provider fixture. First request emits two subagent spawn
/// function calls; every later request emits a plain text completion. Loopback only.
final class FixtureProviderHTTPServer: @unchecked Sendable {
    let endpoint: URL
    private let listener: SocketHandle
    private let lock = NSLock()
    private var running = true
    private var requestCount = 0
    private var acceptTask: Task<Void, Never>?

    init() throws {
        #if os(Windows) || canImport(WinSDK)
        var wsaData = WSADATA()
        _ = WSAStartup(WORD(0x0202), &wsaData)
        let sockType = SOCK_STREAM
        #elseif canImport(Glibc)
        let sockType = Int32(SOCK_STREAM.rawValue)
        #else
        let sockType = SOCK_STREAM
        #endif

        let fd: SocketHandle = socket(AF_INET, sockType, 0)
        #if os(Windows) || canImport(WinSDK)
        guard fd != INVALID_SOCKET else { throw POSIXError(.ENFILE) }
        #else
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        #endif

        var reuse: Int32 = 1
        #if os(Windows) || canImport(WinSDK)
        let optRes = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, withUnsafePointer(to: &reuse) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { $0 } }, SockLen(MemoryLayout<Int32>.size))
        #else
        let optRes = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, SockLen(MemoryLayout<Int32>.size))
        #endif
        guard optRes == 0 else {
            Self.closeSocket(fd)
            throw POSIXError(.EINVAL)
        }

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        #elseif os(Windows) || canImport(WinSDK)
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_addr.S_un.S_addr = inet_addr("127.0.0.1")
        #else
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        #endif
        address.sin_port = 0

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, SockLen(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            Self.closeSocket(fd)
            throw POSIXError(.EADDRINUSE)
        }

        var assigned = sockaddr_in()
        var length = SockLen(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &assigned, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }) == 0 else {
            Self.closeSocket(fd)
            throw POSIXError(.EADDRNOTAVAIL)
        }

        listener = fd
        endpoint = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: assigned.sin_port))/responses")!
        acceptTask = Task.detached { [weak self] in self?.acceptLoop() }
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        let shouldClose = running
        running = false
        lock.unlock()
        guard shouldClose else { return }
        _ = shutdown(listener, kShutdownBoth)
        Self.closeSocket(listener)
        acceptTask?.cancel()
    }

    private static func closeSocket(_ sock: SocketHandle) {
        #if os(Windows) || canImport(WinSDK)
        closesocket(sock)
        #else
        close(sock)
        #endif
    }

    private func acceptLoop() {
        while active {
            var address = sockaddr()
            var length = SockLen(MemoryLayout<sockaddr>.size)
            let client: SocketHandle = accept(listener, &address, &length)
            #if os(Windows) || canImport(WinSDK)
            guard client != INVALID_SOCKET else { continue }
            #else
            guard client >= 0 else { continue }
            #endif
            Task.detached { [weak self] in self?.handle(client) }
        }
    }

    private var active: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func handle(_ client: SocketHandle) {
        defer { Self.closeSocket(client) }
        guard readHeaders(client) != nil else { return }
        lock.lock()
        requestCount += 1
        let count = requestCount
        lock.unlock()

        let body = count == 1 ? Self.spawnEvents : Self.textEvents
        var data = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(Data(body.utf8))
        let sent = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            #if os(Windows) || canImport(WinSDK)
            let ccharPtr = base.bindMemory(to: CChar.self, capacity: data.count)
            return Int(send(client, ccharPtr, Int32(data.count), 0))
            #else
            return send(client, base, data.count, 0)
            #endif
        }
        _ = sent
    }

    private func readHeaders(_ client: SocketHandle) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            #if os(Windows) || canImport(WinSDK)
            let count = buffer.withUnsafeMutableBytes { bufPtr -> Int in
                guard let base = bufPtr.baseAddress else { return -1 }
                let ccharPtr = base.bindMemory(to: CChar.self, capacity: buffer.count)
                return Int(recv(client, ccharPtr, Int32(buffer.count), 0))
            }
            #else
            let count = recv(client, &buffer, buffer.count, 0)
            #endif
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
            guard data.count <= 1024 * 1024 else { return nil }
        }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { return nil }
        let expected = header.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        var body = Data(data[boundary.upperBound...])
        while body.count < expected {
            #if os(Windows) || canImport(WinSDK)
            let count = buffer.withUnsafeMutableBytes { bufPtr -> Int in
                guard let base = bufPtr.baseAddress else { return -1 }
                let ccharPtr = base.bindMemory(to: CChar.self, capacity: buffer.count)
                return Int(recv(client, ccharPtr, Int32(buffer.count), 0))
            }
            #else
            let count = recv(client, &buffer, buffer.count, 0)
            #endif
            guard count > 0 else { return nil }
            body.append(buffer, count: count)
        }
        return body
    }

    private static let textEvents =
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"fixture-ok\"}\n\n" +
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"

    private static let spawnEvents =
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fx-1\",\"call_id\":\"call-foo\",\"name\":\"subagent\",\"arguments\":\"\"}}\n\n" +
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fx-2\",\"call_id\":\"call-bar\",\"name\":\"subagent\",\"arguments\":\"\"}}\n\n" +
        "data: {\"type\":\"response.function_call_arguments.done\",\"call_id\":\"call-foo\",\"name\":\"subagent\",\"arguments\":\"{\\\"action\\\":\\\"spawn\\\",\\\"task\\\":\\\"child-foo\\\",\\\"title\\\":\\\"Foo\\\"}\"}\n\n" +
        "data: {\"type\":\"response.function_call_arguments.done\",\"call_id\":\"call-bar\",\"name\":\"subagent\",\"arguments\":\"{\\\"action\\\":\\\"spawn\\\",\\\"task\\\":\\\"child-bar\\\",\\\"title\\\":\\\"Bar\\\"}\"}\n\n" +
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
}
