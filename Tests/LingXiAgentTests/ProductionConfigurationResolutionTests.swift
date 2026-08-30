import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

struct ProductionConfigurationResolutionTests {
    @Test func explicitProfilesResolveWithoutProviderEnvironment() async throws {
        for (wire, expectedType) in [
            (StoredProviderWireProtocol.chatCompletions, "chat"),
            (.responses, "responses"),
            (.anthropicMessages, "anthropic"),
        ] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let credentials = try FileCredentialStore(dataRoot: root)
            let resolution = try await RuntimeConfigurationResolver.resolveProviders(
                configuration(wire: wire),
                credentials: credentials
            )

            #expect(resolution.missingRequirements.isEmpty)
            #expect(resolution.defaultSelection?.accountID == "account")
            #expect(resolution.assembly.endpoint.providerID == "custom")
            #expect(resolution.assembly.endpoint.modelID.rawValue == "model")
            let expectedWire: ModelWireProtocol = switch wire {
            case .chatCompletions: .chatCompletions
            case .responses: .responses
            case .anthropicMessages: .anthropicMessages
            }
            #expect(resolution.assembly.endpoint.wireProtocol == expectedWire)
            if expectedType == "responses" {
                #expect(resolution.assembly.provider is OpenAIResponsesProvider)
            } else if expectedType == "anthropic" {
                #expect(resolution.assembly.provider is AnthropicMessagesProvider)
            } else {
                #expect(resolution.assembly.provider is OpenAICompatibleProvider)
            }
        }
    }

    @Test func emptyConfigurationIsExplicitlyUnresolved() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolution = try await RuntimeConfigurationResolver.resolveProviders(
            ProvidersConfiguration(),
            credentials: try FileCredentialStore(dataRoot: root)
        )

        #expect(resolution.defaultSelection == nil)
        #expect(resolution.missingRequirements == ["providers.defaultSelection"])
    }

    @Test func accountAndProfileSelectIndependentWireRuntimes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var stored = configuration(wire: .chatCompletions)
        stored.modelProfiles.append(ModelProfileConfiguration(
            id: "responses-profile",
            providerID: "custom",
            modelID: "responses-model",
            displayName: "Responses Model",
            wireProtocol: .responses,
            contextWindow: 64_000
        ))
        let resolution = try await RuntimeConfigurationResolver.resolveProviders(
            stored,
            credentials: try FileCredentialStore(dataRoot: root)
        )
        let resolver = SubagentModelResolver(
            defaultRuntime: resolution.assembly,
            runtimes: resolution.runtimes,
            defaultSelection: resolution.defaultSelection
        )
        let selected = try await resolver.resolve(ModelSelection(
            providerID: "custom",
            accountID: "account",
            profileID: "responses-profile",
            modelID: "responses-model"
        ))

        #expect(resolution.runtimes.count == 2)
        #expect(selected.assembly.endpoint.wireProtocol == .responses)
        #expect(selected.selection.profileID == "responses-profile")
    }

    @Test func credentialAndEndpointValidationFailBeforeRuntime() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try FileCredentialStore(dataRoot: root)
        var missingCredential = configuration(wire: .chatCompletions)
        missingCredential.accounts[0].authentication = .bearer
        missingCredential.accounts[0].credential = CredentialRef("missing")

        await expectValidationError(path: "$.accounts.account.credential") {
            _ = try await RuntimeConfigurationResolver.resolveProviders(missingCredential, credentials: credentials)
        }

        var insecure = configuration(wire: .chatCompletions)
        insecure.customProviders[0].baseURL = "http://provider.example.com/v1"
        await expectValidationError(path: "$.accounts.account.endpointOverride") {
            _ = try await RuntimeConfigurationResolver.resolveProviders(insecure, credentials: credentials)
        }
    }

    @Test func dataRootUsesOneDefaultAndExplicitOverride() {
        let home = URL(fileURLWithPath: "/home/test", isDirectory: true)
        #expect(LingXiDataRootResolver.resolve(environment: [:], homeDirectory: home).path == "/home/test/.lingxiagent")
        #expect(LingXiDataRootResolver.resolve(environment: ["LINGXI_DATA_ROOT": "/tmp/lingxi"], homeDirectory: home).path == "/tmp/lingxi")
    }

    @Test func mcpConfigurationMapsCredentialReferencesWithoutEnvironmentReads() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try FileCredentialStore(dataRoot: root)
        try await credentials.setSecret("bearer-secret", for: CredentialRef("mcp-bearer"))
        try await credentials.setSecret("env-secret", for: CredentialRef("mcp-env"))
        let resolution = try await RuntimeConfigurationResolver.resolveMCP(
            MCPConfiguration(servers: [
                StoredMCPServerConfiguration(
                    id: "http",
                    alias: "HTTP",
                    transport: .streamableHTTP,
                    endpoint: "http://127.0.0.1:9999/mcp",
                    authentication: MCPAuthenticationConfiguration(kind: .bearer, credential: CredentialRef("mcp-bearer"))
                ),
                StoredMCPServerConfiguration(
                    id: "stdio",
                    alias: "Stdio",
                    transport: .stdio,
                    command: "/usr/bin/true",
                    environment: [MCPEnvironmentCredential(name: "TOKEN", credential: CredentialRef("mcp-env"))]
                ),
            ]),
            credentials: credentials,
            discoverTools: false
        )

        #expect(resolution.configurations.count == 2)
        #expect(resolution.configurations[0].auth == .bearer(SecretRef("mcp-bearer")))
        #expect(resolution.configurations[1].environment == ["TOKEN": SecretRef("mcp-env")])
    }

    @Test func mcpMissingCredentialFailsBeforeTransport() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try FileCredentialStore(dataRoot: root)
        let configuration = MCPConfiguration(servers: [
            StoredMCPServerConfiguration(
                id: "http",
                alias: "HTTP",
                transport: .streamableHTTP,
                endpoint: "https://mcp.example.com",
                authentication: MCPAuthenticationConfiguration(kind: .bearer, credential: CredentialRef("missing"))
            ),
        ])

        await expectValidationError(path: "$.servers.http.authentication.credential") {
            _ = try await RuntimeConfigurationResolver.resolveMCP(configuration, credentials: credentials, discoverTools: false)
        }

        var disabled = configuration
        disabled.servers[0].enabled = false
        let resolved = try await RuntimeConfigurationResolver.resolveMCP(disabled, credentials: credentials, discoverTools: false)
        #expect(resolved.configurations.first?.enabled == false)
    }

    @Test func stdioMCPEnforcesConfiguredTimeout() async {
        let transport = MCPStdioTransport(configuration: MCPServerConfiguration(
            serverID: MCPServerID("slow"),
            alias: "Slow",
            transport: .stdio,
            command: "/bin/sleep",
            arguments: ["1"],
            timeoutSeconds: 0.01
        ))
        do {
            _ = try await transport.call(serverID: MCPServerID("slow"), toolName: "ignored", arguments: "{}")
            Issue.record("stdio MCP should time out")
        } catch let error as CoreError {
            #expect(error.code == .commandTimedOut)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    private func configuration(wire: StoredProviderWireProtocol) -> ProvidersConfiguration {
        ProvidersConfiguration(
            customProviders: [CustomProviderConfiguration(id: "custom", displayName: "Custom", baseURL: "https://provider.example.com/v1")],
            accounts: [ProviderAccountConfiguration(id: "account", providerID: "custom", displayName: "Account")],
            modelProfiles: [ModelProfileConfiguration(id: "profile", providerID: "custom", modelID: "model", displayName: "Model", wireProtocol: wire, contextWindow: 32_768)],
            defaultSelection: StoredModelSelection(accountID: "account", profileID: "profile")
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-runtime-configuration-\(UUID().uuidString)", isDirectory: true)
    }

    private func expectValidationError(path: String, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("configuration should fail validation")
        } catch let error as ConfigurationValidationError {
            #expect(error.path == path)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
