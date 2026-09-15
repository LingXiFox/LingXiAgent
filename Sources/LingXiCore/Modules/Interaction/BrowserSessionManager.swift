import Foundation
import LingXiProtocol
import LingXiPlatform

public struct BrowserSessionState: Sendable {
    public let sessionID: String
    public var currentURL: String
    public var currentTitle: String
    public var latestObservation: Observation?
}

/// 浏览器交互会话中枢 (BrowserSessionManager Actor)。
/// 负责管理与外部 Browser Host Sidecar 的长连接、页面上下文与精简 Observation 投影。
public actor BrowserSessionManager {
    public static let shared = BrowserSessionManager()

    private var hostClient: BrowserHostClient?
    private var sessions: [String: BrowserSessionState] = [:]
    private var scriptPath: String

    public init(hostClient: BrowserHostClient? = nil, scriptPath: String? = nil) {
        self.hostClient = hostClient
        if let scriptPath {
            self.scriptPath = scriptPath
        } else {
            // 自动寻找工作区内置的 Sidecar 脚本路径
            let cwd = FileManager.default.currentDirectoryPath
            self.scriptPath = "\(cwd)/Sidecars/browser-host/index.mjs"
        }
    }

    private func ensureClient() async throws -> BrowserHostClient {
        if let client = hostClient {
            return client
        }
        let client = BrowserHostClient(scriptPath: scriptPath)
        try client.start()
        _ = try await client.initialize()
        self.hostClient = client
        return client
    }

    /// 导航到指定 URL 并抓取首帧精简 Observation
    public func navigate(sessionID: String, url: String) async throws -> String {
        let client = try await ensureClient()
        _ = try await client.createSession(sessionID: sessionID)
        let navResult = try await client.navigate(sessionID: sessionID, url: url)

        let obs = try await client.snapshot(sessionID: sessionID)
        sessions[sessionID] = BrowserSessionState(
            sessionID: sessionID,
            currentURL: navResult.url,
            currentTitle: navResult.title,
            latestObservation: obs
        )

        return formatObservationSummary(obs)
    }

    /// 执行点击或输入动作
    public func act(
        sessionID: String,
        actionType: String,
        refString: String?,
        text: String? = nil
    ) async throws -> String {
        let client = try await ensureClient()
        guard var state = sessions[sessionID], let currentObs = state.latestObservation else {
            throw InteractionError.staleReference(.scopeMismatch(expectedScope: sessionID, currentScope: "None"))
        }

        var targetX: Double? = nil
        var targetY: Double? = nil

        if let refString {
            // 匹配 ref_1 或 ref_1@v2
            guard let matchedRef = currentObs.elements.keys.first(where: {
                $0.description == refString || "ref_\($0.index)" == refString
            }) else {
                throw InteractionError.staleReference(.elementDisappeared(ref: ElementRef(
                    sessionID: EnvironmentSessionID(rawValue: sessionID),
                    scopeID: sessionID,
                    version: currentObs.version,
                    index: -1
                )))
            }

            guard let node = currentObs.elements[matchedRef], let bounds = node.bounds else {
                throw InteractionError.actionExecution(.elementNotInteractable(ref: matchedRef, reason: "Element has no bounds"))
            }

            targetX = bounds.origin.x + bounds.width / 2.0
            targetY = bounds.origin.y + bounds.height / 2.0
        }

        try await client.performAction(
            sessionID: sessionID,
            actionType: actionType,
            x: targetX,
            y: targetY,
            text: text
        )

        // 动作完成后自动获取新帧 Observation (Semantic Trimming)
        let newObs = try await client.snapshot(sessionID: sessionID)
        state.latestObservation = newObs
        if case let .browser(_, url, _) = newObs.source {
            state.currentURL = url
        }
        if case let .browser(_, _, title) = newObs.source {
            state.currentTitle = title
        }
        sessions[sessionID] = state

        return formatObservationSummary(newObs)
    }

    /// 关闭会话
    public func close(sessionID: String) async {
        if let client = hostClient {
            try? await client.closeSession(sessionID: sessionID)
        }
        sessions.removeValue(forKey: sessionID)
    }

    /// 停止整个 Host 宿主
    public func shutdown() {
        hostClient?.stop()
        hostClient = nil
        sessions.removeAll()
    }

    /// 格式化精简语义树（Token 预算控制核心：控制在 800 tokens 左右）
    private func formatObservationSummary(_ obs: Observation) -> String {
        var lines: [String] = []
        if case let .browser(_, url, title) = obs.source {
            lines.append("URL: \(url)")
            lines.append("Title: \(title)")
        }
        lines.append("Version: v\(obs.version)")
        lines.append("\nInteractive Elements:")

        let sortedRefs = obs.elements.keys.sorted(by: { $0.index < $1.index })
        for ref in sortedRefs.prefix(30) {
            if let node = obs.elements[ref] {
                let nameStr = node.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let valueStr = node.value != nil ? " value=\"\(node.value!)\"" : ""
                let label = nameStr.isEmpty ? "" : " \"\(nameStr)\""
                lines.append("- [ref_\(ref.index)] <\(node.role)\(valueStr)>\(label)")
            }
        }
        if sortedRefs.count > 30 {
            lines.append("... (\(sortedRefs.count - 30) more elements omitted)")
        }
        return lines.joined(separator: "\n")
    }
}
