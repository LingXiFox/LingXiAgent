import Foundation
import LingXiProtocol

public struct WorkspaceRoot: Sendable {
    public let url: URL
    public let sensitivePathPolicy: SensitivePathPolicy
    public var path: String { url.path }

    public init(path: String, sensitivePathPolicy: SensitivePathPolicy? = nil) throws {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CoreError(code: .workspaceViolation, message: "Workspace Root 不存在或不是目录: \(candidate.path)")
        }
        url = candidate
        self.sensitivePathPolicy = sensitivePathPolicy ?? SensitivePathPolicy(root: candidate)
    }

    public func resolve(_ path: String, profile: ExecutionProfile = .workspace) throws -> URL {
        var cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if (cleanPath.hasPrefix("\"") && cleanPath.hasSuffix("\"")) || (cleanPath.hasPrefix("'") && cleanPath.hasSuffix("'")), cleanPath.count >= 2 {
            cleanPath = String(cleanPath.dropFirst().dropLast())
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expandedPath: String
        if cleanPath == "~" || cleanPath == "$HOME" || cleanPath == "${HOME}" {
            expandedPath = home
        } else if cleanPath.hasPrefix("~/") {
            expandedPath = home + "/" + String(cleanPath.dropFirst(2))
        } else if cleanPath.hasPrefix("$HOME/") {
            expandedPath = home + "/" + String(cleanPath.dropFirst(6))
        } else if cleanPath.hasPrefix("${HOME}/") {
            expandedPath = home + "/" + String(cleanPath.dropFirst(8))
        } else {
            expandedPath = cleanPath
        }
        let input = URL(fileURLWithPath: expandedPath, relativeTo: LingXiPlatform.path.isAbsolute(expandedPath) ? nil : url)
        var candidate = input.standardizedFileURL.resolvingSymlinksInPath()

        // Smart Fuzzy Resolution: if file doesn't exist directly, attempt workspace-scoped unique suffix/nesting resolution
        if !FileManager.default.fileExists(atPath: candidate.path),
           let fuzzy = findFuzzyCandidate(for: candidate, originalPath: expandedPath) {
            candidate = fuzzy
        }

        let root = url.path.hasSuffix("/") ? url.path : url.path + "/"
        guard profile == .fullAccess || candidate.path == url.path || candidate.path.hasPrefix(root) || SensitivePathPolicy.isModelConfigurationPath(candidate) else {
            throw CoreError(code: .workspaceViolation, message: "AccessScope=workspace 禁止访问 Workspace 外路径；请先切换到 FullAccess/YOLO")
        }
        guard !sensitivePathPolicy.isSensitive(candidate) else {
            throw CoreError(code: .workspaceViolation, message: "不允许访问敏感路径")
        }
        return candidate
    }

    private func findFuzzyCandidate(for candidate: URL, originalPath: String) -> URL? {
        let wsPath = url.path
        let filename = candidate.lastPathComponent
        guard !filename.isEmpty, filename != "/", filename != "." else { return nil }

        let relComponents: [String] = {
            if candidate.path.hasPrefix(wsPath) {
                let suffix = String(candidate.path.dropFirst(wsPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return suffix.split(separator: "/").map(String.init)
            } else {
                return originalPath.split(separator: "/").map(String.init)
            }
        }()
        let suffix2 = relComponents.suffix(2).joined(separator: "/")

        // 1. 同名目录展开尝试（针对多层同名嵌套目录少写一层的场景）
        let wsDirName = url.lastPathComponent
        if !wsDirName.isEmpty && candidate.path.contains(wsDirName) {
            let expandedSegmentPath = candidate.path.replacingOccurrences(
                of: "\(wsDirName)/\(wsDirName)/",
                with: "\(wsDirName)/\(wsDirName)/\(wsDirName)/"
            )
            if expandedSegmentPath != candidate.path && FileManager.default.fileExists(atPath: expandedSegmentPath) {
                return URL(fileURLWithPath: expandedSegmentPath).standardizedFileURL
            }
        }

        // 2. 工作区内快速搜索唯一匹配（跳过 .git、.build、node_modules 等）
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var matches: [URL] = []
        let skipDirs: Set<String> = ["node_modules", ".git", ".build", "build", "dist", "deriveddata", ".lingxi"]

        for case let fileURL as URL in enumerator {
            let lastComponent = fileURL.lastPathComponent
            if skipDirs.contains(lastComponent.lowercased()) {
                enumerator.skipDescendants()
                continue
            }
            if lastComponent == filename {
                let filePath = fileURL.path
                if !suffix2.isEmpty && filePath.hasSuffix(suffix2) {
                    matches.append(fileURL)
                } else if relComponents.count <= 1 {
                    matches.append(fileURL)
                }
            }
            if matches.count > 1 {
                return nil // 存在多个候选，避免歧义
            }
        }

        if matches.count == 1 {
            return matches[0].standardizedFileURL
        }
        return nil
    }
}

private func decodeArguments<T: Decodable>(_ arguments: String, as type: T.Type = T.self) throws -> T {
    guard let data = arguments.data(using: .utf8) else {
        throw CoreError(code: .toolArgumentInvalid, message: "Tool 参数不是 UTF-8")
    }
    do {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    } catch {
        throw CoreError(code: .toolArgumentInvalid, message: "Tool 参数无效: \(error.localizedDescription)")
    }
}

private func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func relativePath(_ url: URL, workspace: WorkspaceRoot) -> String {
    let root = workspace.url.path.hasSuffix("/") ? workspace.url.path : workspace.url.path + "/"
    return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
}

private func filesystemCapabilities(_ url: URL, workspace: WorkspaceRoot, write: Bool) -> Set<ToolCapabilityKind> {
    var capabilities: Set<ToolCapabilityKind> = [write ? .projectWrite : .projectRead]
    let root = workspace.url.path.hasSuffix("/") ? workspace.url.path : workspace.url.path + "/"
    if url.path != workspace.url.path && !url.path.hasPrefix(root) {
        capabilities.insert(.externalFilesystem)
    }
    return capabilities
}

private func readText(_ file: URL, operation: String) throws -> String {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
        throw CoreError(code: .toolExecutionFailed, message: "文件不存在: \(file.path)")
    }
    guard !isDirectory.boolValue else {
        throw CoreError(code: .toolExecutionFailed, message: "\(operation) 不能读取目录: \(file.path)")
    }
    let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
    guard size <= ReadFileTool.maximumBytes else {
        throw CoreError(code: .toolExecutionFailed, message: "文件超过 \(ReadFileTool.maximumBytes) bytes 限制: \(file.path)")
    }
    guard let content = String(data: try Data(contentsOf: file), encoding: .utf8) else {
        throw CoreError(code: .toolExecutionFailed, message: "文件不是 UTF-8 文本: \(file.path)")
    }
    return content
}

private func writableFile(_ file: URL) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw CoreError(code: .toolExecutionFailed, message: "父目录不存在: \(file.deletingLastPathComponent().path)")
    }
    if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
        throw CoreError(code: .toolExecutionFailed, message: "不能写入目录: \(file.path)")
    }
}

private func writeText(_ content: String, to file: URL) throws {
    try writableFile(file)
    do {
        try Data(content.utf8).write(to: file, options: .atomic)
    } catch {
        #if os(Windows)
        try Data(content.utf8).write(to: file)
        #else
        throw error
        #endif
    }
}

private func fileVersion(_ file: URL) throws -> String {
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
    return "stat:\(bytes):\(modified)"
}

private func checkExpectedContent(_ content: String?, hash: String?, version: String?, currentVersion: String? = nil, overwrite: Bool?) throws {
    guard overwrite != true else { return }
    guard hash != nil || version != nil else {
        throw CoreError(code: .contentChanged, message: "修改现有文件需要 expected_hash 或 expected_version")
    }
    let actual = sha256Hex(content ?? "")
    let normalizedHash = hash?.lowercased().replacingOccurrences(of: "sha256:", with: "")
    let versionMatches = version.map { $0 == (currentVersion ?? actual) } ?? true
    guard (normalizedHash == nil || normalizedHash == actual) && versionMatches else {
        throw CoreError(code: .contentChanged, message: "文件内容已变更；expected_hash 或 expected_version 不匹配")
    }
}

private func fileWriteResult(for file: URL, workspace: WorkspaceRoot, content: String) -> FileWriteResult {
    let hash = sha256Hex(content)
    return FileWriteResult(path: relativePath(file, workspace: workspace), bytes: content.lengthOfBytes(using: .utf8), hash: hash, version: (try? fileVersion(file)) ?? hash)
}

private struct PathArguments: Decodable { let path: String }
private struct ReadArguments: Decodable {
    let path: String
    let startLine: Int?
    let endLine: Int?
    let maxLines: Int?
    let lineNumbers: Bool?

    enum CodingKeys: String, CodingKey {
        case path
        case startLine = "start_line"
        case startLineCamel = "startLine"
        case endLine = "end_line"
        case endLineCamel = "endLine"
        case maxLines = "max_lines"
        case maxLinesCamel = "maxLines"
        case lineNumbers = "line_numbers"
        case lineNumbersCamel = "lineNumbers"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        startLine = try c.decodeIfPresent(Int.self, forKey: .startLine) ?? c.decodeIfPresent(Int.self, forKey: .startLineCamel)
        endLine = try c.decodeIfPresent(Int.self, forKey: .endLine) ?? c.decodeIfPresent(Int.self, forKey: .endLineCamel)
        maxLines = try c.decodeIfPresent(Int.self, forKey: .maxLines) ?? c.decodeIfPresent(Int.self, forKey: .maxLinesCamel)
        lineNumbers = try c.decodeIfPresent(Bool.self, forKey: .lineNumbers) ?? c.decodeIfPresent(Bool.self, forKey: .lineNumbersCamel)
    }
}
private struct WriteArguments: Decodable {
    let path: String
    let content: String
    let expectedHash: String?
    let expectedVersion: String?
    let overwrite: Bool?

    enum CodingKeys: String, CodingKey {
        case path, content, expectedHash, expectedVersion, overwrite
        case targetFile = "target_file", targetFileCamel = "targetFile"
        case filePath = "file_path", filePathCamel = "filePath"
        case absolutePath = "absolute_path", absolutePathCamel = "AbsolutePath"
        case codeContent = "code_content", codeContentCamel = "codeContent"
        case targetContent = "target_content", targetContentCamel = "TargetContent"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let p = try c.decodeIfPresent(String.self, forKey: .path) {
            path = p
        } else if let p = try c.decodeIfPresent(String.self, forKey: .targetFile) ?? c.decodeIfPresent(String.self, forKey: .targetFileCamel) {
            path = p
        } else if let p = try c.decodeIfPresent(String.self, forKey: .filePath) ?? c.decodeIfPresent(String.self, forKey: .filePathCamel) {
            path = p
        } else if let p = try c.decodeIfPresent(String.self, forKey: .absolutePath) ?? c.decodeIfPresent(String.self, forKey: .absolutePathCamel) {
            path = p
        } else {
            path = try c.decode(String.self, forKey: .path)
        }

        if let cnt = try c.decodeIfPresent(String.self, forKey: .content) {
            content = cnt
        } else if let cnt = try c.decodeIfPresent(String.self, forKey: .codeContent) ?? c.decodeIfPresent(String.self, forKey: .codeContentCamel) {
            content = cnt
        } else {
            content = try c.decode(String.self, forKey: .content)
        }

        expectedHash = try c.decodeIfPresent(String.self, forKey: .expectedHash)
        expectedVersion = try c.decodeIfPresent(String.self, forKey: .expectedVersion)
        overwrite = try c.decodeIfPresent(Bool.self, forKey: .overwrite)
    }
}

private struct EditArguments: Decodable {
    let path: String
    let oldString: String
    let newString: String
    let replaceAll: Bool?
    let expectedHash: String?
    let expectedVersion: String?
    let overwrite: Bool?

