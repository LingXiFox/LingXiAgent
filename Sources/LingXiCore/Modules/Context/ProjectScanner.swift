import Foundation

public enum ProjectScannerError: Error, Sendable, Equatable {
    case rootNotFound(String)
}

/// 仅扫描项目根目录以内的 UTF-8 常规文本文件。
public struct ProjectScanner: Sendable {
    public static let maximumFileBytes = 1_024 * 1_024
    public static let referenceDocumentationDirectories: Set<String> = ["references", "reference-docs"]
    public static let researchArchiveDirectories: Set<String> = ["opencode-extraction", "openchamber-extraction"]
    public let root: URL
    public let minimumPageBytes: Int
    public let maximumPageBytes: Int

    public init(root: URL, minimumPageBytes: Int = 8 * 1024, maximumPageBytes: Int = 16 * 1024) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.minimumPageBytes = max(1, minimumPageBytes)
        self.maximumPageBytes = max(max(1, minimumPageBytes), maximumPageBytes)
    }

    public var projectRoot: String { ContextPage.projectIdentifier(for: root) }

    public func scan() throws -> [ContextPage] {
        try scanManifest().pages
    }

    public func scanManifest() throws -> ProjectScan {
        try scanManifest(reusing: [:])
    }

    func scanManifest(reusing existingFiles: [String: ScannedProjectFile]) throws -> ProjectScan {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else {
            throw ProjectScannerError.rootNotFound(root.path)
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return ProjectScan(projectRoot: projectRoot, files: [])
        }

        var files: [ScannedProjectFile] = []
        while let url = enumerator.nextObject() as? URL {
            let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolvedURL.path.hasPrefix(root.path + "/"),
                  let values = try? url.resourceValues(forKeys: keys),
                  !isSymbolicLink(url, manager: manager) else {
                if (try? url.resourceValues(forKeys: keys))?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true {
                if isExcludedPath(url) { enumerator.skipDescendants() }
                continue
            }
            let path = relativePath(for: url)
            let fileSize = values.fileSize ?? 0
            let modificationDate = values.contentModificationDate
            guard values.isRegularFile == true, !isExcludedPath(url), fileSize <= Self.maximumFileBytes else {
                continue
            }
            if let modificationDate,
               let existing = existingFiles[path],
               existing.fileSize == fileSize,
               existing.modificationDate == modificationDate {
                files.append(existing)
                continue
            }
            guard let data = try? Data(contentsOf: url), !isBinary(data), let text = String(data: data, encoding: .utf8) else {
                continue
            }
            let version = ContextPage.fingerprint(data)
            files.append(ScannedProjectFile(
                path: path,
                version: version,
                pages: makePages(path: path, text: text, version: version),
                fileSize: fileSize,
                modificationDate: modificationDate
            ))
        }
        return ProjectScan(projectRoot: projectRoot, files: files.sorted { $0.path < $1.path })
    }

    private func isExcludedPath(_ url: URL) -> Bool {
        let components = url.pathComponents.map { $0.lowercased() }
        if components.contains(where: { [".git", ".build", ".swiftpm", "deriveddata", "node_modules"].contains($0) }) {
            return true
        }
        if components.contains(where: { $0.contains("credential") || $0.contains("secret") }) {
            return true
        }
        let name = url.lastPathComponent.lowercased()
        return name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".pem") || name.hasSuffix(".key")
    }

    private func isBinary(_ data: Data) -> Bool {
        data.prefix(8 * 1024).contains(0)
    }

    private func isSymbolicLink(_ url: URL, manager: FileManager) -> Bool {
        (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func relativePath(for url: URL) -> String {
        String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
    }

    private func makePages(path: String, text: String, version: String) -> [ContextPage] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        let hasTrailingNewline = text.hasSuffix("\n")
        if hasTrailingNewline { lines.removeLast() }
        var pages: [ContextPage] = []
        var content = ""
        var byteCount = 0
        var startLine = 1

        for (index, segment) in lines.enumerated() {
            let line = segment + (index < lines.count - 1 || hasTrailingNewline ? "\n" : "")
            let lineBytes = line.utf8.count
            // Prefer 8-12 KB pages; retain complete lines and only exceed a limit for one long line.
            if !content.isEmpty && (
                byteCount + lineBytes > maximumPageBytes ||
                    (byteCount >= minimumPageBytes && byteCount + lineBytes > (minimumPageBytes + maximumPageBytes) / 2)
            ) {
                pages.append(page(path: path, startLine: startLine, endLine: index, content: content, version: version))
                content = ""
                byteCount = 0
                startLine = index + 1
            }
            content += line
            byteCount += lineBytes
        }
        if !content.isEmpty {
            pages.append(page(path: path, startLine: startLine, endLine: lines.count, content: content, version: version))
        }
        return pages
    }

    private func page(path: String, startLine: Int, endLine: Int, content: String, version: String) -> ContextPage {
        let extensionName = URL(fileURLWithPath: path).pathExtension.lowercased()
        let sourceType: ContextPageSourceType
        let components = path.split(separator: "/").map { $0.lowercased() }
        if components.contains(where: { Self.researchArchiveDirectories.contains($0) }) { sourceType = .researchArchive }
        else if components.contains(where: { Self.referenceDocumentationDirectories.contains($0) }) { sourceType = .referenceDocumentation }
        else if path == "README.md" { sourceType = .projectMetadata }
        else if path.hasPrefix("Tests/") { sourceType = .test }
        else if ["md", "txt"].contains(extensionName) { sourceType = .documentation }
        else if ["json", "yaml", "yml", "toml", "xcconfig"].contains(extensionName) || URL(fileURLWithPath: path).lastPathComponent == "Package.swift" { sourceType = .configuration }
        else { sourceType = .sourceFile }
        let heading = content.split(separator: "\n").first(where: { $0.hasPrefix("#") }).map(String.init)
        return ContextPage(projectRoot: projectRoot, path: path, startLine: startLine, endLine: endLine, content: content, version: version, sourceType: sourceType, metadata: ContextPageMetadata(path: path, language: extensionName.isEmpty ? nil : extensionName, heading: heading))
    }
}
