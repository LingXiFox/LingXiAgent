import Testing
@testable import LingXiCore

struct SymbolIndexTests {
    @Test func extractorFindsDeclarationsWithAttributesModifiersAndGenerics() {
        let symbols = SwiftSymbolExtractor().extract(
            projectRoot: "/project",
            path: "Sources/Service.swift",
            pageID: "service-page",
            source: """
            @MainActor public final class Service<Client> {
                required init(client: Client) {}
                public func run<T>(_ value: T) {}
                struct Result {}
            }
            extension Service {
                static func make() {}
            }
            protocol Worker {}
            actor Queue {}
            enum State {}
            typealias ID = String
            """
        )

        #expect(symbols.map(\.qualifiedName) == ["Service", "Service.init", "Service.run", "Service.Result", "Service", "Service.make", "Worker", "Queue", "State", "ID"])
        #expect(symbols.map(\.kind) == [.class, SymbolKind.`init`, .func, .struct, SymbolKind.`extension`, .func, .protocol, .actor, .enum, SymbolKind.`typealias`])
    }

    @Test func extractorIgnoresCommentsAndOrdinaryOrMultilineStrings() {
        let symbols = SwiftSymbolExtractor().extract(
            projectRoot: "/project",
            path: "Sources/Real.swift",
            pageID: "real-page",
            source: #"""
            // struct Commented {}
            let text = "func stringValue() {}"
            /* enum BlockComment {}
               actor AlsoCommented {} */
            let multiline = """
            class MultilineString {}
            """
            struct Real {}
            """#
        )

        #expect(symbols.map(\.qualifiedName) == ["Real"])
    }

    @Test func symbolIDsAreStableForUnchangedDeclarations() {
        let extractor = SwiftSymbolExtractor()
        let first = extractor.extract(projectRoot: "/project", path: "A.swift", pageID: "first", source: "struct Stable {}")
        let second = extractor.extract(projectRoot: "/project", path: "A.swift", pageID: "second", source: "struct Stable {}")

        #expect(first.first?.id == second.first?.id)
    }

    @Test func indexReplacesRemovesAndIsolatesProjects() async {
        let extractor = SwiftSymbolExtractor()
        let alpha = extractor.extract(projectRoot: "/alpha", path: "A.swift", pageID: "alpha-a", source: "struct Shared {}\nfunc alpha() {}")
        let beta = extractor.extract(projectRoot: "/beta", path: "B.swift", pageID: "beta-b", source: "struct Shared {}")
        let index = ProjectSymbolIndex()

        await index.replace(projectRoot: "/alpha", path: "A.swift", symbols: alpha)
        await index.replace(projectRoot: "/beta", symbols: beta)
        #expect(await index.exact(projectRoot: "/alpha", name: "Shared").map(\.path) == ["A.swift"])
        #expect(await index.prefix(projectRoot: "/alpha", prefix: "al").map(\.name) == ["alpha"])
        #expect(await index.symbols(projectRoot: "/alpha", pageID: "alpha-a").count == 2)
        #expect(await index.stats(projectRoot: "/alpha") == SymbolIndexStats(symbolCount: 2, fileCount: 1, pageCount: 1))

        let replacement = extractor.extract(projectRoot: "/alpha", path: "A.swift", pageID: "alpha-next", source: "enum Replacement {}")
        await index.replace(projectRoot: "/alpha", path: "A.swift", symbols: replacement)
        #expect(await index.exact(projectRoot: "/alpha", name: "Shared").isEmpty)
        #expect(await index.symbols(projectRoot: "/beta", qualifiedName: "Shared").count == 1)
        await index.remove(projectRoot: "/alpha", path: "A.swift")
        #expect(await index.stats(projectRoot: "/alpha") == SymbolIndexStats(symbolCount: 0, fileCount: 0, pageCount: 0))
    }

    @Test func exactAndReferenceIndexesUseIndexedKeys() async {
        let symbols = SwiftSymbolExtractor().extract(projectRoot: "/project", path: "Sources/Engine.swift", pageID: "engine-page", source: "struct PermissionEngine {}")
        let index = ProjectSymbolIndex()
        await index.replace(projectRoot: "/project", symbols: symbols)

        #expect(await index.exact(projectRoot: "/project", name: "PermissionEngine").count == 1)
        #expect(await index.exactQualifiedName(projectRoot: "/project", name: "PermissionEngine").count == 1)
        #expect(await index.symbols(projectRoot: "/project", path: "Sources/Engine.swift").count == 1)
        #expect(await index.symbols(projectRoot: "/project", pageID: "engine-page").count == 1)
        #expect(await index.prefix(projectRoot: "/project", prefix: "Permission").map(\.name) == ["PermissionEngine"])
    }
}
