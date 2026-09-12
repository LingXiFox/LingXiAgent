import Foundation
import LingXiProtocol

/// The execution/reasoning character of a backend variant.
public enum BackendVariantKind: String, Codable, Sendable, Equatable {
    /// Standard execution with balanced latency and reasoning.
    case standard
    /// Fast response optimized, reasoning disabled or minimized.
    case instant
    /// Deep reasoning / thinking mode enabled.
    case thinking
    /// Specialized or compact variant.
    case specialized
}

/// A specific backend variant of a canonical model.
///
/// Preserves the upstream vendor's model ID verbatim, while isolating execution
/// profile and reasoning characteristics from the model's canonical identity.
public struct BackendModelVariant: Codable, Sendable, Equatable, Identifiable {
    public var id: String { upstreamModelID }

    /// The exact upstream slug, 100% verbatim.
    public let upstreamModelID: String

    /// The variant category.
    public let variantKind: BackendVariantKind

    /// Default reasoning effort associated with this variant.
    public let defaultReasoningEffort: ReasoningEffort?

    /// Supported reasoning efforts for this variant.
    public let supportedReasoningEfforts: [ReasoningEffort]

    /// Whether this variant requires deep reasoning.
    public let reasoning: Bool

    public init(
        upstreamModelID: String,
        variantKind: BackendVariantKind,
        defaultReasoningEffort: ReasoningEffort? = nil,
        supportedReasoningEfforts: [ReasoningEffort] = [],
        reasoning: Bool = false
    ) {
        self.upstreamModelID = upstreamModelID
        self.variantKind = variantKind
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.reasoning = reasoning
    }
}

/// A Canonical Model representation that aggregates one or more backend variants
/// under a unified model identity without inventing display names.
public struct CanonicalModelGroup: Codable, Sendable, Equatable, Identifiable {
    /// The canonical identity ID (e.g., "gpt-5-6" or "gpt-5-5").
    public let id: String

    /// The unadorned display name from upstream (e.g. "GPT-5.6 Sol").
    /// Never synthesized or polluted with "-instant" or "-thinking".
    public let displayName: String

    /// The primary / standard variant's upstream model ID.
    public let primaryUpstreamModelID: String

    /// All available backend variants for this canonical model.
    public let variants: [BackendModelVariant]

    /// Union of all supported reasoning efforts across variants.
    public let supportedReasoningEfforts: [ReasoningEffort]

    /// Context window limit.
    public let contextWindow: Int?

    /// Maximum output tokens.
    public let maxOutputTokens: Int?

    /// Whether any variant of this model supports reasoning.
    public let supportsReasoning: Bool

    /// Upstream visibility metadata (e.g., "list", "hide", "public").
    public let visibility: String

    public init(
        id: String,
        displayName: String,
        primaryUpstreamModelID: String,
        variants: [BackendModelVariant],
        supportedReasoningEfforts: [ReasoningEffort] = [],
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsReasoning: Bool = false,
        visibility: String = "list"
    ) {
        self.id = id
        self.displayName = displayName
        self.primaryUpstreamModelID = primaryUpstreamModelID
        self.variants = variants
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsReasoning = supportsReasoning
        self.visibility = visibility
    }

    /// Resolves the most appropriate verbatim upstream model ID for a requested effort or variant.
    public func resolveUpstreamModelID(for effort: ReasoningEffort?) -> String {
        guard let effort else { return primaryUpstreamModelID }

        switch effort {
        case .off:
            // Prefer instant variant if available
            if let instant = variants.first(where: { $0.variantKind == .instant }) {
                return instant.upstreamModelID
            }
            return primaryUpstreamModelID
        case .minimal, .low, .medium, .high, .xhigh, .max, .ultra:
            // Prefer thinking variant if available
            if let thinking = variants.first(where: { $0.variantKind == .thinking }) {
                return thinking.upstreamModelID
            }
            return primaryUpstreamModelID
        case .auto:
            return primaryUpstreamModelID
        }
    }
}

/// Parser and classifier for decomposing model slugs into canonical identities and backend variants.
public enum CanonicalModelParser {

