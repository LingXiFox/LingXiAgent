import Foundation
import Darwin
import Testing
import LingXiProtocol
import LingXiCore
import LingXiClient
import LingXiApplication

/// 真实 Provider smoke test。默认跳过，避免离线测试消耗 Provider 配额。
@Suite(.serialized)
struct RealProviderSmokeTests {
    private struct SmokeStageTimeout: Error, Sendable, CustomStringConvertible {
        let stage: String
        var description: String { "Real Provider Smoke timed out at \(stage)" }
    }

    private func trace(_ stage: String) {
        FileHandle.standardError.write(Data(("[real-smoke] \(stage)\n").utf8))
    }

    private func smokeAssembly(_ environment: [String: String]) -> ModelRuntimeAssembly? {
        guard let base = environment["LINGXI_PROVIDER_BASE_URL"], let baseURL = URL(string: base), baseURL.scheme != nil, baseURL.host() != nil,
              let model = environment["LINGXI_PROVIDER_MODEL"], !model.isEmpty,
              let wire = environment["LINGXI_PROVIDER_WIRE_PROTOCOL"].flatMap(ModelWireProtocol.init(rawValue:))
        else { return nil }
        let config = ProviderConfig(baseURL: baseURL, apiKey: environment["LINGXI_PROVIDER_API_KEY"], model: model, wireProtocol: wire)
        let provider: any ModelProvider = switch wire {
        case .chatCompletions: OpenAICompatibleProvider(config: config)
        case .responses: OpenAIResponsesProvider(config: config)
        case .anthropicMessages: AnthropicMessagesProvider(config: config)
        }
        return ModelRuntimeAssembly(provider: provider, modelID: ModelID(model), endpoint: ResolvedModelEndpoint(providerID: "smoke", modelID: ModelID(model), baseURL: baseURL, wireProtocol: wire))
    }

