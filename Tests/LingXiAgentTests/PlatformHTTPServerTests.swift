#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows) || canImport(WinSDK)
import WinSDK
#endif
import Foundation
import Testing
@testable import LingXiPlatform

// MARK: - Raw client

/// Loopback HTTP client speaking straight to a socket.
///
/// Deliberately not URLSession: these tests have to send a `Host` the stack would refuse to
/// forge, decode chunk framing byte by byte, and hang up mid-stream to prove the server
/// notices.
private final class RawClient: @unchecked Sendable {
    private let fd: HTTPSocket
    private var received = Data()
    private var consumed = 0
    private(set) var peerClosed = false
    private var closed = false

    init?(port: UInt16, host: String = "127.0.0.1") {
        // Winsock has to be initialized on the thread that calls socket(); on the server side that
        // is the accept/connection threads, and this client runs on a test thread that nobody else
        // has registered. The pair is reference-counted, so `close()` releases it again.
        guard PlatformHTTPSocket.beginThread() else { return nil }
        #if canImport(Darwin)
        let sockType = SOCK_STREAM
        #elseif canImport(Glibc)
        let sockType = Int32(SOCK_STREAM.rawValue)
        #else
        let sockType = SOCK_STREAM
        #endif
        let created = socket(AF_INET, sockType, 0)
        guard created != kHTTPInvalidSocket else {
            PlatformHTTPSocket.endThread()
            return nil
        }
        var address = sockaddr_in()
        #if os(Windows) || canImport(WinSDK)
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_addr.S_un.S_addr = inet_addr(host)
        #elseif canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr(host)
        #else
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr(host)
        #endif
        address.sin_port = port.bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(created, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            PlatformHTTPSocket.closeSocket(created)
            PlatformHTTPSocket.endThread()
            return nil
        }
        fd = created
    }

    func send(_ text: String) {
        _ = PlatformHTTPSocket.sendAll(fd, Data(text.utf8))
    }

    func close() {
        guard !closed else { return }
        closed = true
        PlatformHTTPSocket.closeSocket(fd)
        PlatformHTTPSocket.endThread()
    }

    /// Every byte read so far.
    var snapshot: Data { received }

    /// Read until `stop` is satisfied, the peer closes, or the budget runs out; returns every
    /// byte seen so far. Each loop is bounded, so no test can wedge on a silent server.
    func gather(timeoutMs: Int32 = 3000, until stop: (Data) -> Bool = { _ in false }) -> Data {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while Date() < deadline {
            if stop(received) || peerClosed { break }
            switch PlatformHTTPSocket.waitReadable(fd, timeoutMs: 50) {
            case .ready:
                guard let chunk = PlatformHTTPSocket.receive(fd, maxBytes: 65536) else {
                    peerClosed = true
                    continue
                }
                received.append(chunk)
            case .failed:
                peerClosed = true
            case .timedOut:
                continue
            }
        }
        return received
    }

    /// One buffered request/response pair on this connection, advancing past what was read.
    func exchange(_ text: String, allowShortBody: Bool = false) -> HTTPReply? {
        send(text)
        let outstanding = { Data(self.received.dropFirst(self.consumed)) }
        gather { _ in HTTPReply.parse(outstanding(), allowShortBody: allowShortBody) != nil }
        let reply = HTTPReply.parse(outstanding(), allowShortBody: allowShortBody)
        if let reply { consumed += reply.consumedBytes }
        return reply
    }
}

/// A parsed buffered response.
struct HTTPReply {
    let status: Int
    let headers: [String: String]
    let body: Data
    /// How many bytes of the stream this reply accounts for.
    let consumedBytes: Int

