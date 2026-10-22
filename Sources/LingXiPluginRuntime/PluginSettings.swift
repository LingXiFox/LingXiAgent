import Foundation
import LingXiPluginABI

/// Persisted settings as the runtime sees them. The Core owns the file; the runtime only applies a
/// snapshot to a plugin that is already running.
public struct PluginSettingsSnapshot: Sendable, Equatable {
    public let version: Int
    public let config: JSONValue
    public let preferredModel: String?

    public init(version: Int, config: JSONValue, preferredModel: String? = nil) {
        self.version = version
        self.config = config
        self.preferredModel = preferredModel
    }
}

/// Implemented by the Core's settings store. The runtime never writes configuration itself: it asks
/// for the last committed snapshot and hands it to the plugin.
public protocol PluginSettingsProviding: Sendable {
    func settings(for bundleID: String) async throws -> PluginSettingsSnapshot?
}


public enum PluginSettingsApplyError: Error, CustomStringConvertible, Equatable, Sendable {
    case rejected(String)
    case notRunning(String)

    public var description: String {
        switch self {
        case .rejected(let reason): "the plugin rejected the configuration: \(reason)"
        case .notRunning(let bundleID): "plugin \(bundleID) is not running"
        }
    }
}
