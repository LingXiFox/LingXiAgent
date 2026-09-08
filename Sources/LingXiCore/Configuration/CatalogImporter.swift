import Foundation
import LingXiProtocol

public enum CatalogImporterError: Error, LocalizedError, Equatable {
    case manifestNotFound(String)
    case snapshotNotFound(String)
    case overlayDecodingFailed(file: String, reason: String)
    case upstreamModelNotFound(productID: String, upstreamID: String)
    case schemaValidationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .manifestNotFound(let p): "Manifest file not found at: \(p)"
        case .snapshotNotFound(let p): "Upstream snapshot file not found at: \(p)"
        case .overlayDecodingFailed(let file, let reason): "Failed to decode overlay '\(file)': \(reason)"
        case .upstreamModelNotFound(let p, let u): "Product '\(p)' references unknown upstream model '\(u)'"
        case .schemaValidationFailed(let reason): "Catalog schema validation failed: \(reason)"
        }
    }
}

public enum CatalogImporter {
    public static func loadManifest(from url: URL) throws -> CatalogManifest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CatalogImporterError.manifestNotFound(url.path)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CatalogManifest.self, from: data)
    }

    public static func loadSnapshot(from url: URL) throws -> UpstreamCatalogSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CatalogImporterError.snapshotNotFound(url.path)
        }
        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(UpstreamCatalogSnapshot.self, from: data)
        try CatalogSchemaValidator.validateUpstreamSnapshot(snapshot)
        return snapshot
    }

    public static func loadOverlays(from directoryURL: URL) throws -> [OverlayDocument] {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
            return []
        }
        var overlays: [OverlayDocument] = []
        for file in files.sorted() where file.hasSuffix(".json") {
            let fileURL = directoryURL.appendingPathComponent(file)
            let data = try Data(contentsOf: fileURL)
            do {
                let overlay = try JSONDecoder().decode(OverlayDocument.self, from: data)
                overlays.append(overlay)
            } catch {
                throw CatalogImporterError.overlayDecodingFailed(file: file, reason: error.localizedDescription)
            }
        }
        return overlays
    }

    public static func merge(
        snapshot: UpstreamCatalogSnapshot,
        manifest: CatalogManifest,
        overlays: [OverlayDocument]
    ) throws -> GeneratedProviderCatalog {
        var generatedProducts: [GeneratedProduct] = []

        for doc in overlays {
            for prod in doc.products {
                try CatalogSchemaValidator.validateStringField(prod.id, name: "product.id", maxLength: 64)
                try CatalogSchemaValidator.validateStringField(prod.displayName, name: "product.displayName", maxLength: 128)
                try CatalogSchemaValidator.validateURLString(prod.endpoint, name: "product.endpoint")

                var generatedModels: [GeneratedModel] = []

                for m in prod.models {
                    try CatalogSchemaValidator.validateStringField(m.id, name: "model.id", maxLength: 128)

                    // Find upstream model metadata if available
                    let upstreamModel = snapshot.providers[doc.vendor]?.models[m.upstreamID]
                        ?? snapshot.providers.values.flatMap(\.models.values).first(where: { $0.id == m.upstreamID })

                    let displayName = m.displayName ?? upstreamModel?.name ?? m.id
                    let contextWindow = upstreamModel?.contextWindow
                    let maxOutputTokens = upstreamModel?.maxOutputTokens
                    let toolCalling = m.toolCall ?? upstreamModel?.toolCalling ?? true
                    let parallelTools = upstreamModel?.parallelToolCalling ?? (toolCalling && prod.protocolFamily != "minimax")
                    let vision = m.vision ?? upstreamModel?.vision ?? false
                    let cache = m.cache ?? (upstreamModel?.pricing?.cacheRead != nil)
                    let structuredOutput = upstreamModel?.structuredOutput ?? false
                    let pricing = upstreamModel?.pricing

                    let genModel = GeneratedModel(
                        id: m.id,
                        displayName: displayName,
                        upstreamID: m.upstreamID,
                        contextWindow: contextWindow,
                        maxOutputTokens: maxOutputTokens,
                        toolCalling: toolCalling,
                        parallelToolCalling: parallelTools,
                        vision: vision,
                        cache: cache,
                        reasoningCapability: m.reasoningCapability,
                        structuredOutput: structuredOutput,
                        pricing: pricing
                    )
                    generatedModels.append(genModel)
                }

                // Deterministic sort of models
                generatedModels.sort { $0.id < $1.id }

                let genProduct = GeneratedProduct(
                    id: prod.id,
                    vendor: doc.vendor,
                    displayName: prod.displayName,
                    type: prod.type,
                    protocolFamily: prod.protocolFamily,
                    endpoint: prod.endpoint,
                    authMethods: prod.authMethods.sorted(),
                    concurrencyLimit: prod.concurrencyLimit,
                    quirks: (prod.quirks ?? []).sorted(),
                    verificationStatus: prod.verificationStatus,
                    requiredAccountFields: (prod.requiredAccountFields ?? []).sorted(),
                    oauth: prod.oauth,
                    requestProfiles: prod.requestProfiles ?? [:],
                    modelDiscovery: prod.modelDiscovery ?? (prod.id == "openai-codex" ? .authenticatedRemote : .staticCatalog),
                    models: generatedModels
                )
                generatedProducts.append(genProduct)
            }
        }

        // Deterministic sort of products
        generatedProducts.sort { $0.id < $1.id }

        return GeneratedProviderCatalog(
            schemaVersion: 2,
            generatedAt: manifest.generatedTimestamp,
            manifest: manifest,
            products: generatedProducts
        )
    }

    public static func generateCatalogData(
        catalogDirectory: URL
    ) throws -> (catalog: GeneratedProviderCatalog, jsonData: Data) {
        let manifestURL = catalogDirectory.appendingPathComponent("upstream/manifest.json")
        let snapshotURL = catalogDirectory.appendingPathComponent("upstream/models-dev.snapshot.json")
        let overlaysURL = catalogDirectory.appendingPathComponent("overlays")

        let manifest = try loadManifest(from: manifestURL)
        let snapshot = try loadSnapshot(from: snapshotURL)
        let overlays = try loadOverlays(from: overlaysURL)

        let catalog = try merge(snapshot: snapshot, manifest: manifest, overlays: overlays)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(catalog)
        return (catalog, data)
    }

    public static func generateCompatibilityMatrixMarkdown(catalog: GeneratedProviderCatalog) -> String {
        var lines: [String] = []
        lines.append("# LingXiAgent Provider Compatibility Matrix (v2)")
        lines.append("")
        lines.append("> Auto-generated from generated/builtin-provider-catalog.json")
        lines.append("> Upstream Source: \(catalog.manifest.upstreamSource) (rev \(catalog.manifest.upstreamRevision))")
        lines.append("")
        lines.append("| Product | Vendor | Protocol | Auth | Model Discovery | OAuth Status | Models | Tools | Parallel Tools | Vision | Reasoning | Levels | Structured Output | Context | Max Output | Cache | Continuation | Profile | Status | Quirks |")
        lines.append("|:---|:---|:---|:---|:---|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---|:---:|:---|")

        for p in catalog.products {
            let authStr = p.authMethods.joined(separator: ", ")
            let discoveryStr: String
            if p.id == "openai-codex" || p.modelDiscovery == .authenticatedRemote {
                discoveryStr = "Authenticated ChatGPT Remote Catalog"
            } else if p.modelDiscovery == .endpoint {
                discoveryStr = "API Endpoint /models"
            } else if p.modelDiscovery == .local {
                discoveryStr = "Local Runtime Discovery"
            } else {
                discoveryStr = "Static / models.dev"
            }
            let oauthStatus = p.oauth != nil ? "✅ Ready" : "—"
            let modelCount = p.id == "openai-codex" ? "dynamic" : "\(p.models.count)"
            let hasTools = p.models.contains(where: \.toolCalling) || p.id == "openai-codex" ? "✅" : "❌"
            let hasParallel = p.models.contains(where: \.parallelToolCalling) || p.id == "openai-codex" ? "✅" : "❌"
            let hasVision = p.models.contains(where: \.vision) || p.id == "openai-codex" ? "✅" : "❌"
            let hasReasoning = p.models.contains(where: { $0.reasoningCapability != nil }) || p.id == "openai-codex" ? "🧠" : "❌"

            var levels: Set<String> = []
            for m in p.models {
                if let rc = m.reasoningCapability {
                    levels.formUnion(rc.supportedEfforts.map(\.rawValue))
                }
            }
            if p.id == "openai-codex" {
                levels.formUnion(["low", "medium", "high"])
            }
            let levelsStr = levels.isEmpty ? "—" : levels.sorted().joined(separator: ", ")

            let hasStructured = p.models.contains(where: \.structuredOutput) || p.id == "openai-codex" ? "✅" : "❌"
            let maxCtx = p.models.compactMap(\.contextWindow).max().map { "\($0 / 1000)k" } ?? (p.id == "openai-codex" ? "200k" : "—")
            let maxOut = p.models.compactMap(\.maxOutputTokens).max().map { "\($0 / 1000)k" } ?? (p.id == "openai-codex" ? "100k" : "—")
            let hasCache = p.models.contains(where: \.cache) || p.id == "openai-codex" ? "✅" : "❌"
            let continuation = p.protocolFamily == "openai_responses" ? "responses_api" : "stateless"
            let profileName = p.requestProfiles.keys.sorted().first ?? "default"
            let quirksStr = p.quirks.isEmpty ? "none" : p.quirks.joined(separator: ", ")

            lines.append("| `\(p.id)` | \(p.vendor) | `\(p.protocolFamily)` | \(authStr) | \(discoveryStr) | \(oauthStatus) | \(modelCount) | \(hasTools) | \(hasParallel) | \(hasVision) | \(hasReasoning) | \(levelsStr) | \(hasStructured) | \(maxCtx) | \(maxOut) | \(hasCache) | \(continuation) | `\(profileName)` | \(p.verificationStatus) | \(quirksStr) |")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }
}
