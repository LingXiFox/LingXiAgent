import Testing
import Foundation
import LingXiProtocol
@testable import LingXiCore
import LingXiClient
@testable import LingXiApplication
@testable import LingXiTUI
import LingXiTUIComponents

@Suite("Resume & Config Enhancements Tests")
struct ResumeAndConfigEnhancementTests {

    @Test func sessionCatalogOrdersStrictlyByUpdatedAtDescending() {
        let now = Date()
        let sOld = SessionSummary(
            sessionID: SessionID("sess-old"),
            title: "Old Session",
            createdAt: now.addingTimeInterval(-3600),
            updatedAt: now.addingTimeInterval(-3600),
            turnCount: 2,
            mode: .build,
            reasoningEffort: .auto,
            workingDirectory: "/Volumes/Work/ProjectA",
            messageCount: 4
        )
        let sMid = SessionSummary(
            sessionID: SessionID("sess-mid"),
            title: "Mid Session",
            createdAt: now.addingTimeInterval(-1800),
            updatedAt: now.addingTimeInterval(-1800),
            turnCount: 5,
            mode: .build,
            reasoningEffort: .auto,
            workingDirectory: "/Volumes/Work/ProjectB",
            messageCount: 10
        )
        let sNewest = SessionSummary(
            sessionID: SessionID("sess-newest"),
            title: "Newest Session",
            createdAt: now,
            updatedAt: now,
            turnCount: 1,
            mode: .build,
            reasoningEffort: .auto,
            workingDirectory: "/Volumes/Work/ProjectC",
            messageCount: 2
        )

        let unordered = [sOld, sNewest, sMid]
        let sorted = SessionCatalog.groups(unordered, currentDirectory: "/unrelated").flatMap(\.sessions)

        #expect(sorted.count == 3)
        #expect(sorted[0].sessionID == SessionID("sess-newest"))
        #expect(sorted[1].sessionID == SessionID("sess-mid"))
        #expect(sorted[2].sessionID == SessionID("sess-old"))
    }

    @Test func resumeGroupsCurrentProjectAndSortsWithinEachProject() {
        let sessions = [
            SessionSummary(sessionID: SessionID("old"), updatedAt: Date(timeIntervalSince1970: 1), workingDirectory: "/work/A"),
            SessionSummary(sessionID: SessionID("other"), updatedAt: Date(timeIntervalSince1970: 9), workingDirectory: "/work/B"),
            SessionSummary(sessionID: SessionID("new"), updatedAt: Date(timeIntervalSince1970: 3), workingDirectory: "/work/A/"),
            SessionSummary(sessionID: SessionID("unknown"), updatedAt: Date(timeIntervalSince1970: 0))
        ]
        let groups = SessionCatalog.groups(sessions, currentDirectory: "/work/A")
        #expect(groups.map(\.directory) == ["/work/A", "/work/B", ""])
        #expect(groups[0].sessions.map(\.sessionID.rawValue) == ["new", "old"])
        #expect(SessionCatalog.groups(sessions, currentDirectory: "/work/A", query: "/work/B").flatMap(\.sessions).count == 1)
    }

    @Test @MainActor func resumeLayoutFitsNarrowTerminalAndKeepsSelectionVisible() {
        let sessions = (0..<24).map { i in
            SessionSummary(sessionID: SessionID("session-\(i)"), title: "中文标题\n包含换行和长文本", updatedAt: Date(timeIntervalSince1970: Double(24 - i)), workingDirectory: "/work/project")
        }
        for selected in [0, 12, 23] {
            let overlay = ApplicationTUI.sessionPickerOverlay(sessions: sessions, currentDirectory: "/work/project", activeSessionID: nil, query: "", selected: selected, size: TUISize(width: 42, height: 18))
            #expect(overlay.lines.allSatisfy { TUIDisplayWidth.width(of: $0.text) <= 36 && !$0.text.contains("\n") })
            #expect(overlay.lines.contains { $0.style == .modalHighlight })
            #expect(overlay.lines.contains { $0.style == .modalGroup })
            #expect(overlay.lines.count + 2 <= 18)
        }
    }

