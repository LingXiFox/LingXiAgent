import Foundation
import LingXiProtocol

/// StagedWALRecord：描述单个 Command 事务的在途/已提交状态。
public struct StagedWALRecord: Codable, Sendable, Equatable {
    public let commandID: String
    public let commandName: String
    public var stage: String // "staged", "eventsAppended", "committed"
    public var createdSessionID: String?
    public var sessionID: String?
    public var stagedUserMessageID: String?
    public var turnID: String?
    public var runID: String?
    public var initialRuntimeSequence: UInt64?
    public var initialSessionSequence: UInt64?
    public var receiptData: Data?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        commandID: String,
        commandName: String,
        stage: String = "staged",
        createdSessionID: String? = nil,
        sessionID: String? = nil,
        stagedUserMessageID: String? = nil,
        turnID: String? = nil,
        runID: String? = nil,
        initialRuntimeSequence: UInt64? = nil,
        initialSessionSequence: UInt64? = nil,
        receiptData: Data? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.commandID = commandID
        self.commandName = commandName
        self.stage = stage
        self.createdSessionID = createdSessionID
        self.sessionID = sessionID
        self.stagedUserMessageID = stagedUserMessageID
        self.turnID = turnID
        self.runID = runID
        self.initialRuntimeSequence = initialRuntimeSequence
        self.initialSessionSequence = initialSessionSequence
        self.receiptData = receiptData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// DurableCommandWAL：管理磁盘 Write-Ahead Log 与进程崩溃恢复。
/// 保证在 state mutation、event append、receipt 任何阶段被 SIGKILL / exit 终止后，
/// 重新启动时能自动消除未提交的孤儿状态与孤儿事件，恢复原子性。
public actor DurableCommandWAL {
    public let storageDirectory: URL?
    private let walDir: URL?
    private let committedDir: URL?

    public init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory
        if let dir = storageDirectory {
            let base = dir.appendingPathComponent("wal", isDirectory: true)
            let committed = dir.appendingPathComponent("committed_tx", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: committed, withIntermediateDirectories: true)
            self.walDir = base
            self.committedDir = committed
        } else {
            self.walDir = nil
            self.committedDir = nil
        }
    }

    public private(set) var quarantinedCorruptWALs: [String] = []

    /// 开始事务：写入 .wal 文件（真正 Write-Ahead：支持在 mutation 发生前落盘定位标识）
    public func beginTransaction(
        commandID: CommandID,
        commandName: String,
        createdSessionID: String? = nil,
        sessionID: String? = nil,
        stagedUserMessageID: String? = nil,
        initialRuntimeSequence: UInt64? = nil,
        initialSessionSequence: UInt64? = nil
    ) throws {
        guard let walDir else { return }
        let record = StagedWALRecord(
            commandID: commandID.rawValue,
            commandName: commandName,
            stage: "staged",
            createdSessionID: createdSessionID,
            sessionID: sessionID,
            stagedUserMessageID: stagedUserMessageID,
            initialRuntimeSequence: initialRuntimeSequence,
            initialSessionSequence: initialSessionSequence
        )
        try writeWAL(record, to: walDir)
    }

    /// 记录状态机变更 (Phase 2)
    public func recordState(
        commandID: CommandID,
        createdSessionID: SessionID? = nil,
        sessionID: SessionID? = nil,
        stagedUserMessageID: MessageID? = nil,
        turnID: TurnID? = nil,
        runID: RunID? = nil,
        initialRuntimeSequence: UInt64? = nil,
        initialSessionSequence: UInt64? = nil
    ) throws {
        guard let walDir else { return }
        var record = readWAL(commandID: commandID) ?? StagedWALRecord(commandID: commandID.rawValue, commandName: "unknown")
        if let createdSessionID { record.createdSessionID = createdSessionID.rawValue }
        if let sessionID { record.sessionID = sessionID.rawValue }
        if let stagedUserMessageID { record.stagedUserMessageID = stagedUserMessageID.rawValue }
        if let turnID { record.turnID = turnID.rawValue }
        if let runID { record.runID = runID.rawValue }
        if let initialRuntimeSequence { record.initialRuntimeSequence = initialRuntimeSequence }
        if let initialSessionSequence { record.initialSessionSequence = initialSessionSequence }
        record.stage = "stateMutated"
        record.updatedAt = Date()
        try writeWAL(record, to: walDir)
    }

    /// 记录语义事件已追加 (Phase 3)
    public func recordEventsAppended(commandID: CommandID) throws {
        guard let walDir else { return }
        guard var record = readWAL(commandID: commandID) else { return }
        record.stage = "eventsAppended"
        record.updatedAt = Date()
        try writeWAL(record, to: walDir)
    }

