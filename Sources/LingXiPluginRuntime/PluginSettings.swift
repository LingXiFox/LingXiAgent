import Foundation
import LingXiPluginABI

/// Persisted settings as the runtime sees them. The Core owns the file; the runtime only applies a
/// snapshot to a plugin that is already running.
public struct PluginSettingsSnapshot: Sendable, Equatable {
    public let version: Int
    public let config: JSONValue

    public init(version: Int, config: JSONValue) {
        self.version = version
        self.config = config
    }
}

/// Implemented by the Core's settings store. The runtime never writes configuration itself: it asks
/// for the last committed snapshot and hands it to the plugin.
public protocol PluginSettingsProviding: Sendable {
    func settings(for bundleID: String) async -> PluginSettingsSnapshot?
}
