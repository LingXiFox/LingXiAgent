import Foundation

// The provider list a user picks from when connecting something new.
//
// Two real sources are merged: the curated Provider registry (which knows auth
// strategies, OAuth products and local runtimes) and the published
// models.lingxifox.cn index (which carries far more providers, each with its
// OpenAI-compatible endpoint). A front end renders these entries and never
// keeps its own provider list.

/// Where an entry came from.
public enum ProviderCatalogSource: String, Codable, Sendable, Equatable {
    /// Curated Provider registry product.
    case registry
    /// Published models.lingxifox.cn index entry.
    case modelsIndex
}

/// What the user has to supply before the provider works.
public enum ProviderSignInMode: String, Codable, Sendable, Equatable {
    case apiKey
    /// Browser sign-in owned by Core; no key to type.
    case browser
    /// A local runtime that needs its endpoint.
    case localEndpoint
    /// Reachable without any credential.
    case none
}

public struct ProviderCatalogEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let source: ProviderCatalogSource
    public let signInMode: ProviderSignInMode
    public let modelCount: Int
    public let vendor: String?
    /// Extra values the curated registry demands before an account can exist.
    public let requiredAccountFields: [String]
    /// False when the published entry has no endpoint this runtime can drive:
    /// it is listed because it exists, but it cannot be connected from here.
    public let connectable: Bool

    public init(id: String, name: String, source: ProviderCatalogSource,
                signInMode: ProviderSignInMode, modelCount: Int, vendor: String? = nil,
                connectable: Bool = true, requiredAccountFields: [String] = []) {
        self.id = id
        self.name = name
        self.source = source
        self.signInMode = signInMode
        self.modelCount = modelCount
        self.vendor = vendor
        self.connectable = connectable
        self.requiredAccountFields = requiredAccountFields
    }
}

public struct GetProviderCatalogRequest: Codable, Sendable, Equatable {
    /// Ask Core to refresh its cached copy of the published index first.
    public let refresh: Bool
    public init(refresh: Bool = false) { self.refresh = refresh }
}

public struct GetProviderCatalogModelsRequest: Codable, Sendable, Equatable {
    public let entryID: String
    public init(entryID: String) { self.entryID = entryID }
}
