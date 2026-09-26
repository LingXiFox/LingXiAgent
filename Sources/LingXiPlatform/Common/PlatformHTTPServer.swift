import Foundation
import LingXiProtocol

/// A small HTTP/1.1 + SSE server for a local WebUI front end.
///
/// Threading model, and the reason it looks the way it does: a project scar (commit
/// "poll the Linux pipe from its own thread, not from the cooperative pool") records what
/// happens when a loop that lives inside `poll` runs on the global executor -- it holds a
/// cooperative-pool worker for as long as the peer keeps the socket open, and on a small CI
/// runner that starves the work meant to resume the caller. So no socket call in this file is
/// ever made from a `Task`:
///
///   * one `Thread` runs the accept loop,
///   * one `Thread` owns each accepted connection and is the only caller of `send`/`recv`/
///     `close` on that descriptor,
///   * route handlers and stream producers run as `Task`s and exchange bytes with the
///     connection thread through `PlatformHTTPStreamPipe`: a locked FIFO plus a
///     `DispatchSemaphore` that the thread waits on with a timeout.
///
/// Every wait is bounded, which is what lets `stop()` unhook the whole thing by shutting the
/// descriptors down and letting each loop notice the stopping flag.
public final class PlatformHTTPServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Dotted-quad IPv4 address to bind. `127.0.0.1` keeps the server on the machine;
        /// binding a routable address is allowed at this layer and policed above it.
        public var host: String = "127.0.0.1"
        /// 0 asks the kernel for an ephemeral port, which `port` then reports.
        public var port: UInt16 = 0
        /// Requests declaring a larger `Content-Length` are refused with 413.
        public var maxBodyBytes: Int = 8 * 1024 * 1024
        /// Hard budget for one request read, and the longest a connection may sit idle
        /// between requests.
        public var idleTimeoutSeconds: Double = 75
        /// Connections served at once; anything beyond gets a 503 and an immediate close.
        public var maxConnections: Int = 16
        /// Request head above this size is refused with 431.
        public var maxHeaderBytes: Int = 32 * 1024
        /// Backpressure bound for a `stream` response: a producer that outruns the socket by
        /// more than this loses its stream instead of growing the queue forever, and an SSE
        /// client simply reconnects.
        public var streamBufferBytes: Int = 4 * 1024 * 1024
        /// `Cache-Control: max-age` for static assets other than HTML.
        public var staticCacheMaxAgeSeconds: Int = 3600
        /// How long a route handler may take before the connection answers 500.
        public var handlerTimeoutSeconds: Double = 60
        /// Value of the `Server` response field.
        public var serverName: String = "lingxiagent"

        public init() {}
    }

    /// Answer for a routed request.
    public typealias Handler = @Sendable (PlatformHTTPRequest) async -> PlatformHTTPResponse
    /// Short-circuit hook consulted before routing.
    public typealias RequestGuard = @Sendable (PlatformHTTPRequest) -> PlatformHTTPResponse?
    /// Text sink for operational chatter; the caller decides where it goes.
    public typealias Log = @Sendable (String) -> Void

    private let state: ServerState

    /// Create and bind the listener. Failures surface here, before any route is registered.
    public init(configuration: Configuration) throws {
        state = try ServerState(configuration: configuration)
    }

    deinit {
        state.stop()
    }

    /// Port actually bound; valid as soon as `init` returns.
    public var port: UInt16 { state.port }

    /// Address the listener is bound to.
    public var host: String { state.configuration.host }

    /// True between `start()` and `stop()`.
    public var isRunning: Bool { state.isRunning }

    /// Number of connections being served right now.
    public var activeConnectionCount: Int { state.liveConnectionCount }

    /// Register a handler for `method` under `pathPrefix`. The longest matching prefix wins,
    /// so "/api/state" still answers when "/api" is also mounted, and registration order is
    /// irrelevant. A `GET` route also serves `HEAD`.
    public func route(_ method: String, _ pathPrefix: String, handler: @escaping Handler) {
        state.addRoute(method: method, prefix: pathPrefix, handler: handler)
    }

    /// Serve a directory of assets under `prefix`. Resolution is traversal-safe; see
    /// `PlatformStaticFileResolver`. Routes are consulted first, so an API route always beats
    /// a file of the same name.
    public func serveStatic(directory: URL, at prefix: String = "/") {
        state.addStaticMount(directory: directory, prefix: prefix)
    }

    /// Consulted for every request before routing; return a response to short-circuit it
    /// (401/403 for Origin or token checks).
    public var guardRequest: RequestGuard? {
        get { state.currentGuard }
        set { state.setGuard(newValue) }
    }

    /// Optional diagnostics sink. A closure rather than a logger so this layer keeps no
    /// dependency.
    public var log: Log? {
        get { state.currentLog }
        set { state.setLog(newValue) }
    }

    /// Start accepting. Returns immediately; the accept loop runs on its own thread.
    public func start() throws {
        try state.start()
    }

    /// Stop accepting, tear down every live connection and wait briefly for the connection
    /// threads to finish. Idempotent, and it never waits past its bound.
    public func stop() {
        state.stop()
    }
}

