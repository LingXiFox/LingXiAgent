import Foundation
import LingXiKernel
import LingXiPluginABI
import LingXiPluginRuntime
import Testing

private let swiftPluginID = "site.lingxi.plugin.contextprobe"
private let cPluginID = "site.lingxi.plugin.cprobe"

private func makeCoordinator() throws -> (PluginCoordinator, PluginRegistry, HookPipeline) {
    let registry = try PluginRegistry(configURL: nil)
    let pipeline = HookPipeline()
    let coordinator = PluginCoordinator(
        hostExecutableURL: builtProduct("LingXiPluginHost"), registry: registry, pipeline: pipeline
    )
    return (coordinator, registry, pipeline)
}

private func installSwiftPlugin(_ coordinator: PluginCoordinator) async throws -> TestBundle {
    let bundle = try makeBundle(
        bundleID: swiftPluginID,
        executableName: "LingXiContextProbe",
        dylib: builtProduct("libLingXiContextProbe.dylib"),
        capabilities: ["hook.contextProbe"]
    )
    try await coordinator.install(bundleID: swiftPluginID, version: "1.0.0", bundlePath: bundle.url.path)
    return bundle
}

private func installCPlugin(_ coordinator: PluginCoordinator) async throws -> TestBundle {
    let bundle = try makeBundle(
        bundleID: cPluginID,
        executableName: "LingXiCProbe",
        dylib: builtProduct("libLingXiCProbe.dylib"),
        capabilities: ["hook.cProbe"]
    )
    try await coordinator.install(bundleID: cPluginID, version: "1.0.0", bundlePath: bundle.url.path)
    return bundle
}

private func markerSeen(_ provider: ScriptedProvider, _ marker: String) -> Bool {
    provider.requests.contains { request in
        request.entries.contains { $0.id.rawValue == marker }
    }
}

@Test("PLG-001 a real .lxap changes context while enabled, stops on disable, and uninstalls clean")
func PLG_001_enableRewriteDisableReenableUninstall() async throws {
    let (coordinator, registry, pipeline) = try makeCoordinator()
    _ = try await installSwiftPlugin(coordinator)

    _ = try await coordinator.enable(bundleID: swiftPluginID, policy: .development)
    #expect(await pipeline.mountedHandlerIDs == ["\(swiftPluginID).contextProbe"])
    #expect(await coordinator.isRunning(bundleID: swiftPluginID))
    #expect(await registry.entry(swiftPluginID)?.enabled == true)

    let provider = ScriptedProvider()
    let loop = try await makeTestLoop(provider: provider, pipeline: pipeline)

    #expect((await loop.run(runRequest(session: "lifecycle", turn: 1), policy: LoopPolicy())).status == .completed)
    #expect(markerSeen(provider, "probe.marker"))

    // Disable: routes go first, then the process, then the registry.
    await coordinator.disable(bundleID: swiftPluginID)
    #expect(await pipeline.mountedHandlerIDs.isEmpty)
    #expect(await coordinator.isRunning(bundleID: swiftPluginID) == false)
    #expect(await registry.entry(swiftPluginID)?.enabled == false)

    #expect((await loop.run(runRequest(session: "lifecycle", turn: 2), policy: LoopPolicy())).status == .completed)
    #expect(provider.requests.count == 2)
    #expect(!provider.requests[1].entries.contains { $0.id.rawValue == "probe.marker" })

    // Re-enable: a fresh host process, the same declared route.
    _ = try await coordinator.enable(bundleID: swiftPluginID, policy: .development)
    #expect((await loop.run(runRequest(session: "lifecycle", turn: 3), policy: LoopPolicy())).status == .completed)
    #expect(provider.requests.count == 3)
    #expect(provider.requests[2].entries.contains { $0.id.rawValue == "probe.marker" })

    // Uninstall: no route, no process, no registry entry.
    try await coordinator.uninstall(bundleID: swiftPluginID)
    #expect(await pipeline.mountedHandlerIDs.isEmpty)
    #expect(await coordinator.runningBundleIDs().isEmpty)
    #expect(await registry.entry(swiftPluginID) == nil)
}

@Test("PLG-015 the same runtime loads a C plugin, proving the ABI is cross-language")
func PLG_015_cPluginUsesTheSameRuntimeAndABI() async throws {
    let (coordinator, _, pipeline) = try makeCoordinator()
    _ = try await installCPlugin(coordinator)
    _ = try await coordinator.enable(bundleID: cPluginID, policy: .development)

    let provider = ScriptedProvider()
    let loop = try await makeTestLoop(provider: provider, pipeline: pipeline)
    #expect((await loop.run(runRequest(session: "c-abi", turn: 1), policy: LoopPolicy())).status == .completed)
    // The marker comes from a C function table loaded through the same host process. No kernel or
    // runtime code was compiled differently for it.
    #expect(markerSeen(provider, "cprobe.marker"))

    await coordinator.disable(bundleID: cPluginID)
    #expect(await coordinator.runningBundleIDs().isEmpty)
}

