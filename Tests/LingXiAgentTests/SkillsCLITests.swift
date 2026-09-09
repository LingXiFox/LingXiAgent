import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiProtocol

@Suite struct SkillsCLITests {
    private func makeTestRoots() throws -> (base: URL, global: URL, project: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-skills-test-\(UUID().uuidString)")
        let global = base.appendingPathComponent("global", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return (base, global, project)
    }

    private func writeSkill(name: String, description: String, body: String, to directory: URL) throws {
        let skillDir = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let content = """
        ---
        name: \(name)
        description: \(description)
        ---
        # \(name)
        \(body)
        """
        try content.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    @Test func skillsListEmptyWhenNoSkillsDiscovered() async throws {
        let roots = try makeTestRoots()
        defer { try? FileManager.default.removeItem(at: roots.base) }

        let output = try await SkillsCLI.run(
            arguments: ["skills", "list"],
            globalRoot: roots.global,
            projectRoot: roots.project
        )

        #expect(output.contains("No skills discovered"))
        #expect(output.contains("Project:"))
        #expect(output.contains("User:"))
    }

    @Test func skillsListDiscoversProjectAndGlobalSkills() async throws {
        let roots = try makeTestRoots()
        defer { try? FileManager.default.removeItem(at: roots.base) }

        // Create project skill
        let projectSkills = roots.project.appendingPathComponent(".lingxi/skills", isDirectory: true)
        try writeSkill(name: "code-review", description: "Automated code reviewer for git PRs", body: "Reviews swift code for guidelines.", to: projectSkills)

        // Create global skill
        let globalSkills = roots.global.appendingPathComponent("skills", isDirectory: true)
        try writeSkill(name: "git-helper", description: "Useful git workflow helpers", body: "Helps rebase and cherry-pick.", to: globalSkills)

        let output = try await SkillsCLI.run(
            arguments: ["skills", "list"],
            globalRoot: roots.global,
            projectRoot: roots.project
        )

        #expect(output.contains("Discovered Skills (2)"))
        #expect(output.contains("code-review"))
        #expect(output.contains("git-helper"))
        #expect(output.contains("project"))
        #expect(output.contains("global"))
        #expect(output.contains("Automated code reviewer"))
        #expect(output.contains("● Enabled"))
    }

    @Test func skillsInfoDisplaysMetadataAndPreview() async throws {
        let roots = try makeTestRoots()
        defer { try? FileManager.default.removeItem(at: roots.base) }

        let projectSkills = roots.project.appendingPathComponent(".lingxi/skills", isDirectory: true)
        try writeSkill(
            name: "unit-tester",
            description: "Run and generate swift tests",
            body: "Run swift test with filters and report results.",
            to: projectSkills
        )

        let output = try await SkillsCLI.run(
            arguments: ["skills", "info", "unit-tester"],
            globalRoot: roots.global,
            projectRoot: roots.project
        )

        #expect(output.contains("Skill Metadata: unit-tester"))
        #expect(output.contains("project"))
        #expect(output.contains("Run and generate swift tests"))
        #expect(output.contains("Content Preview:"))
        #expect(output.contains("Run swift test with filters"))
    }

    @Test func skillsEnableAndDisableUpdatesState() async throws {
        let roots = try makeTestRoots()
        defer { try? FileManager.default.removeItem(at: roots.base) }

        let projectSkills = roots.project.appendingPathComponent(".lingxi/skills", isDirectory: true)
        try writeSkill(name: "deployer", description: "Deployment assistant", body: "Deploy artifacts.", to: projectSkills)

        // Disable
        let disableOutput = try await SkillsCLI.run(
            arguments: ["skills", "disable", "deployer"],
            globalRoot: roots.global,
            projectRoot: roots.project
        )
        #expect(disableOutput.contains("✓ Skill 'deployer' disabled"))

        // Verify listed as disabled
        let listDisabled = try await SkillsCLI.run(
            arguments: ["skills", "list"],
            globalRoot: roots.global,
            projectRoot: roots.project
        )
        #expect(listDisabled.contains("○ Disabled"))

        // Enable
        let enableOutput = try await SkillsCLI.run(
            arguments: ["skills", "enable", "deployer"],
            globalRoot: roots.global,
            projectRoot: roots.project
        )
        #expect(enableOutput.contains("✓ Skill 'deployer' enabled"))

        // Verify listed as enabled
        let listEnabled = try await SkillsCLI.run(
            arguments: ["skills", "list"],
            globalRoot: roots.global,
            projectRoot: roots.project
        )
        #expect(listEnabled.contains("● Enabled"))
    }

    @Test func skillsNotFoundShowsError() async throws {
        let roots = try makeTestRoots()
        defer { try? FileManager.default.removeItem(at: roots.base) }

        let infoOutput = try await SkillsCLI.run(
            arguments: ["skills", "info", "non-existent"],
            globalRoot: roots.global,
            projectRoot: roots.project
        )
        #expect(infoOutput.contains("Error: Skill 'non-existent' not found"))

        let enableOutput = try await SkillsCLI.run(
            arguments: ["skills", "enable", "non-existent"],
            globalRoot: roots.global,
            projectRoot: roots.project
        )
        #expect(enableOutput.contains("Error: Skill 'non-existent' not found"))
    }

    @Test func skillsHelpRendersUsage() async throws {
        let roots = try makeTestRoots()
        defer { try? FileManager.default.removeItem(at: roots.base) }

        let help = try await SkillsCLI.run(
            arguments: ["skills", "help"],
            globalRoot: roots.global,
            projectRoot: roots.project
        )
        #expect(help.contains("Skill Management Commands"))
        #expect(help.contains("lingxiagent skills list"))
        #expect(help.contains("lingxiagent skills info"))
        #expect(help.contains("lingxiagent skills enable"))
        #expect(help.contains("lingxiagent skills disable"))
    }
}
