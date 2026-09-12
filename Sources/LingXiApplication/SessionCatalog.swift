import Foundation
import LingXiProtocol

public enum SessionCatalog {
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
}