    public struct CommittedTransactionRecord: Codable, Sendable {
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

    /// 提交事务：将 receipt 写入 committed_tx 并原子删除 .wal (Phase 4)
    public func commitTransaction<R: Codable & Sendable>(
        commandID: CommandID,
        commandName: String? = nil,
        payloadFingerprint: String? = nil,
        receipt: CommandReceipt<R>
    ) throws {
        let receiptData = try JSONEncoder().encode(receipt)
        let record = CommittedTransactionRecord(
            commandID: commandID.rawValue,
            commandName: commandName,
            payloadFingerprint: payloadFingerprint,
            receiptType: String(reflecting: R.self),
            receiptData: receiptData
        )
        let data = try JSONEncoder().encode(record)
        let safeKey = CommandStorageSecurity.safeStorageKey(for: commandID)
        if let committedDir {
            let committedURL = committedDir.appendingPathComponent("\(safeKey).json")
            // Invariant: Receipt write to disk must succeed BEFORE removing .wal
            try data.write(to: committedURL, options: .atomic)
        }
        if let walDir {
            let walURL = walDir.appendingPathComponent("\(safeKey).wal")
            try? FileManager.default.removeItem(at: walURL)
            // Also clean legacy path if it existed
            let legacyURL = walDir.appendingPathComponent("\(commandID.rawValue).wal")
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    /// 严格查找并校验已提交事务 receipt
    public func lookupCommittedReceipt<R: Codable & Sendable>(
        commandID: CommandID,
        commandName: String? = nil,
        payloadFingerprint: String? = nil,
        as type: R.Type
    ) -> IdempotencyJournal.LookupResult<R> {
        guard let committedDir else { return .notFound }
        let safeKey = CommandStorageSecurity.safeStorageKey(for: commandID)
        let fileURL = committedDir.appendingPathComponent("\(safeKey).json")
        let data: Data
        if let d = try? Data(contentsOf: fileURL) {
            data = d
        } else {
            let legacyURL = committedDir.appendingPathComponent("\(commandID.rawValue).json")
            guard let d = try? Data(contentsOf: legacyURL) else { return .notFound }
            data = d
        }

        let expectedType = String(reflecting: R.self)
        if let record = try? JSONDecoder().decode(CommittedTransactionRecord.self, from: data) {
            if record.receiptType != expectedType {
                return .conflict(existingType: record.receiptType, requestedType: expectedType, reason: "Receipt type mismatch in durable WAL: existing=\(record.receiptType) requested=\(expectedType)")
            }
            if let expectedName = commandName, let recordedName = record.commandName, expectedName != recordedName {
                return .conflict(existingType: record.receiptType, requestedType: expectedType, reason: "Command method mismatch in durable WAL: recorded=\(recordedName) requested=\(expectedName)")
            }
            if let expectedFP = payloadFingerprint, let recordedFP = record.payloadFingerprint, expectedFP != recordedFP {
                return .conflict(existingType: record.receiptType, requestedType: expectedType, reason: "Payload fingerprint mismatch in durable WAL")
            }
            guard let receipt = try? JSONDecoder().decode(CommandReceipt<R>.self, from: record.receiptData) else {
                return .conflict(existingType: record.receiptType, requestedType: expectedType, reason: "Receipt decode failure in durable WAL")
            }
            return .hit(receipt)
        }

        // Backward compatibility for legacy raw CommandReceipt<R> JSON
        if let receipt = try? JSONDecoder().decode(CommandReceipt<R>.self, from: data) {
            return .hit(receipt)
        }
        return .notFound
    }

    /// 检查并获取已提交的 receipt (兼容旧调用)
    public func getCommittedReceipt<R: Codable & Sendable>(
        commandID: CommandID,
        commandName: String? = nil,
        payloadFingerprint: String? = nil,
        as type: R.Type
    ) -> CommandReceipt<R>? {
        if case let .hit(receipt) = lookupCommittedReceipt(commandID: commandID, commandName: commandName, payloadFingerprint: payloadFingerprint, as: type) {
            return receipt
        }
        return nil
    }

    public func getCommittedReceipt<R: Codable & Sendable>(commandID: CommandID, as type: R.Type) -> CommandReceipt<R>? {
        getCommittedReceipt(commandID: commandID, commandName: nil, payloadFingerprint: nil, as: type)
    }

    /// 进程重启恢复：回滚所有未达到 committed 阶段的孤儿状态与孤儿事件
    public func recover(
        sessionStore: any SessionStore,
        runtimeEventLog: RuntimeEventLog,
        coordinatorProvider: (SessionID) async throws -> SessionTurnCoordinator
    ) async {
        guard let walDir else { return }
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: walDir, includingPropertiesForKeys: nil) else { return }

        for fileURL in fileURLs where fileURL.pathExtension == "wal" {
            guard let data = try? Data(contentsOf: fileURL),
                  let record = try? JSONDecoder().decode(StagedWALRecord.self, from: data) else {
                // Invariant: Never silently delete corrupted WAL files. Quarantine them as .corrupt.
                let corruptURL = fileURL.deletingPathExtension().appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: corruptURL)
                try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
                quarantinedCorruptWALs.append(fileURL.lastPathComponent)
                continue
            }

            // P0-D 核心不变量防御：检查该 transaction 是否已经在 committedDir 中成功提交！
            // 如果已存在 committed receipt，说明这是 commitTransaction 后的清理遗留（stale WAL），
            // 绝对不能反向回滚已提交的成功事实！直接清理 stale WAL 即可。
            let cmdID = CommandID(record.commandID)
            let safeKey = CommandStorageSecurity.safeStorageKey(for: cmdID)
            let committedURL = committedDir?.appendingPathComponent("\(safeKey).json")
            let legacyCommittedURL = committedDir?.appendingPathComponent("\(cmdID.rawValue).json")
            let isCommitted = (committedURL != nil && FileManager.default.fileExists(atPath: committedURL!.path)) ||
                              (legacyCommittedURL != nil && FileManager.default.fileExists(atPath: legacyCommittedURL!.path))
            if isCommitted {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }

            // 发现未提交的崩溃事务，必须自动消除未提交副作用！
            var rollbackSuccess = true
            // 1. 如果该事务曾创建会话，删除未提交会话
            if let createdSession = record.createdSessionID {
                do {
                    try await sessionStore.deleteSession(SessionID(createdSession))
                } catch {
                    rollbackSuccess = false
                }
            }

            // 2. 如果该事务曾把用户消息写入了 SessionStore（running Turn 崩溃），必须精准移除该消息，彻底根除 orphan prompt！
            if let msgIDStr = record.stagedUserMessageID, let sessionIDStr = record.sessionID {
                let sessionID = SessionID(sessionIDStr)
                let msgID = MessageID(msgIDStr)
                do {
                    try await sessionStore.removeMessage(sessionID, messageID: msgID)
                } catch {
                    rollbackSuccess = false
                }
            }

            // 3. 如果该事务曾追加 Runtime 事件，截断回退至 initialRuntimeSequence
            if let initialRuntimeSeq = record.initialRuntimeSequence {
                await runtimeEventLog.truncateEvents(afterSequence: initialRuntimeSeq)
            }

            // 4. 如果该事务曾追加 Session 事件或创建 Turn/Run，回滚 Session 状态
            if let sessionIDStr = record.sessionID ?? record.createdSessionID {
                let sessionID = SessionID(sessionIDStr)
                if let coord = try? await coordinatorProvider(sessionID) {
                    if let initialSessionSeq = record.initialSessionSequence {
                        await coord.eventLog.truncateEvents(afterSequence: initialSessionSeq)
                    }
                    if let turnIDStr = record.turnID {
                        await coord.rollbackTurnID(TurnID(turnIDStr), runID: record.runID.flatMap { RunID($0) })
                    }
                } else {
                    rollbackSuccess = false
                }
            }

            // 5. 清除 .wal (仅在回滚成功后清除；回滚失败时保留供人工/诊断分析)
            if rollbackSuccess {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func readWAL(commandID: CommandID) -> StagedWALRecord? {
        guard let walDir else { return nil }
        let safeKey = CommandStorageSecurity.safeStorageKey(for: commandID)
        let url = walDir.appendingPathComponent("\(safeKey).wal")
        if let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(StagedWALRecord.self, from: data) {
            return record
        }
        // Fallback for legacy raw name
        let legacyURL = walDir.appendingPathComponent("\(commandID.rawValue).wal")
        guard let data = try? Data(contentsOf: legacyURL) else { return nil }
        return try? JSONDecoder().decode(StagedWALRecord.self, from: data)
    }

    private func writeWAL(_ record: StagedWALRecord, to dir: URL) throws {
        let safeKey = CommandStorageSecurity.safeStorageKey(for: CommandID(record.commandID))
        let url = dir.appendingPathComponent("\(safeKey).wal")
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
    }
}
