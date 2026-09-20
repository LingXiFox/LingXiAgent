import Foundation
import LingXiProtocol
import LingXiPlatform

public enum BrowserHostMode: String, Sendable, Codable {
    case real
    case mock
}

public struct BrowserHostHandshakeResult: Sendable, Codable {
    public let protocolVersion: String
    public let hostVersion: String
    public let mode: String?
    public let playwrightAvailable: Bool
    public let capabilities: [String]
}

/// Browser Host Sidecar 客户端封装。
/// 通过 StdioTransport + LineDelimitedJSONFramer + JSONRPCPeer 与 Node.js Browser Host 通信。
///
/// 具备全链路超时与取消保证、Real/Mock 严格模式隔离、防陈旧引用与图像开销解耦能力。
public final class BrowserHostClient: @unchecked Sendable {
    private let peer: JSONRPCPeer
    private let transport: StdioTransport?
    private let expectedMode: BrowserHostMode
    private var nextID: Int = 1
    private let lock = NSLock()

    public init(peer: JSONRPCPeer, transport: StdioTransport? = nil, expectedMode: BrowserHostMode = .real) {
        self.peer = peer
        self.transport = transport
        self.expectedMode = expectedMode
    }

    public static func resolveNodeExecutable() -> (executable: String, extraArgs: [String]) {
        if let envNode = ProcessInfo.processInfo.environment["LINGXI_NODE_PATH"],
           !envNode.isEmpty,
           FileManager.default.fileExists(atPath: envNode) {
            return (envNode, [])
        }

        #if os(macOS)
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return (c, [])
        }
        #elseif os(Linux)
        let candidates = [
            "/usr/bin/node",
            "/usr/local/bin/node"
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return (c, [])
        }
        #elseif os(Windows)
        return ("node.exe", [])
        #endif

