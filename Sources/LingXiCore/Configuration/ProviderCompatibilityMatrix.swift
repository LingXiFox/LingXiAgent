import Foundation
import LingXiProtocol

public struct ProviderCompatibilityEntry: Sendable, Codable, Equatable {
    public let providerID: String
    public let vendor: String
    public let displayName: String
    public let protocolFamily: String
    public let endpoint: String
    public let authMethods: [String]
    public let concurrencyLimit: Int?
    public let quirks: [String]
    public let models: [ModelCompatibilityEntry]

    public struct ModelCompatibilityEntry: Sendable, Codable, Equatable {
        public let modelID: String
        public let displayName: String
        public let toolCall: Bool
        public let vision: Bool
        public let cache: Bool
        public let reasoningMode: String
        public let supportedEfforts: [String]
        public let defaultEffort: String
        public let emitsVisibleReasoning: Bool
        public let emitsReasoningSummary: Bool
        public let contextWindow: Int?
        public let maxOutputTokens: Int?
    }
}

public enum ProviderCompatibilityMatrix {
    public static func generateMatrix() -> [ProviderCompatibilityEntry] {
        BuiltinProviderCatalog.profiles.map { profile in
            ProviderCompatibilityEntry(
                providerID: profile.id,
                vendor: profile.vendor,
                displayName: profile.displayName,
                protocolFamily: profile.protocolFamily,
                endpoint: profile.endpoint,
                authMethods: profile.authMethods,
                concurrencyLimit: profile.concurrencyLimit,
                quirks: profile.quirks,
                models: profile.models.map { model in
                    let cap = model.reasoningCapability
                    return ProviderCompatibilityEntry.ModelCompatibilityEntry(
                        modelID: model.id,
                        displayName: model.displayName,
                        toolCall: model.toolCall,
                        vision: model.vision,
                        cache: model.cache,
                        reasoningMode: cap?.mode.rawValue ?? "none",
                        supportedEfforts: cap?.supportedEfforts.map(\.rawValue).sorted() ?? [],
                        defaultEffort: cap?.defaultEffort.rawValue ?? "off",
                        emitsVisibleReasoning: cap?.emitsVisibleReasoning ?? false,
                        emitsReasoningSummary: cap?.emitsReasoningSummary ?? false,
                        contextWindow: model.contextWindow,
                        maxOutputTokens: model.maxOutputTokens
                    )
                }
            )
        }
    }

    public static func renderMarkdownTable() -> String {
        var lines: [String] = []
        lines.append("# Provider Compatibility Matrix\n")
        lines.append("| Provider | Protocol Family | Auth | Models | Reasoning | Tool Call | Vision | Cache | Quirks |")
        lines.append("| :--- | :--- | :--- | :--- | :--- | :---: | :---: | :---: | :--- |")
        for entry in generateMatrix() {
            let modelNames = entry.models.map(\.modelID).joined(separator: ", ")
            let reasoningModes = Set(entry.models.map(\.reasoningMode)).sorted().joined(separator: ", ")
            let toolCall = entry.models.contains(where: \.toolCall) ? "✅" : "❌"
            let vision = entry.models.contains(where: \.vision) ? "✅" : "❌"
            let cache = entry.models.contains(where: \.cache) ? "✅" : "❌"
            let quirksStr = entry.quirks.isEmpty ? "None" : entry.quirks.joined(separator: ", ")
            let authStr = entry.authMethods.joined(separator: ", ")
            lines.append("| \(entry.displayName) (`\(entry.providerID)`) | `\(entry.protocolFamily)` | \(authStr) | \(modelNames) | `\(reasoningModes)` | \(toolCall) | \(vision) | \(cache) | \(quirksStr) |")
        }
        return lines.joined(separator: "\n")
    }
}
