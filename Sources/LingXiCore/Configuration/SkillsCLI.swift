import Foundation
import LingXiProtocol

public enum SkillsCLI {

    public static func run(
        arguments: [String],
        globalRoot: URL? = nil,
        projectRoot: URL? = nil,
        platform: ExtensionPlatform? = nil
    ) async throws -> String {
        let gRoot = globalRoot ?? LingXiDataRootResolver.resolve(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let pRoot = projectRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL

        let plat: ExtensionPlatform
        if let platform {
            plat = platform
        } else {
            let permissions = PermissionEngine(defaultDecision: .allow)
            plat = ExtensionPlatform(globalRoot: gRoot, projectRoot: pRoot, permissions: permissions)
        }

        await plat.restore()
        await plat.discover()

        var args = arguments
        if args.first == "skills" || args.first == "skill" {
            args.removeFirst()
        }

        let subcommand = args.first ?? "list"

        switch subcommand {
        case "list":
            return try await listSkills(platform: plat, projectRoot: pRoot)

        case "info", "show":
            guard args.count > 1 else {
                return "Error: Skill name is required. Usage: lingxiagent skills info <name>"
            }
            return try await infoSkill(name: args[1], platform: plat)

        case "enable":
            guard args.count > 1 else {
                return "Error: Skill name is required. Usage: lingxiagent skills enable <name>"
            }
            return try await setSkillEnabled(name: args[1], enabled: true, platform: plat)

        case "disable":
            guard args.count > 1 else {
                return "Error: Skill name is required. Usage: lingxiagent skills disable <name>"
            }
            return try await setSkillEnabled(name: args[1], enabled: false, platform: plat)

        case "help", "--help", "-h":
            return renderHelp()

        default:
            return "Unknown skills command: '\(subcommand)'.\n\n\(renderHelp())"
        }
    }

    // MARK: - Subcommands

    private static func listSkills(platform: ExtensionPlatform, projectRoot: URL) async throws -> String {
        let skills = await platform.list(type: .skill)
        if skills.isEmpty {
            return """
            No skills discovered.
            Skills are loaded from:
              • Project: .lingxi/skills/<name>/SKILL.md
              • User:    ~/.lingxiagent/skills/<name>/SKILL.md
            """
        }

        var rows: [[String]] = []
        for s in skills {
            let status = s.enabled ? "● Enabled" : "○ Disabled"
            let skillFile = resolveSkillFile(source: s.source)
            let desc = extractDescription(from: skillFile)
            let displayPath: String
            if s.source.hasPrefix(projectRoot.path) {
                let relative = String(s.source.dropFirst(projectRoot.path.count))
                displayPath = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
            } else {
                displayPath = s.source
            }

            rows.append([
                s.id,
                s.scope.rawValue,
                status,
                desc,
                displayPath
            ])
        }

        let table = CLIFormatter.renderTable(
            headers: ["ID", "SCOPE", "STATUS", "DESCRIPTION", "PATH"],
            rows: rows
        )

        return """
        Discovered Skills (\(skills.count)):
        \(table)
        """
    }

    private static func infoSkill(name: String, platform: ExtensionPlatform) async throws -> String {
        let skills = await platform.list(type: .skill)
        guard let skill = skills.first(where: { $0.id == name }) else {
            return "Error: Skill '\(name)' not found."
        }

        let status = skill.enabled ? "● Enabled" : "○ Disabled"
        let skillFile = resolveSkillFile(source: skill.source)
        let content = (try? String(contentsOf: skillFile, encoding: .utf8)) ?? "(Could not read SKILL.md)"
        let desc = extractDescription(from: skillFile)

        let previewLines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(25)
            .joined(separator: "\n")

        let items: [(String, String)] = [
            ("ID", skill.id),
            ("Scope", skill.scope.rawValue),
            ("Status", status),
            ("Location", skill.source),
            ("Summary", desc)
        ]

        let headerCard = CLIFormatter.renderTree(
            header: "Skill Metadata: \(skill.id)",
            items: items
        )

        return """
        \(headerCard)

        Content Preview:
        ------------------------------------------------------------
        \(previewLines)
        """
    }

    private static func setSkillEnabled(name: String, enabled: Bool, platform: ExtensionPlatform) async throws -> String {
        let skills = await platform.list(type: .skill)
        guard let skill = skills.first(where: { $0.id == name }) else {
            return "Error: Skill '\(name)' not found."
        }

        if enabled {
            try await platform.enable(id: skill.id, type: .skill, scope: skill.scope)
            return "✓ Skill '\(skill.id)' enabled."
        } else {
            try await platform.disable(id: skill.id, type: .skill, scope: skill.scope)
            return "✓ Skill '\(skill.id)' disabled."
        }
    }

    // MARK: - Helpers

    private static func resolveSkillFile(source: String) -> URL {
        let url = URL(fileURLWithPath: source)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url.appendingPathComponent("SKILL.md")
        }
        return url
    }

    private static func extractDescription(from fileURL: URL) -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return "(No description)"
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // 1. Check YAML frontmatter: --- ... description: ... ---
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "---" {
                    break
                }
                if trimmed.lowercased().hasPrefix("description:") {
                    var desc = String(trimmed.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
                    if (desc.hasPrefix("\"") && desc.hasSuffix("\"")) || (desc.hasPrefix("'") && desc.hasSuffix("'")) {
                        desc = String(desc.dropFirst().dropLast())
                    }
                    if !desc.isEmpty {
                        return truncate(desc, length: 60)
                    }
                }
            }
        }

        // 2. Fallback: First non-header non-empty line
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("---") {
                continue
            }
            return truncate(trimmed, length: 60)
        }

        return "(No description)"
    }

    private static func truncate(_ text: String, length: Int) -> String {
        if text.count <= length {
            return text
        }
        return String(text.prefix(length - 3)) + "..."
    }

    public static func renderHelp() -> String {
        """
        Skill Management Commands:

        USAGE:
          lingxiagent skills list                   列出当前项目与全局发现的所有 Skills
          lingxiagent skills info <name>            查看指定 Skill 详细信息与 Prompt 预览
          lingxiagent skills enable <name>          启用指定 Skill
          lingxiagent skills disable <name>         禁用指定 Skill
          lingxiagent skills help                   显示此帮助信息

        DIRECTORIES:
          Project Skills:  .lingxi/skills/<name>/SKILL.md
          Global Skills:   ~/.lingxiagent/skills/<name>/SKILL.md
        """
    }
}
