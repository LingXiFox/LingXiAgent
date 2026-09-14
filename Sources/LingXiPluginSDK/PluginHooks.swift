import Foundation

/// 插件可监听的生命周期事件。
public enum PluginHookEvent: String, Codable, Sendable, CaseIterable {
    case sessionStart
    case sessionEnd
    case agentTurnStart
    case agentTurnEnd
    case toolBefore
    case toolAfter
}

/// 钩子事件上下文。
public struct PluginHookPayload: Codable, Sendable, Equatable {
    public let event: PluginHookEvent
    public let subjectID: String
    public let metadata: [String: String]

    public init(event: PluginHookEvent, subjectID: String, metadata: [String: String] = [:]) {
        self.event = event
        self.subjectID = subjectID
        self.metadata = metadata
    }
}

/// 插件专属日志输出器。
public final class PluginLogger: @unchecked Sendable {
    private let pluginID: String
    private let lock = NSLock()
    private let writeHandler: (@Sendable (String, String) -> Void)?

    public init(pluginID: String, writeHandler: (@Sendable (String, String) -> Void)? = nil) {
        self.pluginID = pluginID
        self.writeHandler = writeHandler
    }

    public func info(_ message: String) {
        log(level: "INFO", message: message)
    }

    public func warn(_ message: String) {
        log(level: "WARN", message: message)
    }

    public func error(_ message: String) {
        log(level: "ERROR", message: message)
    }

    private func log(level: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        if let writeHandler {
            writeHandler(level, "[\(pluginID)] [\(level)] \(message)")
        } else {
            FileHandle.standardError.write(Data("[\(pluginID)] [\(level)] \(message)\n".utf8))
        }
    }
}

/// 插件专属私有 KV 存储。
public protocol PluginStorage: Sendable {
    func get(key: String) async throws -> String?
    func set(key: String, value: String) async throws
    func remove(key: String) async throws
}
