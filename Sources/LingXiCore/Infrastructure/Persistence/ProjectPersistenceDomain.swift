import Foundation
import LingXiProtocol

public struct RootBindingID: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ProjectFileID: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ProjectRelativePath: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.hasPrefix("/"), !rawValue.hasPrefix("~"),
              !rawValue.split(separator: "/").contains(".."),
              !rawValue.contains("//"), !rawValue.contains("\\")
        else { throw WorkspaceResolutionError.invalidRelativePath(rawValue) }
        self.rawValue = rawValue == "." ? "" : rawValue
    }

    public init(rawValue: String) { self.rawValue = rawValue }
    public static let root = ProjectRelativePath(rawValue: "")
}

public enum RootBindingKind: String, Sendable, Codable, CaseIterable {
    case main
    case temporary
    case sandbox
    case worktree
    case external
}

public enum RootBindingLifecycleState: String, Sendable, Codable {
    case active
    case missing
    case inactive
}

public struct RootBinding: Sendable, Equatable, Codable {
    public let id: RootBindingID
    public let projectID: ProjectID
    public let kind: RootBindingKind
    public let absoluteRoot: URL
    public let parentBindingID: RootBindingID?
    public let bindingRevision: Int
    public let lifecycleState: RootBindingLifecycleState
    public let createdAt: Date
    public let updatedAt: Date
    public let lastSeenAt: Date?
}

public struct ProjectFileBinding: Sendable, Equatable, Codable {
    public let id: ProjectFileID
    public let projectID: ProjectID
    public let rootBindingID: RootBindingID
    public let relativePath: ProjectRelativePath
    public let contentHash: String
    public let version: String
    public let state: String
    public let createdAt: Date
    public let updatedAt: Date
    public let lastSeenAt: Date?
}

public enum WorkspaceResolutionError: Error, Sendable, Equatable {
    case unknownRootBinding(RootBindingID)
    case invalidRelativePath(String)
    case escapedRoot(RootBindingID)
}

/// 唯一的持久路径解析入口。所有 durable locator 均为 RootBindingID + RelativePath。
public actor WorkspaceResolver {
    private let store: SQLitePersistenceStore

    public init(store: SQLitePersistenceStore) { self.store = store }

    public func resolve(rootBindingID: RootBindingID, relativePath: ProjectRelativePath) async throws -> URL {
        guard let binding = try await store.rootBinding(rootBindingID) else {
            throw WorkspaceResolutionError.unknownRootBinding(rootBindingID)
        }
        let root = binding.absoluteRoot.standardizedFileURL.resolvingSymlinksInPath()
        let target = root.appendingPathComponent(relativePath.rawValue).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path
        guard target.path == rootPath || target.path.hasPrefix(rootPath + "/") else {
            throw WorkspaceResolutionError.escapedRoot(rootBindingID)
        }
        return target
    }
}

public protocol BlobStore: Sendable {
    func put(_ data: Data) throws -> String
    func get(_ reference: String) throws -> Data?
    func byteCount() throws -> Int64
}

public struct FileBlobStore: BlobStore {
    private let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func put(_ data: Data) throws -> String {
        let reference = ContextPage.fingerprint(data)
        let url = directory.appendingPathComponent(reference)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return reference
    }

    public func get(_ reference: String) throws -> Data? {
        let url = directory.appendingPathComponent(reference)
        return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    public func byteCount() throws -> Int64 {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        return Int64(urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) })
    }
}
