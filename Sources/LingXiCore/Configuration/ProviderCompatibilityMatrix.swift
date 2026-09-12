import Foundation
import LingXiProtocol

/// One product's compatibility facts.
///
/// The matrix describes what LingXi maintains by hand — protocol, auth,
/// discovery, runtime support and quirks. It deliberately carries no model IDs:
/// a product's models come from upstream discovery, so a static roster here
/// would be a second, stale answer to the same question.
public struct ProviderCompatibilityEntry: Sendable, Codable, Equatable {
    public let providerID: String
    public let vendor: String
    public let displayName: String
    public let type: String
    public let protocolFamily: String
    public let endpoint: String
    public let authMethods: [String]
    public let discoveryStrategy: String
    public let discoveryKind: String?
    public let runtimeSupport: String
    public let quirks: [String]
    public let accountFields: [String]

    public init(
        providerID: String,
        vendor: String,
        displayName: String,
        type: String,
        protocolFamily: String,
        endpoint: String,
        authMethods: [String],
        discoveryStrategy: String,
        discoveryKind: String?,
        runtimeSupport: String,
        quirks: [String],
        accountFields: [String]
    ) {
        self.providerID = providerID
        self.vendor = vendor
        self.displayName = displayName
        self.type = type
        self.protocolFamily = protocolFamily
        self.endpoint = endpoint
        self.authMethods = authMethods
        self.discoveryStrategy = discoveryStrategy
        self.discoveryKind = discoveryKind
        self.runtimeSupport = runtimeSupport
        self.quirks = quirks
        self.accountFields = accountFields
    }
}

public enum ProviderCompatibilityMatrix {
    public static func generateMatrix() -> [ProviderCompatibilityEntry] {
        BuiltinProviderCatalog.definitions
            .map(entry(for:))
            .sorted { $0.providerID < $1.providerID }
    }

    public static func entry(for definition: ProviderProductDefinition) -> ProviderCompatibilityEntry {
        let id = definition.id.rawValue
        let metadata = BuiltinProviderCatalog.metadata(for: id)
        return ProviderCompatibilityEntry(
            providerID: id,
            vendor: definition.vendorID.rawValue,
            displayName: definition.displayName,
            type: definition.type.rawValue,
            protocolFamily: protocolFamily(for: definition),
            endpoint: definition.endpoints.first?.baseURL?.absoluteString ?? "",
            authMethods: definition.accountTypes.map(\.rawValue).sorted(),
            discoveryStrategy: metadata.discovery.rawValue,
            discoveryKind: metadata.discoveryProfile?.kind,
            runtimeSupport: metadata.runtimeSupport.rawValue,
            quirks: metadata.quirks.sorted(),
            accountFields: definition.requiredAccountFields.sorted()
        )
    }

    public static func renderMarkdownTable() -> String {
        var lines: [String] = []
        lines.append("# Provider Compatibility Matrix\n")
        lines.append("")
        lines.append("Generated from `BuiltinProviderCatalog` — protocol, auth and discovery knowledge only.")
        lines.append("Model IDs are intentionally absent: each product's models are discovered upstream.")
        lines.append("")
        lines.append("| Product | Vendor | Protocol | Auth | Discovery | Runtime | Quirks |")
        lines.append("| :--- | :--- | :--- | :--- | :--- | :--- | :--- |")
        for entry in generateMatrix() {
            let discovery: String
            if let kind = entry.discoveryKind {
                discovery = entry.discoveryStrategy + " (" + kind + ")"
            } else {
                discovery = entry.discoveryStrategy
            }
            let quirks = entry.quirks.isEmpty ? "—" : entry.quirks.joined(separator: ", ")
            lines.append("| `\(entry.providerID)` | \(entry.vendor) | `\(entry.protocolFamily)` | \(entry.authMethods.joined(separator: ", ")) | \(discovery) | \(entry.runtimeSupport) | \(quirks) |")
        }
        return lines.joined(separator: "\n")
    }

    private static func protocolFamily(for definition: ProviderProductDefinition) -> String {
        switch definition.endpoints.first?.wire {
        case .anthropicMessages: return "anthropic_messages"
        case .openAIResponses: return "openai_responses"
        default: return "openai_chat"
        }
    }
}
