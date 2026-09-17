import Foundation
import LingXiProtocol
import LingXiPlatform

public struct BrowserHostHandshakeResult: Sendable, Codable {
    public let protocolVersion: String
    public let hostVersion: String
    public let playwrightAvailable: Bool
    public let capabilities: [String]
}

/// Browser Host Sidecar 客户端封装。
/// 通过 StdioTransport + LineDelimitedJSONFramer + JSONRPCPeer 与 Node.js Browser Host 通信。
public final class BrowserHostClient: @unchecked Sendable {
    private let peer: JSONRPCPeer
    private var nextID: Int = 1
    private let lock = NSLock()

    public init(peer: JSONRPCPeer) {
        self.peer = peer
    }

    public init(executablePath: String = "/usr/bin/env", scriptPath: String) {
        let managedProc = ManagedProcess(
            executablePath: executablePath,
            arguments: ["node", scriptPath]
        )
        let transport = StdioTransport(managedProcess: managedProc)
        let framer = LineDelimitedJSONFramer()
        self.peer = JSONRPCPeer(transport: transport, framer: framer)
    }

    public func start() throws {
        try peer.start()
    }

    public func stop() {
        peer.stop()
    }

    private func allocateID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    /// 执行 initialize 握手
    public func initialize() async throws -> BrowserHostHandshakeResult {
        let reqID = allocateID()
        let resData = try await peer.request(id: reqID, method: "initialize", parameters: nil)
        return try JSONDecoder().decode(BrowserHostHandshakeResult.self, from: resData)
    }

    /// 创建一个浏览器页面会话
    public func createSession(sessionID: String) async throws -> String {
        let reqID = allocateID()
        let params: [String: Any] = ["sessionID": sessionID]
        let paramData = try JSONSerialization.data(withJSONObject: params)
        let resData = try await peer.request(id: reqID, method: "session.create", parameters: paramData)
        guard let obj = try? JSONSerialization.jsonObject(with: resData) as? [String: Any],
              let id = obj["sessionID"] as? String else {
            return sessionID
        }
        return id
    }

    /// 页面跳转
    public func navigate(sessionID: String, url: String) async throws -> (url: String, title: String, version: Int64) {
        let reqID = allocateID()
        let params: [String: Any] = ["sessionID": sessionID, "url": url]
        let paramData = try JSONSerialization.data(withJSONObject: params)
        let resData = try await peer.request(id: reqID, method: "session.navigate", parameters: paramData)
        guard let obj = try? JSONSerialization.jsonObject(with: resData) as? [String: Any] else {
            throw InteractionError.protocolViolation(.invalidFramePayload)
        }
        let navigatedURL = (obj["url"] as? String) ?? url
        let title = (obj["title"] as? String) ?? ""
        let version = (obj["version"] as? NSNumber)?.int64Value ?? 1
        return (navigatedURL, title, version)
    }

    /// 获取当前页面的 DOM 与快照
    public func snapshot(sessionID: String) async throws -> Observation {
        let reqID = allocateID()
        let params: [String: Any] = ["sessionID": sessionID]
        let paramData = try JSONSerialization.data(withJSONObject: params)
        let resData = try await peer.request(id: reqID, method: "session.snapshot", parameters: paramData)
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
            screenshotBlobRef: screenshotBase64 != nil ? "data:image/jpeg;base64,\(screenshotBase64!.prefix(32))..." : nil,
            viewportBounds: displayBounds,
            displayMetrics: metrics
        )
    }

    /// 在页面上执行动作
    public func performAction(sessionID: String, actionType: String, x: Double? = nil, y: Double? = nil, text: String? = nil, ms: Int? = nil) async throws {
        let reqID = allocateID()
        var actDict: [String: Any] = ["type": actionType]
        if let x { actDict["x"] = x }
        if let y { actDict["y"] = y }
        if let text { actDict["text"] = text }
        if let ms { actDict["milliseconds"] = ms }

        let params: [String: Any] = ["sessionID": sessionID, "action": actDict]
        let paramData = try JSONSerialization.data(withJSONObject: params)
        _ = try await peer.request(id: reqID, method: "session.act", parameters: paramData)
    }

    /// 关闭会话
    public func closeSession(sessionID: String) async throws {
        let reqID = allocateID()
        let params: [String: Any] = ["sessionID": sessionID]
        let paramData = try JSONSerialization.data(withJSONObject: params)
        _ = try? await peer.request(id: reqID, method: "session.close", parameters: paramData)
    }
}
