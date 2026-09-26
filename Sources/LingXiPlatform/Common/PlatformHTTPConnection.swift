import Foundation

/// Locked FIFO between a `stream` producer `Task` and the thread that owns the socket.
///
/// The producer never touches the descriptor, and the connection thread never blocks on
/// Swift concurrency: the only synchronisation is this queue plus a semaphore the thread waits
/// on with a timeout, so the thread always returns to watching the peer and the stopping flag.
final class PlatformHTTPStreamPipe: @unchecked Sendable {
    private enum Slot {
        case bytes(Data)
        case end
    }

    private let lock = NSLock()
    private var slots: [Slot] = []
    private var pendingBytes = 0
    private var finished = false
    private var cancelled = false
    private let byteLimit: Int
    private let arrived = DispatchSemaphore(value: 0)

    init(byteLimit: Int) {
        self.byteLimit = max(1024, byteLimit)
    }

    /// Append payload bytes. False means the producer must stop: the stream already ended, or
    /// the backlog tripped the bound and was dropped rather than allowed to grow.
    func append(_ data: Data) -> Bool {
        lock.lock()
        if cancelled || finished {
            lock.unlock()
            return false
        }
        if pendingBytes + data.count > byteLimit {
            cancelled = true
            finished = true
            slots.removeAll()
            pendingBytes = 0
            lock.unlock()
            arrived.signal()
            return false
        }
        slots.append(.bytes(data))
        pendingBytes += data.count
        lock.unlock()
        arrived.signal()
        return true
    }

    /// Producer returned: flush what is queued, then terminate the chunk stream.
    func finish() {
        lock.lock()
        if !finished {
            finished = true
            slots.append(.end)
        }
        lock.unlock()
        arrived.signal()
    }

    /// Peer is gone or the server is stopping: drop the backlog and wake the producer.
    func cancel() {
        lock.lock()
        cancelled = true
        finished = true
        slots.removeAll()
        pendingBytes = 0
        lock.unlock()
        arrived.signal()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Take everything queued; reports whether the end marker came through.
    func drain() -> (payloads: [Data], sawEnd: Bool) {
        lock.lock()
        var payloads: [Data] = []
        var sawEnd = false
        for slot in slots {
            switch slot {
            case .bytes(let data): payloads.append(data)
            case .end: sawEnd = true
            }
        }
        // Draining always consumes the whole queue, end marker included, so the caller's
        // `sawEnd` is the single source of truth for "the producer returned".
        slots = []
        pendingBytes = 0
        lock.unlock()
        return (payloads, sawEnd)
    }

    /// Wait up to `timeoutMilliseconds` for a producer to hand something over.
    func waitForWork(timeoutMilliseconds: Int32) {
        _ = arrived.wait(timeout: .now() + .milliseconds(Int(timeoutMilliseconds)))
    }
}

/// One accepted connection and the thread that owns its descriptor.
///
/// Owned by `ServerState.live` while registered and by its own thread; the descriptor is
/// closed exactly once, here, by the thread that was reading and writing it.
final class PlatformHTTPConnection: @unchecked Sendable {
    private let state: ServerState
    private let socket: HTTPSocket
    private let peer: String
    /// The address the listener was reached on, captured at accept time. It is what the `Host`
    /// check compares against, so a bind to `0.0.0.0` still answers the name the browser typed.
    private let local: String
    private var buffer = Data()

    init(state: ServerState, socket: HTTPSocket, peer: String, local: String) {
        self.state = state
        self.socket = socket
        self.peer = peer
        self.local = local
    }

    func start() {
        let thread = Thread { self.run() }
        thread.name = "lingxi.http.connection"
        thread.start()
    }

    // MARK: - Connection loop

    private func run() {
        defer {
            state.deregisterConnection(socket)
            PlatformHTTPSocket.closeSocket(socket)
        }
        guard PlatformHTTPSocket.beginThread() else { return }
        defer { PlatformHTTPSocket.endThread() }

        PlatformHTTPSocket.setNoDelay(socket)
        PlatformHTTPSocket.suppressSigPipe(socket)
        let parser = PlatformHTTPParser(maxHeaderBytes: state.configuration.maxHeaderBytes,
                                        maxBodyBytes: state.configuration.maxBodyBytes)

        var keepAlive = true
        while keepAlive && !state.isStopping {
            guard let step = readRequest(parser) else { return }
            switch step {
            case .incomplete:
                return // `readRequest` only returns once a request is whole.
            case .request(let request, let wantsKeepAlive, let consumed):
                buffer = buffer.subdata(in: consumed..<buffer.count)
                let response = dispatch(request)
                if case .stream(let headers, let producer) = response {
                    serveStream(headers: headers, producer: producer)
                    return // A stream ends its connection; the client reconnects for more.
                }
                let framing = PlatformHTTPResponseWriter.serialize(
                    response,
                    method: request.method,
                    keepAlive: wantsKeepAlive,
                    date: PlatformHTTPDate.headerValue(),
                    serverName: state.configuration.serverName
                )
                guard PlatformHTTPSocket.sendAll(socket, framing) else { return }
                keepAlive = wantsKeepAlive
            case .rejection(let status, let message):
                state.log("refused \(peer): \(status) \(message)")
                _ = PlatformHTTPSocket.sendAll(socket, PlatformHTTPResponseWriter.serialize(
                    .text(status: status, body: message),
                    method: "GET",
                    keepAlive: false,
                    date: PlatformHTTPDate.headerValue(),
                    serverName: state.configuration.serverName
                ))
                return
            }
        }
    }

