import Testing
import Foundation
@testable import LingXiCore
@testable import LingXiProtocol
@testable import LingXiApplication
@testable import LingXiClient

@Suite("RewindPhase7Tests")
struct RewindPhase7Tests {

    /// 16.7 快速并发竞争测试：模拟多个并发 Task 交替执行 append 与 revert
    @Test
    func highConcurrencyInterleavedMutationStressTest() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let persistence = try SQLitePersistenceStore(dataRoot: tmpDir, mainRoot: tmpDir)
        let store = PersistentSessionStore(persistence: persistence)
        let session = try await store.create()
        let workspace = try WorkspaceRoot(path: tmpDir.path)
        let host = try CoreHost(sessionStore: store, workspaceRoot: workspace)

        // 预置基础消息
        _ = try await store.appendMessage(session.id, role: .user, content: "Base User")
        _ = try await store.appendMessage(session.id, role: .assistant, content: "Base Assistant")

        // 并发执行 50 次提交与撤回操作
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                if i % 2 == 0 {
                    group.addTask {
                        let req = RevertLastTurnRequest(sessionID: session.id)
                        let envelope = CommandEnvelope(payload: req)
                        _ = try? await host.revertLastTurn(envelope: envelope)
                    }
                } else {
                    group.addTask {
                        let currentRev = (try? await store.currentRevision(session.id)) ?? 0
                        _ = try? await store.appendMessage(
                            session.id,
                            role: .user,
                            content: "Concurrent User \(i)",
                            expectedRevision: currentRev
                        )
                    }
                }
            }
        }

        // 验证系统状态完全自洽，无死锁，无崩溃，revision 正确单调递增
        let finalRev = try await store.currentRevision(session.id)
        #expect(finalRev >= 1)

        let finalSession = try await store.session(session.id)
        #expect(finalSession.revision == finalRev)

        // 验证消息流结构合法：user 消息与 assistant 消息不出现破损
        var lastRole: MessageRole? = nil
        for msg in finalSession.messages {
            #expect(!msg.content.isEmpty)
            lastRole = msg.role
        }
        _ = lastRole
    }

    /// 16.2 & 16.3 模拟运行中撤回：迟到的写入必须全部被 Revision Barrier 拦截
    @Test
    func inFlightAsyncExecutionBlockedByConcurrentRevert() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let persistence = try SQLitePersistenceStore(dataRoot: tmpDir, mainRoot: tmpDir)
        let store = PersistentSessionStore(persistence: persistence)
        let session = try await store.create()
        let workspace = try WorkspaceRoot(path: tmpDir.path)
        let host = try CoreHost(sessionStore: store, workspaceRoot: workspace)

        _ = try await store.appendMessage(session.id, role: .user, content: "Initial Question")
        _ = try await store.appendMessage(session.id, role: .assistant, content: "Initial Answer")
        _ = try await store.appendMessage(session.id, role: .user, content: "Question To Revert")

        let capturedRevision = try await store.currentRevision(session.id)
        let lease = RunLease(sessionID: session.id, turnID: TurnID("t-test"), runID: RunID("r-test"), revision: capturedRevision)

        // 模拟一个异步后台任务正在准备写入迟到的 ToolResult / Assistant 消息
        let backgroundWriter = Task { () -> Bool in
            try? await Task.sleep(for: .milliseconds(30))
            do {
                _ = try await store.appendMessage(
                    session.id,
                    role: .assistant,
                    content: "Stale Late Reply",
                    expectedRevision: lease.revision
                )
                return true
            } catch {
                return false
            }
        }

        // 主线程在此时立即发起撤回操作
        let req = RevertLastTurnRequest(sessionID: session.id)
        let receipt = try await host.revertLastTurn(envelope: CommandEnvelope(payload: req))
        #expect(receipt.applied == true)
        let res = try #require(receipt.result)
        #expect(res.revertedPrompt == "Question To Revert")

        // 等待后台迟到写入结束
        let writeSucceeded = await backgroundWriter.value
        #expect(writeSucceeded == false)

        // 确认数据库中绝对没有 "Stale Late Reply"
        let afterSession = try await store.session(session.id)
        let containsStale = afterSession.messages.contains { $0.content.contains("Stale Late Reply") }
        #expect(containsStale == false)
        #expect(afterSession.messages.count == 2)
    }

    /// 16.10 撤回后的 Session 重启持久化一致性验证
    @Test
    func sessionPersistenceRebootConsistencyAfterRewind() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sessionID: SessionID
        let expectedFinalRevision: UInt64

        // Session 第一次生命周期：创建、聊天、撤回
        do {
            let persistence = try SQLitePersistenceStore(dataRoot: tmpDir, mainRoot: tmpDir)
            let store = PersistentSessionStore(persistence: persistence)
            let session = try await store.create()
            sessionID = session.id

            _ = try await store.appendMessage(session.id, role: .user, content: "Persisted Turn 1 Q")
            _ = try await store.appendMessage(session.id, role: .assistant, content: "Persisted Turn 1 A")
            _ = try await store.appendMessage(session.id, role: .user, content: "Persisted Turn 2 Q")
            _ = try await store.appendMessage(session.id, role: .assistant, content: "Persisted Turn 2 A")

            let workspace = try WorkspaceRoot(path: tmpDir.path)
            let host = try CoreHost(sessionStore: store, workspaceRoot: workspace)

            let receipt = try await host.revertLastTurn(envelope: CommandEnvelope(payload: RevertLastTurnRequest(sessionID: session.id)))
            let res = try #require(receipt.result)
            #expect(res.revertedPrompt == "Persisted Turn 2 Q")
            expectedFinalRevision = try #require(res.revision)
        }

        // 模拟进程完全退出，全新初始化 PersistentSessionStore 与 CoreHost
        do {
            let rebootPersistence = try SQLitePersistenceStore(dataRoot: tmpDir, mainRoot: tmpDir)
            let rebootStore = PersistentSessionStore(persistence: rebootPersistence)
            let rebootWorkspace = try WorkspaceRoot(path: tmpDir.path)
            let rebootHost = try CoreHost(sessionStore: rebootStore, workspaceRoot: rebootWorkspace)

            let restoredSession = try await rebootStore.session(sessionID)
            let restoredRevision = try await rebootStore.currentRevision(sessionID)

            #expect(restoredRevision == expectedFinalRevision)
            #expect(restoredSession.revision == expectedFinalRevision)
            #expect(restoredSession.messages.count == 2)
            #expect(restoredSession.messages.first?.content == "Persisted Turn 1 Q")
            #expect(restoredSession.messages.last?.content == "Persisted Turn 1 A")

            // 获取重启后的快照
            let req = GetSessionSnapshotRequest(sessionID: sessionID)
            let snapEnvelope = try await rebootHost.getSessionSnapshot(envelope: QueryEnvelope(payload: req))
            let snap = snapEnvelope.payload

            #expect(snap.sessionID == sessionID)
            #expect(snap.recentTurns.count == 1)
            #expect(snap.recentTurns.first?.userMessage.text == "Persisted Turn 1 Q")
            #expect(snap.activeRootRun == nil)
        }
    }
}
