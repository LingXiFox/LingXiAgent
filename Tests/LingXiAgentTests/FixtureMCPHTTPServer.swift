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

private enum FixtureMCPError: Error {
    case socketFailed
    case setsockoptFailed
    case bindFailed
    case listenFailed
    case getsocknameFailed
}

private func closeSocketHandle(_ sock: SocketHandle) {
    #if os(Windows) || canImport(WinSDK)
    _ = closesocket(sock)
    #else
    _ = close(sock)
    #endif
}

/// Test-only localhost Streamable HTTP MCP fixture. It never binds outside loopback.
final class FixtureMCPHTTPServer: @unchecked Sendable {
    let endpoint: URL
    private let listener: SocketHandle
    private let lock = NSLock()
    private let acceptQueue = DispatchQueue(label: "LingXiAgent.FixtureMCPHTTPServer.accept.\(UUID().uuidString)")
    private let lifecycle = DispatchGroup()
    private var running = true
    private var state = "created"
    private var calls: [(toolName: String, key: String?)] = []
    private var activeClients: Set<SocketHandle> = []
    private var requestCount = 0
    private var responseStartedCount = 0
    private var responseCompletedCount = 0

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
        guard fd != INVALID_SOCKET else { throw FixtureMCPError.socketFailed }
        #else
        guard fd >= 0 else { throw FixtureMCPError.socketFailed }
        #endif

