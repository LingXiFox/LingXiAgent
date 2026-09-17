import Testing
import Foundation
import LingXiProtocol
import LingXiClient
@testable import LingXiCore
@testable import LingXiApplication
@testable import LingXiTUI
@testable import LingXiTUIComponents

@Suite("Application ChangeSet & Incremental Update Tests (Phase 4)", .serialized)
struct ApplicationChangeSetTests {

    @Test("Streaming text delta produces precise nodeChange with kind == .update and transcriptStructureChanged == false")
    func streamingDeltaProducesPreciseNodeChange() throws {
        let sessionID = SessionID("test_session_phase4")
        var sessionState = SessionViewState(sessionID: sessionID)

        let streamID = StreamID("test_stream_phase4")
        let messageID = MessageID("test_msg_phase4")
        let stepID = ModelStepID("test_step_phase4")

        // 建立流映射
        sessionState.messageIDByStream[streamID] = messageID

        let causal = CausalContext(sessionID: sessionID, modelStepID: stepID)

        // 首个 frame：初始化 assistant 节点
        let frame1 = StreamFrame(
            streamID: streamID,
            owner: causal,
            index: 0,
            kind: .assistantText,
            text: "Hello"
        )
        let changes1 = SessionReducer.reduceStreamFrame(state: &sessionState, frame: frame1, connectionState: ConnectionState(status: .connected))
        #expect(changes1.transcriptStructureChanged == true, "First frame should append new node to timeline")
        #expect(changes1.nodeChanges.count == 1)
        #expect(changes1.nodeChanges.first?.kind == .append)

        // 后续流式增量 frame：仅更新内容
        let frame2 = StreamFrame(
            streamID: streamID,
            owner: causal,
            index: 1,
            kind: .assistantText,
            text: " world"
        )
        let changes2 = SessionReducer.reduceStreamFrame(state: &sessionState, frame: frame2, connectionState: ConnectionState(status: .connected))

        #expect(changes2.transcriptStructureChanged == false, "Subsequent delta MUST NOT alter timeline structure")
        #expect(changes2.sessionChanged == false)
        #expect(changes2.contextChanged == false)
        #expect(changes2.transcriptNodesChanged.count == 1)
        let nodeID = TimelineNodeID.message(messageID, modelStepID: stepID)
        #expect(changes2.transcriptNodesChanged.contains(nodeID))
        #expect(changes2.nodeChanges == [TimelineNodeChange(nodeID: nodeID, kind: .update)])
    }

    @Test("Snapshot resync produces full snapshot changeSet")
    func snapshotResyncProducesFullSnapshot() throws {
        let sessionID = SessionID("test_session_snapshot")
        var sessionState = SessionViewState(sessionID: sessionID)
        let timestamp = Date()

        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            info: SessionSummary(sessionID: sessionID, title: "Test Session", createdAt: timestamp, updatedAt: timestamp),
            contextState: ContextStateSnapshot(sessionID: sessionID),
            eventCursor: EventCursor(generationID: EventLogGenerationID("gen_1"), sequence: 1)
        )

