import Foundation
import LingXiKernel
import LingXiPluginABI
import LingXiPluginRuntime
import LingXiSettingsProtocol
import Testing

private struct StaticSettingsProvider: PluginSettingsProviding {
    let snapshot: PluginSettingsSnapshot?

    func settings(for bundleID: String) async throws -> PluginSettingsSnapshot? {
        snapshot
    }
}

private func startupCoordinator(
    bundleID: String, dylib: String, capabilities: [String],
    settings: PluginSettingsSnapshot?
) async throws -> (PluginCoordinator, ModelRouter, TestBundle) {
    let bundle = try makeBundle(
        bundleID: bundleID, executableName: bundleID.split(separator: ".").last.map(String.init) ?? "Plugin",
        dylib: builtProduct(dylib), capabilities: capabilities
    )
    let registry = try PluginRegistry(configURL: nil)
    let router = ModelRouter()
    let coordinator = PluginCoordinator(
        hostExecutableURL: builtProduct("LingXiPluginHost"),
        registry: registry, pipeline: HookPipeline(), router: router,
        settingsProvider: StaticSettingsProvider(snapshot: settings)
    )
    try await coordinator.install(bundleID: bundleID, version: "1.0.0", bundlePath: bundle.url.path)
    return (coordinator, router, bundle)
}

@Test("startup restores a committed settings snapshot before registering model routes")
func startupSettingsRestoreSucceeds() async throws {
    let settings = PluginSettingsSnapshot(version: 1, config: .object([
        "protocolKind": .string("chatCompletions"),
        "model": .string("mimo-v2.6-flash"),
        "thinkingMode": .string("enabled"),
    ]))
    let (coordinator, router, _) = try await startupCoordinator(
        bundleID: "site.lingxi.provider.mimo", dylib: "libMiMoProvider.dylib",
        capabilities: ["provider.mimo", "settings.view.v1"], settings: settings
    )
    defer { Task { try? await coordinator.disable(bundleID: "site.lingxi.provider.mimo") } }
    _ = try await coordinator.enable(
        bundleID: "site.lingxi.provider.mimo", policy: .development,
        grantedPermissions: []
    )
    #expect(await router.offeredModels.map(\.rawValue).sorted() == ["mimo-v2.6-flash", "mimo-v2.6-pro"])
}

@Test("a plugin rejection during startup restore fails enable and registers no model route")
func startupSettingsRejectionFailsEnable() async throws {
    let settings = PluginSettingsSnapshot(version: 1, config: .object([
        "protocolKind": .string("not-a-protocol"),
        "model": .string("mimo-v2.6-flash"),
        "thinkingMode": .string("default"),
    ]))
    let (coordinator, router, _) = try await startupCoordinator(
        bundleID: "site.lingxi.provider.mimo", dylib: "libMiMoProvider.dylib",
        capabilities: ["provider.mimo", "settings.view.v1"], settings: settings
    )
    defer { Task { await coordinator.shutdown() } }
    var failure: Error?
    do {
        _ = try await coordinator.enable(
            bundleID: "site.lingxi.provider.mimo", policy: .development,
            grantedPermissions: []
        )
    } catch {
        failure = error
    }
    #expect(failure != nil)
    #expect(await router.offeredModels.isEmpty)
    #expect(await coordinator.runningBundleIDs().isEmpty)
    #expect(await coordinator.processIdentifier(bundleID: "site.lingxi.provider.mimo") == nil)
}

@Test("saved settings without a declared settings capability fail instead of using defaults")
func startupSettingsWithoutCapabilityFails() async throws {
    let settings = PluginSettingsSnapshot(version: 1, config: .object([:]))
    let (coordinator, router, _) = try await startupCoordinator(
        bundleID: "site.lingxi.plugin.contextprobe", dylib: "libLingXiContextProbe.dylib",
        capabilities: ["hook.contextProbe"], settings: settings
    )
    defer { Task { await coordinator.shutdown() } }
    var failure: Error?
    do {
        _ = try await coordinator.enable(
            bundleID: "site.lingxi.plugin.contextprobe", policy: .development,
            grantedPermissions: []
        )
    } catch {
        failure = error
    }
    #expect(failure != nil)
    #expect(await router.offeredModels.isEmpty)
    #expect(await coordinator.runningBundleIDs().isEmpty)
}

