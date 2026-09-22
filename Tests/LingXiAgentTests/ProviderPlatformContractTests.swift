import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import LingXiProtocol
@testable import LingXiCore

struct ProviderPlatformContractTests {
    @Test(arguments: [
        Contract(productID: "openai-api", endpointID: "responses", authentication: .bearer, path: "/v1/responses", header: ("Authorization", "Bearer openai-api-secret"), wire: .responses),
        Contract(productID: "anthropic-api", endpointID: "messages", authentication: .header, headerName: "x-api-key", path: "/v1/messages", header: ("x-api-key", "anthropic-api-secret"), wire: .anthropicMessages),
        Contract(productID: "deepseek-api", endpointID: "chat", authentication: .bearer, path: "/chat/completions", header: ("Authorization", "Bearer deepseek-api-secret"), wire: .chatCompletions),
        Contract(productID: "openrouter", endpointID: "chat", authentication: .bearer, path: "/api/v1/chat/completions", header: ("Authorization", "Bearer openrouter-secret"), wire: .chatCompletions),
        Contract(productID: "gemini-api", endpointID: "openai", authentication: .bearer, path: "/v1beta/openai/chat/completions", header: ("Authorization", "Bearer gemini-api-secret"), wire: .chatCompletions),
        Contract(productID: "alibaba-bailian-api", endpointID: "responses", authentication: .bearer, path: "/compatible-mode/v1/responses", header: ("Authorization", "Bearer alibaba-bailian-api-secret"), wire: .responses),
        Contract(productID: "llama-cpp-local", endpointID: "openai", authentication: .none, path: "/v1/chat/completions", header: nil, wire: .chatCompletions),
        Contract(productID: "llama-cpp-local", endpointID: "openai-auth", authentication: .bearer, path: "/v1/chat/completions", header: ("Authorization", "Bearer llama-cpp-local-secret"), wire: .chatCompletions),
        Contract(productID: "lm-studio-local", endpointID: "openai", authentication: .none, path: "/v1/chat/completions", header: nil, wire: .chatCompletions),
        Contract(productID: "ollama-local", endpointID: "openai", authentication: .none, path: "/v1/chat/completions", header: nil, wire: .chatCompletions),
    ]) private func runnableBuiltinContractsPreserveProductWireModelAndCredentialBoundary(contract: Contract) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase", iterations: 100_000)
        let reference = CredentialRef("credential")
        if contract.authentication != .none { try await credentials.setSecret("\(contract.productID)-secret", for: reference) }

        let resolution = try await RuntimeConfigurationResolver.resolveProviders(configuration(for: contract, credential: contract.authentication == .none ? nil : reference), credentials: credentials)
        let assembly = resolution.assembly
        #expect(assembly.endpoint.productID == contract.productID)
        #expect(assembly.endpoint.endpointID == contract.endpointID)
        #expect(assembly.endpoint.modelID.rawValue == "preserved-model")
        #expect(assembly.endpoint.wireProtocol == contract.wire)
        #expect(resolution.availability["account::profile"] == .available)

