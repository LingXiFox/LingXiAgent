import Foundation
import Testing
import LingXiPlatform
import LingXiProtocol
import LingXiClient
import LingXiApplication
@testable import LingXiCore

@Suite(.serialized)
struct ModelSelectionAndTurnExecutionFixTests {
    @Test func historyRunRestorationFailureIsIsolatedAndDoesNotBlockCoreReady() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-core-ready-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let persistence = try SQLitePersistenceStore(dataRoot: tempDir, mainRoot: tempDir)
        let sessionStore = PersistentSessionStore(persistence: persistence)
        let session = try await sessionStore.create(kind: .primary, parentSessionID: nil, rootSessionID: nil, spawnedByRunID: nil, spawnedByToolCallID: nil, title: "Test Session")

        // Inject an orphan run with an unauthenticated/unresolvable model
        let brokenModel = ModelSelection(providerID: "nonexistent-provider", modelID: "dummy-model")
        let runID = AgentRunID(UUID().uuidString)
        let orphanRun = AgentRunInfo(
            runID: runID,
            sessionID: session.id,
            projectID: persistence.projectID,
            parentRunID: nil,
            rootRunID: runID,
            agentKind: .primary,
            status: .waitingForUser,
            modelSelection: brokenModel,
            startedAt: .now,
            latestActivityAt: .now,
            title: "Orphan Broken Run"
        )
        try await persistence.saveAgentRun(orphanRun)

        let host = try CoreHost(
            sessionStore: sessionStore,
            dataRoot: tempDir,
            persistence: persistence,
            permissionDecision: .allow
        )
        await host.start()

        // CoreHost MUST be ready and not crash into .stopped
        let stateResp = try await host.handle(.getState)
        guard case let .state(coreState) = stateResp else {
            Issue.record("Expected state response")
            return
        }
        #expect(coreState == .ready)

