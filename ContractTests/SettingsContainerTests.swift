import Foundation
import LingXiFrontendProtocol
import LingXiPluginABI
import LingXiPluginRuntime
import LingXiSettingsProtocol
import Testing

private func settingsRows(_ frame: SettingsFrame) -> [String] {
    frame.rows.map { $0.spans.map(\.text).joined() }
}

private func seedSettingsProbe(_ directory: URL, grants: [String] = []) async throws -> TestBundle {
    let bundle = try makeBundle(
        bundleID: "site.lingxi.probe.settings", executableName: "LingXiSettingsProbe",
        dylib: builtProduct("libLingXiSettingsProbe.dylib"), capabilities: ["settings.view.v1"]
    )
    let registry = try PluginRegistry(configURL: directory.appendingPathComponent("plugins.json"))
    try await registry.upsert(.init(
        bundleID: "site.lingxi.probe.settings", version: "1.0.0", bundlePath: bundle.url.path,
        enabled: false, grants: grants
    ))
    return bundle
}

@Test("plugin settings open, edit, save and cancel against a real Plugin Host")
func pluginSettingsTransaction() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory)

    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    let hello = try #require(await core.waitReply(core.send(.hello)))
    #expect(hello.models?.isEmpty == true, "a disabled settings-only plugin must not register routes")

    let viewport = SettingsViewport(width: 40, height: 12)
    let open = try #require(await core.waitReply(
        core.send(.pluginSettingsOpen, bundleID: "site.lingxi.probe.settings", viewport: viewport)
    ))
    #expect(open.ok, "\(open.error ?? "")")
    let snapshot = try #require(open.settings)
    #expect(snapshot.title == "Settings Probe")
    #expect(settingsRows(snapshot.frame).contains { $0.contains("Settings Probe") })

    let input = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "X")
    )))
    #expect(input.ok, "\(input.error ?? "")")
    #expect(settingsRows(try #require(input.settings).frame).contains { $0.contains("probeX") })

    let save = try #require(await core.waitReply(
        core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
    ))
    #expect(save.ok, "\(save.error ?? "")")
    let stored = directory.appendingPathComponent("plugin-settings/site.lingxi.probe.settings.json")
    let data = try Data(contentsOf: stored)
    let saved = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let config = try #require(saved["config"] as? [String: Any])
    #expect(config["name"] as? String == "probeX")

    // Reopening sees the committed value. Cancel discards a later edit and leaves the file alone.
    let second = try #require(await core.waitReply(
        core.send(.pluginSettingsOpen, bundleID: "site.lingxi.probe.settings", viewport: viewport)
    ))
    let secondSnapshot = try #require(second.settings)
    #expect(settingsRows(secondSnapshot.frame).contains { $0.contains("probeX") })
    _ = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: secondSnapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "Y")
    )))
    let cancel = try #require(await core.waitReply(
        core.send(.pluginSettingsCancel, settingsSessionID: secondSnapshot.sessionID)
    ))
    #expect(cancel.ok)
    let unchanged = try Data(contentsOf: stored)
    #expect(!String(decoding: unchanged, as: UTF8.self).contains("probeXY"))
}

@Test("an invalid frame is rejected without taking the Core down")
func settingsFrameRejection() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-bad-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory, grants: ["badframe"])

    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    #expect(!open.ok)
    #expect(open.error?.contains("invalid frame") == true)
    let stillAlive = try #require(await core.waitReply(core.send(.modelsList)))
    #expect(stillAlive.ok)
}

@Test("an unsupported settings version is refused, not migrated by guess")
func settingsStoreRejectsUnknownVersion() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-version-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsDirectory = directory.appendingPathComponent("plugin-settings")
    try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    let file = settingsDirectory.appendingPathComponent("site.lingxi.probe.settings.json")
    try Data(#"{"version":99,"config":{}}"#.utf8).write(to: file)
    _ = try await seedSettingsProbe(directory)

    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    #expect(!open.ok)
    #expect(open.error?.contains("unsupported settings version") == true)
}

@Test("a settings-only plugin can be enabled and disabled without a provider route")
func settingsOnlyPluginToggle() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-toggle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory)
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let enable = try #require(await core.waitReply(
        core.send(.pluginEnable, bundleID: "site.lingxi.probe.settings")
    ))
    #expect(enable.ok, "\(enable.error ?? "")")
    let disable = try #require(await core.waitReply(
        core.send(.pluginDisable, bundleID: "site.lingxi.probe.settings")
    ))
    #expect(disable.ok, "\(disable.error ?? "")")
}

@Test("a settings host crash closes the session without taking the Core down")
func settingsHostCrashIsolation() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-crash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory, grants: ["crash"])
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    #expect(!open.ok)
    let alive = try #require(await core.waitReply(core.send(.modelsList)))
    #expect(alive.ok)
}
