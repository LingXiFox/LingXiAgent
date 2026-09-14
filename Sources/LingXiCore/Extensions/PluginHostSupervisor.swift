import Foundation
import LingXiProtocol
import LingXiPlatform
import LingXiPluginSDK

/// 插件系统管理中心：负责扫描可执行二进制插件、沙箱进程宿主管理与调用分发。
public actor PluginHostSupervisor {
    public let globalPluginsRoot: URL
    public let projectPluginsRoot: URL
    private let permissions: PermissionEngine

    private var hostsByPluginID: [String: PluginProcessHost] = [:]
    private var toolToPluginID: [String: String] = [:]
    private var commandToPluginID: [String: String] = [:]

    public init(
        globalRoot: URL,
        projectRoot: URL,
        permissions: PermissionEngine
    ) {
        self.globalPluginsRoot = globalRoot.appendingPathComponent("plugins", isDirectory: true)
        self.projectPluginsRoot = projectRoot.appendingPathComponent(".lingxi/plugins", isDirectory: true)
        self.permissions = permissions
    }

    /// 扫描并加载所有可用插件
    public func discoverAndStartAll() async -> [PluginHandshakeResult] {
        terminateAll()

        var discoveredResults: [PluginHandshakeResult] = []

        // 项目级优先，其次全局级
        let searchDirectories = [
            (ExtensionScope.project, projectPluginsRoot),
            (.global, globalPluginsRoot),
            (.global, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lingxiagent/plugins", isDirectory: true))
        ]

        var seenIDs = Set<String>()

        for (scope, dir) in searchDirectories {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isExecutableKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

            for entry in entries {
                guard let binaryURL = resolveExecutableBinary(at: entry) else { continue }

                let host = PluginProcessHost(binaryURL: binaryURL, scope: scope, permissions: permissions)
                do {
                    let handshake = try await host.start()
                    let pluginID = handshake.manifest.id

                    // 项目同名覆盖全局
                    if seenIDs.insert(pluginID).inserted {
                        hostsByPluginID[pluginID] = host

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
                        await host.terminate()
                    }
                } catch {
                    // 握手失败直接清理
                    await host.terminate()
                }
            }
        }

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
    public func terminateAll() {
        for host in hostsByPluginID.values {
            Task { await host.terminate() }
        }
        hostsByPluginID.removeAll()
        toolToPluginID.removeAll()
        commandToPluginID.removeAll()
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