    /// Decomposes a slug into its canonical identifier and variant kind.
    ///
    /// Examples:
    /// - "gpt-5-6" -> canonical "gpt-5-6", kind .standard
    /// - "gpt-5-6-instant" -> canonical "gpt-5-6", kind .instant
    /// - "gpt-5-6-thinking" -> canonical "gpt-5-6", kind .thinking
    /// - "gpt-5-6-t-mini" -> canonical "gpt-5-6-mini", kind .thinking
    /// - "claude-3-5-sonnet" -> canonical "claude-3-5-sonnet", kind .standard
    public static func parseSlug(_ slug: String) -> (canonicalID: String, kind: BackendVariantKind) {
        let lower = slug.lowercased()

        // 1. Instant variants
        if lower.hasSuffix("-instant") {
            let base = String(slug.dropLast("-instant".count))
            return (base, .instant)
        }
        if lower.contains("-instant-") {
            let base = slug.replacingOccurrences(of: "-instant-", with: "-")
            return (base, .instant)
        }

        // 2. Thinking variants
        if lower.hasSuffix("-thinking") {
            let base = String(slug.dropLast("-thinking".count))
            return (base, .thinking)
        }
        if lower.contains("-thinking-") {
            let base = slug.replacingOccurrences(of: "-thinking-", with: "-")
            return (base, .thinking)
        }
        // Handle shorthand "-t-" like "gpt-5-6-t-mini" -> base "gpt-5-6-mini"
        if lower.contains("-t-") {
            let base = slug.replacingOccurrences(of: "-t-", with: "-")
            return (base, .thinking)
        }

        // 3. Specialized / compact variants
        if lower.hasSuffix("-compact") || lower.hasSuffix("-openai-compact") {
            return (slug, .specialized)
        }

        return (slug, .standard)
    }

    /// Strips variant noise from a display name so it remains the clean upstream model title.
    /// Does not invent names; only sanitizes suffixes like " Thinking" or " Instant" if present.
    public static func cleanDisplayName(_ name: String, fallbackSlug: String) -> String {
        var clean = name
        let suffixes = [" Thinking", " Instant", " (Thinking)", " (Instant)"]
        for suffix in suffixes {
            if clean.hasSuffix(suffix) {
                clean = String(clean.dropLast(suffix.count))
            }
        }
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackSlug : trimmed
    }

    /// Groups a flat list of discovered models into canonical model groups.
    ///
    /// Preserves all upstreamModelIDs verbatim.
    public static func groupModels(_ models: [DiscoveredRemoteModel]) -> [CanonicalModelGroup] {
        var groups: [String: [DiscoveredRemoteModel]] = [:]
        var canonicalOrder: [String] = []

        for model in models {
            let (canonicalID, _) = parseSlug(model.upstreamModelID ?? model.id)
            if groups[canonicalID] == nil {
                canonicalOrder.append(canonicalID)
                groups[canonicalID] = []
            }
            groups[canonicalID]?.append(model)
        }

        var result: [CanonicalModelGroup] = []

        for canonicalID in canonicalOrder {
            guard let groupModels = groups[canonicalID], !groupModels.isEmpty else { continue }

            // Find primary model (standard preferred, else first)
            let primary = groupModels.first(where: {
                let (_, kind) = parseSlug($0.upstreamModelID ?? $0.id)
                return kind == .standard
            }) ?? groupModels[0]

            let primarySlug = primary.upstreamModelID ?? primary.id
            let cleanName = cleanDisplayName(primary.displayName, fallbackSlug: primarySlug)

            var variants: [BackendModelVariant] = []
            var allEfforts: Set<ReasoningEffort> = []
            var anyReasoning = false
            var maxContext: Int? = nil
            var maxOutput: Int? = nil

            for model in groupModels {
                let verbatimSlug = model.upstreamModelID ?? model.id
                let (_, kind) = parseSlug(verbatimSlug)

                let modelReasoning = (model.capabilities?.reasoning ?? false)
                    || !model.supportedReasoningEfforts.isEmpty

                if modelReasoning { anyReasoning = true }

                let efforts = model.supportedReasoningEfforts
                for e in efforts { allEfforts.insert(e) }

                let defaultEffort: ReasoningEffort? = modelReasoning ? (efforts.first ?? .auto) : nil

                variants.append(
                    BackendModelVariant(
                        upstreamModelID: verbatimSlug,
                        variantKind: kind,
                        defaultReasoningEffort: defaultEffort,
                        supportedReasoningEfforts: efforts,
                        reasoning: modelReasoning
                    )
                )

                if let cw = model.contextWindow {
                    maxContext = max(maxContext ?? 0, cw)
                }
                if let mo = model.maxOutputTokens {
                    maxOutput = max(maxOutput ?? 0, mo)
                }
            }

            result.append(
                CanonicalModelGroup(
                    id: canonicalID,
                    displayName: cleanName,
                    primaryUpstreamModelID: primarySlug,
                    variants: variants,
                    supportedReasoningEfforts: Array(allEfforts).sorted(),
                    contextWindow: maxContext,
                    maxOutputTokens: maxOutput,
                    supportsReasoning: anyReasoning,
                    visibility: primary.visibility
                )
            )
        }

        return result
    }
}
