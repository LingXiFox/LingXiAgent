import Foundation
import LingXiProtocol

private extension Data {
    func writePlatformSafe(to url: URL) throws {
        #if os(Windows)
        try write(to: url, options: [])
        #else
        try write(to: url, options: .atomic)
        #endif
    }
}

/// SessionEventLog：管理单个 Session 的因果事件日志与 Replay 边界。
public actor SessionEventLog {
    private struct PersistedMeta: Codable {
        let generationID: String
        var sequence: UInt64
    }

    public let sessionID: SessionID
    public let generationID: EventLogGenerationID
    public private(set) var sequence: UInt64
    public private(set) var isDegraded: Bool = false
    private var events: [SessionEventEnvelope]
    private var subscribers: [UUID: AsyncStream<SessionEventEnvelope>.Continuation]
    private let maxRetainedEvents: Int
    private let storageDirectory: URL?

    public init(
        sessionID: SessionID,
        generationID: EventLogGenerationID? = nil,
        initialSequence: UInt64 = 0,
        maxRetainedEvents: Int = 10_000,
        storageDirectory: URL? = nil,
        isDegraded: Bool = false
    ) {
        self.sessionID = sessionID
        self.maxRetainedEvents = maxRetainedEvents
        self.storageDirectory = storageDirectory
        self.subscribers = [:]

        var resolvedGen = generationID ?? EventLogGenerationID("gen-\(sessionID.rawValue)")
        var resolvedSeq = initialSequence
        var loadedEvents: [SessionEventEnvelope] = []
        var degradedState = isDegraded

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
            if let fileData = try? Data(contentsOf: eventsURL), !fileData.isEmpty {
                let decoder = JSONDecoder()
                var validByteOffset: UInt64 = 0
                var currentLineStart = 0
                let totalBytes = fileData.count

                for i in 0..<totalBytes {
                    if fileData[i] == 0x0A { // 换行符 '\n'
                        let lineRange = currentLineStart..<i
                        currentLineStart = i + 1
                        if lineRange.isEmpty { continue }
                        let lineBytes = fileData.subdata(in: lineRange)
                        if let envelope = try? decoder.decode(SessionEventEnvelope.self, from: lineBytes) {
                            loadedEvents.append(envelope)
                            validByteOffset = UInt64(i + 1)
                        }
                    }
                }

                // P0-B & P0-C: 自动识别并截断 torn/partial tail，若截断失败显式进入 degraded 状态，杜绝向坏 tail 追加
                if validByteOffset < UInt64(totalBytes) {
                    do {
                        let fileHandle = try FileHandle(forWritingTo: eventsURL)
                        try fileHandle.truncate(atOffset: validByteOffset)
                        try fileHandle.close()
                    } catch {
                        degradedState = true
                    }
                }
            }

            // P1: 长 Session 重启 retention 截断，防止内存无限制膨胀
            if loadedEvents.count > maxRetainedEvents {
                loadedEvents = Array(loadedEvents.suffix(maxRetainedEvents))
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
                try? data.writePlatformSafe(to: metaURL)
            }
        }

        self.generationID = resolvedGen
        self.sequence = resolvedSeq
        self.events = loadedEvents
        self.isDegraded = degradedState
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
    public func append(causal: CausalContext, payload: SessionEventPayload) throws -> SessionEventEnvelope {
        if isDegraded {
            throw RuntimeError(
                category: .runtime,
                code: "eventLogDegraded",
                message: "SessionEventLog is in degraded state: torn tail recovery failed",
                retryability: .none,
                source: .core
            )
        }

        let nextSeq = sequence + 1
        let cursor = EventCursor(generationID: generationID, sequence: nextSeq)
        let envelope = SessionEventEnvelope(cursor: cursor, timestamp: Date(), causal: causal, payload: payload)

        if let dir = storageDirectory {
            let sessionDir = dir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
            let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
            let envelopeData = try JSONEncoder().encode(envelope)
            guard let lineStr = String(data: envelopeData, encoding: .utf8) else {
                throw RuntimeError(category: .runtime, code: "eventEncodingFailed", message: "Failed to encode event to UTF-8", retryability: .none, source: .core)
            }
            let lineToAppend = lineStr + "\n"
            let lineData = Data(lineToAppend.utf8)

            if FileManager.default.fileExists(atPath: eventsURL.path) {
                let fileHandle = try FileHandle(forWritingTo: eventsURL)
                defer { try? fileHandle.close() }
                _ = try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: lineData)
                try fileHandle.synchronize()
            } else {
                try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
                try lineData.writePlatformSafe(to: eventsURL)
            }

            // P0-B Single Commit Point Invariant:
            // events.jsonl 是权威落盘事实。一旦写入并物理刷盘成功，事务即已不可逆 durable。
            // 此时必须立即推进内存 sequence，杜绝因后续 meta.json 缓存写失败而回退 sequence 造成重复序列号分裂！
            sequence = nextSeq
            events.append(envelope)
            if events.count > maxRetainedEvents {
                events.removeFirst(events.count - maxRetainedEvents)
            }

            let metaURL = sessionDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: nextSeq)
            if let metaData = try? JSONEncoder().encode(meta) {
                try? metaData.writePlatformSafe(to: metaURL)
            }
        } else {
            sequence = nextSeq
            events.append(envelope)
            if events.count > maxRetainedEvents {
                events.removeFirst(events.count - maxRetainedEvents)
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
            try? Data(newContent.utf8).writePlatformSafe(to: eventsURL)
            let metaURL = sessionDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: sequence)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.writePlatformSafe(to: metaURL)
            }
        }
    }

    public func truncateEvents(afterSequence targetSeq: UInt64) throws {
        let remainingEvents = events.filter { $0.cursor.sequence <= targetSeq }
        if let dir = storageDirectory {
            let sessionDir = dir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
            let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
            var newContent = ""
            for env in remainingEvents {
                let envData = try JSONEncoder().encode(env)
                if let s = String(data: envData, encoding: .utf8) {
                    newContent += s + "\n"
                }
            }
            try Data(newContent.utf8).writePlatformSafe(to: eventsURL)

            // P0-C Invariant: events.jsonl 是权威落盘事实。一旦原子写入成功，截断即已不可逆生效！
            // 此时必须立即推进内存状态，杜绝后续 meta.json 缓存写失败导致磁盘已截断但内存仍是旧 sequence 的脑裂！
            events = remainingEvents
            sequence = targetSeq

            let metaURL = sessionDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: targetSeq)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.writePlatformSafe(to: metaURL)
            }
        } else {
            events = remainingEvents
            sequence = targetSeq
        }
    }

    public func resetToEvents(_ newEvents: [SessionEventEnvelope]) throws {
        let newSeq = newEvents.last?.cursor.sequence ?? 0
        if let dir = storageDirectory {
            let sessionDir = dir.appendingPathComponent("sessions/\(sessionID.rawValue)", isDirectory: true)
            try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
            var newContent = ""
            for env in newEvents {
                let envData = try JSONEncoder().encode(env)
                if let s = String(data: envData, encoding: .utf8) {
                    newContent += s + "\n"
                }
            }
            try Data(newContent.utf8).writePlatformSafe(to: eventsURL)

            let metaURL = sessionDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: newSeq)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.writePlatformSafe(to: metaURL)
            }
        }

        // P0-C Invariant: 磁盘写入成功后才更新内存状态，绝不造成分裂
        self.events = newEvents
        self.sequence = newSeq
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
    public private(set) var isDegraded: Bool = false
    private var events: [RuntimeEventEnvelope]
    private var subscribers: [UUID: AsyncStream<RuntimeEventEnvelope>.Continuation]
    private let maxRetainedEvents: Int
    private let storageDirectory: URL?

    public init(
        generationID: EventLogGenerationID? = nil,
        initialSequence: UInt64 = 0,
        maxRetainedEvents: Int = 5_000,
        storageDirectory: URL? = nil,
        isDegraded: Bool = false
    ) {
        self.maxRetainedEvents = maxRetainedEvents
        self.storageDirectory = storageDirectory
        self.subscribers = [:]

        var resolvedGen = generationID ?? EventLogGenerationID("gen-runtime-global")
        var resolvedSeq = initialSequence
        var loadedEvents: [RuntimeEventEnvelope] = []
        var degradedState = isDegraded

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
            if let fileData = try? Data(contentsOf: eventsURL), !fileData.isEmpty {
                let decoder = JSONDecoder()
                var validByteOffset: UInt64 = 0
                var currentLineStart = 0
                let totalBytes = fileData.count

                for i in 0..<totalBytes {
                    if fileData[i] == 0x0A { // 换行符 '\n'
                        let lineRange = currentLineStart..<i
                        currentLineStart = i + 1
                        if lineRange.isEmpty { continue }
                        let lineBytes = fileData.subdata(in: lineRange)
                        if let envelope = try? decoder.decode(RuntimeEventEnvelope.self, from: lineBytes) {
                            loadedEvents.append(envelope)
                            validByteOffset = UInt64(i + 1)
                        }
                    }
                }

                // P0-B & P0-C: 自动识别并截断 torn/partial tail，若截断失败显式进入 degraded 状态，杜绝向坏 tail 追加
                if validByteOffset < UInt64(totalBytes) {
                    do {
                        let fileHandle = try FileHandle(forWritingTo: eventsURL)
                        try fileHandle.truncate(atOffset: validByteOffset)
                        try fileHandle.close()
                    } catch {
                        degradedState = true
                    }
                }
            }

            // P1: 长 Runtime EventLog 重启 retention 截断，防止内存无限制膨胀
            if loadedEvents.count > maxRetainedEvents {
                loadedEvents = Array(loadedEvents.suffix(maxRetainedEvents))
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
                try? data.writePlatformSafe(to: metaURL)
            }
        }

        self.generationID = resolvedGen
        self.sequence = resolvedSeq
        self.events = loadedEvents
        self.isDegraded = degradedState
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
    public func append(payload: RuntimeEventPayload) throws -> RuntimeEventEnvelope {
        if isDegraded {
            throw RuntimeError(
                category: .runtime,
                code: "eventLogDegraded",
                message: "RuntimeEventLog is in degraded state: torn tail recovery failed",
                retryability: .none,
                source: .core
            )
        }

        let nextSeq = sequence + 1
        let cursor = EventCursor(generationID: generationID, sequence: nextSeq)
        let envelope = RuntimeEventEnvelope(cursor: cursor, timestamp: Date(), payload: payload)

        if let dir = storageDirectory {
            let runtimeDir = dir.appendingPathComponent("runtime", isDirectory: true)
            let eventsURL = runtimeDir.appendingPathComponent("events.jsonl")
            let envelopeData = try JSONEncoder().encode(envelope)
            guard let lineStr = String(data: envelopeData, encoding: .utf8) else {
                throw RuntimeError(category: .runtime, code: "eventEncodingFailed", message: "Failed to encode event to UTF-8", retryability: .none, source: .core)
            }
            let lineToAppend = lineStr + "\n"
            let lineData = Data(lineToAppend.utf8)

            if FileManager.default.fileExists(atPath: eventsURL.path) {
                let fileHandle = try FileHandle(forWritingTo: eventsURL)
                defer { try? fileHandle.close() }
                _ = try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: lineData)
                try fileHandle.synchronize()
            } else {
                try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
                try lineData.writePlatformSafe(to: eventsURL)
            }

            // P0-B Single Commit Point Invariant:
            // events.jsonl 是权威落盘事实。一旦写入并物理刷盘成功，事务即已不可逆 durable。
            // 此时必须立即推进内存 sequence，杜绝因后续 meta.json 缓存写失败而回退 sequence 造成重复序列号分裂！
            sequence = nextSeq
            events.append(envelope)
            if events.count > maxRetainedEvents {
                events.removeFirst(events.count - maxRetainedEvents)
            }

            let metaURL = runtimeDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: nextSeq)
            if let metaData = try? JSONEncoder().encode(meta) {
                try? metaData.writePlatformSafe(to: metaURL)
            }
        } else {
            sequence = nextSeq
            events.append(envelope)
            if events.count > maxRetainedEvents {
                events.removeFirst(events.count - maxRetainedEvents)
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
            try? Data(newContent.utf8).writePlatformSafe(to: eventsURL)
            let metaURL = runtimeDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: sequence)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.writePlatformSafe(to: metaURL)
            }
        }
    }

    public func truncateEvents(afterSequence targetSeq: UInt64) throws {
        let remainingEvents = events.filter { $0.cursor.sequence <= targetSeq }
        if let dir = storageDirectory {
            let runtimeDir = dir.appendingPathComponent("runtime", isDirectory: true)
            let eventsURL = runtimeDir.appendingPathComponent("events.jsonl")
            var newContent = ""
            for env in remainingEvents {
                let envData = try JSONEncoder().encode(env)
                if let s = String(data: envData, encoding: .utf8) {
                    newContent += s + "\n"
                }
            }
            try Data(newContent.utf8).writePlatformSafe(to: eventsURL)

            // P0-C Invariant: events.jsonl 是权威落盘事实。一旦原子写入成功，截断即已不可逆生效！
            // 此时必须立即推进内存状态，杜绝后续 meta.json 缓存写失败导致磁盘已截断但内存仍是旧 sequence 的脑裂！
            events = remainingEvents
            sequence = targetSeq

            let metaURL = runtimeDir.appendingPathComponent("meta.json")
            let meta = PersistedMeta(generationID: generationID.rawValue, sequence: targetSeq)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.writePlatformSafe(to: metaURL)
            }
        } else {
            events = remainingEvents
            sequence = targetSeq
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
    public private(set) var quarantinedCorruptEntries: [String] = []

    public init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory
        if let dir = storageDirectory {
            let journalDir = dir.appendingPathComponent("idempotency", isDirectory: true)
            try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
            if let fileURLs = try? FileManager.default.contentsOfDirectory(at: journalDir, includingPropertiesForKeys: nil) {
                for fileURL in fileURLs where fileURL.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
                        // 损坏或空文件，隔离为 .corrupt
                        let corruptURL = fileURL.deletingPathExtension().appendingPathExtension("corrupt")
                        try? FileManager.default.removeItem(at: corruptURL)
                        try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
                        quarantinedCorruptEntries.append(fileURL.lastPathComponent)
                        continue
                    }

                    if let entry = try? JSONDecoder().decode(JournalEntry.self, from: data) {
                        journal[CommandID(entry.commandID)] = entry
                    } else {
                        // Invariant: Never assume SHA-256 hash filename is raw commandID!
                        // If file is corrupt or not a valid JournalEntry, quarantine it.
                        let corruptURL = fileURL.deletingPathExtension().appendingPathExtension("corrupt")
                        try? FileManager.default.removeItem(at: corruptURL)
                        try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
                        quarantinedCorruptEntries.append(fileURL.lastPathComponent)
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
        if let dir = storageDirectory {
            let journalDir = dir.appendingPathComponent("idempotency", isDirectory: true)
            let safeKey = CommandStorageSecurity.safeStorageKey(for: commandID)
            let fileURL = journalDir.appendingPathComponent("\(safeKey).json")
            let recordData = try JSONEncoder().encode(entry)
            try recordData.writePlatformSafe(to: fileURL)
        }
        journal[commandID] = entry
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
