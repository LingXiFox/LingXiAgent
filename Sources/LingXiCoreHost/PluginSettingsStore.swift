import Foundation
import LingXiPluginABI
import LingXiPluginRuntime
import LingXiSettingsProtocol

/// Core-owned plugin settings. Kept separate from events, the plugin registry and Keychain: this is
/// ordinary configuration, never a secret, and it must be atomically replaceable.
actor PluginSettingsStore: PluginSettingsProviding {
    struct Payload: Codable {
        let version: Int
        let config: JSONValue
        /// Optional frontend hint: the model this plugin wants selected for new conversations. It
        /// never changes routing; the Core still rejects a model it does not offer.
        let preferredModel: String?
    }

    enum StoreError: Error, CustomStringConvertible, Equatable {
        case invalidBundleID(String)
        case unsupportedVersion(Int)
        case configNotObject
        case configTooLarge(Int)
        case unreadable(String)

        var description: String {
            switch self {
            case .invalidBundleID(let id): "invalid bundle id for settings: \(id)"
            case .unsupportedVersion(let version): "unsupported settings version: \(version)"
            case .configNotObject: "settings config must be a JSON object"
            case .configTooLarge(let bytes): "settings config is \(bytes) bytes; the limit is \(SettingsWireLimits.maxConfigBytes)"
            case .unreadable(let reason): "settings file is unreadable: \(reason)"
            }
        }
    }

    private let directory: URL

    init(dataDirectory: String) {
        directory = URL(fileURLWithPath: dataDirectory).appendingPathComponent("plugin-settings")
    }

    func settings(for bundleID: String) async throws -> PluginSettingsSnapshot? {
        try load(bundleID: bundleID)
    }

    func load(bundleID: String) throws -> PluginSettingsSnapshot? {
        let url = try fileURL(bundleID: bundleID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == 1 else { throw StoreError.unsupportedVersion(payload.version) }
            guard payload.config.object != nil else { throw StoreError.configNotObject }
            return PluginSettingsSnapshot(
                version: payload.version, config: payload.config,
                preferredModel: payload.preferredModel
            )
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.unreadable("\(error)")
        }
    }

    func save(
        bundleID: String, version: Int = 1, config: JSONValue,
        preferredModel: String? = nil
    ) throws {
        guard version == 1 else { throw StoreError.unsupportedVersion(version) }
        guard config.object != nil else { throw StoreError.configNotObject }
        let data = try JSONEncoder().encode(
            Payload(version: version, config: config, preferredModel: preferredModel)
        )
        guard data.count <= SettingsWireLimits.maxConfigBytes else {
            throw StoreError.configTooLarge(data.count)
        }
        let url = try fileURL(bundleID: bundleID)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func remove(bundleID: String) throws {
        let url = try fileURL(bundleID: bundleID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(bundleID: String) throws -> URL {
        let allowed = bundleID.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
        }
        guard !bundleID.isEmpty, allowed else { throw StoreError.invalidBundleID(bundleID) }
        return directory.appendingPathComponent(bundleID + ".json")
    }
}

extension PluginSettingsStore {
    /// Reads only the frontend hint. A corrupt file is ignored here on purpose: this is a cosmetic
    /// selection hint, while an explicit open/save surfaces the same corruption as a hard error.
    func preferredModelHint(bundleIDs: [String]) -> String? {
        for bundleID in bundleIDs {
            if let snapshot = try? load(bundleID: bundleID), let model = snapshot.preferredModel {
                return model
            }
        }
        return nil
    }
}
