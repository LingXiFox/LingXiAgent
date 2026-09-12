import Foundation
import LingXiProtocol

/// Merges the three independent answers about a model into one list.
///
/// The three questions are deliberately kept apart:
///
///   1. **Registry catalog** — what exists upstream and what LingXi knows about
///      it (protocol, capabilities, quirks, status). Account-independent.
///   2. **Account discovery** — what *this* account can actually reach with its
///      own credential. When present it is the sole authority on availability:
///      a model the registry lists but the account cannot reach is not offered,
///      and a model the account can reach but the registry has never seen is
///      still offered.
///   3. **Runtime support** — what LingXi can execute. A product the runtime has
///      not implemented is never presented as runnable, however well described.
///
/// Metadata resolution follows the same separation: the account decides
/// *whether* a model appears, the registry decides *how much we know* about it.
public enum ModelAvailabilityResolver {

    /// Fallback limits used only when neither the registry nor the upstream
    /// listing stated a value. They are a last resort for a UI that needs a
    /// number, not a claim about the model.
    public enum Fallback {
        public static let contextWindow = 128_000
        public static let maxOutputTokens = 4_096
    }

    public struct Outcome: Sendable, Equatable {
        /// Models to present, already filtered and ordered.
        public let models: [ProviderModelInfo]
        /// Model IDs withheld because their registry status is deprecated or
        /// retired and compatibility mode is off. Retained so callers can
        /// explain the omission or offer an opt-in.
        public let withheldByStatus: [String]
        /// True when the product is known to the registry but not implemented
        /// by the runtime, so nothing is offered regardless of metadata.
        public let runtimeUnsupported: Bool
        /// True when deprecated/retired models had to be shown because they are
        /// all the account can reach.
        public let fellBackToLegacyOnly: Bool

        public init(
            models: [ProviderModelInfo],
            withheldByStatus: [String] = [],
            runtimeUnsupported: Bool = false,
            fellBackToLegacyOnly: Bool = false
        ) {
            self.models = models
            self.withheldByStatus = withheldByStatus
            self.runtimeUnsupported = runtimeUnsupported
            self.fellBackToLegacyOnly = fellBackToLegacyOnly
        }

        public static let empty = Outcome(models: [])
    }

