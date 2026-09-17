import Testing
import Foundation
@testable import LingXiProtocol
@testable import LingXiApplication
@testable import LingXiTUI
@testable import LingXiTUIComponents
@testable import LingXiCore
import LingXiClient

@Suite("Frontend Authority Cleanup & Sidebar Stabilization Tests (Round 2 Phase F)")
struct FrontendAuthorityCleanupTests {

    // MARK: - 1. E-Core 无硬容量时不显示虚假 100% 进度条
    @Test func ecoreWithoutHardCapacityOmitsProgressBarAndPercentage() {
        let eCoreLayer = TUISidebarModel.CacheLayer(
            name: "E-Core",
            usedTokens: 1024 * 1024, // 1 MB
            capacityTokens: nil, // 无硬容量上限
            detailText: "42 objs · 1.0 MB"
        )
        #expect(eCoreLayer.ratio == nil, "Unbounded cache layer must have nil ratio")

        let pCoreLayer = TUISidebarModel.CacheLayer(
            name: "P-Core",
            usedTokens: 2500,
            capacityTokens: 10000,
            detailText: "2.5k/10k"
        )
        #expect(pCoreLayer.ratio == 0.25)

        let app = TUIApp()
        app.heroConfig = nil
        app.sidebarModel = TUISidebarModel(
            summary: "会话摘要",
            cacheLayers: [pCoreLayer, eCoreLayer],
            mcpItems: [],
            tasks: []
        )

        let size = TUISize(width: 110, height: 35)
        let frame = app.render(size: size, overlay: nil)
        let renderedText = frame.text(in: TUIRect(x: 0, y: 0, width: size.width, height: size.height))

        // P-Core 具有硬容量，应当展示百分比和进度条
        #expect(renderedText.contains("P-Core: 2.5k/10k (25.0%)"))

        // E-Core 无硬容量，必须只展示文本，绝不展示虚假的 (100.0%)！
        #expect(renderedText.contains("E-Core: 42 objs · 1.0 MB"))
        #expect(!renderedText.contains("E-Core: 42 objs · 1.0 MB (100.0%)"))
        #expect(!renderedText.contains("E-Core: 42 objs · 1.0 MB (0.0%)"))
    }

    // MARK: - 2. MCP 状态完全由 Core authoritative state 驱动，消除 failedMCPServers 跨 session 污染与文本推断
    @MainActor
    @Test func mcpStatusIsAuthoritativelyDrivenByExtensionsWithoutCrossSessionPollution() {
        let tui = ApplicationTUI(options: TUILaunchOptions())

        // 构造两个 session：session 1 发生了一个 tool 报错（历史文本包含 github 和 mcpServerUnavailable）
        let session1ID = SessionID("sess-1")
        var session1 = SessionViewState(sessionID: session1ID)
        let failedToolNode = TimelineNode(
            id: .tool(ToolCallID("call-fail")),
            timestamp: Date(),
            kind: .tool(ToolNode(
                callID: ToolCallID("call-fail"),
                toolName: "mcp_github_create_issue",
                phase: .failed,
                result: ToolResultSnapshot(
                    callID: ToolCallID("call-fail"),
                    toolName: "mcp_github_create_issue",
                    success: false,
                    summary: "mcpServerUnavailable for github",
                    preview: "Connection refused",
                    error: RuntimeError(category: .tool, code: "mcpServerUnavailable", message: "github MCP unavailable")
                )
            ))
        )
        session1.appendNode(failedToolNode)

        // 但 Core 报告的权威扩展状态是：github 已经恢复 ready，notion 处于 error
        let exts = [
            ExtensionInfo(id: "github", version: "1.0", kind: .mcp, scope: "global", enabled: true, lifecycleState: "ready"),
            ExtensionInfo(id: "notion", version: "1.0", kind: .mcp, scope: "global", enabled: true, lifecycleState: "error: failed to start")
        ]

        var appState = ApplicationState()
        appState.activeSessionID = session1ID
        appState.activeSessionState = session1
        appState.extensions = exts

        let sidebarSession1 = tui.buildSidebarModelForTesting(from: appState)
        let githubItem1 = sidebarSession1.mcpItems.first(where: { $0.id == "github" })
        let notionItem1 = sidebarSession1.mcpItems.first(where: { $0.id == "notion" })

        // 权威校验：即便 timeline 历史有报错，github 必须根据 Core 的权威 ready 判定为 ready，不得被历史文本污染为 error！
        #expect(githubItem1?.status == .ready)
        #expect(notionItem1?.status == .error("错误"))

        // 切换到全新的 session 2（无任何历史节点）
        let session2ID = SessionID("sess-2")
        let session2 = SessionViewState(sessionID: session2ID)
        appState.activeSessionID = session2ID
        appState.activeSessionState = session2

        let sidebarSession2 = tui.buildSidebarModelForTesting(from: appState)
        let githubItem2 = sidebarSession2.mcpItems.first(where: { $0.id == "github" })

        // 杜绝跨 Session 污染：session 2 的 github 依然干净地维持 ready
        #expect(githubItem2?.status == .ready)
    }

