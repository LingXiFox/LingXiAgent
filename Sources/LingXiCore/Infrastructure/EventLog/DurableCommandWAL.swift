import Foundation
import LingXiProtocol

/// StagedWALRecord：描述单个 Command 事务的在途/已提交状态。
public struct StagedWALRecord: Codable, Sendable, Equatable {
    public let commandID: String
    public let commandName: String
    public var stage: String // "staged", "eventsAppended", "committed"
    public var createdSessionID: String?
    public var sessionID: String?
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

    /// 开始事务：写入 .wal 文件
    public func beginTransaction(commandID: CommandID, commandName: String) {
        guard let walDir else { return }
        let record = StagedWALRecord(commandID: commandID.rawValue, commandName: commandName, stage: "staged")
        writeWAL(record, to: walDir)
    }

    /// 记录状态机变更 (Phase 2)
    public func recordState(
        commandID: CommandID,
        createdSessionID: SessionID? = nil,
        sessionID: SessionID? = nil,
        turnID: TurnID? = nil,
        runID: RunID? = nil,
        initialRuntimeSequence: UInt64? = nil,
        initialSessionSequence: UInt64? = nil
    ) {
        guard let walDir else { return }
        var record = readWAL(commandID: commandID) ?? StagedWALRecord(commandID: commandID.rawValue, commandName: "unknown")
        if let createdSessionID { record.createdSessionID = createdSessionID.rawValue }
        if let sessionID { record.sessionID = sessionID.rawValue }
        if let turnID { record.turnID = turnID.rawValue }
        if let runID { record.runID = runID.rawValue }
        if let initialRuntimeSequence { record.initialRuntimeSequence = initialRuntimeSequence }
        if let initialSessionSequence { record.initialSessionSequence = initialSessionSequence }
        record.stage = "stateMutated"
        record.updatedAt = Date()
        writeWAL(record, to: walDir)
    }

    /// 记录语义事件已追加 (Phase 3)
    public func recordEventsAppended(commandID: CommandID) {
        guard let walDir else { return }
        guard var record = readWAL(commandID: commandID) else { return }
        record.stage = "eventsAppended"
        record.updatedAt = Date()
        writeWAL(record, to: walDir)
    }

    /// 提交事务：将 receipt 写入 committed_tx 并原子删除 .wal (Phase 4)
    public func commitTransaction<R: Codable & Sendable>(commandID: CommandID, receipt: CommandReceipt<R>) {
        guard let data = try? JSONEncoder().encode(receipt) else { return }
        if let committedDir {
            let committedURL = committedDir.appendingPathComponent("\(commandID.rawValue).json")
            try? data.write(to: committedURL)
        }
        if let walDir {
            let walURL = walDir.appendingPathComponent("\(commandID.rawValue).wal")
            try? FileManager.default.removeItem(at: walURL)
        }
    }

    /// 检查并获取已提交的 receipt
    public func getCommittedReceipt<R: Codable & Sendable>(commandID: CommandID, as type: R.Type) -> CommandReceipt<R>? {
        guard let committedDir else { return nil }
        let fileURL = committedDir.appendingPathComponent("\(commandID.rawValue).json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CommandReceipt<R>.self, from: data)
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
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }

            // 发现未提交的崩溃事务，必须自动消除未提交副作用！
            // 1. 如果该事务曾创建会话，删除未提交会话
            if let createdSession = record.createdSessionID {
                try? await sessionStore.deleteSession(SessionID(createdSession))
            }

            // 2. 如果该事务曾追加 Runtime 事件，截断回退至 initialRuntimeSequence
            if let initialRuntimeSeq = record.initialRuntimeSequence {
                await runtimeEventLog.truncateEvents(afterSequence: initialRuntimeSeq)
            }

            // 3. 如果该事务曾追加 Session 事件或创建 Turn/Run，回滚 Session 状态
            if let sessionIDStr = record.sessionID ?? record.createdSessionID {
                let sessionID = SessionID(sessionIDStr)
                if let coord = try? await coordinatorProvider(sessionID) {
                    if let initialSessionSeq = record.initialSessionSequence {
                        await coord.eventLog.truncateEvents(afterSequence: initialSessionSeq)
                    }
                    if let turnIDStr = record.turnID {
                        await coord.rollbackTurnID(TurnID(turnIDStr), runID: record.runID.flatMap { RunID($0) })
                    }
                }
            }

            // 4. 清除 .wal
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func readWAL(commandID: CommandID) -> StagedWALRecord? {
        guard let walDir else { return nil }
        let url = walDir.appendingPathComponent("\(commandID.rawValue).wal")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StagedWALRecord.self, from: data)
    }

    private func writeWAL(_ record: StagedWALRecord, to dir: URL) {
        let url = dir.appendingPathComponent("\(record.commandID).wal")
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: url)
        }
    }
}
