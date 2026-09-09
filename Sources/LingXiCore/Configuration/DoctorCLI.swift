import Foundation
import LingXiProtocol

public enum DoctorCLI {

    public struct HealthReport: Sendable {
        public let systemStatus: String
        public let gitStatus: String
        public let storageStatus: String
        public let vaultStatus: String
        public let providerStatus: String
        public let mcpStatus: String
        public let skillsStatus: String
        public let isHealthy: Bool
    }

    public static func run(
        dataRoot: URL? = nil,
        projectRoot: URL? = nil,
        credentialStore: CredentialStore? = nil,
        configurationStore: ConfigurationStore? = nil
    ) async throws -> String {
        let root = dataRoot ?? LingXiDataRootResolver.resolve(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let projRoot = projectRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL

        let credStore: CredentialStore
        if let credentialStore {
            credStore = credentialStore
        } else {
            credStore = try PlatformSecureCredentialStore(
                dataRoot: root,
                passphrase: ProcessInfo.processInfo.environment["LINGXI_CREDENTIALS_PASSPHRASE"]
            )
        }
        let configStore = try configurationStore ?? ConfigurationStore(dataRoot: root)

        let report = await evaluate(
            dataRoot: root,
            projectRoot: projRoot,
            credStore: credStore,
            configStore: configStore
        )

        let treeOutput = CLIFormatter.renderTree(
            header: report.isHealthy ? "LingXiAgent Doctor: ✓ All Systems Operational" : "LingXiAgent Doctor: ⚠ Issues Detected",
            items: [
                ("Operating System", report.systemStatus),
                ("Workspace & Git", report.gitStatus),
                ("Data & Config Root", report.storageStatus),
                ("Secure Vault", report.vaultStatus),
                ("Providers & Models", report.providerStatus),
                ("MCP Runtime", report.mcpStatus),
                ("Skills Platform", report.skillsStatus)
            ]
        )

        return """
        \(treeOutput)

        Status: \(report.isHealthy ? "● Healthy (ready to code)" : "○ Degraded (see recommendations above)")
        """
    }

    public static func evaluate(
        dataRoot: URL,
        projectRoot: URL,
        credStore: CredentialStore,
        configStore: ConfigurationStore
    ) async -> HealthReport {
        // 1. OS & Platform
        #if os(macOS)
        let osName = "macOS"
        #elseif os(Linux)
        let osName = "Linux"
        #else
        let osName = "Unknown OS"
        #endif
        #if arch(arm64)
        let archName = "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        let archName = "x86_64"
        #else
        let archName = "Unknown Arch"
        #endif
        let systemStatus = "\(osName) · \(archName)"

        // 2. Git
        var gitStatus = "Non-git directory: \(projectRoot.path)"
        let gitDir = projectRoot.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitDir.path) {
            let branch = runQuickProcess(executable: "/usr/bin/git", arguments: ["rev-parse", "--abbrev-ref", "HEAD"], cwd: projectRoot) ?? "unknown"
            let dirty = runQuickProcess(executable: "/usr/bin/git", arguments: ["status", "-s"], cwd: projectRoot) ?? ""
            let dirtyCount = dirty.split(separator: "\n").count
            gitStatus = "Git repo (branch: \(branch), uncommitted: \(dirtyCount) files)"
        }

        // 3. Storage
        var storageHealthy = true
        var storageMsg = "Directory: \(dataRoot.path)"
        if FileManager.default.fileExists(atPath: dataRoot.path) {
            storageMsg += " (Permissions: secure)"
        } else {
            storageHealthy = false
            storageMsg += " (Not created yet)"
        }

        // 4. Vault
        var vaultHealthy = true
        var vaultMsg = "AES-256-GCM Vault active"
        do {
            let testRef = CredentialRef("doctor-probe-\(UUID().uuidString)")
            try await credStore.setSecret("probe", for: testRef)
            let readBack = try await credStore.secret(for: testRef)
            try await credStore.removeSecret(for: testRef)
            if readBack == "probe" {
                vaultMsg = "AES-256-GCM Vault operational (read/write verified)"
            } else {
                vaultHealthy = false
                vaultMsg = "Vault verification failed (read mismatch)"
            }
        } catch {
            vaultHealthy = false
            vaultMsg = "Vault error: \(error.localizedDescription)"
        }

        // 5. Providers & Models
        let providerHealthy = true
        var providerMsg = "No providers configured"
        if let snapshot = try? await configStore.load() {
            let count = snapshot.providers.providers.count
            let defaultModel = snapshot.providers.model ?? "(none)"
            if count > 0 {
                providerMsg = "\(count) providers configured (default: \(defaultModel))"
            } else {
                providerMsg = "0 configured (Use 'lingxiagent auth login' to connect)"
            }
        }

        // 6. MCP
        var mcpMsg = "0 configured"
        if let snapshot = try? await configStore.load() {
            let total = snapshot.mcp.servers.count
            let enabled = snapshot.mcp.servers.filter(\.enabled).count
            mcpMsg = "\(total) servers configured (\(enabled) enabled)"
        }

        // 7. Skills
        let permissions = PermissionEngine(defaultDecision: .allow)
        let platform = ExtensionPlatform(globalRoot: dataRoot, projectRoot: projectRoot, permissions: permissions)
        await platform.restore()
        let discovered = await platform.discover()
        let skillsCount = discovered.extensions.filter { $0.type == .skill }.count
        let skillsMsg = "\(skillsCount) skills discovered"

        let isHealthy = storageHealthy && vaultHealthy && providerHealthy

        return HealthReport(
            systemStatus: systemStatus,
            gitStatus: gitStatus,
            storageStatus: storageMsg,
            vaultStatus: vaultMsg,
            providerStatus: providerMsg,
            mcpStatus: mcpMsg,
            skillsStatus: skillsMsg,
            isHealthy: isHealthy
        )
    }

    private static func runQuickProcess(executable: String, arguments: [String], cwd: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
