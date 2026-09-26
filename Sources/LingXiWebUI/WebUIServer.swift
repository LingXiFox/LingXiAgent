import Foundation
import LingXiProtocol
import LingXiApplication
import LingXiPlatform

/// JSON settings shared by every WebUI response so encoding stays deterministic
/// across reconnects (the browser diffs payloads by revision, not by bytes).
enum WebJSON {
    /// Deliberately the contract's own codec rather than a WebUI-private one: dates stay
    /// seconds-since-1970 like every other Codable wire type in this repo.
    static var encoder: JSONEncoder { FrontendWire.makeEncoder() }
    static var decoder: JSONDecoder { FrontendWire.makeDecoder() }

    static func data<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let raw = try encoder.encode(value) as Data?,
              let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw CoreError(code: .transport, message: "WebUI frame did not encode to a JSON object")
        }
        return json
    }
}

/// One pump per serve session: the single consumer of `FrontendRuntime.updates`.
/// SSE clients attach and detach freely (refresh, new tab, dropped network) without
/// ever touching the Core session, which is the whole point of the Frontend contract.
actor WebUIHub {
    private let runtime: any FrontendRuntime
    private let options: WebUIServeOptions

    private var pumpTask: Task<Void, Never>?
    private var lastRevision: UInt64 = 0
    private var lastUpdate: ApplicationUpdate?
    private var cachedSnapshot: (revision: UInt64, data: Data)?
    private var recentDeltas: [(revision: UInt64, data: Data)] = []
    private var clients: [UUID: WebUIClient] = [:]
    private var clientCountByRevision: UInt64 = 0
    private var started = false

    struct WebUIClient: Sendable {
        let id: UUID
        let continuation: AsyncStream<WebUIFrame>.Continuation
    }

    /// Frame kinds are carried pre-encoded: encoding once per revision keeps
    /// N tabs from re-encoding the same transcript.
    enum WebUIFrame: Sendable {
        case snapshot(Data)
        case delta(revision: UInt64, Data)
        case resync(Data)
        case ping
    }

    init(runtime: any FrontendRuntime, options: WebUIServeOptions) {
        self.runtime = runtime
        self.options = options
    }

    var activeClients: Int { clients.count }

    func start() {
        guard !started else { return }
        started = true
        pumpTask = Task { [weak self] in
            await self?.pump()
        }
    }

    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        for client in clients.values { client.continuation.finish() }
        clients.removeAll()
    }

    /// The update stream ends when Core goes away; surface that as a terminal event
    /// so `serve` exits instead of holding a browser tab over a dead runtime.
    var didLoseRuntime: Bool { started && pumpTask == nil }

    private func pump() async {
        let updates = await runtime.updates
        for await update in updates {
            if Task.isCancelled { return }
            lastRevision = update.revision
            lastUpdate = update
            cachedSnapshot = nil
            guard !clients.isEmpty else { continue }
            guard let delta = try? WebJSON.data(FrontendWire.delta(from: update)) else { continue }
            recentDeltas.append((update.revision, delta))
            if recentDeltas.count > 96 { recentDeltas.removeFirst(recentDeltas.count - 96) }
            for client in clients.values {
                client.continuation.yield(.delta(revision: update.revision, delta))
            }
        }
        pumpTask = nil
    }

    /// Snapshots are encoded only when a browser actually needs one: re-encoding the
    /// whole transcript on every streamed token would be quadratic on a long session.
    private func makeSnapshot() async -> Data? {
        if let cachedSnapshot, cachedSnapshot.revision == lastRevision { return cachedSnapshot.data }
        guard let update = lastUpdate else { return nil }
        let commands = await runtime.availableCommands
        guard let data = try? WebJSON.data(FrontendWire.snapshot(from: update, commands: commands)) else {
            return nil
        }
        cachedSnapshot = (update.revision, data)
        return data
    }

    /// Attach a browser stream. A gap between what the client last saw and what we
    /// buffered (or a first attach) resolves to a full snapshot, which is the only
    /// way to stay correct across duplicated / out-of-order / missed events.
    func attach(resumedFrom revision: UInt64?) async -> (UUID, AsyncStream<WebUIFrame>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<WebUIFrame>.makeStream(bufferingPolicy: .bufferingNewest(256))
        clients[id] = WebUIClient(id: id, continuation: continuation)

        let needsSnapshot: Bool
        if let revision, lastRevision >= revision, revision > 0 {
            needsSnapshot = recentDeltas.first(where: { $0.revision == revision }) == nil && revision != lastRevision
        } else {
            needsSnapshot = true
        }

        if needsSnapshot, let snapshot = await makeSnapshot() {
            continuation.yield(.snapshot(snapshot))
        } else if let revision {
            for entry in recentDeltas where entry.revision > revision {
                continuation.yield(.delta(revision: entry.revision, entry.data))
            }
        }
        return (id, stream)
    }

    func detach(_ id: UUID) {
        clients[id]?.continuation.finish()
        clients.removeValue(forKey: id)
    }

    func broadcastError(_ message: String) {
        guard let payload = try? WebJSON.data(["message": message]) else { return }
        for client in clients.values { client.continuation.yield(.resync(payload)) }
    }

    // MARK: - Client-facing operations

    func currentSnapshot() async -> Data? {
        await makeSnapshot()
    }

    func submit(_ command: FrontendCommand) async throws {
        await runtime.dispatch(ApplicationAction.from(command))
    }

    func executeRaw(_ input: String) async throws -> ApplicationCommandResult {
        try await runtime.executeCommand(input)
    }

    func references() async -> [String] {
        await runtime.workspaceReferenceCandidates()
    }

    func state() async -> ApplicationState {
        await runtime.state
    }

    var protocolRevision: UInt64 { lastRevision }
}

