import Foundation
import LingXiProtocol

public struct UserPreferences: Codable, Sendable, Equatable {
    static func parseToggle(_ raw: String, _ current: Bool) throws -> Bool {
        switch raw.lowercased() {
        case "on", "true", "yes", "1", "open", "expand": return true
        case "off", "false", "no", "0", "close", "collapse": return false
        case "toggle": return !current
        default: throw ApplicationCommandError.executionFailed("无效配置值: \(raw)。请使用 on、off 或 toggle。")
        }
    }
    public var lastModelID: String?
    public var lastReasoningEffort: String?
    public var expandThinking: Bool?
    public var expandTools: Bool?
    public var showSidebar: Bool?

    public init(
        lastModelID: String? = nil,
        lastReasoningEffort: String? = nil,
        expandThinking: Bool? = nil,
        expandTools: Bool? = nil,
        showSidebar: Bool? = nil
    ) {
        self.lastModelID = lastModelID
        self.lastReasoningEffort = lastReasoningEffort
        self.expandThinking = expandThinking
        self.expandTools = expandTools
        self.showSidebar = showSidebar
    }
}

public final class UserPreferencesStore: @unchecked Sendable {
    public static let shared = UserPreferencesStore()
    private let lock = NSLock()
    private let fileURL: URL
    private var cached: UserPreferences?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let override = ProcessInfo.processInfo.environment["LINGXI_DATA_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseDir = override.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lingxiagent", isDirectory: true)
            self.fileURL = baseDir.appendingPathComponent("preferences.json")
        }
    }

    public func load() -> UserPreferences {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    private func loadUnlocked() -> UserPreferences {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: fileURL) else {
            let empty = UserPreferences()
            cached = empty
            return empty
        }
        let preferences = (try? JSONDecoder().decode(UserPreferences.self, from: data)) ?? UserPreferences()
        cached = preferences
        return preferences
    }

    public func save(_ preferences: UserPreferences) {
        lock.lock()
        defer { lock.unlock() }
        saveUnlocked(preferences)
    }

    @discardableResult
    private func saveUnlocked(_ preferences: UserPreferences) -> Bool {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(preferences)
            try data.write(to: fileURL, options: .atomic)
            cached = preferences
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func update(
        modelID: String? = nil,
        reasoningEffort: String? = nil,
        expandThinking: Bool? = nil,
        expandTools: Bool? = nil,
        showSidebar: Bool? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var current = loadUnlocked()
        var changed = false
        if let modelID, !modelID.isEmpty, current.lastModelID != modelID {
            current.lastModelID = modelID
            changed = true
        }
        if let reasoningEffort, !reasoningEffort.isEmpty, current.lastReasoningEffort != reasoningEffort {
            current.lastReasoningEffort = reasoningEffort
            changed = true
        }
        if let expandThinking, current.expandThinking != expandThinking {
            current.expandThinking = expandThinking
            changed = true
        }
        if let expandTools, current.expandTools != expandTools {
            current.expandTools = expandTools
            changed = true
        }
        if let showSidebar, current.showSidebar != showSidebar {
            current.showSidebar = showSidebar
            changed = true
        }
        if changed {
            return saveUnlocked(current)
        }
        return true
    }
}
