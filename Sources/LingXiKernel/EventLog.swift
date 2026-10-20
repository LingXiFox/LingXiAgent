import Foundation

public enum RecordedEvent: Sendable, Codable {
    case runCreated(RunID, SessionID, TurnID)
    case runStarted(RunID)
    case entryRecorded(RunID, ContextEntry)
    /// Durable intent to execute a tool batch. It is appended before any tool runs, so recovery can
    /// tell "settled" from "may have partially executed" (LOOP-025).
    case batchStarted(RunID, BatchID, [ToolCall])
    case batchSettled(RunID, BatchID, [ToolOutcome])
    case batchConsumed(RunID, BatchID)
    case runTerminal(RunID, RunStatus, TerminalCause)

    public var runID: RunID {
        switch self {
        case .runCreated(let id, _, _), .runStarted(let id), .entryRecorded(let id, _),
             .batchStarted(let id, _, _),
             .batchSettled(let id, _, _), .batchConsumed(let id, _), .runTerminal(let id, _, _):
            id
        }
    }
}

public enum EventLogError: Error {
    /// A corrupt record that is not the last one in the journal. The log refuses to open rather
    /// than silently dropping committed history (STORE-009).
    case undecodableLine(index: Int, reason: String)
    /// Opening the journal found a torn tail record and could not truncate it.
    case repairFailed(reason: String)
    /// A previous append failed; the caller must roll back to a marker before writing again so the
    /// in-memory record list and the file cannot diverge.
    case repairRequired
    /// Rolling back failed. The journal is now unusable for the rest of this process.
    case rollbackFailed(reason: String)
    /// The journal is poisoned (a rollback already failed); no further writes are allowed.
    case unavailable(reason: String)
    case invalidMarker(marker: Int, recordCount: Int)
}

public protocol EventLogSink: Sendable {
    func append(line: String) throws
    func truncate(toLineCount count: Int) throws
    func readLines() throws -> [String]
}

public struct FileEventLogSink: EventLogSink {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func append(line: String) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            // A torn write can leave the previous record without its trailing newline. Never glue a
            // new record onto it (that would turn two records into one unparsable line).
            try handle.seek(toOffset: end - 1)
            let lastByte = try handle.read(upToCount: 1) ?? Data()
            if lastByte != Data([0x0A]) {
                try handle.write(contentsOf: Data([0x0A]))
            }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.synchronize()
    }

    public func truncate(toLineCount count: Int) throws {
        let kept = try readLines().prefix(count)
        let data = (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).data(using: .utf8) ?? Data()
        try data.write(to: url, options: .atomic)
    }

    public func readLines() throws -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // Lossy UTF-8 decoding keeps a torn multi-byte tail visible as a malformed record instead of
        // collapsing the whole journal to "no data".
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Append-only journal. Callers take a marker before a multi-record commit and roll back to it when
/// any append fails, so a half-written commit never becomes visible in memory (STORE-001, LOOP-002).
///
/// Opening policy (STORE-009): only the final record may be torn. It is truncated and counted in
/// `repairedTailRecordCount`; a corrupt record anywhere else throws `undecodableLine`, because
/// dropping committed history silently is worse than refusing to start.
public actor DurableEventLog {
    private let sink: any EventLogSink
    private var lines: [String]
    private var needsRepair = false
    private var poisonedReason: String?

    public private(set) var repairedTailRecordCount: Int

    public init(sink: any EventLogSink) throws {
        self.sink = sink
        var loaded = try sink.readLines()
        var repaired = 0

        if let last = loaded.last, (try? Self.decode(last)) == nil {
            loaded.removeLast()
            repaired = 1
            do {
                try sink.truncate(toLineCount: loaded.count)
            } catch {
                throw EventLogError.repairFailed(reason: "\(error)")
            }
        }
        for (index, line) in loaded.enumerated() where (try? Self.decode(line)) == nil {
            throw EventLogError.undecodableLine(index: index, reason: "malformed record")
        }

        self.lines = loaded
        self.repairedTailRecordCount = repaired
    }

    public var recordCount: Int { lines.count }

    public var isUsable: Bool { poisonedReason == nil }

    public func beginMarker() -> Int {
        lines.count
    }

    @discardableResult
    public func append(_ event: RecordedEvent) throws -> Int {
        if let reason = poisonedReason {
            throw EventLogError.unavailable(reason: reason)
        }
        guard !needsRepair else { throw EventLogError.repairRequired }
        let line = try Self.encode(event)
        do {
            try sink.append(line: line)
        } catch {
            // The sink may have written part of the line; only a rollback can make the journal
            // trustworthy again.
            needsRepair = true
            throw error
        }
        lines.append(line)
        return lines.count - 1
    }

    public func rollBack(to marker: Int) throws {
        if let reason = poisonedReason {
            throw EventLogError.unavailable(reason: reason)
        }
        guard marker >= 0, marker <= lines.count else {
            throw EventLogError.invalidMarker(marker: marker, recordCount: lines.count)
        }
        do {
            try sink.truncate(toLineCount: marker)
        } catch {
            poisonedReason = "rollback failed: \(error)"
            throw EventLogError.rollbackFailed(reason: "\(error)")
        }
        lines = Array(lines.prefix(marker))
        needsRepair = false
    }

    public func events() throws -> [RecordedEvent] {
        try lines.enumerated().map { index, line in
            do {
                return try Self.decode(line)
            } catch {
                throw EventLogError.undecodableLine(index: index, reason: "malformed record")
            }
        }
    }

    private static func encode(_ event: RecordedEvent) throws -> String {
        let data = try JSONEncoder().encode(event)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode(_ line: String) throws -> RecordedEvent {
        try JSONDecoder().decode(RecordedEvent.self, from: Data(line.utf8))
    }
}
