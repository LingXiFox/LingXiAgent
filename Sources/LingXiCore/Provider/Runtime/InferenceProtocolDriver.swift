import Foundation
import LingXiProtocol

/// Runtime context passed to an inference protocol driver during a stream request.
public struct ProtocolDriverContext: Sendable {
    public let product: ResolvedProviderProduct
    public let binding: ProviderProtocolBindingSpec
    public let credential: String?
    public let transport: (any ProviderHTTPTransport)?
    public let diagnosticsEnabled: Bool
    public let performanceDiagnosticsEnabled: Bool

    public init(
        product: ResolvedProviderProduct,
        binding: ProviderProtocolBindingSpec,
        credential: String? = nil,
        transport: (any ProviderHTTPTransport)? = nil,
        diagnosticsEnabled: Bool = false,
        performanceDiagnosticsEnabled: Bool = false
    ) {
        self.product = product
        self.binding = binding
        self.credential = credential
        self.transport = transport
        self.diagnosticsEnabled = diagnosticsEnabled
        self.performanceDiagnosticsEnabled = performanceDiagnosticsEnabled
    }
}

/// Core contract implemented by all runtime wire protocol drivers.
public protocol InferenceProtocolDriver: Sendable {
    /// Canonical protocol identifier (e.g., "openaiChat", "openaiResponses", "anthropicMessages", "geminiNative", "ollamaNative").
    var protocolIdentifier: String { get }

    /// Streams model events for an incoming ModelRequest using the specified binding and credentials.
    func stream(
        _ request: ModelRequest,
        context: ProtocolDriverContext
    ) async throws -> AsyncThrowingStream<ModelEvent, Error>
}
