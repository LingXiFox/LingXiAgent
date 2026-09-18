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
        platform: String = LingXiPlatform.system.osName,
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
    static let runtimeGuidelines = """
    Agent Runtime Guidelines:
    - File Operations Protocol (CRITICAL):
      * Always use dedicated file mutation tools: `write_file` (for creating new files or full overwrites) and `edit_file` or `apply_patch` (for surgical edits and patches).
      * NEVER use shell/bash commands (such as `cat <<EOF`, `echo >`, `sed`, `awk`, or redirection scripts) to write, create, or modify files. Shell execution is strictly reserved for compilation, testing, package management, git commands, and process execution.
    - Background Execution Protocol (CRITICAL):
      * When the user requests running commands in the background (e.g. '在后台跑', '移交后台', long processes, watchers, servers, or delay/sleep), or whenever executing long-running operations that should not block the conversation, you MUST call `run_background_command` (specifying mandatory `timeout_seconds`, 1~7200s).
      * NEVER use foreground `shell` to run sleep/delays, daemonize with `&`, or execute blocking commands when asked for background execution.
      * DO NOT enter a busy-waiting loop calling `manage_background_command(action: 'poll')` repeatedly in the same turn when a task is running.
      * If a task is still running, IMMEDIATELY inform the user that the task has started in the background (reporting its task ID, timeout, and description) and return control to the user. The runtime will automatically inject system notifications when the background task completes, exits, or produces outputs.
      * You can inspect or manage background tasks using `manage_background_command` (actions: 'poll', 'input', 'terminate', 'list').
      * The user can monitor or cancel background tasks anytime via the `/tasks` command or status bar in the TUI.
    - Task Planning: For multi-step tasks, investigations, or refactoring, proactively use `todo` (action: 'add') to establish a checklist, and update task status ('in_progress', 'completed', 'failed') as you advance to keep the sidebar updated.
    - Parallel Tool Calling: When you need to read multiple files, inspect directories, grep across files, or perform independent read-only investigations, emit multiple tool calls in parallel within the same turn instead of waiting for sequential round-trips. The runtime executes independent tool calls concurrently.
    - Computer & Browser Use Protocol:
      * NOTE: Computer Use and Browser Use tools (`computer_batch`, `browser_navigate`, `browser_act`) are currently FROZEN and disabled per owner directive. Do NOT attempt to invoke them.
    - Model & Provider Configuration Protocol (CRITICAL):
      * When asked to configure, add, or update LLM models or custom providers (e.g. OpenCode Zen, OpenAI, DeepSeek, Anthropic, or local endpoints):
        - The canonical configuration file is `~/.lingxiagent/providers.json` (or `.lingxiagent/providers.json` in workspace).
        - NEVER search the codebase or Swift implementation files to figure out configuration format.
        - Schema & format:
          {
            "$schema": "https://lingxiagent.lingxifox.cn/schema/providers.json",
            "version": 1,
            "model": "provider-id/model-id", // optional default selection
            "providers": {
              "provider-id": {
                "name": "Provider Name",
                "adapter": "openai-responses" | "openai-compatible" | "anthropic-messages",
                "models": {
                  "model-id": {
                    "name": "Model Display Name",
                    "limit": { "context": 131072, "output": 8192 },
                    "toolCalling": true,
                    "parallelToolCalling": true,
                    "reasoning": true,
                    "vision": false,
                    "structuredOutput": false
                  }
                },
                "options": {
                  "baseURL": "https://api.example.com/v1", // or endpoint without /responses or /chat/completions
                  "token": "{env:API_KEY_NAME}"
                }
              }
            }
          }
    - Goal-Directed Execution & Convergence Protocol (/goal Mode - CRITICAL):
      * Monotonic Progress Principle: Every single tool action MUST move the task closer to the final tangible deliverable. NEVER wander into speculative, open-ended research when the deliverable can be produced directly.
      * Anti-Dispersion Circuit Breaker:
        - NEVER execute more than 2 consecutive exploratory search/grep queries without performing a concrete mutation or delivery action.
        - As soon as you locate the target file or understand the target data structure (e.g. `providers.json`), STOP searching immediately and perform the modification directly with `edit_file` or `write_file`.
        - DO NOT deep-dive into compiler internals, Swift protocols, or unrelated framework files when the user only asked for a configuration, script, or feature patch.
        - When a non-essential tool fails (e.g. web search unavailable, optional documentation missing), DO NOT get sidetracked trying to debug or investigate why the tool failed. Pivot immediately to the shortest local alternative and converge toward the user goal.
      * Bias for Immediate Completion: Once the required change is written and verified, STOP calling more tools and deliver the final answer concisely to the user. Do NOT perform unnecessary speculative cleanup or unprompted secondary investigations.
    - Tool Discovery: Builtin tools are always available for filesystem, grep, and execution. If `search_tools` returns no matches or a diagnostic notice (empty/error), do not retry searching; proceed with builtin tools.
    - Execution & Truthfulness: Inspect before mutating, run verification after changes, and report obstacles truthfully without hallucination.
    """

    static func renderResidentMCPCatalog() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let mcpFile = home.appendingPathComponent(".lingxiagent/mcp.json")
        var serversSummary: [String] = []

        if let data = try? Data(contentsOf: mcpFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = json["servers"] as? [[String: Any]] {
            for server in servers where (server["enabled"] as? Bool ?? true) {
                guard let id = (server["alias"] as? String) ?? (server["id"] as? String), !id.isEmpty else { continue }
                let transport = server["transport"] as? String ?? "stdio"
                if let desc = server["description"] as? String, !desc.isEmpty {
                    serversSummary.append("- **\(id)** (\(transport)): \(desc)")
                } else {
                    serversSummary.append("- **\(id)** (transport: \(transport))")
                }
            }
        }

        if serversSummary.isEmpty {
            return ""
        }

        return """
        # Active MCP Servers
        The following external MCP servers are currently configured and enabled:
        \(serversSummary.joined(separator: "\n"))

        ## How to Use MCP Tools:
        1. Discover tools: call `search_tools(query: "<keyword>", server: "<optional_server_alias>")` to discover available tool IDs and their schemas.
        2. Lease tool: call `load_tool(tool_id: "<tool_name>")` to arm the tool for execution.
        3. Execute tool: call `execute_tool(tool_id: "<tool_name>", arguments: <arguments_json>)` to invoke the leased tool.
        4. Prefer specialized MCP tools over manual or speculative exploration when applicable.
        """
    }

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
        entries.append(runtimeGuidelines)
        let mcpCatalog = renderResidentMCPCatalog()
        if !mcpCatalog.isEmpty {
            entries.append(mcpCatalog)
        }
        if let configured, !configured.isEmpty { entries.append(configured) }
        if let repository = repository.rendered() { entries.append(repository) }
        return entries.joined(separator: "\n\n")
    }
}
