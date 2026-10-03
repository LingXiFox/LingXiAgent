import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiPlatform
import LingXiClient

/// Follow-ups from the first real LM Studio smoke test.
@Suite("Local runtime follow-ups", .serialized)
struct LocalRuntimeFollowupTests {

    private func tempDir(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - LM Studio from the catalog becomes an editable local-runtime entry

    @Test("connecting the LM Studio catalog entry writes a providers.json local runtime, key optional")
    func catalogConnectWritesLocalRuntime() async throws {
        let root = try tempDir("lx-lms-connect")
        let workspace = try tempDir("lx-lms-ws")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: workspace) }
        let host = try CoreHost(startupPolicy: .integrationTest, workspaceRoot: try WorkspaceRoot(path: workspace.path),
                                dataRoot: root, interactive: false, credentialStore: EphemeralCredentialStore())
        await host.start()
        let client = try await LingXiClientVNext.inProcess(service: host)

        // What an earlier build wrote: the catalog id itself, no models, no runtime marker.
        try #"{"version":1,"providers":{"lm-studio-local":{"name":"LM Studio","adapter":"openai-compatible","options":{"baseURL":"http://10.0.0.128:1234/v1","headers":{}},"models":{}}}}"#
            .write(to: root.appendingPathComponent("providers.json"), atomically: true, encoding: .utf8)
        // Models passed explicitly so the test needs no server; no key, as with an open LM Studio.
        let info = try await client.provider.connect(ConnectProviderRequest(
            productID: "lm-studio-local", endpoint: "http://10.0.0.128:1234",
            modelIDs: ["qwen3.8-9b-q6k"]))
        #expect(info.id == "lmstudio")

        let stored = try String(contentsOf: root.appendingPathComponent("providers.json"), encoding: .utf8)
        let config = try JSONDecoder().decode(ProvidersConfiguration.self, from: Data(stored.utf8))
        let entry = try #require(config.providers["lmstudio"])
        #expect(entry.options.localRuntime?.backend == .lmStudio)
        #expect(entry.options.baseURL == "http://10.0.0.128:1234/v1", "裸服务器地址应规范化为 API 根")
        #expect(entry.options.apiKey == nil)
        #expect(entry.models.keys.contains("qwen3.8-9b-q6k"))
        #expect(config.providers["lm-studio-local"] == nil, "旧的同名只读条目应被替换，不留双胞胎")

