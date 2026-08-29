public actor ProjectSymbolIndex {
    private var symbolsByProject: [String: [SymbolID: Symbol]] = [:]
    private var byName: [String: [String: Set<SymbolID>]] = [:]
    private var byQualifiedName: [String: [String: Set<SymbolID>]] = [:]
    private var byPath: [String: [String: Set<SymbolID>]] = [:]
    private var byPageID: [String: [String: Set<SymbolID>]] = [:]

    public init() {}

    public func replace(projectRoot: String, symbols: [Symbol]) {
        symbolsByProject[projectRoot] = Dictionary(symbols.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        rebuildIndexes(projectRoot: projectRoot)
    }

    public func replace(projectRoot: String, path: String, symbols: [Symbol]) {
        var projectSymbols = symbolsByProject[projectRoot, default: [:]]
        projectSymbols = projectSymbols.filter { $0.value.path != path }
        for symbol in symbols where symbol.path == path { projectSymbols[symbol.id] = symbol }
        symbolsByProject[projectRoot] = projectSymbols
        rebuildIndexes(projectRoot: projectRoot)
    }

    public func remove(projectRoot: String, path: String) {
        guard var projectSymbols = symbolsByProject[projectRoot] else { return }
        projectSymbols = projectSymbols.filter { $0.value.path != path }
        symbolsByProject[projectRoot] = projectSymbols
        rebuildIndexes(projectRoot: projectRoot)
    }

    public func remove(projectRoot: String) {
        symbolsByProject.removeValue(forKey: projectRoot)
        byName.removeValue(forKey: projectRoot)
        byQualifiedName.removeValue(forKey: projectRoot)
        byPath.removeValue(forKey: projectRoot)
        byPageID.removeValue(forKey: projectRoot)
    }

    public func exact(projectRoot: String, name: String) -> [Symbol] {
        sorted(ids: byName[projectRoot]?[name] ?? [], projectRoot: projectRoot)
    }

    public func exactQualifiedName(projectRoot: String, name: String) -> [Symbol] {
        sorted(ids: byQualifiedName[projectRoot]?[name] ?? [], projectRoot: projectRoot)
    }

    public func prefix(projectRoot: String, prefix: String) -> [Symbol] {
        let names = byName[projectRoot, default: [:]].filter { $0.key.hasPrefix(prefix) }.values
        let qualifiedNames = byQualifiedName[projectRoot, default: [:]].filter { $0.key.hasPrefix(prefix) }.values
        return sorted(ids: Set(names.flatMap(Array.init) + qualifiedNames.flatMap(Array.init)), projectRoot: projectRoot)
    }

    public func symbols(projectRoot: String, qualifiedName: String) -> [Symbol] {
        sorted(ids: byQualifiedName[projectRoot]?[qualifiedName] ?? [], projectRoot: projectRoot)
    }

    public func symbols(projectRoot: String, path: String) -> [Symbol] {
        sorted(ids: byPath[projectRoot]?[path] ?? [], projectRoot: projectRoot)
    }

    public func symbols(projectRoot: String, pageID: String) -> [Symbol] {
        sorted(ids: byPageID[projectRoot]?[pageID] ?? [], projectRoot: projectRoot)
    }

    public func stats(projectRoot: String) -> SymbolIndexStats {
        let symbols = symbols(projectRoot: projectRoot)
        return SymbolIndexStats(
            symbolCount: symbols.count,
            fileCount: Set(symbols.map(\.path)).count,
            pageCount: Set(symbols.map(\.pageID)).count
        )
    }

    public func allSymbols(projectRoot: String) -> [Symbol] {
        sorted(symbols(projectRoot: projectRoot))
    }

    private func symbols(projectRoot: String) -> [Symbol] {
        Array(symbolsByProject[projectRoot, default: [:]].values)
    }

    private func sorted(_ symbols: [Symbol]) -> [Symbol] {
        symbols.sorted {
            if $0.qualifiedName != $1.qualifiedName { return $0.qualifiedName < $1.qualifiedName }
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.line != $1.line { return $0.line < $1.line }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    private func sorted(ids: Set<SymbolID>, projectRoot: String) -> [Symbol] {
        sorted(ids.compactMap { symbolsByProject[projectRoot]?[$0] })
    }

    private func rebuildIndexes(projectRoot: String) {
        var names: [String: Set<SymbolID>] = [:]
        var qualifiedNames: [String: Set<SymbolID>] = [:]
        var paths: [String: Set<SymbolID>] = [:]
        var pages: [String: Set<SymbolID>] = [:]
        for symbol in symbols(projectRoot: projectRoot) {
            names[symbol.name, default: []].insert(symbol.id)
            qualifiedNames[symbol.qualifiedName, default: []].insert(symbol.id)
            paths[symbol.path, default: []].insert(symbol.id)
            pages[symbol.pageID, default: []].insert(symbol.id)
        }
        byName[projectRoot] = names
        byQualifiedName[projectRoot] = qualifiedNames
        byPath[projectRoot] = paths
        byPageID[projectRoot] = pages
    }
}
