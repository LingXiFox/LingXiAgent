import Foundation
import LingXiProtocol

public enum SymbolKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case actor
    case `extension`
    case `func`
    case `init`
    case `typealias`
}

public struct SymbolID: RawRepresentable, Sendable, Equatable, Hashable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(projectID: ProjectID, fileID: ProjectFileID, qualifiedName: String, kind: SymbolKind, line: Int) {
        self.rawValue = Self.fingerprint("\(projectID.rawValue)|\(fileID.rawValue)|\(qualifiedName)|\(kind.rawValue)|\(line)")
    }

    public init(projectRoot: String, path: String, qualifiedName: String, kind: SymbolKind, line: Int) {
        self.rawValue = Self.fingerprint("\(projectRoot)|\(path)|\(qualifiedName)|\(kind.rawValue)|\(line)")
    }

    public static func < (lhs: SymbolID, rhs: SymbolID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

public struct Symbol: Sendable, Equatable, Hashable {
    public let id: SymbolID
    public let projectID: ProjectID?
    public let fileID: ProjectFileID?
    public let projectRoot: String
    public let name: String
    public let qualifiedName: String
    public let kind: SymbolKind
    public let path: String
    public let pageID: String
    public let line: Int

    public init(
        projectRoot: String,
        projectID: ProjectID? = nil,
        fileID: ProjectFileID? = nil,
        name: String,
        qualifiedName: String,
        kind: SymbolKind,
        path: String,
        pageID: String,
        line: Int,
        id: SymbolID? = nil
    ) {
        self.projectRoot = projectRoot
        self.projectID = projectID
        self.fileID = fileID
        self.name = name
        self.qualifiedName = qualifiedName
        self.kind = kind
        self.path = path
        self.pageID = pageID
        self.line = line
        self.id = id ?? (projectID.flatMap { project in fileID.map { SymbolID(projectID: project, fileID: $0, qualifiedName: qualifiedName, kind: kind, line: line) } } ?? SymbolID(projectRoot: projectRoot, path: path, qualifiedName: qualifiedName, kind: kind, line: line))
    }
}

public protocol SymbolExtractor: Sendable {
    func extract(projectRoot: String, path: String, pageID: String, source: String) -> [Symbol]
}

public struct SymbolIndexStats: Sendable, Equatable {
    public let symbolCount: Int
    public let fileCount: Int
    public let pageCount: Int

    public init(symbolCount: Int, fileCount: Int, pageCount: Int) {
        self.symbolCount = symbolCount
        self.fileCount = fileCount
        self.pageCount = pageCount
    }
}