    enum CodingKeys: String, CodingKey {
        case path, oldString, newString, replaceAll, expectedHash, expectedVersion, overwrite
        case targetFile = "target_file", targetFileCamel = "targetFile"
        case filePath = "file_path", filePathCamel = "filePath"
        case absolutePath = "absolute_path", absolutePathCamel = "AbsolutePath"
        case targetContent = "target_content", targetContentCamel = "TargetContent"
        case replacementContent = "replacement_content", replacementContentCamel = "ReplacementContent"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let p = try c.decodeIfPresent(String.self, forKey: .path) {
            path = p
        } else if let p = try c.decodeIfPresent(String.self, forKey: .targetFile) ?? c.decodeIfPresent(String.self, forKey: .targetFileCamel) {
            path = p
        } else if let p = try c.decodeIfPresent(String.self, forKey: .filePath) ?? c.decodeIfPresent(String.self, forKey: .filePathCamel) {
            path = p
        } else if let p = try c.decodeIfPresent(String.self, forKey: .absolutePath) ?? c.decodeIfPresent(String.self, forKey: .absolutePathCamel) {
            path = p
        } else {
            path = try c.decode(String.self, forKey: .path)
        }

        if let old = try c.decodeIfPresent(String.self, forKey: .oldString) {
            oldString = old
        } else if let old = try c.decodeIfPresent(String.self, forKey: .targetContent) ?? c.decodeIfPresent(String.self, forKey: .targetContentCamel) {
            oldString = old
        } else {
            oldString = try c.decode(String.self, forKey: .oldString)
        }

        if let nw = try c.decodeIfPresent(String.self, forKey: .newString) {
            newString = nw
        } else if let nw = try c.decodeIfPresent(String.self, forKey: .replacementContent) ?? c.decodeIfPresent(String.self, forKey: .replacementContentCamel) {
            newString = nw
        } else {
            newString = try c.decode(String.self, forKey: .newString)
        }

        replaceAll = try c.decodeIfPresent(Bool.self, forKey: .replaceAll)
        expectedHash = try c.decodeIfPresent(String.self, forKey: .expectedHash)
        expectedVersion = try c.decodeIfPresent(String.self, forKey: .expectedVersion)
        overwrite = try c.decodeIfPresent(Bool.self, forKey: .overwrite)
    }
}
private struct GlobArguments: Decodable {
    let pattern: String
    let path: String?
    let maxResults: Int?
    let includeHidden: Bool?
    let includeIgnored: Bool?
    let includeGenerated: Bool?
}
private struct GrepArguments: Decodable {
    let pattern: String
    let path: String?
    let glob: String?
    let maxResults: Int?
    let includeHidden: Bool?
    let includeIgnored: Bool?
    let includeGenerated: Bool?
}
private struct PatchArguments: Decodable { let patch: String; let expectedHashes: [String: String]? }
private struct ShellArguments: Decodable {
    let command: String?
    let executable: String?
    let arguments: [String]?
    let cwd: String?
    let timeoutMs: Int?
}
private struct GitArguments: Decodable {
    let action: GitAction?
    let arguments: [String]?
    let cwd: String?
    let paths: [String]?
    let reference: String?
    let branch: String?
    let message: String?
    let limit: Int?
}
private struct ProcessArguments: Decodable {
    let action: String
    let executable: String?
    let arguments: [String]?
    let cwd: String?
    let id: String?
    let input: String?
    let stdoutCursor: Int?
    let stderrCursor: Int?
}
private struct RunBackgroundCommandArguments: Decodable {
    let command: String
    let timeoutSeconds: Int?
    let cwd: String?
    let description: String?
    let taskId: String?
}
private struct ManageBackgroundCommandArguments: Decodable {
    let action: String
    let taskId: String?
    let stdoutCursor: Int?
    let stderrCursor: Int?
    let inputText: String?
}
private struct QuestionArguments: Decodable { let question: String; let options: [String]?; let multiple: Bool? }
private struct SymbolArguments: Decodable { let symbol: String; let mode: String?; let direction: String? }
private struct CodeIntelligenceArguments: Decodable { let action: String; let query: String?; let path: String?; let line: Int?; let character: Int?; let maximumCharacters: Int? }
private struct SkillArguments: Decodable { let name: String }

private func pathArguments(_ arguments: String) throws -> PathArguments { try decodeArguments(arguments) }

private struct ReadLine: Codable { let number: Int; let content: String }
private struct ReadPage: Codable {
    let path: String
    let lines: [ReadLine]
    let startLine: Int
    let endLine: Int
    let nextLine: Int?
    let truncated: Bool
    let hash: String?
    let version: String
}

private func readPage(_ file: URL, workspace: WorkspaceRoot, input: ReadArguments) throws -> ReadPage {
    var start = max(1, input.startLine ?? 1)
    var end = input.endLine
    if let e = end {
        if e <= 0 {
            // Negative or 0 end_line means no upper bound or read to EOF
            end = nil
        } else if e < start {
            // Model may have specified relative line count (e.g., start=100, end=50 lines),
            // or swapped start and end.
            if e > 0 && e <= 500 && start > e {
                end = start + e
            } else {
                swap(&start, &end!)
            }
        }
    }
    let count = min(max(1, input.maxLines ?? end.map { max(1, $0 - start + 1) } ?? 200), 2_000)
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var carry = Data()
    var lineNumber = 1
    var lines: [ReadLine] = []
    var hasMore = false
    while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
        if chunk.contains(0) { throw CoreError(code: .binaryFileUnsupported, message: "文件包含 NUL 字节，不能作为文本读取") }
        carry.append(chunk)
        while let newline = carry.firstIndex(of: 10) {
            let lineData = carry.prefix(upTo: newline)
            carry.removeSubrange(...newline)
            guard let text = String(data: lineData, encoding: .utf8) else {
                throw CoreError(code: .binaryFileUnsupported, message: "文件不是 UTF-8 文本")
            }
            if lineNumber >= start && (end.map { lineNumber <= $0 } ?? true) {
                if lines.count < count { lines.append(ReadLine(number: lineNumber, content: text)) }
                else { hasMore = true; break }
            }
            lineNumber += 1
        }
        if hasMore { break }
    }
    if !carry.isEmpty && !hasMore {
        guard let text = String(data: carry, encoding: .utf8) else { throw CoreError(code: .binaryFileUnsupported, message: "文件不是 UTF-8 文本") }
        if lineNumber >= start && (end.map { lineNumber <= $0 } ?? true) {
            if lines.count < count { lines.append(ReadLine(number: lineNumber, content: text)) }
            else { hasMore = true }
        }
    }
    let nextLine = hasMore ? (lines.last?.number ?? start) + 1 : nil
    return ReadPage(path: relativePath(file, workspace: workspace), lines: lines, startLine: lines.first?.number ?? start, endLine: lines.last?.number ?? start - 1, nextLine: nextLine, truncated: hasMore, hash: nil, version: try fileVersion(file))
}

public struct ReadFileTool: ToolExecutor {
    public static let maximumBytes = 1_024 * 1_024
    private let workspace: WorkspaceRoot

    public init(workspace: WorkspaceRoot) {
        self.workspace = workspace
    }

    public let definition = ToolDefinition(
        id: ToolID("read_file"),
        description: "Read a UTF-8 text file inside the workspace.",
        inputSchema: ToolInputSchema(
            properties: [
                "path": ToolInputProperty(type: .string, description: "File path to read (workspace-relative or absolute path)"),
                "start_line": ToolInputProperty(type: .integer, description: "1-based start line"),
                "end_line": ToolInputProperty(type: .integer, description: "1-based end line")
            ],
            required: ["path"]
        ),
        capability: ToolCapability(readOnly: true)
    )

    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        try workspace.resolve(pathArguments(arguments).path, profile: profile).path
    }

    public func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        filesystemCapabilities(try workspace.resolve(pathArguments(arguments).path, profile: profile), workspace: workspace, write: false)
    }

    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: ReadArguments = try decodeArguments(arguments)
        let file = try workspace.resolve(input.path, profile: profile)
        if input.startLine != nil || input.endLine != nil || input.maxLines != nil || input.lineNumbers == true {
            return try json(readPage(file, workspace: workspace, input: input))
        }
        return try readText(file, operation: "read_file")
    }
}

public struct ContextRecallTool: ToolExecutor {
    private let ecoreStore: ECoreObjectStore?
    private let sessionID: SessionID?

    public init(ecoreStore: ECoreObjectStore? = nil, sessionID: SessionID? = nil) {
        self.ecoreStore = ecoreStore
        self.sessionID = sessionID
    }

    public let definition = ToolDefinition(
        id: ToolID("context_recall"),
        description: "Recall observation content by object ID and byte offset",
        inputSchema: ToolInputSchema(
            properties: [
                "id": ToolInputProperty(type: .string, description: "Context object ID"),
                "offset": ToolInputProperty(type: .integer, description: "Start byte offset"),
                "limit_bytes": ToolInputProperty(type: .integer, description: "Max bytes (default 16KB)"),
                "limit_lines": ToolInputProperty(type: .integer, description: "Max lines (default 400)"),
                "session_id": ToolInputProperty(type: .string, description: "Target session ID (optional)")
            ],
            required: ["id"]
        ),
        capability: ToolCapability(readOnly: true)
    )

    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        ""
    }

    public func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        [.projectRead]
    }

    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        struct Input: Decodable {
            let id: String
            let offset: Int?
            let limitBytes: Int?
            let limitLines: Int?
            let sessionId: String?
        }
        let input: Input = try decodeArguments(arguments)
        let objectID: ContextObjectID
        do {
            objectID = try ContextObjectID(input.id)
        } catch {
            return "Error: Invalid ContextObjectID format '\(input.id)'"
        }

        guard let store = ecoreStore else {
            return "Error: E-Core object store is not configured."
        }

        let sID = input.sessionId.map(SessionID.init) ?? self.sessionID ?? ToolExecutionContext.sessionID ?? SessionID("default")
        let chunk = try await store.recall(
            sessionID: sID,
            objectID: objectID,
            offsetBytes: max(0, input.offset ?? 0),
            limitBytes: input.limitBytes,
            limitLines: input.limitLines
        )

        guard let chunk else {
            return "Context object '\(objectID.rawValue)' not found in session '\(sID.rawValue)'."
        }

        return """
        [Context Object Slice: \(chunk.objectID.rawValue)]
        Lines: \(chunk.startLine) - \(chunk.endLine) of \(chunk.totalLines)
        Bytes: \(chunk.offsetBytes) - \(chunk.offsetBytes + chunk.lengthBytes) of \(chunk.totalBytes)
        Has More: \(chunk.hasMore ? "true" : "false")
        --- Content ---
        \(chunk.content)
        """
    }
}

public struct ListDirectoryTool: ToolExecutor {
    private let workspace: WorkspaceRoot

    public init(workspace: WorkspaceRoot) {
        self.workspace = workspace
    }

