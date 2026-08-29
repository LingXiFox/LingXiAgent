import Darwin
import Foundation
@testable import LingXiCore

/// Test-only localhost Streamable HTTP MCP fixture. It never binds outside loopback.
final class FixtureMCPHTTPServer: @unchecked Sendable {
    let endpoint: URL
    private let listener: Int32
    private let lock = NSLock()
    private var running = true
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
        endpoint = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: assigned.sin_port))/mcp")!
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
        guard let request = readRequest(client) else { return }
        let response = respond(to: request)
        write(response, to: client)
    }

    private func readRequest(_ client: Int32) -> (method: String, path: String, headers: [String: String], body: Data)? {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = recv(client, &buffer, buffer.count, 0)
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
            let count = recv(client, &buffer, buffer.count, 0)
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
        switch name {
        case "lookup_anchor": return json(id: id, result: content((arguments["key"] as? String) == "phase12" ? "MCPAnchor-729" : "missing"))
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
        let anchor: [String: Any] = ["name": "lookup_anchor", "description": "Retrieve a test anchor by key.", "inputSchema": ["type": "object", "properties": ["key": ["type": "string"]], "required": ["key"]]]
        let echo: [String: Any] = ["name": "echo", "description": "Echo text.", "inputSchema": ["type": "object", "properties": ["value": ["type": "string"]]]]
        let large: [String: Any] = ["name": "large_result", "description": "Return a large result.", "inputSchema": ["type": "object", "properties": [:]]]
        let slow: [String: Any] = ["name": "slow_tool", "description": "Return after delay.", "inputSchema": ["type": "object", "properties": [:]]]
        let error: [String: Any] = ["name": "error_tool", "description": "Return an error.", "inputSchema": ["type": "object", "properties": [:]]]
        return cursor == nil ? ["tools": [anchor, echo], "nextCursor": "page-2"] : ["tools": [large, slow, error], "nextCursor": ""]
    }

    private func content(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]]] }
    private func json(id: Any, result: [String: Any]) -> (Int, String, Data) { (200, "application/json", jsonData(id: id, result: result)) }
    private func jsonData(id: Any, result: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result], options: [.sortedKeys])) ?? Data() }
    private func write(_ response: (Int, String, Data), to socket: Int32) {
        let reason = response.0 == 200 ? "OK" : response.0 == 204 ? "No Content" : response.0 == 400 ? "Bad Request" : response.0 == 403 ? "Forbidden" : response.0 == 404 ? "Not Found" : "Internal Server Error"
        var data = Data("HTTP/1.1 \(response.0) \(reason)\r\nContent-Type: \(response.1)\r\nContent-Length: \(response.2.count)\r\nConnection: close\r\n\r\n".utf8); data.append(response.2)
        _ = data.withUnsafeBytes { send(socket, $0.baseAddress, data.count, 0) }
    }
}
