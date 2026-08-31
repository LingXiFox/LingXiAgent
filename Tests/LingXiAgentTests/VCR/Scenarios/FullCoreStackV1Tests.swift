import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

private actor FullStackEventCapture {
    private var events: [CoreEvent] = []
    func append(_ event: CoreEvent) { events.append(event) }
    func snapshot() -> [CoreEvent] { events }
}

private actor VCRProgressTrace {
    private let started = ContinuousClock.now
    private var lastProgress = ContinuousClock.now
    private var currentStage = "bootstrap"
    private var stages: [String] = []
    private var callStages: [ToolCallID: String] = [:]
    private var runAliases: [AgentRunID: String] = [:]

    func emit(_ stage: String, session: String? = nil, run: String? = nil, step: Int? = nil) {
        currentStage = stage
        stages.append(stage)
        lastProgress = ContinuousClock.now
        var fields = ["stage=\(stage)", "elapsed=\(milliseconds(started.duration(to: lastProgress)))ms"]
        if let session { fields.append("session=\(session)") }
        if let run { fields.append("run=\(run)") }
        if let step { fields.append("step=\(step)") }
        print("VCR progress: \(fields.joined(separator: " "))")
    }

    func observe(_ event: CoreEvent) {
        switch event {
        case let .toolCallCompleted(call):
            let stage: String?
            switch call.toolID.rawValue {
            case "skill": stage = "skill"
            case "read_file", "grep", "symbol_lookup": stage = "builtin-tool"
            case "search_tools": stage = "mcp.search"
            case "load_tool": stage = "mcp.load"
            case "subagent":
                emit("subagent.spawn", session: "main")
                stage = nil
            default: stage = call.toolID.rawValue.hasPrefix("vcrfixture_lookup_anchor_") ? "mcp.call" : nil
            }
            if let stage {
                callStages[call.callID] = stage
                emit("\(stage).begin")
            }
        case let .toolResult(result):
            if let stage = callStages.removeValue(forKey: result.callID) { emit("\(stage).end") }
            if result.toolName == "subagent", !result.success {
                emit("subagent.spawn.failed code=\(result.error?.code ?? "unknown")")
            }
        case let .subagentSpawned(run): emit("subagent.spawn", run: alias(for: run.runID))
        case let .agentRunStarted(run) where run.parentRunID != nil: emit("subagent.child.request.begin", run: alias(for: run.runID))
        case let .agentRunCompleted(run) where run.parentRunID != nil:
            let childAlias = alias(for: run.runID)
            emit("subagent.child.request.end", run: childAlias)
            emit("subagent.completed", run: childAlias)
        case let .agentRunFailed(run) where run.parentRunID != nil:
            emit("subagent.child.failed error=\(run.error.map { String(describing: $0) } ?? "none")", run: alias(for: run.runID))
        case let .agentRunCancelled(run) where run.parentRunID != nil:
            emit("subagent.child.cancelled", run: alias(for: run.runID))
        case .questionEscalated: emit("question.requested")
        default: break
        }
    }

    func reportIfStalled(after threshold: Duration) {
        if let message = stalledMessage(after: threshold) { print(message) }
    }

    func stalledMessage(after threshold: Duration) -> String? {
        let elapsed = lastProgress.duration(to: ContinuousClock.now)
        guard elapsed >= threshold else { return nil }
        return "VCR still running: currentStage=\(currentStage), elapsed=\(milliseconds(elapsed))ms"
    }

    func stageSnapshot() -> [String] { stages }

    func failed(_ error: Error) {
        for line in failureLines(error) { print(line) }
    }

    func failureLines(_ error: Error) -> [String] {
        let blocker: String
        if let error = error as? CoreError { blocker = "CoreError.\(error.code.rawValue)" }
        else if let error = error as? CassetteMismatch { blocker = error.message }
        else if let error = error as? URLError { blocker = "URLError.\(error.code.rawValue)" }
        else { blocker = String(reflecting: type(of: error)) }
        return ["FAILED at stage=\(currentStage)", "blocker=\(blocker)"]
    }

    private func alias(for runID: AgentRunID) -> String {
        if let alias = runAliases[runID] { return alias }
        let alias = "child-\(runAliases.count + 1)"
        runAliases[runID] = alias
        return alias
    }

    private func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000) + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}