        let changes = SessionReducer.reduceSnapshot(state: &sessionState, snapshot: snapshot, connectionState: ConnectionState(status: .connected))
        #expect(changes.sessionChanged == true)
        #expect(changes.transcriptStructureChanged == true)
        #expect(changes.contextChanged == true)
        #expect(changes.statusChanged == true)
    }

    @Test("200 token streaming burst: TUI full transcript projection count is zero")
    @MainActor
    func streamingBurstKeepsFullProjectionAtZero() throws {
        let metrics = TUIPerformanceMetrics.shared
        metrics.reset()
        metrics.isEnabled = true
        defer { metrics.isEnabled = false }

        let tui = ApplicationTUI(options: TUILaunchOptions(noAltScreen: true))
        let sessionID = SessionID("burst_session")
        var appState = ApplicationState()
        var sessionState = SessionViewState(sessionID: sessionID)

        // 初始填充 20 条已提交历史节点
        for i in 0..<20 {
            let mID = MessageID("hist_\(i)")
            let node = TimelineNode(
                id: .message(mID),
                timestamp: Date(),
                kind: .message(MessageNode(messageID: mID, role: i % 2 == 0 ? .user : .assistant, content: "History message \(i)"))
            )
            sessionState.appendCommittedNode(node)
        }
        appState.activeSessionID = sessionID
        appState.activeSessionState = sessionState

        // 首次刷新（全量水合）
        tui.refreshViewForTesting(appState, changes: .fullSnapshot)
        let initialFullRefreshes = metrics.fullRefreshCount
        #expect(initialFullRefreshes == 1, "Initial render must perform exactly 1 full refresh")

        // 模拟流式消息启动
        let streamID = StreamID("stream_burst")
        let assistantMsgID = MessageID("stream_msg_burst")
        let stepID = ModelStepID("step_burst_1")
        sessionState.messageIDByStream[streamID] = assistantMsgID
        let causal = CausalContext(sessionID: sessionID, modelStepID: stepID)

        // 初始首帧：创建 Assistant 节点并完成首次挂载
        let initialFrame = StreamFrame(
            streamID: streamID,
            owner: causal,
            index: 0,
            kind: .assistantText,
            text: "start"
        )
        let initChanges = SessionReducer.reduceStreamFrame(
            state: &sessionState,
            frame: initialFrame,
            connectionState: ConnectionState(status: .connected)
        )
        appState.activeSessionState = sessionState
        tui.refreshViewForTesting(appState, changes: initChanges)

        // 记录此时的全量与增量刷新基准
        let fullRefreshesBeforeBurst = metrics.fullRefreshCount
        let incrementalBeforeBurst = metrics.incrementalRefreshCount

        // 模拟 200 个连续 streaming token burst
        for tokenIndex in 1...200 {
            let frame = StreamFrame(
                streamID: streamID,
                owner: causal,
                index: UInt64(tokenIndex),
                kind: .assistantText,
                text: " t\(tokenIndex)"
            )
            let changes = SessionReducer.reduceStreamFrame(
                state: &sessionState,
                frame: frame,
                connectionState: ConnectionState(status: .connected)
            )
            appState.activeSessionState = sessionState

            // 触发带增量变更集的 UI 刷新
            tui.refreshViewForTesting(appState, changes: changes)
        }

        // 验收指标验证：
        // 1. 200 次 streaming token burst 期间，TUI full transcript projector 调用次数严格为 0
        // 2. 200 次 streaming token 全部走 incremental refresh 路径
        let burstFullCount = metrics.fullRefreshCount - fullRefreshesBeforeBurst
        let burstIncrementalCount = metrics.incrementalRefreshCount - incrementalBeforeBurst
        #expect(burstFullCount == 0, "Full transcript projection count during 200 token burst must be exactly 0 (no full re-projections)")
        #expect(burstIncrementalCount == 200, "All 200 streaming tokens must be processed incrementally")
    }

    private func createTestEnvironment() async throws -> (CoreHost, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let workspace = try WorkspaceRoot(path: tempDir.path)
        let credStore = try FileCredentialStore(dataRoot: tempDir.appendingPathComponent("vault"), passphrase: "test")
        let assembly = ModelRuntimeAssembly(provider: ScriptedFakeProvider(script: []), modelID: ModelID("test-model"))
        let host = try CoreHost(
            providerAssembly: assembly,
            sessionStore: InMemorySessionStore(),
            workspaceRoot: workspace,
            credentialStore: credStore
        )
        await host.start()
        return (host, tempDir)
    }

    @Test("ApplicationStore updates stream yields mono-incrementing revisions with valid changeSets")
    func storeUpdatesYieldsMonoIncrementingRevisions() async throws {
        let (host, tempDir) = try await createTestEnvironment()
        defer {
            Task {
                await host.shutdown()
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        let client = try await LingXiClientVNext.connectInProcess(service: host)
        let store = await ApplicationStore(client: client, autoConnect: false)

        var revisions: [UInt64] = []
        var changesList: [ApplicationChangeSet] = []

        let task = Task {
            for await update in await store.updates {
                revisions.append(update.revision)
                changesList.append(update.changes)
                if revisions.count >= 3 {
                    break
                }
            }
        }

        await store.dispatch(._connectionStateChanged(ConnectionState(status: .connected)))
        await store.dispatch(.setMode(.plan))

        _ = await task.result

        #expect(revisions.count >= 3)
        #expect(revisions[1] > revisions[0])
        #expect(revisions[2] > revisions[1])
        #expect(changesList[0] == .fullSnapshot)
        #expect(changesList[1].statusChanged == true)
    }
}