/// Route table entry.
struct PlatformHTTPRoute {
    let method: String
    let prefix: String
    let handler: PlatformHTTPServer.Handler
}

/// A directory mounted for static serving.
struct PlatformHTTPStaticMount {
    let prefix: String
    let directory: URL
}

/// Prefix match on path boundaries: "/api" covers "/api" and "/api/state" but not "/apiary".
func platformHTTPPrefixMatches(_ prefix: String, _ path: String) -> Bool {
    if prefix == "/" { return path.hasPrefix("/") }
    if prefix == path { return true }
    return path.hasPrefix(prefix + "/")
}

/// Everything the threads share, behind one lock.
///
/// Threads hold a strong reference to this object and never to `PlatformHTTPServer`, which is
/// what lets the server's `deinit` run at all: a connection thread keeping the server alive
/// would leave `deinit` unreachable, and a `deinit` that never runs leaves the accept loop
/// parked forever.
final class ServerState: @unchecked Sendable {
    let configuration: PlatformHTTPServer.Configuration
    let port: UInt16

    /// `stop()` waits this long for connection threads to notice and exit.
    static let drainBoundSeconds = 2.0

    private let lock = NSLock()
    private var listener: HTTPSocket = kHTTPInvalidSocket
    private var routes: [PlatformHTTPRoute] = []
    private var mounts: [PlatformHTTPStaticMount] = []
    private var requestGuard: PlatformHTTPServer.RequestGuard?
    private var logSink: PlatformHTTPServer.Log?
    private var live: [HTTPSocket: PlatformHTTPConnection] = [:]
    private var started = false
    private var acceptThreadStarted = false
    private var acceptEnded = false
    private var stopping = false
    /// Whether this instance still owes the Winsock reference `init` took. Meaningless off Windows.
    private var holdsWinsock = true
    private let drained = DispatchSemaphore(value: 0)

    /// Stop is terminal: the bound listener is closed and never reopened, so a caller that
    /// wants to serve again builds a new server.
    init(configuration: PlatformHTTPServer.Configuration) throws {
        guard PlatformHTTPSocket.beginThread() else {
            throw CoreError(code: .transport, message: "Failed to initialize Winsock on the HTTP server thread")
        }
        let backlog = Int32(truncatingIfNeeded: max(8, configuration.maxConnections * 4))
        do {
            let (socket, boundPort) = try PlatformHTTPSocket.makeListeningSocket(
                host: configuration.host,
                port: configuration.port,
                backlog: backlog
            )
            self.configuration = configuration
            self.listener = socket
            self.port = boundPort
        } catch {
            PlatformHTTPSocket.endThread()
            holdsWinsock = false
            throw error
        }
    }

    // MARK: - Shared reads

    var isRunning: Bool { read { started && !stopping } }
    var isStopping: Bool { read { stopping } }
    var liveConnectionCount: Int { read { live.count } }
    var currentGuard: PlatformHTTPServer.RequestGuard? { read { requestGuard } }
    var currentLog: PlatformHTTPServer.Log? { read { logSink } }

    func setGuard(_ value: PlatformHTTPServer.RequestGuard?) {
        lock.lock()
        requestGuard = value
        lock.unlock()
    }

    func setLog(_ value: PlatformHTTPServer.Log?) {
        lock.lock()
        logSink = value
        lock.unlock()
    }

    func log(_ message: String) {
        currentLog?(message)
    }

    /// The host the client typed, as it must appear in the `Host` field.
    var allowedPortText: String { String(port) }

    private func read<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Registration

    func addRoute(method: String, prefix: String, handler: @escaping PlatformHTTPServer.Handler) {
        let entry = PlatformHTTPRoute(method: method.uppercased(),
                                      prefix: Self.normalize(prefix),
                                      handler: handler)
        lock.lock()
        routes.append(entry)
        lock.unlock()
    }

    func addStaticMount(directory: URL, prefix: String) {
        let mount = PlatformHTTPStaticMount(prefix: Self.normalize(prefix), directory: directory)
        lock.lock()
        mounts.append(mount)
        lock.unlock()
    }

