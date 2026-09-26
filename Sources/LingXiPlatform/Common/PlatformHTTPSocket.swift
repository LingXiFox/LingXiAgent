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
typealias HTTPSocket = SOCKET
typealias HTTPSocketLen = Int32
let kHTTPInvalidSocket: HTTPSocket = INVALID_SOCKET
private let kHTTPShutdownBoth: Int32 = SD_BOTH
#else
typealias HTTPSocket = Int32
typealias HTTPSocketLen = socklen_t
let kHTTPInvalidSocket: HTTPSocket = -1
private let kHTTPShutdownBoth: Int32 = Int32(SHUT_RDWR)
#endif

/// Outcome of a bounded wait for a socket to become readable or writable.
enum HTTPSocketReadiness {
    case ready
    case timedOut
    case failed
}

/// The socket calls this server needs, kept in one place so the request handling code
/// never branches on a platform again.
///
/// The `poll` constants are spelled as raw values: glibc imports `POLLIN` as `Int32` in one
/// toolchain and as an enum in another, and each spelling breaks the other (see the history
/// of `AsyncLineReader`).
enum PlatformHTTPSocket {
    private static let pollIn: Int16 = 0x0001
    private static let pollOut: Int16 = 0x0004
    private static let pollNval: Int16 = 0x0020

    /// Bind Winsock to the calling thread. POSIX platforms have nothing to do here.
    /// Every thread this server creates touches sockets, so each one calls it on entry.
    static func beginThread() -> Bool {
        #if os(Windows) || canImport(WinSDK)
        var data = WSADATA()
        return WSAStartup(WORD(0x0202), &data) == 0
        #else
        return true
        #endif
    }

    static func endThread() {
        #if os(Windows) || canImport(WinSDK)
        WSACleanup()
        #endif
    }