        let request = try wireRequest(from: assembly.provider)
        #expect(request.url?.path == contract.path)
        if let header = contract.header { #expect(request.value(forHTTPHeaderField: header.0) == header.1) }
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == (contract.productID == "anthropic-api" ? "2023-06-01" : nil))
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "preserved-model")
        #expect(!String(data: body, encoding: .utf8)!.contains("secret"))
    }

    @Test func unverifiedAndAuthenticationMismatchedProductsFailClosed() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase", iterations: 100_000)
        try await credentials.setSecret("must-not-leak", for: CredentialRef("credential"))

        await expectResolutionError(.providerProductUnverified(ProviderProductID(rawValue: "openai-codex"))) {
            _ = try await RuntimeConfigurationResolver.resolveProviders(configuration(for: Contract(productID: "openai-codex", endpointID: "responses", authentication: .bearer, path: "", header: nil, wire: .responses), credential: CredentialRef("credential")), credentials: credentials)
        }

        await expectAuthenticationError {
            _ = try await RuntimeConfigurationResolver.resolveProviders(configuration(for: Contract(productID: "anthropic-api", endpointID: "messages", authentication: .bearer, path: "", header: nil, wire: .anthropicMessages), credential: CredentialRef("credential")), credentials: credentials)
        }
    }

    @Test func explicitEndpointCannotSilentlyChangeTheDeclaredWire() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase", iterations: 100_000)
        let contract = Contract(productID: "openai-api", endpointID: "chat", authentication: .bearer, path: "", header: nil, wire: .responses)
        try await credentials.setSecret("endpoint-wire-secret", for: CredentialRef("credential"))
        await expectResolutionError(.providerWireUnsupported(.openAIResponses)) {
            _ = try await RuntimeConfigurationResolver.resolveProviders(configuration(for: contract, credential: CredentialRef("credential")), credentials: credentials)
        }
    }

    @Test func everyNonVerifiedBuiltinProductFailsClosed() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase", iterations: 100_000)
        let products = BuiltinProviderCatalog.definitions.filter { !$0.verificationStatus.isRuntimeVerified }
        for product in products {
            do {
                _ = try await RuntimeConfigurationResolver.resolveProviders(
                    configuration(for: Contract(productID: product.id.rawValue, endpointID: "missing", authentication: .none, path: "", header: nil, wire: .chatCompletions), credential: nil),
                    credentials: credentials
                )
                Issue.record("\(product.id.rawValue) unexpectedly resolved")
            } catch let error as ProviderResolutionError {
                #expect(error == .providerProductUnverified(product.id))
            } catch {
                Issue.record("\(product.id.rawValue) returned the wrong error: \(error)")
            }
        }
    }

    @Test func customProviderOverridesUnverifiedBuiltinProduct() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase", iterations: 100_000)
        try await credentials.setSecret("opencode-key", for: CredentialRef("opencode-cred"))

        let config = ProvidersConfiguration(
            customProviders: [
                CustomProviderConfiguration(
                    id: "opencode-zen",
                    displayName: "OpenCode Zen Custom",
                    baseURL: "https://opencode.ai/zen/v1",
                    requiredHeaders: [:]
                )
            ],
            accounts: [
                ProviderAccountConfiguration(
                    id: "opencode-zen",
                    providerID: "opencode-zen",
                    displayName: "OpenCode Zen",
                    authentication: .bearer,
                    credential: CredentialRef("opencode-cred"),
                    accountType: .apiKey
                )
            ],
            modelProfiles: [
                ModelProfileConfiguration(
                    id: "opencode-zen::muse-spark",
                    providerID: "opencode-zen",
                    modelID: "muse-spark",
                    displayName: "Muse Spark",
                    wireProtocol: .responses,
                    contextWindow: 131_072
                )
            ],
            defaultSelection: StoredModelSelection(accountID: "opencode-zen", profileID: "opencode-zen::muse-spark")
        )

        let resolution = try await RuntimeConfigurationResolver.resolveProviders(config, credentials: credentials)
        #expect(resolution.runtimes["opencode-zen::opencode-zen::muse-spark"] != nil)
    }

    @Test("CoreHost listModels yields custom configured opencode-zen even if built-in catalog contains unconfigured entry")
    func coreHostListModelsYieldsCustomConfiguredProvider() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let providersJSON = """
        {
          "$schema": "https://lingxiagent.lingxifox.cn/schema/providers.json",
          "version": 1,
          "providers": {
            "opencode-zen": {
              "name": "OpenCode Zen",
              "adapter": "openai-responses",
              "options": {
                "baseURL": "https://opencode.ai/zen/v1",
                "apiKey": "{env:OPENCODE_API_KEY}"
              },
              "models": {
                "muse-spark-1.3-contributor-free": {
                  "name": "Muse Spark 1.3 Contributor Free",
                  "limit": { "context": 131072, "output": 8192 },
                  "reasoning": true
                }
              }
            }
          }
        }
        """
        let provURL = tempDir.appendingPathComponent("providers.json")
        try providersJSON.data(using: .utf8)?.write(to: provURL)

        let configurations = try ConfigurationStore(dataRoot: tempDir)
        let host = try CoreHost(
            workspaceRoot: WorkspaceRoot(path: tempDir.path),
            dataRoot: tempDir,
            configurationStore: configurations
        )
        let response = try await host.listModels(envelope: QueryEnvelope(payload: VoidResult()))
        let models = response.payload
        let found = models.first { $0.id == "opencode-zen/muse-spark-1.3-contributor-free" }
        #expect(found != nil)
        #expect(found?.displayName == "Muse Spark 1.3 Contributor Free")
        #expect(found?.configured == true)
    }

    @Test("CoreHost listModels yields configured models from isolated providers.json")
    func coreHostListModelsYieldsConfiguredModelsFromIsolatedStore() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-hermetic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let providersJSON = """
        {
          "$schema": "https://lingxiagent.lingxifox.cn/schema/providers.json",
          "version": 1,
          "providers": {
            "test-provider": {
              "name": "Test Provider",
              "adapter": "openai-compatible",
              "options": {
                "baseURL": "https://test.example.com/v1",
                "apiKey": "{env:TEST_KEY}"
              },
              "models": {
                "test-model": {
                  "name": "Test Model",
                  "limit": { "context": 131072, "output": 8192 }
                }
              }
            }
          }
        }
        """
        try providersJSON.data(using: .utf8)?.write(to: tempDir.appendingPathComponent("providers.json"))
        let host = try CoreHost(dataRoot: tempDir)
        let response = try await host.listModels(envelope: QueryEnvelope(payload: VoidResult()))
        let models = response.payload
        let found = models.first { $0.id == "test-provider/test-model" }
        #expect(found != nil)
        #expect(found?.displayName == "Test Model")
        #expect(!models.isEmpty)
    }

    @Test("CoreHost listModels merges builtin models and custom models for same provider")
    func coreHostListModelsMergesBuiltinAndCustomModels() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let providersJSON = """
        {
          "$schema": "https://lingxiagent.lingxifox.cn/schema/providers.json",
          "version": 1,
          "providers": {
            "llama-cpp-local": {
              "name": "Local LLaMA Custom",
              "adapter": "openai-compatible",
              "options": {
                "baseURL": "http://127.0.0.1:8080/v1"
              },
              "models": {
                "custom-finetuned": {
                  "name": "Custom Finetuned Model",
                  "limit": { "context": 32768, "output": 4096 },
                  "reasoning": false
                }
              }
            }
          }
        }
        """
        let provURL = tempDir.appendingPathComponent("providers.json")
        try providersJSON.data(using: .utf8)?.write(to: provURL)

        let configurations = try ConfigurationStore(dataRoot: tempDir)
        let host = try CoreHost(
            workspaceRoot: WorkspaceRoot(path: tempDir.path),
            dataRoot: tempDir,
            configurationStore: configurations
        )
        let response = try await host.listModels(envelope: QueryEnvelope(payload: VoidResult()))
        let models = response.payload
        let hasCustom = models.contains { $0.id == "llama-cpp-local/custom-finetuned" && $0.configured == true }
        #expect(hasCustom)
    }

    private func configuration(for contract: Contract, credential: CredentialRef?) -> ProvidersConfiguration {
        let local = contract.authentication == .none
        return ProvidersConfiguration(
            accounts: [ProviderAccountConfiguration(
                id: "account",
                providerID: contract.productID,
                displayName: "Account",
                authentication: contract.authentication,
                headerName: contract.headerName,
                credential: credential,
                accountType: local ? .anonymousLocal : .apiKey
            )],
            modelProfiles: [ModelProfileConfiguration(
                id: "profile",
                providerID: contract.productID,
                modelID: "preserved-model",
                displayName: "Model",
                wireProtocol: storedWire(contract.wire),
                contextWindow: 32_768,
                endpointID: contract.endpointID
            )],
            defaultSelection: StoredModelSelection(accountID: "account", profileID: "profile")
        )
    }

    private func storedWire(_ wire: ModelWireProtocol) -> StoredProviderWireProtocol {
        switch wire {
        case .chatCompletions: .chatCompletions
        case .responses: .responses
        case .anthropicMessages: .anthropicMessages
        }
    }

    private func wireRequest(from provider: any ModelProvider) throws -> URLRequest {
        let request = ModelRequest(model: ModelID("preserved-model"), messages: [ModelMessage(role: .user, content: "hello")])
        if let provider = provider as? OpenAICompatibleProvider { return try provider.makeURLRequest(request) }
        if let provider = provider as? OpenAIResponsesProvider { return try provider.makeURLRequest(request) }
        if let provider = provider as? AnthropicMessagesProvider { return try provider.makeURLRequest(request) }
        throw TestFailure.unknownProvider
    }

    private func expectResolutionError(_ expected: ProviderResolutionError, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("resolution should fail")
        } catch let error as ProviderResolutionError {
            #expect(error == expected)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    private func expectAuthenticationError(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("resolution should fail")
        } catch let error as ProviderResolutionError {
            guard case .authenticationUnsupported = error else { Issue.record("unexpected provider error: \(error)"); return }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-p14-contract-\(UUID().uuidString)", isDirectory: true)
    }

    private struct Contract: Sendable {
        let productID: String
        let endpointID: String
        let authentication: StoredProviderAuthenticationKind
        let headerName: String?
        let path: String
        let header: (String, String)?
        let wire: ModelWireProtocol

        init(productID: String, endpointID: String, authentication: StoredProviderAuthenticationKind, headerName: String? = nil, path: String, header: (String, String)?, wire: ModelWireProtocol) {
            self.productID = productID
            self.endpointID = endpointID
            self.authentication = authentication
            self.headerName = headerName
            self.path = path
            self.header = header
            self.wire = wire
        }
    }

    private enum TestFailure: Error { case unknownProvider }
}

