import Foundation

/// A decoded HTTP request handed to a route handler.
public struct PlatformHTTPRequest: Sendable {
    /// Uppercase request method, for example `GET`, `POST`, `HEAD`, `OPTIONS`.
    public let method: String
    /// Percent-decoded request target without the query string, for example `/api/state`.
    public let path: String
    /// Query parameters of the request target; the last value wins when a key repeats.
    public let query: [String: String]
    /// Header fields keyed by lower-cased name. Repeated fields are joined with `", "`.
    public let headers: [String: String]
    /// Fully buffered request body; empty when the request carried no `Content-Length`.
    public let body: Data
    /// Dotted-quad address of the peer that opened the connection.
    public let clientAddress: String

    public init(method: String,
                path: String,
                query: [String: String],
                headers: [String: String],
                body: Data,
                clientAddress: String) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.clientAddress = clientAddress
    }

    /// Look up a header field case-insensitively.
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// Everything a route handler can answer with.
public enum PlatformHTTPResponse: Sendable {
    /// `application/json; charset=utf-8` body.
    case json(status: Int, value: Data, headers: [String: String] = [:])
    /// Arbitrary bytes with an explicit content type.
    case data(status: Int, contentType: String, value: Data, headers: [String: String] = [:])
    /// 404 with a short text body.
    case notFound
    /// `text/plain; charset=utf-8` body.
    case text(status: Int, body: String, headers: [String: String] = [:])
    /// Long-lived SSE response. `producer` is invoked once; it writes frames via the
    /// writer and returns when the stream should end.
    ///
    /// The stream is sent with `Transfer-Encoding: chunked` and always ends the
    /// connection, so a reconnecting client starts from a clean slate.
    case stream(headers: [String: String], producer: @Sendable (PlatformHTTPWriter) async -> Void)
}

/// Sink handed to a `stream` producer.
public protocol PlatformHTTPWriter: Sendable {
    /// Write one SSE event: `id:`, `event:`, `data:` lines then a blank line.
    /// Returns false once the peer is gone, the stream was cancelled, or the buffering
    /// bound was exceeded -- a false result means the producer should stop.
    @discardableResult func sse(id: String?, event: String, data: String) async -> Bool

    /// Write raw bytes as one HTTP chunk. Returns false under the same conditions as `sse`.
    @discardableResult func write(_ chunk: Data) async -> Bool

    /// True once the peer disconnected, the server is stopping, or the buffer bound tripped.
    var isCancelled: Bool { get async }
}

/// Reason phrase paired with a status code on the response line.
enum PlatformHTTPStatus {
    static func reason(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }

    /// Statuses that must not carry a body, per RFC 9112 section 6.3.
    static func allowsBody(_ code: Int) -> Bool {
        code != 204 && code != 304 && !(100...199 ~= code)
    }
}

/// Ordered response header fields with case-insensitive replacement, so a handler-supplied
/// override wins over a generated default no matter how it is capitalised.
struct PlatformHTTPHeadFields: Sendable {
    private var fields: [(name: String, value: String)] = []

    mutating func set(_ name: String, _ value: String) {
        let lowered = name.lowercased()
        if let index = fields.firstIndex(where: { $0.name.lowercased() == lowered }) {
            fields[index] = (fields[index].name, value)
        } else {
            fields.append((name, value))
        }
    }

    /// Render as `Name: value` lines without the terminating blank line.
    func serializedData() -> Data {
        var text = ""
        for field in fields {
            // CRLF inside a header value would let a handler inject extra response lines.
            let sanitized = field.value
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            text += "\(field.name): \(sanitized)\r\n"
        }
        return Data(text.utf8)
    }
}

