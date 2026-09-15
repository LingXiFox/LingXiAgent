import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

struct SensitivePathPolicyTests {
    @Test func modelConfigurationDirectoryAndFilesAreNotSensitive() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let policy = SensitivePathPolicy(root: home)

        let configDir = home.appendingPathComponent(".lingxiagent", isDirectory: true)
        let configFile = configDir.appendingPathComponent("config.json")
        let providersFile = configDir.appendingPathComponent("providers.json")
        let modelsFile = configDir.appendingPathComponent("models.json")
        let preferencesFile = configDir.appendingPathComponent("preferences.json")
        let customModelFile = configDir.appendingPathComponent("custom-models.yaml")
        let skillsDir = configDir.appendingPathComponent("skills/my-skill", isDirectory: true)

        #expect(policy.isSensitive(configDir) == false)
        #expect(policy.isSensitive(configFile) == false)
        #expect(policy.isSensitive(providersFile) == false)
        #expect(policy.isSensitive(modelsFile) == false)
        #expect(policy.isSensitive(preferencesFile) == false)
        #expect(policy.isSensitive(customModelFile) == false)
        #expect(policy.isSensitive(skillsDir) == false)
    }

    @Test func explicitCredentialsInsideOrOutsideConfigDirAreAlwaysSensitive() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let policy = SensitivePathPolicy(root: home)

        let configDir = home.appendingPathComponent(".lingxiagent", isDirectory: true)
        let vaultFile = configDir.appendingPathComponent("credentials.vault")
        let vaultKeyFile = configDir.appendingPathComponent(".vault_key")
        let envInConfig = configDir.appendingPathComponent(".env")
        let envLocalInConfig = configDir.appendingPathComponent(".env.local")

        #expect(policy.isSensitive(vaultFile) == true)
        #expect(policy.isSensitive(vaultKeyFile) == true)
        #expect(policy.isSensitive(envInConfig) == true)
        #expect(policy.isSensitive(envLocalInConfig) == true)

        let projectRoot = URL(fileURLWithPath: "/workspace/my-project")
        let projectPolicy = SensitivePathPolicy(root: projectRoot)

        #expect(projectPolicy.isSensitive(projectRoot.appendingPathComponent(".env")) == true)
        #expect(projectPolicy.isSensitive(projectRoot.appendingPathComponent(".env.local")) == true)
        #expect(projectPolicy.isSensitive(projectRoot.appendingPathComponent("develop.env")) == true)
        #expect(projectPolicy.isSensitive(projectRoot.appendingPathComponent("prod.env")) == true)
        #expect(projectPolicy.isSensitive(projectRoot.appendingPathComponent(".ssh/id_rsa")) == true)
        #expect(projectPolicy.isSensitive(projectRoot.appendingPathComponent(".aws/credentials")) == true)
        #expect(projectPolicy.isSensitive(projectRoot.appendingPathComponent("cert.pem")) == true)
        #expect(projectPolicy.isSensitive(projectRoot.appendingPathComponent("server.key")) == true)
        #expect(projectPolicy.isSensitive(projectRoot.appendingPathComponent("db-credentials.json")) == true)
        #expect(projectPolicy.isSensitive(projectRoot.appendingPathComponent("service-secret.txt")) == true)
        #expect(projectPolicy.isSensitive(projectRoot.appendingPathComponent("api-token.txt")) == true)
    }

    @Test func ordinaryCodeFilesWithTokenOrSecretWordsAreNotBlocked() {
        let root = URL(fileURLWithPath: "/workspace/my-project")
        let policy = SensitivePathPolicy(root: root)

        #expect(policy.isSensitive(root.appendingPathComponent("Sources/tokenizer.swift")) == false)
        #expect(policy.isSensitive(root.appendingPathComponent("Sources/token_counter.py")) == false)
        #expect(policy.isSensitive(root.appendingPathComponent("Sources/SecretSharingAlgorithm.java")) == false)
        #expect(policy.isSensitive(root.appendingPathComponent("tokens.json")) == false)
    }

    @Test func workspaceRootResolvesModelConfigPathWithoutWorkspaceViolation() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workspace = try WorkspaceRoot(path: tempDir.path)

        // Resolving ~/.lingxiagent or ~/.lingxiagent/config.json should succeed
        let resolvedConfigDir = try workspace.resolve("~/.lingxiagent")
        #expect(resolvedConfigDir.path.hasSuffix("/.lingxiagent"))

        let resolvedConfigFile = try workspace.resolve("~/.lingxiagent/config.json")
        #expect(resolvedConfigFile.path.hasSuffix("/.lingxiagent/config.json"))

        let resolvedProvidersFile = try workspace.resolve("~/.lingxiagent/providers.json")
        #expect(resolvedProvidersFile.path.hasSuffix("/.lingxiagent/providers.json"))

        // But credentials.vault should still throw sensitive path violation
        #expect(throws: CoreError.self) {
            try workspace.resolve("~/.lingxiagent/credentials.vault")
        }
    }

    @Test func builtinToolsCanListAndReadModelConfigDirectoryWhileFilteringVault() async throws {
        let tempWorkspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let mockHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let mockConfigDir = mockHome.appendingPathComponent(".lingxiagent", isDirectory: true)
        try FileManager.default.createDirectory(at: tempWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mockConfigDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempWorkspace)
            try? FileManager.default.removeItem(at: mockHome)
        }

        // Create files in mock .lingxiagent
        let configFile = mockConfigDir.appendingPathComponent("config.json")
        let providersFile = mockConfigDir.appendingPathComponent("providers.json")
        let vaultFile = mockConfigDir.appendingPathComponent("credentials.vault")
        let keyFile = mockConfigDir.appendingPathComponent(".vault_key")

        try "{\"model\":\"opencode-zen\"}".write(to: configFile, atomically: true, encoding: .utf8)
        try "{\"providers\":[]}".write(to: providersFile, atomically: true, encoding: .utf8)
        try "encrypted-vault-bytes".write(to: vaultFile, atomically: true, encoding: .utf8)
        try "secret-key".write(to: keyFile, atomically: true, encoding: .utf8)

        let workspace = try WorkspaceRoot(path: tempWorkspace.path)
        let runtime = ToolRuntime(registry: .builtin(workspace: workspace), permissions: PermissionEngine(defaultDecision: .allow))

        // List directory of mockConfigDir: should include config.json and providers.json, but NOT credentials.vault or .vault_key
        let listCall = ToolCall(callID: ToolCallID("call-1"), toolID: ToolID("list_directory"), arguments: "{\"path\":\"\(mockConfigDir.path)\"}")
        let listResult = await runtime.execute(listCall, sessionID: SessionID("s")) { _ in }
        #expect(listResult.success)
        #expect(listResult.content.contains("config.json"))
        #expect(listResult.content.contains("providers.json"))
        #expect(!listResult.content.contains("credentials.vault"))
        #expect(!listResult.content.contains(".vault_key"))

        // Read config.json: should succeed
        let readCall = ToolCall(callID: ToolCallID("call-2"), toolID: ToolID("read_file"), arguments: "{\"path\":\"\(configFile.path)\"}")
        let readResult = await runtime.execute(readCall, sessionID: SessionID("s")) { _ in }
        #expect(readResult.success)
        #expect(readResult.content == "{\"model\":\"opencode-zen\"}")

        // Read credentials.vault: should be blocked with sensitive path error
        let readVaultCall = ToolCall(callID: ToolCallID("call-3"), toolID: ToolID("read_file"), arguments: "{\"path\":\"\(vaultFile.path)\"}")
        let readVaultResult = await runtime.execute(readVaultCall, sessionID: SessionID("s")) { _ in }
        #expect(!readVaultResult.success)
        #expect(readVaultResult.error?.code == CoreError.Code.workspaceViolation.rawValue)
        #expect(readVaultResult.error?.message == "不允许访问敏感路径")
    }
}
