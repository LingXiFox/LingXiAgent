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
/// 负责管理与外部 Browser Host Sidecar 的长连接、页面上下文单 Context 复用与精简 Observation 投影。
public actor BrowserSessionManager {
    public static let shared = BrowserSessionManager()

    private var hostClient: BrowserHostClient?
    private var sessions: [String: BrowserSessionState] = [:]
    private var scriptPath: String
    private var mode: BrowserHostMode

    public init(
        hostClient: BrowserHostClient? = nil,
        scriptPath: String? = nil,
        mode: BrowserHostMode? = nil
    ) {
        self.hostClient = hostClient
        
        let envModeStr = ProcessInfo.processInfo.environment["LINGXI_BROWSER_HOST_MODE"]
        let defaultMode: BrowserHostMode = (envModeStr == "mock") ? .mock : .real
        self.mode = mode ?? defaultMode

        if let scriptPath {
            self.scriptPath = scriptPath
        } else if let envPath = ProcessInfo.processInfo.environment["LINGXI_BROWSER_HOST_PATH"], !envPath.isEmpty {
            self.scriptPath = envPath
        } else {
            // 多层确定性解析：Bundle -> 进程可执行文件同级/上级 -> 工作区 cwd -> 用户全局目录
            let fm = FileManager.default
            let cwd = fm.currentDirectoryPath
            var candidates: [String] = []
            
            if let bundleResource = Bundle.main.resourcePath {
                candidates.append("\(bundleResource)/Sidecars/browser-host/index.mjs")
            }
            if let execPath = CommandLine.arguments.first {
                let execURL = URL(fileURLWithPath: execPath)
                candidates.append(execURL.deletingLastPathComponent().appendingPathComponent("Sidecars/browser-host/index.mjs").path)
                candidates.append(execURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sidecars/browser-host/index.mjs").path)
            }
            candidates.append("\(cwd)/Sidecars/browser-host/index.mjs")
            candidates.append("\(fm.homeDirectoryForCurrentUser.path)/.lingxiagent/sidecars/browser-host/index.mjs")

            let resolved = candidates.first { fm.fileExists(atPath: $0) }
            self.scriptPath = resolved ?? "\(cwd)/Sidecars/browser-host/index.mjs"
        }
    }

    private func ensureClient() async throws -> BrowserHostClient {
        if let client = hostClient {
            return client
        }
        let client = BrowserHostClient(scriptPath: scriptPath, mode: mode)
        try client.start()
        _ = try await client.initialize()
        self.hostClient = client
        return client
    }

    /// 导航到指定 URL 并抓取首帧精简 Observation。
    /// 严格遵循单 Context 复用原则：同一 sessionID 仅在首次打开时创建 Context/Page，后续直接复用既有页面进行跳转，杜绝 Chromium 实例与内存泄漏。
    public func navigate(sessionID: String, url: String) async throws -> String {
        let client = try await ensureClient()

        if sessions[sessionID] == nil {
            _ = try await client.createSession(sessionID: sessionID)
        }

        let navResult = try await client.navigate(sessionID: sessionID, url: url)

        // 默认快照不抓取大 Base64 截屏，零拷贝传输
        let obs = try await client.snapshot(sessionID: sessionID, includeScreenshot: false)
        sessions[sessionID] = BrowserSessionState(
            sessionID: sessionID,
            currentURL: navResult.url,
            currentTitle: navResult.title,
            latestObservation: obs
        )

        return formatObservationSummary(obs)
    }

    /// 显式重置并重建指定会话（安全销毁旧 Context/Page，防止残留 Cookies 或状态）
    public func resetSession(sessionID: String, url: String? = nil) async throws -> String {
        let client = try await ensureClient()
        try await client.closeSession(sessionID: sessionID)
        sessions.removeValue(forKey: sessionID)

        _ = try await client.createSession(sessionID: sessionID)
        let targetURL = url ?? "about:blank"
        let navResult = try await client.navigate(sessionID: sessionID, url: targetURL)
        let obs = try await client.snapshot(sessionID: sessionID, includeScreenshot: false)

        sessions[sessionID] = BrowserSessionState(
            sessionID: sessionID,
            currentURL: navResult.url,
            currentTitle: navResult.title,
            latestObservation: obs
        )
        return formatObservationSummary(obs)
    }

    /// 执行点击或输入动作（带语义引用验证与防陈旧点击保护）
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
        var refIndex: Int? = nil
        var refVersion: Int64? = nil

        if let refString {
            // 严格匹配目标引用
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

            refIndex = matchedRef.index
            refVersion = matchedRef.version
            targetX = bounds.origin.x + bounds.width / 2.0
            targetY = bounds.origin.y + bounds.height / 2.0
        }

        try await client.performAction(
            sessionID: sessionID,
            actionType: actionType,
            refIndex: refIndex,
            version: refVersion,
            x: targetX,
            y: targetY,
            text: text,
            allowCoordinateFallback: false // 禁止无脑降级为未知坐标点击
        )

        // 动作完成后获取新帧 Observation (Semantic Trimming)
        let newObs = try await client.snapshot(sessionID: sessionID, includeScreenshot: false)
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

    /// 独立页面截屏（按需调用，不污染常规 Observation 循环）
    public func captureScreenshot(sessionID: String, savePath: String? = nil) async throws -> (path: String?, base64: String?) {
        let client = try await ensureClient()
        return try await client.capture(sessionID: sessionID, savePath: savePath)
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
