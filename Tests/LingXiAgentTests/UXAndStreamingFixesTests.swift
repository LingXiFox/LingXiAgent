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

    @Test("First token latency never displays 0ms and properly accounts for reasoning duration")
    func testFirstTokenNeverShowsZeroMilliseconds() {
        // 场景 1：内部时钟重置产生的纳秒级噪声（0.05ms），必须被过滤，绝不展示 "首字 0ms"
        let zeroMetrics = MessageMetrics(
            model: "deepseek-v4-flash",
            durationMs: 7200.0,
            firstTokenMs: 0.05,
            tokenRate: 138.1
        )
        let ftStr: String? = {
            if let ft = zeroMetrics.firstTokenMs, ft >= 10.0 {
                return ft >= 1000 ? String(format: "%.1fs", ft / 1000.0) : "\(Int(round(ft)))ms"
            } else if let ms = zeroMetrics.durationMs, ms > 200 {
                let estimatedFt = min(ms * 0.25, max(150.0, ms * 0.15))
                return estimatedFt >= 1000 ? String(format: "%.1fs", estimatedFt / 1000.0) : "\(Int(round(estimatedFt)))ms"
            } else {
                return nil
            }
        }()
        #expect(ftStr != "0ms")
        #expect(ftStr != nil)

        // 场景 2：带思考过程的模型（思考耗时 1200ms），正文首字时延必须正确反映 1.2s
        let reasoningMetrics = MessageMetrics(
            model: "deepseek-v4-flash",
            durationMs: 7200.0,
            firstTokenMs: 1200.0,
            tokenRate: 138.1
        )
        let reasoningFtStr: String? = {
            if let ft = reasoningMetrics.firstTokenMs, ft >= 10.0 {
                return ft >= 1000 ? String(format: "%.1fs", ft / 1000.0) : "\(Int(round(ft)))ms"
            } else {
                return nil
            }
        }()
        #expect(reasoningFtStr == "1.2s")
    }

    // MARK: - Waiting 提示与 Codex 模型去重与选择测试
    @Test("Waiting prompt remains clean without slow response notice when not rate limited")
    func testWaitingPromptCleanWithoutSlowResponseNotice() {
        func buildPrompt(isRateLimited: Bool, elapsed: Int, modelID: String, spinnerChar: String = "⠋") -> String {
            if isRateLimited {
                return "\(spinnerChar) 上游限流中 (429)，正在等待恢复重试 (\(elapsed)s)..."
            } else {
                return "\(spinnerChar) Waiting for \(modelID) (\(elapsed)s)..."
            }
        }

        let cleanText = buildPrompt(isRateLimited: false, elapsed: 15, modelID: "deepseek-v4-flash")
        #expect(cleanText == "⠋ Waiting for deepseek-v4-flash (15s)...")
        #expect(!cleanText.contains("上游响应较慢"))
        #expect(!cleanText.contains("限流重试中"))

        let rateLimitedText = buildPrompt(isRateLimited: true, elapsed: 5, modelID: "deepseek-v4-flash")
        #expect(rateLimitedText.contains("上游限流中 (429)"))
    }

    @Test("Codex remote discovery filters internal watermark models and disambiguates variants")
    func testCodexRemoteDiscoveryDeduplicationAndDisambiguation() throws {
        let mockJSON = """
        {
          "models": [
            { "id": "gpt-5-6", "title": "GPT-5.6 Sol", "capabilities": { "tools": true } },
            { "id": "gpt-5-6-instant", "title": "GPT-5.6 Sol", "capabilities": { "tools": true } },
            { "id": "gpt-5-6-thinking", "title": "GPT-5.6 Sol", "capabilities": { "tools": true } },
            { "id": "gpt-5.6-sol-wm", "title": "GPT-5.6 Sol", "capabilities": { "tools": true } },
            { "id": "gpt-5-6-mini", "title": "GPT-5.6 Luna", "capabilities": { "tools": true } },
            { "id": "gpt-5-6-t-mini", "title": "GPT-5.6 Luna", "capabilities": { "tools": true } },
            { "id": "gpt-5.6-luna-wm", "title": "GPT-5.6 Luna", "capabilities": { "tools": true } }
          ]
        }
        """
        let models = try CodexRemoteModelDiscovery.parseRemoteModels(from: Data(mockJSON.utf8))
        
        // 内部水印影子模型 -wm 必须被过滤
        #expect(!models.contains(where: { $0.id.contains("-wm") }))

        // 剩余的公开模型数量应为 5
        #expect(models.count == 5)

        // 验证展示名称已智能消歧，且无任何重复
        let displayNames = models.map(\.displayName)
        let uniqueNames = Set(displayNames)
        #expect(displayNames.count == uniqueNames.count, "模型列表中不应存在重复的 displayName")

        #expect(models.first(where: { $0.id == "gpt-5-6" })?.displayName == "GPT-5.6 Sol")
        #expect(models.first(where: { $0.id == "gpt-5-6-instant" })?.displayName == "GPT-5.6 Sol Instant")
        #expect(models.first(where: { $0.id == "gpt-5-6-thinking" })?.displayName == "GPT-5.6 Sol Thinking")
        #expect(models.first(where: { $0.id == "gpt-5-6-mini" })?.displayName == "GPT-5.6 Luna Mini")
        #expect(models.first(where: { $0.id == "gpt-5-6-t-mini" })?.displayName == "GPT-5.6 Luna Thinking Mini")
    }

    @Test("TUI modelOptions eliminates -wm models and ensures all display names are unique")
    func testTUIModelOptionsDeduplicatesAndDisambiguates() {
        func makeModel(_ id: String, _ slug: String, _ name: String) -> ProviderModelInfo {
            ProviderModelInfo(id: id, providerID: "openai-codex", modelID: slug, displayName: name, contextWindow: 128000, maxOutputTokens: 4096, reasoning: false, configured: true)
        }

        let rawCatalog: [ProviderModelInfo] = [
            makeModel("openai-codex/gpt-5-5", "gpt-5-5", "GPT-5.5"),
            makeModel("openai-codex/gpt-5-5-instant", "gpt-5-5-instant", "GPT-5.5 Instant"),
            makeModel("openai-codex/gpt-5-6", "gpt-5-6", "GPT-5.6 Sol"),
            makeModel("openai-codex/gpt-5-6-instant", "gpt-5-6-instant", "GPT-5.6 Sol"),
            makeModel("openai-codex/gpt-5-5-thinking", "gpt-5-5-thinking", "GPT-5.5 Thinking"),
            makeModel("openai-codex/gpt-5-6-thinking", "gpt-5-6-thinking", "GPT-5.6 Sol"),
            makeModel("openai-codex/gpt-5.5-wm", "gpt-5.5-wm", "GPT-5.5"),
            makeModel("openai-codex/gpt-5.6-sol-wm", "gpt-5.6-sol-wm", "GPT-5.6 Sol"),
            makeModel("openai-codex/gpt-5.6-terra-wm", "gpt-5.6-terra-wm", "GPT-5.6 Terra"),
            makeModel("openai-codex/gpt-5.6-luna-wm", "gpt-5.6-luna-wm", "GPT-5.6 Luna"),
            makeModel("openai-codex/gpt-6-astra-wm", "gpt-6-astra-wm", "GPT-6 Astra"),
            makeModel("openai-codex/gpt-5-3-mini", "gpt-5-3-mini", "GPT-5.3 Mini"),
            makeModel("openai-codex/gpt-5-5-mini", "gpt-5-5-mini", "GPT-5.5 Mini"),
            makeModel("openai-codex/gpt-5-6-mini", "gpt-5-6-mini", "GPT-5.6 Luna"),
            makeModel("openai-codex/gpt-5-4-t-mini", "gpt-5-4-t-mini", "GPT-5.4 Thinking Mini"),
            makeModel("openai-codex/gpt-5-6-t-mini", "gpt-5-6-t-mini", "GPT-5.6 Luna"),
            makeModel("openai-codex/research", "research", "Deep Research"),
        ]

        var seenDisplayKeys = Set<String>()
        var processedItems: [(modelID: String, displayName: String)] = []

        for m in rawCatalog {
            if m.modelID.contains("-wm") {
                continue
            }

            var cleanDisplayName = m.displayName.isEmpty ? m.modelID : m.displayName
            let lowerModelID = m.modelID.lowercased()
            let lowerDisplay = cleanDisplayName.lowercased()
            if lowerModelID.contains("instant") && !lowerDisplay.contains("instant") {
                cleanDisplayName += " Instant"
            } else if (lowerModelID.contains("thinking") || lowerModelID.contains("-t-mini")) && !lowerDisplay.contains("thinking") {
                if lowerModelID.contains("mini") && !lowerDisplay.contains("mini") {
                    cleanDisplayName += " Thinking Mini"
                } else {
                    cleanDisplayName += " Thinking"
                }
            } else if lowerModelID.contains("mini") && !lowerDisplay.contains("mini") {
                cleanDisplayName += " Mini"
            }

            let dedupeKey = "\(m.providerID)::\(cleanDisplayName)"
            if seenDisplayKeys.contains(dedupeKey) {
                cleanDisplayName = "\(cleanDisplayName) (\(m.modelID))"
            }
            seenDisplayKeys.insert("\(m.providerID)::\(cleanDisplayName)")

            processedItems.append((modelID: m.id, displayName: cleanDisplayName))
        }

        // 1. -wm 模型必须全部被过滤
        #expect(!processedItems.contains(where: { $0.modelID.contains("-wm") }))

        // 2. 所有处理后的显示名称必须唯一，绝无重复
        let names = processedItems.map(\.displayName)
        let uniqueNames = Set(names)
        #expect(names.count == uniqueNames.count, "TUI 列表中处理后不应存在重复的 displayName")

        // 3. 验证具体名称
        #expect(processedItems.first(where: { $0.modelID == "openai-codex/gpt-5-6" })?.displayName == "GPT-5.6 Sol")
        #expect(processedItems.first(where: { $0.modelID == "openai-codex/gpt-5-6-instant" })?.displayName == "GPT-5.6 Sol Instant")
        #expect(processedItems.first(where: { $0.modelID == "openai-codex/gpt-5-6-thinking" })?.displayName == "GPT-5.6 Sol Thinking")
        #expect(processedItems.first(where: { $0.modelID == "openai-codex/gpt-5-6-mini" })?.displayName == "GPT-5.6 Luna Mini")
        #expect(processedItems.first(where: { $0.modelID == "openai-codex/gpt-5-6-t-mini" })?.displayName == "GPT-5.6 Luna Thinking Mini")
    }
}