    public let definition = ToolDefinition(
        id: ToolID("list_directory"),
        description: "List direct entries of a directory inside the workspace.",
        inputSchema: ToolInputSchema(
            properties: ["path": ToolInputProperty(type: .string, description: "Workspace-relative directory path")],
            required: ["path"]
        ),
        capability: ToolCapability(readOnly: true)
    )

    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        try workspace.resolve(pathArguments(arguments).path, profile: profile).path
    }

    public func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        filesystemCapabilities(try workspace.resolve(pathArguments(arguments).path, profile: profile), workspace: workspace, write: false)
    }

    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let directory = try workspace.resolve(pathArguments(arguments).path, profile: profile)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw CoreError(code: .toolExecutionFailed, message: "目录不存在: \(directory.path)")
        }
        guard isDirectory.boolValue else {
            throw CoreError(code: .toolExecutionFailed, message: "list_directory 只能读取目录: \(directory.path)")
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return try entries.filter { !workspace.sensitivePathPolicy.isSensitive($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { entry in
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirectoryEntry = values.isDirectory == true
            let kind = isDirectoryEntry ? "directory" : "file"
            // A directory's st_size is an implementation detail of the filesystem (an inode's
            // linked-entry count on ext4, a fixed allocation on APFS), so it carries no meaning
            // that survives a platform change.
            let size = isDirectoryEntry ? "-" : (values.fileSize.map(String.init) ?? "-")
            return "\(entry.lastPathComponent)\t\(kind)\t\(size)"
        }.joined(separator: "\n")
    }
}

private func regex(forGlob pattern: String) throws -> NSRegularExpression {
    let characters = Array(pattern)
    var source = "^"
    var index = 0
    while index < characters.count {
        switch characters[index] {
        case "*":
            if index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                if index < characters.count, characters[index] == "/" {
                    source += "(?:.*/)?"
                    index += 1
                } else {
                    source += ".*"
                }
                continue
            }
            source += "[^/]*"
        case "?": source += "[^/]"
        case "\\", ".", "^", "$", "|", "(", ")", "[", "]", "{", "}", "+":
            source += "\\"
            source.append(characters[index])
        default: source.append(characters[index])
        }
        index += 1
    }
    return try NSRegularExpression(pattern: source + "$")
}

private func files(at root: URL, workspace: WorkspaceRoot, profile: ExecutionProfile) throws -> [URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
        throw CoreError(code: .toolExecutionFailed, message: "路径不存在: \(root.path)")
    }
    guard isDirectory.boolValue else { return [root] }
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
        throw CoreError(code: .toolExecutionFailed, message: "无法枚举目录: \(root.path)")
    }
    var result: [URL] = []
    while let entry = enumerator.nextObject() as? URL {
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true { enumerator.skipDescendants() }
        if workspace.sensitivePathPolicy.isSensitive(entry) {
            if values?.isDirectory == true { enumerator.skipDescendants() }
            continue
        }
        if let resolved = try? workspace.resolve(entry.path, profile: profile) { result.append(resolved) }
    }
    return result
}

public struct GlobTool: ToolExecutor {
    private let workspace: WorkspaceRoot
    public init(workspace: WorkspaceRoot) { self.workspace = workspace }
    public let definition = ToolDefinition(
        id: ToolID("glob"), description: "Find workspace files matching a glob pattern.",
        inputSchema: ToolInputSchema(properties: [
            "pattern": ToolInputProperty(type: .string, description: "Glob pattern"),
            "path": ToolInputProperty(type: .string, description: "Workspace-relative search root"),
            "max_results": ToolInputProperty(type: .integer, description: "Maximum matches", minimum: 1)
        ], required: ["pattern"]), capability: ToolCapability(readOnly: true)
    )
    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: GlobArguments = try decodeArguments(arguments)
        return try workspace.resolve(input.path ?? ".", profile: profile).path
    }
    public func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        filesystemCapabilities(URL(fileURLWithPath: try resource(for: arguments, profile: profile)), workspace: workspace, write: false)
    }
    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: GlobArguments = try decodeArguments(arguments)
        let root = try workspace.resolve(input.path ?? ".", profile: profile)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw CoreError(code: .toolExecutionFailed, message: "路径不存在: \(root.path)")
        }
        guard isDirectory.boolValue else {
            throw CoreError(code: .toolExecutionFailed, message: "glob 搜索根路径必须是目录: \(root.path)")
        }
        let limit = min(max(1, input.maxResults ?? 1_000), 10_000)
        let result = try await runRipgrep(arguments: ripgrepArguments(input, root: root), root: root, workspace: workspace, profile: profile)
        let paths = ignoredByWorkspaceGitignore(result.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init), root: root, includeIgnored: input.includeIgnored)
            .map { workspaceRelativeSearchPath($0, root: root, workspace: workspace) }
            .sorted()
        return try json(Array(paths.prefix(limit)))
    }
}

private struct GrepMatch: Codable { let path: String; let line: Int; let content: String }
private struct SearchResult<T: Codable>: Codable { let matches: [T]; let truncated: Bool }

private func ripgrepExecutable() throws -> String {
    guard let executable = LingXiPlatform.process.resolveExecutable(named: "rg", customSearchPaths: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]) else {
        throw CoreError(code: .toolExecutionFailed, message: "未找到受支持的 ripgrep (rg) 可执行文件")
    }
    return executable
}

private func generatedExcludes(_ includeGenerated: Bool?) -> [String] {
    guard includeGenerated != true else { return [] }
    return ["!**/.build/**", "!**/build/**", "!**/dist/**", "!**/node_modules/**", "!**/vendor/**", "!**/coverage/**"]
}

private let sensitiveSearchExcludes = [
    "!**/.ssh/**", "!**/.aws/**", "!**/.gnupg/**", "!**/.netrc", "!**/.npmrc",
    "!**/.env", "!**/.env.*", "!**/*.env", "!**/*.pem", "!**/*.key",
    "!**/credentials.vault", "!**/.vault_key", "!**/.master_key",
    "!**/*-credentials.*", "!**/*_credentials.*", "!**/credential.json", "!**/credentials.json",
    "!**/*-secret.*", "!**/*_secret.*", "!**/private-secret/**",
    "!**/*-token.*", "!**/*_token.*"
]

private func workspaceIgnoreArguments(root: URL, includeIgnored: Bool?) -> [String] {
    guard includeIgnored != true else { return [] }
    let ignore = root.appendingPathComponent(".gitignore")
    return FileManager.default.fileExists(atPath: ignore.path) ? ["--ignore-file", ignore.path] : []
}

private func ignoredByWorkspaceGitignore(_ paths: [String], root: URL, includeIgnored: Bool?) -> [String] {
    guard includeIgnored != true,
          let text = try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
    else { return paths }
    let patterns = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
    return paths.filter { original in
        var path = original.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        var ignored = false
        for raw in patterns {
            let negated = raw.hasPrefix("!")
            let pattern = (negated ? String(raw.dropFirst()) : raw).replacingOccurrences(of: "\\", with: "/")
            let matches: Bool
            if !pattern.contains("/") { matches = path.split(separator: "/").contains(pattern[...]) }
            else { matches = (try? regex(forGlob: pattern).firstMatch(in: path, range: NSRange(path.startIndex..., in: path))) != nil }
            if matches { ignored = !negated }
        }
        return !ignored
    }
}

private func ripgrepArguments(_ input: GlobArguments, root: URL) -> [String] {
    var arguments = ["--files", "--no-require-git", "--color", "never", "--glob", input.pattern]
    if input.includeHidden == true { arguments.append("--hidden") }
    if input.includeIgnored == true { arguments.append("--no-ignore") }
    arguments += workspaceIgnoreArguments(root: root, includeIgnored: input.includeIgnored)
    for exclude in generatedExcludes(input.includeGenerated) + sensitiveSearchExcludes { arguments += ["--glob", exclude] }
    return arguments
}

private func ripgrepArguments(_ input: GrepArguments, root: URL, targetIsFile: Bool = false, filePath: String? = nil) -> [String] {
    var arguments = ["--json", "--no-require-git", "--line-number", "--color", "never", "--regexp", input.pattern]
    if !targetIsFile, let glob = input.glob { arguments += ["--glob", glob] }
    if input.includeHidden == true { arguments.append("--hidden") }
    if input.includeIgnored == true { arguments.append("--no-ignore") }
    arguments += workspaceIgnoreArguments(root: root, includeIgnored: input.includeIgnored)
    for exclude in generatedExcludes(input.includeGenerated) + sensitiveSearchExcludes { arguments += ["--glob", exclude] }
    if targetIsFile, let filePath {
        arguments.append(filePath)
    } else {
        arguments.append(".")
    }
    return arguments
}

private func runRipgrep(arguments: [String], root: URL, workspace: WorkspaceRoot, profile: ExecutionProfile) async throws -> CommandResult {
    let executable = try ripgrepExecutable()
    let setup = try processSetup(executable: executable, arguments: arguments, workspace: workspace, cwd: root, profile: profile)
    let result = try await runToolProcess(invocation: setup.0, cwd: root, environment: setup.1, timeoutMilliseconds: 30_000, lifecycleTrace: ToolExecutionContext.lifecycleTrace)
    guard result.exitCode == 0 || result.exitCode == 1 else {
        throw CoreError(code: .commandFailed, message: try json(result))
    }
    return result
}

private func workspaceRelativeSearchPath(_ path: String, root: URL, workspace: WorkspaceRoot) -> String {
    var normalized = path.replacingOccurrences(of: "\\", with: "/")
    if LingXiPlatform.path.isAbsolute(normalized) {
        let wsPath = workspace.url.path.replacingOccurrences(of: "\\", with: "/")
        if normalized == wsPath { return "." }
        if normalized.hasPrefix(wsPath + "/") {
            return String(normalized.dropFirst(wsPath.count + 1))
        }
    }
    if normalized.hasPrefix("./") {
        normalized = String(normalized.dropFirst(2))
    }
    let rootPath = root.path.replacingOccurrences(of: "\\", with: "/")
    let wsPath = workspace.url.path.replacingOccurrences(of: "\\", with: "/")
    if rootPath == wsPath { return normalized }
    let prefix = relativePath(root, workspace: workspace).replacingOccurrences(of: "\\", with: "/")
    return prefix == "." || prefix.isEmpty ? normalized : prefix + "/" + normalized
}

public struct GrepTool: ToolExecutor {
    private let workspace: WorkspaceRoot
    public init(workspace: WorkspaceRoot) { self.workspace = workspace }
    public let definition = ToolDefinition(
        id: ToolID("grep"), description: "Search UTF-8 workspace files with a regular expression.",
        inputSchema: ToolInputSchema(properties: [
            "pattern": ToolInputProperty(type: .string, description: "Regular expression"),
            "path": ToolInputProperty(type: .string, description: "Workspace-relative search root"),
            "max_results": ToolInputProperty(type: .integer, description: "Maximum matches", minimum: 1)
        ], required: ["pattern"]), capability: ToolCapability(readOnly: true)
    )
    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: GrepArguments = try decodeArguments(arguments)
        return try workspace.resolve(input.path ?? ".", profile: profile).path
    }
    public func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        filesystemCapabilities(URL(fileURLWithPath: try resource(for: arguments, profile: profile)), workspace: workspace, write: false)
    }
    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: GrepArguments = try decodeArguments(arguments)
        let target = try workspace.resolve(input.path ?? ".", profile: profile)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            throw CoreError(code: .toolExecutionFailed, message: "搜索路径不存在: \(target.path)")
        }
        let limit = min(max(1, input.maxResults ?? 1_000), 10_000)
        let targetIsFile = !isDirectory.boolValue
        if targetIsFile, workspace.sensitivePathPolicy.isSensitive(target) {
            return try json([GrepMatch]())
        }
        let runDir = targetIsFile ? (FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) ? target.deletingLastPathComponent() : workspace.url) : target
        let rgArgs = ripgrepArguments(input, root: runDir, targetIsFile: targetIsFile, filePath: targetIsFile ? target.path : nil)
        let result = try await runRipgrep(arguments: rgArgs, root: runDir, workspace: workspace, profile: profile)
        var matches: [GrepMatch] = []
        for row in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = row.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "match",
                  let payload = object["data"] as? [String: Any],
                  let pathObject = payload["path"] as? [String: Any],
                  let path = pathObject["text"] as? String,
                  let line = (payload["line_number"] as? NSNumber)?.intValue,
                  let lineObject = payload["lines"] as? [String: Any],
                  let text = lineObject["text"] as? String
            else { continue }
            let relPath = workspaceRelativeSearchPath(path, root: runDir, workspace: workspace)
            matches.append(GrepMatch(path: relPath, line: line, content: text.hasSuffix("\n") ? String(text.dropLast()) : text))
        }
        let ordered = matches.filter { !ignoredByWorkspaceGitignore([$0.path], root: runDir, includeIgnored: input.includeIgnored).isEmpty }.sorted { $0.path == $1.path ? $0.line < $1.line : $0.path < $1.path }
        return try json(Array(ordered.prefix(limit)))
    }
}