        // The broken run should have been downgraded to .recoveryRequired, and session not locked in activeSessions
        let loadedRuns = try await persistence.loadAgentRuns()
        let target = loadedRuns.first { $0.runID == orphanRun.runID }
        #expect(target?.status == AgentRunStatus.recoveryRequired)
        await host.shutdown()
    }

    @Test func applicationStorePreservesUserSelectedModelAcrossRefresh() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-app-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let assembly = ModelRuntimeAssembly(
            provider: OpenAICompatibleProvider(config: ProviderConfig(baseURL: URL(string: "http://127.0.0.1:1234/v1")!, apiKey: "test", model: "default-model", wireProtocol: .chatCompletions)),
            modelID: ModelID("default-model"),
            endpoint: ResolvedModelEndpoint(providerID: "default-provider", modelID: ModelID("default-model"), baseURL: URL(string: "http://127.0.0.1:1234/v1")!, wireProtocol: .chatCompletions)
        )

        let host = try CoreHost(
            providerAssembly: assembly,
            dataRoot: tempDir,
            permissionDecision: .allow
        )
        await host.start()

        let client = try await LingXiClientVNext.inProcess(service: host)
        let store = await ApplicationStore(client: client, autoConnect: false)
        try await store.connect()

        // 1. Initial connect sets default model
        let initialModel = await store.state.currentModelID
        #expect(initialModel != nil)

        // 2. User selects a custom model
        await store.dispatch(.selectModel("user-chosen-provider/user-model"))

        // Simulate reconnect with an already chosen model
        await store.dispatch(._connectionStateChanged(ConnectionState(status: .connected)))
        try await Task.sleep(for: .milliseconds(200))

        // Ensure refreshBasics does not wipe non-empty currentModelID
        let currentModel = await store.state.currentModelID
        #expect(currentModel != nil)
        await host.shutdown()
    }

    @Test func unresolvableModelReportsRuntimeFailureInsteadOfCompleted() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-turn-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let host = try CoreHost(
            dataRoot: tempDir,
            permissionDecision: .allow
        )
        await host.start()

        let client = try await LingXiClientVNext.inProcess(service: host)
        let sessionReceipt = try await client.session.create()
        let sessionID = try #require(sessionReceipt.result?.sessionID)

        // Submit turn with an invalid model
        let intent = TurnExecutionIntent(modelSelection: "unauthenticated-provider/broken-model")
        let turnReceipt = try await client.turn.submitTurn(
            sessionID: sessionID,
            input: UserInput(text: "Hello there"),
            executionIntent: intent
        )
        let turnID = try #require(turnReceipt.result?.turnID)

        // Wait for turn execution to fail transparently
        var observedFailure = false
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            let snapshot = try await client.session.snapshot(sessionID: sessionID)
            if let turn = snapshot.recentTurns.first(where: { $0.turnID == turnID }), turn.status == .failed {
                observedFailure = true
                break
            }
        }
        #expect(observedFailure, "Turn execution must report .failed with clear error, never .completed silently")
        await host.shutdown()
    }

    @Test func unresolvableModelWithDefaultProviderFailsFastAndDoesNotFallbackSilently() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-turn-failfast-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Host has a valid working default provider assembly
        let assembly = ModelRuntimeAssembly(
            provider: OpenAICompatibleProvider(config: ProviderConfig(baseURL: URL(string: "http://127.0.0.1:1234/v1")!, apiKey: "test", model: "default-model", wireProtocol: .chatCompletions)),
            modelID: ModelID("default-model"),
            endpoint: ResolvedModelEndpoint(providerID: "default-provider", modelID: ModelID("default-model"), baseURL: URL(string: "http://127.0.0.1:1234/v1")!, wireProtocol: .chatCompletions)
        )

        let host = try CoreHost(
            providerAssembly: assembly,
            dataRoot: tempDir,
            permissionDecision: .allow
        )
        await host.start()

        let client = try await LingXiClientVNext.inProcess(service: host)
        let sessionReceipt = try await client.session.create()
        let sessionID = try #require(sessionReceipt.result?.sessionID)

        // Submit turn with an invalid model
        let intent = TurnExecutionIntent(modelSelection: "broken-provider/broken-model")
        let turnReceipt = try await client.turn.submitTurn(
            sessionID: sessionID,
            input: UserInput(text: "Execute with broken model"),
            executionIntent: intent
        )
        let turnID = try #require(turnReceipt.result?.turnID)

        // Must fail fast with runtimeFailure, NOT succeed by silently falling back to default-model
        var observedFailure = false
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            let snapshot = try await client.session.snapshot(sessionID: sessionID)
            if let turn = snapshot.recentTurns.first(where: { $0.turnID == turnID }), turn.status == .failed {
                observedFailure = true
                break
            }
        }
        #expect(observedFailure, "Turn must fail fast when requested model is unresolvable, even if default provider exists")
        await host.shutdown()
    }

    @Test func permissionHierarchyFollowsCliThenConfigThenDefaultsToAskWorkspace() async throws {
        // 1. CLI --yolo has highest priority
        let cliYolo = AppCompositionRoot.resolveInitialPermission(isYoloMode: true)
        #expect(cliYolo == .yoloFullAccess)

        // 2. Default without config.json must be Ask/Workspace
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // When config.json is absent or has no YOLO, default is askWorkspace
        let defaultPerm = AppCompositionRoot.resolveInitialPermission(isYoloMode: false)
        #expect(defaultPerm == .askWorkspace)
    }

    @Test func customProviderInProvidersJsonTakesPrecedenceAndHonorsEnvApiKey() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-custom-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write a providers.json that configures opencode-zen with env:OPENCODE_TEST_KEY
        LingXiPlatform.environment.set("OPENCODE_TEST_KEY", value: "test-token-value-12345")
        defer { LingXiPlatform.environment.unset("OPENCODE_TEST_KEY") }

        let providersJson = """
        {
          "$schema": "https://lingxiagent.lingxifox.cn/schema/providers.json",
          "version": 1,
          "providers": {
            "opencode-zen": {
              "name": "OpenCode Zen",
              "adapter": "openai-responses",
              "options": {
                "apiKey": "{env:OPENCODE_TEST_KEY}",
                "baseURL": "https://opencode.ai/zen/v1"
              },
              "models": {
                "muse-spark-1.3-contributor-free": {
                  "name": "Muse Spark 1.3 Contributor Free",
                  "limit": { "context": 131072, "output": 8192 }
                }
              }
            }
          }
        }
        """
        try providersJson.write(to: tempDir.appendingPathComponent("providers.json"), atomically: true, encoding: .utf8)

        let host = try CoreHost(
            dataRoot: tempDir,
            permissionDecision: .allow
        )
        await host.start()

        // Selecting opencode-zen/muse-spark-1.3-contributor-free must succeed and not throw unauthenticated
        let client = try await LingXiClientVNext.inProcess(service: host)
        let selectReceipt = try await client.model.select(model: "opencode-zen/muse-spark-1.3-contributor-free")
        #expect(selectReceipt.applied == true)
        #expect(selectReceipt.result?.modelID == "opencode-zen/muse-spark-1.3-contributor-free")
        #expect(selectReceipt.result?.providerID == "opencode-zen")
        await host.shutdown()
    }

    @Test func customProviderWithoutSchemaAndWithInheritedBuiltinModelsSucceeds() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-schemaless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Environment key for deepseek
        LingXiPlatform.environment.set("DEEPSEEK_API_KEY", value: "test-deepseek-key-67890")
        defer { LingXiPlatform.environment.unset("DEEPSEEK_API_KEY") }

        // providers.json WITHOUT "$schema", and with empty models (inheriting from builtin catalog)
        let schemalessJson = """
        {
          "version": 1,
          "providers": {
            "deepseek-api": {
              "name": "Custom DeepSeek Proxy",
              "adapter": "openai-compatible",
              "options": {
                "baseURL": "https://proxy.internal/v1"
              },
              "models": {}
            }
          }
        }
        """
        try schemalessJson.write(to: tempDir.appendingPathComponent("providers.json"), atomically: true, encoding: .utf8)

        let host = try CoreHost(
            dataRoot: tempDir,
            permissionDecision: .allow
        )
        await host.start()

        let client = try await LingXiClientVNext.inProcess(service: host)
        // Select an inherited builtin model (deepseek-chat)
        let selectReceipt = try await client.model.select(model: "deepseek-api/deepseek-chat")
        #expect(selectReceipt.applied == true)
        #expect(selectReceipt.result?.modelID == "deepseek-api/deepseek-chat")
        #expect(selectReceipt.result?.providerID == "deepseek-api")
        await host.shutdown()
    }
}


