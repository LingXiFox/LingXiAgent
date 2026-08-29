import Foundation

public enum ReferenceKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case `import`
    case typeReference
    case protocolConformance
    case inheritance
    case extensionTarget
    case memberReference
    case functionReference
}

public enum ReferenceResolutionQuality: String, Sendable, Equatable, Hashable {
    case exactResolved
    case symbolNameResolved
    case receiverHint
    case ambiguous
    case unresolved
}

public struct ReferenceID: RawRepresentable, Sendable, Equatable, Hashable, Comparable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(projectRoot: String, sourcePath: String, line: Int, kind: ReferenceKind, targetName: String) {
        self.rawValue = Self.fingerprint("\(projectRoot)|\(sourcePath)|\(line)|\(kind.rawValue)|\(targetName)")
    }

    public static func < (lhs: ReferenceID, rhs: ReferenceID) -> Bool { lhs.rawValue < rhs.rawValue }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 { hash ^= UInt64(byte); hash &*= 0x100000001b3 }
        return String(hash, radix: 16)
    }
}

public struct ProjectReference: Sendable, Equatable, Hashable {
    public let id: ReferenceID
    public let projectRoot: String
    public let sourceSymbolID: SymbolID?
    public let sourcePageID: String
    public let sourcePath: String
    public let sourceLine: Int
    public let targetName: String
    public let targetSymbolID: SymbolID?
    public let targetPageID: String?
    public let targetPath: String?
    public let kind: ReferenceKind
    public let resolutionQuality: ReferenceResolutionQuality
    public let candidateSymbolIDs: [SymbolID]
    public let receiverHint: String?

    public init(projectRoot: String, sourceSymbolID: SymbolID? = nil, sourcePageID: String, sourcePath: String, sourceLine: Int, targetName: String, kind: ReferenceKind, targetSymbolID: SymbolID? = nil, targetPageID: String? = nil, targetPath: String? = nil, resolutionQuality: ReferenceResolutionQuality = .unresolved, candidateSymbolIDs: [SymbolID] = [], receiverHint: String? = nil) {
        self.projectRoot = projectRoot; self.sourceSymbolID = sourceSymbolID; self.sourcePageID = sourcePageID; self.sourcePath = sourcePath; self.sourceLine = sourceLine; self.targetName = targetName; self.kind = kind; self.targetSymbolID = targetSymbolID; self.targetPageID = targetPageID; self.targetPath = targetPath; self.resolutionQuality = resolutionQuality; self.candidateSymbolIDs = candidateSymbolIDs.sorted(); self.receiverHint = receiverHint
        id = ReferenceID(projectRoot: projectRoot, sourcePath: sourcePath, line: sourceLine, kind: kind, targetName: targetName)
    }

    public func resolving(to symbols: [Symbol], quality: ReferenceResolutionQuality) -> ProjectReference {
        let target = symbols.count == 1 ? symbols[0] : nil
        return ProjectReference(projectRoot: projectRoot, sourceSymbolID: sourceSymbolID, sourcePageID: sourcePageID, sourcePath: sourcePath, sourceLine: sourceLine, targetName: targetName, kind: kind, targetSymbolID: target?.id, targetPageID: target?.pageID, targetPath: target?.path, resolutionQuality: quality, candidateSymbolIDs: symbols.map(\.id), receiverHint: receiverHint)
    }
}

public enum DependencyKind: String, Sendable, Equatable, Hashable {
    case importModule
    case symbolDependency
    case typeDependency
    case conformanceDependency
    case extensionDependency
}

public struct DependencyEdge: Sendable, Equatable, Hashable {
    public let sourcePath: String
    public let targetPath: String?
    public let targetModule: String?
    public let kind: DependencyKind
    public let evidence: ReferenceID
    public let sourcePageID: String

    public init(reference: ProjectReference) {
        sourcePath = reference.sourcePath; targetPath = reference.targetPath; sourcePageID = reference.sourcePageID; evidence = reference.id
        if reference.kind == .import { kind = .importModule; targetModule = reference.targetName.split(separator: ".").first.map(String.init) }
        else {
            targetModule = nil
            switch reference.kind {
            case .typeReference: kind = .typeDependency
            case .protocolConformance, .inheritance: kind = .conformanceDependency
            case .extensionTarget: kind = .extensionDependency
            default: kind = .symbolDependency
            }
        }
    }
}

public struct ReferenceIndexStats: Sendable, Equatable {
    public let referenceCount: Int
    public let resolvedCount: Int
    public let ambiguousCount: Int
    public let unresolvedCount: Int
    public let dependencyCount: Int
    public let indexedFileCount: Int
}

public struct ReferenceLookupResult: Sendable, Equatable {
    public let pageIDs: [String]
    public let directReferenceHits: Int
    public let dependencyHits: Int

    public init(pageIDs: [String] = [], directReferenceHits: Int = 0, dependencyHits: Int = 0) {
        self.pageIDs = pageIDs; self.directReferenceHits = directReferenceHits; self.dependencyHits = dependencyHits
    }
}

public protocol ReferenceExtractor: Sendable {
    func extract(projectRoot: String, path: String, pages: [ContextPage], symbols: [Symbol]) -> [ProjectReference]
}
