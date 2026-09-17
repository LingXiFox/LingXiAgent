import Testing
import Foundation
import LingXiProtocol
import LingXiClient
@testable import LingXiCore
@testable import LingXiApplication
@testable import LingXiTUI
import LingXiTUIComponents

@Suite("Undo & Compact Spacing Tests")
struct UndoAndCompactSpacingTests {

    @Test func compactMarkdownRenderingCompressesConsecutiveAndTrailingEmptyLines() {
        let rawMarkdown = """


# 报告主人

这是第一行。



这是第二行。

- 列表项 1
- 列表项 2



"""
        let rendered = TUIMarkdownRenderer.render(rawMarkdown, width: 80)

        // 验证首行不是空行
        #expect(!rendered.isEmpty)
        #expect(!rendered.first!.text.isEmpty)

        // 验证末尾没有空行
        #expect(!rendered.last!.text.isEmpty)

        // 验证没有两个连续的空行
        var consecutiveEmpty = 0
        for line in rendered {
            if line.text.isEmpty {
                consecutiveEmpty += 1
                #expect(consecutiveEmpty <= 1, "Consecutive empty lines must not exceed 1")
            } else {
                consecutiveEmpty = 0
            }
        }
    }

    @Test func ecoreStorePrunesOrphanedObjectsAfterRevert() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let config = ContextObjectFabricConfiguration(
            ecoreStorageEnabled: true,
            objectizationThreshold: 10
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sessionID = SessionID("sess-revert-test")

        let call1 = ToolCallID("call_1")
        let call2 = ToolCallID("call_2")

        let meta1 = await store.store(sessionID: sessionID, toolCallID: call1, toolName: "read_file", content: "Line 1\nLine 2\nLine 3\nLine 4")
        let meta2 = await store.store(sessionID: sessionID, toolCallID: call2, toolName: "read_file", content: "Another Line 1\nAnother Line 2")

        #expect(meta1 != nil)
        #expect(meta2 != nil)

        let initialList = await store.listObjects(sessionID: sessionID)
        #expect(initialList.count == 2)

        // 模拟 undo：call2 被撤回，仅保留 call1
        await store.prune(sessionID: sessionID, keepingToolCallIDs: [call1])

        let prunedList = await store.listObjects(sessionID: sessionID)
        #expect(prunedList.count == 1)
        #expect(prunedList.first?.toolCallID == call1)

        // 再次 undo：全部被撤回
        await store.prune(sessionID: sessionID, keepingToolCallIDs: [])
        let emptyList = await store.listObjects(sessionID: sessionID)
        #expect(emptyList.isEmpty)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func contextCacheControllerReconcilesAfterRevert() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet())
        let scanner = ProjectScanner(root: root)
        let controller = ContextCacheController(contextPager: pager, scanner: scanner, maxL1ResidentCharacters: 48 * 1024)
        let sessionID = SessionID("sess-cache-reconcile")

        let msg1 = Message(
            id: MessageID("msg-1"),
            role: .user,
            parts: [.text("Hello")],
            createdAt: Date()
        )

        // 模拟已记录的旧 Provider 状态
        await controller.recordSessionL1Tokens(sessionID: sessionID, tokens: 1000, count: 2)

        // 模拟撤回到只有 1 条消息
        await controller.reconcileAfterRevert(sessionID: sessionID, remainingMessages: [msg1])

        let l1Tokens = await controller.l1UsageTokens(for: sessionID)
        #expect(l1Tokens > 0 && l1Tokens < 1000)

        let record = await controller.lastProviderCacheRecord(for: sessionID)
        #expect(record?.status == "coldNewEpoch")

        // 撤回至全部清空
        await controller.reconcileAfterRevert(sessionID: sessionID, remainingMessages: [])
        let clearedTokens = await controller.l1UsageTokens(for: sessionID)
        #expect(clearedTokens == 0)

        try? FileManager.default.removeItem(at: root)
    }

