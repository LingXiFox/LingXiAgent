import Foundation
import LingXiProtocol

/// SessionEventLog：管理单个 Session 的因果事件日志与 Replay 边界。
public actor SessionEventLog {
    private struct PersistedMeta: Codable {
        let generationID: String
        var sequence: UInt64
    }

    public let sessionID: SessionID
    public let generationID: EventLogGenerationID
    public private(set) var sequence: UInt64
    private var events: [SessionEventEnvelope]
    private var subscribers: [UUID: AsyncStream<SessionEventEnvelope>.Continuation]
    private let maxRetainedEvents: Int
    private let storageDirectory: URL?

    public init(
        sessionID: SessionID,
        generationID: EventLogGenerationID? = nil,
        initialSequence: UInt64 = 0,
        maxRetainedEvents: Int = 10_000,
        storageDirectory: URL? = nil
    ) {
        self.sessionID = sessionID
        self.maxRetainedEvents = maxRetainedEvents
        self.storageDirectory = storageDirectory
        self.subscribers = [:]

        var resolvedGen = generationID ?? EventLogGenerationID("gen-\(sessionID.rawValue)")
        var resolvedSeq = initialSequence
        var loadedEvents: [SessionEventEnvelope] = []

        if let dir = storageDirectory {
            let sessionDir = dir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
            try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            let metaURL = sessionDir.appendingPathComponent("meta.json")
            if let metaData = try? Data(contentsOf: metaURL),
               let meta = try? JSONDecoder().decode(PersistedMeta.self, from: metaData) {
                resolvedGen = generationID ?? EventLogGenerationID(meta.generationID)
                resolvedSeq = meta.sequence
            } else {
                let meta = PersistedMeta(generationID: resolvedGen.rawValue, sequence: resolvedSeq)
                if let data = try? JSONEncoder().encode(meta) {
                    try? data.write(to: metaURL)
                }
            }

            let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
            if let linesData = try? Data(contentsOf: eventsURL),
               let linesStr = String(data: linesData, encoding: .utf8) {
                let lines = linesStr.split(separator: "\n")
                let decoder = JSONDecoder()
                for line in lines {
                    if let lineData = line.data(using: .utf8),
                       let envelope = try? decoder.decode(SessionEventEnvelope.self, from: lineData) {
                        loadedEvents.append(envelope)
                    }
                }
            }
        }

        self.generationID = resolvedGen
        self.sequence = resolvedSeq
        self.events = loadedEvents
    }

    public func currentCursor() -> EventCursor {
        EventCursor(generationID: generationID, sequence: sequence)
    }

    public func currentSequence() -> UInt64 {
        sequence
    }

    public func currentWatermark() -> EventWatermark {
        EventWatermark(scope: .session(sessionID), cursor: currentCursor())
    }

    @discardableResult
    public func append(causal: CausalContext, payload: SessionEventPayload) -> SessionEventEnvelope {
        sequence += 1
        let cursor = EventCursor(generationID: generationID, sequence: sequence)
        let envelope = SessionEventEnvelope(cursor: cursor, timestamp: Date(), causal: causal, payload: payload)
        events.append(envelope)
        if events.count > maxRetainedEvents {
            events.removeFirst(events.count - maxRetainedEvents)
        }

        if let dir = storageDirectory {
            let sessionDir = dir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
            let metaURL = sessionDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: sequence)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: metaURL)
            }
            let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
            if let envelopeData = try? JSONEncoder().encode(envelope),
               let lineStr = String(data: envelopeData, encoding: .utf8) {
                let lineToAppend = lineStr + "\n"
                if FileManager.default.fileExists(atPath: eventsURL.path) {
                    if let fileHandle = try? FileHandle(forWritingTo: eventsURL) {
                        defer { try? fileHandle.close() }
                        _ = try? fileHandle.seekToEnd()
                        try? fileHandle.write(contentsOf: Data(lineToAppend.utf8))
                    }
                } else {
                    try? Data(lineToAppend.utf8).write(to: eventsURL)
                }
            }
        }

        for subscriber in subscribers.values {
            subscriber.yield(envelope)
        }
        return envelope
    }

    public func rollbackLastAppended() {
        guard !events.isEmpty else { return }
        events.removeLast()
        sequence = max(0, sequence - 1)
        if let dir = storageDirectory {
            let sessionDir = dir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
            let metaURL = sessionDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: sequence)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: metaURL)
            }
            let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
            var newContent = ""
            for env in events {
                if let envData = try? JSONEncoder().encode(env),
                   let s = String(data: envData, encoding: .utf8) {
                    newContent += s + "\n"
                }
            }
            try? Data(newContent.utf8).write(to: eventsURL)
        }
    }

    public func truncateEvents(afterSequence targetSeq: UInt64) {
        events.removeAll { $0.cursor.sequence > targetSeq }
        sequence = targetSeq
        if let dir = storageDirectory {
            let sessionDir = dir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
            let metaURL = sessionDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: sequence)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: metaURL)
            }
            let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
            var newContent = ""
            for env in events {
                if let envData = try? JSONEncoder().encode(env),
                   let s = String(data: envData, encoding: .utf8) {
                    newContent += s + "\n"
                }
            }
            try? Data(newContent.utf8).write(to: eventsURL)
        }
    }

    public func subscribe(after: EventCursor?) throws -> AsyncStream<SessionEventEnvelope> {
        var replayEvents: [SessionEventEnvelope] = []
        if let after {
            guard after.generationID == generationID else {
                throw RuntimeError(
                    category: .runtime,
                    code: "replayUnavailable",
                    message: "Generation mismatch: requested=\(after.generationID.rawValue) current=\(generationID.rawValue)",
                    retryability: .afterUserAction,
                    source: .core
                )
            }
            if let firstRetained = events.first, after.sequence < firstRetained.cursor.sequence - 1 {
                throw RuntimeError(
                    category: .runtime,
                    code: "replayUnavailable",
                    message: "Event log retention gap: requested sequence \(after.sequence) is older than earliest retained \(firstRetained.cursor.sequence)",
                    retryability: .afterUserAction,
                    source: .core
                )
            }
            replayEvents = events.filter { $0.cursor.sequence > after.sequence }
        }

        let key = UUID()
        return AsyncStream { continuation in
            for event in replayEvents {
                continuation.yield(event)
            }
            self.subscribers[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeSubscriber(key)
                }
            }
        }
    }

    public func listEvents(before: EventCursor?, after: EventCursor?, limit: Int) -> [SessionEventEnvelope] {
        var filtered = events
        if let after {
            filtered = filtered.filter { $0.cursor.sequence > after.sequence }
        }
        if let before {
            filtered = filtered.filter { $0.cursor.sequence < before.sequence }
        }
        if filtered.count > limit {
            return Array(filtered.prefix(limit))
        }
        return filtered
    }

    public func recentEvents(count: Int = 50) -> [SessionEventEnvelope] {
        if events.count > count {
            return Array(events.suffix(count))
        }
        return events
    }

    private func removeSubscriber(_ key: UUID) {
        subscribers.removeValue(forKey: key)
    }
}

