import Foundation
import LingXiProtocol

public struct WorkspaceRoot: Sendable {
    public let url: URL

    public init(path: String) throws {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CoreError(code: .workspaceViolation, message: "Workspace Root 不存在或不是目录: \(candidate.path)")
        }
        url = candidate
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> WorkspaceRoot {
        try WorkspaceRoot(path: environment["LINGXI_WORKSPACE_ROOT"] ?? FileManager.default.currentDirectoryPath)
    }

    public func resolve(_ path: String, profile: ExecutionProfile = .workspace) throws -> URL {
        let input = URL(fileURLWithPath: path, relativeTo: path.hasPrefix("/") ? nil : url)
        let candidate = input.standardizedFileURL.resolvingSymlinksInPath()
        let root = url.path.hasSuffix("/") ? url.path : url.path + "/"
        guard profile == .fullAccess || candidate.path == url.path || candidate.path.hasPrefix(root) else {
            throw CoreError(code: .workspaceViolation, message: "路径超出 Workspace Root: \(candidate.path)")
        }
        let name = candidate.lastPathComponent.lowercased()
        guard !(name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".pem") || name.hasSuffix(".key")) else {
            throw CoreError(code: .workspaceViolation, message: "不允许访问敏感文件: \(candidate.path)")
        }
        return candidate
    }
}

private struct PathArguments: Decodable {
    let path: String
}

private func pathArguments(_ arguments: String) throws -> PathArguments {
    guard let data = arguments.data(using: .utf8) else {
        throw CoreError(code: .toolArgumentInvalid, message: "Tool 参数不是 UTF-8")
    }
    do {
        return try JSONDecoder().decode(PathArguments.self, from: data)
    } catch {
        throw CoreError(code: .toolArgumentInvalid, message: "Tool 参数无效: \(error.localizedDescription)")
    }
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

    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let file = try workspace.resolve(pathArguments(arguments).path, profile: profile)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            throw CoreError(code: .toolExecutionFailed, message: "文件不存在: \(file.path)")
        }
        guard !isDirectory.boolValue else {
            throw CoreError(code: .toolExecutionFailed, message: "read_file 不能读取目录: \(file.path)")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maximumBytes else {
            throw CoreError(code: .toolExecutionFailed, message: "文件超过 \(Self.maximumBytes) bytes 限制: \(file.path)")
        }
        let data = try Data(contentsOf: file)
        guard let content = String(data: data, encoding: .utf8) else {
            throw CoreError(code: .toolExecutionFailed, message: "文件不是 UTF-8 文本: \(file.path)")
        }
        return content
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
        return try entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { entry in
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let kind = values.isDirectory == true ? "directory" : "file"
            let size = values.fileSize.map(String.init) ?? "-"
            return "\(entry.lastPathComponent)\t\(kind)\t\(size)"
        }.joined(separator: "\n")
    }
}

public extension ToolRegistry {
    static func builtin(workspace: WorkspaceRoot) -> ToolRegistry {
        ToolRegistry([ReadFileTool(workspace: workspace), ListDirectoryTool(workspace: workspace)])
    }
}