    @Test func reduceSnapshotReconcilesActiveTurnAgainstAuthoritativeActiveRootRun() {
        var viewState = SessionViewState(sessionID: SessionID("sess-revert-snapshot"))

        let pastTurnID = TurnID("turn-past")
        let turnSnapshot = TurnSnapshot(
            turnID: pastTurnID,
            sessionID: SessionID("sess-revert-snapshot"),
            userMessage: MessageSnapshot(messageID: MessageID("m1"), role: .user, text: "hello", createdAt: Date()),
            executionIntent: TurnExecutionIntent(),
            status: .completed,
            createdAt: Date()
        )

        let cursor = EventCursor(generationID: EventLogGenerationID(UUID().uuidString), sequence: 1)

        // 构造一个包含历史 turnCreated 事件的快照，但权威 activeRootRun 为 nil
        let pastEvent = SessionEventEnvelope(
            cursor: cursor,
            timestamp: Date(),
            causal: CausalContext(sessionID: SessionID("sess-revert-snapshot"), turnID: pastTurnID),
            payload: .turnCreated(turnSnapshot)
        )

        let contextSnapshot = ContextStateSnapshot(sessionID: SessionID("sess-revert-snapshot"))

        let snapshot = SessionSnapshot(
            sessionID: SessionID("sess-revert-snapshot"),
            info: SessionSummary(sessionID: SessionID("sess-revert-snapshot")),
            recentTurns: [turnSnapshot],
            activeRootRun: nil,
            activeChildRuns: [],
            pendingInteractions: [],
            activeModelSteps: [],
            recentToolInvocations: [],
            contextState: contextSnapshot,
            permissionConfiguration: .askWorkspace,
            agentMode: .build,
            recentEvents: [pastEvent],
            historyBeforeCursor: nil,
            eventCursor: cursor,
            revision: 1
        )

        SessionReducer.reduceSnapshot(state: &viewState, snapshot: snapshot, connectionState: ConnectionState(status: .connected))

        // 校验：事件重放完毕后，activeTurnID 必须被权威快照 (activeRootRun == nil) 矫正为 nil！
        #expect(viewState.activeTurnID == nil)
        #expect(viewState.activeRootRunID == nil)
        #expect(viewState.status == .ready)
    }

    @Test func eventReplayCoordinatorResetsCursorAndDoesNotSwallowEventsAfterRevert() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let host = try CoreHost(workspaceRoot: WorkspaceRoot(path: root.path))
        await host.start()

        let transport = InProcessTransport(service: host)
        let coordinator = EventReplayCoordinator(transport: transport, sync: WatermarkSynchronizer())
        let sessionClient = SessionDomainClient(transport: transport, replayCoordinator: coordinator)
        let turnClient = TurnDomainClient(transport: transport)

        // 1. 创建会话
        let created = try await sessionClient.create()
        guard let sessionID = created.result?.sessionID else {
            #expect(Bool(false), "Failed to create session")
            return
        }

        // 2. 模拟第一轮对话提交
        _ = try await turnClient.submitTurn(sessionID: sessionID, input: UserInput(text: "Hello 1"))

        // 3. 执行撤回 undo
        let revertResult = try await sessionClient.revertLastTurn(sessionID: sessionID)
        #expect(revertResult.removedCount >= 1)

        // 4. 获取最新权威快照并订阅事件流（如前端 switchToSession 所做）
        let snapshot = try await sessionClient.snapshot(sessionID: sessionID)
        let stream = try await sessionClient.events(sessionID: sessionID, after: snapshot.eventCursor)

        var iterator = stream.makeAsyncIterator()

        // 5. 在 undo 之后提交新的用户消息
        _ = try await turnClient.submitTurn(sessionID: sessionID, input: UserInput(text: "Hello after undo"))

        // 6. 校验：客户端事件流必须能顺利收到新的 turnCreated 和 userMessageCommitted 事件，绝不被吞！
        var receivedTurnCreated = false
        var receivedUserMessage = false
        for _ in 0..<10 {
            if let env = await iterator.next() {
                if case let .turnCreated(t) = env.payload, t.userMessage.text == "Hello after undo" {
                    receivedTurnCreated = true
                }
                if case let .userMessageCommitted(m) = env.payload, m.text == "Hello after undo" {
                    receivedUserMessage = true
                }
                if receivedTurnCreated && receivedUserMessage {
                    break
                }
            }
        }
        #expect(receivedTurnCreated)
        #expect(receivedUserMessage)

