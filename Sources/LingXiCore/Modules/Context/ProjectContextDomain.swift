import Foundation
import LingXiProtocol

public enum ContextPageSourceType: String, Sendable, Equatable, Hashable {
    case sourceFile
    case documentation
    case referenceDocumentation
    case researchArchive
    case configuration
    case test
    case projectMetadata
}

public struct ContextPageMetadata: Sendable, Equatable, Hashable {
    public let path: String
    public let language: String?
    public let heading: String?

    public init(path: String, language: String? = nil, heading: String? = nil) {
        self.path = path
        self.language = language
        self.heading = heading
    }
}

/// 可注入模型项目上下文的最小、不可变文本页。
public struct ContextPage: Sendable, Equatable, Hashable {
    public let id: String
    public let projectID: ProjectID?
    public let fileID: ProjectFileID?
    public let projectRoot: String
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let content: String
    public let hash: String
    public let version: String
    public let sourceType: ContextPageSourceType
    public let metadata: ContextPageMetadata

    public var characterCount: Int { content.count }
    public var byteCount: Int { content.utf8.count }

    public init(
        projectRoot: String,
        projectID: ProjectID? = nil,
        fileID: ProjectFileID? = nil,
        path: String,
        startLine: Int,
        endLine: Int,
        content: String,
        hash: String? = nil,
        version: String? = nil,
        sourceType: ContextPageSourceType = .sourceFile,
        metadata: ContextPageMetadata? = nil
    ) {
        self.projectRoot = projectRoot
        self.projectID = projectID
        self.fileID = fileID
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.content = content
        self.hash = hash ?? Self.fingerprint(content.utf8)
        self.version = version ?? Self.fingerprint(content.utf8)
        self.sourceType = sourceType
        self.metadata = metadata ?? ContextPageMetadata(path: path)
        self.id = projectID.flatMap { project in fileID.map { "page:" + Self.fingerprint("\(project.rawValue)|\($0.rawValue)|\(startLine)|\(endLine)".utf8) } } ?? "\(projectRoot)|\(path):\(startLine)-\(endLine)"
    }

    public func binding(projectID: ProjectID, fileID: ProjectFileID) -> ContextPage {
        ContextPage(projectRoot: projectRoot, projectID: projectID, fileID: fileID, path: path, startLine: startLine, endLine: endLine, content: content, hash: hash, version: version, sourceType: sourceType, metadata: metadata)
    }

    public static func projectIdentifier(for root: URL) -> String {
        root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func fingerprint<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            value ^= UInt64(byte)
            value &*= 0x100000001b3
        }
        return String(format: "%016llx", value)
    }
}

public struct ProjectScan: Sendable, Equatable {
    public let projectRoot: String
    public let files: [ScannedProjectFile]

    public var pages: [ContextPage] { files.flatMap(\.pages) }

    public init(projectRoot: String, files: [ScannedProjectFile]) {
        self.projectRoot = projectRoot
        self.files = files
    }
}

public struct ScannedProjectFile: Sendable, Equatable {
    public let fileID: ProjectFileID?
    public let path: String
    public let version: String
    public let pages: [ContextPage]
    public let fileSize: Int
    public let modificationDate: Date?

    public init(fileID: ProjectFileID? = nil, path: String, version: String, pages: [ContextPage], fileSize: Int = -1, modificationDate: Date? = nil) {
        self.fileID = fileID
        self.path = path
        self.version = version
        self.pages = pages
        self.fileSize = fileSize
        self.modificationDate = modificationDate
    }

    public func binding(projectID: ProjectID, fileID: ProjectFileID) -> ScannedProjectFile {
        ScannedProjectFile(fileID: fileID, path: path, version: version, pages: pages.map { $0.binding(projectID: projectID, fileID: fileID) }, fileSize: fileSize, modificationDate: modificationDate)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path == rhs.path && lhs.version == rhs.version && lhs.pages == rhs.pages
    }
}

public struct ProjectPageStoreUpdate: Sendable, Equatable {
    public let initialIndexedPaths: [String]
    public let rebuiltPaths: [String]
    public let removedPaths: [String]
    public let invalidatedPageIDs: [String]
    public let filesChecked: Int
    public let filesRebuilt: Int
    public let initialIndexedPages: Int
    public let scanMilliseconds: Int