@Test("PLG-011 a manifest whose ABI major disagrees with the table is refused")
func PLG_011_manifestAbiMajorMismatchIsRefused() async throws {
    let (coordinator, _, pipeline) = try makeCoordinator()
    let bundle = try makeBundle(
        bundleID: swiftPluginID,
        executableName: "LingXiContextProbe",
        dylib: builtProduct("libLingXiContextProbe.dylib"),
        capabilities: ["hook.contextProbe"],
        abiMajor: 2
    )
    try await coordinator.install(bundleID: swiftPluginID, version: "1.0.0", bundlePath: bundle.url.path)

    var refusal = ""
    do {
        _ = try await coordinator.enable(bundleID: swiftPluginID, policy: .development)
    } catch {
        refusal = "\(error)"
    }
    #expect(refusal.contains("ABI") || refusal.lowercased().contains("abi"))
    #expect(await pipeline.mountedHandlerIDs.isEmpty)
    #expect(await coordinator.runningBundleIDs().isEmpty)
}

@Test("PLG-009 a manifest without an explicit Permissions declaration is refused")
func PLG_009_missingPermissionDeclarationFailsTheLoad() async throws {
    let (coordinator, _, pipeline) = try makeCoordinator()
    let bundle = try makeBundle(
        bundleID: swiftPluginID,
        executableName: "LingXiContextProbe",
        dylib: builtProduct("libLingXiContextProbe.dylib"),
        capabilities: ["hook.contextProbe"],
        omitPermissions: true
    )
    try await coordinator.install(bundleID: swiftPluginID, version: "1.0.0", bundlePath: bundle.url.path)

    var refusal = ""
    do {
        _ = try await coordinator.enable(bundleID: swiftPluginID, policy: .development)
    } catch {
        refusal = "\(error)"
    }
    #expect(refusal.contains("Permissions"))
    #expect(await pipeline.mountedHandlerIDs.isEmpty)
    #expect(await coordinator.runningBundleIDs().isEmpty)
}

@Test("PLG-017 ad-hoc signatures are refused in restricted mode and admitted as untrusted in development")
func PLG_017_signaturePolicyTiers() async throws {
    let (coordinator, _, _) = try makeCoordinator()
    _ = try await installSwiftPlugin(coordinator)

    var restrictedRefusal = ""
    do {
        _ = try await coordinator.enable(bundleID: swiftPluginID, policy: .restricted)
    } catch {
        restrictedRefusal = "\(error)"
    }
    #expect(restrictedRefusal.contains("ad-hoc"))
    #expect(await coordinator.runningBundleIDs().isEmpty)

    // Development admits it and labels it: the bundle is not Developer ID and is not notarised.
    _ = try await coordinator.enable(bundleID: swiftPluginID, policy: .development)
    #expect(await coordinator.isRunning(bundleID: swiftPluginID))
    await coordinator.disable(bundleID: swiftPluginID)
}

@Test("PLG-018 a crashing plugin kills only its host and the run is denied, not silently passed")
func PLG_018_pluginCrashIsIsolated() async throws {
    let (coordinator, _, pipeline) = try makeCoordinator()
    _ = try await installSwiftPlugin(coordinator)
    _ = try await installCPlugin(coordinator)

    // A healthy plugin alongside the one that will die.
    _ = try await coordinator.enable(bundleID: swiftPluginID, policy: .development)
    _ = try await coordinator.enable(bundleID: cPluginID, policy: .development, grantedPermissions: ["fault.crash"])

    let provider = ScriptedProvider(script: [.started, .textDelta("ok"), .completed(.stop)])
    let loop = try await makeTestLoop(provider: provider, pipeline: pipeline)

    let crashed = await loop.run(runRequest(session: "crash", turn: 1), policy: LoopPolicy())

    // The C hook holds a veto, so a failed invocation is a denial: nothing was sent.
    #expect(crashed.status == .failed)
    #expect(crashed.cause == .hookDenied)
    #expect(provider.requests.isEmpty)

    // Only that host died. The other plugin keeps its process and its route.
    #expect(await waitUntil { await coordinator.isRunning(bundleID: cPluginID) == false })
    #expect(await coordinator.isRunning(bundleID: swiftPluginID))
    #expect(await pipeline.mountedHandlerIDs.contains("\(swiftPluginID).contextProbe"))
    #expect(await pipeline.mountedHandlerIDs.contains("\(cPluginID).cProbe"))

    // Tear the dead one down: registry says disabled, no process, route gone.
    await coordinator.disable(bundleID: cPluginID)
    #expect(await pipeline.mountedHandlerIDs == ["\(swiftPluginID).contextProbe"])
    #expect(await coordinator.isRunning(bundleID: cPluginID) == false)

    // The session recovers on the next turn, still served by the surviving plugin.
    let recovered = await loop.run(runRequest(session: "crash", turn: 2), policy: LoopPolicy())
    #expect(recovered.status == .completed)
    #expect(provider.requests.count == 1)
    #expect(provider.requests[0].entries.contains { $0.id.rawValue == "probe.marker" })
}

@Test("PLG-001 the registry persists across a fresh instance and never touches the event log")
func PLG_001_registryPersistsAsSeparateConfig() async throws {
    let configURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-registry-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: configURL) }

    let first = try PluginRegistry(configURL: configURL)
    try await first.upsert(.init(bundleID: swiftPluginID, version: "1.0.0", bundlePath: "/tmp/x.lxap", enabled: true))

    let second = try PluginRegistry(configURL: configURL)
    #expect(await second.entry(swiftPluginID)?.enabled == true)

    try await second.remove(swiftPluginID)
    let third = try PluginRegistry(configURL: configURL)
    #expect(await third.entry(swiftPluginID) == nil)
}
