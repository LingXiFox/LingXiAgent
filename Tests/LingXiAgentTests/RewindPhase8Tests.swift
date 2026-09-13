import Testing
import Foundation
@testable import LingXiCore
@testable import LingXiProtocol

@Suite("RewindPhase8Tests")
struct RewindPhase8Tests {

    /// 12.3 新创建文件：撤回时若内容仍等于 Agent 写入结果，则安全删除文件
    @Test
    func createdFileDeletedOnRollback() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("new_created_file.txt")
        let content = "Hello newly created file content"
        let data = Data(content.utf8)
        try data.write(to: fileURL)

        let engine = FileRollbackEngine()
        let afterHash = FileRollbackEngine.computeHash(data: data)

        let mutation = FileMutation(
            sessionID: SessionID("s-1"),
            turnID: TurnID("t-1"),
            revision: 1,
            toolCallID: ToolCallID("c-1"),
            path: "new_created_file.txt",
            beforeHash: nil,
            beforeContent: nil,
            afterHash: afterHash,
            afterContent: data
        )

        let report = try await engine.rollbackMutations([mutation], workspaceRoot: tmpDir)

        #expect(!report.hasConflicts)
        #expect(report.deletedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// 12.3 已有文件编辑：撤回时安全恢复为 beforeContent
    @Test
    func editedFileRestoredOnRollback() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("existing_file.txt")
        let originalContent = "Original line 1\nOriginal line 2\n"
        let editedContent = "Original line 1\nOriginal line 2 EDITED\n"

        let originalData = Data(originalContent.utf8)
        let editedData = Data(editedContent.utf8)

        // 模拟 Agent 刚刚写入了 editedData
        try editedData.write(to: fileURL)

        let engine = FileRollbackEngine()
        let beforeHash = FileRollbackEngine.computeHash(data: originalData)
        let afterHash = FileRollbackEngine.computeHash(data: editedData)

        let mutation = FileMutation(
            sessionID: SessionID("s-2"),
            turnID: TurnID("t-1"),
            revision: 1,
            toolCallID: ToolCallID("c-2"),
            path: "existing_file.txt",
            beforeHash: beforeHash,
            beforeContent: originalData,
            afterHash: afterHash,
            afterContent: editedData
        )

        let report = try await engine.rollbackMutations([mutation], workspaceRoot: tmpDir)

        #expect(!report.hasConflicts)
        #expect(report.restoredCount == 1)

        let restoredData = try Data(contentsOf: fileURL)
        let restoredString = String(decoding: restoredData, as: UTF8.self)
        #expect(restoredString == originalContent)
    }

    /// 12.3 冲突防护：如果文件在 Agent 修改后又被外部篡改，安全第一，不盲目覆盖
    @Test
    func externallyTamperedFileYieldsConflictWithoutOverwriting() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("conflict_file.txt")
        let beforeData = Data("before".utf8)
        let agentData = Data("agent edited".utf8)
        let userTamperedData = Data("user manual edit after agent".utf8)

        // 模拟用户在 Agent 之后手动进行了编辑
        try userTamperedData.write(to: fileURL)

        let engine = FileRollbackEngine()
        let mutation = FileMutation(
            sessionID: SessionID("s-3"),
            turnID: TurnID("t-1"),
            revision: 1,
            toolCallID: ToolCallID("c-3"),
            path: "conflict_file.txt",
            beforeHash: FileRollbackEngine.computeHash(data: beforeData),
            beforeContent: beforeData,
            afterHash: FileRollbackEngine.computeHash(data: agentData),
            afterContent: agentData
        )

        let report = try await engine.rollbackMutations([mutation], workspaceRoot: tmpDir)

        #expect(report.hasConflicts == true)
        #expect(report.restoredCount == 0)

        // 验证用户未保存的内容没有被粗暴冲掉
        let currentData = try Data(contentsOf: fileURL)
        let currentString = String(decoding: currentData, as: UTF8.self)
        #expect(currentString == "user manual edit after agent")
    }

    /// 端到端集成测试：CoreHost.revertLastTurn 联动 FileMutationJournal 逆向回滚文件
    @Test
    func coreHostRevertTriggersFileMutationRollback() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let persistence = try SQLitePersistenceStore(dataRoot: tmpDir, mainRoot: tmpDir)
        let store = PersistentSessionStore(persistence: persistence)
        let session = try await store.create()
        let workspace = try WorkspaceRoot(path: tmpDir.path)
        let host = try CoreHost(sessionStore: store, workspaceRoot: workspace, persistence: persistence)

        _ = try await store.appendMessage(session.id, role: .user, content: "Create file please")
        _ = try await store.appendMessage(session.id, role: .assistant, content: "File created")

        // 模拟 Agent 在该轮写入了一个文件
        let testFile = tmpDir.appendingPathComponent("rollback_target.txt")
        let agentContent = "Agent generated content"
        let agentData = Data(agentContent.utf8)
        try agentData.write(to: testFile)

        let mutation = FileMutation(
            sessionID: session.id,
            turnID: TurnID("turn-file"),
            revision: 1,
            toolCallID: ToolCallID("call-file"),
            path: "rollback_target.txt",
            beforeHash: nil,
            beforeContent: nil,
            afterHash: FileRollbackEngine.computeHash(data: agentData),
            afterContent: agentData
        )
        try await persistence.recordFileMutation(mutation)

        let recorded = try await persistence.loadFileMutations(sessionID: session.id)
        #expect(recorded.count == 1)

        // 执行会话撤回
        let req = RevertLastTurnRequest(sessionID: session.id)
        let receipt = try await host.revertLastTurn(envelope: CommandEnvelope(payload: req))
        #expect(receipt.applied == true)

        // 验证文件已经被逆向安全删除
        #expect(!FileManager.default.fileExists(atPath: testFile.path))

        // 验证 journal 中已清空
        let afterMutations = try await persistence.loadFileMutations(sessionID: session.id)
        #expect(afterMutations.isEmpty)
    }
}
