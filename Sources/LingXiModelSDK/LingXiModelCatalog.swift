import Foundation

/// A published model catalog, as loaded from one snapshot of the data source.
///
/// The catalog is a value: load it once, pass it around, and every lookup below
/// answers from that same snapshot. Fetching, caching and schema compatibility
/// are the SDK's job, so a consumer never decodes the published JSON itself.
public struct LingXiModelCatalog: Sendable, Equatable {
    /// Where a snapshot came from and how current it is.
    public struct Revision: Codable, Sendable, Equatable {
        /// Shape of the published document. A changed revision with an unchanged
        /// schema is new data, not a breaking change.
        public let schemaVersion: String
        /// Content identity of this publication; changes whenever the data does.
        public let catalogRevision: String
        public let catalogHash: String?
        /// The upstream the publication derives from, e.g. `models.dev`.
        public let source: String?
        public let sourceURL: String?
        public let sourceHash: String?
        public let generatedAt: Date?
        public let sourceFetchedAt: Date?
        public let totalProviders: Int
        public let totalModels: Int

        public init(
            schemaVersion: String,
            catalogRevision: String,
            catalogHash: String?,
            source: String?,
            sourceURL: String?,
            sourceHash: String?,
            generatedAt: Date?,
            sourceFetchedAt: Date?,
            totalProviders: Int,
            totalModels: Int
        ) {
            self.schemaVersion = schemaVersion
            self.catalogRevision = catalogRevision
            self.catalogHash = catalogHash
            self.source = source
            self.sourceURL = sourceURL
            self.sourceHash = sourceHash
            self.generatedAt = generatedAt
            self.sourceFetchedAt = sourceFetchedAt
            self.totalProviders = totalProviders
            self.totalModels = totalModels
        }
    }

    public let revision: Revision
    /// Providers in publication order. Display should use `sortedProviders(featured:)`,
    /// which applies the documented ordering rule.
    public let providers: [CatalogProvider]
    /// The bytes this catalog was decoded from, kept so that caching can store
    /// the document as published instead of re-encoding it — which would drop
    /// every field the SDK does not model.
    public internal(set) var rawDocument: Data?

    public init(revision: Revision, providers: [CatalogProvider], rawDocument: Data? = nil) {
        self.revision = revision
        self.providers = providers
        self.rawDocument = rawDocument
    }

    public var totalModels: Int { providers.reduce(0) { $0 + $1.modelCount } }

    // MARK: - Lookup

    public func provider(_ providerID: String) -> CatalogProvider? {
        let key = Self.normalized(providerID)
        return providers.first { Self.normalized($0.id) == key }
    }

    public func model(provider providerID: String, id modelID: String) -> CatalogModel? {
        guard let provider = provider(providerID) else { return nil }
        let key = Self.normalized(modelID)
        return provider.models.first { Self.normalized($0.id) == key }
    }

    /// `provider/model` in either the qualified form or a bare model id, which is
    /// how a user names a model they already know they mean.
    public func model(id: String) -> CatalogModel? {
        if let slash = id.firstIndex(of: "/") {
            let providerID = String(id[..<slash])
            let modelID = String(id[id.index(after: slash)...])
            return model(provider: providerID, id: modelID)
        }
        let key = Self.normalized(id)
        for provider in providers {
            if let match = provider.models.first(where: { Self.normalized($0.id) == key }) { return match }
        }
        return nil
    }

    /// Every model under one provider, in the documented model order.
    public func models(provider providerID: String) -> [CatalogModel] {
        guard let provider = provider(providerID) else { return [] }
        return Self.modelsInStableOrder(provider.models)
    }

    /// All models, grouped provider by provider in display order.
    public var allModels: [CatalogModel] {
        sortedProviders().flatMap { Self.modelsInStableOrder($0.models) }
    }

    // MARK: - Ordering

