import Foundation

/// The plugin registry is configuration, not session history: D3 makes the event log the only source
/// of truth for sessions and runs, and a plugin being enabled is neither. It therefore lives in its
/// own JSON file under the data directory, written atomically, and the log never mentions plugins.
public actor PluginRegistry {
    public struct Entry: Codable, Sendable, Equatable {
        public var bundleID: String
        public var version: String
        public var bundlePath: String
        public var enabled: Bool
        /// Grants passed to the plugin at start (e.g. `vcr=<path>`). Optional so existing files
        /// still decode; absent means no grants.
        public var grants: [String]?
        /// Last known declared capabilities and permissions, cached when the plugin was enabled so
        /// the UI can describe a stopped plugin without loading it.
        public var capabilities: [String]?
        public var permissions: [String]?

        public init(
            bundleID: String, version: String, bundlePath: String, enabled: Bool,
            grants: [String]? = nil, capabilities: [String]? = nil, permissions: [String]? = nil
        ) {
            self.bundleID = bundleID
            self.version = version
            self.bundlePath = bundlePath
            self.enabled = enabled
            self.grants = grants
            self.capabilities = capabilities
            self.permissions = permissions
        }
    }

    private struct File: Codable {
        var plugins: [Entry]
    }

    private var entries: [String: Entry] = [:]
    private let configURL: URL?

    /// A nil URL keeps the registry in memory, which the tests use when persistence is not the point.
    public init(configURL: URL?) throws {
        self.configURL = configURL
        guard let configURL, FileManager.default.fileExists(atPath: configURL.path) else { return }
        let data = try Data(contentsOf: configURL)
        let file = try JSONDecoder().decode(File.self, from: data)
        for entry in file.plugins { entries[entry.bundleID] = entry }
    }

    public func all() -> [Entry] {
        entries.values.sorted { $0.bundleID < $1.bundleID }
    }

    public func entry(_ bundleID: String) -> Entry? { entries[bundleID] }

    public func upsert(_ entry: Entry) throws {
        let previous = entries[entry.bundleID]
        entries[entry.bundleID] = entry
        do {
            try persist()
        } catch {
            // The disk is the source of truth for enabled state: if the write failed, in-memory must
            // not claim otherwise.
            if let previous { entries[entry.bundleID] = previous } else { entries.removeValue(forKey: entry.bundleID) }
            throw error
        }
    }

    public func remove(_ bundleID: String) throws {
        let previous = entries.removeValue(forKey: bundleID)
        do {
            try persist()
        } catch {
            if let previous { entries[bundleID] = previous }
            throw error
        }
    }

    private func persist() throws {
        guard let configURL else { return }
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let file = File(plugins: all())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: configURL, options: .atomic)
    }
}
