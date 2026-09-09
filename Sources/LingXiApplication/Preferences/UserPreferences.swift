import Foundation
import LingXiProtocol

public struct UserPreferences: Codable, Sendable, Equatable {
    public var lastModelID: String?
    public var lastReasoningEffort: String?

    public init(lastModelID: String? = nil, lastReasoningEffort: String? = nil) {
        self.lastModelID = lastModelID
        self.lastReasoningEffort = lastReasoningEffort
    }
}

public final class UserPreferencesStore: @unchecked Sendable {
    public static let shared = UserPreferencesStore()
    private let lock = NSLock()
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lingxiagent", isDirectory: true)
            self.fileURL = baseDir.appendingPathComponent("preferences.json")
        }
    }

    public func load() -> UserPreferences {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else {
            return UserPreferences()
        }
        return (try? JSONDecoder().decode(UserPreferences.self, from: data)) ?? UserPreferences()
    }

    public func save(_ preferences: UserPreferences) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(preferences)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Ignore write error
        }
    }

    public func update(modelID: String? = nil, reasoningEffort: String? = nil) {
        var current = load()
        var changed = false
        if let modelID, !modelID.isEmpty, current.lastModelID != modelID {
            current.lastModelID = modelID
            changed = true
        }
        if let reasoningEffort, !reasoningEffort.isEmpty, current.lastReasoningEffort != reasoningEffort {
            current.lastReasoningEffort = reasoningEffort
            changed = true
        }
        if changed {
            save(current)
        }
    }
}
