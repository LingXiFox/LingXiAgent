import CryptoKit
import Foundation
import LingXiProtocol

public struct WorkspaceRoot: Sendable {
    public let url: URL
    public let sensitivePathPolicy: SensitivePathPolicy

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
        let input = URL(fileURLWithPath: path, relativeTo: path.hasPrefix("/") ? nil : url)
        let candidate = input.standardizedFileURL.resolvingSymlinksInPath()
        let root = url.path.hasSuffix("/") ? url.path : url.path + "/"
        guard profile == .fullAccess || candidate.path == url.path || candidate.path.hasPrefix(root) else {
            throw CoreError(code: .workspaceViolation, message: "路径超出 Workspace Root")
        }
        guard !sensitivePathPolicy.isSensitive(candidate) else {
            throw CoreError(code: .workspaceViolation, message: "不允许访问敏感路径")
        }
        return candidate
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
    encoder.outputFormatting = [.sortedKeys]
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
    try Data(content.utf8).write(to: file, options: .atomic)
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
}
private struct WriteArguments: Decodable {
    let path: String
    let content: String
    let expectedHash: String?
    let expectedVersion: String?
    let overwrite: Bool?
}
private struct EditArguments: Decodable {
    let path: String
    let oldString: String
    let newString: String
    let replaceAll: Bool?
    let expectedHash: String?
    let expectedVersion: String?
    let overwrite: Bool?
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
private struct QuestionArguments: Decodable { let question: String; let options: [String]?; let multiple: Bool? }
private struct SymbolArguments: Decodable { let symbol: String; let mode: String?; let direction: String? }
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
    let start = max(1, input.startLine ?? 1)
    let end = input.endLine
    if let end, end < start { throw CoreError(code: .toolArgumentInvalid, message: "end_line 必须不小于 start_line") }
    let count = min(max(1, input.maxLines ?? end.map { $0 - start + 1 } ?? 200), 2_000)
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
            properties: ["path": ToolInputProperty(type: .string, description: "Workspace-relative file path")],
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
            let kind = values.isDirectory == true ? "directory" : "file"
            let size = values.fileSize.map(String.init) ?? "-"
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
    let candidates = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"]
    guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
        throw CoreError(code: .toolExecutionFailed, message: "未找到受支持的 ripgrep (rg) 可执行文件")
    }
    return executable
}

private func generatedExcludes(_ includeGenerated: Bool?) -> [String] {
    guard includeGenerated != true else { return [] }
    return ["!**/.build/**", "!**/build/**", "!**/dist/**", "!**/node_modules/**", "!**/vendor/**", "!**/coverage/**"]
}