    public init(
        initialIndexedPaths: [String] = [],
        rebuiltPaths: [String] = [],
        removedPaths: [String] = [],
        invalidatedPageIDs: [String] = [],
        filesChecked: Int = 0,
        filesRebuilt: Int = 0,
        initialIndexedPages: Int = 0,
        scanMilliseconds: Int = 0
    ) {
        self.initialIndexedPaths = initialIndexedPaths
        self.rebuiltPaths = rebuiltPaths
        self.removedPaths = removedPaths
        self.invalidatedPageIDs = invalidatedPageIDs
        self.filesChecked = filesChecked
        self.filesRebuilt = filesRebuilt
        self.initialIndexedPages = initialIndexedPages
        self.scanMilliseconds = scanMilliseconds
    }
}

public struct L2PromotionResult: Sendable, Equatable {
    public let admitted: [ContextPage]
    public let evicted: [ContextPage]

    public init(admitted: [ContextPage], evicted: [ContextPage]) {
        self.admitted = admitted
        self.evicted = evicted
    }
}

public struct L2WorkingSetMetrics: Sendable, Equatable {
    public let pageCount: Int
    public let characterCount: Int

    public init(pageCount: Int, characterCount: Int) {
        self.pageCount = pageCount
        self.characterCount = characterCount
    }
}

public struct ContextPagerMetrics: Sendable, Equatable {
    public let hits: Int
    public let misses: Int
    public let pageFaults: Int

    public init(hits: Int = 0, misses: Int = 0, pageFaults: Int = 0) {
        self.hits = hits
        self.misses = misses
        self.pageFaults = pageFaults
    }
}

public struct ContextPagingTurnMetrics: Sendable, Equatable {
    public let lookups: Int
    public let hits: Int
    public let misses: Int
    public let pageFaults: Int
    public let promotions: Int
    public let evictions: Int
    public let candidatePages: Int
    public let candidateCharacters: Int
    public let selectedPages: Int
    public let selectedCharacters: Int
    public let retrievalMilliseconds: Double
    public let materializationMilliseconds: Double
    public let symbolHints: Int
    public let symbolExactMatches: Int
    public let symbolQualifiedExactMatches: Int
    public let symbolFallbackExactMatches: Int
    public let symbolPrefixMatches: Int
    public let symbolCandidatePages: Int
    public let symbolHintExtractionMilliseconds: Double
    public let symbolExactLookupMilliseconds: Double
    public let symbolPrefixLookupMilliseconds: Double
    public let symbolCandidateMergeMilliseconds: Double
    public let symbolRankingMilliseconds: Double
    public let symbolTotalMilliseconds: Double
    public let lexicalCandidatePages: Int
    public let currentSourceCandidates: Int
    public let documentationCandidates: Int
    public let referenceCandidates: Int
    public let relationHints: Int
    public let directReferenceHits: Int
    public let dependencyHits: Int
    public let relatedPages: Int
    public let referenceResolutionMilliseconds: Double
    public let referenceExpansionMilliseconds: Double

    public static let zero = ContextPagingTurnMetrics(lookups: 0, hits: 0, misses: 0, pageFaults: 0, promotions: 0, evictions: 0, candidatePages: 0, candidateCharacters: 0, selectedPages: 0, selectedCharacters: 0, retrievalMilliseconds: 0, materializationMilliseconds: 0, symbolHints: 0, symbolExactMatches: 0, symbolQualifiedExactMatches: 0, symbolFallbackExactMatches: 0, symbolPrefixMatches: 0, symbolCandidatePages: 0, symbolHintExtractionMilliseconds: 0, symbolExactLookupMilliseconds: 0, symbolPrefixLookupMilliseconds: 0, symbolCandidateMergeMilliseconds: 0, symbolRankingMilliseconds: 0, symbolTotalMilliseconds: 0, lexicalCandidatePages: 0, currentSourceCandidates: 0, documentationCandidates: 0, referenceCandidates: 0, relationHints: 0, directReferenceHits: 0, dependencyHits: 0, relatedPages: 0, referenceResolutionMilliseconds: 0, referenceExpansionMilliseconds: 0)
}

public struct SymbolSearchMetrics: Sendable, Equatable {
    public let hints: Int
    public let exactMatches: Int
    public let qualifiedExactMatches: Int
    public let fallbackExactMatches: Int
    public let prefixMatches: Int
    public let candidatePages: Int
    public let exactLookupMilliseconds: Double
    public let prefixLookupMilliseconds: Double
    public let candidateMergeMilliseconds: Double
    public let rankingMilliseconds: Double
    public let totalMilliseconds: Double
    public let lexicalCandidatePages: Int
    public let currentSourceCandidates: Int
    public let documentationCandidates: Int
    public let referenceCandidates: Int
    public let relationHints: Int
    public let directReferenceHits: Int
    public let dependencyHits: Int
    public let relatedPages: Int
    public let resolutionMilliseconds: Double
    public let expansionMilliseconds: Double

