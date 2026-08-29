public actor ProjectReferenceIndex {
    private var referencesByProject: [String: [ReferenceID: ProjectReference]] = [:]
    private var bySourceSymbol: [String: [SymbolID: Set<ReferenceID>]] = [:]
    private var byTargetSymbol: [String: [SymbolID: Set<ReferenceID>]] = [:]
    private var bySourcePage: [String: [String: Set<ReferenceID>]] = [:]
    private var byTargetPage: [String: [String: Set<ReferenceID>]] = [:]
    private var bySourcePath: [String: [String: Set<ReferenceID>]] = [:]
    private var byTargetPath: [String: [String: Set<ReferenceID>]] = [:]
    private var byTargetName: [String: [String: Set<ReferenceID>]] = [:]
    private var dependenciesByProject: [String: Set<DependencyEdge>] = [:]

    public init() {}

    public func replaceReferences(projectRoot: String, forPath path: String, references: [ProjectReference]) {
        var project = referencesByProject[projectRoot, default: [:]]
        project = project.filter { $0.value.sourcePath != path }
        for reference in references { project[reference.id] = reference }
        referencesByProject[projectRoot] = project
        rebuild(projectRoot)
    }

    public func replaceResolved(projectRoot: String, references: [ProjectReference]) {
        referencesByProject[projectRoot] = Dictionary(references.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        rebuild(projectRoot)
    }

    public func removeReferences(projectRoot: String, forPath path: String) {
        referencesByProject[projectRoot] = referencesByProject[projectRoot, default: [:]].filter { $0.value.sourcePath != path }
        rebuild(projectRoot)
    }

    public func references(projectRoot: String) -> [ProjectReference] { sorted(referencesByProject[projectRoot, default: [:]].values) }
    public func referencesFrom(projectRoot: String, symbol: SymbolID) -> [ProjectReference] { lookup(bySourceSymbol[projectRoot]?[symbol] ?? [], projectRoot) }
    public func referencesFrom(projectRoot: String, page: String) -> [ProjectReference] { lookup(bySourcePage[projectRoot]?[page] ?? [], projectRoot) }
    public func referencesFrom(projectRoot: String, path: String) -> [ProjectReference] { lookup(bySourcePath[projectRoot]?[path] ?? [], projectRoot) }
    public func referencesTo(projectRoot: String, symbol: SymbolID) -> [ProjectReference] { lookup(byTargetSymbol[projectRoot]?[symbol] ?? [], projectRoot) }
    public func dependenciesFrom(projectRoot: String, path: String) -> [DependencyEdge] { dependencies(projectRoot).filter { $0.sourcePath == path }.sorted { $0.evidence < $1.evidence } }
    public func dependenciesTo(projectRoot: String, path: String) -> [DependencyEdge] { dependencies(projectRoot).filter { $0.targetPath == path }.sorted { $0.evidence < $1.evidence } }

    public func lookupRelatedPages(projectRoot: String, symbolIDs: Set<SymbolID>, targetNames: Set<String>, maximumPages: Int = 8, maximumDepth: Int = 1) -> ReferenceLookupResult {
        guard maximumDepth == 1 else { return .init() }
        var ids = Set<ReferenceID>()
        for symbol in symbolIDs { ids.formUnion(bySourceSymbol[projectRoot]?[symbol] ?? []); ids.formUnion(byTargetSymbol[projectRoot]?[symbol] ?? []) }
        for name in targetNames { ids.formUnion(byTargetName[projectRoot]?[name] ?? []) }
        let refs = lookup(ids, projectRoot)
        let pages = Array(Set(refs.flatMap { [$0.sourcePageID, $0.targetPageID].compactMap { $0 } })).sorted().prefix(max(0, maximumPages))
        let dependencyHits = refs.filter { $0.kind == .import || $0.targetPath != nil }.count
        return ReferenceLookupResult(pageIDs: Array(pages), directReferenceHits: refs.count, dependencyHits: dependencyHits)
    }

    public func stats(projectRoot: String) -> ReferenceIndexStats {
        let references = self.references(projectRoot: projectRoot)
        return ReferenceIndexStats(referenceCount: references.count, resolvedCount: references.filter { $0.resolutionQuality == .exactResolved || $0.resolutionQuality == .symbolNameResolved }.count, ambiguousCount: references.filter { $0.resolutionQuality == .ambiguous }.count, unresolvedCount: references.filter { $0.resolutionQuality == .unresolved || $0.resolutionQuality == .receiverHint }.count, dependencyCount: dependencies(projectRoot).count, indexedFileCount: Set(references.map(\.sourcePath)).count)
    }

    private func dependencies(_ projectRoot: String) -> Set<DependencyEdge> { dependenciesByProject[projectRoot, default: []] }
    private func lookup(_ ids: Set<ReferenceID>, _ projectRoot: String) -> [ProjectReference] { sorted(ids.compactMap { referencesByProject[projectRoot]?[$0] }) }
    private func sorted<S: Sequence>(_ references: S) -> [ProjectReference] where S.Element == ProjectReference { references.sorted { $0.id < $1.id } }
    private func rebuild(_ projectRoot: String) {
        var sourceSymbol: [SymbolID: Set<ReferenceID>] = [:], targetSymbol: [SymbolID: Set<ReferenceID>] = [:], sourcePage: [String: Set<ReferenceID>] = [:], targetPage: [String: Set<ReferenceID>] = [:], sourcePath: [String: Set<ReferenceID>] = [:], targetPath: [String: Set<ReferenceID>] = [:], targetName: [String: Set<ReferenceID>] = [:]
        let references = self.references(projectRoot: projectRoot)
        for reference in references {
            if let value = reference.sourceSymbolID { sourceSymbol[value, default: []].insert(reference.id) }
            if let value = reference.targetSymbolID { targetSymbol[value, default: []].insert(reference.id) }
            sourcePage[reference.sourcePageID, default: []].insert(reference.id)
            if let value = reference.targetPageID { targetPage[value, default: []].insert(reference.id) }
            sourcePath[reference.sourcePath, default: []].insert(reference.id)
            if let value = reference.targetPath { targetPath[value, default: []].insert(reference.id) }
            targetName[reference.targetName, default: []].insert(reference.id)
        }
        bySourceSymbol[projectRoot] = sourceSymbol; byTargetSymbol[projectRoot] = targetSymbol; bySourcePage[projectRoot] = sourcePage; byTargetPage[projectRoot] = targetPage; bySourcePath[projectRoot] = sourcePath; byTargetPath[projectRoot] = targetPath; byTargetName[projectRoot] = targetName
        dependenciesByProject[projectRoot] = Set(references.map(DependencyEdge.init(reference:)))
    }
}
