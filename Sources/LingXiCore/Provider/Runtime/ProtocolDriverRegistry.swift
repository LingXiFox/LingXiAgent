import Foundation
import LingXiProtocol

/// Registry managing all runtime inference protocol drivers.
public final class ProtocolDriverRegistry: Sendable {
    public static let shared = ProtocolDriverRegistry()

    private let drivers: [String: any InferenceProtocolDriver]

    public init(drivers: [any InferenceProtocolDriver] = [
        OpenAIChatDriver(),
        OpenAIResponsesDriver(),
        AnthropicMessagesDriver(),
        GeminiNativeDriver(),
        OllamaNativeDriver()
    ]) {
        var map: [String: any InferenceProtocolDriver] = [:]
        for driver in drivers {
            map[driver.protocolIdentifier] = driver
        }
        self.drivers = map
    }

    /// Returns driver for the given protocol identifier.
    public func driver(for protocolIdentifier: String) -> (any InferenceProtocolDriver)? {
        drivers[protocolIdentifier]
    }

    /// Returns driver for product or falls back to OpenAIChatDriver.
    public func resolveDriver(for product: ResolvedProviderProduct, requestedProtocol: String? = nil) -> any InferenceProtocolDriver {
        let proto = requestedProtocol ?? product.primaryProtocol
        if let driver = drivers[proto] {
            return driver
        }
        // Fallback to openaiChat
        return drivers["openaiChat"] ?? OpenAIChatDriver()
    }
}
