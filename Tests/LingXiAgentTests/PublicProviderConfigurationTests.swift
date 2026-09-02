import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

struct PublicProviderConfigurationTests {
    @Test func publicOpenAICompatibleConfigurationResolvesEnvironmentCredential() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConfigurationStore(dataRoot: root)
        _ = try await store.load()
        let publicConfiguration = #"""
        {
          "$schema": "https://schemas.example.invalid/lingxiagent/providers.schema.json",
          "version": 1,
          "model": "amd-radeon/DeepSeek-V4-Flash",
          "providers": {
            "amd-radeon": {
              "name": "AMD Radeon Cloud",
              "adapter": "openai-compatible",
              "options": {
                "baseURL": "https://developer.amd.com.cn/radeon/api/v1",
                "apiKey": "{env:AMD_RADEON_API_KEY}"
              },
              "models": {
                "DeepSeek-V4-Flash": {
                  "name": "DeepSeek V4 Flash (AMD)",
                  "reasoning": true,
                  "limit": { "context": 1048576, "output": 384000 }
                }
              }
            }
          }
        }
        """#
        try Data(publicConfiguration.utf8).write(to: root.appendingPathComponent("providers.json"), options: .atomic)

        let configuration = try await store.load().providers
        let resolution = try await RuntimeConfigurationResolver.resolveProviders(
            configuration,
            credentials: FileCredentialStore(dataRoot: root),
            environment: ["AMD_RADEON_API_KEY": "test-secret"]
        )

        #expect(resolution.defaultSelection?.modelID == "DeepSeek-V4-Flash")
        #expect(resolution.assembly.endpoint.providerID == "amd-radeon")
        #expect(resolution.assembly.endpoint.contextProfile.contextWindowTokens == 1_048_576)
        #expect(resolution.assembly.endpoint.contextProfile.maxOutputTokens == 384_000)
        #expect(resolution.assembly.provider is OpenAICompatibleProvider)
        #expect(!publicConfiguration.contains("test-secret"))
    }

    @Test func publicConfigurationCanResolveVaultCredentialWithoutInternalFields() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConfigurationStore(dataRoot: root)
        _ = try await store.load()
        let credentials = try FileCredentialStore(dataRoot: root, passphrase: "test-passphrase")
        try await credentials.setSecret("vault-secret", for: CredentialRef("amd-key"))
        let configuration = ProvidersConfiguration(
            model: "provider/model",
            providers: [
                "provider": PublicProviderConfiguration(
                    name: "Provider",
                    options: PublicProviderOptions(baseURL: "https://provider.example.com/v1", apiKey: "{vault:amd-key}"),
                    models: ["model": PublicModelConfiguration(name: "Model", limit: PublicModelLimit(context: 32_768, output: 4_096))]
                ),
            ]
        )

        let resolution = try await RuntimeConfigurationResolver.resolveProviders(configuration, credentials: credentials)
        #expect(resolution.missingRequirements.isEmpty)
        #expect(resolution.defaultSelection?.providerID == "provider")
    }

    @Test func publicConfigurationRejectsLiteralApiKey() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConfigurationStore(dataRoot: root)
        _ = try await store.load()
        let invalid = #"{"$schema":"https://schemas.example.invalid/lingxiagent/providers.schema.json","version":1,"providers":{"provider":{"name":"Provider","adapter":"openai-compatible","options":{"baseURL":"https://provider.example.com/v1","apiKey":"literal-secret"},"models":{"model":{"name":"Model","limit":{"context":32768,"output":4096}}}}}}"#
        try Data(invalid.utf8).write(to: root.appendingPathComponent("providers.json"), options: .atomic)

        await #expect(throws: ConfigurationValidationError.self) { _ = try await store.load() }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-public-provider-\(UUID().uuidString)", isDirectory: true)
    }
}