    func handler(for request: PlatformHTTPRequest) -> PlatformHTTPServer.Handler? {
        if let direct = handler(method: request.method, path: request.path) { return direct }
        // RFC 9110: a GET handler also answers HEAD, with the same fields and no octets, so
        // nobody has to register a route twice to be a correct server.
        if request.method == "HEAD" { return handler(method: "GET", path: request.path) }
        return nil
    }

    private func handler(method: String, path: String) -> PlatformHTTPServer.Handler? {
        let snapshot = read { routes }
        var best: PlatformHTTPRoute?
        for route in snapshot where route.method == method && platformHTTPPrefixMatches(route.prefix, path) {
            if best == nil || route.prefix.count > best!.prefix.count { best = route }
        }
        return best?.handler
    }

    func staticMount(for request: PlatformHTTPRequest) -> PlatformHTTPStaticMount? {
        guard request.method == "GET" || request.method == "HEAD" else { return nil }
        let snapshot = read { mounts }
        var best: PlatformHTTPStaticMount?
        for mount in snapshot where platformHTTPPrefixMatches(mount.prefix, request.path) {
            if best == nil || mount.prefix.count > best!.prefix.count { best = mount }
        }
        return best
    }

    /// Path inside the mount, with the mount prefix removed. "/" is the mounted directory
    /// itself, which the resolver answers with its index.html; both "/assets" and "/assets/"
    /// mean that, and neither may be read as a path component named "assets".
    func relativePath(for request: PlatformHTTPRequest, mount: PlatformHTTPStaticMount) -> String {
        guard mount.prefix != "/" else { return request.path }
        let remainder = String(request.path.dropFirst(mount.prefix.count))
        return remainder.isEmpty ? "/" : remainder
    }

    private static func normalize(_ prefix: String) -> String {
        var value = prefix.hasPrefix("/") ? prefix : "/" + prefix
        if value.count > 1, value.hasSuffix("/") { value = String(value.dropLast()) }
        return value
    }

    // MARK: - DNS-rebinding net

    /// Whether a `Host` field names an address that can legitimately reach this listener.
    ///
    /// This is a hard-coded safety net rather than a hook: an attacker's page can point its own
    /// domain at 127.0.0.1 and then talk to a loopback server as if it were theirs, and only the
    /// `Host` distinguishes that traffic. The interface address the socket was accepted on
    /// belongs in the set so a bind to `0.0.0.0` still answers on the address clients typed,
    /// which keeps the check from silently breaking LAN use.
    func hostIsAllowed(_ headerValue: String?, localAddress: String) -> Bool {
        guard let headerValue, !headerValue.isEmpty else { return false }
        let lowered = headerValue.lowercased()
        let allowed: Set<String> = [
            configuration.host.lowercased(), "127.0.0.1", "localhost", "[::1]", "::1",
            localAddress.lowercased(),
        ]

        if lowered.hasPrefix("[") {
            guard let close = lowered.firstIndex(of: "]") else { return false }
            let remainder = String(lowered[lowered.index(after: close)...])
            guard remainder == ":\(allowedPortText)" else { return false }
            let bracketed = String(lowered[...close])
            let bare = String(lowered[lowered.index(after: lowered.startIndex)..<close])
            return allowed.contains(bracketed) || allowed.contains(bare)
        }
        guard let colon = lowered.lastIndex(of: ":") else { return false }
        let name = String(lowered[..<colon])
        let portPart = String(lowered[lowered.index(after: colon)...])
        guard portPart == allowedPortText, !name.isEmpty else { return false }
        return allowed.contains(name)
    }

    // MARK: - Lifecycle