    /// Providers in the documented order: an explicitly featured provider first,
    /// then by display name, then by id as the stable tie-break. Model count is
    /// deliberately not a ranking signal — "more models" is not "more important".
    ///
    /// - Parameter featured: Provider ids in the caller's preferred order. The
    ///   catalog ships no featured list; ranking here is always an explicit choice.
    public func sortedProviders(featured: [String] = []) -> [CatalogProvider] {
        let ranks = Dictionary(uniqueKeysWithValues: featured.enumerated().map { (Self.normalized($1), $0) })
        return providers.sorted { lhs, rhs in
            let l = ranks[Self.normalized(lhs.id)] ?? .max
            let r = ranks[Self.normalized(rhs.id)] ?? .max
            if l != r { return l < r }
            let byName = ModelCatalogOrdering.displayName(lhs.name, lhs.id, rhs.name, rhs.id)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    /// Models in the documented order: newest published first, then model family,
    /// then name, then id as the stable tie-break. Same catalog, same order.
    public static func modelsInStableOrder(_ models: [CatalogModel]) -> [CatalogModel] {
        models.sorted { lhs, rhs in
            let byDate = compareDescending(lhs.releaseDate, rhs.releaseDate)
            if byDate != .orderedSame { return byDate == .orderedAscending }
            let byFamily = ModelCatalogOrdering.displayName(lhs.family ?? "", lhs.id, rhs.family ?? "", rhs.id)
            if byFamily != .orderedSame { return byFamily == .orderedAscending }
            let byName = ModelCatalogOrdering.displayName(lhs.name, lhs.id, rhs.name, rhs.id)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    /// Newest first; a model with no stated release date sorts after one with a
    /// date, so undated entries never displace current work.
    private static func compareDescending(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (.some, nil): return .orderedAscending
        case (nil, .some): return .orderedDescending
        case let (.some(l), .some(r)):
            // ISO dates compare correctly as text; equality still means equality.
            return l == r ? .orderedSame : (l > r ? .orderedAscending : .orderedDescending)
        }
    }

    // MARK: - Search and filtering

    public func search(_ query: String, limit: Int? = nil) -> [CatalogModel] {
        let needle = Self.normalized(query)
        guard !needle.isEmpty else { return Array(allModels.prefix(limit ?? allModels.count)) }
        var matches: [CatalogModel] = []
        for provider in sortedProviders() {
            let providerMatches = Self.modelsInStableOrder(provider.models).filter {
                Self.normalized($0.id).contains(needle)
                    || Self.normalized($0.name).contains(needle)
                    || Self.normalized($0.family ?? "").contains(needle)
                    || Self.normalized($0.overview ?? "").contains(needle)
            }
            if Self.normalized(provider.id).contains(needle) || Self.normalized(provider.name).contains(needle) {
                matches.append(contentsOf: Self.modelsInStableOrder(provider.models))
            } else {
                matches.append(contentsOf: providerMatches)
            }
            if let limit, matches.count >= limit { break }
        }
        return limit.map { Array(matches.prefix($0)) } ?? matches
    }

    /// Catalog-wide filtering. The predicate answers only from published metadata.
    public func models(matching filter: ModelFilter) -> [CatalogModel] {
        var matches: [CatalogModel] = []
        for provider in sortedProviders(featured: filter.featuredProviderIDs) {
            if let wanted = filter.providerID, Self.normalized(provider.id) != Self.normalized(wanted) { continue }
            matches.append(contentsOf: Self.modelsInStableOrder(provider.models).filter { filter.matches($0, provider: provider) })
        }
        return matches
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// A filter over published metadata. Every field unset means "no constraint".
public struct ModelFilter: Sendable, Equatable {
    public var providerID: String?
    /// Matches model id, name, family or provider name.
    public var query: String?
    public var reasoning: Bool?
    public var toolCalling: Bool?
    public var structuredOutput: Bool?
    public var vision: Bool?
    public var attachments: Bool?
    public var openWeights: Bool?
    public var minimumContextWindow: Int?
    public var minimumMaxOutputTokens: Int?
    /// Deprecated models are excluded unless asked for.
    public var includeDeprecated: Bool = false
    public var featuredProviderIDs: [String] = []

    public init(
        providerID: String? = nil,
        query: String? = nil,
        reasoning: Bool? = nil,
        toolCalling: Bool? = nil,
        structuredOutput: Bool? = nil,
        vision: Bool? = nil,
        attachments: Bool? = nil,
        openWeights: Bool? = nil,
        minimumContextWindow: Int? = nil,
        minimumMaxOutputTokens: Int? = nil,
        includeDeprecated: Bool = false,
        featuredProviderIDs: [String] = []
    ) {
        self.providerID = providerID
        self.query = query
        self.reasoning = reasoning
        self.toolCalling = toolCalling
        self.structuredOutput = structuredOutput
        self.vision = vision
        self.attachments = attachments
        self.openWeights = openWeights
        self.minimumContextWindow = minimumContextWindow
        self.minimumMaxOutputTokens = minimumMaxOutputTokens
        self.includeDeprecated = includeDeprecated
        self.featuredProviderIDs = featuredProviderIDs
    }

    func matches(_ model: CatalogModel, provider: CatalogProvider) -> Bool {
        if !includeDeprecated, !model.status.isSelectable { return false }
        if let reasoning, model.capabilities.reasoning != reasoning { return false }
        if let toolCalling, model.capabilities.toolCalling != toolCalling { return false }
        if let structuredOutput, model.capabilities.structuredOutput != structuredOutput { return false }
        if let vision, model.capabilities.vision != vision { return false }
        if let attachments, model.capabilities.attachments != attachments { return false }
        if let openWeights, model.capabilities.openWeights != openWeights { return false }
        if let minimum = minimumContextWindow, (model.limits.context ?? 0) < minimum { return false }
        if let minimum = minimumMaxOutputTokens, (model.limits.output ?? 0) < minimum { return false }
        if let query = query.map(LingXiModelCatalog.normalized), !query.isEmpty {
            let haystacks = [model.id, model.name, model.family ?? "", model.overview ?? "", provider.id, provider.name]
                .map(LingXiModelCatalog.normalized)
            if !haystacks.contains(where: { $0.contains(query) }) { return false }
        }
        return true
    }
}

/// The one ordering rule this catalog publishes and every reader applies.
///
/// Case-insensitive, digit runs compared as numbers so `GPT-5` precedes
/// `GPT-10`, a number before a word at the same position, and a shorter name
/// before its extension. The publisher sorts by this rule before writing the
/// document, so a listing never depends on how the upstream happened to iterate.
public enum ModelCatalogOrdering {
    /// Compares two display names, falling back to the identifier when the names
    /// are equal — the tie-break that keeps a sort total.
    public static func displayName(_ lhsName: String, _ lhsID: String,
                                   _ rhsName: String, _ rhsID: String) -> ComparisonResult {
        let result = compare(lhsName, rhsName)
        if result != .orderedSame { return result }
        if lhsID == rhsID { return .orderedSame }
        return lhsID < rhsID ? .orderedAscending : .orderedDescending
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = tokens(lhs)
        let right = tokens(rhs)
        for index in 0..<min(left.count, right.count) {
            let result = compareToken(left[index], right[index])
            if result != .orderedSame { return result }
        }
        if left.count == right.count { return .orderedSame }
        return left.count < right.count ? .orderedAscending : .orderedDescending
    }

    private enum Token: Equatable {
        case number(Int, String)
        case text(String)

        var raw: String {
            switch self {
            case let .number(_, digits): return digits
            case let .text(value): return value
            }
        }
    }

    private static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var digits = ""
        var word = ""
        for character in text {
            if character.isNumber, character.isASCII {
                if !word.isEmpty { result.append(.text(word.lowercased())); word = "" }
                digits.append(character)
            } else {
                if !digits.isEmpty { result.append(.number(Int(digits) ?? 0, digits)); digits = "" }
                word.append(character)
            }
        }
        if !digits.isEmpty { result.append(.number(Int(digits) ?? 0, digits)) }
        if !word.isEmpty { result.append(.text(word.lowercased())) }
        return result
    }

    private static func compareToken(_ lhs: Token, _ rhs: Token) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (.number(a, rawA), .number(b, rawB)):
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
            return rawA == rawB ? .orderedSame : (rawA < rawB ? .orderedAscending : .orderedDescending)
        case (.number, .text):
            return .orderedAscending
        case (.text, .number):
            return .orderedDescending
        case let (.text(a), .text(b)):
            if a == b { return .orderedSame }
            return a < b ? .orderedAscending : .orderedDescending
        }
    }
}