    /// Returns nil while the response is still arriving, which is what lets the caller poll.
    static func parse(_ data: Data, allowShortBody: Bool = false) -> HTTPReply? {
        let bytes = [UInt8](data)
        guard let headEnd = findCRLF(bytes, from: 0, blankLine: true) else { return nil }
        let head = String(decoding: bytes[0..<headEnd], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.components(separatedBy: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = headEnd + 4
        var body = Data(bytes[bodyStart...])
        var consumedBytes = bodyStart + body.count
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = ChunkedCodec.complete(body) else { return nil }
            body = decoded
        } else if let length = headers["content-length"].flatMap({ Int($0) }) {
            guard body.count >= length || allowShortBody else { return nil }
            // HEAD announces the length of a body it never sends.
            if !allowShortBody {
                body = Data(bytes[bodyStart..<(bodyStart + length)])
                consumedBytes = bodyStart + length
            } else {
                body = Data()
                consumedBytes = bodyStart
            }
        }
        return HTTPReply(status: status, headers: headers, body: body, consumedBytes: consumedBytes)
    }

    var text: String { String(decoding: body, as: UTF8.self) }
}

/// Chunked transfer-coding helpers, so the tests decode the framing instead of trusting it.
enum ChunkedCodec {
    /// Payload once the terminating zero-length chunk has arrived, otherwise nil.
    static func complete(_ data: Data) -> Data? {
        let (payload, ended) = decode([UInt8](data))
        return ended ? payload : nil
    }

    /// Everything the framing has delivered so far, even mid-stream.
    static func partial(_ data: Data) -> Data {
        decode([UInt8](data)).0
    }

    private static func decode(_ bytes: [UInt8]) -> (Data, Bool) {
        var payload = [UInt8]()
        var index = 0
        while true {
            guard let lineEnd = findCRLF(bytes, from: index) else { return (Data(payload), false) }
            guard let size = Int(String(decoding: bytes[index..<lineEnd], as: UTF8.self), radix: 16) else {
                return (Data(payload), false)
            }
            let bodyStart = lineEnd + 2
            if size == 0 { return (Data(payload), true) }
            guard bytes.count >= bodyStart + size + 2 else { return (Data(payload), false) }
            payload.append(contentsOf: bytes[bodyStart..<(bodyStart + size)])
            index = bodyStart + size + 2
        }
    }
}

/// Find a CRLF, or with `blankLine` the CRLF CRLF that ends a head.
private func findCRLF(_ bytes: [UInt8], from: Int, blankLine: Bool = false) -> Int? {
    var index = from
    while index + 1 < bytes.count {
        if bytes[index] == 0x0d, bytes[index + 1] == 0x0a {
            if !blankLine { return index }
            if index + 3 < bytes.count, bytes[index + 2] == 0x0d, bytes[index + 3] == 0x0a {
                return index
            }
        }
        index += 1
    }
    return nil
}

private func requestLine(method: String,
                         path: String,
                         port: UInt16,
                         host: String? = nil,
                         body: String? = nil,
                         extraHeaders: [String] = []) -> String {
    var text = "\(method) \(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\n"
    for header in extraHeaders {
        text += "\(header)\r\n"
    }
    if let body {
        text += "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    } else {
        text += "\r\n"
    }
    return text
}

/// Poll until a whole buffered reply is on the wire, then parse it.
private func readReply(_ client: RawClient, timeoutMs: Int32 = 3000) -> HTTPReply? {
    _ = client.gather(timeoutMs: timeoutMs) { HTTPReply.parse($0) != nil }
    return HTTPReply.parse(client.snapshot)
}

/// SSE event frames of a stream response, with the head and chunk framing stripped off.
private func eventFrames(in data: Data) -> [String] {
    String(decoding: streamPayload(data), as: UTF8.self)
        .components(separatedBy: "\n\n")
        .filter { $0.hasPrefix("id:") }
}

/// Payload of a stream response, with the head and chunk framing stripped off.
private func streamPayload(_ data: Data) -> Data {
    guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else { return Data() }
    return ChunkedCodec.partial(data[boundary.upperBound...])
}

/// A flag a stream producer can raise from another thread.
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}