    /// Fill the buffer until the parser has a whole request, then hand it over. Nil means the
    /// connection is finished and should be closed.
    private func readRequest(_ parser: PlatformHTTPParser) -> PlatformHTTPParseStep? {
        let budget = state.configuration.idleTimeoutSeconds
        let deadline = Date().addingTimeInterval(budget)
        // Bound the buffer as well, so a client that never finishes a head cannot grow it past
        // what the parser already refuses.
        let ceiling = state.configuration.maxHeaderBytes + state.configuration.maxBodyBytes + 64 * 1024

        while true {
            switch parser.consume(buffer, clientAddress: peer) {
            case .incomplete:
                break
            case let step:
                return step
            }
            if state.isStopping { return nil }
            if buffer.count > ceiling {
                return .rejection(status: 431, message: "Request too large")
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                // Nothing at all on an idle keep-alive connection is normal: close quietly.
                // Half a request is the client's problem, so answer 408 before closing.
                if buffer.isEmpty { return nil }
                return .rejection(status: 408, message: "Request timeout")
            }
            // Short slices keep stop() prompt even while a request is still arriving.
            let slice = Int32(max(1, min(remaining * 1000, 250)))
            switch PlatformHTTPSocket.waitReadable(socket, timeoutMs: slice) {
            case .timedOut:
                continue
            case .failed:
                return nil
            case .ready:
                guard let chunk = PlatformHTTPSocket.receive(socket, maxBytes: 16 * 1024) else { return nil }
                if !chunk.isEmpty {
                    buffer.append(chunk)
                }
            }
        }
    }

    // MARK: - Dispatch

    private func dispatch(_ request: PlatformHTTPRequest) -> PlatformHTTPResponse {
        guard state.hostIsAllowed(request.header("host"), localAddress: local) else {
            state.log("rejected \(peer): Host '\(request.header("host") ?? "none")' is not this server")
            return .text(status: 403, body: "forbidden host")
        }
        if let shortCircuit = state.currentGuard?(request) {
            return shortCircuit
        }
        if let handler = state.handler(for: request) {
            return awaitResponse(handler, request)
        }
        if let mount = state.staticMount(for: request) {
            return serveStaticFile(request, mount: mount)
        }
        return .notFound
    }

    /// Run an async handler off the socket thread and wait for it on a semaphore. Blocking
    /// here is safe precisely because this is a real OS thread, never a pool worker.
    private func awaitResponse(_ handler: @escaping PlatformHTTPServer.Handler,
                               _ request: PlatformHTTPRequest) -> PlatformHTTPResponse {
        let gate = DispatchSemaphore(value: 0)
        let box = PlatformHTTPResponseBox()
        let state = self.state
        Task {
            let response = await handler(request)
            box.set(response)
            gate.signal()
        }
        if gate.wait(timeout: .now() + state.configuration.handlerTimeoutSeconds) == .timedOut {
            state.log("handler for \(request.method) \(request.path) did not answer in time")
            return .text(status: 500, body: "handler timeout")
        }
        return box.value ?? .text(status: 500, body: "handler produced no response")
    }

    private func serveStaticFile(_ request: PlatformHTTPRequest, mount: PlatformHTTPStaticMount) -> PlatformHTTPResponse {
        let relative = state.relativePath(for: request, mount: mount)
        guard let asset = PlatformStaticFileResolver.resolve(root: mount.directory,
                                                            relativePath: relative,
                                                            cacheMaxAgeSeconds: state.configuration.staticCacheMaxAgeSeconds) else {
            return .notFound
        }
        // The body is buffered, so an asset larger than the request budget the server already
        // enforces is treated as absent rather than allowed to balloon memory.
        guard asset.fileSize <= state.configuration.maxBodyBytes else {
            state.log("static \(request.path) is \(asset.fileSize) bytes, over the limit")
            return .notFound
        }
        guard let contents = try? Data(contentsOf: asset.url) else { return .notFound }
        if request.method == "GET" {
            state.log("200 \(request.path) (\(contents.count) bytes)")
        }
        return .data(status: 200, contentType: asset.contentType, value: contents,
                     headers: ["Cache-Control": asset.cacheControl])
    }

