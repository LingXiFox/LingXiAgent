import Foundation
import LingXiProtocol

public enum SessionCatalog {
    /// Time-bucketed session group for modern picker UI.
    public struct TimeGroup: Sendable {
        public let title: String
        public let sessions: [SessionSummary]

        public init(title: String, sessions: [SessionSummary]) {
            self.title = title
            self.sessions = sessions
        }
    }

    /// Current project first; other projects and sessions newest first. Unknown roots stay separate.
    public static func groups(_ sessions: [SessionSummary], currentDirectory: String, query: String = "") -> [(directory: String, sessions: [SessionSummary])] {
        let current = URL(fileURLWithPath: currentDirectory).standardizedFileURL.path
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = sessions.filter {
            query.isEmpty || "\($0.title ?? "") \($0.sessionID.rawValue) \($0.workingDirectory ?? "")".lowercased().contains(query)
        }
        let grouped = Dictionary(grouping: filtered) { session in
            session.workingDirectory.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).standardizedFileURL.path } ?? ""
        }
        return grouped.map { directory, sessions in
            (directory: directory, sessions: sessions.sorted {
                $0.updatedAt == $1.updatedAt ? $0.sessionID.rawValue < $1.sessionID.rawValue : $0.updatedAt > $1.updatedAt
            })
        }.sorted {
            if ($0.directory == current) != ($1.directory == current) { return $0.directory == current }
            let left = $0.sessions.first?.updatedAt ?? .distantPast
            let right = $1.sessions.first?.updatedAt ?? .distantPast
            return left == right ? $0.directory < $1.directory : left > right
        }
    }

    /// Buckets sessions into chronological groups: Today, Yesterday, Previous 7 Days, Older.
    public static func timeGroups(
        _ sessions: [SessionSummary],
        query: String = "",
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [TimeGroup] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = sessions.filter {
            trimmedQuery.isEmpty || "\($0.title ?? "") \($0.sessionID.rawValue) \($0.workingDirectory ?? "")".lowercased().contains(trimmedQuery)
        }
        let sorted = filtered.sorted {
            $0.updatedAt == $1.updatedAt ? $0.sessionID.rawValue < $1.sessionID.rawValue : $0.updatedAt > $1.updatedAt
        }

        var today: [SessionSummary] = []
        var yesterday: [SessionSummary] = []
        var pastWeek: [SessionSummary] = []
        var older: [SessionSummary] = []

        for s in sorted {
            if calendar.isDateInToday(s.updatedAt) {
                today.append(s)
            } else if calendar.isDateInYesterday(s.updatedAt) {
                yesterday.append(s)
            } else if let days = calendar.dateComponents([.day], from: s.updatedAt, to: now).day, days < 7 {
                pastWeek.append(s)
            } else {
                older.append(s)
            }
        }

        var result: [TimeGroup] = []
        if !today.isEmpty { result.append(TimeGroup(title: "Today", sessions: today)) }
        if !yesterday.isEmpty { result.append(TimeGroup(title: "Yesterday", sessions: yesterday)) }
        if !pastWeek.isEmpty { result.append(TimeGroup(title: "Previous 7 Days", sessions: pastWeek)) }
        if !older.isEmpty { result.append(TimeGroup(title: "Older", sessions: older)) }
        return result
    }
}

public extension SessionSummary {
    /// The remote-frontend intent that opens this catalog entry.
    /// `FrontendCommand` is the serializable mirror of `ApplicationAction`, so a web client
    /// can drive the catalog with the same contract the GUI/TUI use in-process.
    func toWireCommand() -> FrontendCommand {
        .switchSession(sessionID: sessionID)
    }
}