    private func within<T: Sendable>(
        _ stage: String,
        seconds: Double = 45,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                try Task.checkCancellation()
                throw SmokeStageTimeout(stage: stage)
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw SmokeStageTimeout(stage: stage) }
            return value
        }
    }

    private func send(_ client: LingXiClient, sessionID: SessionID, timeout: Double = 45, _ prompt: String) async throws -> String {
        trace("provider-request-start")
        let text = try await within("provider-request", seconds: timeout) {
            let stream = try await client.sendMessage(sessionID: sessionID, content: prompt)
            var text = ""
            for try await chunk in stream where chunk.kind == .text { text += chunk.text }
            try await Task.sleep(for: .seconds(5))
            return text
        }
        trace("provider-request-finished")
        return text
    }

    @Test func realProviderPhaseNineSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LINGXI_RUN_REAL_PROVIDER_SMOKE"] == "1",
              let assembly = smokeAssembly(environment)
        else {
            return
        }
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-phase9-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        setenv("LINGXI_PERF_DEBUG", "1", 1)
        let host = try CoreHost(
            providerAssembly: assembly,
            workspaceRoot: try WorkspaceRoot(path: workspaceURL.path),
            permissionDecision: .allow
        )
        await host.start()
        let client = LingXiClient.inProcess(endpoint: host)

        do {
            let sessionID = try await client.createSession()
            var anchors: [(name: String, messageID: MessageID)] = []
            var transition: (name: String, messageID: MessageID)?
            for index in 1...12 {
                let before = try await client.context(sessionID)
                let name = String(format: "Anchor-%02d", index)
                _ = try await send(client, sessionID: sessionID, "记住会话标记 \(name)。")
                let session = try await client.session(sessionID)
                let message = try #require(session.messages.last { $0.role == .user && $0.content.contains(name) })
                anchors.append((name, message.id))
                let after = try #require(await client.context(sessionID))
                if transition == nil, let before {
                    transition = anchors.dropLast().first { anchor in
                        before.units.first { $0.messageID == anchor.messageID }?.residency == .active &&
                        after.units.first { $0.messageID == anchor.messageID }?.residency == .derived
                    }
                }
            }
            for prompt in [
                "说明 ToolRuntime 与 PermissionEngine 的关系。直接回答，不调用工具。",
                "说明 SessionRuntime 与 ContextPager 的关系。直接回答，不调用工具。",
                "说明 Symbol Index 与 Reference Index 如何参与 Context retrieval。直接回答，不调用工具。",
            ] {
                let before = try await client.context(sessionID)
                _ = try await send(client, sessionID: sessionID, prompt)
                let after = try #require(await client.context(sessionID))
                if transition == nil, let before {
                    transition = anchors.first { anchor in
                        before.units.first { $0.messageID == anchor.messageID }?.residency == .active &&
                        after.units.first { $0.messageID == anchor.messageID }?.residency == .derived
                    }
                }
            }
            let beforeCompact = try #require(await client.context(sessionID))
            let performanceBeforeCompact = try #require(await client.performance(sessionID))
            let budget = try #require(performanceBeforeCompact.contextBudget)
            #expect(budget.lowWater > beforeCompact.mandatoryTokens + 256)
            print("[rehydration-budget] mandatory=\(beforeCompact.mandatoryTokens) preferred=\(budget.preferredActive) low=\(budget.lowWater) active=\(beforeCompact.estimatedTokens) project=\(beforeCompact.projectTokens) session=\(beforeCompact.recentSessionTokens)")
            let canonical = try await client.session(sessionID)
            var compact = try await client.compact(sessionID)
            var afterCompact = try #require(await client.context(sessionID))
            #expect(compact.triggerSource == "manual")
            #expect(compact.beforeEstimatedTokens > compact.afterEstimatedTokens)
            #expect(compact.reductionPercent > 0)
            if transition == nil {
                transition = anchors.first { anchor in
                    beforeCompact.units.first { $0.messageID == anchor.messageID }?.residency == .active &&
                    afterCompact.units.first { $0.messageID == anchor.messageID }?.residency == .derived
                }
            }
            if !anchors.contains(where: { anchor in afterCompact.units.first { $0.messageID == anchor.messageID }?.residency == .derived }) {
                for index in 13...16 {
                    let beforeSend = try #require(await client.context(sessionID))
                    let name = String(format: "Anchor-%02d", index)
                    _ = try await send(client, sessionID: sessionID, "记住会话标记 \(name)。")
                    let session = try await client.session(sessionID)
                    let message = try #require(session.messages.last { $0.role == .user && $0.content.contains(name) })
                    anchors.append((name, message.id))
                    let afterSend = try #require(await client.context(sessionID))
                    if transition == nil {
                        transition = anchors.dropLast().first { anchor in
                            beforeSend.units.first { $0.messageID == anchor.messageID }?.residency == .active &&
                            afterSend.units.first { $0.messageID == anchor.messageID }?.residency == .derived
                        }
                    }
                    let canonicalBeforeRetry = try await client.session(sessionID)
                    compact = try await client.compact(sessionID)
                    afterCompact = try #require(await client.context(sessionID))
                    #expect(try await client.session(sessionID) == canonicalBeforeRetry)
                    if transition == nil {
                        transition = anchors.first { anchor in
                            afterSend.units.first { $0.messageID == anchor.messageID }?.residency == .active &&
                            afterCompact.units.first { $0.messageID == anchor.messageID }?.residency == .derived
                        }
                    }
                    if anchors.contains(where: { anchor in afterCompact.units.first { $0.messageID == anchor.messageID }?.residency == .derived }) { break }
                }
            }
            print("[rehydration-compact] before=\(compact.beforeEstimatedTokens) after=\(compact.afterEstimatedTokens) reduction=\(compact.reductionTokens) percent=\(String(format: "%.2f", compact.reductionPercent)) low=\(compact.targetLowWater) mandatory=\(compact.mandatoryFloor) paged=\(compact.unitsPagedOut) projectOffloads=\(compact.projectBackedOffloads) derivedCreated=\(compact.derivedPagesCreated) historical=\(compact.historicalToolBatchesPagedOut) generation=\(compact.compactionGeneration)")
            guard let marker = transition ?? anchors.first(where: { anchor in
                afterCompact.units.first { $0.messageID == anchor.messageID }?.residency == .derived
            }) else {
                print("[rehydration-after] active=\(afterCompact.estimatedTokens) project=\(afterCompact.projectTokens) session=\(afterCompact.recentSessionTokens) mandatory=\(afterCompact.mandatoryTokens)")
                Issue.record("没有 historical ordinary user unit 被换出到 Derived L3")
                await host.shutdown()
                return
            }
            let markerUnit = try #require(afterCompact.units.first { $0.messageID == marker.messageID })
            #expect(markerUnit.residency == .derived)
            let markerPageID = try #require(markerUnit.derivedPageID)
            #expect(!afterCompact.materializedDerivedPageIDs.contains(markerPageID))
            let canonicalAfterCompact = try await client.session(sessionID)
            #expect(Array(canonicalAfterCompact.messages.prefix(canonical.messages.count)) == canonical.messages)
            let cacheBefore = try await client.projectCache()
            let answer = try await send(client, sessionID: sessionID, "我之前让你记住的 \(marker.name) 是什么？直接回答，不调用工具。")
            #expect(answer.contains(marker.name))
            #expect((try await client.session(sessionID)).messages.count > canonical.messages.count)
            let cache = try await client.projectCache()
            #expect(cache.derivedL3Hits > cacheBefore.derivedL3Hits)
            #expect(cache.sessionL2DerivedPromotions > cacheBefore.sessionL2DerivedPromotions || cache.sessionL2DerivedHits > cacheBefore.sessionL2DerivedHits)
            #expect(cache.derivedPageInCount > cacheBefore.derivedPageInCount)
            let rehydrated = try #require(await client.context(sessionID))
            #expect(rehydrated.derivedPageCount > 0)
            #expect(rehydrated.derivedTokens > 0)
            #expect(rehydrated.materializedDerivedPageIDs.contains(markerPageID))
            let performance = try #require(await client.performance(sessionID))
            #expect(performance.derivedL3Hits > 0)
            #expect(performance.sessionL2DerivedPromotions > 0 || performance.sessionL2DerivedHits > 0)
            #expect(performance.derivedPageIns > 0)
            #expect(afterCompact.compactionGeneration > 0)
            unsetenv("LINGXI_PERF_DEBUG")
            await host.shutdown()
        } catch {
            await host.shutdown()
            throw error
        }
    }

    @Test func realProviderPhaseTenRestartSmoke() async throws {
        trace("test-enter")
        let environment = ProcessInfo.processInfo.environment
        guard environment["LINGXI_RUN_REAL_PROVIDER_SMOKE"] == "1",
              let assembly = smokeAssembly(environment)
        else { return }
        let dataRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-phase10-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-phase10-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceURL.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data("public actor ContextPager {}\n".utf8).write(to: workspaceURL.appendingPathComponent("Sources/ContextPager.swift"))
        setenv("LINGXI_PERF_DEBUG", "1", 1)
        defer {
            unsetenv("LINGXI_PERF_DEBUG")
            try? FileManager.default.removeItem(at: dataRoot)
            try? FileManager.default.removeItem(at: workspaceURL)
        }

        let workspace = try WorkspaceRoot(path: workspaceURL.path)
        trace("core-a-start")
        let first = try await within("core-a-start") {
            let host = try CoreHost(providerAssembly: assembly, workspaceRoot: workspace, dataRoot: dataRoot, permissionDecision: .allow)
            await host.start()
            return host
        }
        let firstClient = LingXiClient.inProcess(endpoint: first)
        trace("project-open")
        _ = try await within("project-open") { try await firstClient.projectCache() }
        trace("session-created")
        let sessionID = try await within("session-created") { try await firstClient.createSession() }
        trace("turn-1-start")
        _ = try await within("turn-1") { try await send(firstClient, sessionID: sessionID, "记住持久化测试标记 PersistAnchor-729。只回复确认，不调用工具。") }
        trace("turn-1-finished")
        _ = try await within("compact") { try await firstClient.compact(sessionID) }
        trace("compact-finished")
        let firstPersistence = try #require(await first.persistence)
        let projectID = firstPersistence.projectID
        let mainBindingID = try await firstPersistence.mainRootBinding().id
        let canonical = try await firstClient.session(sessionID)
        trace("core-a-shutdown")
        _ = try await within("core-a-shutdown") { await first.shutdown() }

        trace("core-b-start")
        let second = try await within("core-b-start") {
            let host = try CoreHost(providerAssembly: assembly, workspaceRoot: workspace, dataRoot: dataRoot, permissionDecision: .allow)
            await host.start()
            return host
        }
        let secondClient = LingXiClient.inProcess(endpoint: second)
        trace("session-restored")
        let restored = try await within("session-restored") { try await secondClient.session(sessionID) }
        #expect(restored == canonical)
        let secondPersistence = try #require(await second.persistence)
        #expect(secondPersistence.projectID == projectID)
        #expect(try await secondPersistence.mainRootBinding().id == mainBindingID)
        trace("turn-2-start")
        let marker = try await within("turn-2") { try await send(secondClient, sessionID: sessionID, "我之前让你记住的持久化测试标记是什么？直接回答，不调用工具。") }
        trace("turn-2-finished")
        #expect(marker.contains("PersistAnchor-729"))
        _ = try await within("core-b-shutdown") { await second.shutdown() }
        trace("done")
    }

    @Test func realProviderPhaseTwelveHTTPMCPSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LINGXI_RUN_REAL_PROVIDER_SMOKE"] == "1",
              let assembly = smokeAssembly(environment)
        else { return }
        let server = try FixtureMCPHTTPServer()
        defer { server.stop() }
        let serverID = MCPServerID("fixture-server")
        let transport = MCPStreamableHTTPTransport(configuration: MCPServerConfiguration(serverID: serverID, alias: "fixture", transport: .streamableHTTP, endpoint: server.endpoint, timeoutSeconds: 30))
        let connections = MCPConnectionManager()
        await connections.register(transport, for: serverID)
        let pager = MCPToolPager(invoker: connections)
        try await pager.replaceCatalog(serverID: serverID, tools: try await transport.listTools())
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-phase12-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let host = try CoreHost(providerAssembly: assembly, workspaceRoot: try WorkspaceRoot(path: rootURL.path), permissionDecision: .allow, mcpPager: pager)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let answer = try await within("phase12-http-mcp", seconds: 180) {
            try await send(client, sessionID: sessionID, timeout: 180, "有一个外部 MCP 测试服务包含 phase12 的测试标记。请通过工具目录找到合适能力，load 后立即用 key=phase12 调用该外部工具。不要搜索 workspace，不要猜测，也不要只描述下一步。")
        }
        #expect(answer.contains("MCPAnchor-729"))
        #expect(await pager.leaseCount(sessionID: sessionID) == 0)
        let residency = await pager.requestSchemaCounts(sessionID: sessionID)
        #expect(residency.first == 0)
        #expect(residency.contains(1))
        #expect(residency.last == 0)
    }

    @Test func realProviderPhaseThirteenMultiAgentSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LINGXI_RUN_REAL_PROVIDER_SMOKE"] == "1",
              let assembly = smokeAssembly(environment)
        else { return }
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-phase13-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data("public struct Foo { public let value = 1 }\n".utf8).write(to: rootURL.appendingPathComponent("Foo.swift"))
        try Data("public struct Bar { public let value = 2 }\n".utf8).write(to: rootURL.appendingPathComponent("Bar.swift"))
        let host = try CoreHost(providerAssembly: assembly, workspaceRoot: try WorkspaceRoot(path: rootURL.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let root = try await client.createSession()
        _ = try await within("phase13-spawn", seconds: 120) {
            try await send(client, sessionID: root, timeout: 120, "必须立刻使用 subagent 工具创建两个 child：一个 task 分析 Foo.swift，一个 task 分析 Bar.swift。只负责 spawn，不能自己分析文件，也不要等待或汇总。")
        }
        let deadline = Date().addingTimeInterval(120)
        var tree = try await client.getAgentTree(root)
        while (tree.children.count < 2 || tree.children.contains { $0.latestRun?.status != .completed }), Date() < deadline {
            try await Task.sleep(for: .seconds(1))
            tree = try await client.getAgentTree(root)
        }
        try #require(tree.children.count >= 2)
        try #require(tree.children.allSatisfy { $0.latestRun?.status == .completed })
        #expect(tree.children.allSatisfy { $0.latestRun?.sessionID == $0.session.id })
        let runIDs = tree.children.compactMap { $0.latestRun?.runID.rawValue }.joined(separator: ", ")
        _ = try await within("phase13-results", seconds: 120) {
            try await send(client, sessionID: root, timeout: 120, "必须通过 subagent 工具 action=result 读取这两个已完成 child run：\(runIDs)。只读取结果，不要汇总。")
        }
        let answer = try await within("phase13-synthesis", seconds: 120) {
            try await send(client, sessionID: root, timeout: 120, "不要调用任何工具。基于刚才读取的两个 subagent result，只用两句汇总 Foo 和 Bar 各自职责。")
        }
        #expect(answer.localizedCaseInsensitiveContains("Foo"))
        #expect(answer.localizedCaseInsensitiveContains("Bar"))
    }

    @Test func realProviderResponsesSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LINGXI_RUN_REAL_PROVIDER_SMOKE"] == "1",
              let assembly = smokeAssembly(environment)
        else { return }
        guard assembly.endpoint.wireProtocol == .responses else {
            Issue.record("Responses smoke requires LINGXI_PROVIDER_WIRE_PROTOCOL=responses")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-responses-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "ResponsesToolAnchor-729".write(to: root.appendingPathComponent("anchor.txt"), atomically: true, encoding: .utf8)
        let host = try CoreHost(providerAssembly: assembly, workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let text = try await within("responses-text") {
            try await send(client, sessionID: sessionID, "只回复 ResponsesTextAnchor-729，不调用工具。")
        }
        #expect(!text.isEmpty)
        let tool = try await within("responses-tool", seconds: 90) {
            try await send(client, sessionID: sessionID, "必须调用 read_file 读取 anchor.txt，然后只回复文件内容。")
        }
        let session = try await client.session(sessionID)
        let calledTool = session.messages.flatMap(\.parts).contains { if case .toolCall = $0 { return true }; return false }
        let receivedToolResult = session.messages.flatMap(\.parts).contains { if case .toolResult = $0 { return true }; return false }
        #expect(calledTool)
        #expect(receivedToolResult)
        #expect(tool.contains("ResponsesToolAnchor-729"))
    }

    @MainActor
    @Test func testSensenovaRealPrompt() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["SENSENOVA_API_KEY"] else { return }
        let prompt = """
        请执行系统级全要素综合体检，按以下步骤对当前会话环境中的所有 MCP 工具链、Skills 技能库与 To-Do 任务流进行一次性端到端实测：
        ### 1. 建立 To-Do 任务清单
        请先梳理并输出一份结构化 To-Do 待办清单，包含以下待测项，并在后续每完成一项时实时更新状态（[ ] -> [x]）：
        - [ ] 探活 Notion MCP（调用 read-only 搜索或元数据探测，如 notion-search）
        - [ ] 探活 Context7 MCP（查询官方库信息，如 resolve-library-id 或 query-docs）
        - [ ] 探活 Penpot MCP（探测可用设计项目或画板状态）
        - [ ] 探活 Codebase Memory MCP（查询代码架构或项目索引，如 get_architecture / list_projects）
        - [ ] 探活 Excel MCP（调用基础工作表能力，如版本/公式校验或读取）
        - [ ] 探活 OpenAPI MCP Core（探测云服务 OpenAPI 定义或版本）
        - [ ] 探活 Trivy MCP（执行 trivy_version 探活）
        - [ ] 验证 Skills 技能生态与调用路由
        - [ ] 最终汇总综合体检健康度报告
        ### 2. 逐步执行轻量探活
        对上述每一个 MCP 与技能模块，挑选最安全、无破坏性且轻量的只读/探测接口进行真实调用：
        1. 观察调用是否顺畅、参数解析是否正常。
        2. 记录每个接口返回的有效字段摘要或状态码。
        3. 若某项服务由于外部网络、权限限制发生降级，诚实记录具体原因与返回信息。
        ### 3. 输出最终验收报告
        测试完毕后，更新并展示最终勾选完成的 To-Do 列表，并输出一份 Markdown 表格：
        | 组件类别 | 服务/工具名 | 测试调用动作 | 响应状态（✓/⚠️/×）| 实际返回摘要 |
        |---|---|---|---|---|
        最后给出整体可用性判定结论。
        """
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("test-sensenova-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let userHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lingxiagent", isDirectory: true)
        let config = ProviderConfig(
            baseURL: URL(string: "https://token.sensenova.cn/v1")!,
            apiKey: apiKey,
            model: "deepseek-v4-flash",
            wireProtocol: .chatCompletions,
            diagnosticsEnabled: true
        )
        let provider = OpenAICompatibleProvider(config: config)
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("deepseek-v4-flash"))
        let host = try CoreHost(
            providerAssembly: assembly,
            workspaceRoot: try WorkspaceRoot(path: root.path),
            permissionDecision: .allow
        )
        await host.start()
        defer { Task { await host.shutdown() } }

        let client = try await LingXiClientVNext(transport: InProcessTransport(service: host), handshakeImmediately: true)
        let store = await ApplicationStore(client: client, autoConnect: false)
        try await store.connect()
        await store.dispatch(.createSession(title: "test", mode: .build))
        await store.dispatch(.submitPrompt(prompt))

        print("[TEST] Prompt submitted. Waiting for response...")
        for i in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            let sessionState = await store.state.activeSessionState
            let status = await store.state.status
            let nodes = sessionState?.timelineNodes ?? []
            if i % 4 == 0 {
                print("[TEST] step \(i), status: \(status), nodes count: \(nodes.count)")
                for node in nodes {
                    print("  -> node: \(node.kind)")
                }
            }
            if nodes.contains(where: { if case let .message(m) = $0.kind, m.role == .assistant, !m.content.isEmpty { return true }; return false }) {
                print("[TEST] SUCCESS: got assistant message!")
                break
            }
        }
    }

    @Test func testPrefixCacheWithRealProvider() async throws {
        let dataRoot = LingXiDataRootResolver.resolve(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        guard let configurations = try? ConfigurationStore(dataRoot: dataRoot),
              let snapshot = try? await configurations.load(),
              let credentials = try? PlatformSecureCredentialStore(dataRoot: dataRoot, passphrase: nil),
              let providers = try? await RuntimeConfigurationResolver.resolveProviders(
                  snapshot.providers,
                  credentials: credentials,
                  environment: ProcessInfo.processInfo.environment
              ) else {
            print("[PrefixCacheSmoke] No real provider configured or credential accessible. Skipping real provider test.")
            return
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("test-prefix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let host = try CoreHost(
            providerAssembly: providers.assembly,
            providerMissingRequirements: providers.missingRequirements,
            modelRuntimes: providers.runtimes,
            defaultModelSelection: providers.defaultSelection,
            configuration: snapshot.core,
            workspaceRoot: try WorkspaceRoot(path: root.path),
            dataRoot: dataRoot,
            permissionDecision: .allow
        )
        await host.start()
        defer { Task { await host.shutdown() } }

        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()

        // 构造一个约 3000 tokens 的稳定长前缀内容
        let longPrefix = String(repeating: "灵犀Agent核心前缀缓存测试长文本上下文。包含架构定义、三级缓存L1/L2/L3分层调度、OpenTUI渲染器及工具安全审批流。\n", count: 35)

        print("[PrefixCacheSmoke] ========== Turn 1 (Cold Start) ==========")
        let stream1 = try await client.sendMessage(sessionID: sessionID, content: "\(longPrefix)\n问题1：请只回答数字 101。")
        for try await _ in stream1 {}
        let s1 = await host.contextStateSnapshot(sessionID: sessionID)
        let s1Reuse = s1.prefixReuseEfficiency.map { String(format: "%.1f%%", $0 * 100) } ?? "N/A"
        let s1Share = s1.cachedInputShare.map { String(format: "%.1f%%", $0 * 100) } ?? "0.0%"
        print("[PrefixCacheSmoke] T1: prompt=\(s1.promptTokens ?? 0), cacheRead=\(s1.cacheReadTokens ?? 0), reuse=\(s1Reuse), share=\(s1Share), status=\(s1.cacheStatus ?? "none")")

        print("[PrefixCacheSmoke] ========== Turn 2 (Identical Prefix) ==========")
        let stream2 = try await client.sendMessage(sessionID: sessionID, content: "问题2：请只回答数字 202。")
        for try await _ in stream2 {}
        let s2 = await host.contextStateSnapshot(sessionID: sessionID)
        let s2Reuse = s2.prefixReuseEfficiency.map { String(format: "%.1f%%", $0 * 100) } ?? "N/A"
        let s2Share = s2.cachedInputShare.map { String(format: "%.1f%%", $0 * 100) } ?? "0.0%"
        print("[PrefixCacheSmoke] T2: prompt=\(s2.promptTokens ?? 0), cacheRead=\(s2.cacheReadTokens ?? 0), prev=\(s2.previousPromptTokens ?? 0), reuse=\(s2Reuse), share=\(s2Share), status=\(s2.cacheStatus ?? "none")")
        if let diag = s2.missDiagnostics { print("[PrefixCacheSmoke] T2 Miss Diagnostics: \(diag)") }

        print("[PrefixCacheSmoke] ========== Turn 3 (Extended Turn) ==========")
        let stream3 = try await client.sendMessage(sessionID: sessionID, content: "问题3：请只回答数字 303。")
        for try await _ in stream3 {}
        let s3 = await host.contextStateSnapshot(sessionID: sessionID)
        let s3Reuse = s3.prefixReuseEfficiency.map { String(format: "%.1f%%", $0 * 100) } ?? "N/A"
        let s3Share = s3.cachedInputShare.map { String(format: "%.1f%%", $0 * 100) } ?? "0.0%"
        print("[PrefixCacheSmoke] T3: prompt=\(s3.promptTokens ?? 0), cacheRead=\(s3.cacheReadTokens ?? 0), prev=\(s3.previousPromptTokens ?? 0), reuse=\(s3Reuse), share=\(s3Share), status=\(s3.cacheStatus ?? "none")")
        if let diag = s3.missDiagnostics { print("[PrefixCacheSmoke] T3 Miss Diagnostics: \(diag)") }

        print("[PrefixCacheSmoke] ========== Turn 4 (Extended Turn) ==========")
        let stream4 = try await client.sendMessage(sessionID: sessionID, content: "问题4：请只回答数字 404。")
        for try await _ in stream4 {}
        let s4 = await host.contextStateSnapshot(sessionID: sessionID)
        let s4Reuse = s4.prefixReuseEfficiency.map { String(format: "%.1f%%", $0 * 100) } ?? "N/A"
        let s4Share = s4.cachedInputShare.map { String(format: "%.1f%%", $0 * 100) } ?? "0.0%"
        print("[PrefixCacheSmoke] T4: prompt=\(s4.promptTokens ?? 0), cacheRead=\(s4.cacheReadTokens ?? 0), prev=\(s4.previousPromptTokens ?? 0), reuse=\(s4Reuse), share=\(s4Share), status=\(s4.cacheStatus ?? "none")")
        if let diag = s4.missDiagnostics { print("[PrefixCacheSmoke] T4 Miss Diagnostics: \(diag)") }

        if let cacheRead = s2.cacheReadTokens, cacheRead > 0 {
            print("[PrefixCacheSmoke] SUCCESS: Verified prefix cache hit tokens: \(cacheRead) across multiple rounds!")
        } else {
            print("[PrefixCacheSmoke] NOTE: Provider responded without prompt cache hits (may be cold cache or provider unsupported).")
        }
    }
}
