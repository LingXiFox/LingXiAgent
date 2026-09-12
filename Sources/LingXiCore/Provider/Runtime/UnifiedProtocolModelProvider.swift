import Foundation
import LingXiProtocol

/// Unified ModelProvider adapter powered by the new modular protocol driver system.
public struct UnifiedProtocolModelProvider: ModelProvider {
    public let product: ResolvedProviderProduct
    public let binding: ProviderProtocolBindingSpec
    public let credential: String?
    public let transport: (any ProviderHTTPTransport)?
    public let diagnosticsEnabled: Bool
    public let performanceDiagnosticsEnabled: Bool

    public init(
        product: ResolvedProviderProduct,
        binding: ProviderProtocolBindingSpec? = nil,
        credential: String? = nil,
        transport: (any ProviderHTTPTransport)? = nil,
        diagnosticsEnabled: Bool = false,
        performanceDiagnosticsEnabled: Bool = false
    ) {
        self.product = product
        let resolvedBinding = binding ?? product.binding(for: product.primaryProtocol) ?? ProviderProtocolBindingSpec(
            productID: product.id,
            protocol: product.primaryProtocol,
            baseURL: "https://api.openai.com/v1",
            path: "/chat/completions"
        )
        self.binding = resolvedBinding
        self.credential = credential
        self.transport = transport
        self.diagnosticsEnabled = diagnosticsEnabled
        self.performanceDiagnosticsEnabled = performanceDiagnosticsEnabled
    }

    public func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let driver = ProtocolDriverRegistry.shared.resolveDriver(for: product, requestedProtocol: binding.protocol)
        let context = ProtocolDriverContext(
            product: product,
            binding: binding,
            credential: credential,
            transport: transport,
            diagnosticsEnabled: diagnosticsEnabled,
            performanceDiagnosticsEnabled: performanceDiagnosticsEnabled
        )
        return try await driver.stream(request, context: context)
    }

    public func endExecution(_ executionID: AgentRunID) async {}
}