        return ("/usr/bin/env", ["node"])
    }

    public init(
        executablePath: String? = nil,
        scriptPath: String,
        mode: BrowserHostMode = .real
    ) {
        self.expectedMode = mode
        let resolvedExec: String
        var args: [String] = []

        if let executablePath {
            resolvedExec = executablePath
            args = [scriptPath]
        } else {
            let (exec, extra) = Self.resolveNodeExecutable()
            resolvedExec = exec
            args = extra + [scriptPath]
        }

        var procEnv = ProcessInfo.processInfo.environment
        procEnv["LINGXI_BROWSER_HOST_MODE"] = mode.rawValue

        let managedProc = ManagedProcess(
            executablePath: resolvedExec,
            arguments: args,
            environment: procEnv
        )
        let transport = StdioTransport(managedProcess: managedProc)
        let framer = LineDelimitedJSONFramer()
        self.transport = transport
        self.peer = JSONRPCPeer(transport: transport, framer: framer)
    }

    public func recentStderr(maxBytes: Int = 4096) -> String {
        transport?.recentStderr(maxBytes: maxBytes) ?? ""
    }

    public func start() throws {
        try peer.start()
    }

    public func stop() {
        peer.stop()
        transport?.close()
    }

    deinit {
        stop()
    }

    private func allocateID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    /// 执行 initialize 握手并实施 Real 模式强校验
    public func initialize(timeout: TimeInterval = 10.0) async throws -> BrowserHostHandshakeResult {
        let reqID = allocateID()
        let resData: Data
        do {
            resData = try await peer.request(id: reqID, method: "initialize", parameters: nil, timeoutSeconds: timeout)
        } catch let rpcError as JSONRPCError {
            if case let .remoteError(code, message) = rpcError, code == -32001 {
                throw InteractionError.capability(
                    .featureUnsupported(
                        feature: "BrowserHost",
                        reason: message
                    )
                )
            }
            throw rpcError
        }

        let handshake = try JSONDecoder().decode(BrowserHostHandshakeResult.self, from: resData)

        if expectedMode == .real && !handshake.playwrightAvailable {
            throw InteractionError.capability(
                .featureUnsupported(
                    feature: "BrowserHost",
                    reason: "Sidecar initialized in 'real' mode but Playwright runtime is unavailable"
                )
            )
        }

        return handshake
    }

    /// 创建一个浏览器页面会话
    public func createSession(sessionID: String, timeout: TimeInterval = 15.0) async throws -> String {
        let reqID = allocateID()
        let params: [String: Any] = ["sessionID": sessionID]
        let paramData = try JSONSerialization.data(withJSONObject: params)
        let resData = try await peer.request(id: reqID, method: "session.create", parameters: paramData, timeoutSeconds: timeout)
        guard let obj = try? JSONSerialization.jsonObject(with: resData) as? [String: Any],
              let id = obj["sessionID"] as? String else {
            return sessionID
        }
        return id
    }

    /// 页面跳转
    public func navigate(
        sessionID: String,
        url: String,
        timeout: TimeInterval = 30.0
    ) async throws -> (url: String, title: String, version: Int64) {
        let reqID = allocateID()
        let params: [String: Any] = ["sessionID": sessionID, "url": url]
        let paramData = try JSONSerialization.data(withJSONObject: params)
        let resData = try await peer.request(id: reqID, method: "session.navigate", parameters: paramData, timeoutSeconds: timeout)
        guard let obj = try? JSONSerialization.jsonObject(with: resData) as? [String: Any] else {
            throw InteractionError.protocolViolation(.invalidFramePayload)
        }
        let navigatedURL = (obj["url"] as? String) ?? url
        let title = (obj["title"] as? String) ?? ""
        let version = (obj["version"] as? NSNumber)?.int64Value ?? 1
        return (navigatedURL, title, version)
    }

    /// 获取当前页面的 DOM 与快照（默认 includeScreenshot: false 消除冗余图像搬运）
    public func snapshot(
        sessionID: String,
        includeScreenshot: Bool = false,
        timeout: TimeInterval = 10.0
    ) async throws -> Observation {
        let reqID = allocateID()
        let params: [String: Any] = [
            "sessionID": sessionID,
            "includeScreenshot": includeScreenshot
        ]
        let paramData = try JSONSerialization.data(withJSONObject: params)
        let resData = try await peer.request(id: reqID, method: "session.snapshot", parameters: paramData, timeoutSeconds: timeout)
        guard let obj = try? JSONSerialization.jsonObject(with: resData) as? [String: Any] else {
            throw InteractionError.protocolViolation(.invalidFramePayload)
        }

        let envSession = EnvironmentSessionID(rawValue: sessionID)
        let version = (obj["version"] as? NSNumber)?.int64Value ?? 1
        let url = (obj["url"] as? String) ?? "about:blank"
        let title = (obj["title"] as? String) ?? ""
        let screenshotBase64 = obj["screenshotBase64"] as? String

        let displayBounds = CoordinateRect(
            origin: TargetPosition(x: 0, y: 0, space: .browserViewport(tabID: sessionID)),
            width: 1280,
            height: 800
        )
        let metrics = DisplayMetrics(
            displayID: "browser-viewport",
            scaleFactor: 1.0,
            bounds: displayBounds
        )

        var elementsMap: [ElementRef: AccessibilityNodeSnapshot] = [:]

        if let rawElements = obj["elements"] as? [String: [String: Any]] {
            for (key, elData) in rawElements {
                let refIndex = (elData["refIndex"] as? NSNumber)?.intValue ?? 1
                let ref = ElementRef(sessionID: envSession, scopeID: sessionID, version: version, index: refIndex)

                let x = (elData["x"] as? NSNumber)?.doubleValue ?? 0
                let y = (elData["y"] as? NSNumber)?.doubleValue ?? 0
                let w = (elData["width"] as? NSNumber)?.doubleValue ?? 0
                let h = (elData["height"] as? NSNumber)?.doubleValue ?? 0

                let node = AccessibilityNodeSnapshot(
                    id: (elData["id"] as? String) ?? key,
                    role: (elData["role"] as? String) ?? "element",
                    name: elData["name"] as? String,
                    value: elData["value"] as? String,
                    isInteractable: (elData["isInteractable"] as? Bool) ?? true,
                    bounds: CoordinateRect(
                        origin: TargetPosition(x: x, y: y, space: .browserViewport(tabID: sessionID)),
                        width: w,
                        height: h
                    )
                )
                elementsMap[ref] = node
            }
        }

        return Observation(
            id: ObservationID(),
            sessionID: envSession,
            version: version,
            observedAt: Date(),
            source: .browser(tabID: sessionID, url: url, title: title),
            elements: elementsMap,
            screenshotBlobRef: {
                guard let b64 = screenshotBase64, !b64.isEmpty, let imgData = Data(base64Encoded: b64) else { return nil }
                let digest = LingXiPlatform.crypto.sha256Hex(imgData)
                let contentDir = CoreStorageLayout.current.content
                try? FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
                try? imgData.write(to: contentDir.appendingPathComponent("\(digest).jpg"))
                return "content://sha256:\(digest)"
            }(),
            viewportBounds: displayBounds,
            displayMetrics: metrics
        )
    }

    /// 独立页面截屏（支持直接落盘或获取图像）
    public func capture(
        sessionID: String,
        savePath: String? = nil,
        timeout: TimeInterval = 15.0
    ) async throws -> (path: String?, base64: String?) {
        let reqID = allocateID()
        var params: [String: Any] = ["sessionID": sessionID]
        if let savePath { params["savePath"] = savePath }
        let paramData = try JSONSerialization.data(withJSONObject: params)
        let resData = try await peer.request(id: reqID, method: "session.capture", parameters: paramData, timeoutSeconds: timeout)
        guard let obj = try? JSONSerialization.jsonObject(with: resData) as? [String: Any] else {
            throw InteractionError.protocolViolation(.invalidFramePayload)
        }
        let path = obj["path"] as? String
        let base64 = obj["screenshotBase64"] as? String
        return (path, base64)
    }

    /// 在页面上执行动作（带版本与陈旧引用防护）
    public func performAction(
        sessionID: String,
        actionType: String,
        refIndex: Int? = nil,
        version: Int64? = nil,
        x: Double? = nil,
        y: Double? = nil,
        text: String? = nil,
        ms: Int? = nil,
        allowCoordinateFallback: Bool = false,
        timeout: TimeInterval = 15.0
    ) async throws {
        let reqID = allocateID()
        var actDict: [String: Any] = ["type": actionType]
        if let refIndex { actDict["refIndex"] = refIndex }
        if let version { actDict["version"] = version }
        if let x { actDict["x"] = x }
        if let y { actDict["y"] = y }
        if let text { actDict["text"] = text }
        if let ms { actDict["milliseconds"] = ms }
        actDict["allowCoordinateFallback"] = allowCoordinateFallback

        let params: [String: Any] = ["sessionID": sessionID, "action": actDict]
        let paramData = try JSONSerialization.data(withJSONObject: params)
        _ = try await peer.request(id: reqID, method: "session.act", parameters: paramData, timeoutSeconds: timeout)
    }

    /// 关闭会话
    public func closeSession(sessionID: String, timeout: TimeInterval = 5.0) async throws {
        let reqID = allocateID()
        let params: [String: Any] = ["sessionID": sessionID]
        let paramData = try JSONSerialization.data(withJSONObject: params)
        _ = try? await peer.request(id: reqID, method: "session.close", parameters: paramData, timeoutSeconds: timeout)
    }
}