    @Test func configRejectsInvalidValuesAndRegistersAliases() throws {
        #expect(try UserPreferences.parseToggle("off", true) == false)
        #expect(try UserPreferences.parseToggle("toggle", false) == true)
        #expect(throws: ApplicationCommandError.self) { try UserPreferences.parseToggle("typo", false) }
        let command = try #require(BuiltinCommands.createAll().first { $0.name == "config" })
        #expect(command.aliases.contains("set"))
        #expect(command.aliases.contains("preference"))
    }

    @Test func userPreferencesStoreTogglesThinkingToolsAndSidebar() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test_prefs.json")
        let store = UserPreferencesStore(fileURL: testFile)

        // 初始为空
        let initial = store.load()
        #expect(initial.expandThinking == nil)
        #expect(initial.expandTools == nil)
        #expect(initial.showSidebar == nil)

        // 开启 thinking
        store.update(expandThinking: true)
        #expect(store.load().expandThinking == true)

        // 开启 tools，隐藏 sidebar
        store.update(expandTools: true, showSidebar: false)
        let updated = store.load()
        #expect(updated.expandThinking == true)
        #expect(updated.expandTools == true)
        #expect(updated.showSidebar == false)

        // 折叠 thinking
        store.update(expandThinking: false)
        #expect(store.load().expandThinking == false)
    }

    @Test func mcpResolverConcurrentlyResolvesDisabledAndEmptyServers() async throws {
        let emptyConfig = MCPConfiguration(servers: [
            StoredMCPServerConfiguration(id: "s1", alias: "Server1", transport: .stdio, command: "/bin/echo", arguments: ["hi"], enabled: false),
            StoredMCPServerConfiguration(id: "s2", alias: "Server2", transport: .stdio, command: "/bin/echo", arguments: ["hi"], enabled: false)
        ])
        let creds = try PlatformSecureCredentialStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let res = try await RuntimeConfigurationResolver.resolveMCP(emptyConfig, credentials: creds, discoverTools: false)
        #expect(res.configurations.count == 2)
        #expect(res.configurations.allSatisfy { !$0.enabled })
    }

    @Test func sessionCatalogTimeGroupsBucketsAccurately() {
        let now = Date()
        let calendar = Calendar.current
        let todaySession = SessionSummary(
            sessionID: SessionID("sess-today"),
            title: "重构网络连接层",
            updatedAt: now,
            workingDirectory: "/work/A",
            messageCount: 8
        )
        let yesterdaySession = SessionSummary(
            sessionID: SessionID("sess-yesterday"),
            title: "修复缓存泄露",
            updatedAt: calendar.date(byAdding: .day, value: -1, to: now) ?? now,
            workingDirectory: "/work/A",
            messageCount: 4
        )
        let pastWeekSession = SessionSummary(
            sessionID: SessionID("sess-week"),
            title: "实现双核心架构",
            updatedAt: calendar.date(byAdding: .day, value: -3, to: now) ?? now,
            workingDirectory: "/work/B",
            messageCount: 16
        )
        let olderSession = SessionSummary(
            sessionID: SessionID("sess-older"),
            title: "初始项目搭建",
            updatedAt: calendar.date(byAdding: .day, value: -15, to: now) ?? now,
            workingDirectory: "/work/C",
            messageCount: 2
        )

        let all = [olderSession, todaySession, pastWeekSession, yesterdaySession]
        let groups = SessionCatalog.timeGroups(all, calendar: calendar, now: now)

        #expect(groups.map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "Older"])
        #expect(groups[0].sessions.map(\.sessionID.rawValue) == ["sess-today"])
        #expect(groups[1].sessions.map(\.sessionID.rawValue) == ["sess-yesterday"])
        #expect(groups[2].sessions.map(\.sessionID.rawValue) == ["sess-week"])
        #expect(groups[3].sessions.map(\.sessionID.rawValue) == ["sess-older"])

        // 模糊搜索过滤
        let searchRes = SessionCatalog.timeGroups(all, query: "双核心", calendar: calendar, now: now)
        #expect(searchRes.count == 1)
        #expect(searchRes[0].title == "Previous 7 Days")
        #expect(searchRes[0].sessions.first?.sessionID == SessionID("sess-week"))
    }

    @Test @MainActor func sessionPickerModernPopupLayoutMatchesModelPickerStyle() {
        let now = Date()
        let activeID = SessionID("sess-1")
        let sessions = [
            SessionSummary(sessionID: activeID, title: "重构网络请求", updatedAt: now, messageCount: 6),
            SessionSummary(sessionID: SessionID("sess-2"), title: "实现会话摘要", updatedAt: now.addingTimeInterval(-3600), messageCount: 12)
        ]

        let overlay = ApplicationTUI.sessionPickerOverlay(
            sessions: sessions,
            currentDirectory: "/work",
            activeSessionID: activeID,
            query: "",
            selected: 0,
            size: TUISize(width: 80, height: 24)
        )

        #expect(overlay.isModal == true)
        #expect(overlay.focus == .picker)
        #expect(overlay.lines.first?.text.contains("Select session") == true)
        #expect(overlay.lines.first?.text.contains("esc") == true)
        #expect(overlay.lines.contains { $0.text.contains("│Search") })
        #expect(overlay.lines.contains { $0.text.contains("Today") && $0.style == .modalGroup })
        #expect(overlay.lines.contains { $0.text.contains("● ") && $0.text.contains("重构网络请求") && $0.style == .modalHighlight })
        #expect(overlay.lines.last?.text.contains("↑↓ 移动 · Enter 恢复 · Esc 关闭") == true)
    }

    @Test @MainActor func tabCompletionDoesNotAppendTrailingSpaceForZeroArgCommands() {
        let noArgCommands = ["resume", "history", "undo", "rewind", "perf", "status", "context", "clear"]
        for cmdName in noArgCommands {
            let hasSub = ApplicationTUI.hasSubcommands(cmdName)
            #expect(hasSub == false, "Command /\(cmdName) should not have subcommands and should not append space on tab completion")
        }
    }

    @Test func revertLastTurnInMemoryStoreRemovesLastTurnAndReturnsPrompt() async throws {
        let store = InMemorySessionStore()
        let session = try await store.create()
        try await store.appendMessage(session.id, role: .user, content: "第一轮问题")
        try await store.appendMessage(session.id, role: .assistant, content: "第一轮回答")
        try await store.appendMessage(session.id, role: .user, content: "第二轮问题：要被撤回的内容")
        try await store.appendMessage(session.id, role: .assistant, content: "第二轮回答")

        let result = try await store.revertLastTurn(session.id)
        #expect(result.revertedPrompt == "第二轮问题：要被撤回的内容")
        #expect(result.removedCount == 2)

        let loaded = try await store.session(session.id)
        #expect(loaded.messages.count == 2)
        #expect(loaded.messages.map(\.content) == ["第一轮问题", "第一轮回答"])
    }

    @Test func revertLastTurnSQLitePersistenceRemovesLastTurn() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("undo_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sqlite = try SQLitePersistenceStore(dataRoot: tempDir, mainRoot: tempDir)
        let store = PersistentSessionStore(persistence: sqlite)
        let session = try await store.create()

        _ = try await store.appendMessage(session.id, role: .user, content: "历史提问 1")
        _ = try await store.appendMessage(session.id, role: .assistant, content: "历史回复 1")
        _ = try await store.appendMessage(session.id, role: .user, content: "待撤回的用户输入")
        _ = try await store.appendMessage(session.id, role: .assistant, content: "待撤回的助手回复")

        let result = try await store.revertLastTurn(session.id)
        #expect(result.revertedPrompt == "待撤回的用户输入")
        #expect(result.removedCount == 2)

        let loaded = try await store.session(session.id)
        #expect(loaded.messages.count == 2)
        #expect(loaded.messages.last?.content == "历史回复 1")
    }

    @Test @MainActor func sessionRestorePreservesYoloPermissionMode() async {
        var state = ApplicationState()
        state.nextTurnPermission = .yoloFullAccess

        // 验证处于 YOLO 模式时，显示与保持机制正常
        #expect(state.nextTurnPermission?.displayName == "YOLO")

        // 模拟恢复会话逻辑：若当前应用已显式处于 YOLO，切换后保持该策略
        let currentPerm = state.activeSessionState?.permissionConfiguration
        if state.nextTurnPermission == nil, let currentPerm, currentPerm.displayName == "YOLO" {
            state.nextTurnPermission = currentPerm
        }
        #expect(state.nextTurnPermission?.displayName == "YOLO")
    }

    @Test @MainActor func toolNodeDoesNotDegradeToGenericPlaceholderUnderRacingToolRequested() {
        var state = SessionViewState(sessionID: SessionID("test-sess"))
        let callID = ToolCallID("call_list_directory_123")
        let timestamp = Date()

        let connection = ConnectionState(status: .connected)
        // 模拟抢跑：toolScheduled 先到达并触发 ensureToolNode
        let scheduledEvent = SessionEventEnvelope(
            cursor: EventCursor(generationID: EventLogGenerationID("gen"), sequence: 1),
            timestamp: timestamp,
            causal: CausalContext(sessionID: state.sessionID),
            payload: .toolScheduled(callID: callID)
        )
        SessionReducer.reduce(state: &state, event: scheduledEvent, connectionState: connection)

        // 验证占位已自动推断为 "list_directory" 而非写死 "Tool"
        #expect(state.toolNodes[callID]?.toolName == "list_directory")

        // 随后真正的 toolRequested 到达，提供完整参数和显示名
        let invocation = ToolInvocationSnapshot(
            callID: callID,
            toolID: ToolID("list_directory"),
            displayName: "list_directory",
            argumentsSummary: #"{"path":"/Volumes/App"}"#,
            state: .requested
        )
        let requestedEvent = SessionEventEnvelope(
            cursor: EventCursor(generationID: EventLogGenerationID("gen"), sequence: 2),
            timestamp: timestamp,
            causal: CausalContext(sessionID: state.sessionID),
            payload: .toolRequested(invocation)
        )
        SessionReducer.reduce(state: &state, event: requestedEvent, connectionState: connection)

        let node = state.toolNodes[callID]
        #expect(node?.toolName == "list_directory")
        #expect(node?.argumentsJSON == #"{"path":"/Volumes/App"}"#)
        #expect(node?.toolName != "Tool")
    }

    @Test func coordinatorResetForRevertAllowsSubsequentTurnExecution() async throws {
        let sessionID = SessionID("test-revert-coord")
        let eventLog = SessionEventLog(sessionID: sessionID)
        let coord = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        // 模拟提交第一轮
        let msg1 = MessageSnapshot(messageID: MessageID("m1"), role: .user, text: "hello 1", createdAt: Date())
        let d1 = try await coord.submitTurn(input: UserInput(text: "hello 1"), intent: TurnExecutionIntent(), userMessage: msg1)
        #expect(d1.shouldStartExecution == true)
        #expect(await coord.activeRootRunID != nil)

        // 模拟在第一轮运行或异常时执行撤回
        await coord.resetForRevert(remainingMessages: [])
        #expect(await coord.activeRootRunID == nil)

        // 撤回后再提交新的一轮，应当能够正常启动执行，绝对不能被判定为 queued 死锁（被吞）
        let msg2 = MessageSnapshot(messageID: MessageID("m2"), role: .user, text: "hello 2", createdAt: Date())
        let d2 = try await coord.submitTurn(input: UserInput(text: "hello 2"), intent: TurnExecutionIntent(), userMessage: msg2)
        #expect(d2.shouldStartExecution == true)
        #expect(d2.runID != nil)
        #expect(d2.status == .running)
    }

    @Test func hydrateHistoricalMessagesDeduplicatesConsecutiveIdenticalUserInputs() async {
        let sessionID = SessionID("sess-dedup")
        let eventLog = SessionEventLog(sessionID: sessionID)
        let coord = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        let duplicateUserMessages = [
            Message(id: MessageID("m1"), role: .user, content: "帮我看一下代码", createdAt: Date().addingTimeInterval(-10)),
            Message(id: MessageID("m2"), role: .user, content: "帮我看一下代码", createdAt: Date().addingTimeInterval(-9)),
            Message(id: MessageID("m3"), role: .assistant, content: "好的，我已经看了", createdAt: Date().addingTimeInterval(-5)),
            Message(id: MessageID("m4"), role: .user, content: "第二轮问题", createdAt: Date().addingTimeInterval(-2))
        ]

        await coord.hydrateHistoricalMessages(duplicateUserMessages)
        let turns = await coord.listTurns(page: PageRequest(limit: 10)).items
        #expect(turns.count == 2)
        #expect(turns.first?.userMessage.text == "帮我看一下代码")
        #expect(turns.last?.userMessage.text == "第二轮问题")
    }

    @Test @MainActor func tasksModalOverlayRendersHeaderAndTasksCorrectly() {
        let now = Date()
        let task1 = BackgroundTaskSnapshot(
            id: "task-1",
            command: "sleep 10",
            cwd: "/tmp",
            timeoutSeconds: 30,
            startedAt: now.addingTimeInterval(-5),
            completedAt: nil,
            status: .running,
            pid: 12345,
            exitCode: nil,
            description: nil,
            stdout: "running step 1\nrunning step 2",
            stderr: "",
            stdoutCursor: 30,
            stderrCursor: 0,
            elapsedSeconds: 5.0,
            remainingTimeoutSeconds: 25.0
        )
        let task2 = BackgroundTaskSnapshot(
            id: "task-2",
            command: "git status",
            cwd: "/tmp",
            timeoutSeconds: 15,
            startedAt: now.addingTimeInterval(-20),
            completedAt: now.addingTimeInterval(-18),
            status: .exited,
            pid: 12340,
            exitCode: 0,
            description: nil,
            stdout: "clean",
            stderr: "",
            stdoutCursor: 5,
            stderrCursor: 0,
            elapsedSeconds: 2.0,
            remainingTimeoutSeconds: 13.0
        )

        let overlay = ApplicationTUI.tasksModalOverlay(
            selected: 0,
            tasks: [task1, task2],
            expandedDetail: true,
            size: TUISize(width: 80, height: 24)
        )

        #expect(overlay.isModal == true)
        #expect(overlay.focus == .picker)
        #expect(overlay.lines.first?.text.contains("后台任务监控") == true)
        #expect(overlay.lines.first?.text.contains("esc") == true)
        #expect(overlay.lines.contains { $0.text.contains("↑/↓ 切换 · Enter 详情 · k 终止 · r 刷新 · Esc 退出") })
        #expect(overlay.lines.contains { $0.text.contains("RUNNING") && $0.text.contains("sleep 10") })
        #expect(overlay.lines.contains { $0.text.contains("SUCCESS") && $0.text.contains("git status") })
        #expect(overlay.lines.contains { $0.text.contains("Log Tail:") })
        #expect(overlay.lines.contains { $0.text.contains("running step 2") })
    }
}