private struct FileWriteResult: Codable {
    let path: String
    let bytes: Int
    let hash: String
    let version: String
}

private struct CommandToolResult: Codable {
    let command: String
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let summary: String

    enum CodingKeys: String, CodingKey { case command, stdout, stderr, exitCode = "exit_code", summary }
}

public struct WriteFileTool: ToolExecutor {
    private let workspace: WorkspaceRoot
    public init(workspace: WorkspaceRoot) { self.workspace = workspace }
    public let definition = ToolDefinition(
        id: ToolID("write_file"), description: "Write UTF-8 text to a file. Supports workspace-relative paths, absolute paths, ~, and $HOME (e.g. ~/Desktop/file.txt).",
        inputSchema: ToolInputSchema(properties: [
            "path": ToolInputProperty(type: .string, description: "File path (supports workspace-relative, absolute, ~, and $HOME)"),
            "content": ToolInputProperty(type: .string, description: "Replacement file content"),
            "expected_hash": ToolInputProperty(type: .string, description: "Current SHA-256 required before writing"),
            "expected_version": ToolInputProperty(type: .string, description: "Current version required before writing"),
            "overwrite": ToolInputProperty(type: .boolean, description: "Explicitly bypass stale-content checks")
        ], required: ["path", "content"]), capability: ToolCapability(readOnly: false)
    )
    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: WriteArguments = try decodeArguments(arguments)
        return try workspace.resolve(input.path, profile: profile).path
    }
    public func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        filesystemCapabilities(URL(fileURLWithPath: try resource(for: arguments, profile: profile)), workspace: workspace, write: true)
    }
    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: WriteArguments = try decodeArguments(arguments)
        let file = try workspace.resolve(input.path, profile: profile)
        if FileManager.default.fileExists(atPath: file.path) {
            let existing = try readText(file, operation: "write_file")
            try checkExpectedContent(existing, hash: input.expectedHash, version: input.expectedVersion, currentVersion: try fileVersion(file), overwrite: input.overwrite)
        }
        try writeText(input.content, to: file)
        if await FormatCoordinator.shared.autoFormatEnabled() {
            _ = await FormatCoordinator.shared.format(fileURL: file, workspaceRoot: workspace.url)
        }
        return try json(fileWriteResult(for: file, workspace: workspace, content: input.content))
    }
}

public struct EditFileTool: ToolExecutor {
    private let workspace: WorkspaceRoot
    public init(workspace: WorkspaceRoot) { self.workspace = workspace }
    public let definition = ToolDefinition(
        id: ToolID("edit_file"), description: "Replace exact text in a UTF-8 file. Supports workspace-relative paths, absolute paths, ~, and $HOME.",
        inputSchema: ToolInputSchema(properties: [
            "path": ToolInputProperty(type: .string, description: "File path (supports workspace-relative, absolute, ~, and $HOME)"),
            "old_string": ToolInputProperty(type: .string, description: "Text to replace"),
            "new_string": ToolInputProperty(type: .string, description: "Replacement text"),
            "replace_all": ToolInputProperty(type: .boolean, description: "Replace every occurrence"),
            "expected_hash": ToolInputProperty(type: .string, description: "Current SHA-256 required before editing"),
            "expected_version": ToolInputProperty(type: .string, description: "Current version required before editing"),
            "overwrite": ToolInputProperty(type: .boolean, description: "Explicitly bypass stale-content checks")
        ], required: ["path", "old_string", "new_string"]), capability: ToolCapability(readOnly: false)
    )
    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: EditArguments = try decodeArguments(arguments)
        return try workspace.resolve(input.path, profile: profile).path
    }
    public func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        filesystemCapabilities(URL(fileURLWithPath: try resource(for: arguments, profile: profile)), workspace: workspace, write: true)
    }
    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: EditArguments = try decodeArguments(arguments)
        guard !input.oldString.isEmpty else { throw CoreError(code: .toolArgumentInvalid, message: "old_string 不能为空") }
        let file = try workspace.resolve(input.path, profile: profile)
        let original = try readText(file, operation: "edit_file")
        try checkExpectedContent(original, hash: input.expectedHash, version: input.expectedVersion, currentVersion: try fileVersion(file), overwrite: input.overwrite)
        let count = original.components(separatedBy: input.oldString).count - 1
        guard count > 0 else { throw CoreError(code: .contentChanged, message: "未找到要替换的文本: \(file.path)") }
        guard input.replaceAll == true || count == 1 else { throw CoreError(code: .ambiguousEdit, message: "匹配到 \(count) 处文本；请使用 replace_all") }
        let updated = input.replaceAll == true ? original.replacingOccurrences(of: input.oldString, with: input.newString) : original.replacingOccurrences(of: input.oldString, with: input.newString, options: [], range: original.range(of: input.oldString))
        try writeText(updated, to: file)
        if await FormatCoordinator.shared.autoFormatEnabled() {
            _ = await FormatCoordinator.shared.format(fileURL: file, workspaceRoot: workspace.url)
        }
        return try json(fileWriteResult(for: file, workspace: workspace, content: updated))
    }
}

private enum PatchKind: Equatable { case add, update, delete }
private struct PatchSpec { var kind: PatchKind; var path: String; var moveTo: String?; var lines: [String] }
private struct PatchWrite { let url: URL; let content: String }
private struct PatchPlan { let writes: [PatchWrite]; let deletes: [URL] }
private struct PatchResult: Codable { let operation: String; let path: String }

/// 测试可通过此钩子在第 N 次落盘前制造失败，验证补丁事务的回滚。
public enum ApplyPatchFailpoint {
    private static let state = ApplyPatchFailpointState()

    public static func fail(after operation: Int?) { state.set(after: operation) }

    fileprivate static func shouldFail(at operation: Int) -> Bool {
        state.shouldFail(at: operation)
    }
}

private final class ApplyPatchFailpointState: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: Int?
    func set(after operation: Int?) { lock.lock(); self.operation = operation; lock.unlock() }
    func shouldFail(at operation: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return self.operation == operation }
}

private struct PatchSnapshot { let url: URL; let data: Data? }

private func patchSnapshots(for plan: PatchPlan) throws -> [PatchSnapshot] {
    try Dictionary(grouping: plan.writes.map(\.url) + plan.deletes, by: \.path).values.map { urls in
        let url = urls[0]
        return PatchSnapshot(url: url, data: FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil)
    }
}

private func restorePatchSnapshots(_ snapshots: [PatchSnapshot]) throws {
    for snapshot in snapshots {
        if let data = snapshot.data {
            try data.write(to: snapshot.url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: snapshot.url.path) {
            try FileManager.default.removeItem(at: snapshot.url)
        }
    }
}

private func parsePatch(_ patch: String) throws -> [PatchSpec] {
    var lines = patch.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    while lines.last == "" { lines.removeLast() }
    guard lines.first == "*** Begin Patch", lines.last == "*** End Patch" else {
        throw CoreError(code: .invalidPatch, message: "Patch 必须以 *** Begin Patch 和 *** End Patch 包裹")
    }
    var specs: [PatchSpec] = []
    var current: PatchSpec?
    func flush() { if let current { specs.append(current) } }
    for line in lines.dropFirst().dropLast() {
        if line.hasPrefix("*** Add File: ") || line.hasPrefix("*** Update File: ") || line.hasPrefix("*** Delete File: ") {
            flush()
            let add = line.hasPrefix("*** Add File: ")
            let update = line.hasPrefix("*** Update File: ")
            let prefix = add ? "*** Add File: " : update ? "*** Update File: " : "*** Delete File: "
            let path = String(line.dropFirst(prefix.count))
            guard !path.isEmpty else { throw CoreError(code: .invalidPatch, message: "Patch 路径不能为空") }
            current = PatchSpec(kind: add ? .add : update ? .update : .delete, path: path, moveTo: nil, lines: [])
        } else if line.hasPrefix("*** Move to: ") {
            guard var spec = current, spec.kind == .update else {
                throw CoreError(code: .invalidPatch, message: "Move to 必须紧随 Update File")
            }
            let path = String(line.dropFirst("*** Move to: ".count))
            guard !path.isEmpty else { throw CoreError(code: .invalidPatch, message: "移动目标不能为空") }
            spec.moveTo = path
            current = spec
        } else {
            guard var spec = current else { throw CoreError(code: .invalidPatch, message: "Patch 缺少文件操作") }
            spec.lines.append(line)
            current = spec
        }
    }
    flush()
    guard !specs.isEmpty else { throw CoreError(code: .invalidPatch, message: "Patch 不包含文件操作") }
    return specs
}

private func applyHunks(_ rows: [String], to content: String) throws -> String {
    var result = content.components(separatedBy: "\n")
    var hunks: [[String]] = [[]]
    for row in rows {
        if row.hasPrefix("@@") { hunks.append([]) }
        else if row == "\\ No newline at end of file" { continue }
        else { hunks[hunks.count - 1].append(row) }
    }
    for hunk in hunks where !hunk.isEmpty {
        var old: [String] = []
        var new: [String] = []
        for row in hunk {
            guard let marker = row.first, marker == " " || marker == "+" || marker == "-" else {
                throw CoreError(code: .invalidPatch, message: "Update 行必须以空格、+ 或 - 开头")
            }
            let line = String(row.dropFirst())
            if marker != "+" { old.append(line) }
            if marker != "-" { new.append(line) }
        }
        guard !old.isEmpty, result.count >= old.count else {
            throw CoreError(code: .patchConflict, message: "Patch 缺少可定位的上下文")
        }
        let positions = (0...(result.count - old.count)).filter { Array(result[$0..<$0 + old.count]) == old }
        guard positions.count == 1, let position = positions.first else {
            throw CoreError(code: .patchConflict, message: positions.isEmpty ? "Patch 上下文不匹配" : "Patch 上下文不唯一")
        }
        result.replaceSubrange(position..<(position + old.count), with: new)
    }
    return result.joined(separator: "\n")
}

private func patchPlan(_ specs: [PatchSpec], expectedHashes: [String: String]?, workspace: WorkspaceRoot, profile: ExecutionProfile) throws -> PatchPlan {
    var writes: [PatchWrite] = []
    var deletes: [URL] = []
    var touched = Set<String>()
    for spec in specs {
        let source = try workspace.resolve(spec.path, profile: profile)
        let target = try spec.moveTo.map { try workspace.resolve($0, profile: profile) } ?? source
        let paths = target == source ? [source.path] : [source.path, target.path]
        guard touched.isDisjoint(with: paths) else { throw CoreError(code: .invalidPatch, message: "Patch 重复操作文件") }
        touched.formUnion(paths)
        switch spec.kind {
        case .add:
            guard spec.lines.allSatisfy({ $0.hasPrefix("+") }) else { throw CoreError(code: .invalidPatch, message: "Add File 内容必须以 + 开头") }
            guard !FileManager.default.fileExists(atPath: source.path) else { throw CoreError(code: .patchConflict, message: "文件已存在: \(source.path)") }
            try writableFile(source)
            let content = spec.lines.map { String($0.dropFirst()) }.joined(separator: "\n") + (spec.lines.isEmpty ? "" : "\n")
            writes.append(PatchWrite(url: source, content: content))
        case .update:
            let original = try readText(source, operation: "apply_patch")
            if let expected = expectedHashes?[spec.path], expected.lowercased().replacingOccurrences(of: "sha256:", with: "") != sha256Hex(original) {
                throw CoreError(code: .contentChanged, message: "Patch 前置版本不匹配: \(spec.path)")
            }
            try writableFile(target)
            if target != source {
                guard !FileManager.default.fileExists(atPath: target.path) else { throw CoreError(code: .patchConflict, message: "移动目标已存在: \(target.path)") }
                try writableFile(target)
                deletes.append(source)
            }
            writes.append(PatchWrite(url: target, content: try applyHunks(spec.lines, to: original)))
        case .delete:
            guard spec.lines.isEmpty else { throw CoreError(code: .invalidPatch, message: "Delete File 不接受内容") }
            let original = try readText(source, operation: "apply_patch")
            if let expected = expectedHashes?[spec.path], expected.lowercased().replacingOccurrences(of: "sha256:", with: "") != sha256Hex(original) {
                throw CoreError(code: .contentChanged, message: "Patch 前置版本不匹配: \(spec.path)")
            }
            deletes.append(source)
        }
    }
    return PatchPlan(writes: writes, deletes: deletes)
}

public struct ApplyPatchTool: ToolExecutor {
    private let workspace: WorkspaceRoot
    public init(workspace: WorkspaceRoot) { self.workspace = workspace }
    public let definition = ToolDefinition(
        id: ToolID("apply_patch"), description: "Apply an Add, Update, Delete, or Move patch in the workspace.",
        inputSchema: ToolInputSchema(properties: [
            "patch": ToolInputProperty(type: .string, description: "Patch in *** Begin Patch syntax")
        ], required: ["patch"]),
        capability: ToolCapability([.projectWrite, .destructive])
    )
    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: PatchArguments = try decodeArguments(arguments)
        return try parsePatch(input.patch).map { try workspace.resolve($0.path, profile: profile).path }.sorted().joined(separator: ",")
    }
    public func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        let input: PatchArguments = try decodeArguments(arguments)
        let specs = try parsePatch(input.patch)
        var result: Set<ToolCapabilityKind> = [.projectWrite, .destructive]
        for spec in specs {
            for path in [spec.path, spec.moveTo].compactMap({ $0 }) {
                result.formUnion(filesystemCapabilities(try workspace.resolve(path, profile: profile), workspace: workspace, write: true))
            }
        }
        return result
    }
    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: PatchArguments = try decodeArguments(arguments)
        let specs = try parsePatch(input.patch)
        let plan = try patchPlan(specs, expectedHashes: input.expectedHashes, workspace: workspace, profile: profile)
        let snapshots = try patchSnapshots(for: plan)
        do {
            var operation = 0
            for write in plan.writes {
                operation += 1
                if ApplyPatchFailpoint.shouldFail(at: operation) { throw CoreError(code: .toolExecutionFailed, message: "apply_patch failpoint \(operation)") }
                try writeText(write.content, to: write.url)
                if await FormatCoordinator.shared.autoFormatEnabled() {
                    _ = await FormatCoordinator.shared.format(fileURL: write.url, workspaceRoot: workspace.url)
                }
            }
            for file in plan.deletes {
                operation += 1
                if ApplyPatchFailpoint.shouldFail(at: operation) { throw CoreError(code: .toolExecutionFailed, message: "apply_patch failpoint \(operation)") }
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            do {
                try restorePatchSnapshots(snapshots)
            } catch {
                throw CoreError(code: .patchConflict, message: "Patch 失败且回滚失败: \(error.localizedDescription)")
            }
            throw error
        }
        let results = specs.map { PatchResult(operation: $0.kind == .add ? "add" : $0.kind == .delete ? "delete" : $0.moveTo == nil ? "update" : "move", path: $0.moveTo ?? $0.path) }
        return try json(results)
    }
}

