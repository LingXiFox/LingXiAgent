import Foundation
import LingXiProtocol

/// Reads and writes the persisted Developer Debug Mode flag.
///
/// A value-translation unit and nothing else. `CoreHost` is already an actor and already owns
/// `storageLayout`, so mode changes are serialized there; a second actor holding the flag would add
/// a hop and a second authority without adding any safety.
///
/// The flag lives in Core rather than in the GUI's `UserDefaults` for one reason: what it gates is
/// Core-side collection. A GUI-local copy would let the Settings toggle disagree with what the hub
/// is actually recording, which is exactly the two-authorities failure this feature is supposed to
/// remove.
///
/// A missing or unreadable file means off. That is not a fallback, it is the default: a fresh data
/// root, and therefore every integration test, starts with debug mode disabled without anyone
/// having to configure it.
struct DebugModeStore: Sendable {
    struct State: Codable, Sendable, Equatable {
        var enabled: Bool
        var schemaVersion: Int
        var updatedAt: Date

        init(enabled: Bool, schemaVersion: Int = DebugTelemetryHub.schemaVersion, updatedAt: Date = .now) {
            self.enabled = enabled
            self.schemaVersion = schemaVersion
            self.updatedAt = updatedAt
        }
    }

    let url: URL

    init(layout: CoreStorageLayout) {
        self.url = layout.debugModeState
    }

    /// Absent, unreadable, or unparseable all report false. A corrupt mode file must not silently
    /// switch deep telemetry on, and must not stop Core from booting.
    func load() -> Bool {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return false
        }
        return state.enabled
    }

    /// Returns false when the write failed. The caller keeps the in-memory mode as-is: a debug flag
    /// that will not persist is a live-but-not-surviving-restart state, and saying so beats
    /// pretending the save happened.
    @discardableResult
    func save(enabled: Bool) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(State(enabled: enabled)).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
