import Darwin
import Foundation
@testable import LingXiCore

/// Test-only localhost Provider fixture. First request emits two subagent spawn
/// function calls; every later request emits a plain text completion. Loopback only.
final class FixtureProviderHTTPServer: @unchecked Sendable {
    let endpoint: URL
    private let listener: Int32
    private let lock = NSLock()
    private var running = true
    private var requestCount = 0
    private var acceptTask: Task<Void, Never>?

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        var reuse: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw POSIXError(.EINVAL) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        var assigned = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &assigned, { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        listener = fd
        endpoint = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: assigned.sin_port))/responses")!
        acceptTask = Task.detached { [weak self] in self?.acceptLoop() }
    }

    deinit { stop() }

    func stop() {
        lock.lock(); let shouldClose = running; running = false; lock.unlock()
        guard shouldClose else { return }
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        acceptTask?.cancel()
    }

    private func acceptLoop() {
        while active {
            var address = sockaddr(); var length = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listener, &address, &length)
            guard client >= 0 else { continue }
            Task.detached { [weak self] in self?.handle(client) }
        }
    }

    private var active: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func handle(_ client: Int32) {
        defer { Darwin.close(client) }
        guard readHeaders(client) != nil else { return }
        lock.lock(); requestCount += 1; let count = requestCount; lock.unlock()
        let body = count == 1 ? Self.spawnEvents : Self.textEvents
        var data = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(Data(body.utf8))
        let sent = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return send(client, base, data.count, 0)
        }
        _ = sent
    }

    private func readHeaders(_ client: Int32) -> Data? {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
            guard data.count <= 1024 * 1024 else { return nil }
        }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)), let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { return nil }
        let expected = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }.flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        var body = Data(data[boundary.upperBound...])
        while body.count < expected {
            let count = recv(client, &buffer, buffer.count, 0)
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
