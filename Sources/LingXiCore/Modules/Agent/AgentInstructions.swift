import Foundation
import LingXiProtocol

struct AgentInstruction: Sendable, Equatable {
    let source: String
    let scope: String
    let content: String
    let global: Bool
}

struct AgentInstructionSet: Sendable {
    private let workspace: URL
    private let instructions: [AgentInstruction]

    static func load(workspace: URL, globalInstructionsURL: URL? = defaultGlobalInstructionsURL) throws -> Self {
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL
        let skipped = Set([".build", ".git", ".dev-sandbox", ".dev-sandbox-backups", "node_modules"])
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        )
        var instructions = (try globalInstructionsURL.flatMap(loadGlobal)).map { [$0] } ?? []

        while let candidate = enumerator?.nextObject() as? URL {
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values.isDirectory == true, skipped.contains(candidate.lastPathComponent) {
                enumerator?.skipDescendants()
                continue
            }
            guard candidate.lastPathComponent == "AGENTS.md", values.isRegularFile == true else { continue }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.lastPathComponent == "AGENTS.md", contains(root, resolved), (values.fileSize ?? 0) <= 64 * 1_024 else { continue }
            guard let content = try? String(contentsOf: resolved, encoding: .utf8) else {
                throw CoreError(code: .toolExecutionFailed, message: "无法读取 AGENTS.md: \(relative(resolved, to: root))")
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            instructions.append(AgentInstruction(
                source: relative(resolved, to: root),
                scope: relative(resolved.deletingLastPathComponent(), to: root),
                content: trimmed,
                global: false
            ))
        }
        return Self(workspace: root, instructions: instructions.sorted {
            $0.global != $1.global ? $0.global : $0.scope.count < $1.scope.count
        })
    }

    func applicable(to target: URL) -> [AgentInstruction] {
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL
        guard Self.contains(workspace, resolved) else { return [] }
        return instructions.filter { instruction in
            if instruction.global { return true }
            let scope = instruction.scope == "." ? workspace : workspace.appendingPathComponent(instruction.scope).standardizedFileURL
            return Self.contains(scope, resolved)
        }
    }

    func rendered() -> String? {
        guard !instructions.isEmpty else { return nil }
        let entries = instructions.enumerated().map { offset, instruction in
            "[AGENTS source=\(instruction.source) scope=\(instruction.scope) priority=\(offset + 1)]\n\(instruction.content)"
        }
        return "Repository instructions are scoped by target path. Apply only sources whose scope contains the target; a higher priority (closer scope) overrides a conflicting lower priority instruction. Runtime safety and the active execution profile cannot be overridden.\n\n" + entries.joined(separator: "\n\n")
    }

    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path + "/")
    }

    private static var defaultGlobalInstructionsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lingxiagent/AGENTS.md")
    }

    private static func loadGlobal(_ url: URL) throws -> AgentInstruction? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resolved.lastPathComponent == "AGENTS.md", values.isRegularFile == true, (values.fileSize ?? 0) <= 64 * 1_024 else { return nil }
        guard let content = try? String(contentsOf: resolved, encoding: .utf8) else {
            throw CoreError(code: .toolExecutionFailed, message: "无法读取全局 AGENTS.md")
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AgentInstruction(source: "~/.lingxiagent/AGENTS.md", scope: "global", content: trimmed, global: true)
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let path = url.path
        let prefix = root.path == "/" ? "/" : root.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : "."
    }
}

public struct AgentEnvironmentFacts: Sendable, Equatable {
    public let platform: String
    public let workspaceRoot: String
    public let currentDirectory: String
    public let homeDirectory: String
    public let shell: String
    public let isGitRepository: Bool
    public let gitBranch: String?
    public let accessScope: String

    public init(
        platform: String = {
            #if os(macOS)
            return "macOS"
            #elseif os(Linux)
            return "Linux"
            #elseif os(Windows)
            return "Windows"
            #else
            return "unknown"
            #endif
        }(),
        workspaceRoot: String,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        shell: String = "unknown",
        isGitRepository: Bool? = nil,
        gitBranch: String? = nil,
        accessScope: String = "workspace"
    ) {
        self.platform = platform
        self.workspaceRoot = workspaceRoot
        self.currentDirectory = currentDirectory
        self.homeDirectory = homeDirectory
        self.shell = shell
        let gitRoot = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(".git")
        self.isGitRepository = isGitRepository ?? FileManager.default.fileExists(atPath: gitRoot.path)
        if let gitBranch {
            self.gitBranch = gitBranch
        } else if let head = try? String(contentsOf: gitRoot.appendingPathComponent("HEAD"), encoding: .utf8), head.hasPrefix("ref: refs/heads/") {
            self.gitBranch = String(head.dropFirst("ref: refs/heads/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            self.gitBranch = nil
        }
        self.accessScope = accessScope
    }

    public func render() -> String {
        """
        Environment facts:
        - platform: \(platform)
        - workspaceRoot: \(workspaceRoot)
        - cwd: \(currentDirectory)
        - userHome: \(homeDirectory)
        - shell: \(shell)
        - gitRepository: \(isGitRepository ? "yes" : "no")\(gitBranch.map { " · branch: \($0)" } ?? "")
        - accessScope: \(accessScope)
        """
    }
}

enum AgentBehaviorInstructions {
    static func render(
        profile: AgentBehaviorProfile,
        configured: String?,
        repository: AgentInstructionSet,
        environmentFacts: AgentEnvironmentFacts? = nil
    ) -> String? {
        var entries: [String] = []
        if let facts = environmentFacts {
            entries.append(facts.render())
        }
        switch profile {
        case .build:
            entries.append("Build profile: inspect before editing; after every mutation, run the narrowest relevant verification. On tool failure or timeout, use returned diagnostics to change strategy or report the blocker. Before completion, inspect the diff and verification result. Do not repeat an identical failed action.")
        case .plan:
            entries.append("Plan profile: investigate with read-only tools and return an executable plan with evidence. Repository mutation is forbidden by runtime capability policy.")
        case .explore:
            entries.append("Explore profile: use read-only search and inspection, report evidence and uncertainty, and do not mutate the repository. Mutation is forbidden by runtime capability policy.")
        }
        if let configured, !configured.isEmpty { entries.append(configured) }
        if let repository = repository.rendered() { entries.append(repository) }
        return entries.joined(separator: "\n\n")
    }
}
