import Foundation
import LingXiProtocol
import LingXiPlatform
import LingXiPluginSDK

private final class PluginSupervisorState: @unchecked Sendable {
    var hosts: [PluginProcessHost] = []
    private let lock = NSLock()

    func setHosts(_ next: [PluginProcessHost]) {
        lock.lock()
        defer { lock.unlock() }
        self.hosts = next
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        self.hosts.removeAll()
    }

    func terminateSync() {
        lock.lock()
        let current = hosts
        hosts.removeAll()
        lock.unlock()

        for host in current {
            host.terminateSync()
        }
    }
}

/// 插件系统管理中心：负责扫描可执行二进制插件、沙箱进程宿主管理与调用分发。
public actor PluginHostSupervisor {
    public let globalPluginsRoot: URL
    public private(set) var projectPluginsRoot: URL
    private let permissions: PermissionEngine
    public var isEnabled: Bool

    private let state = PluginSupervisorState()
    private var hostsByPluginID: [String: PluginProcessHost] = [:]
    private var toolToPluginID: [String: String] = [:]
    private var commandToPluginID: [String: String] = [:]

    public init(
        globalRoot: URL,
        projectRoot: URL,
        permissions: PermissionEngine,
        isEnabled: Bool = true
    ) {
        self.globalPluginsRoot = globalRoot.appendingPathComponent("plugins", isDirectory: true)
        self.projectPluginsRoot = projectRoot.appendingPathComponent(".lingxi/plugins", isDirectory: true)
        self.permissions = permissions
        self.isEnabled = isEnabled
    }

    /// 更新工作区工程根路径并重置插件进程
    public func updateProjectRoot(_ newURL: URL) async {
        await terminateAll()
        self.projectPluginsRoot = newURL.appendingPathComponent(".lingxi/plugins", isDirectory: true)
    }

    deinit {
        state.terminateSync()
    }

    /// 扫描并加载所有可用插件（并行拉起与握手）
    public func discoverAndStartAll() async -> [PluginHandshakeResult] {
        await terminateAll()
        guard isEnabled, ProcessInfo.processInfo.environment["LINGXI_DISABLE_PLUGINS"] != "1" else { return [] }

        // 严格遵循依赖注入根目录，绝不硬编码扫描用户个人 HOME 目录
        let searchDirectories = [
            (ExtensionScope.project, projectPluginsRoot),
            (.global, globalPluginsRoot)
        ]

        struct Candidate: Sendable {
            let priority: Int
            let scope: ExtensionScope
            let binaryURL: URL
        }

        var candidates: [Candidate] = []
        for (priority, (scope, dir)) in searchDirectories.enumerated() {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isExecutableKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                if let binaryURL = resolveExecutableBinary(at: entry) {
                    candidates.append(Candidate(priority: priority, scope: scope, binaryURL: binaryURL))
                }
            }
        }

        guard !candidates.isEmpty else { return [] }

        struct StartResult: Sendable {
            let priority: Int
            let host: PluginProcessHost
            let handshake: PluginHandshakeResult?
        }

        // 并行拉起所有插件并握手
        let results: [StartResult] = await withTaskGroup(of: StartResult.self) { group in
            for candidate in candidates {
                let permissions = self.permissions
                group.addTask {
                    let host = PluginProcessHost(binaryURL: candidate.binaryURL, scope: candidate.scope, permissions: permissions)
                    do {
                        let handshake = try await host.start()
                        return StartResult(priority: candidate.priority, host: host, handshake: handshake)
                    } catch {
                        await host.terminate()
                        return StartResult(priority: candidate.priority, host: host, handshake: nil)
                    }
                }
            }

            var collected: [StartResult] = []
            for await res in group {
                collected.append(res)
            }
            return collected
        }

        // 按优先级排序（数字越小优先级越高）
        let sorted = results.sorted(by: { $0.priority < $1.priority })

        var seenIDs = Set<String>()
        var discoveredResults: [PluginHandshakeResult] = []

        for item in sorted {
            guard let handshake = item.handshake else { continue }
            let pluginID = handshake.manifest.id

            if seenIDs.insert(pluginID).inserted {
                hostsByPluginID[pluginID] = item.host

                // 登记 Tools
                for tool in handshake.tools {
                    toolToPluginID[tool.name] = pluginID
                }

                // 登记 Commands
                for cmd in handshake.commands {
                    commandToPluginID[cmd.name.lowercased()] = pluginID
                    for alias in cmd.aliases {
                        commandToPluginID[alias.lowercased()] = pluginID
                    }
                }

                discoveredResults.append(handshake)
            } else {
                // 重复或低优先级，终止
                await item.host.terminate()
            }
        }

        state.setHosts(Array(hostsByPluginID.values))
        return discoveredResults
    }

    /// 所有已就绪的插件元数据
    public func activePlugins() async -> [PluginHandshakeResult] {
        var results: [PluginHandshakeResult] = []
        for host in hostsByPluginID.values {
            if let hs = await host.handshakeResult {
                results.append(hs)
            }
        }
        return results.sorted(by: { $0.manifest.id < $1.manifest.id })
    }

    /// 执行插件工具
    public func executeTool(name: String, arguments: String, sessionID: String, toolCallID: String) async throws -> String {
        guard let pluginID = toolToPluginID[name], let host = hostsByPluginID[pluginID] else {
            throw CoreError(code: .toolNotFound, message: "No plugin found providing tool '\(name)'")
        }
        return try await host.executeTool(name: name, arguments: arguments, sessionID: sessionID, toolCallID: toolCallID)
    }

    /// 执行插件命令
    public func executeCommand(name: String, arguments: [String], sessionID: String?) async throws -> PluginCommandCallResult {
        guard let pluginID = commandToPluginID[name.lowercased()], let host = hostsByPluginID[pluginID] else {
            throw CoreError(code: .unsupportedCommand, message: "No plugin found providing command '\(name)'")
        }
        return try await host.executeCommand(name: name, arguments: arguments, sessionID: sessionID)
    }

    /// 分发生命周期事件
    public func broadcastHook(_ payload: PluginHookPayload) async {
        for host in hostsByPluginID.values {
            await host.emitHook(payload)
        }
    }

    /// 全局终止所有插件进程（用于退出或全局熔断）
    public func terminateAll() async {
        let hosts = Array(hostsByPluginID.values)
        hostsByPluginID.removeAll()
        toolToPluginID.removeAll()
        commandToPluginID.removeAll()
        state.clear()

        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask {
                    await host.terminate()
                }
            }
        }
    }

    /// 同步尽力终止所有插件进程（供 deinit 使用）
    public nonisolated func terminateAllSync() {
        state.terminateSync()
    }

    // MARK: - Helper

    private func resolveExecutableBinary(at url: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        if !isDir.boolValue {
            // 普通文件，检查是否可执行
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        // 文件夹：检查内部同名文件、bin/ 目录或单个可执行文件
        let candidateNames = [url.lastPathComponent, "bin/\(url.lastPathComponent)", "main"]
        for cand in candidateNames {
            let file = url.appendingPathComponent(cand)
            if FileManager.default.isExecutableFile(atPath: file.path) {
                return file
            }
        }

        // 或者找文件夹下的第一个可执行文件
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for item in contents {
            if FileManager.default.isExecutableFile(atPath: item.path) {
                return item
            }
        }
        return nil
    }
}
