import Foundation
import LingXiProtocol
import LingXiClient
import LingXiPlatform

public enum ApplicationCommandError: Error, Sendable, Equatable {
    case commandNotFound(String)
    case invalidArguments(String)
    case executionFailed(String)
}

/// 统一业务命令注册表。
/// 汇聚 Builtin 命令与 Extension contribution 命令。
public final class ApplicationCommandRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var commandsByName: [String: ApplicationCommand] = [:]
    private var aliasToCanonical: [String: String] = [:]
    private var pluginCommands: [String: ApplicationCommand] = [:]
    public let customRoots: [URL]?

    public init(customRoots: [URL]? = nil) {
        self.customRoots = customRoots
    }

    /// 注册命令（支持 Builtin 与 Extension 贡献）
    public func register(_ command: ApplicationCommand) {
        lock.lock()
        defer { lock.unlock() }

        let canonicalName = command.name.lowercased()
        commandsByName[canonicalName] = command
        for alias in command.aliases {
            aliasToCanonical[alias.lowercased()] = canonicalName
        }
    }

    /// 批量注册/同步外部插件命令
    public func syncPluginCommands(from extensions: [ExtensionInfo], client: LingXiClientVNext) {
        lock.lock()
        defer { lock.unlock() }

        for ext in extensions where ext.kind == .command {
            let name = ext.id.lowercased()
            let command = ApplicationCommand(
                name: ext.id,
                aliases: [],
                description: ext.summary ?? "外部 Swift 插件提供的交互命令",
                category: "Plugin",
                argumentSchema: "[]"
            ) { [weak client] ctx in
                guard let client else {
                    throw ApplicationCommandError.executionFailed("Client unavailable")
                }
                let res = try await client.extensionDomain.executeCommand(
                    name: ctx.commandName,
                    arguments: ctx.arguments,
                    sessionID: ctx.sessionID?.rawValue
                )
                if res.isPrompt {
                    return ApplicationCommandResult(
                        output: "🦊 [插件提示词宏 /\(res.name)] 已展开：\n\n\(res.output)",
                        presentation: .inline,
                        revertedComposerText: res.output
                    )
                } else {
                    let style = CommandPresentationStyle(rawValue: res.presentation) ?? .modal
                    return ApplicationCommandResult(
                        output: res.output,
                        presentation: style,
                        modalTitle: res.title ?? "/\(res.name)"
                    )
                }
            }
            pluginCommands[name] = command
        }
    }

    /// 注销命令
    public func unregister(name: String) {
        lock.lock()
        defer { lock.unlock() }

        let canonical = name.lowercased()
        if let cmd = commandsByName.removeValue(forKey: canonical) {
            for alias in cmd.aliases {
                aliasToCanonical.removeValue(forKey: alias.lowercased())
            }
        }
        pluginCommands.removeValue(forKey: canonical)
    }

    /// 查询命令（支持静态、插件与自定义 Markdown 宏）
    public func command(named name: String) -> ApplicationCommand? {
        let lower = name.lowercased()

        lock.lock()
        if let cmd = commandsByName[lower] {
            lock.unlock()
            return cmd
        }
        if let canonical = aliasToCanonical[lower], let cmd = commandsByName[canonical] {
            lock.unlock()
            return cmd
        }
        if let cmd = pluginCommands[lower] {
            lock.unlock()
            return cmd
        }
        lock.unlock()

        // 动态检查自定义 Markdown 指令
        let customs = discoverCustomMarkdownCommands()
        if let found = customs.first(where: { $0.name.lowercased() == lower }) {
            return found
        }

        return nil
    }

    /// 全部可用命令（Builtin + 插件贡献 + 自定义 Markdown 宏）
    public var allCommands: [ApplicationCommand] {
        lock.lock()
        let staticList = Array(commandsByName.values)
        let pluginList = Array(pluginCommands.values)
        lock.unlock()

        let customList = discoverCustomMarkdownCommands()
        var map: [String: ApplicationCommand] = [:]
        for cmd in staticList {
            map[cmd.name.lowercased()] = cmd
        }
        for cmd in pluginList {
            map[cmd.name.lowercased()] = cmd
        }
        for cmd in customList {
            if map[cmd.name.lowercased()] == nil {
                map[cmd.name.lowercased()] = cmd
            }
        }
        return Array(map.values).sorted(by: { $0.name < $1.name })
    }

    /// 发现项目级与全局级自定义 Markdown 指令
    public func discoverCustomMarkdownCommands() -> [ApplicationCommand] {
        let candidateDirs: [URL]
        if let customRoots {
            candidateDirs = customRoots
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            candidateDirs = [
                currentDir.appendingPathComponent(".lingxi/commands"),
                home.appendingPathComponent(".lingxiagent/commands"),
                home.appendingPathComponent(".lingxi/commands")
            ]
        }

        var results: [ApplicationCommand] = []
        var seenNames = Set<String>()

        for dir in candidateDirs {
            guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "md" {
                guard let parsed = CustomCommandEngine.parse(fileURL: fileURL, isProjectScope: !fileURL.path.contains(".lingxiagent")) else { continue }
                let lowerName = parsed.name.lowercased()
                guard !seenNames.contains(lowerName) else { continue }
                seenNames.insert(lowerName)

                let cmd = ApplicationCommand(
                    name: parsed.name,
                    aliases: [],
                    description: parsed.description,
                    category: parsed.category.isEmpty ? "Custom" : parsed.category,
                    argumentSchema: parsed.argumentsHint.isEmpty ? "[]" : parsed.argumentsHint
                ) { [weak self] ctx in
                    if let result = await self?.resolveCustomMarkdownCommand(name: ctx.commandName, args: ctx.arguments, client: ctx.client, sessionID: ctx.sessionID) {
                        return result
                    }
                    throw ApplicationCommandError.commandNotFound(ctx.commandName)
                }
                results.append(cmd)
            }
        }
        return results
    }

    /// 执行命令字符串（如 "/model gpt-4o" 或 "model gpt-4o"）
    public func execute(
        input: String,
        sessionID: SessionID?,
        client: LingXiClientVNext,
        state: ApplicationState
    ) async throws -> ApplicationCommandResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ApplicationCommandError.commandNotFound("")
        }

        let rawCommand = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        let parts = rawCommand.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let name = parts.first else {
            throw ApplicationCommandError.commandNotFound("")
        }

        let args = Array(parts.dropFirst())
        if let command = self.command(named: name) {
            let ctx = ApplicationCommandContext(
                rawInput: input,
                commandName: name,
                arguments: args,
                sessionID: sessionID,
                client: client,
                state: state
            )
            return try await command.handler(ctx)
        }

        // 尝试向 Core 插件下发执行
        if let pluginResult = try? await client.extensionDomain.executeCommand(name: name, arguments: args, sessionID: sessionID?.rawValue) {
            if pluginResult.isPrompt {
                return ApplicationCommandResult(
                    output: "🦊 [插件提示词宏 /\(pluginResult.name)] 已展开：\n\n\(pluginResult.output)",
                    presentation: .inline,
                    revertedComposerText: pluginResult.output
                )
            } else {
                let style = CommandPresentationStyle(rawValue: pluginResult.presentation) ?? .modal
                return ApplicationCommandResult(
                    output: pluginResult.output,
                    presentation: style,
                    modalTitle: pluginResult.title ?? "/\(pluginResult.name)"
                )
            }
        }

        // 尝试从项目级与全局级目录发现自定义 Markdown 指令并委托 Core 执行
        if let customResult = await resolveCustomMarkdownCommand(name: name, args: args, client: client, sessionID: sessionID) {
            return customResult
        }

        throw ApplicationCommandError.commandNotFound(name)
    }

    private func resolveCustomMarkdownCommand(name: String, args: [String], client: LingXiClientVNext?, sessionID: SessionID?) async -> ApplicationCommandResult? {
        let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidatePaths: [URL]
        if let customRoots {
            candidatePaths = customRoots.map { $0.appendingPathComponent("\(name).md") }
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            candidatePaths = [
                currentDir.appendingPathComponent(".lingxi/commands/\(name).md"),
                home.appendingPathComponent(".lingxiagent/commands/\(name).md"),
                home.appendingPathComponent(".lingxi/commands/\(name).md")
            ]
        }

        for path in candidatePaths {
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            guard let parsed = CustomCommandEngine.parse(fileURL: path, isProjectScope: !path.path.contains(".lingxiagent")) else { continue }

            let interpolated = CustomCommandEngine.interpolate(
                template: parsed.template,
                arguments: args,
                workspaceRoot: currentDir.path
            )

            switch parsed.type {
            case .prompt:
                return ApplicationCommandResult(
                    output: "🦊 [自定义提示词宏 /\(parsed.name)] 已展开：\n\n\(interpolated)",
                    revertedComposerText: interpolated
                )
            case .script:
                // 委托 Core 统一执行自定义脚本，严禁前端越权直接 spawn /bin/sh (Audit Round 5 Phase C)
                if let client {
                    do {
                        let res = try await client.extensionDomain.executeCommand(
                            name: parsed.name,
                            arguments: args,
                            sessionID: sessionID?.rawValue
                        )
                        return ApplicationCommandResult(output: res.output.isEmpty ? "✓ 脚本执行完毕" : res.output)
                    } catch {
                        return ApplicationCommandResult(output: "❌ 脚本由 Core 执行失败: \(error)")
                    }
                } else {
                    return ApplicationCommandResult(output: "❌ 客户端未连接 Core，无法执行脚本命令")
                }
            }
        }
        return nil
    }

}