private func cwd(_ value: String?, workspace: WorkspaceRoot, profile: ExecutionProfile) throws -> URL {
    let url = try workspace.resolve(value ?? ".", profile: profile)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        throw CoreError(code: .toolExecutionFailed, message: "工作目录不存在: \(url.path)")
    }
    guard isDirectory.boolValue else {
        throw CoreError(code: .toolExecutionFailed, message: "工作目录必须是目录而不是文件: \(url.path)")
    }
    return url
}

func processSetup(executable: String, arguments: [String], workspace: WorkspaceRoot, cwd: URL, profile: ExecutionProfile) throws -> (ToolProcessInvocation, [String: String]) {
    guard LingXiPlatform.path.isAbsolute(executable), FileManager.default.isExecutableFile(atPath: executable) else {
        throw CoreError(code: .toolArgumentInvalid, message: "executable 必须是可执行的绝对路径")
    }
    var environment = EnvironmentSanitizer.sanitized()
    let temporary = workspace.url.appendingPathComponent(".lingxi-tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    environment["TMPDIR"] = temporary.path
    // /usr/bin/git is a system tool; inherited Xcode selection can force xcrun to write host-global caches outside policy.
    if executable.hasSuffix("/git") {
        environment.removeValue(forKey: "DEVELOPER_DIR")
        environment.removeValue(forKey: "SDKROOT")
        environment.removeValue(forKey: "TOOLCHAINS")
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
    }
    if profile == .workspace {
        let developerDirectory = environment["DEVELOPER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let policy = SandboxPolicy(
            workspace: workspace.url,
            readOnlyPaths: developerDirectory.map { [$0] } ?? [],
            workingDirectory: cwd
        )
        return (try workspaceInvocation(executable: executable, arguments: arguments, policy: policy), environment)
    }
    return (ToolProcessInvocation(executable: executable, arguments: arguments), environment)
}

private func isReadOnlyShellCommand(_ cmd: String) -> Bool {
    var trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    trimmed = trimmed.replacingOccurrences(of: "2>/dev/null", with: "")
        .replacingOccurrences(of: ">/dev/null", with: "")
        .replacingOccurrences(of: "1>/dev/null", with: "")
        .replacingOccurrences(of: "2>&1", with: "")
        .replacingOccurrences(of: "&>/dev/null", with: "")
    if trimmed.contains(">") || trimmed.contains("rm ") || trimmed.contains("mv ") || trimmed.contains("cp ") || trimmed.contains("mkdir ") || trimmed.contains("touch ") || trimmed.contains("chmod ") || trimmed.contains("chown ") || trimmed.contains("tee ") {
        return false
    }
    let readOnlyTokens: Set<String> = ["ls", "pwd", "which", "echo", "cat", "head", "tail", "grep", "find", "diff", "file", "stat", "true", "false", "wc", "readlink", "whoami", "uname", "id", "hostname", "date"]
    let firstToken = trimmed.components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "|;&"))).first { !$0.isEmpty } ?? ""
    let base = URL(fileURLWithPath: firstToken).lastPathComponent
    return readOnlyTokens.contains(base)
}

public struct ShellTool: ToolExecutor {
    private let workspace: WorkspaceRoot
    public init(workspace: WorkspaceRoot) { self.workspace = workspace }
    public let definition = ToolDefinition(
        id: ToolID("shell"), description: "Run a synchronous foreground shell command. IMPORTANT: Never run long-running tasks, servers, watchers, sleep, or background requests here. For background tasks or commands that shouldn't block the conversation, use 'run_background_command' instead.",
        inputSchema: ToolInputSchema(properties: [
            "command": ToolInputProperty(type: .string, description: "Shell command"),
            "executable": ToolInputProperty(type: .string, description: "Absolute executable path"),
            "arguments": ToolInputProperty(type: .array, description: "Executable argv"),
            "cwd": ToolInputProperty(type: .string, description: "Workspace-relative working directory"),
            "timeout_ms": ToolInputProperty(type: .integer, description: "Timeout in milliseconds", minimum: 1, maximum: 300_000)
        ], required: []), capability: ToolCapability([.processExecute])
    )
    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: ShellArguments = try decodeArguments(arguments)
        _ = try cwd(input.cwd, workspace: workspace, profile: profile)
        return input.command ?? ([input.executable ?? ""] + (input.arguments ?? [])).joined(separator: " ")
    }
    public func externalResource(for arguments: String, profile: ExecutionProfile) throws -> String? {
        let input: ShellArguments = try decodeArguments(arguments)
        return try cwd(input.cwd, workspace: workspace, profile: profile).path
    }
    public func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        let input: ShellArguments = try decodeArguments(arguments)
        let isWrite = !isReadOnlyShellCommand(input.command ?? input.executable ?? "")
        return Set([.processExecute]).union(filesystemCapabilities(try cwd(input.cwd, workspace: workspace, profile: profile), workspace: workspace, write: isWrite))
    }
    public static func isBackgroundShellCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("&") && !trimmed.hasSuffix("&&") {
            return true
        }
        if let regex = try? NSRegularExpression(pattern: #"(?<![&>])&(?![&>0-9])"#) {
            let range = NSRange(command.startIndex..<command.endIndex, in: command)
            if regex.firstMatch(in: command, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: ShellArguments = try decodeArguments(arguments)
        let command: (String, [String])
        if let shell = input.command {
            if Self.isBackgroundShellCommand(shell) {
                throw CoreError(
                    code: .toolArgumentInvalid,
                    message: "禁止在 shell 中直接使用 '&' 盲放后台。长耗时或后台任务必须使用 'run_background_command'（必须指定 timeout_seconds，1~7200 秒），以便由看门狗管理并在完成后主动注入通知。"
                )
            }
            #if os(Windows)
            let shellExe = LingXiPlatform.process.resolveExecutable(named: "powershell.exe", customSearchPaths: nil) ?? "C:\\Windows\\System32\\cmd.exe"
            let shellArgs = shellExe.lowercased().contains("powershell") ? ["-NoProfile", "-NonInteractive", "-Command", shell] : ["/c", shell]
            command = (shellExe, shellArgs)
            #else
            let shellExe = LingXiPlatform.process.resolveExecutable(named: "sh", customSearchPaths: ["/bin", "/usr/bin"]) ?? "/bin/sh"
            command = (shellExe, ["-c", shell])
            #endif
        } else if let executable = input.executable {
            command = (executable, input.arguments ?? [])
        } else {
            throw CoreError(code: .toolArgumentInvalid, message: "shell 需要 command 或 executable")
        }
        let directory = try cwd(input.cwd, workspace: workspace, profile: profile)
        let setup = try processSetup(executable: command.0, arguments: command.1, workspace: workspace, cwd: directory, profile: profile)
        let result = try await runToolProcess(invocation: setup.0, cwd: directory, environment: setup.1, timeoutMilliseconds: input.timeoutMs ?? 60_000, lifecycleTrace: ToolExecutionContext.lifecycleTrace)
        guard result.exitCode == 0 else { throw CoreError(code: .commandFailed, message: try json(result)) }
        return try json(result)
    }
}

public enum GitAction: String, Codable, Sendable, CaseIterable {
    case status, diff, log, show, branch, add, restore, checkout, `switch`, commit
}

private func gitCommand(_ input: GitArguments) throws -> (GitAction, [String]) {
    if let action = input.action {
        switch action {
        case .status: return (action, ["status", "--short"])
        case .diff: return (action, ["diff", "--"] + (input.paths ?? []))
        case .log: return (action, ["log", "--oneline", "-n", String(min(max(input.limit ?? 10, 1), 100))])
        case .show: return (action, ["show", input.reference ?? "HEAD"])
        case .branch: return (action, input.branch.map { ["branch", $0] } ?? ["branch"])
        case .add: return (action, ["add", "--"] + (input.paths ?? []))
        case .restore: return (action, ["restore", "--"] + (input.paths ?? []))
        case .checkout: guard let reference = input.reference else { throw CoreError(code: .toolArgumentInvalid, message: "checkout 需要 reference") }; return (action, ["checkout", reference])
        case .switch: guard let branch = input.branch else { throw CoreError(code: .toolArgumentInvalid, message: "switch 需要 branch") }; return (action, ["switch", branch])
        case .commit: guard let message = input.message, !message.isEmpty else { throw CoreError(code: .toolArgumentInvalid, message: "commit 需要 message") }; return (action, ["commit", "-m", message])
        }
    }
    guard let legacy = input.arguments, let command = legacy.first, let action = GitAction(rawValue: command) else {
        throw CoreError(code: .toolArgumentInvalid, message: "git 需要受支持的 action")
    }
    // Compatibility is intentionally limited to read-only legacy invocations.
    guard [.status, .diff, .log, .show].contains(action), !legacy.dropFirst().contains(where: { $0 == "-C" || $0 == "--git-dir" || $0 == "--work-tree" }) else {
        throw CoreError(code: .toolArgumentInvalid, message: "git 仅支持结构化 action")
    }
    return (action, legacy)
}

