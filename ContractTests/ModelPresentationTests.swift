import Foundation
import LingXiFrontendProtocol
import LingXiPluginABI
import Testing

private func identity(
    models: [String],
    details: [ProviderModel]?
) -> ProviderIdentity {
    ProviderIdentity(
        id: "provider.test", models: models, supportsParallelToolCalls: false,
        toolResultPlacement: "anywhereInHistory", modelDetails: details
    )
}

@Test("a provider may declare ordered thinking levels and a default for each model")
func providerDeclarationAcceptsThinkingLevels() throws {
    let declaration = identity(
        models: ["model-a"],
        details: [ProviderModel(
            id: "model-a",
            thinkingLevels: [
                ProviderThinkingLevel(id: "low", label: "低"),
                ProviderThinkingLevel(id: "medium", label: "中"),
                ProviderThinkingLevel(id: "high", label: "高"),
            ],
            defaultThinkingLevel: "medium"
        )]
    )
    try declaration.validate()
}

@Test("provider metadata must list exactly the same model ids in the same order")
func providerDeclarationRejectsModelDrift() {
    let declaration = identity(
        models: ["model-a", "model-b"],
        details: [ProviderModel(id: "model-b")]
    )
    #expect(throws: ProviderDeclarationError.modelDetailsMismatch) {
        try declaration.validate()
    }
}

@Test("a default thinking level must belong to the declared levels")
func providerDeclarationRejectsUnknownDefault() {
    let declaration = identity(
        models: ["model-a"],
        details: [ProviderModel(
            id: "model-a",
            thinkingLevels: [ProviderThinkingLevel(id: "low", label: "低")],
            defaultThinkingLevel: "high"
        )]
    )
    #expect(throws: ProviderDeclarationError.unknownDefaultThinkingLevel(model: "model-a", level: "high")) {
        try declaration.validate()
    }
}

@Test("duplicate thinking level ids are refused instead of silently collapsed")
func providerDeclarationRejectsDuplicateLevels() {
    let declaration = identity(
        models: ["model-a"],
        details: [ProviderModel(
            id: "model-a",
            thinkingLevels: [
                ProviderThinkingLevel(id: "low", label: "低"),
                ProviderThinkingLevel(id: "low", label: "更低"),
            ]
        )]
    )
    #expect(throws: ProviderDeclarationError.duplicateThinkingLevel(model: "model-a", level: "low")) {
        try declaration.validate()
    }
}

@Test("model details round-trip through the frontend protocol without changing models")
func modelDetailsRoundTrip() throws {
    let summary = ModelSummary(
        id: "model-a", provider: "provider.test",
        thinkingLevels: [
            ModelThinkingLevel(id: "low", label: "低"),
            ModelThinkingLevel(id: "high", label: "高"),
        ],
        defaultThinkingLevel: "low"
    )
    var reply = FrontendReply(id: 7, ok: true)
    reply.models = ["model-a"]
    reply.modelDetails = [summary]

    let decoded = try JSONDecoder().decode(FrontendReply.self, from: JSONEncoder().encode(reply))
    #expect(decoded.models == ["model-a"])
    #expect(decoded.modelDetails == [summary])
}
