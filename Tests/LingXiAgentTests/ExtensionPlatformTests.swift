import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

struct ExtensionPlatformTests {
    @Test func globalProjectSkillsAndCommandsUseProjectPrecedenceWithProvenance() async throws {
        let root = try roots()
        defer { try? FileManager.default.removeItem(at: root.base) }
        try write("global", to: root.global.appendingPathComponent("skills/shared/SKILL.md"))
        try write("project", to: root.project.appendingPathComponent(".lingxi/skills/shared/SKILL.md"))
        try write("global command", to: root.global.appendingPathComponent("commands/build.md"))
        try write("project command", to: root.project.appendingPathComponent(".lingxi/commands/build.md"))
        let skills = ExtensionDiscovery.skills(globalRoot: root.global, projectRoot: root.project)
        let commands = ExtensionDiscovery.commands(globalRoot: root.global, projectRoot: root.project)
        #expect(skills.extensions.map(\.id) == ["shared"])
        #expect(skills.extensions.first?.scope == .project)
        #expect(skills.extensions.first?.provenance.location.hasSuffix(".lingxi/skills/shared") == true)
        #expect(commands.extensions.map(\.id) == ["build"])
        #expect(commands.extensions.first?.scope == .project)
    }

    @Test func pluginLifecycleIsAtomicAndPersistsStateAcrossRestart() async throws {
        let root = try roots()
        defer { try? FileManager.default.removeItem(at: root.base) }
        let package = try plugin(root: root.base, id: "fixture", version: "1.0.0")
        let permissions = PermissionEngine(defaultDecision: .allow)
        let platform = ExtensionPlatform(globalRoot: root.global, projectRoot: root.project, permissions: permissions)
        let installed = try await platform.installPlugin(from: package)
        #expect(installed.lifecycleState == .installed)
        _ = try await platform.enable(id: "fixture", type: .plugin)
        #expect((await platform.registry.descriptor(id: "fixture", type: .plugin))?.enabled == true)
        try await platform.disable(id: "fixture", type: .plugin)
        let updatedPackage = try plugin(root: root.base, id: "fixture", version: "2.0.0")
        let updated = try await platform.updatePlugin(id: "fixture", from: updatedPackage)
        #expect(updated.version == "2.0.0")
        let restarted = ExtensionPlatform(globalRoot: root.global, projectRoot: root.project, permissions: permissions)
        await restarted.restore()
        #expect((await restarted.registry.descriptor(id: "fixture", type: .plugin))?.version == "2.0.0")
        try await restarted.uninstallPlugin(id: "fixture")
        #expect(await restarted.registry.descriptor(id: "fixture", type: .plugin) == nil)
    }

    @Test func incompatiblePluginIsRejectedAndDoesNotReplaceExistingState() async throws {
        let root = try roots()
        defer { try? FileManager.default.removeItem(at: root.base) }
        let package = try plugin(root: root.base, id: "fixture", version: "1.0.0", compatibility: ExtensionCompatibility(minimumCoreVersion: "99.0.0"))
        let platform = ExtensionPlatform(globalRoot: root.global, projectRoot: root.project, permissions: PermissionEngine(defaultDecision: .allow))
        await #expect(throws: ExtensionError.incompatible("fixture")) { try await platform.installPlugin(from: package) }
        #expect(await platform.registry.descriptor(id: "fixture", type: .plugin) == nil)
    }

    @Test func hooksIsolateSuccessFailureAndTimeout() async throws {
        let root = try roots()
        defer { try? FileManager.default.removeItem(at: root.base) }
        let platform = ExtensionPlatform(globalRoot: root.global, projectRoot: root.project, permissions: PermissionEngine(defaultDecision: .allow))
        for id in ["ok", "bad", "slow"] {
            try await platform.registry.register(ExtensionDescriptor(id: id, type: .hook, source: id, lifecycleState: .enabled))
        }
        try await platform.registerHook(extensionID: "ok", event: .agentRunStart) { _ in }
        try await platform.registerHook(extensionID: "bad", event: .agentRunStart) { _ in throw ExtensionError.lifecycle("fixture failure") }
        try await platform.registerHook(extensionID: "slow", event: .agentRunStart, timeoutSeconds: 0.01) { _ in try await Task.sleep(for: .seconds(10)) }
        let diagnostics = await platform.emit(ExtensionEvent(kind: .agentRunStart, subjectID: "run"))
        #expect(diagnostics.map(\.outcome).sorted() == ["failure", "success", "timedOut"].sorted())
        #expect(diagnostics.count == 3)
    }

    @Test func undeclaredPluginCapabilityIsDeniedByPermissionEngine() async throws {
        let root = try roots()
        defer { try? FileManager.default.removeItem(at: root.base) }
        let platform = ExtensionPlatform(globalRoot: root.global, projectRoot: root.project, permissions: PermissionEngine(configuration: .strict))
        try await platform.registry.register(ExtensionDescriptor(id: "limited", type: .plugin, source: "limited", capabilities: [.processExecute], lifecycleState: .enabled))
        await #expect(throws: ExtensionError.capabilityDenied("limited", .networkAccess)) { try await platform.requireCapability(extensionID: "limited", capability: .networkAccess) }
        await #expect(throws: ExtensionError.capabilityDenied("limited", .processExecute)) { try await platform.requireCapability(extensionID: "limited", capability: .processExecute) }
    }

    @Test func mcpStateIsManagedWithoutReplacingMCPRuntime() async throws {
        let root = try roots()
        defer { try? FileManager.default.removeItem(at: root.base) }
        let server = MCPServerRegistry()
        let platform = ExtensionPlatform(globalRoot: root.global, projectRoot: root.project, permissions: PermissionEngine(defaultDecision: .allow))
        await platform.attachMCPRegistry(server)
        let configuration = MCPServerConfiguration(serverID: MCPServerID("fixture"), alias: "Fixture", transport: .streamableHTTP, endpoint: URL(string: "https://mcp.example.invalid")!, enabled: true)
        try await platform.registerMCP(configuration)
        try await platform.disable(id: "fixture", type: .mcp)
        #expect(await server.server(MCPServerID("fixture"))?.enabled == false)
        try await platform.enable(id: "fixture", type: .mcp)
        #expect(await server.server(MCPServerID("fixture"))?.enabled == true)
    }

    @Test func malformedRegistryIsFailClosedAndOnlyProducesDiagnostics() async throws {
        let root = try roots()
        defer { try? FileManager.default.removeItem(at: root.base) }
        let state = root.global.appendingPathComponent("extension-registry.json")
        try Data("not-json".utf8).write(to: state)
        let platform = ExtensionPlatform(globalRoot: root.global, projectRoot: root.project, permissions: PermissionEngine(defaultDecision: .allow))
        await platform.restore()
        #expect(await platform.registry.all().isEmpty)
        #expect((await platform.diagnostics()).count == 1)
    }

    private func roots() throws -> (base: URL, global: URL, project: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-extension-\(UUID().uuidString)", isDirectory: true)
        let global = base.appendingPathComponent("global", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return (base, global, project)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func plugin(root: URL, id: String, version: String, compatibility: ExtensionCompatibility = ExtensionCompatibility()) throws -> URL {
        let package = root.appendingPathComponent("package-\(id)-\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let data = try JSONEncoder.sorted.encode(PluginManifest(id: id, version: version, compatibility: compatibility))
        try data.write(to: package.appendingPathComponent("extension.json"))
        return package
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}
