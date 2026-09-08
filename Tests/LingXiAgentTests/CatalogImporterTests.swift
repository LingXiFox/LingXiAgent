import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

struct CatalogImporterTests {
    @Test func schemaValidatorRejectsDangerousPayloads() {
        #expect(throws: CatalogValidationError.self) {
            try CatalogSchemaValidator.validateStringField("<script>alert(1)</script>", name: "model.id")
        }
        #expect(throws: CatalogValidationError.self) {
            try CatalogSchemaValidator.validateStringField("/bin/bash -c rm", name: "endpoint")
        }
    }

    @Test func schemaValidatorEnforcesSafeURLSchemes() {
        #expect(throws: CatalogValidationError.self) {
            try CatalogSchemaValidator.validateURLString("javascript:alert(1)", name: "endpoint")
        }
        #expect(throws: CatalogValidationError.self) {
            try CatalogSchemaValidator.validateURLString("file:///etc/passwd", name: "endpoint")
        }
        #expect(throws: Never.self) {
            try CatalogSchemaValidator.validateURLString("https://api.openai.com/v1", name: "endpoint")
            try CatalogSchemaValidator.validateURLString("http://localhost:11434/v1", name: "endpoint")
        }
    }

    @Test func schemaValidatorDetectsDuplicateModelIDs() {
        let models: [String: UpstreamModel] = [
            "m1": UpstreamModel(id: "dup-id", name: "Model 1"),
            "m2": UpstreamModel(id: "dup-id", name: "Model 2")
        ]
        let provider = UpstreamProvider(id: "prov", name: "Provider", models: models)
        let snapshot = UpstreamCatalogSnapshot(version: "1.0", generatedAt: "2025-01-01", providers: ["prov": provider])

        #expect(throws: CatalogValidationError.self) {
            try CatalogSchemaValidator.validateUpstreamSnapshot(snapshot)
        }
    }

    @Test func catalogImporterMergesUpstreamAndOverlaysWithVerifiedPrecedence() throws {
        let manifest = CatalogManifest(
            upstreamSource: "https://models.dev/test",
            upstreamRevision: "2025.01",
            snapshotDate: "2025-01-01",
            sha256: "test-hash",
            importerSchemaVersion: 2,
            generatedTimestamp: "2025-01-01"
        )

        let upstreamModel = UpstreamModel(
            id: "gpt-4o",
            name: "Upstream GPT-4o",
            contextWindow: 128_000,
            maxOutputTokens: 16_384,
            vision: true,
            toolCalling: true,
            parallelToolCalling: true,
            reasoning: false,
            structuredOutput: true,
            pricing: UpstreamPricing(input: 2.5, output: 10.0, cacheRead: 1.25, cacheWrite: 2.5)
        )
        let upstreamProvider = UpstreamProvider(id: "openai", name: "OpenAI", models: ["gpt-4o": upstreamModel])
        let snapshot = UpstreamCatalogSnapshot(version: "1.0", generatedAt: "2025-01-01", providers: ["openai": upstreamProvider])

        // Overlay with custom display name and custom reasoning capability (verified override)
        let overlayModel = OverlayModel(
            upstreamID: "gpt-4o",
            id: "gpt-4o",
            displayName: "LingXi GPT-4o Verified",
            reasoningCapability: ReasoningCapability(
                mode: .effort,
                supportedEfforts: [.low, .high],
                defaultEffort: .low,
                emitsVisibleReasoning: false,
                emitsReasoningSummary: true,
                coarseMappings: [:]
            )
        )
        let overlayProduct = OverlayProduct(
            id: "openai-api",
            displayName: "OpenAI API",
            type: "cloudAPI",
            protocolFamily: "openai_responses",
            endpoint: "https://api.openai.com/v1",
            authMethods: ["bearerToken"],
            verificationStatus: "verified",
            models: [overlayModel]
        )
        let overlayDoc = OverlayDocument(vendor: "openai", products: [overlayProduct])

        let merged = try CatalogImporter.merge(snapshot: snapshot, manifest: manifest, overlays: [overlayDoc])

        #expect(merged.products.count == 1)
        guard let prod = merged.products.first else {
            Issue.record("Expected product in merged catalog")
            return
        }
        #expect(prod.id == "openai-api")
        #expect(prod.models.count == 1)

        guard let model = prod.models.first else {
            Issue.record("Expected model in merged product")
            return
        }
        // Verified overlay display name takes precedence over upstream name
        #expect(model.displayName == "LingXi GPT-4o Verified")
        // Upstream hardware limits are inherited
        #expect(model.contextWindow == 128_000)
        #expect(model.maxOutputTokens == 16_384)
        // Pricing is inherited
        #expect(model.pricing?.input == 2.5)
        // Reasoning capability from verified overlay is preserved
        #expect(model.reasoningCapability?.mode == .effort)
    }

    @Test func catalogGenerationIsDeterministic() throws {
        let manifest = CatalogManifest(
            upstreamSource: "https://models.dev/test",
            upstreamRevision: "2025.01",
            snapshotDate: "2025-01-01",
            sha256: "test-hash",
            importerSchemaVersion: 2,
            generatedTimestamp: "2025-01-01"
        )
        let snapshot = UpstreamCatalogSnapshot(version: "1.0", generatedAt: "2025-01-01", providers: [:])
        let overlay1 = OverlayDocument(vendor: "b_vendor", products: [
            OverlayProduct(id: "z_prod", displayName: "Z", type: "cloudAPI", protocolFamily: "openai_chat", endpoint: "https://z.com", authMethods: ["apiKey"], verificationStatus: "verified")
        ])
        let overlay2 = OverlayDocument(vendor: "a_vendor", products: [
            OverlayProduct(id: "a_prod", displayName: "A", type: "cloudAPI", protocolFamily: "openai_chat", endpoint: "https://a.com", authMethods: ["apiKey"], verificationStatus: "verified")
        ])

        // Pass in different order
        let merged1 = try CatalogImporter.merge(snapshot: snapshot, manifest: manifest, overlays: [overlay1, overlay2])
        let merged2 = try CatalogImporter.merge(snapshot: snapshot, manifest: manifest, overlays: [overlay2, overlay1])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data1 = try encoder.encode(merged1)
        let data2 = try encoder.encode(merged2)

        #expect(data1 == data2)
        #expect(merged1.products.first?.id == "a_prod")
        #expect(merged1.products.last?.id == "z_prod")
    }

    @Test func compatibilityMatrixGeneratesValidMarkdown() {
        guard let catalog = BuiltinProviderCatalog.catalog else {
            Issue.record("Generated catalog could not be loaded")
            return
        }
        let md = CatalogImporter.generateCompatibilityMatrixMarkdown(catalog: catalog)
        #expect(md.contains("# LingXiAgent Provider Compatibility Matrix (v2)"))
        #expect(md.contains("| `openai-api` |"))
        #expect(md.contains("| `openai-codex` |"))
        #expect(md.contains("| `gemini-code-assist` |"))
        #expect(md.contains("| `antigravity` |"))
        #expect(md.contains("| `deepseek-api` |"))
    }
}
