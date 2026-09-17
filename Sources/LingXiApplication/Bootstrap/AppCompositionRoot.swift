import Foundation
import LingXiProtocol
import LingXiClient

/// 通用应用启动配置，供所有前端与组合根使用。
public struct ApplicationLaunchConfiguration: Sendable, Equatable {
    public var corePath: String?
    public var initialPrompt: String?
    public var initialModelID: String?
    public var initialWorkingDir: String?
    public var isYoloMode: Bool
    public var reasoningEffort: ReasoningEffort?
    public var resumeSessionID: String?

    public init(
        corePath: String? = nil,
        initialPrompt: String? = nil,
        initialModelID: String? = nil,
        initialWorkingDir: String? = nil,
        isYoloMode: Bool = false,
        reasoningEffort: ReasoningEffort? = nil,
        resumeSessionID: String? = nil
    ) {
        self.corePath = corePath
        self.initialPrompt = initialPrompt
        self.initialModelID = initialModelID
        self.initialWorkingDir = initialWorkingDir
        self.isYoloMode = isYoloMode
        self.reasoningEffort = reasoningEffort
        self.resumeSessionID = resumeSessionID
    }

    public static let `default` = ApplicationLaunchConfiguration()
}

/// 统一应用程序组合根 (Composition Root)。
/// 彻底解耦前端与后端生命周期：
/// 1. 负责管理 Core 进程启动与连接（Stdio/InProcess 等）；
/// 2. 装配 ApplicationStore；
/// 3. 执行应用启动时的初态分发（会话恢复、模式设置、模型选择、Prompt 投递）；
/// 4. 挂载并运行 Frontend 视图层，并在退出时优雅收口。
public final class AppCompositionRoot: Sendable {
    public let configuration: ApplicationLaunchConfiguration

    public init(configuration: ApplicationLaunchConfiguration = .default) {
        self.configuration = configuration
    }

    /// 启动应用主生命周期，装配 Core 与 Store 并注入给前端运行。
    public func launch(with frontend: any Frontend) async throws {
        // 1. 设置工作目录（若指定）
        if let workDir = configuration.initialWorkingDir, !workDir.isEmpty {
            FileManager.default.changeCurrentDirectoryPath(workDir)
        }

        // 2. 装配 ApplicationStore（在等待冷启动握手时输出友好提示）
        if isatty(fileno(stderr)) != 0 {
            FileHandle.standardError.write(Data("🦊 正在唤醒 LingXiAgent (恢复工作区状态与扩展组件)...\r\n".utf8))
        }
        let store = try await ApplicationStore.stdio(
            corePath: configuration.corePath,
            interactive: true,
            autoConnect: true
        )

        // 3. 派发初始业务状态与偏好
        let initialPerm = Self.resolveInitialPermission(isYoloMode: configuration.isYoloMode)
        let bootstrapTask = Task { [configuration, initialPerm] in
            await store.dispatch(.listSessions)

            let prefs = UserPreferencesStore.shared.load()
            if let resumeID = configuration.resumeSessionID, !resumeID.isEmpty {
                await store.dispatch(.switchSession(SessionID(resumeID)))
                if configuration.isYoloMode {
                    await store.dispatch(.setPermissionConfiguration(.yoloFullAccess))
                }
            } else {
                await store.dispatch(.setPermissionConfiguration(initialPerm))
            }
            let targetModel = configuration.initialModelID ?? prefs.lastModelID
            if let modelID = targetModel, !modelID.isEmpty {
                await store.dispatch(.selectModel(modelID))
            }
            let targetEffort = configuration.reasoningEffort ?? prefs.lastReasoningEffort.flatMap(ReasoningEffort.init(rawValue:))
            if let effort = targetEffort {
                await store.dispatch(.setReasoningEffort(effort))
            }
            if let prompt = configuration.initialPrompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await store.dispatch(.submitPrompt(prompt))
            }
        }

        defer {
            bootstrapTask.cancel()
        }

        // 4. 注入 Frontend 并运行交互视图循环
        do {
            try await frontend.run(with: store)
        } catch {
            await store.dispatch(.disconnect)
            throw error
        }

        // 5. 前端退出后优雅断开
        await store.dispatch(.disconnect)
    }

    /// 解析启动时的初始权限配置。
    /// 优先级规则：
    /// 1. 命令行显式传入 -y / --yolo（最高优先级）
    /// 2. ~/.lingxiagent/config.json 显式配置的 permissionPolicy / executionProfile
    /// 3. 兜底默认：严格必须为 Ask/Workspace (.askWorkspace)
    /// 注意：禁止从临时偏好（preferences.json）自动继承 YOLO 权限！
    public static func resolveInitialPermission(isYoloMode: Bool) -> PermissionConfiguration {
        if isYoloMode {
            return .yoloFullAccess
        }

        let override = ProcessInfo.processInfo.environment["LINGXI_DATA_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseDir = override.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lingxiagent", isDirectory: true)
        let configFile = baseDir.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: configFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let agent = json["agent"] as? [String: Any] {
            let policy = (agent["permissionPolicy"] as? String)?.lowercased()
            let profile = (agent["executionProfile"] as? String)?.lowercased()
            let perm = (agent["permission"] as? String)?.lowercased()

            if perm == "yolo" || policy == "yolo" || (policy == "auto" && profile == "fullaccess") {
                return .yoloFullAccess
            } else if perm == "auto" || perm == "autoworkspace" || policy == "auto" {
                return .autoWorkspace
            } else if perm == "askfull" || perm == "askfullaccess" || (policy == "ask" && profile == "fullaccess") {
                return .askFullAccess
            } else if perm == "ask" || perm == "askworkspace" || policy == "ask" {
                return .askWorkspace
            }
        }

        return .askWorkspace
    }
}