/// Bridges the shared Frontend contract (ApplicationState / ApplicationChangeSet /
/// ApplicationAction) onto HTTP + Server-Sent-Events. Nothing here computes agent
/// state: Core stays the single source of truth and the browser only projects it.
public final class WebUIServer: @unchecked Sendable {
    private let options: WebUIServeOptions
    private let server: PlatformHTTPServer
    private let hub: WebUIHub
    private let accessToken: String
    private let assetsRoot: URL
    private let startedAt = Date()
    private var keepAlive: Task<Void, Never>?

    public init(runtime: any FrontendRuntime, options: WebUIServeOptions) throws {
        self.options = options
        self.hub = WebUIHub(runtime: runtime, options: options)
        self.accessToken = options.accessToken ?? WebUIServer.makeToken()
        self.assetsRoot = try WebUIServer.resolveAssets(options: options)

        var configuration = PlatformHTTPServer.Configuration()
        configuration.host = options.bindHost
        configuration.port = options.port
        configuration.maxBodyBytes = 32 * 1024 * 1024
        self.server = try PlatformHTTPServer(configuration: configuration)
    }

    public var port: UInt16 { server.port }
    public var token: String { accessToken }
    /// For a remote bind the token rides in the URL fragment: fragments are never sent to
    /// the server, so it stays out of logs and Referer while surviving a page refresh.
    public var baseURL: String {
        let origin = "http://\(options.displayHost):\(server.port)/"
        return options.isLoopbackHost ? origin : "\(origin)#t=\(accessToken)"
    }

    // MARK: - Lifecycle

    public func start(terminal: WebUITerminal) async throws {
        registerRoutes(terminal: terminal)
        server.guardRequest = { [weak self] request in
            self?.rejectForeignRequest(request)
        }
        try server.start()
        await hub.start()
        if options.idleShutdownSeconds > 0 {
            keepAlive = Task { [weak self] in
                await self?.watchIdle(terminal: terminal)
            }
        }
    }

    public func stop() {
        keepAlive?.cancel()
        keepAlive = nil
        server.stop()
        Task { await self.hub.stop() }
    }