        var reuse: Int32 = 1
        #if os(Windows) || canImport(WinSDK)
        let optRes = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, withUnsafePointer(to: &reuse) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { $0 } }, SockLen(MemoryLayout<Int32>.size))
        #else
        let optRes = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, SockLen(MemoryLayout<Int32>.size))
        #endif
        guard optRes == 0 else {
            closeSocketHandle(fd)
            throw FixtureMCPError.setsockoptFailed
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
            closeSocketHandle(fd)
            throw FixtureMCPError.bindFailed
        }

        var assigned = sockaddr_in()
        var length = SockLen(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &assigned, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }) == 0 else {
            closeSocketHandle(fd)
            throw FixtureMCPError.getsocknameFailed
        }

        listener = fd
        endpoint = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: assigned.sin_port))/mcp")!
        state = "listening"
        lifecycle.enter()
        acceptQueue.async { [weak self] in
            defer { self?.lifecycle.leave() }
            self?.acceptLoop()
        }
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        let shouldClose = running
        running = false
        state = "stopping"
        let clients = activeClients
        lock.unlock()
        guard shouldClose else { return }
        _ = shutdown(listener, kShutdownBoth)
        closeSocketHandle(listener)
        for client in clients {
            _ = shutdown(client, kShutdownBoth)
            closeSocketHandle(client)
        }
        lifecycle.wait()
        lock.lock(); state = "stopped"; lock.unlock()
    }

    func callCount(toolName: String, key: String? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.toolName == toolName && (key == nil || $0.key == key) }.count
    }

    func diagnostics() -> String {
        lock.lock()
        defer { lock.unlock() }
        return "fixtureID=\(ObjectIdentifier(self).hashValue) endpoint=\(endpoint.host ?? "loopback"):\(endpoint.port ?? 0) state=\(state) ready=\(state == "listening") requestCount=\(requestCount) responseStarted=\(responseStartedCount) responseCompleted=\(responseCompletedCount) activeClients=\(activeClients.count) calls=\(calls.count)"
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
            lock.lock(); activeClients.insert(client); lock.unlock()
            lifecycle.enter()
            Thread.detachNewThread { [weak self] in
                defer { self?.lifecycle.leave() }
                self?.handle(client)
            }
        }
    }

    private var active: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func handle(_ client: SocketHandle) {
        defer {
            lock.lock(); activeClients.remove(client); lock.unlock()
            closeSocketHandle(client)
        }
        guard let request = readRequest(client) else { return }
        lock.lock(); requestCount += 1; state = "handling"; lock.unlock()
        let response = respond(to: request)
        lock.lock(); responseStartedCount += 1; lock.unlock()
        write(response, to: client)
        lock.lock(); responseCompletedCount += 1; if running { state = "listening" }; lock.unlock()
    }

    private func readRequest(_ client: SocketHandle) -> (method: String, path: String, headers: [String: String], body: Data)? {
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
            guard data.count <= 128 * 1024 else { return nil }
        }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)), let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { return nil }
        let rows = header.components(separatedBy: "\r\n")
        let first = rows.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for row in rows.dropFirst() {
            let pair = row.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { headers[pair[0].lowercased()] = pair[1] }
        }
        let expected = Int(headers["content-length"] ?? "0") ?? 0
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
        return (String(first[0]), String(first[1]), headers, body)
    }

    private func respond(to request: (method: String, path: String, headers: [String: String], body: Data)) -> (Int, String, Data) {
        guard request.path == "/mcp" else { return (404, "text/plain", Data("not found".utf8)) }
        if let origin = request.headers["origin"], !origin.hasPrefix("http://127.0.0.1") { return (403, "text/plain", Data("forbidden origin".utf8)) }
        if request.method == "GET" { return (204, "application/json", Data()) }
        guard request.method == "POST", request.headers["content-type"]?.contains("application/json") == true, request.headers["accept"]?.contains("application/json") == true, request.headers["accept"]?.contains("text/event-stream") == true, request.headers["mcp-protocol-version"] == MCPProtocolVersionNegotiator.modern else { return (400, "text/plain", Data("bad request".utf8)) }
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any], object["jsonrpc"] as? String == "2.0", let method = object["method"] as? String, let params = object["params"] as? [String: Any], request.headers["mcp-method"] == method else { return (400, "text/plain", Data("bad json-rpc".utf8)) }
        let id = object["id"] ?? "id"
        if method == "tools/list" { return json(id: id, result: toolList(cursor: params["cursor"] as? String)) }
        guard method == "tools/call", let name = params["name"] as? String, request.headers["mcp-name"] == name else { return (400, "text/plain", Data("routing mismatch".utf8)) }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        lock.lock(); calls.append((name, arguments["key"] as? String)); lock.unlock()
        switch name {
        case "lookup_anchor":
            let key = arguments["key"] as? String
            return json(id: id, result: content(key == "phase12" || key == "full-core-stack-v1" ? "MCPAnchor-729" : "missing"))
        case "echo":
            let value = String(describing: arguments["value"] ?? "")
            let payload = jsonData(id: id, result: content(value))
            return (200, "text/event-stream", Data("data: \(String(decoding: payload, as: UTF8.self))\n\ndata: [DONE]\n\n".utf8))
        case "large_result": return json(id: id, result: content(String(repeating: "x", count: 32_000)))
        case "slow_tool": Thread.sleep(forTimeInterval: 1); return json(id: id, result: content("slow"))
        case "error_tool": return json(id: id, result: ["isError": true, "content": [["type": "text", "text": "fixture error"]]])
        default: return (500, "text/plain", Data("unknown tool".utf8))
        }
    }

    private func toolList(cursor: String?) -> [String: Any] {
        let anchor: [String: Any] = ["name": "lookup_anchor", "description": "Retrieve the phase12 or full-core-stack-v1 deterministic test anchor by key.", "inputSchema": ["type": "object", "properties": ["key": ["type": "string"]], "required": ["key"]]]
        let echo: [String: Any] = ["name": "echo", "description": "Echo text.", "inputSchema": ["type": "object", "properties": ["value": ["type": "string"]]]]
        let large: [String: Any] = ["name": "large_result", "description": "Return a large result.", "inputSchema": ["type": "object", "properties": [:]]]
        let slow: [String: Any] = ["name": "slow_tool", "description": "Return after delay.", "inputSchema": ["type": "object", "properties": [:]]]
        let error: [String: Any] = ["name": "error_tool", "description": "Return an error.", "inputSchema": ["type": "object", "properties": [:]]]
        return cursor == nil ? ["tools": [anchor, echo], "nextCursor": "page-2"] : ["tools": [large, slow, error], "nextCursor": ""]
    }

    private func content(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]]] }
    private func json(id: Any, result: [String: Any]) -> (Int, String, Data) { (200, "application/json", jsonData(id: id, result: result)) }
    private func jsonData(id: Any, result: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result], options: [.sortedKeys])) ?? Data() }
    private func write(_ response: (Int, String, Data), to socket: SocketHandle) {
        let reason = response.0 == 200 ? "OK" : response.0 == 204 ? "No Content" : response.0 == 400 ? "Bad Request" : response.0 == 403 ? "Forbidden" : response.0 == 404 ? "Not Found" : "Internal Server Error"
        var data = Data("HTTP/1.1 \(response.0) \(reason)\r\nContent-Type: \(response.1)\r\nContent-Length: \(response.2.count)\r\nConnection: close\r\n\r\n".utf8); data.append(response.2)
        data.withUnsafeBytes { raw in
            guard let start = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                #if os(Windows) || canImport(WinSDK)
                let chunkLen = Int32(min(data.count - offset, Int(Int32.max)))
                let ccharPtr = start.advanced(by: offset).bindMemory(to: CChar.self, capacity: Int(chunkLen))
                let written = send(socket, ccharPtr, chunkLen, 0)
                #else
                let chunkLen = data.count - offset
                let written = send(socket, start.advanced(by: offset), chunkLen, 0)
                #endif
                if written > 0 { offset += Int(written) }
                else if written < 0, errno == EINTR { continue }
                else { return }
            }
        }
    }
}