    public static let zero = SymbolSearchMetrics(hints: 0, exactMatches: 0, qualifiedExactMatches: 0, fallbackExactMatches: 0, prefixMatches: 0, candidatePages: 0, exactLookupMilliseconds: 0, prefixLookupMilliseconds: 0, candidateMergeMilliseconds: 0, rankingMilliseconds: 0, totalMilliseconds: 0, lexicalCandidatePages: 0, currentSourceCandidates: 0, documentationCandidates: 0, referenceCandidates: 0, relationHints: 0, directReferenceHits: 0, dependencyHits: 0, relatedPages: 0, resolutionMilliseconds: 0, expansionMilliseconds: 0)
}

public struct ProjectPageSearchResult: Sendable, Equatable {
    public let pages: [ContextPage]
    public let symbolMetrics: SymbolSearchMetrics

    public init(pages: [ContextPage], symbolMetrics: SymbolSearchMetrics = .zero) {
        self.pages = pages
        self.symbolMetrics = symbolMetrics
    }
}

public struct ContextPagerResult: Sendable, Equatable {
    public let pages: [ContextPage]
    public let metrics: ContextPagerMetrics
    public let candidatePageCount: Int
    public let candidateCharacterCount: Int
    public let selectedPageCount: Int
    public let selectedCharacterCount: Int
    public let turnMetrics: ContextPagingTurnMetrics

    public var characterCount: Int { pages.reduce(0) { $0 + $1.characterCount } }

    public init(pages: [ContextPage], metrics: ContextPagerMetrics, candidatePageCount: Int = 0, candidateCharacterCount: Int = 0, selectedPageCount: Int? = nil, selectedCharacterCount: Int? = nil, turnMetrics: ContextPagingTurnMetrics = .zero) {
        self.pages = pages
        self.metrics = metrics
        self.candidatePageCount = candidatePageCount
        self.candidateCharacterCount = candidateCharacterCount
        self.selectedPageCount = selectedPageCount ?? pages.count
        self.selectedCharacterCount = selectedCharacterCount ?? pages.reduce(0) { $0 + $1.characterCount }
        self.turnMetrics = turnMetrics
    }
}

public struct ContextPagingDebugMetrics: Sendable, Equatable {
    public let queryCharacters: Int
    public let queryTerms: Int
    public let candidatePages: Int
    public let candidateCharacters: Int
    public let selectedPages: Int
    public let selectedCharacters: Int
    public let injectedPages: Int
    public let injectedCharacters: Int
    public let filesChecked: Int
    public let filesRebuilt: Int
    public let scanMilliseconds: Int
    public let initialIndexedFiles: Int
    public let l2Lookups: Int
    public let l2Hits: Int
    public let l2Misses: Int
    public let l2Pages: Int
    public let l2Characters: Int
    public let l3Pages: Int
    public let l3Queries: Int
    public let l3Candidates: Int
    public let l3Materializations: Int
    public let staleRebuilds: Int
    public let pageFaults: Int
    public let promotions: Int
    public let evictions: Int
    public let retrievalMilliseconds: Double
    public let materializationMilliseconds: Double
    public let symbolCount: Int
    public let symbolIndexedFiles: Int
    public let symbolHints: Int
    public let symbolExactMatches: Int
    public let symbolQualifiedExactMatches: Int
    public let symbolFallbackExactMatches: Int
    public let symbolPrefixMatches: Int
    public let symbolCandidatePages: Int
    public let symbolHintExtractionMilliseconds: Double
    public let symbolExactLookupMilliseconds: Double
    public let symbolPrefixLookupMilliseconds: Double
    public let symbolCandidateMergeMilliseconds: Double
    public let symbolRankingMilliseconds: Double
    public let symbolTotalMilliseconds: Double
    public let lexicalCandidatePages: Int
    public let currentSourceCandidates: Int
    public let documentationCandidates: Int
    public let referenceCandidates: Int
    public let referenceCount: Int
    public let resolvedReferenceCount: Int
    public let ambiguousReferenceCount: Int
    public let unresolvedReferenceCount: Int
    public let dependencyCount: Int
    public let referenceIndexedFiles: Int
    public let relationHints: Int
    public let directReferenceHits: Int
    public let dependencyHits: Int
    public let relatedPages: Int
    public let referenceResolutionMilliseconds: Double
    public let referenceExpansionMilliseconds: Double
}