extension ProviderPlatformContractTests {
    @Test("OpenCode Zen request automatically injects x-opencode-session and CLI headers")
    func opencodeZenRequestInjectsRequiredSessionAndCliHeaders() throws {
        let config = ProviderConfig(
            baseURL: URL(string: "https://opencode.ai/zen/v1")!,
            apiKey: "test-opencode-key",
            model: "muse-spark-1.3-contributor-free",
            wireProtocol: .responses
        )
        let provider = OpenAIResponsesProvider(config: config)
        let request = ModelRequest(
            model: ModelID("muse-spark-1.3-contributor-free"),
            executionID: AgentRunID("run-session-12345"),
            messages: [ModelMessage(role: .user, content: "Hello OpenCode")]
        )
        let urlRequest = try provider.makeURLRequest(request)

        #expect(urlRequest.value(forHTTPHeaderField: "x-opencode-session") != nil)
        #expect(urlRequest.value(forHTTPHeaderField: "x-opencode-client") == "cli")
        #expect(urlRequest.value(forHTTPHeaderField: "x-opencode-project") != nil)
        #expect(urlRequest.value(forHTTPHeaderField: "x-opencode-request") != nil)
        #expect(urlRequest.value(forHTTPHeaderField: "User-Agent")?.contains("opencode") == true)
    }
}