    // MARK: - SSE

    /// Write a chunked SSE response. This thread does every `send`; the producer only fills
    /// the pipe.
    private func serveStream(headers: [String: String],
                             producer: @escaping @Sendable (PlatformHTTPWriter) async -> Void) {
        let configuration = state.configuration
        let pipe = PlatformHTTPStreamPipe(byteLimit: configuration.streamBufferBytes)
        let writer = PlatformHTTPStreamWriter(pipe: pipe)

        var head = PlatformHTTPHeadFields()
        head.set("Content-Type", "text/event-stream; charset=utf-8")
        head.set("Cache-Control", "no-cache")
        // A reverse proxy that buffers turns SSE into polling; this asks it not to.
        head.set("X-Accel-Buffering", "no")
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let lowered = name.lowercased()
            if lowered == "content-length" || lowered == "transfer-encoding" || lowered == "connection" {
                continue
            }
            head.set(name, value)
        }
        head.set("Date", PlatformHTTPDate.headerValue())
        head.set("Server", configuration.serverName)
        head.set("Transfer-Encoding", "chunked")
        head.set("Connection", "close")

        var preface = Data("HTTP/1.1 200 OK\r\n".utf8)
        preface.append(head.serializedData())
        preface.append(Data("\r\n".utf8))
        guard PlatformHTTPSocket.sendAll(socket, preface) else {
            pipe.cancel()
            return
        }

        let producerTask = Task { [pipe] in
            await producer(writer)
            pipe.finish()
        }

        while true {
            if state.isStopping {
                pipe.cancel()
                break
            }
            pipe.waitForWork(timeoutMilliseconds: 50)
            if pipe.isCancelled { break }
            // poll() with no wait, then a peek: a client that hung up reports EOF or a reset on
            // the read side long before the next write would fail.
            if PlatformHTTPSocket.peerGone(socket) {
                pipe.cancel()
                break
            }
            let queued = pipe.drain()
            var broken = false
            for payload in queued.payloads {
                if !PlatformHTTPSocket.sendAll(socket, Self.chunkFrame(payload)) {
                    broken = true
                    break
                }
            }
            if broken {
                pipe.cancel()
                break
            }
            if queued.sawEnd { break }
        }

        if !pipe.isCancelled {
            _ = PlatformHTTPSocket.sendAll(socket, Data("0\r\n\r\n".utf8))
        }
        pipe.cancel()
        // Structured cancellation for producers that park on a timer instead of polling
        // `isCancelled`; harmless for the ones that already finished.
        producerTask.cancel()
    }

    /// One payload per HTTP chunk, which is what flushes an SSE frame immediately.
    private static func chunkFrame(_ payload: Data) -> Data {
        var frame = Data(String(format: "%x\r\n", payload.count).utf8)
        frame.append(payload)
        frame.append(Data("\r\n".utf8))
        return frame
    }
}

/// Handoff box for a handler whose result arrives on another thread.
final class PlatformHTTPResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PlatformHTTPResponse?

    func set(_ value: PlatformHTTPResponse) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: PlatformHTTPResponse? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Writer vended to a `stream` producer; it only ever touches the pipe.
final class PlatformHTTPStreamWriter: PlatformHTTPWriter {
    private let pipe: PlatformHTTPStreamPipe

    init(pipe: PlatformHTTPStreamPipe) {
        self.pipe = pipe
    }

    @discardableResult
    func sse(id: String?, event: String, data: String) async -> Bool {
        var frame = ""
        if let id, !id.isEmpty {
            frame += "id: \(Self.sanitize(id))\n"
        }
        if !event.isEmpty {
            frame += "event: \(Self.sanitize(event))\n"
        }
        // A multi-line payload is still one event, so every continuation line needs its own
        // "data:" prefix.
        for line in data.components(separatedBy: "\n") {
            frame += "data: \(Self.sanitize(line))\n"
        }
        frame += "\n"
        return await write(Data(frame.utf8))
    }

    @discardableResult
    func write(_ chunk: Data) async -> Bool {
        if pipe.isCancelled { return false }
        // Give the socket thread a turn before the next frame, so a producer writing in a
        // tight loop cannot pile up the whole bound without it ever getting scheduled.
        await Task.yield()
        return pipe.append(chunk)
    }

    var isCancelled: Bool {
        get async { pipe.isCancelled }
    }

    /// Newlines inside a field would let a payload forge extra SSE lines.
    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
