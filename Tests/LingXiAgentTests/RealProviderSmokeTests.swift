import Foundation
import Darwin
import Testing
import LingXiProtocol
import LingXiCore
import LingXiClient

/// 真实 Provider smoke test。默认跳过，避免离线测试消耗 Provider 配额。
struct RealProviderSmokeTests {
    private struct SmokeStageTimeout: Error, Sendable, CustomStringConvertible {
        let stage: String
        var description: String { "Real Provider Smoke timed out at \(stage)" }
    }

    private func trace(_ stage: String) {
        FileHandle.standardError.write(Data(("[real-smoke] \(stage)\n").utf8))
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

    private func send(_ client: LingXiClient, sessionID: SessionID, _ prompt: String) async throws -> String {
        trace("provider-request-start")
        let stream = try await client.sendMessage(sessionID: sessionID, content: prompt)
        var text = ""
        for try await chunk in stream where chunk.kind == .text { text += chunk.text }
        try await Task.sleep(for: .seconds(5))
        trace("provider-request-finished")
        return text
    }

    @Test func realProviderPhaseNineSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LINGXI_RUN_REAL_PROVIDER_SMOKE"] == "1",
              let base = environment[ProviderSetup.baseURLKey], !base.isEmpty,
              let model = environment[ProviderSetup.modelKey], !model.isEmpty
        else {
            return
        }
        let workspacePath = environment["LINGXI_WORKSPACE_ROOT"].flatMap { $0.isEmpty ? nil : $0 } ?? FileManager.default.currentDirectoryPath

        let (assembly, missing) = ProviderSetup.resolve(environment)
        #expect(missing.isEmpty)
        setenv("LINGXI_CONTEXT_PREFERRED_ACTIVE_TOKENS", "372", 1)
        setenv("LINGXI_PERF_DEBUG", "1", 1)
        let host = try CoreHost(
            providerAssembly: assembly,
            workspaceRoot: try WorkspaceRoot(path: workspacePath),
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
            unsetenv("LINGXI_CONTEXT_PREFERRED_ACTIVE_TOKENS")
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
        guard environment["LINGXI_RUN_REAL_PROVIDER_SMOKE"] == "1"
        else { return }
        let workspacePath = environment["LINGXI_WORKSPACE_ROOT"].flatMap { $0.isEmpty ? nil : $0 } ?? FileManager.default.currentDirectoryPath
        let (assembly, missing) = ProviderSetup.resolve(environment)
        #expect(missing.isEmpty)
        let dataRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-phase10-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        setenv("LINGXI_DATA_ROOT", dataRoot.path, 1)
        setenv("LINGXI_CONTEXT_PREFERRED_ACTIVE_TOKENS", "372", 1)
        setenv("LINGXI_PERF_DEBUG", "1", 1)
        defer {
            unsetenv("LINGXI_DATA_ROOT")
            unsetenv("LINGXI_CONTEXT_PREFERRED_ACTIVE_TOKENS")
            unsetenv("LINGXI_PERF_DEBUG")
            try? FileManager.default.removeItem(at: dataRoot)
        }

        let workspace = try WorkspaceRoot(path: workspacePath)
        trace("core-a-start")
        let first = try await within("core-a-start") {
            let host = try CoreHost(providerAssembly: assembly, workspaceRoot: workspace, permissionDecision: .allow)
            await host.start()
            return host
        }
        let firstClient = LingXiClient.inProcess(endpoint: first)
        trace("project-open")
        _ = try await within("project-open") { try await firstClient.projectCache() }
        trace("session-created")
        let sessionID = try await within("session-created") { try await firstClient.createSession() }
        trace("turn-1-start")
        _ = try await within("turn-1") { try await send(firstClient, sessionID: sessionID, "记住本次持久化测试标记 PersistAnchor-729。" + String(repeating: " PersistAnchor-729", count: 300)) }
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
            let host = try CoreHost(providerAssembly: assembly, workspaceRoot: workspace, permissionDecision: .allow)
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
        let definition = try await within("project-query") { try await send(secondClient, sessionID: sessionID, "ContextPager 定义在哪里，它是什么类型？直接回答，不调用工具。") }
        #expect(definition.localizedCaseInsensitiveContains("ContextPager"))
        _ = try await within("core-b-shutdown") { await second.shutdown() }
        trace("done")
    }

    @Test func realProviderPhaseTwelveHTTPMCPSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LINGXI_RUN_REAL_PROVIDER_SMOKE"] == "1",
              let base = environment[ProviderSetup.baseURLKey], !base.isEmpty,
              let model = environment[ProviderSetup.modelKey], !model.isEmpty
        else { return }
        let (assembly, missing) = ProviderSetup.resolve(environment)
        #expect(missing.isEmpty)
        let server = try FixtureMCPHTTPServer()
        defer { server.stop() }
        let serverID = MCPServerID("fixture-server")
        let transport = MCPStreamableHTTPTransport(configuration: MCPServerConfiguration(serverID: serverID, alias: "fixture", transport: .streamableHTTP, endpoint: server.endpoint, timeoutSeconds: 30))
        let connections = MCPConnectionManager()
        await connections.register(transport, for: serverID)
        let pager = MCPToolPager(invoker: connections)
        try await pager.replaceCatalog(serverID: serverID, tools: try await transport.listTools())
        let root = try WorkspaceRoot(path: environment["LINGXI_WORKSPACE_ROOT"]?.isEmpty == false ? environment["LINGXI_WORKSPACE_ROOT"]! : FileManager.default.currentDirectoryPath)
        let host = try CoreHost(providerAssembly: assembly, workspaceRoot: root, permissionDecision: .allow, mcpPager: pager)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let answer = try await within("phase12-http-mcp", seconds: 90) {
            try await send(client, sessionID: sessionID, "有一个外部 MCP 测试服务包含 phase12 的测试标记。请通过工具目录找到合适能力，load 后立即用 key=phase12 调用该外部工具。不要搜索 workspace，不要猜测，也不要只描述下一步。")
        }
        #expect(answer.contains("MCPAnchor-729"))
        #expect(await pager.leaseCount(sessionID: sessionID) == 0)
        let residency = await pager.requestSchemaCounts(sessionID: sessionID)
        #expect(residency.first == 0)
        #expect(residency.contains(1))
        #expect(residency.last == 0)
    }
}