    func start() throws {
        lock.lock()
        if stopping {
            lock.unlock()
            throw CoreError(code: .transport, message: "PlatformHTTPServer.stop() is terminal; create a new server")
        }
        if started {
            lock.unlock()
            return
        }
        let socket = listener
        guard socket != kHTTPInvalidSocket else {
            lock.unlock()
            throw CoreError(code: .transport, message: "HTTP listener is not bound")
        }
        started = true
        acceptThreadStarted = true
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.acceptLoop(socket)
        }
        thread.name = "lingxi.http.accept"
        thread.start()
        log("HTTP listening on http://\(configuration.host):\(port)")
    }

    func stop() {
        lock.lock()
        stopping = true
        started = false
        let socketToClose = listener
        listener = kHTTPInvalidSocket
        let connections = Array(live.keys)
        lock.unlock()

        if socketToClose != kHTTPInvalidSocket {
            PlatformHTTPSocket.shutdownForClose(socketToClose)
            PlatformHTTPSocket.closeSocket(socketToClose)
        }
        // `shutdown`, never `close`: each connection thread owns its descriptor and is the only
        // one that closes it. Closing here could hand a recycled descriptor number to a thread
        // still sitting in `poll`.
        for connection in connections {
            PlatformHTTPSocket.shutdownForClose(connection)
        }
        waitForDrain()
        // The reference `init` took on the creating thread is released here, once, so a server
        // that is stopped and thrown away does not keep Winsock alive.
        lock.lock()
        let owesCleanup = holdsWinsock
        holdsWinsock = false
        lock.unlock()
        if owesCleanup { PlatformHTTPSocket.endThread() }
        log("HTTP stopped")
    }

    /// Bounded wait: every loop re-checks these flags after at most one poll slice, so the
    /// deadline is a safety net rather than the usual exit path.
    private func waitForDrain() {
        let deadline = Date().addingTimeInterval(Self.drainBoundSeconds)
        while !isDrained {
            if Date() >= deadline {
                log("HTTP stop: \(liveConnectionCount) connection(s) still finishing after \(Self.drainBoundSeconds)s")
                return
            }
            _ = drained.wait(timeout: .now() + .milliseconds(10))
        }
    }

    private var isDrained: Bool {
        read { live.isEmpty && (!acceptThreadStarted || acceptEnded) }
    }

    /// Take a connection out of the live set, waking `stop()` if that emptied it.
    ///
    /// The owning thread calls this *before* closing its descriptor: were the order reversed,
    /// `stop()` could snapshot a descriptor that was already closed and `shutdown` a number
    /// the kernel had just handed to somebody else's new connection.
    func deregisterConnection(_ socket: HTTPSocket) {
        lock.lock()
        live.removeValue(forKey: socket)
        let idle = live.isEmpty && (!acceptThreadStarted || acceptEnded)
        lock.unlock()
        if idle { drained.signal() }
    }

    // MARK: - Accept loop

    private func acceptLoop(_ socket: HTTPSocket) {
        // Only a thread that actually initialized Winsock owes the cleanup: deferring it ahead of
        // the guard made a failed startup decrement a reference this thread never took.
        guard PlatformHTTPSocket.beginThread() else {
            finishAcceptLoop()
            return
        }
        defer { PlatformHTTPSocket.endThread() }

        while true {
            if isStopping { break }
            switch PlatformHTTPSocket.waitReadable(socket, timeoutMs: 200) {
            case .timedOut:
                continue
            case .failed:
                // Listener is gone. The stopping flag is already set, so nothing else is owed.
                finishAcceptLoop()
                return
            case .ready:
                break
            }
            guard let accepted = PlatformHTTPSocket.acceptConnection(socket) else { continue }

            lock.lock()
            let stoppingNow = stopping
            let overCapacity = live.count >= configuration.maxConnections
            var connection: PlatformHTTPConnection?
            if !stoppingNow, !overCapacity {
                let candidate = PlatformHTTPConnection(state: self,
                                                       socket: accepted.socket,
                                                       peer: accepted.peer,
                                                       local: accepted.local)
                live[accepted.socket] = candidate
                connection = candidate
            }
            lock.unlock()

            if let connection {
                // Started outside the lock, so a connection never observes itself as serving
                // before it is registered against the bound.
                connection.start()
                continue
            }
            if stoppingNow {
                PlatformHTTPSocket.closeSocket(accepted.socket)
                continue
            }
            refuseOverCapacity(accepted.socket, peer: accepted.peer)
        }
        finishAcceptLoop()
    }

    /// Refuse a connection that cannot be adopted. The accept loop is still the only thread
    /// touching the descriptor, so it answers and closes in place -- and it only writes when
    /// the descriptor is writable right now, because a client that connects and never reads
    /// must not be able to park the loop that hands out every other connection.
    private func refuseOverCapacity(_ socket: HTTPSocket, peer: String) {
        defer { PlatformHTTPSocket.closeSocket(socket) }
        guard PlatformHTTPSocket.waitWritable(socket, timeoutMs: 0) == .ready else {
            log("closed \(peer) without an answer: \(configuration.maxConnections) connections in flight")
            return
        }
        _ = PlatformHTTPSocket.sendAll(socket, PlatformHTTPResponseWriter.serialize(
            .text(status: 503, body: "server is at capacity"),
            method: "GET",
            keepAlive: false,
            date: PlatformHTTPDate.headerValue(),
            serverName: configuration.serverName
        ))
        log("rejected \(peer) at capacity (\(configuration.maxConnections))")
    }

    private func finishAcceptLoop() {
        lock.lock()
        acceptEnded = true
        let idle = live.isEmpty
        lock.unlock()
        if idle { drained.signal() }
    }
}