@Test("no saved settings keeps the legacy default behavior")
func startupSettingsAbsentUsesDefaults() async throws {
    let (coordinator, router, _) = try await startupCoordinator(
        bundleID: "site.lingxi.provider.mimo", dylib: "libMiMoProvider.dylib",
        capabilities: ["provider.mimo", "settings.view.v1"], settings: nil
    )
    defer { Task { try? await coordinator.disable(bundleID: "site.lingxi.provider.mimo") } }
    _ = try await coordinator.enable(
        bundleID: "site.lingxi.provider.mimo", policy: .development,
        grantedPermissions: []
    )
    #expect(await router.offeredModels.count == 2)
}

private struct ThrowingSettingsProvider: PluginSettingsProviding {
    func settings(for bundleID: String) async throws -> PluginSettingsSnapshot? {
        throw NSError(domain: "settings", code: 1, userInfo: [NSLocalizedDescriptionKey: "corrupt settings"])
    }
}

@Test("a settings read failure during startup aborts enable before routes are registered")
func startupSettingsReadFailureFailsEnable() async throws {
    let bundle = try makeBundle(
        bundleID: "site.lingxi.provider.mimo", executableName: "MiMoProvider",
        dylib: builtProduct("libMiMoProvider.dylib"),
        capabilities: ["provider.mimo", "settings.view.v1"]
    )
    let registry = try PluginRegistry(configURL: nil)
    let router = ModelRouter()
    let coordinator = PluginCoordinator(
        hostExecutableURL: builtProduct("LingXiPluginHost"),
        registry: registry, pipeline: HookPipeline(), router: router,
        settingsProvider: ThrowingSettingsProvider()
    )
    try await coordinator.install(bundleID: "site.lingxi.provider.mimo", version: "1.0.0", bundlePath: bundle.url.path)
    defer { Task { await coordinator.shutdown() } }
    await #expect(throws: (any Error).self) {
        _ = try await coordinator.enable(
            bundleID: "site.lingxi.provider.mimo", policy: .development,
            grantedPermissions: []
        )
    }
    #expect(await router.offeredModels.isEmpty)
    #expect(await coordinator.runningBundleIDs().isEmpty)
}

@Test("a settings host crash during startup restore fails enable and leaves no live host")
func startupSettingsCrashFailsEnable() async throws {
    let bundle = try makeBundle(
        bundleID: "site.lingxi.probe.settings", executableName: "LingXiSettingsProbe",
        dylib: builtProduct("libLingXiSettingsProbe.dylib"),
        capabilities: ["settings.view.v1"]
    )
    let registry = try PluginRegistry(configURL: nil)
    let router = ModelRouter()
    let coordinator = PluginCoordinator(
        hostExecutableURL: builtProduct("LingXiPluginHost"),
        registry: registry, pipeline: HookPipeline(), router: router,
        settingsProvider: StaticSettingsProvider(
            snapshot: PluginSettingsSnapshot(version: 1, config: .object(["name": .string("probe")]))
        )
    )
    try await coordinator.install(
        bundleID: "site.lingxi.probe.settings", version: "1.0.0", bundlePath: bundle.url.path
    )
    defer { Task { await coordinator.shutdown() } }
    await #expect(throws: (any Error).self) {
        _ = try await coordinator.enable(
            bundleID: "site.lingxi.probe.settings", policy: .development,
            grantedPermissions: ["crashOnApply"]
        )
    }
    #expect(await router.offeredModels.isEmpty)
    #expect(await coordinator.runningBundleIDs().isEmpty)
}
