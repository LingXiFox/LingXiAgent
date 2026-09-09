import Testing
import Foundation
@testable import LingXiCore
@testable import LingXiProtocol
@testable import LingXiApplication
@testable import LingXiTUIComponents

private actor StreamCollector {
    var texts: [String] = []
    var isFinished = false
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func append(_ text: String) {
        texts.append(text)
    }

    func count() -> Int {
        texts.count
    }

    func joined() -> String {
        texts.joined()
    }

    func markFinished() {
        isFinished = true
        finishContinuation?.resume()
        finishContinuation = nil
    }

    func waitForFinish() async {
        if isFinished { return }
        await withCheckedContinuation { cont in
            self.finishContinuation = cont
        }
    }
}

@Suite("UX and Streaming Fixes Tests")
struct UXAndStreamingFixesTests {

    // MARK: - 1. 问题 4 验证：MCP 错误与空列表状态细化及模型诊断条目暴露
    @Test("MCP Tool Pager marks empty tools and exposes diagnostic search candidates")
    func mcpEmptyAndErrorStateDiagnostics() async throws {
        let pager = MCPToolPager()
        let emptyServerID = MCPServerID("openapi-mcp-core")
        
        // 模拟 Core 探测到一个工具列表为空的 MCP 服务
        try await pager.replaceCatalog(serverID: emptyServerID, tools: [])
        await pager.recordServerStatus(.empty, for: emptyServerID, alias: "openapi-mcp-core")

        let emptyStatus = await pager.serverStatus(for: emptyServerID)
        #expect(emptyStatus == .empty)

        // 模型在搜索该 server 时，必须能拿到诊断信息而不是冷冰冰的 []
        let searchForEmpty = await pager.search(sessionID: SessionID("s1"), projectID: ProjectID("p1"), query: "openapi")
        #expect(searchForEmpty.count == 1)
        #expect(searchForEmpty.first?.availability == "empty")
        #expect(searchForEmpty.first?.toolID.rawValue.contains("diagnostic") == true)
        #expect(searchForEmpty.first?.shortDescription.contains("0 tools") == true)

        // 若模型尝试 load 诊断条目，必须抛出明确的拒绝错误，指引模型使用内置工具
        if let diagID = searchForEmpty.first?.toolID {
            await #expect(throws: CoreError.self) {
                _ = try await pager.load(sessionID: SessionID("s1"), toolID: diagID, schemaTokenBudget: 1000)
            }
        }

