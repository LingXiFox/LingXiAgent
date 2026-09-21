import Foundation
import LingXiPlatform
import LingXiProtocol

/// 单次文件修改日志项（对应 Spec 12.1）
public struct FileMutation: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let turnID: TurnID
    public let revision: UInt64
    public let toolCallID: ToolCallID
    public let path: String
    public let beforeHash: String?
    public let beforeContent: Data?
    public let afterHash: String?
    public let afterContent: Data?
    public let createdAt: Date

    public init(
        sessionID: SessionID,
        turnID: TurnID,
        revision: UInt64,
        toolCallID: ToolCallID,
        path: String,
        beforeHash: String?,
        beforeContent: Data?,
        afterHash: String?,
        afterContent: Data?,
        createdAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.revision = revision
        self.toolCallID = toolCallID
        self.path = path
        self.beforeHash = beforeHash
        self.beforeContent = beforeContent
        self.afterHash = afterHash
        self.afterContent = afterContent
        self.createdAt = createdAt
    }
}

/// 文件回滚操作单项结果
public enum FileRollbackAction: Sendable, Equatable {
    case restored(path: String)
    case deleted(path: String)
    case conflict(path: String, reason: String)
}

/// 文件回滚汇总报告
public struct FileRollbackReport: Sendable, Equatable {
    public let actions: [FileRollbackAction]

    public var hasConflicts: Bool {
        actions.contains {
            if case .conflict = $0 { return true }
            return false
        }
    }

    public var restoredCount: Int {
        actions.filter {
            if case .restored = $0 { return true }
            return false
        }.count
    }

    public var deletedCount: Int {
        actions.filter {
            if case .deleted = $0 { return true }
            return false
        }.count
    }

    public init(actions: [FileRollbackAction] = []) {
        self.actions = actions
    }
}

/// 文件修改日记与回滚引擎（对应 Spec 12.2 & 12.3）
public actor FileRollbackEngine {
    public init() {}

    public static func computeHash(data: Data) -> String {
        return "sha256:" + LingXiPlatform.crypto.sha256Hex(data)
    }

    public static func captureState(at url: URL) -> (hash: String?, content: Data?) {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return (nil, nil)
        }
        return (computeHash(data: data), data)
    }

    /// 倒序回滚指定的 FileMutation 列表
    public func rollbackMutations(
        _ mutations: [FileMutation],
        workspaceRoot: URL
    ) throws -> FileRollbackReport {
        var actions: [FileRollbackAction] = []

        // 严格倒序逆向处理本轮变更
        for mutation in mutations.reversed() {
            let targetURL = LingXiPlatform.path.isAbsolute(mutation.path)
                ? URL(fileURLWithPath: mutation.path)
                : workspaceRoot.appendingPathComponent(mutation.path)

            let exists = FileManager.default.fileExists(atPath: targetURL.path)
            if exists {
                let currentData = try? Data(contentsOf: targetURL)
                let currentHash = currentData.map(Self.computeHash)

                if currentHash == mutation.afterHash {
                    if let beforeContent = mutation.beforeContent {
                        // 文件在修改后未被变动：安全恢复修改前内容
                        try beforeContent.write(to: targetURL, options: .atomic)
                        actions.append(.restored(path: mutation.path))
                    } else {
                        // 该文件是 Agent 新建的且未被变动：安全删除
                        try FileManager.default.removeItem(at: targetURL)
                        actions.append(.deleted(path: mutation.path))
                    }
                } else if currentHash == mutation.beforeHash {
                    // P0-C Idempotency Invariant:
                    // 当前文件内容已与 beforeHash 一致，说明在此前的回滚阶段（或崩溃重试前）已成功还原。
                    // 处于目标收敛状态，作为幂等 no-op 处理，绝不误报 conflict！
                    actions.append(.restored(path: mutation.path))
                } else {
                    // 文件在 Agent 修改后又被外部篡改：安全优先，不盲目覆盖，报告 conflict
                    actions.append(.conflict(
                        path: mutation.path,
                        reason: "File was modified externally after agent change (current hash != expected after hash)"
                    ))
                }
            } else {
                if let beforeContent = mutation.beforeContent {
                    // 文件不存在但修改前存在：重建恢复
                    try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try beforeContent.write(to: targetURL, options: .atomic)
                    actions.append(.restored(path: mutation.path))
                } else {
                    // P0-C Idempotency Invariant:
                    // 该文件为 Agent 新建文件（beforeContent == nil），且当前磁盘上已不存在。
                    // 说明在此前的回滚阶段（或崩溃重试前）已成功删除，处于目标收敛状态，作为幂等 no-op 处理！
                    actions.append(.deleted(path: mutation.path))
                }
            }
        }

        return FileRollbackReport(actions: actions)
    }
}