public struct GitTool: ToolExecutor {
    private let workspace: WorkspaceRoot
    public init(workspace: WorkspaceRoot) { self.workspace = workspace }
    public let definition = ToolDefinition(
        id: ToolID("git"), description: "Run an allow-listed structured git action in the workspace.",
        inputSchema: ToolInputSchema(properties: [
            "action": ToolInputProperty(type: .string, description: "Git action", enumValues: GitAction.allCases.map(\.rawValue)),
            "arguments": ToolInputProperty(type: .array, description: "Legacy read-only git argv"),
            "cwd": ToolInputProperty(type: .string, description: "Workspace-relative working directory"),
            "paths": ToolInputProperty(type: .array, description: "Pathspecs for supported actions"),
            "reference": ToolInputProperty(type: .string, description: "Git revision"),
            "branch": ToolInputProperty(type: .string, description: "Branch name"),
            "message": ToolInputProperty(type: .string, description: "Commit message"),
            "limit": ToolInputProperty(type: .integer, description: "Log entry limit", minimum: 1, maximum: 100)
        ], required: []), capability: ToolCapability([.repositoryRead])
    )
    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: GitArguments = try decodeArguments(arguments)
        return try cwd(input.cwd, workspace: workspace, profile: profile).path
    }
    public func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        let input: GitArguments = try decodeArguments(arguments)
        let (action, _) = try gitCommand(input)
        var result: Set<ToolCapabilityKind> = [.status, .diff, .log, .show].contains(action) || action == .branch && input.branch == nil ? [.repositoryRead] : [.repositoryWrite]
        if action == .restore || action == .checkout || action == .switch { result.insert(.destructive) }
        return result
    }
    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: GitArguments = try decodeArguments(arguments)
        _ = try capabilities(for: arguments, profile: profile)
        let (_, command) = try gitCommand(input)
        let directory = try cwd(input.cwd, workspace: workspace, profile: profile)
        guard let gitExecutable = LingXiPlatform.process.resolveExecutable(named: "git", customSearchPaths: ["/Library/Developer/CommandLineTools/usr/bin", "/usr/bin", "/usr/local/bin"]) else {
            throw CoreError(code: .gitError, message: "未找到可执行的 git 命令")
        }
        let setup = try processSetup(executable: gitExecutable, arguments: command, workspace: workspace, cwd: directory, profile: profile)
        let result = try await runToolProcess(invocation: setup.0, cwd: directory, environment: setup.1, timeoutMilliseconds: 60_000, lifecycleTrace: ToolExecutionContext.lifecycleTrace)
        guard result.exitCode == 0 else { throw CoreError(code: .gitError, message: try json(result)) }
        return try json(result)
    }
}

public actor ToolProcessStore {
    private var processes: [String: ManagedToolProcess] = [:]

    public init() {}

    func start(id: String, invocation: ToolProcessInvocation, cwd: URL, environment: [String: String], lifecycleTrace: ToolLifecycleTrace? = nil) throws -> ProcessStatus {
        guard processes[id] == nil else { throw CoreError(code: .toolArgumentInvalid, message: "进程 ID 已存在: \(id)") }
        let process = ManagedToolProcess(invocation: invocation, cwd: cwd, environment: environment, lifecycleTrace: lifecycleTrace)
        try process.launch()
        processes[id] = process
        return process.snapshot(id: id, stdoutCursor: nil, stderrCursor: nil)
    }

    func poll(id: String, stdoutCursor: Int?, stderrCursor: Int?) throws -> ProcessStatus {
        guard let process = processes[id] else { throw CoreError(code: .processNotFound, message: "进程不存在: \(id)") }
        return process.snapshot(id: id, stdoutCursor: stdoutCursor, stderrCursor: stderrCursor)
    }

    func input(id: String, text: String, stdoutCursor: Int?, stderrCursor: Int?) throws -> ProcessStatus {
        guard let process = processes[id] else { throw CoreError(code: .processNotFound, message: "进程不存在: \(id)") }
        try process.write(text)
        return process.snapshot(id: id, stdoutCursor: stdoutCursor, stderrCursor: stderrCursor)
    }

    func stop(id: String, stdoutCursor: Int?, stderrCursor: Int?) throws -> ProcessStatus {
        guard let process = processes[id] else { throw CoreError(code: .processNotFound, message: "进程不存在: \(id)") }
        process.terminate()
        return process.snapshot(id: id, stdoutCursor: stdoutCursor, stderrCursor: stderrCursor)
    }

    func stopAll() async {
        for process in processes.values { process.terminate() }
        for process in processes.values { await process.waitForExit() }
        processes.removeAll()
    }
}

public struct ProcessTool: ToolExecutor {
    private let store: ToolProcessStore
    private let workspace: WorkspaceRoot
    public init(workspace: WorkspaceRoot, store: ToolProcessStore = ToolProcessStore()) {
        self.workspace = workspace
        self.store = store
    }
    public let definition = ToolDefinition(
        id: ToolID("process"), description: "Start, poll, provide input to, or stop a long-running process.",
        inputSchema: ToolInputSchema(properties: [
            "action": ToolInputProperty(type: .string, description: "start, poll, input, or stop", enumValues: ["start", "poll", "input", "stop", "status", "terminate"]),
            "executable": ToolInputProperty(type: .string, description: "Absolute executable path for start"),
            "arguments": ToolInputProperty(type: .array, description: "Executable argv for start"),
            "cwd": ToolInputProperty(type: .string, description: "Workspace-relative working directory"),
            "id": ToolInputProperty(type: .string, description: "Process ID"),
            "input": ToolInputProperty(type: .string, description: "UTF-8 stdin data"),
            "stdout_cursor": ToolInputProperty(type: .integer, description: "stdout cursor", minimum: 0),
            "stderr_cursor": ToolInputProperty(type: .integer, description: "stderr cursor", minimum: 0)
        ], required: ["action"]), capability: ToolCapability([.processExecute])
    )
    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: ProcessArguments = try decodeArguments(arguments)
        return try cwd(input.cwd, workspace: workspace, profile: profile).path
    }
    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: ProcessArguments = try decodeArguments(arguments)
        let id = input.id ?? UUID().uuidString
        let status: ProcessStatus
        switch input.action {
        case "start":
            guard let executable = input.executable else { throw CoreError(code: .toolArgumentInvalid, message: "start 需要 executable") }
            let directory = try cwd(input.cwd, workspace: workspace, profile: profile)
            let setup = try processSetup(executable: executable, arguments: input.arguments ?? [], workspace: workspace, cwd: directory, profile: profile)
            status = try await store.start(id: id, invocation: setup.0, cwd: directory, environment: setup.1, lifecycleTrace: ToolExecutionContext.lifecycleTrace)
        case "poll", "status": status = try await store.poll(id: id, stdoutCursor: input.stdoutCursor, stderrCursor: input.stderrCursor)
        case "input":
            guard let text = input.input else { throw CoreError(code: .toolArgumentInvalid, message: "input 需要 input") }
            status = try await store.input(id: id, text: text, stdoutCursor: input.stdoutCursor, stderrCursor: input.stderrCursor)
        case "stop", "terminate": status = try await store.stop(id: id, stdoutCursor: input.stdoutCursor, stderrCursor: input.stderrCursor)
        default: throw CoreError(code: .toolArgumentInvalid, message: "未知 process action: \(input.action)")
        }
        return try json(status)
    }
}

public struct RunBackgroundCommandTool: ToolExecutor {
    private let workspace: WorkspaceRoot
    private let manager: BackgroundCommandManager

    public init(workspace: WorkspaceRoot, manager: BackgroundCommandManager) {
        self.workspace = workspace
        self.manager = manager
    }

    public let definition = ToolDefinition(
        id: ToolID("run_background_command"),
        description: "Execute a non-conflicting shell command in the background, freeing the foreground to proceed. MANDATORY: `timeout_seconds` must be specified (e.g. 60-3600); commands without timeout will be strictly rejected. Note: After launching, do NOT poll repeatedly in the same turn; report task start to user immediately. The system proactively injects status updates when the task finishes.",
        inputSchema: ToolInputSchema(properties: [
            "command": ToolInputProperty(type: .string, description: "Shell command to run in the background"),
            "timeout_seconds": ToolInputProperty(type: .integer, description: "Mandatory timeout in seconds (1 to 7200). Commands without timeout are rejected.", minimum: 1, maximum: 7200),
            "cwd": ToolInputProperty(type: .string, description: "Workspace-relative working directory"),
            "description": ToolInputProperty(type: .string, description: "Brief description of the background command purpose"),
            "task_id": ToolInputProperty(type: .string, description: "Optional custom unique task identifier (e.g. 'build-target')")
        ], required: ["command", "timeout_seconds"]),
        capability: ToolCapability([.processExecute])
    )

    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: RunBackgroundCommandArguments = try decodeArguments(arguments)
        return try cwd(input.cwd, workspace: workspace, profile: profile).path
    }

    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: RunBackgroundCommandArguments = try decodeArguments(arguments)
        let directory = try cwd(input.cwd, workspace: workspace, profile: profile)
        let effectiveSessionID = ToolExecutionContext.sessionID ?? AgentExecutionContext.current?.sessionID
        let effectiveRunID = ToolExecutionContext.runID ?? AgentExecutionContext.current.map { RunID($0.runID.rawValue) }
        let snapshot = try await manager.spawn(
            command: input.command,
            timeoutSeconds: input.timeoutSeconds,
            cwd: directory,
            workspace: workspace,
            profile: profile,
            description: input.description,
            customID: input.taskId,
            lifecycleTrace: ToolExecutionContext.lifecycleTrace,
            sessionID: effectiveSessionID,
            runID: effectiveRunID
        )
        return try json(snapshot)
    }
}

public struct ManageBackgroundCommandTool: ToolExecutor {
    private let manager: BackgroundCommandManager

    public init(manager: BackgroundCommandManager) {
        self.manager = manager
    }

    public let definition = ToolDefinition(
        id: ToolID("manage_background_command"),
        description: "Manage, inspect, supply input to, or terminate running background commands. Use action='poll' to inspect output or exit status. If a task is still running, do NOT poll continuously in a busy loop; yield turn and inform the user.",
        inputSchema: ToolInputSchema(properties: [
            "action": ToolInputProperty(type: .string, description: "poll, input, terminate, or list", enumValues: ["poll", "input", "terminate", "list"]),
            "task_id": ToolInputProperty(type: .string, description: "Task ID (required for poll, input, terminate)"),
            "stdout_cursor": ToolInputProperty(type: .integer, description: "Cursor for incremental stdout reading", minimum: 0),
            "stderr_cursor": ToolInputProperty(type: .integer, description: "Cursor for incremental stderr reading", minimum: 0),
            "input_text": ToolInputProperty(type: .string, description: "UTF-8 text to send to stdin for action='input'")
        ], required: ["action"]),
        capability: ToolCapability([.processExecute])
    )

    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: ManageBackgroundCommandArguments = try decodeArguments(arguments)
        return input.taskId ?? "all"
    }

    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: ManageBackgroundCommandArguments = try decodeArguments(arguments)
        switch input.action {
        case "poll", "status":
            guard let id = input.taskId else {
                throw CoreError(code: .toolArgumentInvalid, message: "manage_background_command action='\(input.action)' 需要 task_id")
            }
            let snapshot = try await manager.poll(id: id, stdoutCursor: input.stdoutCursor, stderrCursor: input.stderrCursor)
            return try json(snapshot)
        case "input":
            guard let id = input.taskId else {
                throw CoreError(code: .toolArgumentInvalid, message: "manage_background_command action='input' 需要 task_id")
            }
            guard let text = input.inputText else {
                throw CoreError(code: .toolArgumentInvalid, message: "manage_background_command action='input' 需要 input_text")
            }
            let snapshot = try await manager.input(id: id, text: text, stdoutCursor: input.stdoutCursor, stderrCursor: input.stderrCursor)
            return try json(snapshot)
        case "terminate", "stop", "kill":
            guard let id = input.taskId else {
                throw CoreError(code: .toolArgumentInvalid, message: "manage_background_command action='terminate' 需要 task_id")
            }
            let snapshot = try await manager.terminate(id: id, stdoutCursor: input.stdoutCursor, stderrCursor: input.stderrCursor)
            return try json(snapshot)
        case "list":
            let list = await manager.list()
            return try json(list)
        default:
            throw CoreError(code: .toolArgumentInvalid, message: "未知的 manage_background_command action: \(input.action)")
        }
    }
}