/// RuntimeEventLog：管理全局 Runtime 级别的因果事件日志与 Replay。
public actor RuntimeEventLog {
    private struct PersistedMeta: Codable {
        let generationID: String
        var sequence: UInt64
    }

    public let generationID: EventLogGenerationID
    public private(set) var sequence: UInt64
    private var events: [RuntimeEventEnvelope]
    private var subscribers: [UUID: AsyncStream<RuntimeEventEnvelope>.Continuation]
    private let maxRetainedEvents: Int
    private let storageDirectory: URL?

    public init(
        generationID: EventLogGenerationID? = nil,
        initialSequence: UInt64 = 0,
        maxRetainedEvents: Int = 5_000,
        storageDirectory: URL? = nil
    ) {
        self.maxRetainedEvents = maxRetainedEvents
        self.storageDirectory = storageDirectory
        self.subscribers = [:]

        var resolvedGen = generationID ?? EventLogGenerationID("gen-runtime-global")
        var resolvedSeq = initialSequence
        var loadedEvents: [RuntimeEventEnvelope] = []

        if let dir = storageDirectory {
            let runtimeDir = dir.appendingPathComponent("runtime", isDirectory: true)
            try? FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
            let metaURL = runtimeDir.appendingPathComponent("meta.json")
            if let metaData = try? Data(contentsOf: metaURL),
               let meta = try? JSONDecoder().decode(PersistedMeta.self, from: metaData) {
                resolvedGen = generationID ?? EventLogGenerationID(meta.generationID)
                resolvedSeq = meta.sequence
            } else {
                let meta = PersistedMeta(generationID: resolvedGen.rawValue, sequence: resolvedSeq)
                if let data = try? JSONEncoder().encode(meta) {
                    try? data.write(to: metaURL)
                }
            }

            let eventsURL = runtimeDir.appendingPathComponent("events.jsonl")
            if let linesData = try? Data(contentsOf: eventsURL),
               let linesStr = String(data: linesData, encoding: .utf8) {
                let lines = linesStr.split(separator: "\n")
                let decoder = JSONDecoder()
                for line in lines {
                    if let lineData = line.data(using: .utf8),
                       let envelope = try? decoder.decode(RuntimeEventEnvelope.self, from: lineData) {
                        loadedEvents.append(envelope)
                    }
                }
            }
        }

        self.generationID = resolvedGen
        self.sequence = resolvedSeq
        self.events = loadedEvents
    }

    public func currentCursor() -> EventCursor {
        EventCursor(generationID: generationID, sequence: sequence)
    }

    public func currentSequence() -> UInt64 {
        sequence
    }

    public func currentWatermark() -> EventWatermark {
        EventWatermark(scope: .runtime, cursor: currentCursor())
    }

    @discardableResult
    public func append(payload: RuntimeEventPayload) -> RuntimeEventEnvelope {
        sequence += 1
        let cursor = EventCursor(generationID: generationID, sequence: sequence)
        let envelope = RuntimeEventEnvelope(cursor: cursor, timestamp: Date(), payload: payload)
        events.append(envelope)
        if events.count > maxRetainedEvents {
            events.removeFirst(events.count - maxRetainedEvents)
        }

        if let dir = storageDirectory {
            let runtimeDir = dir.appendingPathComponent("runtime", isDirectory: true)
            let metaURL = runtimeDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: sequence)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: metaURL)
            }
            let eventsURL = runtimeDir.appendingPathComponent("events.jsonl")
            if let envelopeData = try? JSONEncoder().encode(envelope),
               let lineStr = String(data: envelopeData, encoding: .utf8) {
                let lineToAppend = lineStr + "\n"
                if FileManager.default.fileExists(atPath: eventsURL.path) {
                    if let fileHandle = try? FileHandle(forWritingTo: eventsURL) {
                        defer { try? fileHandle.close() }
                        _ = try? fileHandle.seekToEnd()
                        try? fileHandle.write(contentsOf: Data(lineToAppend.utf8))
                    }
                } else {
                    try? Data(lineToAppend.utf8).write(to: eventsURL)
                }
            }
        }

        for subscriber in subscribers.values {
            subscriber.yield(envelope)
        }
        return envelope
    }

    public func rollbackLastAppended() {
        guard !events.isEmpty else { return }
        events.removeLast()
        sequence = max(0, sequence - 1)
        if let dir = storageDirectory {
            let runtimeDir = dir.appendingPathComponent("runtime", isDirectory: true)
            let metaURL = runtimeDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: sequence)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: metaURL)
            }
            let eventsURL = runtimeDir.appendingPathComponent("events.jsonl")
            var newContent = ""
            for env in events {
                if let envData = try? JSONEncoder().encode(env),
                   let s = String(data: envData, encoding: .utf8) {
                    newContent += s + "\n"
                }
            }
            try? Data(newContent.utf8).write(to: eventsURL)
        }
    }

    public func truncateEvents(afterSequence targetSeq: UInt64) {
        events.removeAll { $0.cursor.sequence > targetSeq }
        sequence = targetSeq
        if let dir = storageDirectory {
            let runtimeDir = dir.appendingPathComponent("runtime", isDirectory: true)
            let metaURL = runtimeDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: sequence)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: metaURL)
            }
            let eventsURL = runtimeDir.appendingPathComponent("events.jsonl")
            var newContent = ""
            for env in events {
                if let envData = try? JSONEncoder().encode(env),
                   let s = String(data: envData, encoding: .utf8) {
                    newContent += s + "\n"
                }
            }
            try? Data(newContent.utf8).write(to: eventsURL)
        }
    }

    public func subscribe(after: EventCursor?) -> AsyncStream<RuntimeEventEnvelope> {
        var replayEvents: [RuntimeEventEnvelope] = []
        if let after, after.generationID == generationID {
            replayEvents = events.filter { $0.cursor.sequence > after.sequence }
        }

        let key = UUID()
        return AsyncStream { continuation in
            for event in replayEvents {
                continuation.yield(event)
            }
            self.subscribers[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeSubscriber(key)
                }
            }
        }
    }

    private func removeSubscriber(_ key: UUID) {
        subscribers.removeValue(forKey: key)
    }
}