    /// Open an IPv4 listener on `host`, and report the port actually bound.
    ///
    /// Unlike the OAuth loopback server this deliberately has no ephemeral fallback: a
    /// browser front end is bookmarked by port, so silently answering on another one is
    /// worse than failing to start.
    static func makeListeningSocket(host: String, port: UInt16, backlog: Int32) throws -> (HTTPSocket, UInt16) {
        #if canImport(Darwin)
        let sockType = SOCK_STREAM
        #elseif canImport(Glibc)
        let sockType = Int32(SOCK_STREAM.rawValue)
        #elseif os(Windows) || canImport(WinSDK)
        let sockType = SOCK_STREAM
        #else
        throw CoreError(code: .transport, message: "HTTP server sockets are unavailable on this platform")
        #endif

        #if canImport(Darwin) || canImport(Glibc) || os(Windows) || canImport(WinSDK)
        let sock = socket(AF_INET, sockType, 0)
        guard sock != kHTTPInvalidSocket else {
            throw CoreError(code: .transport, message: "Failed to allocate socket for HTTP server")
        }

        var reuse: Int32 = 1
        #if os(Windows) || canImport(WinSDK)
        let reuseResult = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR,
                                     withUnsafePointer(to: &reuse) {
                                         $0.withMemoryRebound(to: CChar.self, capacity: 1) { $0 }
                                     }, HTTPSocketLen(MemoryLayout<Int32>.size))
        #else
        let reuseResult = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, HTTPSocketLen(MemoryLayout<Int32>.size))
        #endif
        guard reuseResult == 0 else {
            closeSocket(sock)
            throw CoreError(code: .transport, message: "Failed to configure HTTP listener: \(lastError())")
        }

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr(host)
        #elseif os(Windows) || canImport(WinSDK)
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_addr.S_un.S_addr = inet_addr(host)
        #else
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr(host)
        #endif
        address.sin_port = port.bigEndian

        // inet_addr yields INADDR_NONE for anything that is not a dotted-quad IPv4 literal.
        let unresolvedHost: UInt32 = 0xFFFF_FFFF
        #if os(Windows) || canImport(WinSDK)
        let hostAddress = address.sin_addr.S_un.S_addr
        #else
        let hostAddress = address.sin_addr.s_addr
        #endif
        guard hostAddress != unresolvedHost || host == "255.255.255.255" else {
            closeSocket(sock)
            throw CoreError(code: .transport, message: "HTTP server host must be an IPv4 literal, got '\(host)'")
        }

        var bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, HTTPSocketLen(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0, port != 0 {
            bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, HTTPSocketLen(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bindResult == 0 else {
            let detail = lastError()
            closeSocket(sock)
            throw CoreError(code: .transport, message: "Failed to bind HTTP listener on \(host):\(port): \(detail)")
        }

        guard listen(sock, backlog) == 0 else {
            let detail = lastError()
            closeSocket(sock)
            throw CoreError(code: .transport, message: "Failed to listen on HTTP socket: \(detail)")
        }

        var assigned = sockaddr_in()
        var length = HTTPSocketLen(MemoryLayout<sockaddr_in>.size)
        let probed = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
        }
        guard probed == 0 else {
            closeSocket(sock)
            throw CoreError(code: .transport, message: "Failed to read the bound HTTP port")
        }
        return (sock, UInt16(bigEndian: assigned.sin_port))
        #else
        throw CoreError(code: .transport, message: "HTTP server sockets are unavailable on this platform")
        #endif
    }

    /// Accept one connection, or nil when the listener is closed or the wait expired.
    static func acceptConnection(_ listener: HTTPSocket) -> (socket: HTTPSocket, peer: String, local: String)? {
        var peerAddress = sockaddr_in()
        var length = HTTPSocketLen(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &peerAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
        }
        guard client != kHTTPInvalidSocket else { return nil }
        var localAddress = sockaddr_in()
        var localLength = HTTPSocketLen(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &localAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(client, $0, &localLength) }
        }
        return (client, dottedQuad(peerAddress), dottedQuad(localAddress))
    }

    /// SSE frames must leave immediately; Nagle would coalesce them into the next write.
    static func setNoDelay(_ sock: HTTPSocket) {
        var enable: Int32 = 1
        #if os(Windows) || canImport(WinSDK)
        _ = setsockopt(sock, IPPROTO_TCP, TCP_NODELAY,
                       withUnsafePointer(to: &enable) {
                           $0.withMemoryRebound(to: CChar.self, capacity: 1) { $0 }
                       }, HTTPSocketLen(MemoryLayout<Int32>.size))
        #else
        _ = setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &enable, HTTPSocketLen(MemoryLayout<Int32>.size))
        #endif
    }

    /// Stop SIGPIPE without touching process-global signal state: Darwin has a per-socket
    /// option and Linux a per-send flag, so the rest of the app keeps its own handlers.
    static func suppressSigPipe(_ sock: HTTPSocket) {
        #if canImport(Darwin)
        var enable: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &enable, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    static func sendFlags() -> Int32 {
        #if canImport(Glibc)
        return Int32(MSG_NOSIGNAL)
        #else
        return 0
        #endif
    }

    static func waitReadable(_ sock: HTTPSocket, timeoutMs: Int32) -> HTTPSocketReadiness {
        #if os(Windows) || canImport(WinSDK)
        var descriptors = fd_set()
        descriptors.fd_count = 1
        withUnsafeMutablePointer(to: &descriptors.fd_array) { pointer in
            pointer.withMemoryRebound(to: SOCKET.self, capacity: 1) { $0.pointee = sock }
        }
        var timeout = timeval()
        timeout.tv_sec = timeoutMs / 1000
        timeout.tv_usec = (timeoutMs % 1000) * 1000
        let result = select(0, &descriptors, nil, nil, &timeout)
        if result == 0 { return .timedOut }
        if result == SOCKET_ERROR { return .failed }
        return .ready
        #else
        var descriptor = pollfd(fd: sock, events: pollIn, revents: 0)
        let result = poll(&descriptor, 1, timeoutMs)
        if result == 0 { return .timedOut }
        if result < 0 {
            if lastError() == EINTR { return .timedOut }
            return .failed
        }
        if descriptor.revents & pollNval != 0 { return .failed }
        // HUP/ERR still count as ready: the caller's read reports the real cause.
        return .ready
        #endif
    }

    static func waitWritable(_ sock: HTTPSocket, timeoutMs: Int32) -> HTTPSocketReadiness {
        #if os(Windows) || canImport(WinSDK)
        var descriptors = fd_set()
        descriptors.fd_count = 1
        withUnsafeMutablePointer(to: &descriptors.fd_array) { pointer in
            pointer.withMemoryRebound(to: SOCKET.self, capacity: 1) { $0.pointee = sock }
        }
        var timeout = timeval()
        timeout.tv_sec = timeoutMs / 1000
        timeout.tv_usec = (timeoutMs % 1000) * 1000
        let result = select(0, nil, &descriptors, nil, &timeout)
        if result == 0 { return .timedOut }
        if result == SOCKET_ERROR { return .failed }
        return .ready
        #else
        var descriptor = pollfd(fd: sock, events: pollOut, revents: 0)
        let result = poll(&descriptor, 1, timeoutMs)
        if result == 0 { return .timedOut }
        if result < 0 {
            if lastError() == EINTR { return .timedOut }
            return .failed
        }
        return descriptor.revents & pollNval == 0 ? .ready : .failed
        #endif
    }

    /// Read at most `count` bytes; nil means the peer is gone or the descriptor broke.
    static func receive(_ sock: HTTPSocket, maxBytes: Int) -> Data? {
        var storage = [UInt8](repeating: 0, count: maxBytes)
        let received: Int = storage.withUnsafeMutableBytes { pointer in
            guard let base = pointer.baseAddress else { return -1 }
            #if os(Windows) || canImport(WinSDK)
            return Int(recv(sock, base.bindMemory(to: CChar.self, capacity: maxBytes), Int32(maxBytes), 0))
            #else
            return recv(sock, base, maxBytes, 0)
            #endif
        }
        if received > 0 { return Data(storage[0..<received]) }
        if received == 0 { return nil }
        let failure = lastError()
        if failure == EAGAIN || failure == EWOULDBLOCK || failure == EINTR { return Data() }
        return nil
    }

    /// Whether the peer went away while we were busy writing.
    ///
    /// `poll` with no wait comes first: readability on an idle SSE connection means the peer
    /// has either sent something or closed, and both need looking at. Only then does the peek
    /// ask which, so a healthy connection costs one syscall.
    static func peerGone(_ sock: HTTPSocket) -> Bool {
        switch waitReadable(sock, timeoutMs: 0) {
        case .timedOut: return false
        case .failed: return true
        case .ready: break
        }
        var byte: UInt8 = 0
        #if os(Windows) || canImport(WinSDK)
        let flags: Int32 = Int32(MSG_PEEK) | Int32(MSG_NONBLOCK)
        #else
        let flags: Int32 = Int32(MSG_PEEK) | Int32(MSG_DONTWAIT)
        #endif
        let peeked: Int = withUnsafeMutablePointer(to: &byte) { pointer in
            #if os(Windows) || canImport(WinSDK)
            return Int(recv(sock, pointer.withMemoryRebound(to: CChar.self, capacity: 1) { $0 }, 1, flags))
            #else
            return Int(recv(sock, pointer, 1, flags))
            #endif
        }
        if peeked > 0 { return false }
        if peeked == 0 { return true }
        let failure = lastError()
        if failure == EAGAIN || failure == EWOULDBLOCK || failure == EINTR { return false }
        return true
    }

    /// Write everything, retrying short writes. False means the peer is gone.
    static func sendAll(_ sock: HTTPSocket, _ data: Data) -> Bool {
        if data.isEmpty { return true }
        let flags = sendFlags()
        return data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            let total = bytes.count
            while offset < total {
                let cursor = base.advanced(by: offset)
                let written: Int
                #if os(Windows) || canImport(WinSDK)
                written = Int(send(sock, cursor.bindMemory(to: CChar.self, capacity: total - offset),
                                   Int32(total - offset), flags))
                #else
                written = send(sock, cursor, total - offset, flags)
                #endif
                if written > 0 {
                    offset += written
                    continue
                }
                let failure = lastError()
                if failure == EINTR { continue }
                if failure == EAGAIN || failure == EWOULDBLOCK {
                    if waitWritable(sock, timeoutMs: 5_000) == .ready { continue }
                    return false
                }
                return false // EPIPE / ECONNRESET and friends: the peer is gone.
            }
            return true
        }
    }

    /// Make a blocked peer wake up. Only the owning thread closes a connection socket,
    /// so `stop()` reaches for `shutdown` rather than `close` -- closing an fd another
    /// thread is about to `poll` can hand it a recycled descriptor.
    static func shutdownForClose(_ sock: HTTPSocket) {
        _ = shutdown(sock, kHTTPShutdownBoth)
    }

    static func closeSocket(_ sock: HTTPSocket) {
        #if os(Windows) || canImport(WinSDK)
        closesocket(sock)
        #elseif canImport(Darwin)
        _ = Darwin.close(sock)
        #elseif canImport(Glibc)
        _ = Glibc.close(sock)
        #else
        _ = close(sock)
        #endif
    }

    static func lastError() -> Int32 {
        #if os(Windows) || canImport(WinSDK)
        return WSAGetLastError()
        #else
        return errno
        #endif
    }

    /// Dotted quad straight out of the address bytes, which are already in network order.
    static func dottedQuad(_ address: sockaddr_in) -> String {
        var copy = address
        #if os(Windows) || canImport(WinSDK)
        let bytes: [UInt8] = withUnsafeBytes(of: &copy.sin_addr.S_un) { Array($0.prefix(4)) }
        #else
        let bytes: [UInt8] = withUnsafeBytes(of: &copy.sin_addr) { Array($0.prefix(4)) }
        #endif
        guard bytes.count == 4 else { return "0.0.0.0" }
        return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
    }
}