public struct QuestionTool: ToolExecutor {
    private let questions: QuestionRuntime?

    public init(questions: QuestionRuntime? = nil) {
        self.questions = questions
    }
    public let definition = ToolDefinition(
        id: ToolID("question"), description: "Ask the user to choose from provided options.",
        inputSchema: ToolInputSchema(properties: [
            "question": ToolInputProperty(type: .string, description: "Question for the user"),
            "options": ToolInputProperty(type: .array, description: "Optional choices"),
            "multiple": ToolInputProperty(type: .boolean, description: "Whether multiple choices are allowed")
        ], required: ["question"]), capability: ToolCapability([.userInteraction])
    )
    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: QuestionArguments = try decodeArguments(arguments)
        return input.question
    }
    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        guard let questions else {
            throw CoreError(code: .questionUnavailable, message: "当前 transport 不支持交互式问题")
        }
        let input: QuestionArguments = try decodeArguments(arguments)
        let request = QuestionRequest(
            questionID: QuestionID(UUID().uuidString),
            question: input.question,
            options: input.options ?? [],
            allowsMultiple: input.multiple ?? false
        )
        let reply = try await questions.ask(request)
        let selectedOptions = reply.selectedOptionIndices.map { request.options[$0] }
        return try json(QuestionToolResult(
            questionID: request.questionID.rawValue,
            cancelled: reply.cancelled,
            selectedOptions: selectedOptions,
            text: reply.text
        ))
    }
}

private struct QuestionToolResult: Codable {
    let questionID: String
    let cancelled: Bool
    let selectedOptions: [String]
    let text: String?
}

private struct SkillTool: ToolExecutor {
    let workspace: WorkspaceRoot

    var definition: ToolDefinition {
        let names = Self.names(in: workspace)
        return ToolDefinition(
            id: ToolID("skill"),
            description: names.isEmpty ? "Load a workspace skill by name. No skills are currently available." : "Load a workspace skill by name. Available: \(names.joined(separator: ", ")).",
            inputSchema: ToolInputSchema(properties: ["name": ToolInputProperty(type: .string, description: "Available skill name", enumValues: names)], required: ["name"]),
            capability: ToolCapability(readOnly: true)
        )
    }

    init(workspace: WorkspaceRoot) {
        self.workspace = workspace
    }

    func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: SkillArguments = try decodeArguments(arguments)
        return try skillFile(input.name, profile: profile).path
    }

    func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: SkillArguments = try decodeArguments(arguments)
        return try readText(skillFile(input.name, profile: profile), operation: "skill")
    }

    private func skillFile(_ name: String, profile: ExecutionProfile) throws -> URL {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) }) else {
            throw CoreError(code: .toolArgumentInvalid, message: "Skill 名称无效")
        }
        let file = try workspace.resolve(".lingxi/skills/\(name)/SKILL.md", profile: profile)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CoreError(code: .resourceNotFound, message: "Skill 不存在: \(name)")
        }
        return file
    }

    private static func names(in workspace: WorkspaceRoot) -> [String] {
        let root = workspace.url.appendingPathComponent(".lingxi/skills", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }
            .map(\.lastPathComponent)
            .sorted()
    }
}

private struct IndexResult: Codable {
    let id: String
    let path: String
    let name: String
    let kind: String
    let line: Int
}

private struct ProjectIndexTool: ToolExecutor {
    enum Kind { case symbols, references, dependencies }

    let definition: ToolDefinition
    let kind: Kind
    let pager: ContextPager
    let scanner: ProjectScanner

    func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: SymbolArguments = try decodeArguments(arguments)
        return input.symbol
    }

    func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: SymbolArguments = try decodeArguments(arguments)
        _ = try await pager.rebuildStaleFiles(using: scanner)
        switch kind {
        case .symbols:
            let symbols = await pager.symbolLookup(projectRoot: scanner.root, query: input.symbol, mode: input.mode ?? "prefix")
            return try json(symbols.map { IndexResult(id: $0.id.rawValue, path: $0.path, name: $0.qualifiedName, kind: $0.kind.rawValue, line: $0.line) })
        case .references:
            let symbols = await pager.symbolLookup(projectRoot: scanner.root, query: input.symbol, mode: input.mode ?? "qualified")
            guard symbols.count == 1 else {
                throw CoreError(code: .resourceNotFound, message: symbols.isEmpty ? "未找到 Symbol: \(input.symbol)" : "Symbol 不唯一: \(input.symbol)")
            }
            let references = await pager.references(projectRoot: scanner.root, symbolID: symbols[0].id)
            return try json(references.map { IndexResult(id: $0.id.rawValue, path: $0.sourcePath, name: $0.targetName, kind: $0.resolutionQuality.rawValue, line: $0.sourceLine) })
        case .dependencies:
            let edges = await pager.dependencies(projectRoot: scanner.root, path: input.symbol, incoming: input.direction == "incoming")
            return try json(edges.map { IndexResult(id: $0.evidence.rawValue, path: $0.sourcePath, name: $0.targetPath ?? $0.targetModule ?? "", kind: $0.kind.rawValue, line: 0) })
        }
    }
}

private struct CodeIntelligenceTool: ToolExecutor {
    let definition: ToolDefinition
    let intelligence: CodeIntelligence
    let workspace: WorkspaceRoot

    func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: CodeIntelligenceArguments = try decodeArguments(arguments)
        return input.path ?? input.query ?? workspace.url.path
    }

    func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: CodeIntelligenceArguments = try decodeArguments(arguments)
        switch input.action {
        case "symbols": return try json(await intelligence.symbols(input.query ?? ""))
        case "definition": return try json(await intelligence.definition(path: try required(input.path, "path"), line: try required(input.line, "line"), character: input.character ?? 0))
        case "references": return try json(await intelligence.references(path: try required(input.path, "path"), line: try required(input.line, "line"), character: input.character ?? 0))
        case "document_symbols": return try json(await intelligence.documentSymbols(path: try required(input.path, "path")))
        case "diagnostics": return try json(await intelligence.diagnostics(path: try required(input.path, "path")))
        case "hover": return try json(await intelligence.hover(path: try required(input.path, "path"), line: try required(input.line, "line"), character: input.character ?? 0))
        case "completion": return try json(await intelligence.completion(path: try required(input.path, "path"), line: try required(input.line, "line"), character: input.character ?? 0))
        case "repo_map": return await intelligence.repoMap()
        case "context": return try json(await intelligence.context(input.query ?? "", maximumCharacters: min(max(0, input.maximumCharacters ?? 16_000), 32_768)))
        default: throw CoreError(code: .toolArgumentInvalid, message: "未知 code_intelligence action")
        }
    }

    private func required<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw CoreError(code: .toolArgumentInvalid, message: "code_intelligence 缺少 \(name)") }
        return value
    }
}

private struct ContextRetrieveArguments: Codable {
    let query: String
    let limit: Int?
}

package struct ContextRetrieveTool: ToolExecutor {
    package let definition: ToolDefinition
    let cacheController: ContextCacheController

    package init(id: String = "context_search", cacheController: ContextCacheController) {
        self.cacheController = cacheController
        self.definition = ToolDefinition(
            id: ToolID(id),
            description: "Search and retrieve relevant context from the project codebase index or compacted session history. The runtime cache controller evaluates weighted priority and pages the highest relevance entries into the L1 working set.",
            inputSchema: ToolInputSchema(
                properties: [
                    "query": ToolInputProperty(type: .string, description: "Search query describing what context to retrieve"),
                    "limit": ToolInputProperty(type: .integer, description: "Maximum items to retrieve (default: 5)", minimum: 1, maximum: 20)
                ],
                required: ["query"]
            ),
            capability: ToolCapability(readOnly: true)
        )
    }

    package func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: ContextRetrieveArguments = try decodeArguments(arguments)
        return input.query
    }

    package func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: ContextRetrieveArguments = try decodeArguments(arguments)
        let limit = min(max(1, input.limit ?? 5), 20)
        let sessionID = ToolExecutionContext.sessionID ?? SessionID("default")
        return try await cacheController.handleSearch(
            sessionID: sessionID,
            query: input.query,
            activeTask: "",
            activeFiles: [],
            limit: limit
        )
    }
}

private struct TodoArguments: Codable {
    let action: String
    let id: String?
    let title: String?
    let status: String?
}

private struct TodoMutationResponse: Codable {
    let status: String
    let task: TodoItemData?
    let id: String?
    let newStatus: String?
    let message: String?
    init(status: String, task: TodoItemData? = nil, id: String? = nil, newStatus: String? = nil, message: String? = nil) {
        self.status = status
        self.task = task
        self.id = id
        self.newStatus = newStatus
        self.message = message
    }
}

private struct TodoListResponse: Codable {
    let status: String
    let tasks: [TodoItemData]
}

public struct TodoTool: ToolExecutor {
    public let definition = ToolDefinition(
        id: ToolID("todo"),
        description: "Manage task and to-do items for the current session. For multi-step tasks, comprehensive health checks, environment diagnostics, or refactoring, ALWAYS use this tool first (action: 'add') to establish a checklist, then update status ('in_progress', 'completed', 'failed') as you proceed to maintain real-time visibility on the sidebar.",
        inputSchema: ToolInputSchema(
            properties: [
                "action": ToolInputProperty(type: .string, description: "Action to perform: add, update, list, clear", enumValues: ["add", "update", "list", "clear"]),
                "id": ToolInputProperty(type: .string, description: "Unique task ID, e.g. task-1"),
                "title": ToolInputProperty(type: .string, description: "Task title or description"),
                "status": ToolInputProperty(type: .string, description: "Task status", enumValues: ["pending", "in_progress", "completed", "failed"])
            ],
            required: ["action"]
        ),
        capability: ToolCapability(readOnly: false)
    )

    private let todoStore: TodoStore

    public init(todoStore: TodoStore? = nil) {
        self.todoStore = todoStore ?? TodoStore.shared
    }

    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: TodoArguments = try decodeArguments(arguments)
        return "\(input.action): \(input.title ?? input.id ?? "")"
    }

    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: TodoArguments = try decodeArguments(arguments)
        let sessionKey = ToolExecutionContext.sessionID?.rawValue ?? "default"
        switch input.action {
        case "add":
            guard let title = input.title, !title.isEmpty else {
                throw CoreError(code: .toolArgumentInvalid, message: "add 需要 title")
            }
            let taskID = input.id ?? UUID().uuidString.prefix(6).lowercased()
            let status = input.status ?? "pending"
            let item = TodoItemData(id: String(taskID), title: title, status: status)
            todoStore.addTodo(item, for: sessionKey)
            return try json(TodoMutationResponse(status: "ok", task: item))
        case "update":
            guard let id = input.id, !id.isEmpty else {
                throw CoreError(code: .toolArgumentInvalid, message: "update 需要 id")
            }
            let status = input.status ?? "in_progress"
            let ok = todoStore.updateTodo(id: id, status: status, title: input.title, for: sessionKey)
            return try json(TodoMutationResponse(status: ok ? "ok" : "not_found", id: id, newStatus: status))
        case "list":
            let items = todoStore.getTodos(for: sessionKey)
            return try json(TodoListResponse(status: "ok", tasks: items))
        case "clear":
            todoStore.clear(for: sessionKey)
            return try json(TodoMutationResponse(status: "ok", message: "Todos cleared"))
        default:
            throw CoreError(code: .toolArgumentInvalid, message: "不支持的 action: \(input.action)")
        }
    }
}

