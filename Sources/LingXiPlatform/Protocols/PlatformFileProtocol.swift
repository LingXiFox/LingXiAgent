import Foundation

public struct PlatformFileMetadata: Sendable, Equatable {
    public let size: Int64
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let modificationDate: Date?
    public let isExecutable: Bool

    public init(size: Int64, isDirectory: Bool, isSymlink: Bool = false, modificationDate: Date? = nil, isExecutable: Bool = false) {
        self.size = size
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.modificationDate = modificationDate
        self.isExecutable = isExecutable
    }
}

public enum PlatformFilesystemEventKind: String, Sendable, Codable {
    case created
    case modified
    case deleted
    case renamed
}

public struct PlatformFilesystemEvent: Sendable {
    public let path: String
    public let kind: PlatformFilesystemEventKind

    public init(path: String, kind: PlatformFilesystemEventKind) {
        self.path = path
        self.kind = kind
    }
}

/// 跨平台文件系统抽象与原子化 I/O
public protocol PlatformFileProtocol: Sendable {
    func readFile(at path: String, limit: Int?) throws -> Data
    func writeAtomic(contents: Data, to path: String) throws
    func append(contents: Data, to path: String) throws
    func exists(at path: String) -> Bool
    func metadata(at path: String) throws -> PlatformFileMetadata
    func listDirectory(at path: String, recursive: Bool, maxResults: Int?) throws -> [String]
    func createDirectories(at path: String) throws
    func remove(at path: String) throws
    func move(from source: String, to destination: String) throws
    func copy(from source: String, to destination: String) throws
    func resolveSymlinks(at path: String) -> String
    func watch(paths: [String], events: [PlatformFilesystemEventKind]) -> AsyncThrowingStream<PlatformFilesystemEvent, Error>
    func makeTemporaryDirectory(prefix: String) throws -> String
}

public extension PlatformFileProtocol {
    func readFile(at path: String, limit: Int? = nil) throws -> Data {
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if let limit = limit {
            return handle.readData(ofLength: limit)
        } else {
            return handle.readDataToEndOfFile()
        }
    }

    func writeAtomic(contents: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try contents.writePlatformSafe(to: url)
    }

    func append(contents: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            try contents.writePlatformSafe(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: contents)
    }

    func exists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func metadata(at path: String) throws -> PlatformFileMetadata {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let type = attrs[.type] as? FileAttributeType
        let isDir = type == .typeDirectory
        let isSym = type == .typeSymbolicLink
        let modDate = attrs[.modificationDate] as? Date
        let isExec = FileManager.default.isExecutableFile(atPath: path)
        return PlatformFileMetadata(size: size, isDirectory: isDir, isSymlink: isSym, modificationDate: modDate, isExecutable: isExec)
    }

    func listDirectory(at path: String, recursive: Bool, maxResults: Int? = nil) throws -> [String] {
        let fm = FileManager.default
        var results: [String] = []
        if recursive {
            guard let enumerator = fm.enumerator(atPath: path) else { return [] }
            for case let file as String in enumerator {
                results.append(file)
                if let maxResults = maxResults, results.count >= maxResults {
                    break
                }
            }
        } else {
            results = try fm.contentsOfDirectory(atPath: path)
            if let maxResults = maxResults, results.count > maxResults {
                results = Array(results.prefix(maxResults))
            }
        }
        return results
    }

    func createDirectories(at path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func remove(at path: String) throws {
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    func move(from source: String, to destination: String) throws {
        try FileManager.default.moveItem(atPath: source, toPath: destination)
    }

    func copy(from source: String, to destination: String) throws {
        try FileManager.default.copyItem(atPath: source, toPath: destination)
    }

    func resolveSymlinks(at path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func watch(paths: [String], events: [PlatformFilesystemEventKind]) -> AsyncThrowingStream<PlatformFilesystemEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func makeTemporaryDirectory(prefix: String) throws -> String {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir.path
    }
}