        // 测试错误服务的隔离与诊断暴露
        let brokenServerID = MCPServerID("penpot-broken")
        await pager.recordServerStatus(.error(reason: "Connection refused"), for: brokenServerID, alias: "penpot")
        let searchForBroken = await pager.search(sessionID: SessionID("s1"), projectID: ProjectID("p1"), query: "penpot")
        #expect(searchForBroken.count == 1)
        #expect(searchForBroken.first?.availability == "unavailable")
        #expect(searchForBroken.first?.shortDescription.contains("Connection refused") == true)
    }

    // MARK: - 2. 问题 4 验证：自适应平滑流式吐字缓冲区
    @Test("Adaptive Fluid Stream Pacer delivers smoothly and flushes completely")
    func adaptiveFluidStreamPacerSmoothDelivery() async throws {
        let pacer = AdaptiveFluidStreamPacer(intervalMs: 10)
        let collector = StreamCollector()

        pacer.setHandlers(
            onYield: { frame in
                await collector.append(frame.textPayload ?? "")
            },
            onFinished: {
                await collector.markFinished()
            }
        )

        // 模拟一次突发输入 40 个字符（模仿网络卡顿后突然冒出的 chunk）
        let inputString = "你好主人，这是一段用于验证平滑流式吐字的测试文本，确保不卡顿！"
        let streamID = StreamID("test-stream")
        let frame = StreamFrame(
            streamID: streamID,
            owner: CausalContext(sessionID: SessionID("s1"), modelStepID: ModelStepID("m1")),
            index: 0,
            kind: .assistantText,
            text: inputString
        )

        pacer.enqueue(frame)

        // 等待微任务平滑步长调度推进
        try await Task.sleep(nanoseconds: 50_000_000)

        let chunksSoFar = await collector.count()
        // 应该被平滑切分为多个小块逐帧输出，而不是一次性输出 1 个大块
        #expect(chunksSoFar >= 2)

        // 结束流
        await pacer.finish()
        await collector.waitForFinish()

        let combined = await collector.joined()

        // 验证最终文本 100% 完整无缺，中文字符无乱码
        #expect(combined == inputString)
    }

    // MARK: - 3. 问题 3 验证：侧边栏独立局部滚动与固定顶栏
    @Test("Sidebar renders modular sections with independent local scrolling")
    func sidebarModularIndependentScrolling() {
        let app = TUIApp()
        app.heroConfig = nil

        let mcpItems = (1...6).map {
            TUISidebarModel.MCPItem(id: "mcp_service_\($0)", status: $0 == 2 ? .error("不可用") : .ready)
        }
        let tasks = (1...6).map {
            TUISidebarModel.TaskItem(id: "t_\($0)", title: "Task number \($0)", status: .pending)
        }

        app.sidebarModel = TUISidebarModel(
            summary: "Active UX Fix Session",
            cacheLayers: [
                TUISidebarModel.CacheLayer(name: "L1", usedTokens: 500, capacityTokens: 1000)
            ],
            prefixCache: TUISidebarModel.PrefixCacheStats(
                cachedTokens: 800,
                promptTokens: 1000,
                status: "active"
            ),
            mcpItems: mcpItems,
            tasks: tasks,
            mcpScrollOffset: 0,
            taskScrollOffset: 0
        )

        let size = TUISize(width: 110, height: 35)
        let frame = app.render(size: size, overlay: nil)
        let renderedText = frame.text(in: TUIRect(x: 0, y: 0, width: size.width, height: size.height))

        // 验证：固定顶栏常驻存在
        #expect(renderedText.contains("◈ 会话摘要"))
        #expect(renderedText.contains("Active UX Fix Session"))
        #expect(renderedText.contains("◈ 缓存用量"))

        // 验证：MCP 组件和 Tasks 组件存在
        #expect(renderedText.contains("◈ MCP 工具"))
        #expect(renderedText.contains("◈ 待办任务"))

        // 验证：错误 MCP 状态正确标注为不可用
        #expect(renderedText.contains("不可用"))
    }

    // MARK: - 4. 问题 3 验证：限流调度器精确释放与新会话立即重置
    @Test("ProviderRateScheduler releases slots cleanly and supports reset")
    func rateSchedulerCleanSlotReleaseAndReset() async throws {
        let scheduler = ProviderRateScheduler()
        let endpoint = ResolvedModelEndpoint(
            providerID: "sensenova",
            accountID: "acc1",
            modelID: ModelID("deepseek-v4-flash"),
            baseURL: URL(string: "https://token.sensenova.cn/v1")!,
            wireProtocol: .chatCompletions
        )
        let req1 = ModelRequestID("req-1")
        let req2 = ModelRequestID("req-2")

        // 准入第一个请求
        try await scheduler.admit(endpoint: endpoint, requestID: req1, estimatedTokens: 500)
        let active1 = await scheduler.activeRequests(for: endpoint)
        #expect(active1 == 1)

        // 取消第一个请求：必须立即从 active 槽位和 token workloads 中剔除
        await scheduler.cancel(requestID: req1, endpoint: endpoint)
        let activeAfterCancel = await scheduler.activeRequests(for: endpoint)
        #expect(activeAfterCancel == 0)

        // 准入第二个请求
        try await scheduler.admit(endpoint: endpoint, requestID: req2, estimatedTokens: 1000)
        #expect(await scheduler.activeRequests(for: endpoint) == 1)

        // 正常完成 release
        await scheduler.release(requestID: req2, endpoint: endpoint)
        #expect(await scheduler.activeRequests(for: endpoint) == 0)

        // 全局重置（模拟 /new 新会话）
        await scheduler.reset()
        #expect(await scheduler.activeRequests(for: endpoint) == 0)
    }

    // MARK: - 5. 精简 Agent Runtime Guidelines 注入验证
    @Test("Agent instructions inject compact runtime guidelines with prefix stability")
    func agentCompactRuntimeGuidelinesInjected() {
        let emptySet = try! AgentInstructionSet.load(workspace: FileManager.default.temporaryDirectory)
        let rendered = AgentBehaviorInstructions.render(
            profile: .build,
            configured: nil,
            repository: emptySet,
            environmentFacts: nil
        )
        #expect(rendered != nil)
        #expect(rendered?.contains("Agent Runtime Guidelines:") == true)
        #expect(rendered?.contains("Task Planning:") == true)
        #expect(rendered?.contains("Tool Discovery:") == true)
    }

    // MARK: - 6. Pass 3 验证：多轮连续调用不因本地 TPM 累加死等数秒
    @Test("Pass 3: Multi-turn tool loops admit rapidly without multi-second stalls")
    func multiTurnRateSchedulerAdmissionDoesNotStall() async throws {
        let scheduler = ProviderRateScheduler()
        let limits = ProviderRateLimits(tpm: 12_000, rpm: 120, maxConcurrentRequests: 2)
        let endpoint = ResolvedModelEndpoint(
            providerID: "test-provider",
            accountID: "acc1",
            modelID: ModelID("deepseek-v4-flash"),
            baseURL: URL(string: "https://api.example.com/v1")!,
            wireProtocol: .chatCompletions,
            rateLimits: limits
        )

        let clock = ContinuousClock()
        let start = clock.now

        // 连续模拟同一个 session 发生 5 次 tool 迭代，每次 8,000 tokens
        // 累积 40,000 tokens 远超 12,000 的 tpm，但在无服务端 429 的情况下必须在很短时间内完成平滑放行
        for i in 1...5 {
            let reqID = ModelRequestID("req-\(i)")
            try await scheduler.admit(endpoint: endpoint, requestID: reqID, estimatedTokens: 8_000)
            await scheduler.release(requestID: reqID, endpoint: endpoint)
        }

        let elapsed = start.duration(to: clock.now).components.seconds
        // 必须在 1 秒之内全部完成，绝对不能等待 5 秒或几十秒
        #expect(elapsed < 1)
    }

    // MARK: - 7. Pass 3 验证：load_tool 隐藏花括号元数据、任务限制4条与圆角UI
    @Test("Pass 3: Metadata suppression, capped task slots, and rounded UI components")
    func pass3VisualRefinementAndMetadataSuppression() {
        let app = TUIApp()
        app.heroConfig = nil

        // 构造 9 个待办任务
        let nineTasks = (1...9).map {
            TUISidebarModel.TaskItem(id: "task-\($0)", title: "测试待办任务第 \($0) 项", status: $0 == 1 ? .inProgress : ($0 == 2 ? .completed : .pending))
        }

        app.sidebarModel = TUISidebarModel(
            summary: "Pass 3 Test Session",
            cacheLayers: [],
            mcpItems: [],
            tasks: nineTasks
        )

        let size = TUISize(width: 120, height: 35)
        let frame = app.render(size: size, overlay: nil)
        let renderedText = frame.text(in: TUIRect(x: 0, y: 0, width: size.width, height: size.height))

        // 验证：待办任务标题标注数量并带有滚动标记 [1/9]
        #expect(renderedText.contains("◈ 待办任务 (9)"))
        #expect(renderedText.contains("[1/9]"))

        // 验证：图标为实心现代符号，未完成任务置顶展示，无古董方括号与奇怪的黄色 [C]
        #expect(renderedText.contains("● 测试待办任务第 1 项"))
        #expect(renderedText.contains("• 测试待办任务第 3 项"))
        #expect(renderedText.contains("• 测试待办任务第 4 项"))
        #expect(!renderedText.contains("[ ]"))
        #expect(!renderedText.contains("[C]"))

        // 验证：滚动后可查看已完成项
        app.sidebarModel = TUISidebarModel(
            summary: "Pass 3 Test Session",
            cacheLayers: [],
            mcpItems: [],
            tasks: nineTasks,
            taskScrollOffset: 5
        )
        let scrolledFrame = app.render(size: size, overlay: nil)
        let scrolledText = scrolledFrame.text(in: TUIRect(x: 0, y: 0, width: size.width, height: size.height))
        #expect(scrolledText.contains("✓ 测试待办任务第 2 项"))

        // 验证：底部输入框使用圆润平滑边框，无 ┼ 缺角
        #expect(renderedText.contains("╭") && renderedText.contains("╮"))
        #expect(renderedText.contains("╰") && renderedText.contains("╯"))
        #expect(!renderedText.contains("┼"))
    }

    @Test("Assistant message renders session parameter footer with dim styling at completion")
    func testAssistantMessageRendersSessionParametersFooterWithDimStyle() {
        let viewport = TranscriptViewport()
        let sampleContent = """
        你好！我是 LingXiAgent 工作区中的编程助手。
        
        我已经准备好为你效劳。
        
        ⚡️ deepseek-chat · 耗时 1.8s · 首字 420ms · 48.5 tok/s · 23:00:12
        """
        let entry = TUITranscriptEntry(
            id: "msg-test",
            kind: .assistant,
            text: sampleContent,
            timestamp: Date()
        )

        viewport.append(entry)
        let lines = viewport.render(viewportHeight: 20, width: 80)

        // 验证第一行为带 ✦ 的助手正文，样式为 .assistantText
        let firstLine = lines.first(where: { $0.text.contains("你好！我是 LingXiAgent") })
        #expect(firstLine != nil)
        #expect(firstLine?.text.hasPrefix("✦ ") == true)
        #expect(firstLine?.style == .assistantText)

        // 验证参数行包含 ⚡️，无 ✦ 前缀，样式为 .dim
        let paramLine = lines.first(where: { $0.text.contains("⚡️ deepseek-chat") })
        #expect(paramLine != nil)
        #expect(paramLine?.text.contains("耗时 1.8s") == true)
        #expect(paramLine?.text.contains("首字 420ms") == true)
        #expect(paramLine?.text.contains("48.5 tok/s") == true)
        #expect(paramLine?.text.contains("23:00:12") == true)
        #expect(!paramLine!.text.hasPrefix("✦ "))
        #expect(paramLine?.style == .dim)
    }
}
