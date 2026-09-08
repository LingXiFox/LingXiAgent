import Foundation
import LingXiProtocol
import LingXiClient

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

    public init() {}

    /// 注册命令（支持 Extension 贡献）
    public func register(_ command: ApplicationCommand) {
        lock.lock()
        defer { lock.unlock() }

        let canonicalName = command.name.lowercased()
        commandsByName[canonicalName] = command
        for alias in command.aliases {
            aliasToCanonical[alias.lowercased()] = canonicalName
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
    }

    /// 查询命令
    public func command(named name: String) -> ApplicationCommand? {
        lock.lock()
        defer { lock.unlock() }

        let lower = name.lowercased()
        if let cmd = commandsByName[lower] {
            return cmd
        }
        if let canonical = aliasToCanonical[lower], let cmd = commandsByName[canonical] {
            return cmd
        }
        return nil
    }

    /// 全部已注册命令
    public var allCommands: [ApplicationCommand] {
        lock.lock()
        defer { lock.unlock() }
        return Array(commandsByName.values).sorted(by: { $0.name < $1.name })
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
        guard let command = self.command(named: name) else {
            throw ApplicationCommandError.commandNotFound(name)
        }

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
}