/// IdempotencyJournal：持久化命令去重日志，保证相同 commandID 不重复副作用。
public actor IdempotencyJournal {
    private struct Entry {
        let receiptData: Data
    }

    private var journal: [CommandID: Entry] = [:]
    private let storageDirectory: URL?

    public init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory
        if let dir = storageDirectory {
            let journalDir = dir.appendingPathComponent("idempotency", isDirectory: true)
            try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
            if let fileURLs = try? FileManager.default.contentsOfDirectory(at: journalDir, includingPropertiesForKeys: nil) {
                for fileURL in fileURLs where fileURL.pathExtension == "json" {
                    let cmdStr = fileURL.deletingPathExtension().lastPathComponent
                    if let data = try? Data(contentsOf: fileURL) {
                        journal[CommandID(cmdStr)] = Entry(receiptData: data)
                    }
                }
            }
        }
    }

    public func get<R: Codable & Sendable>(commandID: CommandID, as type: R.Type) -> CommandReceipt<R>? {
        guard let entry = journal[commandID] else { return nil }
        return try? JSONDecoder().decode(CommandReceipt<R>.self, from: entry.receiptData)
    }

    public func record<R: Codable & Sendable>(commandID: CommandID, receipt: CommandReceipt<R>) {
        guard let data = try? JSONEncoder().encode(receipt) else { return }
        journal[commandID] = Entry(receiptData: data)
        if let dir = storageDirectory {
            let journalDir = dir.appendingPathComponent("idempotency", isDirectory: true)
            let fileURL = journalDir.appendingPathComponent("\(commandID.rawValue).json")
            try? data.write(to: fileURL)
        }
    }

    public func rollback(commandID: CommandID) {
        journal.removeValue(forKey: commandID)
        if let dir = storageDirectory {
            let journalDir = dir.appendingPathComponent("idempotency", isDirectory: true)
            let fileURL = journalDir.appendingPathComponent("\(commandID.rawValue).json")
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
