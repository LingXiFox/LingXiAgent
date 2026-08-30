import Testing
@testable import LingXiCore

struct BuiltinProviderCatalogTests {
    @Test func catalogHasStableUniqueDefinitionsWithoutUnverifiedClaims() {
        let definitions = BuiltinProviderCatalog.definitions
        #expect(definitions.count == 22)
        #expect(Set(definitions.map(\.id)).count == definitions.count)
        #expect(definitions.allSatisfy { !$0.id.isEmpty && !$0.displayName.isEmpty })
        #expect(definitions.allSatisfy { $0.status != .declared || !$0.officialSources.isEmpty })
        #expect(definitions.filter { $0.officialSources.isEmpty }.allSatisfy { $0.defaultBaseURL == nil && $0.supportedWires.isEmpty })
        #expect(BuiltinProviderCatalog.definition(id: "antigravity")?.status == .unsupported)
    }
}