        await host.shutdown()
    }

    @Test func openAICompatibleProviderDoesNotDuplicateSystemPromptInCachePlan() throws {
        let systemPrompt = "You are LingXiAgent."
        let userMessage = ModelMessage(role: .user, parts: [.text("Hello")])
        // 模拟 contextEngine 生成的包含 system 消息的列表
        let systemMessage = ModelMessage(role: .system, parts: [.text(systemPrompt)])

        let cachePlan = CanonicalCachePlan(
            epochIdentity: CanonicalCachePlan.EpochIdentity(epoch: 1, reason: "test"),
            immutableBase: CanonicalCachePlan.ImmutableBase(
                systemPrompt: systemPrompt,
                developerPrompt: nil,
                coreTools: [],
                stablePolicy: nil
            ),
            appendOnlyContext: CanonicalCachePlan.AppendOnlyContext(
                dynamicTools: [],
                messages: [systemMessage, userMessage],
                skillActivations: []
            ),
            volatileTail: CanonicalCachePlan.VolatileTail(currentTurnState: nil, ephemeralNotes: nil),
            structuralHealth: ClientStructuralCacheHealth(stablePrefixHash: "test")
        )

        let request = ModelRequest(
            model: ModelID("test-model"),
            messages: [systemMessage, userMessage],
            tools: [],
            cachePlan: cachePlan
        )

        let data = try OpenAICompatibleProvider.makeRequestBody(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let messages = json?["messages"] as? [[String: Any]]

        #expect(messages != nil)
        let systemMessages = messages!.filter { ($0["role"] as? String) == "system" }
        // 验证系统提示词只有 1 条，杜绝重复两条破坏 KV Cache！
        #expect(systemMessages.count == 1)
        #expect(systemMessages.first?["content"] as? String == systemPrompt)
    }

    @Test func sessionReducerReplacesOptimisticUserMessageSeamlessly() {
        var viewState = SessionViewState(sessionID: SessionID("sess-opt-test"))

        // 1. 本地乐观添加用户消息
        let optID = MessageID("opt:12345")
        let optNodeID = TimelineNodeID.message(optID)
        let optNode = TimelineNode(
            id: optNodeID,
            timestamp: Date(),
            kind: .message(MessageNode(
                messageID: optID,
                role: .user,
                content: "Optimistic user prompt",
                isStreaming: false,
                isFinal: true
            ))
        )
        viewState.appendNode(optNode)
        #expect(viewState.timelineNodes.count == 1)
        #expect(viewState.timelineNodes.first?.id == optNodeID)

        // 2. 权威 turnCreated 事件到达
        let authTurnID = TurnID("turn-auth-1")
        let authMsgID = MessageID("msg-auth-1")
        let turnSnapshot = TurnSnapshot(
            turnID: authTurnID,
            sessionID: SessionID("sess-opt-test"),
            userMessage: MessageSnapshot(messageID: authMsgID, role: .user, text: "Optimistic user prompt", createdAt: Date()),
            executionIntent: TurnExecutionIntent(),
            status: .queued,
            createdAt: Date()
        )
        let turnEvent = SessionEventEnvelope(
            cursor: EventCursor(generationID: EventLogGenerationID("gen"), sequence: 1),
            timestamp: Date(),
            causal: CausalContext(sessionID: SessionID("sess-opt-test"), turnID: authTurnID),
            payload: .turnCreated(turnSnapshot)
        )

        SessionReducer.reduce(state: &viewState, event: turnEvent, connectionState: ConnectionState(status: .connected))

        // 3. 校验：乐观节点被平滑清除，权威节点就位，总数依然为 1，无重复消息！
        #expect(viewState.timelineNodes.count == 1)
        #expect(viewState.timelineNodes.first?.id == .message(authMsgID))
        if case let .message(m) = viewState.timelineNodes.first?.kind {
            #expect(m.content == "Optimistic user prompt")
            #expect(m.messageID == authMsgID)
        } else {
            #expect(Bool(false), "Expected message node")
        }
    }

    @Test @MainActor func undoPreservesExplicitReasoningEffort() async throws {
        let host = try CoreHost()
        let client = try await LingXiClientVNext.connectInProcess(service: host)
        let store = await ApplicationStore(client: client)
        await store.dispatch(.connect)
        await store.dispatch(.createSession())

        // 设置 reasoning effort 为 high
        await store.setReasoningEffort(.high)
        let stateBefore = await store.state
        #expect(stateBefore.effectiveReasoningEffort == .high)

        // 提交一轮对话
        await store.dispatch(.submitPrompt("Hello"))

        // 执行 /undo 撤回
        let result = try await store.executeCommand("/undo")
        #expect(result.revertedComposerText == "Hello")

        // 关键断言：undo 撤回并 resync snapshot 之后，思考等级必须维持 high，绝对不能被重置为 auto！
        let stateAfter = await store.state
        #expect(stateAfter.effectiveReasoningEffort == .high)
    }

    @Test @MainActor func duplicateToolCallIsRenderedAsSuccessWithoutGhostSpinner() {
        let tui = ApplicationTUI(options: TUILaunchOptions())
        let callID = ToolCallID("call-dup-1")
        var tool = ToolNode(callID: callID, toolName: "view_file")
        tool.argumentsJSON = #"{"path":"test.swift"}"#
        tool.phase = .completed
        tool.result = ToolResultSnapshot(
            callID: callID,
            toolName: "view_file",
            success: false,
            summary: "duplicate read",
            preview: "content",
            contentRef: nil,
            error: RuntimeError(category: .tool, code: "duplicateToolCall", message: "连续重复调用已复用前一成功结果"),
            timing: ToolTiming(milliseconds: 15, queueMilliseconds: 0, executionMilliseconds: 15)
        )

        let entry = tui.formatModernToolCall(tool: tool, id: "tool:\(callID.rawValue)", active: false, timestamp: Date())

        // 关键断言：duplicateToolCall 属于正常只读复用，不得渲染为错误样式，且必须带有耗时文本
        #expect(entry.style != .error)
        #expect(entry.text.contains("15ms") || entry.text.contains("15.0ms"))
        #expect(!entry.text.contains("⠋"))
        #expect(entry.text.contains("●"))
    }
}