    // MARK: - 3. 拒绝从 Timeline Markdown 历史中偷猜 Checkbox 任务
    @MainActor
    @Test func tasksAreNotHeuristicallyInferredFromAssistantMarkdownCheckboxes() {
        let tui = ApplicationTUI(options: TUILaunchOptions())

        let sessionID = SessionID("sess-markdown-check")
        var session = SessionViewState(sessionID: sessionID)

        // 助手消息中包含了 Markdown 任务列表语法
        let assistantMsgNode = TimelineNode(
            id: .message(MessageID("msg-ast")),
            timestamp: Date(),
            kind: .message(MessageNode(
                messageID: MessageID("msg-ast"),
                role: .assistant,
                content: """
                以下是本次工作的计划：
                - [ ] 步骤一：分析依赖
                - [x] 步骤二：编写测试
                - [-] 步骤三：取消任务
                """
            ))
        )
        session.appendNode(assistantMsgNode)

        var appState = ApplicationState()
        appState.activeSessionID = sessionID
        appState.activeSessionState = session
        appState.workflows = [] // 无权威 workflow

        let sidebar = tui.buildSidebarModelForTesting(from: appState)

        // 权威事实约束：由于没有权威的 session.todos 或 workflows，tasks 列表必须为空，禁止从 markdown 历史偷猜！
        #expect(sidebar.tasks.isEmpty, "Tasks must not be inferred from assistant markdown checkboxes")
    }

    // MARK: - 4. 权威 Todos 流转：Core SessionSnapshot -> SessionViewState -> TUI Sidebar
    @MainActor
    @Test func authoritativeTodosFlowFromSessionSnapshotToSessionViewStateAndSidebar() {
        let sessionID = SessionID("sess-todos-flow")

        let authoritativeTodos = [
            TodoItemData(id: "t-1", title: "实现跨平台构建网关", status: "completed"),
            TodoItemData(id: "t-2", title: "修复流式背压合流", status: "in_progress")
        ]

        let summary = SessionSummary(sessionID: sessionID, title: "权威 Todo 测试")
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            info: summary,
            contextState: ContextStateSnapshot(sessionID: sessionID),
            eventCursor: EventCursor(generationID: EventLogGenerationID("gen1"), sequence: 1),
            todos: authoritativeTodos
        )

        var sessionView = SessionViewState(sessionID: sessionID)
        _ = SessionReducer.reduceSnapshot(
            state: &sessionView,
            snapshot: snapshot,
            connectionState: ConnectionState(status: .connected)
        )

        // 验证 Reducer 正确同步了权威 todos
        #expect(sessionView.todos.count == 2)
        #expect(sessionView.todos.first?.title == "实现跨平台构建网关")
        #expect(sessionView.todos.first?.status == "completed")

        // 验证 TUI Sidebar 正确渲染权威 todos
        let tui = ApplicationTUI(options: TUILaunchOptions())
        var appState = ApplicationState()
        appState.activeSessionID = sessionID
        appState.activeSessionState = sessionView

        let sidebar = tui.buildSidebarModelForTesting(from: appState)
        #expect(sidebar.tasks.count == 2)
        #expect(sidebar.tasks[0].title == "实现跨平台构建网关")
        #expect(sidebar.tasks[0].status == .completed)
        #expect(sidebar.tasks[1].title == "修复流式背压合流")
        #expect(sidebar.tasks[1].status == .inProgress)
    }
}