    /// Resolves the selectable models for one product.
    ///
    /// - Parameters:
    ///   - accountModels: Models discovered against the user's own account.
    ///     Empty when discovery has not run or the product is account-independent.
    ///   - registryModels: Models published for this product in the registry
    ///     catalog.
    ///   - compatibilityMode: When true, deprecated and retired models are
    ///     offered alongside current ones.
    public static func resolve(
        product: RegistryProduct,
        registryModels: [RegistryModelRecord],
        accountModels: [DiscoveredRemoteModel],
        isConfigured: Bool,
        compatibilityMode: Bool = false,
        aggregateCanonicalModels: Bool = false
    ) -> Outcome {
        // A product the runtime cannot execute is never offered, however much
        // the catalog knows about it.
        guard product.runtime.isRunnable else {
            return Outcome(models: [], runtimeUnsupported: true)
        }

        let registryIndex = Dictionary(
            registryModels.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Build the candidate list. Account discovery, when it produced
        // anything, is the authority on availability.
        var candidates: [Candidate] = []

        if !accountModels.isEmpty {
            if aggregateCanonicalModels {
                let groups = CanonicalModelParser.groupModels(accountModels)
                for group in groups {
                    // Upstream first-party visibility metadata determines selectability:
                    // models marked "hide" or "disabled" are preserved in listing and cache verbatim,
                    // but withheld from user selectable models.
                    guard group.visibility.lowercased() != "hide" && group.visibility.lowercased() != "disabled" else { continue }
                    let record = registryIndex[group.id] ?? registryIndex[group.primaryUpstreamModelID]
                    let synthesized = DiscoveredRemoteModel(
                        id: group.primaryUpstreamModelID,
                        displayName: group.displayName,
                        priority: 100,
                        visibility: group.visibility,
                        isDefault: false,
                        supportedReasoningEfforts: group.supportedReasoningEfforts,
                        minimalClientVersion: nil,
                        contextWindow: group.contextWindow,
                        maxOutputTokens: group.maxOutputTokens,
                        toolCalling: true,
                        vision: false,
                        metadataIncomplete: false,
                        upstreamModelID: group.primaryUpstreamModelID,
                        displayNameSource: "canonical",
                        canonicalModelID: group.id,
                        backendVariant: "standard"
                    )
                    candidates.append(
                        Candidate(
                            discovered: synthesized,
                            record: record,
                            allVariants: group.variants.map(\.upstreamModelID)
                        )
                    )
                }
            } else {
                for model in accountModels {
                    guard model.visibility.lowercased() != "hide" && model.visibility.lowercased() != "disabled" else { continue }
                    let record = registryIndex[model.id]
                    candidates.append(Candidate(discovered: model, record: record))
                }
            }
        } else {
            // No account view: fall back to what the registry publishes. These
            // are advertised, not confirmed reachable, so they are marked
            // unconfigured when the product itself is not configured.
            for record in registryModels {
                candidates.append(Candidate(record: record, isConfigured: isConfigured))
            }
        }

        guard !candidates.isEmpty else { return .empty }

        // Partition by registry status. A model the registry has never seen has
        // no status and is treated as new rather than as legacy: it stays
        // visible so an upstream addition needs no LingXi release to appear.
        var current: [Candidate] = []
        var legacy: [Candidate] = []
        for candidate in candidates {
            switch candidate.status {
            case .deprecated, .retired:
                legacy.append(candidate)
            case .active, .preview, .unknown:
                current.append(candidate)
            }
        }

        var withheld: [String] = []
        var selected = current
        var fellBack = false

        if !legacy.isEmpty {
            if compatibilityMode {
                selected = current + legacy
            } else if current.isEmpty {
                // The account can only reach superseded models. Showing nothing
                // would leave the user with no model at all, so they are shown
                // — this is the documented exception to hiding deprecated ones.
                selected = legacy
                fellBack = true
            } else {
                withheld = legacy.map(\.modelID)
            }
        }

        selected.sort(by: ordering)

        let models = selected.map { candidate in
            ProviderModelInfo(
                id: "\(product.id)/\(candidate.modelID)",
                providerID: product.id,
                modelID: candidate.modelID,
                displayName: candidate.displayName,
                contextWindow: candidate.contextWindow,
                maxOutputTokens: candidate.maxOutputTokens,
                reasoning: candidate.reasoning,
                configured: isConfigured,
                metadataIncomplete: candidate.metadataIncomplete,
                canonicalModelID: candidate.canonicalModelID,
                backendVariant: candidate.backendVariant,
                backendVariants: candidate.backendVariants
            )
        }

        return Outcome(
            models: models,
            withheldByStatus: withheld,
            runtimeUnsupported: false,
            fellBackToLegacyOnly: fellBack
        )
    }

    /// Current models first, then ones we know nothing about, then by ID so the
    /// order is stable across launches.
    private static func ordering(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let lhsRank = rank(lhs.status)
        let rhsRank = rank(rhs.status)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.modelID < rhs.modelID
    }

    private static func rank(_ status: RegistryModelStatus) -> Int {
        switch status {
        case .active: return 0
        case .preview: return 1
        case .unknown: return 2
        case .deprecated: return 3
        case .retired: return 4
        }
    }

    // MARK: - Candidate

    /// One model under consideration, with metadata already merged from the
    /// registry record and the upstream listing.
    private struct Candidate {
        let modelID: String
        let displayName: String
        let status: RegistryModelStatus
        let contextWindow: Int
        let maxOutputTokens: Int
        let reasoning: Bool
        let metadataIncomplete: Bool
        let canonicalModelID: String?
        let backendVariant: String?
        let backendVariants: [String]?

        /// From an account discovery result, optionally enriched by a registry
        /// record for the same model.
        init(discovered: DiscoveredRemoteModel, record: RegistryModelRecord?, allVariants: [String]? = nil) {
            modelID = discovered.id
            displayName = record?.displayName ?? discovered.displayName
            status = record?.modelStatus ?? .unknown
            // A registry record is preferred for limits, but a discovered value
            // is better than a fallback, and the fallback is better than zero.
            contextWindow = record?.capabilities.contextWindow
                ?? discovered.contextWindow
                ?? Fallback.contextWindow
            maxOutputTokens = record?.capabilities.maxOutputTokens
                ?? discovered.maxOutputTokens
                ?? Fallback.maxOutputTokens
            reasoning = record?.capabilities.reasoning
                ?? discovered.capabilities?.reasoning
                ?? !discovered.supportedReasoningEfforts.isEmpty
            // The registry not describing a model is exactly what
            // metadataIncomplete means.
            metadataIncomplete = record?.metadataIncomplete ?? true
            canonicalModelID = discovered.canonicalModelID
            backendVariant = discovered.backendVariant
            backendVariants = allVariants ?? (discovered.canonicalModelID != nil ? [discovered.id] : nil)
        }

        /// From a registry record alone, with no account view.
        init(record: RegistryModelRecord, isConfigured: Bool) {
            modelID = record.id
            displayName = record.displayName
            status = record.modelStatus
            contextWindow = record.capabilities.contextWindow ?? Fallback.contextWindow
            maxOutputTokens = record.capabilities.maxOutputTokens ?? Fallback.maxOutputTokens
            reasoning = record.capabilities.reasoning ?? false
            metadataIncomplete = record.metadataIncomplete
            canonicalModelID = nil
            backendVariant = nil
            backendVariants = nil
        }
    }
}
