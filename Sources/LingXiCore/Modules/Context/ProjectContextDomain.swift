import Foundation

public enum ContextPageSourceType: String, Sendable, Equatable, Hashable {
    case sourceFile
    case documentation
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
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.content = content
        self.hash = hash ?? Self.fingerprint(content.utf8)
        self.version = version ?? Self.fingerprint(content.utf8)
        self.sourceType = sourceType
        self.metadata = metadata ?? ContextPageMetadata(path: path)
        self.id = "\(projectRoot)|\(path):\(startLine)-\(endLine)"
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
    public let path: String
    public let version: String
    public let pages: [ContextPage]
    public let fileSize: Int
    public let modificationDate: Date?

    public init(path: String, version: String, pages: [ContextPage], fileSize: Int = -1, modificationDate: Date? = nil) {
        self.path = path
        self.version = version
        self.pages = pages
        self.fileSize = fileSize
        self.modificationDate = modificationDate
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

    public static let zero = ContextPagingTurnMetrics(lookups: 0, hits: 0, misses: 0, pageFaults: 0, promotions: 0, evictions: 0, candidatePages: 0, candidateCharacters: 0, selectedPages: 0, selectedCharacters: 0, retrievalMilliseconds: 0, materializationMilliseconds: 0)
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
}
