import Foundation

/// 插件上下文：注册工具、命令、钩子与访问只读感知信息。
public final class PluginContext: @unchecked Sendable {
    private let lock = NSLock()
    public let pluginID: String
    public let info: PluginInfoHub
    public let storage: PluginStorage
    public let logger: PluginLogger

    private var registeredTools: [String: any PluginTool] = [:]
    private var registeredCommands: [String: any PluginCommand] = [:]
    private var registeredHooks: [PluginHookEvent: [@Sendable (PluginHookPayload) async throws -> Void]] = [:]

    public init(
        pluginID: String,
        info: PluginInfoHub,
        storage: PluginStorage,
        logger: PluginLogger
    ) {
        self.pluginID = pluginID
        self.info = info
        self.storage = storage
        self.logger = logger
    }

    /// 注册供大模型调用的自定义工具
    public func registerTool(_ tool: any PluginTool) {
        lock.lock()
        defer { lock.unlock() }
        registeredTools[tool.name] = tool
    }

    /// 注册供终端用户敲击使用的 Slash Command
    public func registerCommand(_ command: any PluginCommand) {
        lock.lock()
        defer { lock.unlock() }
        registeredCommands[command.name] = command
        for alias in command.aliases {
            registeredCommands[alias] = command
        }
    }

    /// 注册生命周期钩子
    public func on(_ event: PluginHookEvent, handler: @escaping @Sendable (PluginHookPayload) async throws -> Void) {
        lock.lock()
        defer { lock.unlock() }
        registeredHooks[event, default: []].append(handler)
    }

    // MARK: - Internal for SDK Driver

    public var allTools: [any PluginTool] {
        lock.lock()
        defer { lock.unlock() }
        return Array(registeredTools.values)
    }

    public var allCommands: [any PluginCommand] {
        lock.lock()
        defer { lock.unlock() }
        var unique: [String: any PluginCommand] = [:]
        for cmd in registeredCommands.values {
            unique[cmd.name] = cmd
        }
        return Array(unique.values)
    }

    public func tool(named name: String) -> (any PluginTool)? {
        lock.lock()
        defer { lock.unlock() }
        return registeredTools[name]
    }

    public func command(named name: String) -> (any PluginCommand)? {
        lock.lock()
        defer { lock.unlock() }
        return registeredCommands[name]
    }

    public func executeHooks(_ payload: PluginHookPayload) async {
        let handlers = getHookHandlers(for: payload.event)
        for handler in handlers {
            do {
                try await handler(payload)
            } catch {
                logger.error("Hook handler for \(payload.event.rawValue) failed: \(error)")
            }
        }
    }

    private func getHookHandlers(for event: PluginHookEvent) -> [@Sendable (PluginHookPayload) async throws -> Void] {
        lock.lock()
        defer { lock.unlock() }
        return registeredHooks[event] ?? []
    }
}