        // Reconnecting the same server updates the entry instead of adding a twin.
        let again = try await client.provider.connect(ConnectProviderRequest(
            productID: "lm-studio-local", endpoint: "http://10.0.0.128:1234/v1/", modelIDs: ["other-model"]))
        #expect(again.id == "lmstudio")
        let reloaded = try JSONDecoder().decode(ProvidersConfiguration.self,
                                                from: Data(contentsOf: root.appendingPathComponent("providers.json")))
        #expect(reloaded.providers.keys.filter { $0.hasPrefix("lmstudio") }.count == 1)
        await host.shutdown()
    }

    @Test("an LM Studio entry left by an earlier build is repaired on start without reconnecting")
    func legacyEntryMigratesOnStart() async throws {
        let root = try tempDir("lx-lms-migrate")
        let workspace = try tempDir("lx-lms-migrate-ws")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: workspace) }
        // Exactly what the earlier build wrote. Port 9 is closed, so the start-up attempt fails fast.
        try #"{"version":1,"providers":{"lm-studio-local":{"name":"LM Studio","adapter":"openai-compatible","options":{"baseURL":"http://127.0.0.1:9/v1","headers":{}},"models":{}}}}"#
            .write(to: root.appendingPathComponent("providers.json"), atomically: true, encoding: .utf8)
        let host = try CoreHost(startupPolicy: .integrationTest, workspaceRoot: try WorkspaceRoot(path: workspace.path),
                                dataRoot: root, interactive: false, credentialStore: EphemeralCredentialStore())
        await host.start()

        // Unreachable: nothing valid to write, so the entry is left for the next start.
        let offline: LMStudioDiscovery.HTTPClient = { _ in throw URLError(.cannotConnectToHost) }
        #expect(await host.migrateLegacyLMStudioEntry(httpClient: offline) == nil)

        let server: LMStudioDiscovery.HTTPClient = { request in
            let body = request.url?.path == "/api/v1/models" ? LMStudioRuntimeTests.nativeJSON : ""
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: body.isEmpty ? 404 : 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await host.migrateLegacyLMStudioEntry(httpClient: server) == "lmstudio")
        let config = try JSONDecoder().decode(ProvidersConfiguration.self,
                                              from: Data(contentsOf: root.appendingPathComponent("providers.json")))
        #expect(config.providers["lm-studio-local"] == nil)
        let entry = try #require(config.providers["lmstudio"])
        #expect(entry.options.localRuntime?.backend == .lmStudio)
        #expect(Array(entry.models.keys) == ["qwen3.8-9b-q6k"])
        #expect(config.model == "lmstudio/qwen3.8-9b-q6k", "没有默认模型时应选中发现的模型，消除 defaultSelection 缺失")
        #expect(await host.migrateLegacyLMStudioEntry(httpClient: server) == nil, "迁移只做一次")
        await host.shutdown()
    }

    @Test("the model list offers chat models by the id requests use, and drops embeddings")
    func chatModelListing() async throws {
        let client: LMStudioDiscovery.HTTPClient = { request in
            let body = request.url?.path == "/api/v1/models" ? LMStudioRuntimeTests.nativeJSON : ""
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: body.isEmpty ? 404 : 200, httpVersion: nil, headerFields: nil)!)
        }
        let models = await LMStudioDiscovery.listChatModels(baseURL: "http://10.0.0.128:1234/v1", httpClient: client)
        #expect(models == ["qwen3.8-9b-q6k"], "已加载的模型用实例 id，嵌入模型不得出现")

        let offline: LMStudioDiscovery.HTTPClient = { _ in throw URLError(.cannotConnectToHost) }
        #expect(await LMStudioDiscovery.listChatModels(baseURL: "http://10.0.0.128:1234/v1", httpClient: offline) == nil,
                "连不上必须是 nil，不能是空列表")
    }

    // MARK: - An answer written only into reasoning

    private func runTurn(_ script: [[ModelEvent]]) async throws -> (String?, ScriptedFakeProvider) {
        let root = try tempDir("lx-promote")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFakeProvider(script: script)
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")),
                                workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow, interactive: false)
        await host.start()
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: sessionID, content: "go") {}
        return (try await client.session(sessionID).messages.last(where: { $0.role == .assistant })?.content, provider)
    }

    @Test("a final step that answers only in reasoning delivers that answer")
    func reasoningOnlyAnswerIsPromoted() async throws {
        let (answer, _) = try await runTurn([[.reasoningDelta("编译器都因 Xcode 许可未接受而失败。"), .completed(.stop)]])
        #expect(answer == "编译器都因 Xcode 许可未接受而失败。", "最终回复不能是空的")
    }

    @Test("truncated reasoning is not promoted, and visible text is never replaced")
    func promotionIsNarrow() async throws {
        let (truncated, _) = try await runTurn([[.reasoningDelta("思考到一半"), .completed(.maxTokens)]])
        #expect(truncated?.contains("思考到一半") != true, "被截断的思考不是答案")
        let (normal, _) = try await runTurn([[.reasoningDelta("思考"), .textDelta("正式回答"), .completed(.stop)]])
        #expect(normal == "正式回答")
    }

    // MARK: - The empty-result note reaches the model

    @Test("after two empty batches the note is in what the model sees next")
    func emptyResultNoteDelivered() async throws {
        let globs = ["*.nothing1", "*.nothing2", "*.nothing3"].enumerated().map { index, pattern -> [ModelEvent] in
            let call = ToolCall(callID: ToolCallID("g\(index)"), toolID: ToolID("glob"), arguments: "{\"pattern\":\"\(pattern)\"}")
            return [.toolCallStarted(callID: call.callID, toolID: call.toolID), .toolCallCompleted(call), .completed(.toolCalls)]
        }
        let (_, provider) = try await runTurn(globs + [[.textDelta("没有找到"), .completed(.stop)]])
        let third = try #require(provider.recorder.requests.dropFirst(2).first)
        let texts = third.messages.flatMap(\.parts).compactMap { part -> String? in
            if case let .toolResult(result) = part { return result.content } else { return nil }
        }
        #expect(texts.contains { $0.contains("returned empty results") },
                "空结果提示必须写进持久化结果，模型才看得到：\(texts)")
    }

    // MARK: - xcrun cache inside the shell sandbox

    #if canImport(Darwin)
    @Test("the sandbox lets xcrun keep its cache and nothing else in the user temp directory")
    func xcrunCacheAllowedOnlyThere() throws {
        let workspace = try tempDir("lx-sbx")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let adapter = DarwinSandboxAdapter()
        let userTemp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        func run(_ path: String) throws -> Int32 {
            let invocation = try adapter.invocation(executable: "/bin/sh", arguments: ["-c", "echo x > '\(path)'"],
                                                    policy: SandboxPolicy(workspace: workspace))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: invocation.executable)
            process.arguments = invocation.arguments
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        let cache = userTemp + "/xcrun_db-lxtest-\(UUID().uuidString.prefix(6))"
        let other = userTemp + "/lx-not-allowed-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: cache) }
        #expect(try run(cache) == 0, "xcrun 缓存应可写")
        #expect(try run(other) != 0, "用户临时目录的其他文件仍必须被拒绝")
        #expect(!FileManager.default.fileExists(atPath: other))
    }

    private static func hostCanCompile() -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lx-cc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? "int main(){return 0;}\n".write(to: dir.appendingPathComponent("a.cpp"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/g++")
        process.arguments = ["a.cpp", "-o", "a"]
        process.currentDirectoryURL = dir
        process.standardOutput = Pipe(); process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The real smoke test's "You have not agreed to the Xcode license" (exit 69) came from the
    /// sandbox, not the machine: xcodebuild could not read the licence plist. Where the host
    /// compiles, the sandbox must compile too.
    @Test("where the host can compile, the shell sandbox can compile too", .enabled(if: hostCanCompile()))
    func sandboxCompiles() throws {
        let workspace = try tempDir("lx-sbx-cc")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let temporary = workspace.appendingPathComponent(".lingxi-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try "int main(){return 0;}\n".write(to: workspace.appendingPathComponent("a.cpp"), atomically: true, encoding: .utf8)
        let invocation = try DarwinSandboxAdapter().invocation(executable: "/usr/bin/g++", arguments: ["a.cpp", "-o", "a"],
                                                              policy: SandboxPolicy(workspace: workspace))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = workspace
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporary.path
        process.environment = environment
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "沙箱内编译失败：\(message.prefix(300))")
        #expect(!message.contains("You have not agreed"), "沙箱不得制造假的许可报错")
        #expect(FileManager.default.isExecutableFile(atPath: workspace.appendingPathComponent("a").path), "应真实产出可执行文件")
    }
    #endif
}