private struct FormatFileArguments: Decodable {
    let path: String?
    let paths: [String]?
}

public struct FormatFileTool: ToolExecutor {
    private let workspace: WorkspaceRoot
    public init(workspace: WorkspaceRoot) { self.workspace = workspace }
    public let definition = ToolDefinition(
        id: ToolID("format_file"),
        description: "Format source code files using project or system formatters (swift-format, ruff/black, prettier/biome, rustfmt, gofmt, clang-format). Automatically detects project-local configs.",
        inputSchema: ToolInputSchema(properties: [
            "path": ToolInputProperty(type: .string, description: "Workspace-relative or absolute file path to format"),
            "paths": ToolInputProperty(type: .array, description: "Optional list of file paths to format in batch")
        ], required: []),
        capability: ToolCapability(readOnly: false)
    )
    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input: FormatFileArguments = try decodeArguments(arguments)
        if let p = input.path {
            return try workspace.resolve(p, profile: profile).path
        }
        return workspace.url.path
    }
    public func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        [.projectWrite]
    }
    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: FormatFileArguments = try decodeArguments(arguments)
        if let paths = input.paths, !paths.isEmpty {
            var urls: [URL] = []
            for p in paths {
                if let url = try? workspace.resolve(p, profile: profile) {
                    urls.append(url)
                }
            }
            let results = await FormatCoordinator.shared.format(files: urls, workspaceRoot: workspace.url)
            return try json(results)
        } else if let p = input.path {
            let url = try workspace.resolve(p, profile: profile)
            let result = await FormatCoordinator.shared.format(fileURL: url, workspaceRoot: workspace.url)
            return try json(result)
        } else {
            throw CoreError(code: .toolArgumentInvalid, message: "Must provide either 'path' or 'paths'")
        }
    }
}

private struct CodebaseGraphArguments: Decodable {
    let action: String
    let target: String?
    let direction: String?
    let depth: Int?
    let kind: String?
    let reindex: Bool?
}

public struct CodebaseGraphTool: ToolExecutor {
    private let workspace: WorkspaceRoot
    private let graphEngine: CodebaseGraphEngine

    public init(workspace: WorkspaceRoot, graphEngine: CodebaseGraphEngine? = nil) {
        self.workspace = workspace
        self.graphEngine = graphEngine ?? CodebaseGraphEngine(cachePolicy: .disabled)
    }

    public let definition = ToolDefinition(
        id: ToolID("codebase_graph"),
        description: "Explore the codebase knowledge graph: architecture layers, hotspots, call hierarchy trace (inbound/outbound), and symbol topological search.",
        inputSchema: ToolInputSchema(properties: [
            "action": ToolInputProperty(type: .string, description: "Action to perform: architecture, overview, trace, search, or refresh", enumValues: ["architecture", "overview", "trace", "search", "refresh"]),
            "target": ToolInputProperty(type: .string, description: "Symbol name or query for trace/search"),
            "direction": ToolInputProperty(type: .string, description: "Call trace direction: inbound (who calls target) or outbound (what target calls)", enumValues: ["inbound", "outbound"]),
            "depth": ToolInputProperty(type: .integer, description: "Maximum trace depth (1-5, default 3)", minimum: 1, maximum: 5),
            "kind": ToolInputProperty(type: .string, description: "Filter symbol kind for search (e.g. class, function, struct, interface)"),
            "reindex": ToolInputProperty(type: .boolean, description: "Whether to force re-indexing rather than using in-memory cached graph")
        ], required: ["action"]),
        capability: ToolCapability(readOnly: true)
    )
    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        workspace.url.path
    }
    public func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        [.projectRead]
    }
    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: CodebaseGraphArguments = try decodeArguments(arguments)
        let shouldReindex = input.reindex == true || input.action == "refresh"
        let isIndexed = await graphEngine.isIndexed
        if shouldReindex || !isIndexed {
            _ = await graphEngine.indexWorkspace(workspaceURL: workspace.url, forceReindex: shouldReindex)
        }

        switch input.action {
        case "architecture", "overview", "refresh":
            let overview = await graphEngine.getArchitecture()
            return try json(overview)
        case "trace":
            guard let target = input.target, !target.isEmpty else {
                throw CoreError(code: .toolArgumentInvalid, message: "Action 'trace' requires 'target' parameter")
            }
            let dir: TraceDirection = (input.direction == "inbound") ? .inbound : .outbound
            let depth = min(max(1, input.depth ?? 3), 5)
            if let report = await graphEngine.traceCallPath(symbolNameOrId: target, direction: dir, maxDepth: depth) {
                return try json(report)
            } else {
                return try json(["status": "not_found", "message": "Symbol '\(target)' not found in codebase graph"])
            }
        case "search":
            guard let query = input.target, !query.isEmpty else {
                throw CoreError(code: .toolArgumentInvalid, message: "Action 'search' requires 'target' parameter")
            }
            let filterKind = input.kind.flatMap { GraphNodeKind(rawValue: $0.lowercased()) }
            let results = await graphEngine.search(query: query, kind: filterKind)
            return try json(results)
        default:
            throw CoreError(code: .toolArgumentInvalid, message: "Unsupported action '\(input.action)'")
        }
    }
}

public extension BuiltInToolProvider {
    init(workspace: WorkspaceRoot, contextPager: ContextPager? = nil, scanner: ProjectScanner? = nil, questions: QuestionRuntime? = nil, processes: ToolProcessStore? = nil, backgroundManager: BackgroundCommandManager? = nil, codeIntelligence: CodeIntelligence? = nil, cacheController: ContextCacheController? = nil, webSearchEndpoint: URL? = nil, tavilyAPIKey: String? = nil, graphEngine: CodebaseGraphEngine? = nil, todoStore: TodoStore? = nil, browserManager: BrowserSessionManager? = nil) {
        let indexTools: [any ToolExecutor]
        if let contextPager, let scanner {
            indexTools = [
                ProjectIndexTool(definition: ToolDefinition(id: ToolID("symbol_lookup"), description: "Look up a symbol in the configured code index.", inputSchema: ToolInputSchema(properties: ["symbol": ToolInputProperty(type: .string, description: "Symbol name"), "mode": ToolInputProperty(type: .string, description: "exact, qualified, or prefix", enumValues: ["exact", "qualified", "prefix"])], required: ["symbol"]), capability: ToolCapability(readOnly: true)), kind: .symbols, pager: contextPager, scanner: scanner),
                ProjectIndexTool(definition: ToolDefinition(id: ToolID("find_references"), description: "Find incoming references for a unique indexed symbol.", inputSchema: ToolInputSchema(properties: ["symbol": ToolInputProperty(type: .string, description: "Symbol query"), "mode": ToolInputProperty(type: .string, description: "exact or qualified", enumValues: ["exact", "qualified"])], required: ["symbol"]), capability: ToolCapability(readOnly: true)), kind: .references, pager: contextPager, scanner: scanner),
                ProjectIndexTool(definition: ToolDefinition(id: ToolID("dependency_query"), description: "Query incoming or outgoing indexed file dependencies.", inputSchema: ToolInputSchema(properties: ["symbol": ToolInputProperty(type: .string, description: "Project-relative file path"), "direction": ToolInputProperty(type: .string, description: "incoming or outgoing", enumValues: ["incoming", "outgoing"])], required: ["symbol"]), capability: ToolCapability(readOnly: true)), kind: .dependencies, pager: contextPager, scanner: scanner),
            ]
        } else {
            indexTools = []
        }
        let intelligenceTools: [any ToolExecutor] = codeIntelligence.map { intelligence in
            [CodeIntelligenceTool(definition: ToolDefinition(id: ToolID("code_intelligence"), description: "Structured code intelligence powered by Language Server Protocol (LSP). Supports symbols, definitions, references, document_symbols, diagnostics, hover, completion, repository map, and bounded context; falls back safely when LSP is unavailable.", inputSchema: ToolInputSchema(properties: ["action": ToolInputProperty(type: .string, description: "symbols, definition, references, document_symbols, diagnostics, hover, completion, repo_map, or context", enumValues: ["symbols", "definition", "references", "document_symbols", "diagnostics", "hover", "completion", "repo_map", "context"]), "query": ToolInputProperty(type: .string, description: "Symbol or task query"), "path": ToolInputProperty(type: .string, description: "Workspace-relative source path"), "line": ToolInputProperty(type: .integer, description: "One-based line", minimum: 1), "character": ToolInputProperty(type: .integer, description: "Zero-based character", minimum: 0), "maximum_characters": ToolInputProperty(type: .integer, description: "Bounded context character limit", minimum: 0, maximum: 32_768)], required: ["action"]), capability: ToolCapability(readOnly: true)), intelligence: intelligence, workspace: workspace)]
        } ?? []
        let effectiveBgManager = backgroundManager ?? BackgroundCommandManager()
        self.init(tools: [
            ReadFileTool(workspace: workspace),
            ContextRecallTool(ecoreStore: cacheController?.ecoreStore),
            RetrievalSearchTool(projectRoot: workspace.url, ecoreStore: cacheController?.ecoreStore, graphEngine: graphEngine),
            ListDirectoryTool(workspace: workspace),
            GlobTool(workspace: workspace),
            GrepTool(workspace: workspace),
            WriteFileTool(workspace: workspace),
            EditFileTool(workspace: workspace),
            ApplyPatchTool(workspace: workspace),
            FormatFileTool(workspace: workspace),
            CodebaseGraphTool(workspace: workspace, graphEngine: graphEngine),
            ShellTool(workspace: workspace),
            RunBackgroundCommandTool(workspace: workspace, manager: effectiveBgManager),
            ManageBackgroundCommandTool(manager: effectiveBgManager),
            WebSearchTool(endpoint: webSearchEndpoint, tavilyAPIKey: tavilyAPIKey),
            WebFetchTool(),
            ProcessTool(workspace: workspace, store: processes ?? ToolProcessStore()),
            GitTool(workspace: workspace),
            SkillTool(workspace: workspace),
            QuestionTool(questions: questions),
            TodoTool(todoStore: todoStore)
            // NOTE: Computer Use and Browser Use implementations are frozen and disabled from the default toolcall list per owner directive.
            // Underlying implementation code (BrowserNavigateTool, BrowserActTool, ComputerBatchTool) is fully preserved.
            // BrowserNavigateTool(browserManager: browserManager),
            // BrowserActTool(browserManager: browserManager),
            // ComputerBatchTool()
        ] + indexTools + intelligenceTools)
    }
}

public extension ToolRegistry {
    static func builtin(workspace: WorkspaceRoot, contextPager: ContextPager? = nil, scanner: ProjectScanner? = nil, questions: QuestionRuntime? = nil, processes: ToolProcessStore? = nil, backgroundManager: BackgroundCommandManager? = nil, codeIntelligence: CodeIntelligence? = nil, cacheController: ContextCacheController? = nil, webSearchEndpoint: URL? = nil, tavilyAPIKey: String? = nil, graphEngine: CodebaseGraphEngine? = nil, todoStore: TodoStore? = nil, browserManager: BrowserSessionManager? = nil) -> ToolRegistry {
        ToolRegistry(BuiltInToolProvider(workspace: workspace, contextPager: contextPager, scanner: scanner, questions: questions, processes: processes, backgroundManager: backgroundManager, codeIntelligence: codeIntelligence, cacheController: cacheController, webSearchEndpoint: webSearchEndpoint, tavilyAPIKey: tavilyAPIKey, graphEngine: graphEngine, todoStore: todoStore, browserManager: browserManager).tools)
    }
}
