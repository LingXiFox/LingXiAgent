import Foundation
import LingXiProtocol

/// StagedWALRecord：描述单个 Command 事务的在途/已提交状态。
public struct StagedWALRecord: Codable, Sendable, Equatable {
    public let commandID: String
    public let commandName: String
    public var stage: String // "staged", "eventsAppended", "reverted", "committed"
    public var createdSessionID: String?
    public var sessionID: String?
    public var stagedUserMessageID: String?
    public var turnID: String?
    public var runID: String?
    public var initialRuntimeSequence: UInt64?
    public var initialSessionSequence: UInt64?
    public var revertedPrompt: String?
    public var removedMessageCount: Int?
    public var revertedRevision: UInt64?
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
        revertedPrompt: String? = nil,
        removedMessageCount: Int? = nil,
        revertedRevision: UInt64? = nil,
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
        self.revertedPrompt = revertedPrompt
        self.removedMessageCount = removedMessageCount
        self.revertedRevision = revertedRevision
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

    /// 记录 revertLastTurn 已完成破坏性状态修改（防止 SIGKILL 后重试造成双重撤回）
    public func recordRevertState(
        commandID: CommandID,
        sessionID: SessionID,
        revertedPrompt: String?,
        removedCount: Int,
        revision: UInt64
    ) throws {
        guard let walDir else { return }
        var record = readWAL(commandID: commandID) ?? StagedWALRecord(commandID: commandID.rawValue, commandName: "revertLastTurn")
        record.sessionID = sessionID.rawValue
        record.revertedPrompt = revertedPrompt
        record.removedMessageCount = removedCount
        record.revertedRevision = revision
        record.stage = "reverted"
        record.updatedAt = Date()
        try writeWAL(record, to: walDir)
    }

    /// 查询是否存在已完成破坏性修改的 revertLastTurn 记录
    public func lookupRevertedRecord(commandID: CommandID, sessionID: String) -> StagedWALRecord? {
        guard let record = readWAL(commandID: commandID) else { return nil }
        guard record.commandName == "revertLastTurn", record.sessionID == sessionID, (record.stage == "reverted" || record.revertedPrompt != nil || record.removedMessageCount != nil) else { return nil }
        return record
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

            // P0-D & P1/P0 核心不变量防御：检查该 transaction 是否已经在 committedDir 中成功提交！
            // 必须验证文件不仅存在，且能正确反序列化为合法的 CommittedTransactionRecord。
            let cmdID = CommandID(record.commandID)
            let safeKey = CommandStorageSecurity.safeStorageKey(for: cmdID)
            let committedURL = committedDir?.appendingPathComponent("\(safeKey).json")
            let legacyCommittedURL = committedDir?.appendingPathComponent("\(cmdID.rawValue).json")

            var isCommitted = false
            if let committedURL, let d = try? Data(contentsOf: committedURL), !d.isEmpty {
                if (try? JSONDecoder().decode(CommittedTransactionRecord.self, from: d)) != nil {
                    isCommitted = true
                }
            }
            if !isCommitted, let legacyCommittedURL, let d = try? Data(contentsOf: legacyCommittedURL), !d.isEmpty {
                if (try? JSONDecoder().decode(CommittedTransactionRecord.self, from: d)) != nil {
                    isCommitted = true
                }
            }
            if isCommitted {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }

            // P0-D Invariant: 如果是已完成破坏性修改的 revertLastTurn，保留 WAL 供后续同 CommandID 重试命中，
            // 绝不能在重启后将其清除导致重试发生二次撤回（Double-Revert）！
            if record.commandName == "revertLastTurn" && (record.stage == "reverted" || record.revertedPrompt != nil || record.removedMessageCount != nil) {
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
                do {
                    try await runtimeEventLog.truncateEvents(afterSequence: initialRuntimeSeq)
                } catch {
                    rollbackSuccess = false
                }
            }

            // 4. 如果该事务曾追加 Session 事件或创建 Turn/Run，回滚 Session 状态
            // P0-D Invariant: 若事务是未提交的 createSession，Step 1 已删除会话，无需且不能再调用 coordinatorProvider(createdSessionID)
            if let sessionIDStr = record.sessionID, record.createdSessionID == nil {
                let sessionID = SessionID(sessionIDStr)
                if let coord = try? await coordinatorProvider(sessionID) {
                    if let initialSessionSeq = record.initialSessionSequence {
                        do {
                            try await coord.eventLog.truncateEvents(afterSequence: initialSessionSeq)
                        } catch {
                            rollbackSuccess = false
                        }
                    }
                    if let turnIDStr = record.turnID {
                        await coord.rollbackTurnID(TurnID(turnIDStr), runID: record.runID.flatMap { RunID($0) })
                    }
                } else {
                    // 若会话在外部已不复存在，说明无需额外回滚；若会话依然存在但获取 coordinator 失败，才标记回滚未完成
                    if (try? await sessionStore.session(sessionID)) != nil {
                        rollbackSuccess = false
                    }
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