private let sensitiveSearchExcludes = [
    "!**/.ssh/**", "!**/.aws/**", "!**/.gnupg/**", "!**/.env", "!**/.env.*", "!**/*.pem", "!**/*.key",
    "!**/*credential*", "!**/*secret*", "!**/*token*"
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
        let path = original.hasPrefix("./") ? String(original.dropFirst(2)) : original
        var ignored = false
        for raw in patterns {
            let negated = raw.hasPrefix("!")
            let pattern = negated ? String(raw.dropFirst()) : raw
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

private func ripgrepArguments(_ input: GrepArguments, root: URL) -> [String] {
    var arguments = ["--json", "--no-require-git", "--line-number", "--color", "never", "--regexp", input.pattern]
    if let glob = input.glob { arguments += ["--glob", glob] }
    if input.includeHidden == true { arguments.append("--hidden") }
    if input.includeIgnored == true { arguments.append("--no-ignore") }
    arguments += workspaceIgnoreArguments(root: root, includeIgnored: input.includeIgnored)
    for exclude in generatedExcludes(input.includeGenerated) + sensitiveSearchExcludes { arguments += ["--glob", exclude] }
    arguments.append(".")
    return arguments
}

private func runRipgrep(arguments: [String], root: URL, workspace: WorkspaceRoot, profile: ExecutionProfile) async throws -> CommandResult {
    let executable = try ripgrepExecutable()
    let setup = try processSetup(executable: executable, arguments: arguments, workspace: workspace, cwd: root, profile: profile)
    let result = try await runToolProcess(invocation: setup.0, cwd: root, environment: setup.1, timeoutMilliseconds: 30_000)
    guard result.exitCode == 0 || result.exitCode == 1 else {
        throw CoreError(code: .commandFailed, message: try json(result))
    }
    return result
}

private func workspaceRelativeSearchPath(_ path: String, root: URL, workspace: WorkspaceRoot) -> String {
    let local = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    if root.path == workspace.url.path { return local }
    let prefix = relativePath(root, workspace: workspace)
    return prefix == "." || prefix.isEmpty ? local : prefix + "/" + local
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
        let root = try workspace.resolve(input.path ?? ".", profile: profile)
        let limit = min(max(1, input.maxResults ?? 1_000), 10_000)
        let result = try await runRipgrep(arguments: ripgrepArguments(input, root: root), root: root, workspace: workspace, profile: profile)
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
            matches.append(GrepMatch(path: workspaceRelativeSearchPath(path, root: root, workspace: workspace), line: line, content: text.hasSuffix("\n") ? String(text.dropLast()) : text))
        }
        let ordered = matches.filter { !ignoredByWorkspaceGitignore([$0.path], root: root, includeIgnored: input.includeIgnored).isEmpty }.sorted { $0.path == $1.path ? $0.line < $1.line : $0.path < $1.path }
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
        id: ToolID("write_file"), description: "Write UTF-8 text to a workspace file.",
        inputSchema: ToolInputSchema(properties: [
            "path": ToolInputProperty(type: .string, description: "Workspace-relative file path"),
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
        return try json(fileWriteResult(for: file, workspace: workspace, content: input.content))
    }
}

public struct EditFileTool: ToolExecutor {
    private let workspace: WorkspaceRoot
    public init(workspace: WorkspaceRoot) { self.workspace = workspace }
    public let definition = ToolDefinition(
        id: ToolID("edit_file"), description: "Replace exact text in a UTF-8 workspace file.",
        inputSchema: ToolInputSchema(properties: [
            "path": ToolInputProperty(type: .string, description: "Workspace-relative file path"),
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
    try workspace.resolve(value ?? ".", profile: profile)
}

private func processSetup(executable: String, arguments: [String], workspace: WorkspaceRoot, cwd: URL, profile: ExecutionProfile) throws -> (ToolProcessInvocation, [String: String]) {
    guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
        throw CoreError(code: .toolArgumentInvalid, message: "executable 必须是可执行的绝对路径")
    }
    var environment = EnvironmentSanitizer.sanitized()
    let home = workspace.url.appendingPathComponent(".lingxi-home", isDirectory: true)
    let temporary = workspace.url.appendingPathComponent(".lingxi-tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    environment["HOME"] = home.path
    environment["TMPDIR"] = temporary.path
    // /usr/bin/git is a system tool; inherited Xcode selection can force xcrun to write host-global caches outside policy.
    if executable.hasSuffix("/git") {
        environment.removeValue(forKey: "DEVELOPER_DIR")
        environment.removeValue(forKey: "SDKROOT")
        environment.removeValue(forKey: "TOOLCHAINS")
    }
    if profile == .workspace {
        let developerDirectory = environment["DEVELOPER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let policy = SandboxPolicy(workspace: workspace.url, readOnlyPaths: developerDirectory.map { [$0] } ?? [])
        return (try ShellSandboxBackend.workspace().invocation(executable: executable, arguments: arguments, policy: policy), environment)
    }
    return (ToolProcessInvocation(executable: executable, arguments: arguments), environment)
}

public struct ShellTool: ToolExecutor {
    private let workspace: WorkspaceRoot
    public init(workspace: WorkspaceRoot) { self.workspace = workspace }
    public let definition = ToolDefinition(
        id: ToolID("shell"), description: "Run a shell command or absolute executable argv.",
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
        return Set([.processExecute]).union(filesystemCapabilities(try cwd(input.cwd, workspace: workspace, profile: profile), workspace: workspace, write: true))
    }
    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input: ShellArguments = try decodeArguments(arguments)
        let command: (String, [String])
        if let shell = input.command {
            command = ("/bin/sh", ["-c", shell])
        } else if let executable = input.executable {
            command = (executable, input.arguments ?? [])
        } else {
            throw CoreError(code: .toolArgumentInvalid, message: "shell 需要 command 或 executable")
        }
        let directory = try cwd(input.cwd, workspace: workspace, profile: profile)
        let setup = try processSetup(executable: command.0, arguments: command.1, workspace: workspace, cwd: directory, profile: profile)
        let result = try await runToolProcess(invocation: setup.0, cwd: directory, environment: setup.1, timeoutMilliseconds: input.timeoutMs ?? 60_000)
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
        let gitExecutable = ["/Library/Developer/CommandLineTools/usr/bin/git", "/usr/bin/git"].first(where: FileManager.default.isExecutableFile(atPath:))!
        let setup = try processSetup(executable: gitExecutable, arguments: command, workspace: workspace, cwd: directory, profile: profile)
        let result = try await runToolProcess(invocation: setup.0, cwd: directory, environment: setup.1, timeoutMilliseconds: 60_000)
        guard result.exitCode == 0 else { throw CoreError(code: .gitError, message: try json(result)) }
        return try json(result)
    }
}

public actor ToolProcessStore {
    private var processes: [String: ManagedToolProcess] = [:]

    public init() {}

    func start(id: String, invocation: ToolProcessInvocation, cwd: URL, environment: [String: String]) throws -> ProcessStatus {
        guard processes[id] == nil else { throw CoreError(code: .toolArgumentInvalid, message: "进程 ID 已存在: \(id)") }
        let process = ManagedToolProcess(invocation: invocation, cwd: cwd, environment: environment)
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

    func stopAll() {
        for process in processes.values { process.terminate() }
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
            status = try await store.start(id: id, invocation: setup.0, cwd: directory, environment: setup.1)
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

public extension BuiltInToolProvider {
    init(workspace: WorkspaceRoot, contextPager: ContextPager? = nil, scanner: ProjectScanner? = nil, questions: QuestionRuntime? = nil, processes: ToolProcessStore? = nil) {
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
        self.init(tools: [
            ReadFileTool(workspace: workspace),
            ListDirectoryTool(workspace: workspace),
            GlobTool(workspace: workspace),
            GrepTool(workspace: workspace),
            WriteFileTool(workspace: workspace),
            EditFileTool(workspace: workspace),
            ApplyPatchTool(workspace: workspace),
            ShellTool(workspace: workspace),
            ProcessTool(workspace: workspace, store: processes ?? ToolProcessStore()),
            GitTool(workspace: workspace),
            SkillTool(workspace: workspace),
            QuestionTool(questions: questions)
        ] + indexTools)
    }
}

public extension ToolRegistry {
    static func builtin(workspace: WorkspaceRoot, contextPager: ContextPager? = nil, scanner: ProjectScanner? = nil, questions: QuestionRuntime? = nil, processes: ToolProcessStore? = nil) -> ToolRegistry {
        ToolRegistry(BuiltInToolProvider(workspace: workspace, contextPager: contextPager, scanner: scanner, questions: questions, processes: processes).tools)
    }
}
