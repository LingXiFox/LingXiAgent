import Darwin
import Foundation
import LingXiPluginRuntime
import Testing

/// Shared fixtures for the Core-level diagnostics acceptance tests (reasoning selection, provider
/// state, run timing). They drive the real `LingXiCoreHost` over the frontend protocol, so nothing
/// here can fake an HTTP body or a plugin answer.

let diagnosticsMiMoBundleID = "site.lingxi.provider.mimo"
/// The provider id the MiMo plugin declares: routing and state both use this, not the bundle id.
let diagnosticsMiMoProviderID = "mimo"

func diagnosticsConfigGrant(_ config: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    return "config=" + data.base64EncodedString()
}

/// Registers the real MiMo bundle with the real plugin registry. `grants` carry the offline test
/// hooks the plugin already understands (config, endpoint, cassette).
func seedDiagnosticsProvider(
    _ directory: URL, config: [String: Any]? = nil, endpoint: URL? = nil, cassette: URL? = nil
) async throws {
    let bundle = try makeBundle(
        bundleID: diagnosticsMiMoBundleID, executableName: "MiMoProvider",
        dylib: builtProduct("libMiMoProvider.dylib"),
        capabilities: ["provider.mimo", "settings.view.v1"]
    )
    var grants: [String] = []
    if let config { grants.append(try diagnosticsConfigGrant(config)) }
    if let endpoint { grants.append("test.endpoint=\(endpoint.absoluteString)") }
    if let cassette { grants.append("vcr=\(cassette.path)") }
    let registry = try PluginRegistry(configURL: directory.appendingPathComponent("plugins.json"))
    try await registry.upsert(.init(
        bundleID: diagnosticsMiMoBundleID, version: "1.0.0", bundlePath: bundle.url.path,
        enabled: true, grants: grants
    ))
    // Environment-mode credentials need the operator mapping: the plugin declaration only suggests
    // a variable name, never grants the read on its own.
    let mapping = try JSONSerialization.data(
        withJSONObject: ["provider.\(diagnosticsMiMoProviderID)": "MIMO_API_KEY"], options: [.sortedKeys]
    )
    try mapping.write(to: directory.appendingPathComponent("credentials.json"))
}

/// Explicit environment credential for the Core. Never a real key: the plugin only checks presence.
func diagnosticsCredentialEnvironment() -> [String: String] {
    [
        "LINGXI_CREDENTIAL_SOURCE": "environment",
        "MIMO_API_KEY": "offline-test-credential",
    ]
}

func diagnosticsTempDirectory(_ prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

// MARK: - loopback HTTP

struct CapturedHTTPRequest: Sendable {
    let path: String
    let body: String
}

/// Minimal HTTP/1.1 loopback endpoint. It only understands what URLSession sends in these tests and
/// records the raw body, which is what makes "the UI toggle really changed the request" checkable.
final class TestLoopbackServer: @unchecked Sendable {
    private let listenFD: Int32
    private let responses: [String]
    private let lock = NSLock()
    private var captured: [CapturedHTTPRequest] = []
    private var failure: String?
    let port: UInt16

    init(responses: [String]) throws {
        guard !responses.isEmpty else { throw NSError(domain: "TestLoopbackServer", code: 1) }
        self.responses = responses
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "TestLoopbackServer", code: 2) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw NSError(domain: "TestLoopbackServer", code: 3)
        }
        var local = sockaddr_in()
        var localLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &localLength) }
        }
        guard named == 0 else {
            close(fd)
            throw NSError(domain: "TestLoopbackServer", code: 4)
        }
        listenFD = fd
        port = UInt16(bigEndian: local.sin_port)
        Thread.detachNewThread { [self] in serve() }
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")! }

    func request(count: Int) -> CapturedHTTPRequest? {
        lock.lock(); defer { lock.unlock() }
        return captured.count >= count ? captured[count - 1] : nil
    }

    var failureDescription: String? {
        lock.lock(); defer { lock.unlock() }; return failure
    }

    private func record(_ request: CapturedHTTPRequest) {
        lock.lock(); captured.append(request); lock.unlock()
    }

    private func fail(_ message: String) {
        lock.lock(); failure = message; lock.unlock()
    }

    private func serve() {
        for response in responses {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { fail("accept failed: \(errno)"); break }
            handle(client: client, response: response)
            close(client)
        }
        close(listenFD)
    }

    private func handle(client: Int32, response: String) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { fail("client closed before headers"); return }
            data.append(contentsOf: buffer[0..<count])
            headerEnd = data.range(of: Data("\r\n\r\n".utf8))
        }
        guard let headerEnd else { return }
        let head = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        guard let requestLine = head.split(separator: "\r\n").first else {
            fail("no request line"); return
        }
        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        var contentLength = 0
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            let value = line.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            contentLength = Int(value) ?? 0
        }
        var body = Data(data[headerEnd.upperBound...])
        while body.count < contentLength {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer[0..<count])
        }
        record(CapturedHTTPRequest(
            path: path, body: String(decoding: body.prefix(contentLength), as: UTF8.self)
        ))
        let payload = Data(response.utf8)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(client, base.advanced(by: offset), raw.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}

func sseResponse(_ body: String) -> String {
    "HTTP/1.1 200 OK\r\n"
        + "Content-Type: text/event-stream\r\n"
        + "Cache-Control: no-cache\r\n"
        + "Connection: close\r\n\r\n"
        + body
}

func chatSSE(_ text: String) -> String {
    let chunk: [String: Any] = [
        "id": "chatcmpl-test",
        "choices": [[
            "index": 0,
            "delta": ["content": text],
            "finish_reason": "stop",
        ]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: chunk, options: [.sortedKeys])
    return "data: \(String(decoding: data, as: UTF8.self))\n\ndata: [DONE]\n\n"
}

func responsesSSE(_ text: String) -> String {
    var blocks: [[String]] = [
        [
            "event: response.output_text.delta",
            "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":1,\"item_id\":\"msg_test\",\"delta\":\"\(text)\"}",
        ],
    ]
    let completed: [String: Any] = [
        "type": "response.completed",
        "sequence_number": 2,
        "response": ["id": "resp_test", "status": "completed"],
    ]
    let data = try! JSONSerialization.data(withJSONObject: completed, options: [.sortedKeys])
    blocks.append(["event: response.completed", "data: \(String(decoding: data, as: UTF8.self))"])
    return blocks.map { $0.joined(separator: "\n") + "\n\n" }.joined()
}

func waitForRequest(
    _ server: TestLoopbackServer, count: Int, timeout: Duration = .seconds(30)
) async throws -> CapturedHTTPRequest {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if let request = server.request(count: count) { return request }
        if let failure = server.failureDescription {
            throw NSError(domain: "TestLoopbackServer", code: 5, userInfo: [NSLocalizedDescriptionKey: failure])
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw NSError(domain: "TestLoopbackServer", code: 6, userInfo: [NSLocalizedDescriptionKey: "timed out waiting for request \(count)"])
}

func jsonBody(_ request: CapturedHTTPRequest) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any],
        "body: \(request.body)"
    )
}
