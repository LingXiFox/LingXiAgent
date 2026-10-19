import Foundation

public enum RecordedEvent: Sendable, Codable {
    case runCreated(RunID, SessionID, TurnID)
    case runStarted(RunID)
    case entryRecorded(RunID, ContextEntry)
    case batchSettled(RunID, BatchID, [ToolOutcome])
    case batchConsumed(RunID, BatchID)
    case runTerminal(RunID, RunStatus, TerminalCause)

    public var runID: RunID {
        switch self {
        case .runCreated(let id, _, _), .runStarted(let id), .entryRecorded(let id, _),
             .batchSettled(let id, _, _), .batchConsumed(let id, _), .runTerminal(let id, _, _):
            id
        }
    }
}

public enum EventLogError: Error {
    case undecodableLine(index: Int, reason: String)
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
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.synchronize()
    }

    public func truncate(toLineCount count: Int) throws {
        let kept = try readLines().prefix(count)
        let data = (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).data(using: .utf8) ?? Data()
        try data.write(to: url, options: .atomic)
    }

    public func readLines() throws -> [String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

/// Append-only journal. Callers take a marker before a multi-record commit and roll back to it when
/// any append fails, so a half-written commit never becomes visible in memory (STORE-001, LOOP-002).
public actor DurableEventLog {
    private let sink: any EventLogSink
    private var lines: [String]

    public init(sink: any EventLogSink) throws {
        self.sink = sink
        self.lines = try sink.readLines()
    }

    public var recordCount: Int { lines.count }

    public func beginMarker() -> Int {
        lines.count
    }

    @discardableResult
    public func append(_ event: RecordedEvent) throws -> Int {
        let line = try Self.encode(event)
        try sink.append(line: line)
        lines.append(line)
        return lines.count - 1
    }

    public func rollBack(to marker: Int) throws {
        try sink.truncate(toLineCount: marker)
        lines = Array(lines.prefix(marker))
    }

    public func events() throws -> [RecordedEvent] {
        try lines.enumerated().map { index, line in
            guard let event = try? Self.decode(line) else {
                throw EventLogError.undecodableLine(index: index, reason: "malformed record")
            }
            return event
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