private func waitUntil(timeoutMs: Int32 = 3000, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

private func makeConfiguration() -> PlatformHTTPServer.Configuration {
    var configuration = PlatformHTTPServer.Configuration()
    configuration.host = "127.0.0.1"
    configuration.port = 0
    configuration.idleTimeoutSeconds = 5
    configuration.handlerTimeoutSeconds = 5
    return configuration
}

// MARK: - Tests

@Suite("PlatformHTTPServer: routing, static assets, guards, SSE, lifecycle")
struct PlatformHTTPServerTests {

    @Test("Ephemeral bind, JSON routing, longest prefix, 404, POST body and 413")
    func routesAndBodyLimits() throws {
        var configuration = makeConfiguration()
        configuration.maxBodyBytes = 1024
        let server = try PlatformHTTPServer(configuration: configuration)
        defer { server.stop() }

        #expect(server.port > 0, "port 0 must resolve to an ephemeral port")
        #expect(!server.isRunning)

        server.route("GET", "/api") { _ in
            .json(status: 200, value: Data("{\"which\":\"short\"}".utf8))
        }
        server.route("GET", "/api/state") { _ in
            .json(status: 200, value: Data("{\"which\":\"exact\",\"ok\":true}".utf8))
        }
        server.route("POST", "/api/echo") { request in
            var payload = Data("{\"method\":\"".utf8)
            payload.append(Data(request.method.utf8))
            payload.append(Data("\",\"path\":\"".utf8))
            payload.append(Data(request.path.utf8))
            payload.append(Data("\",\"query\":\"".utf8))
            payload.append(Data((request.query["tag"] ?? "").utf8))
            payload.append(Data("\",\"body\":\"".utf8))
            payload.append(request.body)
            payload.append(Data("\"}".utf8))
            return .json(status: 201, value: payload)
        }
        try server.start()
        #expect(server.isRunning)

        let port = server.port
        let client = try #require(RawClient(port: port))
        defer { client.close() }

        let state = try #require(client.exchange(requestLine(method: "GET", path: "/api/state", port: port)))
        #expect(state.status == 200)
        #expect(state.headers["content-type"] == "application/json; charset=utf-8")
        #expect(state.text.contains("\"exact\""), "the longest registered prefix must win")
        #expect(state.headers["connection"] == "keep-alive")

        let missing = try #require(client.exchange(requestLine(method: "GET", path: "/nope", port: port)))
        #expect(missing.status == 404)

        let echoed = try #require(client.exchange(requestLine(method: "POST",
                                                             path: "/api/echo?tag=v1",
                                                             port: port,
                                                             body: "{\"hello\":1}")))
        #expect(echoed.status == 201)
        #expect(echoed.text.contains("\"method\":\"POST\""))
        #expect(echoed.text.contains("{\"hello\":1}"), "the handler must see the raw body")
        #expect(echoed.text.contains("\"query\":\"v1\""), "query parameters must be parsed")

        // Oversized body: refused on the declared length, before the octets are buffered.
        let oversized = try #require(client.exchange(requestLine(method: "POST",
                                                                 path: "/api/echo",
                                                                 port: port,
                                                                 body: String(repeating: "x", count: 4096))))
        #expect(oversized.status == 413)

        // The 413 path drops the connection, so the next request needs a fresh one.
        let next = try #require(RawClient(port: port))
        defer { next.close() }
        let accepted = try #require(next.exchange(requestLine(method: "POST",
                                                              path: "/api/echo",
                                                              port: port,
                                                              body: "tiny")))
        #expect(accepted.status == 201)
    }

    @Test("HEAD, keep-alive, oversized headers and unsupported framing")
    func headKeepAliveAndRejections() throws {
        let server = try PlatformHTTPServer(configuration: makeConfiguration())
        defer { server.stop() }
        server.route("GET", "/page") { _ in
            .text(status: 200, body: "0123456789")
        }
        try server.start()
        let port = server.port

        let client = try #require(RawClient(port: port))
        defer { client.close() }

        let head = try #require(client.exchange(requestLine(method: "HEAD", path: "/page", port: port),
                                               allowShortBody: true))
        #expect(head.status == 200)
        #expect(head.headers["content-length"] == "10", "HEAD must keep the GET length")
        #expect(head.body.isEmpty)

        // A second request on the same socket proves keep-alive.
        let first = try #require(client.exchange(requestLine(method: "GET", path: "/page", port: port)))
        #expect(first.status == 200)
        #expect(first.text == "0123456789")
        let second = try #require(client.exchange(requestLine(method: "GET", path: "/page", port: port)))
        #expect(second.status == 200)
        #expect(second.text == "0123456789")

        let hugeHeader = "GET /page HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-Big: "
            + String(repeating: "a", count: 64 * 1024) + "\r\n\r\n"
        let headers = try #require(RawClient(port: port))
        defer { headers.close() }
        headers.send(hugeHeader)
        let tooLarge = headers.gather(timeoutMs: 2000) { $0.starts(with: Data("HTTP/1.1 431".utf8)) }
        #expect(tooLarge.starts(with: Data("HTTP/1.1 431".utf8)),
                "oversized head must be refused with 431, got: \(tooLarge.prefix(40))")

        let chunked = try #require(RawClient(port: port))
        defer { chunked.close() }
        chunked.send("POST /page HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n1\r\na\r\n0\r\n\r\n")
        let notImplemented = try #require(readReply(chunked))
        #expect(notImplemented.status == 501)

        // A bare LF request must still parse: the head parser is CRLF tolerant.
        let lenient = try #require(RawClient(port: port))
        defer { lenient.close() }
        lenient.send("GET /page HTTP/1.1\nHost: 127.0.0.1:\(port)\n\n")
        let parsed = try #require(readReply(lenient))
        #expect(parsed.status == 200)
        #expect(parsed.text == "0123456789")
    }

    @Test("Static assets serve with the right types and refuse every traversal")
    func staticServingIsTraversalSafe() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-http-static-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "<html><body>index</body></html>".write(to: root.appendingPathComponent("index.html"),
                                                   atomically: true, encoding: .utf8)
        try "console.log('app');".write(to: root.appendingPathComponent("app.js"),
                                        atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("img"),
                                               withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: root.appendingPathComponent("img/logo.png"))
        try "secret".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-http-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try "outside-secret".write(to: outside, atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"),
                                                   withDestinationURL: outside)

        // A second root mounted under a sub-prefix, to prove prefix stripping is correct.
        let nested = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-http-nested-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: nested) }
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "console.log('bundled');".write(to: nested.appendingPathComponent("bundle.mjs"),
                                            atomically: true, encoding: .utf8)
        try "<html><body>nested</body></html>".write(to: nested.appendingPathComponent("index.html"),
                                                    atomically: true, encoding: .utf8)

        let server = try PlatformHTTPServer(configuration: makeConfiguration())
        defer { server.stop() }
        server.serveStatic(directory: root, at: "/")
        server.serveStatic(directory: nested, at: "/assets")
        server.route("GET", "/api") { _ in .json(status: 200, value: Data("{}".utf8)) }
        try server.start()
        let port = server.port
        let client = try #require(RawClient(port: port))
        defer { client.close() }

        let index = try #require(client.exchange(requestLine(method: "GET", path: "/", port: port)))
        #expect(index.status == 200)
        #expect(index.headers["content-type"]?.hasPrefix("text/html") == true)
        #expect(index.headers["cache-control"] == "no-cache")
        #expect(index.text.contains("index"))

        let script = try #require(client.exchange(requestLine(method: "GET", path: "/app.js", port: port)))
        #expect(script.status == 200)
        #expect(script.headers["content-type"]?.hasPrefix("text/javascript") == true)
        /* The app's own sources are un-fingerprinted and `serve --assets` points at a tree that
           changes under a running instance, so they must revalidate: a long max-age makes a
           reload keep executing yesterday's script. */
        #expect(script.headers["cache-control"] == "no-cache")

        let image = try #require(client.exchange(requestLine(method: "GET", path: "/img/logo.png", port: port)))
        #expect(image.status == 200)
        #expect(image.headers["content-type"] == "image/png")
        #expect(image.headers["cache-control"]?.contains("max-age=") == true)

        // Routes are consulted before files, and HEAD works on files too.
        let routed = try #require(client.exchange(requestLine(method: "GET", path: "/api", port: port)))
        #expect(routed.status == 200)
        #expect(routed.headers["content-type"]?.hasPrefix("application/json") == true)
        let headFile = try #require(client.exchange(requestLine(method: "HEAD", path: "/app.js", port: port),
                                                   allowShortBody: true))
        #expect(headFile.status == 200)
        #expect(headFile.body.isEmpty)

        // Every spelling of "get out of the root" answers 404, and never the file.
        let attempts = [
            "/../\(outside.lastPathComponent)",
            "/../../etc/passwd",
            "/%2e%2e/%2e%2e/etc/passwd",
            "/..%2f..%2fetc/passwd",
            "/%2e%2e%2f%2e%2e%2fetc%2fpasswd",
            "/app.js/../../\(outside.lastPathComponent)",
            "/escape",
            "/.env",
            "/img",
        ]
        for attempt in attempts {
            let reply = try #require(client.exchange(requestLine(method: "GET", path: attempt, port: port)))
            #expect(reply.status == 404, "\(attempt) leaked: \(reply.text)")
            #expect(!reply.text.contains("outside-secret"))
            #expect(!reply.text.contains("root:"))
        }

        let missing = try #require(client.exchange(requestLine(method: "GET", path: "/nope.html", port: port)))
        #expect(missing.status == 404)

        // Sub-prefix mount: the prefix is stripped, and it cannot be used to walk back out.
        let bundled = try #require(client.exchange(requestLine(method: "GET", path: "/assets/bundle.mjs", port: port)))
        #expect(bundled.status == 200)
        #expect(bundled.text.contains("bundled"))
        for mountRoot in ["/assets", "/assets/"] {
            let nestedIndex = try #require(client.exchange(requestLine(method: "GET", path: mountRoot, port: port)))
            #expect(nestedIndex.status == 200, "\(mountRoot) must serve the mounted index.html")
            #expect(nestedIndex.text.contains("nested"), "\(mountRoot) served: \(nestedIndex.text)")
        }
        let upFromMount = try #require(client.exchange(requestLine(method: "GET",
                                                                  path: "/assets/\(root.lastPathComponent)/app.js",
                                                                  port: port)))
        #expect(upFromMount.status == 404)
        let mountEscape = try #require(client.exchange(requestLine(method: "GET",
                                                                   path: "/assets/../../etc/passwd",
                                                                   port: port)))
        #expect(mountEscape.status == 404)
        let notFoundUnderMount = try #require(client.exchange(requestLine(method: "GET",
                                                                          path: "/assets/nope.mjs",
                                                                          port: port)))
        #expect(notFoundUnderMount.status == 404)
    }

    @Test("guardRequest short-circuits and a foreign Host is refused")
    func guardHooksAndHostValidation() throws {
        let server = try PlatformHTTPServer(configuration: makeConfiguration())
        defer { server.stop() }
        server.route("GET", "/api/state") { _ in
            .json(status: 200, value: Data("{\"ok\":true}".utf8))
        }
        server.guardRequest = { request in
            request.path.hasPrefix("/api") && request.header("x-lingxi-token") != "s3cret"
                ? .text(status: 401, body: "token required")
                : nil
        }
        try server.start()
        let port = server.port

        let guarded = try #require(RawClient(port: port))
        defer { guarded.close() }
        let blocked = try #require(guarded.exchange(requestLine(method: "GET", path: "/api/state", port: port)))
        #expect(blocked.status == 401, "guardRequest must be able to short-circuit routing")

        let allowed = try #require(guarded.exchange(requestLine(method: "GET",
                                                               path: "/api/state",
                                                               port: port,
                                                               extraHeaders: ["x-lingxi-token: s3cret"])))
        #expect(allowed.status == 200)

        // DNS rebinding: an attacker's page reaches 127.0.0.1 but keeps its own Host.
        let rebound = try #require(RawClient(port: port))
        defer { rebound.close() }
        let forbidden = try #require(rebound.exchange(requestLine(method: "GET",
                                                                  path: "/api/state",
                                                                  port: port,
                                                                  host: "evil.example.com:\(port)",
                                                                  extraHeaders: ["x-lingxi-token: s3cret"])))
        #expect(forbidden.status == 403)
        #expect(forbidden.text.lowercased().contains("host"))

        // Same for a Host with no port at all: nothing legitimate types that for 127.0.0.1:xxxx.
        let portless = try #require(RawClient(port: port))
        defer { portless.close() }
        let missingPort = try #require(portless.exchange(requestLine(method: "GET",
                                                                     path: "/api/state",
                                                                     port: port,
                                                                     host: "localhost")))
        #expect(missingPort.status == 403, "a Host without this port is not addressed to us")

        let alias = try #require(RawClient(port: port))
        defer { alias.close() }
        let loopbackAlias = try #require(alias.exchange(requestLine(method: "GET",
                                                                    path: "/api/state",
                                                                    port: port,
                                                                    host: "localhost:\(port)",
                                                                    extraHeaders: ["x-lingxi-token: s3cret"])))
        #expect(loopbackAlias.status == 200)
    }

    @Test("SSE stream frames events in order and notices the client hanging up")
    func sseStreamAndDisconnectDetection() throws {
        let server = try PlatformHTTPServer(configuration: makeConfiguration())
        defer { server.stop() }
        let sawDisconnect = FlagBox()

        server.route("GET", "/events") { _ in
            .stream(headers: ["Cache-Control": "no-store"]) { writer in
                for index in 1...3 {
                    let written = await writer.sse(id: "\(index)", event: "state", data: "{\"n\":\(index)}")
                    if !written { return }
                }
                var waited = 0
                while !(await writer.isCancelled), waited < 600 {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    waited += 1
                }
                if await writer.isCancelled { sawDisconnect.raise() }
            }
        }
        try server.start()
        let port = server.port

        let client = try #require(RawClient(port: port))
        defer { client.close() }
        client.send(requestLine(method: "GET", path: "/events", port: port))

        let headBytes = client.gather(timeoutMs: 3000) { $0.range(of: Data("\r\n\r\n".utf8)) != nil }
        let boundary = try #require(headBytes.range(of: Data("\r\n\r\n".utf8)))
        let headData = Data(headBytes[headBytes.startIndex..<boundary.lowerBound])
        let head = String(decoding: headData, as: UTF8.self)
        #expect(head.contains("HTTP/1.1 200"))
        #expect(head.lowercased().contains("transfer-encoding: chunked"), "streams must be chunked to flush")
        #expect(head.lowercased().contains("content-type: text/event-stream"))
        #expect(head.lowercased().contains("cache-control: no-store"), "handler headers must survive")
        #expect(head.lowercased().contains("connection: close"))

        let accumulated = client.gather(timeoutMs: 3000) { eventFrames(in: $0).count >= 3 }
        let events = eventFrames(in: accumulated)
        #expect(events.count == 3, "expected three framed events, got: \(events)")
        if events.count == 3 {
            #expect(events[0].contains("id: 1") && events[0].contains("event: state")
                && events[0].contains("data: {\"n\":1}"))
            #expect(events[1].contains("id: 2"))
            #expect(events[2].contains("id: 3"))
        }

        // Hanging up must reach the producer, not just the socket.
        client.close()
        #expect(waitUntil(timeoutMs: 3000) { sawDisconnect.isRaised },
                "the producer must observe isCancelled once the peer is gone")
        #expect(waitUntil(timeoutMs: 3000) { server.activeConnectionCount == 0 })
    }

    @Test("stop() is prompt and idempotent, releases live connections and refuses new ones")
    func lifecycleStopsCleanly() throws {
        let server = try PlatformHTTPServer(configuration: makeConfiguration())
        server.route("GET", "/page") { _ in .text(status: 200, body: "pong") }
        try server.start()
        let port = server.port

        // Two connections opened and left idle: exactly the threads that must not leak.
        let idle = [RawClient(port: port), RawClient(port: port)]
        #expect(waitUntil(timeoutMs: 3000) { server.activeConnectionCount == 2 })

        let elapsed = ContinuousClock().measure { server.stop() }
        #expect(elapsed < .seconds(1), "stop() must be prompt, took \(elapsed)")
        server.stop()
        #expect(!server.isRunning)

        // The idle clients were closed by the server rather than left hanging.
        for client in idle {
            guard let client else { continue }
            #expect(client.gather(timeoutMs: 1000).isEmpty)
            #expect(client.peerClosed)
            client.close()
        }
        #expect(waitUntil(timeoutMs: 3000) { server.activeConnectionCount == 0 })
        #expect(RawClient(port: port) == nil, "connecting after stop() must fail")

        // A request that is in flight when the server goes down must not wedge either.
        let racing = try PlatformHTTPServer(configuration: makeConfiguration())
        racing.route("GET", "/page") { _ in .text(status: 200, body: "pong") }
        try racing.start()
        let inFlight = RawClient(port: racing.port)
        if let inFlight {
            inFlight.send(requestLine(method: "GET", path: "/page", port: racing.port))
            racing.stop()
            #expect(waitUntil(timeoutMs: 3000) { racing.activeConnectionCount == 0 })
            inFlight.close()
        }
        #expect(!racing.isRunning)
    }

    @Test("A stream backlog is dropped at the bound instead of growing without limit")
    func streamPipeBackpressureBound() {
        // White box: the same trip the socket thread relies on, exercised without racing a
        // kernel socket buffer, which is what makes the assertion deterministic.
        let pipe = PlatformHTTPStreamPipe(byteLimit: 4096)
        let chunk = Data(repeating: 0x61, count: 1024)
        var accepted = 0
        while pipe.append(chunk) {
            accepted += 1
            if accepted > 100 { break }
        }
        #expect(accepted * 1024 <= 4096, "the queue must never grow past the bound")
        #expect(pipe.isCancelled, "tripping the bound cancels the stream")
        #expect(!pipe.append(chunk), "a cancelled pipe accepts nothing further")
        #expect(pipe.drain().payloads.isEmpty, "the dropped backlog must not be sent after the trip")

        // A producer that finishes inside the bound keeps everything it wrote.
        let healthy = PlatformHTTPStreamPipe(byteLimit: 4096)
        #expect(healthy.append(Data("id: 1\nevent: tick\n\n".utf8)))
        healthy.finish()
        let queued = healthy.drain()
        #expect(queued.sawEnd)
        #expect(String(decoding: queued.payloads.joined(), as: UTF8.self).contains("event: tick"))
        #expect(!healthy.append(Data("more".utf8)), "nothing is accepted after the end marker")
    }

    @Test("maxConnections bounds concurrency and answers the surplus with 503")
    func capacityBound() throws {
        var configuration = makeConfiguration()
        configuration.maxConnections = 1
        let server = try PlatformHTTPServer(configuration: configuration)
        defer { server.stop() }
        server.route("GET", "/api/state") { _ in
            .json(status: 200, value: Data("{\"ok\":true}".utf8))
        }
        try server.start()
        let port = server.port

        let held = try #require(RawClient(port: port))
        defer { held.close() }
        #expect(waitUntil(timeoutMs: 3000) { server.activeConnectionCount == 1 })

        let surplus = try #require(RawClient(port: port))
        defer { surplus.close() }
        surplus.send(requestLine(method: "GET", path: "/api/state", port: port))
        let refused = try #require(readReply(surplus))
        #expect(refused.status == 503)

        // Freeing the slot makes room again.
        held.close()
        #expect(waitUntil(timeoutMs: 3000) { server.activeConnectionCount == 0 })
        let admitted = try #require(RawClient(port: port))
        defer { admitted.close() }
        let served = try #require(admitted.exchange(requestLine(method: "GET", path: "/api/state", port: port)))
        #expect(served.status == 200)
    }
}
