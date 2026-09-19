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

            // P0-C 单一同态权威校准：以实际成功落盘的 events.jsonl 末尾 cursor 为最终事实，消除 crash split-brain
            if let lastSeq = loadedEvents.last?.cursor.sequence {
                resolvedSeq = lastSeq
            } else if loadedEvents.isEmpty {
                resolvedSeq = 0
            }

            // 将权威 sequence 原子校准写回 meta.json，确保 meta 与 events 100% 对齐
            let correctedMeta = PersistedMeta(generationID: resolvedGen.rawValue, sequence: resolvedSeq)
            if let data = try? JSONEncoder().encode(correctedMeta) {
                try? data.write(to: metaURL, options: .atomic)
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
            let metaURL = sessionDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: sequence)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: metaURL, options: .atomic)
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
            let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
            var newContent = ""
            for env in events {
                if let envData = try? JSONEncoder().encode(env),
                   let s = String(data: envData, encoding: .utf8) {
                    newContent += s + "\n"
                }
            }
            try? Data(newContent.utf8).write(to: eventsURL, options: .atomic)
            let metaURL = sessionDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: sequence)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: metaURL, options: .atomic)
            }
        }
    }

    public func truncateEvents(afterSequence targetSeq: UInt64) {
        events.removeAll { $0.cursor.sequence > targetSeq }
        sequence = targetSeq
        if let dir = storageDirectory {
            let sessionDir = dir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
            let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
            var newContent = ""
            for env in events {
                if let envData = try? JSONEncoder().encode(env),
                   let s = String(data: envData, encoding: .utf8) {
                    newContent += s + "\n"
                }
            }
            try? Data(newContent.utf8).write(to: eventsURL, options: .atomic)
            let metaURL = sessionDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: sequence)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: metaURL, options: .atomic)
            }
        }
    }

    public func resetToEvents(_ newEvents: [SessionEventEnvelope]) {
        self.events = newEvents
        self.sequence = newEvents.last?.cursor.sequence ?? 0
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

    public func allEvents() -> [SessionEventEnvelope] {
        events
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

            // P0-C 单一同态权威校准：以实际成功落盘的 events.jsonl 末尾 cursor 为最终事实，消除 crash split-brain
            if let lastSeq = loadedEvents.last?.cursor.sequence {
                resolvedSeq = lastSeq
            } else if loadedEvents.isEmpty {
                resolvedSeq = 0
            }

            // 将权威 sequence 原子校准写回 meta.json，确保 meta 与 events 100% 对齐
            let correctedMeta = PersistedMeta(generationID: resolvedGen.rawValue, sequence: resolvedSeq)
            if let data = try? JSONEncoder().encode(correctedMeta) {
                try? data.write(to: metaURL, options: .atomic)
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
            let metaURL = runtimeDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: sequence)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: metaURL, options: .atomic)
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
            let eventsURL = runtimeDir.appendingPathComponent("events.jsonl")
            var newContent = ""
            for env in events {
                if let envData = try? JSONEncoder().encode(env),
                   let s = String(data: envData, encoding: .utf8) {
                    newContent += s + "\n"
                }
            }
            try? Data(newContent.utf8).write(to: eventsURL, options: .atomic)
            let metaURL = runtimeDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: sequence)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: metaURL, options: .atomic)
            }
        }
    }

    public func truncateEvents(afterSequence targetSeq: UInt64) {
        events.removeAll { $0.cursor.sequence > targetSeq }
        sequence = targetSeq
        if let dir = storageDirectory {
            let runtimeDir = dir.appendingPathComponent("runtime", isDirectory: true)
            let eventsURL = runtimeDir.appendingPathComponent("events.jsonl")
            var newContent = ""
            for env in events {
                if let envData = try? JSONEncoder().encode(env),
                   let s = String(data: envData, encoding: .utf8) {
                    newContent += s + "\n"
                }
            }
            try? Data(newContent.utf8).write(to: eventsURL, options: .atomic)
            let metaURL = runtimeDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: sequence)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: metaURL, options: .atomic)
            }
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