/// Rendering of the buffered (non-stream) responses.
enum PlatformHTTPResponseWriter {
    /// Build the whole head + body. `suppressBody` implements `HEAD`, which keeps the
    /// `Content-Length` of the would-be response but sends no octets.
    static func serialize(_ response: PlatformHTTPResponse,
                          method: String,
                          keepAlive: Bool,
                          date: String,
                          serverName: String) -> Data {
        var status = 200
        var contentType = "text/plain; charset=utf-8"
        var body = Data()
        var custom: [String: String] = [:]

        switch response {
        case .json(let code, let value, let headers):
            status = code
            contentType = "application/json; charset=utf-8"
            body = value
            custom = headers
        case .data(let code, let type, let value, let headers):
            status = code
            contentType = type
            body = value
            custom = headers
        case .text(let code, let value, let headers):
            status = code
            body = Data(value.utf8)
            custom = headers
        case .notFound:
            status = 404
            body = Data("not found".utf8)
        case .stream:
            // Streams are served by the connection layer; this call never sees one.
            status = 200
        }

        var head = PlatformHTTPHeadFields()
        head.set("Content-Type", contentType)
        // Handlers may override anything except the fields that carry the framing itself;
        // a caller-supplied Content-Length or Transfer-Encoding would desynchronise the
        // connection from the byte stream.
        for (name, value) in custom.sorted(by: { $0.key < $1.key }) {
            let lowered = name.lowercased()
            if lowered == "content-length" || lowered == "transfer-encoding" || lowered == "connection" {
                continue
            }
            head.set(name, value)
        }
        head.set("Date", date)
        head.set("Server", serverName)
        if PlatformHTTPStatus.allowsBody(status) {
            // HEAD reports the length the GET would have produced and simply omits the octets.
            head.set("Content-Length", String(body.count))
        }
        head.set("Connection", keepAlive ? "keep-alive" : "close")

        var out = Data("HTTP/1.1 \(status) \(PlatformHTTPStatus.reason(for: status))\r\n".utf8)
        out.append(head.serializedData())
        out.append(Data("\r\n".utf8))
        if method != "HEAD" {
            out.append(body)
        }
        return out
    }
}

/// One decoded request, or why decoding has not finished / cannot finish.
enum PlatformHTTPParseStep {
    case incomplete
    case request(PlatformHTTPRequest, keepAlive: Bool, consumedBytes: Int)
    /// Malformed or unsupported framing. The connection is not reusable afterwards,
    /// because the byte stream is no longer aligned with a request boundary.
    case rejection(status: Int, message: String)
}

/// Incremental decoder for the HTTP/1.1 subset this server supports: request line,
/// header fields, and `Content-Length` bodies.
///
/// `consume(_:)` requires `buffer` to be a zero-based `Data`, which the connection layer
/// guarantees by always rebuilding the leftover with `subdata(in:)`.
struct PlatformHTTPParser: Sendable {
    let maxHeaderBytes: Int
    let maxBodyBytes: Int

    private static let maxHeaderFields = 128
    private static let maxTargetLength = 16 * 1024

