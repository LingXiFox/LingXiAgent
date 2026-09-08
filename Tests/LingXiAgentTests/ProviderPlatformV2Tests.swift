import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

struct ProviderPlatformV2Tests {
    @Test func builtinOpenAIResolvesToStandardConfiguration() async throws {
        let resolved = try ProviderResolver.resolveBuiltin(
            productID: "openai-api",
            modelID: "o3-mini",
            secret: "sk-test-key"
        )

        #expect(resolved.productID == "openai-api")
        #expect(resolved.vendorID == "openai")
        #expect(resolved.protocolFamily == .responses)
        #expect(resolved.modelID == "o3-mini")
        #expect(resolved.limits.contextWindow == 200_000)
        #expect(resolved.limits.maxOutputTokens == 100_000)
        #expect(resolved.continuationPolicy == "responses_api")
        #expect(resolved.capabilities.reasoning == true)
        #expect(resolved.capabilities.reasoningCapability?.mode == .effort)

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        try await resolved.authStrategy.apply(to: &req)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-key")
    }

    @Test func builtinAnthropicResolvesWithApiKeyHeader() throws {
        let resolved = try ProviderResolver.resolveBuiltin(
            productID: "anthropic-api",
            modelID: "claude-3-7-sonnet",
            secret: "sk-ant-test"
        )

        #expect(resolved.productID == "anthropic-api")
        #expect(resolved.vendorID == "anthropic")
        #expect(resolved.protocolFamily == .anthropicMessages)
        #expect(resolved.modelID == "claude-3-7-sonnet")
        #expect(resolved.limits.contextWindow == 200_000)
        #expect(resolved.limits.maxOutputTokens == 64_000)
        #expect(resolved.capabilities.toolCalling == true)
        #expect(resolved.capabilities.vision == true)
        #expect(resolved.capabilities.reasoningCapability?.mode == .budget)
        #expect(resolved.quirks.contains("requiresAnthropicVersionHeader"))
    }

    @Test func builtinLocalRuntimeResolvesWithoutAuth() throws {
        let resolved = try ProviderResolver.resolveBuiltin(
            productID: "ollama-local",
            modelID: "llama3.2"
        )

        #expect(resolved.productID == "ollama-local")
        #expect(resolved.vendorID == "local")
        #expect(resolved.protocolFamily == .chatCompletions)
        #expect(resolved.limits.contextWindow == 128_000)
    }

    @Test func customProviderResolvesToTheSameUnifiedConfiguration() {
        let customEndpoint = URL(string: "https://my-custom-proxy.internal/v1")!
        let resolved = ProviderResolver.resolveCustom(
            endpoint: customEndpoint,
            modelID: "custom-model",
            protocolFamily: .chatCompletions,
            apiKey: "custom-token",
            customHeaders: ["X-Tenant-ID": "acme-corp"]
        )

        #expect(resolved.productID == "custom")
        #expect(resolved.vendorID == "custom")
        #expect(resolved.endpoint == customEndpoint)
        #expect(resolved.protocolFamily == .chatCompletions)
        #expect(resolved.modelID == "custom-model")
        #expect(resolved.requestProfile?.requiredHeaders["X-Tenant-ID"] == "acme-corp")
    }

    @Test func unknownProductOrModelFailsClosed() {
        #expect(throws: ProviderResolutionError.self) {
            try ProviderResolver.resolveBuiltin(productID: "non-existent-product", modelID: "o3-mini")
        }

        #expect(throws: ProviderResolutionError.self) {
            try ProviderResolver.resolveBuiltin(productID: "openai-api", modelID: "non-existent-model")
        }
    }
}