/// IdempotencyJournal: Persistent deduplication journal ensuring at-most-once side-effects per CommandID.
public actor IdempotencyJournal {
    public struct JournalEntry: Codable, Sendable {
        public let commandID: String
        public let commandName: String?
        public let payloadFingerprint: String?
        public let receiptType: String
        public let receiptData: Data

        public init(
            commandID: String,
            commandName: String? = nil,
            payloadFingerprint: String? = nil,
            receiptType: String,
            receiptData: Data
        ) {
            self.commandID = commandID
            self.commandName = commandName
            self.payloadFingerprint = payloadFingerprint
            self.receiptType = receiptType
            self.receiptData = receiptData
        }
    }

    public enum LookupResult<R: Codable & Sendable> {
        case hit(CommandReceipt<R>)
        case conflict(existingType: String, requestedType: String, reason: String)
        case notFound
    }

    private var journal: [CommandID: JournalEntry] = [:]
    private let storageDirectory: URL?

    public init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory
        if let dir = storageDirectory {
            let journalDir = dir.appendingPathComponent("idempotency", isDirectory: true)
            try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
            if let fileURLs = try? FileManager.default.contentsOfDirectory(at: journalDir, includingPropertiesForKeys: nil) {
                for fileURL in fileURLs where fileURL.pathExtension == "json" {
                    if let data = try? Data(contentsOf: fileURL) {
                        if let entry = try? JSONDecoder().decode(JournalEntry.self, from: data) {
                            journal[CommandID(entry.commandID)] = entry
                        } else {
                            // Backward compatibility for legacy raw receipt format
                            let cmdStr = fileURL.deletingPathExtension().lastPathComponent
                            let legacy = JournalEntry(commandID: cmdStr, receiptType: "unknown", receiptData: data)
                            journal[CommandID(cmdStr)] = legacy
                        }
                    }
                }
            }
        }
    }

    public func lookup<R: Codable & Sendable>(
        commandID: CommandID,
        commandName: String? = nil,
        payloadFingerprint: String? = nil,
        as type: R.Type
    ) -> LookupResult<R> {
        guard let entry = journal[commandID] else { return .notFound }
        let expectedType = String(reflecting: R.self)
        if entry.receiptType != "unknown" && entry.receiptType != expectedType {
            return .conflict(existingType: entry.receiptType, requestedType: expectedType, reason: "Receipt type mismatch: existing=\(entry.receiptType) requested=\(expectedType)")
        }
        if let expectedName = commandName, let recordedName = entry.commandName, expectedName != recordedName {
            return .conflict(existingType: entry.receiptType, requestedType: expectedType, reason: "Command method mismatch: recorded=\(recordedName) requested=\(expectedName)")
        }
        if let expectedFP = payloadFingerprint, let recordedFP = entry.payloadFingerprint, expectedFP != recordedFP {
            return .conflict(existingType: entry.receiptType, requestedType: expectedType, reason: "Payload fingerprint mismatch for identical CommandID")
        }
        guard let receipt = try? JSONDecoder().decode(CommandReceipt<R>.self, from: entry.receiptData) else {
            return .conflict(existingType: entry.receiptType, requestedType: expectedType, reason: "Receipt decode failure")
        }
        return .hit(receipt)
    }

    public func get<R: Codable & Sendable>(
        commandID: CommandID,
        commandName: String? = nil,
        payloadFingerprint: String? = nil,
        as type: R.Type
    ) -> CommandReceipt<R>? {
        if case let .hit(receipt) = lookup(commandID: commandID, commandName: commandName, payloadFingerprint: payloadFingerprint, as: type) {
            return receipt
        }
        return nil
    }

    public func record<R: Codable & Sendable>(
        commandID: CommandID,
        commandName: String? = nil,
        payloadFingerprint: String? = nil,
        receipt: CommandReceipt<R>
    ) throws {
        try CommandStorageSecurity.validate(commandID)
        let data = try JSONEncoder().encode(receipt)
        let entry = JournalEntry(
            commandID: commandID.rawValue,
            commandName: commandName,
            payloadFingerprint: payloadFingerprint,
            receiptType: String(reflecting: R.self),
            receiptData: data
        )
        journal[commandID] = entry
        if let dir = storageDirectory {
            let journalDir = dir.appendingPathComponent("idempotency", isDirectory: true)
            let safeKey = CommandStorageSecurity.safeStorageKey(for: commandID)
            let fileURL = journalDir.appendingPathComponent("\(safeKey).json")
            let recordData = try JSONEncoder().encode(entry)
            try recordData.write(to: fileURL)
        }
    }

    public func rollback(commandID: CommandID) {
        journal.removeValue(forKey: commandID)
        if let dir = storageDirectory {
            let journalDir = dir.appendingPathComponent("idempotency", isDirectory: true)
            let safeKey = CommandStorageSecurity.safeStorageKey(for: commandID)
            let fileURL = journalDir.appendingPathComponent("\(safeKey).json")
            try? FileManager.default.removeItem(at: fileURL)
            let legacyURL = journalDir.appendingPathComponent("\(commandID.rawValue).json")
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }
}