@Suite(.serialized)
struct FullCoreStackV1Tests {
    @Test func fullCoreStackV1() async throws {
        let trace = VCRProgressTrace()
        var activeHost: CoreHost?
        do {
            let configuration = try Self.resolveConfiguration()
            await trace.emit("bootstrap")
            let watchdog = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    if Task.isCancelled { return }
                    await trace.reportIfStalled(after: .seconds(30))
                }
            }
            defer { watchdog.cancel() }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-vcr-workspace-\(UUID().uuidString)", isDirectory: true)
        let dataRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-vcr-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: dataRoot)
        }
        try installWorkspaceFixture(at: workspace)

        let mcpServer = try FixtureMCPHTTPServer()
        defer { mcpServer.stop() }
        let pager = try await mcpPager(server: mcpServer)
        let preflight = await pager.search(sessionID: SessionID("vcr-preflight"), projectID: ProjectID("vcr-preflight"), query: "full-core-stack-v1")
        guard let anchor = preflight.first(where: { $0.toolID == ToolID("vcr-fixture::lookup_anchor") }), anchor.availability == "available" else {
            throw CassetteMismatch(message: "fixture anchor missing from MCP L3 catalog before record")
        }
        let cassette = try VCRCassetteStore(
            directory: configuration.cassetteDirectory,
            manifest: configuration.manifest,
            forbiddenSecrets: configuration.apiKey.map { [$0] } ?? [],
            workspaceRoot: workspace,
            create: configuration.mode == .record
        )
        let transport = VCRProviderTransport(mode: configuration.mode, timing: configuration.timing, cassette: cassette, upstream: configuration.upstream)
        let assembly = providerAssembly(configuration: configuration, transport: transport)
        let first = try CoreHost(providerAssembly: assembly, workspaceRoot: try WorkspaceRoot(path: workspace.path), dataRoot: dataRoot, permissionDecision: .allow, mcpPager: pager, interactive: true)
        activeHost = first
        await first.start()
        let firstClient = LingXiClient.inProcess(endpoint: first)
        let capture = FullStackEventCapture()
        let eventStream = await firstClient.events()
        let eventTask = Task {
            for await event in eventStream {
                await capture.append(event)
                await trace.observe(event)
            }
        }
        let questionTask = await VCRQuestionClient(mode: configuration.mode, cassette: cassette, selectedOptionIndices: [0], onAnswered: { await trace.emit("question.answered") }).run(firstClient)
        defer { eventTask.cancel(); questionTask.cancel() }

        let root = try await firstClient.createSession()
        let skillAnswer = try await tracedSend(firstClient, root, stage: "provider.main.request", trace: trace, prompt: "Call the skill tool with name fixture-analysis. Then use read_file on Fixtures/Foo.swift and grep for BarAnchor-729 under Fixtures. Also use symbol_lookup for Foo. Report the two anchors.")
        guard skillAnswer.contains("FooAnchor-729"), skillAnswer.contains("BarAnchor-729") else {
            print("VCR skillAnswer diagnostic: \(skillAnswer.prefix(600))")
            throw CassetteMismatch(message: "builtin or skill anchor missing")
        }

        let mcpAnswer = try await tracedSend(firstClient, root, stage: "provider.main.request", trace: trace, prompt: "Use search_tools with query full-core-stack-v1. Take the tool_id field from the first JSON result, call load_tool with tool_id set to that exact value, then call the provider_name tool reported by load_tool with arguments {\"key\": \"full-core-stack-v1\"}. Report the exact anchor text the tool returned.")
        guard mcpAnswer.contains("MCPAnchor-729") else { throw CassetteMismatch(message: "local MCP fixture anchor missing") }
        guard mcpServer.callCount(toolName: "lookup_anchor", key: "full-core-stack-v1") == 1 else { throw CassetteMismatch(message: "local MCP fixture tool was not called exactly once") }

        _ = try await tracedSend(firstClient, root, stage: "provider.main.request", trace: trace, prompt: #"Call the subagent tool exactly twice in one step using only these arguments: {"action":"spawn","task":"Read Fixtures/Foo.swift, ask the user 'Continue Foo?' with options Continue and Stop, then report FooAnchor-729 after the answer.","title":"Child Foo"} and {"action":"spawn","task":"Read Fixtures/Bar.swift and report BarAnchor-729.","title":"Child Bar"}. Do not add provider_id, model_id, reasoning, content, run_id, session_id, or any other fields. Do not inspect files yourself."#)
        let tree = try await waitForChildren(firstClient, root: root)
        for child in tree.children {
            let run = child.latestRun
            print("VCR child diagnostics: title=\(child.session.title ?? "-") status=\(run?.status.rawValue ?? "none") error=\(run?.error.map { String(describing: $0) } ?? "none")")
        }
        guard tree.children.count == 2 else { throw CassetteMismatch(message: "expected two child sessions") }
        guard tree.children.allSatisfy({ $0.latestRun?.status == .completed }) else { throw CassetteMismatch(message: "subagent did not complete") }
        let childRunIDs = tree.children.compactMap { $0.latestRun?.runID.rawValue }.sorted()
        guard childRunIDs.count == 2 else { throw CassetteMismatch(message: "expected two child runs") }
        let capturedEvents = await capture.snapshot()
        let questionEvents = capturedEvents.compactMap { if case let .questionEscalated(req) = $0 { req } else { nil } }
        guard let questionReq = questionEvents.first else { throw CassetteMismatch(message: "questionEscalated event missing") }
        guard questionReq.originSessionID != questionReq.rootSessionID else { throw CassetteMismatch(message: "questionEscalated originSessionID equals rootSessionID") }
        guard questionReq.rootSessionID == root else { throw CassetteMismatch(message: "questionEscalated rootSessionID does not match root") }
        guard let originSessionID = questionReq.originSessionID else { throw CassetteMismatch(message: "questionEscalated missing originSessionID") }

        let originChildSession = try await firstClient.session(originSessionID)
        let childToolCalls = originChildSession.messages.flatMap(\.parts).compactMap { if case let .toolCall(call) = $0 { call } else { nil } }
        let childToolResults = originChildSession.messages.flatMap(\.parts).compactMap { if case let .toolResult(result) = $0 { result } else { nil } }
        let questionCalls = childToolCalls.filter { $0.toolID == ToolID("question") }
        guard let questionCall = questionCalls.first else { throw CassetteMismatch(message: "origin child session missing question toolCall") }
        let questionResults = childToolResults.filter { $0.callID == questionCall.callID }
        guard let questionResult = questionResults.first else { throw CassetteMismatch(message: "origin child session missing question toolResult matching callID") }
        guard questionResult.toolName == "question" else { throw CassetteMismatch(message: "origin child question toolResult missing toolName") }

        let childQuestionCallIDs = Set(questionCalls.map(\.callID))
        let rootBeforeResults = try await firstClient.session(root)
        let rootToolCalls = rootBeforeResults.messages.flatMap(\.parts).compactMap { if case let .toolCall(call) = $0 { call } else { nil } }
        let rootToolResults = rootBeforeResults.messages.flatMap(\.parts).compactMap { if case let .toolResult(result) = $0 { result } else { nil } }
        guard !rootToolCalls.contains(where: { $0.toolID == ToolID("question") || childQuestionCallIDs.contains($0.callID) }) else { throw CassetteMismatch(message: "question toolCall leaked into root session") }
        guard !rootToolResults.contains(where: { $0.toolName == "question" || childQuestionCallIDs.contains($0.callID) }) else { throw CassetteMismatch(message: "question toolResult leaked into root session") }

        let final = try await tracedSend(firstClient, root, stage: "main.synthesis", trace: trace, prompt: "Use subagent action=result for both child runs spawned earlier. Then synthesize one concise result containing FooAnchor-729, BarAnchor-729, and MCPAnchor-729.")
        guard final.contains("FooAnchor-729"), final.contains("BarAnchor-729"), final.contains("MCPAnchor-729") else { throw CassetteMismatch(message: "main synthesis omitted an anchor") }
        _ = try await firstClient.compact(root)
        let canonical = try await firstClient.session(root)
        guard let projectID = await first.persistence?.projectID else { throw CassetteMismatch(message: "persistence project ID missing") }
        let events = try await waitForFullStackEvents(capture)
        eventTask.cancel()
        questionTask.cancel()
        await eventTask.value
        await questionTask.value
        await trace.emit("persistence.shutdown", session: "main")
        await first.shutdown()
        activeHost = nil

        let second = try CoreHost(providerAssembly: assembly, workspaceRoot: try WorkspaceRoot(path: workspace.path), dataRoot: dataRoot, permissionDecision: .allow, mcpPager: pager, interactive: true)
        activeHost = second
        await second.start()
        await trace.emit("persistence.restart", session: "main")
        let secondClient = LingXiClient.inProcess(endpoint: second)
        let restored = try await secondClient.session(root)
        guard restored == canonical else { throw CassetteMismatch(message: "restored session differs from canonical session") }
        guard await second.persistence?.projectID == projectID else { throw CassetteMismatch(message: "restored project ID differs") }
        let continued = try await tracedSend(secondClient, root, stage: "provider.main.request", trace: trace, prompt: "Without calling tools, state the three anchors established earlier.")
        guard continued.contains("FooAnchor-729"), continued.contains("BarAnchor-729"), continued.contains("MCPAnchor-729") else { throw CassetteMismatch(message: "restored session omitted an anchor") }
        await second.shutdown()
        activeHost = nil

        guard events.contains(where: { if case .questionEscalated = $0 { true } else { false } }) else { throw CassetteMismatch(message: "question escalation event missing") }
        guard events.filter({ if case .childSessionCreated = $0 { true } else { false } }).count == 2 else { throw CassetteMismatch(message: "child session events missing") }
        guard await pager.requestSchemaCounts(sessionID: root).contains(1) else { throw CassetteMismatch(message: "MCP schema lease was not presented") }
        if configuration.mode == .replay { try await cassette.assertFullyConsumed() }
        await trace.emit("cassette.sanitize")
        try await cassette.audit()
        await trace.emit(configuration.mode == .record ? "record.complete" : "replay.complete")
        } catch {
            await trace.failed(error)
            if let activeHost { await activeHost.shutdown() }
            throw error
        }
    }

    @Test func repositoryGoldenManifestIsCompleteAndSanitized() async throws {
        let manifestData = try Data(contentsOf: Self.defaultGoldenDirectory.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(VCRCassetteManifest.self, from: manifestData)
        #expect(manifest.cassetteVersion == 1)
        #expect(manifest.scenario == "full-core-stack-v1")
        #expect(!manifest.createdAt.isEmpty)
        #expect(!manifest.lingXiCommit.isEmpty)
        #expect(!manifest.lingXiVersion.isEmpty)
        #expect(!manifest.modelAlias.isEmpty)
        #expect(manifest.wire == ModelWireProtocol.responses)
        #expect(manifest.sanitizationVersion == 1)
        #expect(manifest.contextProfile.contextWindowTokens > (manifest.contextProfile.maxOutputTokens ?? 0))

        let cassette = try VCRCassetteStore(directory: Self.defaultGoldenDirectory, manifest: manifest, create: false)
        try await cassette.audit()
        let golden = try ["manifest.json", "provider.jsonl", "interactions.jsonl"].map { name in
            String(decoding: try Data(contentsOf: Self.defaultGoldenDirectory.appendingPathComponent(name)), as: UTF8.self)
        }.joined()
        for forbidden in ["authorization", "bearer ", "cookie", "lingxi_vcr_api_key", "lingxi_provider_api_key", "credentials.vault", "develop.env"] {
            #expect(!golden.localizedCaseInsensitiveContains(forbidden), "Golden cassette contains \(forbidden)")
        }
        #expect(!golden.contains(NSHomeDirectory()))
    }

    @Test func vcrCompositionUsesOnlyItsExplicitDataRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-vcr-isolation-\(UUID().uuidString)", isDirectory: true)
        let protectedRoot = root.appendingPathComponent("protected-production-root", isDirectory: true)
        let testDataRoot = root.appendingPathComponent("test-data-root", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: protectedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testDataRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let protectedFiles = ["providers.json", "config.json", "credentials.vault", "mcp.json"]
        for name in protectedFiles { try Data("sentinel-\(name)".utf8).write(to: protectedRoot.appendingPathComponent(name)) }
        let before = try Dictionary(uniqueKeysWithValues: protectedFiles.map { name in
            (name, try Data(contentsOf: protectedRoot.appendingPathComponent(name)))
        })

        let manifest = try JSONDecoder().decode(VCRCassetteManifest.self, from: Data(contentsOf: Self.defaultGoldenDirectory.appendingPathComponent("manifest.json")))
        let cassette = try VCRCassetteStore(directory: Self.defaultGoldenDirectory, manifest: manifest, workspaceRoot: workspace, create: false)
        let provider = OpenAIResponsesProvider(config: ProviderConfig(baseURL: URL(string: "https://offline.invalid/v1")!, authentication: .none, model: manifest.modelAlias, wireProtocol: manifest.wire), transport: VCRProviderTransport(mode: .replay, cassette: cassette))
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID(manifest.modelAlias), contextProfile: manifest.contextProfile), workspaceRoot: WorkspaceRoot(path: workspace.path), dataRoot: testDataRoot, permissionDecision: .allow)
        await host.start()
        await host.shutdown()

        for name in protectedFiles {
            #expect(try Data(contentsOf: protectedRoot.appendingPathComponent(name)) == before[name])
        }
        #expect(!FileManager.default.fileExists(atPath: protectedRoot.appendingPathComponent("vcr-model").path))
    }

    @Test func localMCPFixtureRunsRealPagingPath() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-vcr-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let server = try FixtureMCPHTTPServer()
        defer { server.stop() }
        let pager = try await mcpPager(server: server)
        let advertised = try await pager.searchToolResult(sessionID: SessionID("vcr-contract"), projectID: ProjectID("vcr-contract"), arguments: #"{"query":"full-core-stack-v1"}"#)
        #expect(advertised.contains(#""tool_id":"vcr-fixture::lookup_anchor""#))
        let blankFiltered = try await pager.searchToolResult(sessionID: SessionID("vcr-contract"), projectID: ProjectID("vcr-contract"), arguments: #"{"capability":"","max_results":8,"query":"full-core-stack-v1","server":""}"#)
        #expect(blankFiltered == advertised)
        let toolID = ToolID("vcr-fixture::lookup_anchor")
        let alias = ProviderToolNameCodec().encode(serverAlias: "vcrfixture", upstreamName: "lookup_anchor", toolID: toolID)
        let provider = ScriptedFakeProvider(script: [
            [.toolCallCompleted(ToolCall(callID: ToolCallID("search"), toolID: ToolID("search_tools"), arguments: #"{"query":"full-core-stack-v1"}"#)), .completed(.toolCalls)],
            [.toolCallCompleted(ToolCall(callID: ToolCallID("load"), toolID: ToolID("load_tool"), arguments: #"{"tool_id":"vcr-fixture::lookup_anchor"}"#)), .completed(.toolCalls)],
            [.toolCallCompleted(ToolCall(callID: ToolCallID("call"), toolID: ToolID(alias), arguments: #"{"key":"full-core-stack-v1"}"#)), .completed(.toolCalls)],
            [.textDelta("MCPAnchor-729"), .completed(.stop)],
        ])
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: workspace.path), permissionDecision: .allow, mcpPager: pager)
        await host.start()
        do {
        let client = LingXiClient.inProcess(endpoint: host)
        let session = try await client.createSession()
        let trace = VCRProgressTrace()
        let events = await client.events()
        let eventTask = Task { for await event in events { await trace.observe(event) } }
        defer { eventTask.cancel() }
        let answer = try await send(client, session, "exercise deterministic MCP fixture")
        let stages = try await waitForMCPProgress(trace)
        #expect(answer == "MCPAnchor-729")
        #expect(provider.recorder.requests.map { $0.tools.filter { $0.rawInputSchema != nil }.count } == [0, 0, 1, 0])
        #expect(await pager.leaseCount(sessionID: session) == 0)
            #expect(await pager.requestSchemaCounts(sessionID: session).contains(1))
            #expect(server.callCount(toolName: "lookup_anchor", key: "full-core-stack-v1") == 1)
        #expect(stages.contains("mcp.search.begin"))
        #expect(stages.contains("mcp.search.end"))
        #expect(stages.contains("mcp.load.begin"))
        #expect(stages.contains("mcp.load.end"))
        #expect(stages.contains("mcp.call.begin"))
        #expect(stages.contains("mcp.call.end"))
        #expect(await trace.stalledMessage(after: .zero)?.hasPrefix("VCR still running: currentStage=mcp.call.end, elapsed=") == true)
        #expect(await trace.failureLines(CoreError(code: .mcpServerUnavailable, message: "Bearer secret prompt")) == ["FAILED at stage=mcp.call.end", "blocker=CoreError.mcpServerUnavailable"])
        await host.shutdown()
        } catch {
            await host.shutdown()
            throw error
        }
    }

/// Offline diagnostic: reproduces the full-stack subagent conditions (dataRoot persistence,
/// interactive, dual event consumers, two concurrent child spawns) with a scripted provider.
@Test func offlineReproduceSubagentChildStartup() async throws {
    struct RoutedProvider: ModelProvider {
        let rootPrompt: String
        func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
            let firstUser = request.messages.first(where: { $0.role == .user })?.content
            let events: [ModelEvent]
            if firstUser == "child-foo" { events = [.textDelta("FooAnchor-729"), .completed(.stop)] }
            else if firstUser == "child-bar" { events = [.textDelta("BarAnchor-729"), .completed(.stop)] }
            else if request.messages.contains(where: { $0.role == .tool }) { events = [.textDelta("children spawned"), .completed(.stop)] }
            else {
                let foo = ToolCall(callID: ToolCallID("spawn-foo"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"child-foo","title":"Foo"}"#)
                let bar = ToolCall(callID: ToolCallID("spawn-bar"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"child-bar","title":"Bar"}"#)
                events = [.toolCallCompleted(foo), .toolCallCompleted(bar), .completed(.toolCalls)]
            }
            return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
                for event in events { _ = continuation.yield(event) }
                continuation.finish()
            }
        }
    }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-repro-\(UUID().uuidString)", isDirectory: true)
    let workspace = base.appendingPathComponent("workspace", isDirectory: true)
    let dataRoot = base.appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: RoutedProvider(rootPrompt: "spawn two"), modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: workspace.path), dataRoot: dataRoot, permissionDecision: .allow, interactive: true)
    await host.start()
    do {
        let client = LingXiClient.inProcess(endpoint: host)
        let events = await client.events()
        var consumed = 0
        let eventTask = Task { for await _ in events { consumed += 1 } }
        defer { eventTask.cancel() }
        let root = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: root, content: "spawn two")
        var text = ""
        for try await chunk in stream where chunk.kind == .text { text += chunk.text }
        let deadline = ContinuousClock.now + .seconds(15)
        var tree = try await client.getAgentTree(root)
        while (tree.children.count < 2 || tree.children.contains { $0.latestRun?.status != .completed }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            tree = try await client.getAgentTree(root)
        }
        for child in tree.children {
            print("repro child title=\(child.session.title ?? "-") run=\(child.latestRun?.status.rawValue ?? "none") error=\(child.latestRun?.error?.message ?? "-")")
        }
        #expect(tree.children.count == 2)
        #expect(tree.children.allSatisfy { $0.latestRun?.status == .completed })
        await host.shutdown()
    } catch {
        await host.shutdown()
        throw error
    }
}

/// Offline diagnostic: record→replay the same subagent spawn flow through the real provider
/// wire against a loopback fixture, then compare the streamed text of both phases.
@Test func offlineReproduceSubagentWithRealTransport() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-repro2-\(UUID().uuidString)", isDirectory: true)
    let workspace = base.appendingPathComponent("workspace", isDirectory: true)
    let dataRoot = base.appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let fixture = try FixtureProviderHTTPServer()
    defer { fixture.stop() }
    let staging = base.appendingPathComponent("staging", isDirectory: true)
    let manifest = VCRCassetteManifest(wire: .responses, modelAlias: "fixture-model", scenario: "offline-repro", lingXiCommit: "test")
    let recordStore = try VCRCassetteStore(directory: staging, manifest: manifest, forbiddenSecrets: [], workspaceRoot: workspace, create: true)
    let config = ProviderConfig(baseURL: fixture.endpoint, authentication: .none, model: "fixture-model", wireProtocol: .responses)

    func runPhase(_ transport: any ProviderHTTPTransport, dataDirectory: URL, phase: String) async throws -> String {
        let provider = OpenAIResponsesProvider(config: config, transport: transport)
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fixture-model")), workspaceRoot: try WorkspaceRoot(path: workspace.path), dataRoot: dataDirectory, permissionDecision: .allow, interactive: true)
        await host.start()
        do {
            let client = LingXiClient.inProcess(endpoint: host)
            let session = try await client.createSession()
            let stream = try await client.sendMessage(sessionID: session, content: "spawn two")
            var text = ""
            for try await chunk in stream where chunk.kind == .text { text += chunk.text }
            let deadline = ContinuousClock.now + .seconds(20)
            var tree = try await client.getAgentTree(session)
            while (tree.children.count < 2 || tree.children.contains { $0.latestRun?.status != .completed }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                tree = try await client.getAgentTree(session)
            }
            for child in tree.children {
                print("repro3 \(phase) child title=\(child.session.title ?? "-") run=\(child.latestRun?.status.rawValue ?? "none") error=\(child.latestRun?.error?.message ?? "-")")
            }
            await host.shutdown()
            return text
        } catch {
            await host.shutdown()
            throw error
        }
    }

    let recordData = dataRoot.appendingPathComponent("record", isDirectory: true)
    try FileManager.default.createDirectory(at: recordData, withIntermediateDirectories: true)
    let recordedText = try await runPhase(VCRProviderTransport(mode: .record, cassette: recordStore, upstream: URLSessionProviderHTTPTransport()), dataDirectory: recordData, phase: "record")
    print("repro3 record root text: \(recordedText.prefix(120))")

    let replayData = dataRoot.appendingPathComponent("replay", isDirectory: true)
    try FileManager.default.createDirectory(at: replayData, withIntermediateDirectories: true)
    let replayStore = try VCRCassetteStore(directory: staging, manifest: manifest, forbiddenSecrets: [], workspaceRoot: workspace, create: false)
    let replayedText = try await runPhase(VCRProviderTransport(mode: .replay, timing: .instant, cassette: replayStore, upstream: nil), dataDirectory: replayData, phase: "replay")
    print("repro3 replay root text: \(replayedText.prefix(120))")

    #expect(recordedText == "fixture-ok")
    #expect(replayedText == "fixture-ok")
}

/// Offline diagnostic: feeds the recorded seq3 SSE frames through the exact Pump decoder path.
@Test func offlineReplayDecoderDiagnostic() async throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Cassettes/Scenarios/full-core-stack-v1", isDirectory: true)
    let rows = try String(decoding: Data(contentsOf: directory.appendingPathComponent("provider.jsonl")), as: UTF8.self)
        .split(separator: "\n")
        .map { try JSONDecoder().decode(VCRWireExchange.self, from: Data($0.utf8)) }
    let seq3 = try #require(rows.first { $0.sequence == 3 })
    var lines = SSEDecoder()
    var decoder = ResponsesSSEDecoder()
    var events: [String] = []
    for chunk in seq3.chunks {
        for line in lines.feed(Data(chunk.data.utf8)) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            for event in try decoder.consume(payload) { events.append(String(describing: event)) }
        }
    }
    print("replay decoder events: \(events.count)")
    for event in events.prefix(14) { print("  \(event.prefix(140))") }
    #expect(events.contains { $0.hasPrefix("textDelta") })
    #expect(events.contains { $0.hasPrefix("completed") })
}

    struct Configuration {
        let mode: VCRMode
        let timing: VCRReplayTiming
        let cassetteDirectory: URL
        let manifest: VCRCassetteManifest
        let baseURL: URL
        let apiKey: String?
        let model: String
        let upstream: (any ProviderHTTPTransport)?
        let cassetteSource: String
    }

    static let defaultGoldenDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Cassettes/Scenarios/full-core-stack-v1", isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()

    static let defaultRepositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .standardizedFileURL
        .resolvingSymlinksInPath()

    static func resolveConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        goldenDirectory: URL? = nil,
        repositoryRoot: URL? = nil
    ) throws -> Configuration {
        let repoRoot = (repositoryRoot ?? defaultRepositoryRoot).standardizedFileURL.resolvingSymlinksInPath()
        let goldenDir = (goldenDirectory ?? defaultGoldenDirectory).standardizedFileURL.resolvingSymlinksInPath()

        let modeValue = environment["LINGXI_VCR_MODE"]
        if let modeValue, VCRMode(rawValue: modeValue) == nil {
            throw CassetteMismatch(message: "invalid LINGXI_VCR_MODE")
        }
        let explicitMode = modeValue.flatMap(VCRMode.init(rawValue:))
        let timing = environment["LINGXI_VCR_TIMING"].flatMap(VCRReplayTiming.init(rawValue:)) ?? .instant

        let explicitCassettePath = environment["LINGXI_VCR_CASSETTE_DIR"]
        let explicitCassetteDir = explicitCassettePath.flatMap { path -> URL? in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        }

        let effectiveMode: VCRMode
        if let explicitMode {
            effectiveMode = explicitMode
        } else {
            effectiveMode = .replay
        }

        if effectiveMode == .replay {
            let targetDirectory = explicitCassetteDir ?? goldenDir
            let manifestFile = targetDirectory.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestFile.path) else {
                throw CassetteMismatch(message: "manifest.json missing from replay cassette directory: \(targetDirectory.path)")
            }

            let isInsideRepo = targetDirectory.path == repoRoot.path || targetDirectory.path.hasPrefix(repoRoot.path + "/")
            let isGolden = targetDirectory.path == goldenDir.path
            let cassetteSource = (isGolden || isInsideRepo) ? "repository" : "staging"

            let manifestData = try Data(contentsOf: manifestFile)
            let manifest = try JSONDecoder().decode(VCRCassetteManifest.self, from: manifestData)
            guard let maxOutputTokens = manifest.contextProfile.maxOutputTokens,
                  let outputReserveTokens = manifest.contextProfile.recommendedOutputReserveTokens
            else {
                throw CassetteMismatch(message: "manifest contextProfile requires output limits")
            }

            print("VCR replay starting: cassetteSource=\(cassetteSource) scenario=\(manifest.scenario) createdAt=\(manifest.createdAt) lingXiCommit=\(manifest.lingXiCommit) modelAlias=\(manifest.modelAlias) wire=\(manifest.wire.rawValue) contextProfile=\(manifest.contextProfile.contextWindowTokens)/\(maxOutputTokens)/\(outputReserveTokens)")

            return Configuration(
                mode: .replay,
                timing: timing,
                cassetteDirectory: targetDirectory,
                manifest: manifest,
                baseURL: URL(string: "https://offline.invalid/v1")!,
                apiKey: nil,
                model: manifest.modelAlias,
                upstream: nil,
                cassetteSource: cassetteSource
            )
        }

        guard let base = environment["LINGXI_VCR_BASE_URL"].flatMap(URL.init(string:)),
              let model = environment["LINGXI_VCR_MODEL"], !model.isEmpty,
              let wire = environment["LINGXI_VCR_WIRE_PROTOCOL"].flatMap(ModelWireProtocol.init(rawValue:))
        else {
            throw CassetteMismatch(message: "record requires test Base URL, Model, and WireProtocol")
        }

        let output: URL
        if effectiveMode == .record {
            guard let value = environment["LINGXI_VCR_OUTPUT"], !value.isEmpty else {
                throw CassetteMismatch(message: "record requires an explicit empty staging directory")
            }
            output = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            guard output.path != repoRoot.path, !output.path.hasPrefix(repoRoot.path + "/") else {
                throw CassetteMismatch(message: "record staging directory must be outside the repository")
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else {
                    throw CassetteMismatch(message: "record staging path must be a directory")
                }
                guard try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty else {
                    throw CassetteMismatch(message: "record staging directory must be empty")
                }
            }
        } else {
            output = explicitCassetteDir ?? goldenDir
        }

        let isInsideRepo = output.path == repoRoot.path || output.path.hasPrefix(repoRoot.path + "/")
        let isGolden = output.path == goldenDir.path
        let cassetteSource = (isGolden || isInsideRepo) ? "repository" : "staging"

        let manifest = VCRCassetteManifest(
            wire: wire,
            modelAlias: "vcr-model",
            scenario: "full-core-stack-v1",
            lingXiCommit: environment["LINGXI_VCR_COMMIT"] ?? "unknown",
            contextProfile: ModelContextProfile(contextWindowTokens: 128_000, maxOutputTokens: 4_096, recommendedOutputReserveTokens: 4_096, source: "vcr-manifest")
        )
        return Configuration(
            mode: effectiveMode,
            timing: timing,
            cassetteDirectory: output,
            manifest: manifest,
            baseURL: base,
            apiKey: environment["LINGXI_VCR_API_KEY"],
            model: model,
            upstream: URLSessionProviderHTTPTransport(),
            cassetteSource: cassetteSource
        )
    }

    @Test func stagingCassetteContractRecordAndReplayIsolatesFromRepositoryGolden() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcr-test-root-\(UUID().uuidString)", isDirectory: true)
        let mockRepoRoot = root.appendingPathComponent("mock-repo", isDirectory: true)
        let goldenStaleDir = mockRepoRoot.appendingPathComponent("Tests/LingXiAgentTests/VCR/Cassettes/Scenarios/full-core-stack-v1", isDirectory: true)
        let stagingADir = root.appendingPathComponent("staging-a", isDirectory: true)

        try FileManager.default.createDirectory(at: goldenStaleDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingADir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func makeRecordRequest() -> URLRequest {
            var req = URLRequest(url: URL(string: "https://offline.invalid/v1/responses")!)
            req.httpBody = Data("{\"model\":\"actual-model\",\"input\":[{\"type\":\"message\",\"role\":\"user\",\"content\":\"hello\"}]}".utf8)
            return req
        }
        func makeReplayRequest() -> URLRequest {
            var req = URLRequest(url: URL(string: "https://offline.invalid/v1/responses")!)
            req.httpBody = Data("{\"model\":\"vcr-model\",\"input\":[{\"type\":\"message\",\"role\":\"user\",\"content\":\"hello\"}]}".utf8)
            return req
        }

        // Setup Stale B in Golden Repo
        let manifestB = VCRCassetteManifest(wire: .responses, modelAlias: "vcr-model", scenario: "full-core-stack-v1", lingXiCommit: "commit-B-stale", createdAt: "2026-08-30T00:00:00Z")
        try JSONEncoder().encode(manifestB).write(to: goldenStaleDir.appendingPathComponent("manifest.json"))
        let staleStore = try VCRCassetteStore(directory: goldenStaleDir, manifest: manifestB, workspaceRoot: root, create: true)
        let stalePrepared = try await staleStore.prepareRecording(
            makeRecordRequest(),
            context: ProviderHTTPRequestContext(wireProtocol: .responses, model: "actual-model", executionID: nil, step: 1)
        )
        try await staleStore.record(
            prepared: stalePrepared,
            context: ProviderHTTPRequestContext(wireProtocol: .responses, model: "actual-model", executionID: nil, step: 1),
            status: 200,
            responseHeaders: ["Content-Type": "application/json"],
            chunks: [VCRWireChunk(index: 0, offsetMilliseconds: 0, data: "{\"result\":\"stale-B\"}")],
            terminalOffsetMilliseconds: 0,
            termination: .completed
        )

        // 1. Record Staging A
        let recordEnv = [
            "LINGXI_VCR_MODE": "record",
            "LINGXI_VCR_BASE_URL": "https://api.openai.com/v1",
            "LINGXI_VCR_MODEL": "actual-model",
            "LINGXI_VCR_WIRE_PROTOCOL": "responses",
            "LINGXI_VCR_OUTPUT": stagingADir.path,
            "LINGXI_VCR_COMMIT": "commit-A-fresh"
        ]
        let recordConfig = try Self.resolveConfiguration(environment: recordEnv, goldenDirectory: goldenStaleDir, repositoryRoot: mockRepoRoot)
        #expect(recordConfig.cassetteSource == "staging")
        #expect(recordConfig.cassetteDirectory.path == stagingADir.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(recordConfig.mode == .record)

        let storeA = try VCRCassetteStore(directory: recordConfig.cassetteDirectory, manifest: recordConfig.manifest, workspaceRoot: root, create: true)
        let preparedA = try await storeA.prepareRecording(
            makeRecordRequest(),
            context: ProviderHTTPRequestContext(wireProtocol: .responses, model: "actual-model", executionID: nil, step: 1)
        )
        try await storeA.record(
            prepared: preparedA,
            context: ProviderHTTPRequestContext(wireProtocol: .responses, model: "actual-model", executionID: nil, step: 1),
            status: 200,
            responseHeaders: ["Content-Type": "application/json"],
            chunks: [VCRWireChunk(index: 0, offsetMilliseconds: 0, data: "{\"result\":\"staging-A-fresh\"}")],
            terminalOffsetMilliseconds: 0,
            termination: .completed
        )

        // 2. Replay Staging A using LINGXI_VCR_CASSETTE_DIR
        let replayDirEnv = [
            "LINGXI_VCR_MODE": "replay",
            "LINGXI_VCR_CASSETTE_DIR": stagingADir.path
        ]
        let replayDirConfig = try Self.resolveConfiguration(environment: replayDirEnv, goldenDirectory: goldenStaleDir, repositoryRoot: mockRepoRoot)
        #expect(replayDirConfig.cassetteSource == "staging")
        #expect(replayDirConfig.cassetteDirectory.path == stagingADir.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(replayDirConfig.manifest.lingXiCommit == "commit-A-fresh")
        #expect(replayDirConfig.manifest.contextProfile == recordConfig.manifest.contextProfile)

        let replayStoreA = try VCRCassetteStore(directory: replayDirConfig.cassetteDirectory, manifest: replayDirConfig.manifest, workspaceRoot: root, create: false)
        let exchangeA = try await replayStoreA.replay(
            makeReplayRequest(),
            context: ProviderHTTPRequestContext(wireProtocol: .responses, model: "vcr-model", executionID: nil, step: 1)
        )
        #expect(exchangeA.chunks.first?.data.contains("staging-A-fresh") == true)
        #expect(exchangeA.chunks.first?.data.contains("stale-B") == false)

        // 3. LINGXI_VCR_OUTPUT is record-only and cannot select a replay source.
        let replayOutputEnv = [
            "LINGXI_VCR_MODE": "replay",
            "LINGXI_VCR_OUTPUT": stagingADir.path
        ]
        let replayOutputConfig = try Self.resolveConfiguration(environment: replayOutputEnv, goldenDirectory: goldenStaleDir, repositoryRoot: mockRepoRoot)
        #expect(replayOutputConfig.cassetteSource == "repository")
        #expect(replayOutputConfig.cassetteDirectory.path == goldenStaleDir.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(replayOutputConfig.manifest.lingXiCommit == "commit-B-stale")

        // 4. Replay without an explicit directory reads repository Golden B.
        let defaultReplayEnv = [
            "LINGXI_VCR_MODE": "replay"
        ]
        let defaultReplayConfig = try Self.resolveConfiguration(environment: defaultReplayEnv, goldenDirectory: goldenStaleDir, repositoryRoot: mockRepoRoot)
        #expect(defaultReplayConfig.cassetteSource == "repository")
        #expect(defaultReplayConfig.cassetteDirectory.path == goldenStaleDir.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(defaultReplayConfig.manifest.lingXiCommit == "commit-B-stale")

        let replayStoreB = try VCRCassetteStore(directory: defaultReplayConfig.cassetteDirectory, manifest: defaultReplayConfig.manifest, workspaceRoot: root, create: false)
        let exchangeB = try await replayStoreB.replay(
            makeReplayRequest(),
            context: ProviderHTTPRequestContext(wireProtocol: .responses, model: "vcr-model", executionID: nil, step: 1)
        )
        #expect(exchangeB.chunks.first?.data.contains("stale-B") == true)
        #expect(exchangeB.chunks.first?.data.contains("staging-A-fresh") == false)

        // 5. Record guards: inside repo or non-empty directory must be rejected
        let insideRepoRecordEnv = [
            "LINGXI_VCR_MODE": "record",
            "LINGXI_VCR_BASE_URL": "https://api.openai.com/v1",
            "LINGXI_VCR_MODEL": "actual-model",
            "LINGXI_VCR_WIRE_PROTOCOL": "responses",
            "LINGXI_VCR_OUTPUT": goldenStaleDir.path
        ]
        #expect(throws: CassetteMismatch.self) {
            _ = try Self.resolveConfiguration(environment: insideRepoRecordEnv, goldenDirectory: goldenStaleDir, repositoryRoot: mockRepoRoot)
        }

        let nonEmptyRecordEnv = [
            "LINGXI_VCR_MODE": "record",
            "LINGXI_VCR_BASE_URL": "https://api.openai.com/v1",
            "LINGXI_VCR_MODEL": "actual-model",
            "LINGXI_VCR_WIRE_PROTOCOL": "responses",
            "LINGXI_VCR_OUTPUT": stagingADir.path
        ]
        #expect(throws: CassetteMismatch.self) {
            _ = try Self.resolveConfiguration(environment: nonEmptyRecordEnv, goldenDirectory: goldenStaleDir, repositoryRoot: mockRepoRoot)
        }
    }

    private func providerAssembly(configuration: Configuration, transport: any ProviderHTTPTransport) -> ModelRuntimeAssembly {
        let authentication: ProviderAuthentication = configuration.apiKey.map {
            configuration.manifest.wire == .anthropicMessages ? .header(name: "x-api-key", value: $0) : .bearer($0)
        } ?? .none
        let config = ProviderConfig(baseURL: configuration.baseURL, authentication: authentication, model: configuration.model, wireProtocol: configuration.manifest.wire)
        let provider: any ModelProvider
        switch configuration.manifest.wire {
        case .chatCompletions: provider = OpenAICompatibleProvider(config: config, transport: transport)
        case .responses: provider = OpenAIResponsesProvider(config: config, transport: transport)
        case .anthropicMessages: provider = AnthropicMessagesProvider(config: config, transport: transport)
        }
        return ModelRuntimeAssembly(
            provider: provider,
            modelID: ModelID(configuration.model),
            endpoint: ResolvedModelEndpoint(
                providerID: "vcr",
                modelID: ModelID(configuration.model),
                baseURL: configuration.baseURL,
                wireProtocol: configuration.manifest.wire,
                contextProfile: configuration.manifest.contextProfile
            )
        )
    }

    private func installWorkspaceFixture(at root: URL) throws {
        let fixtures = root.appendingPathComponent("Fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try "public struct Foo { public let marker = \"FooAnchor-729\" }\n".write(to: fixtures.appendingPathComponent("Foo.swift"), atomically: true, encoding: .utf8)
        try "public struct Bar { public let marker = \"BarAnchor-729\" }\n".write(to: fixtures.appendingPathComponent("Bar.swift"), atomically: true, encoding: .utf8)
        let skillTarget = root.appendingPathComponent(".lingxi/skills/fixture-analysis", isDirectory: true)
        try FileManager.default.createDirectory(at: skillTarget, withIntermediateDirectories: true)
        let skillSource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Skills/fixture-analysis/SKILL.md")
        try FileManager.default.copyItem(at: skillSource, to: skillTarget.appendingPathComponent("SKILL.md"))
    }

    private func mcpPager(server: FixtureMCPHTTPServer) async throws -> MCPToolPager {
        let serverID = MCPServerID("vcr-fixture")
        let transport = MCPStreamableHTTPTransport(configuration: MCPServerConfiguration(serverID: serverID, alias: "vcrfixture", transport: .streamableHTTP, endpoint: server.endpoint, timeoutSeconds: 10))
        let connections = MCPConnectionManager()
        await connections.register(transport, for: serverID)
        let pager = MCPToolPager(invoker: connections)
        try await pager.replaceCatalog(serverID: serverID, tools: try await transport.listTools())
        return pager
    }

    private func tracedSend(_ client: LingXiClient, _ sessionID: SessionID, stage: String, trace: VCRProgressTrace, prompt: String) async throws -> String {
        await trace.emit("\(stage).begin", session: "main")
        let result = try await send(client, sessionID, prompt)
        await trace.emit("\(stage).end", session: "main")
        return result
    }

    private func send(_ client: LingXiClient, _ sessionID: SessionID, _ prompt: String) async throws -> String {
        let stream = try await client.sendMessage(sessionID: sessionID, content: prompt)
        var text = ""
        for try await chunk in stream where chunk.kind == .text { text += chunk.text }
        return text
    }

    private func waitForChildren(_ client: LingXiClient, root: SessionID) async throws -> AgentTreeNode {
        let deadline = ContinuousClock.now + .seconds(120)
        var tree = try await client.getAgentTree(root)
        while (tree.children.count < 2 || tree.children.contains { $0.latestRun?.status != .completed }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            tree = try await client.getAgentTree(root)
        }
        return tree
    }

    private func waitForFullStackEvents(_ capture: FullStackEventCapture) async throws -> [CoreEvent] {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let events = await capture.snapshot()
            let hasQuestion = events.contains { if case .questionEscalated = $0 { true } else { false } }
            let childCount = events.filter { if case .childSessionCreated = $0 { true } else { false } }.count
            let completedCount = events.filter { if case .agentRunCompleted = $0 { true } else { false } }.count
            if hasQuestion, childCount == 2, completedCount >= 2 { return events }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CassetteMismatch(message: "full-stack events did not drain")
    }

    private func waitForMCPProgress(_ trace: VCRProgressTrace) async throws -> [String] {
        let required = Set(["mcp.search.begin", "mcp.search.end", "mcp.load.begin", "mcp.load.end", "mcp.call.begin", "mcp.call.end"])
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let stages = await trace.stageSnapshot()
            if required.isSubset(of: Set(stages)) { return stages }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CassetteMismatch(message: "MCP progress events did not drain")
    }
}