    func consume(_ buffer: Data, clientAddress: String) -> PlatformHTTPParseStep {
        guard let boundary = headerEnd(in: buffer) else {
            if buffer.count > maxHeaderBytes {
                return .rejection(status: 431, message: "Request header fields too large")
            }
            return .incomplete
        }
        let headData = buffer.subdata(in: 0..<boundary.headEnd)
        if headData.count > maxHeaderBytes {
            return .rejection(status: 431, message: "Request header fields too large")
        }
        let bodyStart = boundary.bodyStart
        let availableBody = buffer.count - bodyStart

        let lines = String(decoding: headData, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        // RFC 9112 lets a client flush a keep-alive connection with leading blank lines, and
        // they carry no request. Drop them instead of rejecting the connection for noise.
        let fields = Array(lines.drop(while: { $0.isEmpty }))
        guard !fields.isEmpty, fields.count - 1 <= Self.maxHeaderFields else {
            return .rejection(status: 431, message: "Too many header fields")
        }

        let parts = fields[0].components(separatedBy: " ")
        guard parts.count == 3 else {
            return .rejection(status: 400, message: "Malformed request line")
        }
        let method = parts[0]
        let target = parts[1]
        let version = parts[2]
        guard !method.isEmpty, method.allSatisfy({ $0.isLetter || $0.isNumber }),
              version.hasPrefix("HTTP/1."),
              !target.isEmpty, target.count <= Self.maxTargetLength,
              !target.utf8.contains(where: { Int($0) < 0x21 || $0 == 0x7f }) else {
            return .rejection(status: 400, message: "Malformed request line")
        }

        var headers: [String: String] = [:]
        for line in fields.dropFirst() {
            guard line != "\r", !line.isEmpty else {
                return .rejection(status: 400, message: "Malformed header field")
            }
            guard let colon = line.firstIndex(of: ":") else {
                return .rejection(status: 400, message: "Malformed header field")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains(" ") else {
                return .rejection(status: 400, message: "Malformed header field")
            }
            if let existing = headers[name] {
                // Two different Content-Length values is a request-smuggling signal rather
                // than a repeated field, so refuse instead of joining them.
                if name == "content-length", existing != value {
                    return .rejection(status: 400, message: "Conflicting Content-Length")
                }
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        if headers["transfer-encoding"] != nil {
            return .rejection(status: 501, message: "Transfer-Encoding is not supported")
        }
        var contentLength = 0
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0 else {
                return .rejection(status: 400, message: "Invalid Content-Length")
            }
            contentLength = parsed
        }
        guard contentLength <= maxBodyBytes else {
            return .rejection(status: 413, message: "Request body too large")
        }
        // Answer a bad target now: waiting for the declared body first would let a client
        // hold the connection open on a request that can never be served.
        guard let split = resolveTarget(target) else {
            return .rejection(status: 400, message: "Invalid request target")
        }
        guard availableBody >= contentLength else { return .incomplete }

        let request = PlatformHTTPRequest(
            method: method.uppercased(),
            path: split.path,
            query: split.query,
            headers: headers,
            body: buffer.subdata(in: bodyStart..<(bodyStart + contentLength)),
            clientAddress: clientAddress
        )
        return .request(request,
                        keepAlive: Self.wantsKeepAlive(version: version, connection: headers["connection"]),
                        consumedBytes: bodyStart + contentLength)
    }

    private func resolveTarget(_ target: String) -> (path: String, query: [String: String])? {
        var originForm = target
        // Absolute-form targets come from proxies and from a few HTTP clients; only the
        // path and query matter here.
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            let withoutScheme = target.dropFirst(target.hasPrefix("http://") ? 7 : 8)
            if let slash = withoutScheme.firstIndex(of: "/") {
                originForm = String(withoutScheme[slash...])
            } else {
                originForm = "/"
            }
        }
        if originForm == "*" { originForm = "/*" }
        guard originForm.hasPrefix("/") else { return nil }

        let rawPath: String
        let rawQuery: String
        if let question = originForm.firstIndex(of: "?") {
            rawPath = String(originForm[..<question])
            rawQuery = String(originForm[originForm.index(after: question)...])
        } else {
            rawPath = originForm
            rawQuery = ""
        }
        // Decoding happens exactly once, here. A second decode would turn a literal
        // "%2e%2e" into ".." and re-open the traversal hole the resolver closes.
        guard let path = rawPath.removingPercentEncoding else { return nil }
        guard !path.contains("\0"), !path.contains("\\") else { return nil }
        return (path, Self.parseQuery(rawQuery))
    }

    private static func parseQuery(_ rawQuery: String) -> [String: String] {
        var query: [String: String] = [:]
        guard !rawQuery.isEmpty else { return query }
        for pair in rawQuery.components(separatedBy: "&") where !pair.isEmpty {
            guard let equals = pair.firstIndex(of: "=") else {
                if let key = pair.removingPercentEncoding { query[key] = "" }
                continue
            }
            let rawKey = String(pair[..<equals])
            let rawValue = String(pair[pair.index(after: equals)...])
            guard let key = rawKey.removingPercentEncoding else { continue }
            query[key] = rawValue.removingPercentEncoding ?? rawValue
        }
        return query
    }

    private static func wantsKeepAlive(version: String, connection: String?) -> Bool {
        if let connection {
            let lowered = connection.lowercased()
            if lowered.contains("close") { return false }
            if version == "HTTP/1.1" || lowered.contains("keep-alive") { return true }
            return false
        }
        return version == "HTTP/1.1"
    }

    /// Offsets of the end of the head and the start of the body, tolerating CRLF and bare LF
    /// line endings. Returns nil while the terminating blank line has not arrived.
    private func headerEnd(in buffer: Data) -> (headEnd: Int, bodyStart: Int)? {
        guard buffer.count >= 2 else { return nil }
        return buffer.withUnsafeBytes { raw -> (headEnd: Int, bodyStart: Int)? in
            var index = 1
            while index < raw.count {
                defer { index += 1 }
                guard raw[index] == 0x0a else { continue }
                let next = index + 1
                if next < raw.count, raw[next] == 0x0a {
                    return (Self.headEnd(before: index, raw: raw), next + 1)
                }
                if next + 1 < raw.count, raw[next] == 0x0d, raw[next + 1] == 0x0a {
                    return (Self.headEnd(before: index, raw: raw), next + 2)
                }
            }
            return nil
        }
    }

    /// Drop the CR that belongs to the blank line so the head never ends with a stray byte.
    private static func headEnd(before lineFeed: Int, raw: UnsafeRawBufferPointer) -> Int {
        lineFeed > 0 && raw[lineFeed - 1] == 0x0d ? lineFeed - 1 : lineFeed
    }
}

/// RFC 1123 `Date` header, built from value types so any thread may call it.
enum PlatformHTTPDate {
    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func headerValue(for date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
        guard let weekday = parts.weekday, let month = parts.month,
              let day = parts.day, let year = parts.year,
              let hour = parts.hour, let minute = parts.minute, let second = parts.second else {
            return "Thu, 01 Jan 1970 00:00:00 GMT"
        }
        return String(format: "%@, %02d %@ %04d %02d:%02d:%02d GMT",
                      weekdays[(weekday - 1) % 7], day, months[month - 1], year, hour, minute, second)
    }
}
