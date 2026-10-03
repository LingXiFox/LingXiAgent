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

        private enum CodingKeys: String, CodingKey {
            case enabled, schemaVersion, updatedAt
        }

        /// Tolerant of every date shape this file has ever had.
        ///
        /// `updatedAt` is only a "when did you last flip this" note, but a strict decoder lets it
        /// veto the whole file — and `load` treats an unreadable file as "off", which is the right
        /// answer for corruption and the wrong answer for a timestamp written by an earlier build.
        /// A build that wrote whole-second ISO8601 left exactly such a file behind, so the flag
        /// persisted and silently refused to restore.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.enabled = try container.decode(Bool.self, forKey: .enabled)
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? DebugTelemetryHub.schemaVersion
            if let date = try? container.decode(Date.self, forKey: .updatedAt) {
                self.updatedAt = date
            } else if let text = try? container.decode(String.self, forKey: .updatedAt) {
                self.updatedAt = State.dateFormats.compactMap { formatter in
                    formatter.date(from: text)
                }.first ?? .now
            } else {
                self.updatedAt = .now
            }
        }

        /// Fractional-seconds first (what we write), then whole-second ISO8601 (what an earlier
        /// build wrote).
        static let dateFormats: [DateFormatter] = {
            ["yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"].map { pattern in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = pattern
                return formatter
            }
        }()
    }

    let url: URL

    init(layout: CoreStorageLayout) {
        self.url = layout.debugModeState
    }

    /// Absent, unreadable, or unparseable all report false. A corrupt mode file must not silently
    /// switch deep telemetry on, and must not stop Core from booting.
    ///
    /// The decoder must be the one the writer used. `save` encodes `updatedAt` as an ISO8601
    /// string; a default `JSONDecoder` expects a Double, so it threw on every file it had just
    /// written and `load` fell through to false. The mode therefore persisted and never restored,
    /// and did so silently because "unparseable means off" is the intended behaviour for real
    /// corruption.
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
            // Shared with the archive encoder so the two cannot drift apart again.
            let encoder = DebugTelemetryHub.archiveEncoder()
            encoder.outputFormatting.insert(.prettyPrinted)
            try encoder.encode(State(enabled: enabled)).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