    private func watchIdle(terminal: WebUITerminal) async {
        let limit = options.idleShutdownSeconds
        var idleSeconds = 0.0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            let clients = await hub.activeClients
            idleSeconds = clients == 0 ? idleSeconds + 1 : 0
            if idleSeconds >= limit {
                terminal.stop(reason: "no connected browser for \(Int(limit))s")
                return
            }
        }
    }

    // MARK: - Security boundary

    /// Rejects cross-site request forgery against a loopback agent controller:
    /// a foreign page cannot send the custom header (it would need a CORS preflight
    /// we never grant) and its Origin will not match.
    private func rejectForeignRequest(_ request: PlatformHTTPRequest) -> PlatformHTTPResponse? {
        let isAsset = !request.path.hasPrefix("/api/")
        guard !options.disableBrowserGuard else { return nil }

        if let origin = request.headers["origin"], !origin.isEmpty, origin != "null" {
            guard let originHost = URL(string: origin)?.host,
                  let boundHost = URL(string: "http://\(options.displayHost)")?.host,
                  originHost.lowercased() == boundHost.lowercased() else {
                return .json(status: 403, value: Data("{\"error\":\"foreign origin\"}".utf8))
            }
        }

        if !isAsset {
            if request.method != "GET" && request.headers["x-lingxi-client"] == nil {
                return .json(status: 403, value: Data("{\"error\":\"missing client header\"}".utf8))
            }
            if !options.isLoopbackHost {
                let provided = request.headers["x-lingxi-token"]
                    ?? request.query["token"]
                    ?? bearer(request.headers["authorization"])
                guard provided == accessToken else {
                    return .json(status: 401, value: Data("{\"error\":\"token required\"}".utf8))
                }
            }
        }
        return nil
    }

    private func bearer(_ header: String?) -> String? {
        guard let header, header.lowercased().hasPrefix("bearer ") else { return nil }
        return String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Routes

    private func registerRoutes(terminal: WebUITerminal) {
        server.route("GET", "/api/hello") { [weak self] _ in
            guard let self else { return .notFound }
            let payload = WebHello(
                protocolVersion: WebUIContract.protocolVersion,
                title: "LingXiAgent",
                bindHost: self.options.host,
                loopbackOnly: self.options.isLoopbackHost,
                token: self.options.isLoopbackHost ? nil : self.accessToken,
                startedAt: self.startedAt
            )
            return Self.json(payload)
        }

        server.route("GET", "/api/state") { [weak self] _ in
            guard let self, let data = await self.hub.currentSnapshot() else { return .notFound }
            return .data(status: 200, contentType: "application/json; charset=utf-8", value: data)
        }

        server.route("POST", "/api/command") { [weak self] request in
            guard let self else { return .notFound }
            do {
                let command = try WebJSON.decoder.decode(FrontendCommand.self, from: request.body)
                try await self.hub.submit(command)
                return Self.json(["ok": true])
            } catch {
                return Self.errorResponse(error)
            }
        }

        server.route("POST", "/api/exec") { [weak self] request in
            guard let self else { return .notFound }
            struct ExecBody: Decodable { let input: String }
            do {
                let body = try WebJSON.decoder.decode(ExecBody.self, from: request.body)
                let result = try await self.hub.executeRaw(body.input)
                return Self.json(["output": result.output])
            } catch {
                return Self.errorResponse(error)
            }
        }

        server.route("GET", "/api/references") { [weak self] _ in
            guard let self else { return .notFound }
            let values = await self.hub.references()
            return Self.json(values)
        }

        server.route("POST", "/api/upload") { [weak self] request in
            guard let self else { return .notFound }
            do {
                let path = try self.storeUpload(request)
                return Self.json(["path": path])
            } catch {
                return Self.errorResponse(error)
            }
        }

        server.route("POST", "/api/shutdown") { [weak self] request in
            guard let self else { return .notFound }
            guard self.options.isLoopbackHost || request.headers["x-lingxi-token"] == self.accessToken else {
                return .json(status: 401, value: Data("{\"error\":\"token required\"}".utf8))
            }
            terminal.stop(reason: "requested from WebUI")
            return Self.json(["ok": true])
        }

        // One live pump fans out to every tab; the SSE id is the revision, so a
        // reconnect can resume exactly where the browser left off.
        server.route("GET", "/api/stream") { [weak self] request in
            guard let self else { return .notFound }
            let resume = UInt64(request.headers["last-event-id"] ?? request.query["last"] ?? "")
            let (clientID, stream) = await self.hub.attach(resumedFrom: resume)
            let hub = self.hub
            return .stream(headers: ["X-Accel-Buffering": "no"]) { writer in
                for await frame in stream {
                    if await writer.isCancelled { break }
                    let ok: Bool
                    switch frame {
                    case .snapshot(let data):
                        ok = await WebUIServer.writeSSE(writer, event: "snapshot", data: data, id: nil)
                    case .delta(let revision, let data):
                        ok = await WebUIServer.writeSSE(writer, event: "delta", data: data, id: String(revision))
                    case .resync(let data):
                        ok = await WebUIServer.writeSSE(writer, event: "resync", data: data, id: nil)
                    case .ping:
                        ok = await writer.write(Data(": ping\n\n".utf8))
                    }
                    if !ok { break }
                }
                await hub.detach(clientID)
            }
        }

        server.serveStatic(directory: assetsRoot, at: "/")
    }

    private func storeUpload(_ request: PlatformHTTPRequest) throws -> String {
        let name = request.query["name"] ?? "upload.bin"
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .prefix(120)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxiagent-webui", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(String(cleaned))
        try request.body.write(to: target, options: .atomic)
        return target.path
    }

    private static func writeSSE(
        _ writer: PlatformHTTPWriter,
        event: String,
        data: Data,
        id: String?
    ) async -> Bool {
        var frame = Data()
        if let id { frame.append(Data("id: \(id)\n".utf8)) }
        frame.append(Data("event: \(event)\n".utf8))
        frame.append(Data("data: ".utf8))
        frame.append(data)
        frame.append(Data("\n\n".utf8))
        return await writer.write(frame)
    }

    static func json<T: Encodable>(_ value: T) -> PlatformHTTPResponse {
        guard let data = try? WebJSON.data(value) else {
            return .json(status: 500, value: Data("{\"error\":\"encode failed\"}".utf8))
        }
        return .data(status: 200, contentType: "application/json; charset=utf-8", value: data)
    }

    static func errorResponse(_ error: Error) -> PlatformHTTPResponse {
        let payload: [String: Any] = ["error": error.localizedDescription]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return .data(status: 400, contentType: "application/json; charset=utf-8", value: data)
    }

    static func makeToken() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Release builds read assets from the copied resource bundle; a checkout can
    /// point at the source tree (or `--assets`) so editing HTML/CSS only needs a refresh.
    static func resolveAssets(options: WebUIServeOptions) throws -> URL {
        let fileManager = FileManager.default
        func usable(_ url: URL) -> Bool {
            fileManager.fileExists(atPath: url.appendingPathComponent("index.html").path)
        }
        if let override = options.assetDirectory, !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            if usable(url) { return url }
        }
        if let env = ProcessInfo.processInfo.environment["LINGXI_WEB_ASSETS"], !env.isEmpty {
            let url = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
            if usable(url) { return url }
        }
        for candidate in assetBundleCandidates(sourceRelative: "Sources/LingXiWebUI/Assets") {
            if usable(candidate) { return candidate }
        }
        throw CoreError(code: .transport, message: "WebUI assets were not found next to the executable")
    }

    private static func assetBundleCandidates(sourceRelative: String) -> [URL] {
        var list: [URL] = []
        #if SWIFT_PACKAGE
        let bundleURL = Bundle.module.resourceURL ?? Bundle.module.bundleURL
        list.append(bundleURL.appendingPathComponent("Assets", isDirectory: true))
        list.append(bundleURL)
        #endif
        if let resource = Bundle.main.resourceURL {
            list.append(resource.appendingPathComponent("Assets", isDirectory: true))
            list.append(resource.appendingPathComponent("LingXiAgent_LingXiWebUI.bundle/Assets", isDirectory: true))
            list.append(resource.appendingPathComponent("LingXiAgent_LingXiWebUI.bundle", isDirectory: true))
            list.append(resource)
        }
        let execDir = URL(fileURLWithPath: CommandLine.arguments.first ?? ".", isDirectory: false)
            .deletingLastPathComponent()
        list.append(execDir.appendingPathComponent("Assets", isDirectory: true))
        list.append(execDir.appendingPathComponent("LingXiAgent_LingXiWebUI.bundle/Assets", isDirectory: true))
        // Debug convenience inside a checkout: .build/<config>/ -> repo root.
        var parent = execDir
        for _ in 0..<4 {
            parent = parent.deletingLastPathComponent()
            list.append(parent.appendingPathComponent(sourceRelative, isDirectory: true))
        }
        return list
    }

    static func missingAssetsHTML(port: UInt16) -> String {
        """
        <!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><title>LingXiAgent</title>
        <style>body{background:#121110;color:#F1EEEB;font:14px/1.7 -apple-system,system-ui,sans-serif;
        display:grid;place-items:center;height:100vh;margin:0}code{color:#F28A55}</style></head>
        <body><div><h1>WebUI 资源未找到</h1>
        <p>服务已监听在 <code>127.0.0.1:\(port)</code>，但没有找到打包的界面资源。</p>
        <p>开发时加 <code>--assets Sources/LingXiWebUI/Assets</code>，或让发布构建携带 <code>LingXiAgent_LingXiWebUI.bundle</code>。</p>
        </div></body></html>
        """
    }
}

struct WebHello: Encodable {
    let protocolVersion: String
    let title: String
    let bindHost: String
    let loopbackOnly: Bool
    let token: String?
    let startedAt: Date
}

enum WebUIContract {
    static let protocolVersion = FrontendWire.protocolVersion
}

/// Lets any subsystem (routes, signal handlers, idle watchdog) end the serve session.
public final class WebUITerminal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var stopped = false
    private(set) var reason: String?

    public init() {}

    public var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    public func stop(reason: String? = nil) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        self.reason = reason
        let waiting = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    public func waitUntilStopped() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if stopped {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}
