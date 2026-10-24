import Foundation
import LingXiFrontendProtocol
import LingXiPluginABI
import LingXiPluginRuntime
import LingXiSettingsProtocol
import Testing

private func settingsRows(_ frame: SettingsFrame) -> [String] {
    frame.rows.map { $0.spans.map(\.text).joined() }
}

private func seedSettingsProbe(_ directory: URL, grants: [String] = [], enabled: Bool = false) async throws -> TestBundle {
    let bundle = try makeBundle(
        bundleID: "site.lingxi.probe.settings", executableName: "LingXiSettingsProbe",
        dylib: builtProduct("libLingXiSettingsProbe.dylib"), capabilities: ["settings.view.v1"]
    )
    let registry = try PluginRegistry(configURL: directory.appendingPathComponent("plugins.json"))
    try await registry.upsert(.init(
        bundleID: "site.lingxi.probe.settings", version: "1.0.0", bundlePath: bundle.url.path,
        enabled: enabled, grants: grants
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
    _ = try await seedSettingsProbe(directory)
    let settingsDirectory = directory.appendingPathComponent("plugin-settings")
    try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    try Data(#"{"version":1,"config":{"name":"probe","enabled":true,"probeBadFrame":true}}"#.utf8)
        .write(to: settingsFile(directory))

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
    _ = try await seedSettingsProbe(directory)
    let settingsDirectory = directory.appendingPathComponent("plugin-settings")
    try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    try Data(#"{"version":1,"config":{"name":"probe","enabled":true,"probeCrashOnOpen":true}}"#.utf8)
        .write(to: settingsFile(directory))
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


private func settingsFile(
    _ directory: URL, bundleID: String = "site.lingxi.probe.settings"
) -> URL {
    directory.appendingPathComponent("plugin-settings/\(bundleID).json")
}

@Test("a plugin rejection on prepareSave is reported and leaves no settings file")
func settingsPrepareSaveRejection() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-reject-save-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory, enabled: true)
    let settingsDirectory = directory.appendingPathComponent("plugin-settings")
    try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    try Data(#"{"version":1,"config":{"name":"probe","enabled":true,"probeRejectSave":true}}"#.utf8)
        .write(to: settingsFile(directory))
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let snapshot = try #require(open.settings)
    _ = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "X")
    )))
    let save = try #require(await core.waitReply(
        core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
    ))
    #expect(!save.ok)
    #expect(save.error?.contains("rejected") == true)
    // The existing committed file must be byte-identical: a rejected candidate is never written.
    let unchanged = try Data(contentsOf: settingsFile(directory))
    #expect(String(decoding: unchanged, as: UTF8.self).contains("\"probeRejectSave\":true"))
}

@Test("a plugin semantic rejection on apply rolls back the settings file")
func settingsApplyRejection() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-reject-apply-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory, grants: ["rejectApply"], enabled: true)
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let snapshot = try #require(open.settings)
    _ = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "X")
    )))
    let save = try #require(await core.waitReply(
        core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
    ))
    #expect(!save.ok)
    #expect(save.error?.contains("rejected") == true)
    #expect(!FileManager.default.fileExists(atPath: settingsFile(directory).path))
    let alive = try #require(await core.waitReply(core.send(.modelsList)))
    #expect(alive.ok)
}

@Test("concurrent saves for one plugin are refused instead of overwriting a newer snapshot")
func settingsConcurrentSave() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-concurrent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory, grants: ["slowSave"], enabled: false)
    let settingsDirectory = directory.appendingPathComponent("plugin-settings")
    try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    try Data(#"{"version":1,"config":{"name":"probe","enabled":true,"probeSlowSave":true}}"#.utf8)
        .write(to: settingsFile(directory))
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let snapshot = try #require(open.settings)
    _ = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "X")
    )))
    let first = core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
    let second = core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
    let firstReply = try #require(await core.waitReply(first, timeout: .seconds(30)))
    let secondReply = try #require(await core.waitReply(second, timeout: .seconds(30)))
    #expect(firstReply.ok || secondReply.ok)
    #expect(!(firstReply.ok && secondReply.ok))
    let failed = firstReply.ok ? secondReply : firstReply
    #expect(failed.error?.contains("another settings operation") == true)
    let data = try Data(contentsOf: settingsFile(directory))
    #expect(String(decoding: data, as: UTF8.self).contains("probeX"))
}

@Test("a settings disk write failure is reported without touching the runtime")
func settingsDiskFailure() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-disk-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory, enabled: true)
    let blocked = directory.appendingPathComponent("plugin-settings")
    try Data("not a directory".utf8).write(to: blocked)
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let snapshot = try #require(open.settings)
    let save = try #require(await core.waitReply(
        core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
    ))
    #expect(!save.ok)
    #expect(save.error?.contains("could not be saved") == true)
    let alive = try #require(await core.waitReply(core.send(.modelsList)))
    #expect(alive.ok)
}

@Test("opening the same plugin again invalidates the old settings session")
func settingsSessionReplaced() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-replace-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory)
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let firstReply = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let first = try #require(firstReply.settings)
    let secondReply = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let second = try #require(secondReply.settings)
    #expect(first.sessionID != second.sessionID)
    let stale = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: first.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "X")
    )))
    #expect(!stale.ok)
    #expect(stale.error?.contains("no longer open") == true)
    let staleSave = try #require(await core.waitReply(
        core.send(.pluginSettingsSave, settingsSessionID: first.sessionID)
    ))
    #expect(!staleSave.ok)
}

@Test("one hundred open/cancel cycles do not leave addressable settings sessions")
func settingsSessionChurn() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-churn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory)
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    for _ in 0..<100 {
        let reply = try #require(await core.waitReply(core.send(
            .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
            viewport: SettingsViewport(width: 40, height: 12)
        )))
        let snapshot = try #require(reply.settings)
        _ = try #require(await core.waitReply(
            core.send(.pluginSettingsCancel, settingsSessionID: snapshot.sessionID)
        ))
    }
    let alive = try #require(await core.waitReply(core.send(.modelsList)))
    #expect(alive.ok)
}

@Test("a malicious settings page cannot name another provider's credential")
func settingsCredentialCrossPluginDenied() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-cross-\\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory, grants: ["evilCommand"])
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let snapshot = try #require(open.settings)
    let denied = try #require(await core.waitReply(core.send(
        .pluginSettingsCredential, provider: "mimo",
        settingsSessionID: snapshot.sessionID,
        settingsCredentialAction: "remove", settingsCredentialConfirmed: true
    )))
    #expect(!denied.ok)
    #expect(denied.error?.contains("does not declare") == true)
    // The same session cannot smuggle a different provider through the generic auth path either.
    let forged = try #require(await core.waitReply(core.send(
        .authRemove, provider: "mimo", settingsSessionID: snapshot.sessionID
    )))
    #expect(!forged.ok)
}

@Test("a Settings-Only Host receives no provider grants from the registry")
func settingsOnlyHostDropsRunGrants() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-grants-\\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // badframe would be active if the settings host received registry grants; it must not.
    _ = try await seedSettingsProbe(directory, grants: ["badframe"], enabled: true)
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    #expect(open.ok, "\(open.error ?? "")")
    #expect(open.settings != nil)
}

private let settingsKeychainGate = ProcessInfo.processInfo.environment["LINGXI_RUN_KEYCHAIN_TESTS"] == "1"

private func seedMiMoForSettings(_ directory: URL, enabled: Bool = false) async throws {
    let bundle = try makeBundle(
        bundleID: "site.lingxi.provider.mimo", executableName: "MiMoProvider",
        dylib: builtProduct("libMiMoProvider.dylib"),
        capabilities: ["provider.mimo", "settings.view.v1"]
    )
    let registry = try PluginRegistry(configURL: directory.appendingPathComponent("plugins.json"))
    try await registry.upsert(.init(
        bundleID: "site.lingxi.provider.mimo", version: "1.0.0",
        bundlePath: bundle.url.path, enabled: enabled
    ))
}

@Test(
    "a disabled plugin can manage its own Keychain credential, but another plugin cannot",
    .enabled(if: settingsKeychainGate)
)
func settingsDisabledCredentialIsolation() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-credential-\\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedMiMoForSettings(directory)
    _ = try await seedSettingsProbe(directory, grants: ["evilCommand"])
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))

    // First key for a disabled plugin: no route exists, but the settings session owns the binding.
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.provider.mimo",
        viewport: SettingsViewport(width: 64, height: 24)
    )))
    let mimoSession = try #require(open.settings).sessionID
    let before = try #require(await core.waitReply(core.send(
        .pluginSettingsCredential, provider: "mimo",
        settingsSessionID: mimoSession, settingsCredentialAction: "update"
    )))
    #expect(before.ok)
    #expect(before.credentials?.first?.configured == false)
    let set = try #require(await core.waitReply(core.send(
        .authSet, provider: "mimo", secret: "settings-sentinel-\(UUID().uuidString)",
        settingsSessionID: mimoSession
    )))
    #expect(set.ok, "\(set.error ?? "")")
    let configured = try #require(await core.waitReply(core.send(
        .pluginSettingsCredential, provider: "mimo",
        settingsSessionID: mimoSession, settingsCredentialAction: "update"
    )))
    #expect(configured.credentials?.first?.configured == true)
    _ = try #require(await core.waitReply(
        core.send(.pluginSettingsCancel, settingsSessionID: mimoSession)
    ))

    // A different plugin's settings page must not remove MiMo's credential.
    let probeOpen = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let probeSession = try #require(probeOpen.settings).sessionID
    let denied = try #require(await core.waitReply(core.send(
        .pluginSettingsCredential, provider: "mimo",
        settingsSessionID: probeSession,
        settingsCredentialAction: "remove", settingsCredentialConfirmed: true
    )))
    #expect(!denied.ok)
    _ = try #require(await core.waitReply(
        core.send(.pluginSettingsCancel, settingsSessionID: probeSession)
    ))

    // The original key is still present and can be removed only by MiMo's own confirmed session.
    let mimoAgain = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.provider.mimo",
        viewport: SettingsViewport(width: 64, height: 24)
    )))
    let mimoSession2 = try #require(mimoAgain.settings).sessionID
    let stillConfigured = try #require(await core.waitReply(core.send(
        .pluginSettingsCredential, provider: "mimo",
        settingsSessionID: mimoSession2, settingsCredentialAction: "update"
    )))
    #expect(stillConfigured.credentials?.first?.configured == true)
    let noConfirm = try #require(await core.waitReply(core.send(
        .pluginSettingsCredential, provider: "mimo",
        settingsSessionID: mimoSession2,
        settingsCredentialAction: "remove", settingsCredentialConfirmed: false
    )))
    #expect(!noConfirm.ok)
    let removed = try #require(await core.waitReply(core.send(
        .pluginSettingsCredential, provider: "mimo",
        settingsSessionID: mimoSession2,
        settingsCredentialAction: "remove", settingsCredentialConfirmed: true
    )))
    #expect(removed.ok)
    #expect(removed.credentials?.first?.configured == false)
}

@Test("cancelling while a save is preparing wins before any file write")
func settingsCancelDuringSave() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-cancel-save-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory, grants: ["slowSave"], enabled: false)
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let snapshot = try #require(open.settings)
    _ = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "X")
    )))
    let saveID = core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
    _ = try #require(await core.waitReply(
        core.send(.pluginSettingsCancel, settingsSessionID: snapshot.sessionID)
    ))
    let save = try #require(await core.waitReply(saveID, timeout: .seconds(30)))
    #expect(!save.ok)
    #expect(save.error?.contains("cancelled") == true)
    #expect(!FileManager.default.fileExists(atPath: settingsFile(directory).path))
    // The session is gone and its settings-only Host has exited; a cancelled save must not leave
    // an addressable window or a sleeping process behind.
    let replay = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "Z")
    )))
    #expect(!replay.ok)
    #expect(await waitUntil { core.childProcessCount() == 0 },
            "children=\(core.childProcesses()) stderr=\(core.stderrText.suffix(200))")
}

@Test("a corrupt settings file is an explicit error, never treated as no settings")
func settingsCorruptConfigIsExplicit() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-corrupt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory)
    let settingsDirectory = directory.appendingPathComponent("plugin-settings")
    try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    try Data("{ this is not json".utf8).write(to: settingsFile(directory))
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    #expect(!open.ok)
    #expect(open.error?.contains("unreadable") == true)
    // The corrupt file is preserved for inspection; it is never silently deleted.
    #expect(FileManager.default.fileExists(atPath: settingsFile(directory).path))
}

@Test("a running plugin crash during apply is surfaced and the settings file is removed")
func settingsApplyCrashRollsBack() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-crash-apply-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory, grants: ["crashOnApply"], enabled: true)
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let snapshot = try #require(open.settings)
    _ = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "X")
    )))
    let save = try #require(await core.waitReply(
        core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
    ))
    #expect(!save.ok)
    #expect(save.error?.isEmpty == false, "error=\(save.error ?? "nil")")
    #expect(!FileManager.default.fileExists(atPath: settingsFile(directory).path))
    let alive = try #require(await core.waitReply(core.send(.modelsList)))
    #expect(alive.ok)
}

@Test("a settings IPC timeout closes the session and leaves the Core responsive")
func settingsIPCTimeout() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-timeout-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory)
    let settingsDirectory = directory.appendingPathComponent("plugin-settings")
    try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    try Data(#"{"version":1,"config":{"name":"probe","enabled":true,"probeSlowOpen":true}}"#.utf8)
        .write(to: settingsFile(directory))
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(
        core.send(
            .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
            viewport: SettingsViewport(width: 40, height: 12)
        ),
        timeout: .seconds(60)
    ))
    #expect(!open.ok)
    #expect(open.error?.contains("timeout") == true || open.error?.contains("noReply") == true)
    let alive = try #require(await core.waitReply(core.send(.modelsList)))
    #expect(alive.ok)
}

private func writeProbeConfig(_ directory: URL, _ object: String, enabled: Bool = false) throws {
    let settingsDirectory = directory.appendingPathComponent("plugin-settings")
    try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    try Data("{\"version\":1,\"config\":\(object)}".utf8).write(to: settingsFile(directory))
}

@Test("cancelling during apply restores the old file and closes the settings host")
func settingsCancelDuringApply() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-cancel-apply-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory, enabled: true)
    try writeProbeConfig(directory, #"{"name":"old","enabled":true,"probeSlowApply":true}"#)
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let baseline = core.childProcessCount()
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let snapshot = try #require(open.settings)
    #expect(await waitUntil { core.childProcessCount() >= baseline + 1 })
    _ = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "X")
    )))
    let saveID = core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
    try await Task.sleep(for: .milliseconds(250))
    _ = try #require(await core.waitReply(
        core.send(.pluginSettingsCancel, settingsSessionID: snapshot.sessionID)
    ))
    let save = try #require(await core.waitReply(saveID, timeout: .seconds(30)))
    #expect(!save.ok)
    #expect(save.error?.contains("cancelled") == true)
    let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile(directory))) as? [String: Any]
    #expect((stored?["config"] as? [String: Any])?["name"] as? String == "old")
    let hello = try #require(await core.waitReply(core.send(.hello)))
    #expect(hello.preferredModel == nil)
    #expect(await waitUntil { core.childProcessCount() == baseline })
    let replay = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "Z")
    )))
    #expect(!replay.ok)
}

@Test("cancelling during commit rolls back the file, preference and plugin commit")
func settingsCancelDuringCommit() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-cancel-commit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory)
    try writeProbeConfig(directory, #"{"name":"old","enabled":true,"probeSlowCommit":true,"probePreferredModel":"new-model"}"#)
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let snapshot = try #require(open.settings)
    _ = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "X")
    )))
    let saveID = core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
    try await Task.sleep(for: .milliseconds(300))
    _ = try #require(await core.waitReply(
        core.send(.pluginSettingsCancel, settingsSessionID: snapshot.sessionID)
    ))
    let save = try #require(await core.waitReply(saveID, timeout: .seconds(30)))
    #expect(!save.ok)
    #expect(save.error?.contains("cancelled") == true)
    let hello = try #require(await core.waitReply(core.send(.hello)))
    #expect(hello.preferredModel == nil)
    let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile(directory))) as? [String: Any]
    #expect((stored?["config"] as? [String: Any])?["name"] as? String == "old")
    #expect(await waitUntil { core.childProcessCount() == 0 })
}

@Test("a rejected commit keeps the window usable and never publishes the preference")
func settingsCommitRejection() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-reject-commit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory)
    try writeProbeConfig(directory, #"{"name":"old","enabled":true,"probeRejectCommit":true,"probePreferredModel":"new-model"}"#)
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let snapshot = try #require(open.settings)
    _ = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "X")
    )))
    let save = try #require(await core.waitReply(
        core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
    ))
    #expect(!save.ok)
    #expect(save.preferredModel == nil)
    let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile(directory))) as? [String: Any]
    #expect((stored?["config"] as? [String: Any])?["name"] as? String == "old")
    // A plugin rejection is retryable: the window and its host stay alive.
    let again = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "Y")
    )))
    #expect(again.ok)
    let hello = try #require(await core.waitReply(core.send(.hello)))
    #expect(hello.preferredModel == nil)
    _ = try #require(await core.waitReply(
        core.send(.pluginSettingsCancel, settingsSessionID: snapshot.sessionID)
    ))
    #expect(await waitUntil { core.childProcessCount() == 0 })
}

@Test("a successful save publishes the preferred model and survives a Core restart")
func settingsPreferredModelCommit() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-preferred-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory)
    try writeProbeConfig(directory, #"{"name":"old","enabled":true,"probePreferredModel":"preferred-model"}"#)
    let core = try ProtocolCore(dataDirectory: directory)
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let snapshot = try #require(open.settings)
    _ = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "X")
    )))
    let save = try #require(await core.waitReply(
        core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
    ))
    #expect(save.ok, "\(save.error ?? "")")
    #expect(save.preferredModel == "preferred-model")
    let hello = try #require(await core.waitReply(core.send(.hello)))
    #expect(hello.preferredModel == "preferred-model")
    core.terminate()
    let restarted = try ProtocolCore(dataDirectory: directory)
    defer { restarted.terminate() }
    let after = try #require(await restarted.waitReply(restarted.send(.hello)))
    #expect(after.preferredModel == "preferred-model")
}

private func writeSettingsFile(_ directory: URL, bundleID: String, config: String) {
    let settingsDirectory = directory.appendingPathComponent("plugin-settings")
    try? FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    try? Data("{\"version\":1,\"config\":\(config)}".utf8).write(to: settingsFile(directory, bundleID: bundleID))
}

@Test("Core startup applies a valid stored config before offering model routes")
func startupValidConfigRegistersRoutes() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("startup-valid-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedMiMoForSettings(directory, enabled: true)
    writeSettingsFile(directory, bundleID: "site.lingxi.provider.mimo",
                      config: #"{"protocolKind":"chatCompletions","model":"mimo-v2.6-flash","thinkingMode":"enabled"}"#)
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    let hello = try #require(await core.waitReply(core.send(.hello)))
    #expect(hello.models?.sorted() == ["mimo-v2.6-flash", "mimo-v2.6-pro"])
    #expect(core.stderrText.contains("settings") == false)
}

@Test("Core startup rejects a corrupt stored config and never offers its provider model")
func startupCorruptConfigRegistersNoRoutes() async throws {
    for body in [
        #"{"version":1,"config":{"protocolKind":"chatCompletions""#,
        #"{"version":99,"config":{"protocolKind":"chatCompletions"}}"#,
        #"{"version":1,"config":{"protocolKind":"bogus","model":"mimo-v2.6-flash"}}"#,
    ] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await seedMiMoForSettings(directory, enabled: true)
        let settingsDirectory = directory.appendingPathComponent("plugin-settings")
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: settingsFile(directory, bundleID: "site.lingxi.provider.mimo"))
        let core = try ProtocolCore(dataDirectory: directory)
        let hello = try #require(await core.waitReply(core.send(.hello)))
        #expect(hello.models?.isEmpty == true)
        // The corrupt file is preserved for diagnosis, not overwritten with defaults.
        #expect(FileManager.default.fileExists(
            atPath: settingsFile(directory, bundleID: "site.lingxi.provider.mimo").path
        ))
        core.terminate()
    }
}

@Test("a rollback apply failure is reported instead of claiming the file made the state consistent")
func settingsRollbackRuntimeFailure() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-rollback-runtime-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory, enabled: true)
    try writeProbeConfig(
        directory,
        #"{"name":"old","enabled":true,"probeRejectCommit":true,"probeRejectSecondApply":true,"probePreferredModel":"new-model"}"#
    )
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let baseline = core.childProcessCount()
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let snapshot = try #require(open.settings)
    _ = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "X")
    )))
    let save = try #require(await core.waitReply(
        core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
    ))
    #expect(!save.ok)
    #expect(save.error?.contains("rollback") == true, "error=\(save.error ?? "nil")")
    let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile(directory))) as? [String: Any]
    #expect((stored?["config"] as? [String: Any])?["name"] as? String == "old")
    let hello = try #require(await core.waitReply(core.send(.hello)))
    #expect(hello.preferredModel == nil)
    #expect(core.childProcessCount() >= baseline)
}

@Test("a settings host crash during commit rolls back and removes the dead session")
func settingsCommitCrash() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-crash-commit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory)
    try writeProbeConfig(
        directory,
        #"{"name":"old","enabled":true,"probeCrashOnCommit":true,"probePreferredModel":"new-model"}"#
    )
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let snapshot = try #require(open.settings)
    _ = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "X")
    )))
    let save = try #require(await core.waitReply(
        core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
    ))
    #expect(!save.ok)
    let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile(directory))) as? [String: Any]
    #expect((stored?["config"] as? [String: Any])?["name"] as? String == "old")
    let hello = try #require(await core.waitReply(core.send(.hello)))
    #expect(hello.preferredModel == nil)
    let replay = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "Z")
    )))
    #expect(!replay.ok)
    #expect(await waitUntil { core.childProcessCount() == 0 })
}

@Test("one hundred open/save/cancel cycles leave no session or settings host")
func settingsSaveCancelChurn() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-save-churn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory)
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    for index in 0..<100 {
        let open = try #require(await core.waitReply(core.send(
            .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
            viewport: SettingsViewport(width: 40, height: 12)
        )))
        let snapshot = try #require(open.settings)
        _ = try #require(await core.waitReply(core.send(
            .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
            settingsInput: SettingsInput(kind: .key, key: "char", char: "x")
        )))
        let save = try #require(await core.waitReply(
            core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
        ))
        #expect(save.ok, "cycle \(index): \(save.error ?? "")")
        let reopened = try #require(await core.waitReply(core.send(
            .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
            viewport: SettingsViewport(width: 40, height: 12)
        )))
        let second = try #require(reopened.settings)
        let cancel = try #require(await core.waitReply(
            core.send(.pluginSettingsCancel, settingsSessionID: second.sessionID)
        ))
        #expect(cancel.ok)
    }
    #expect(await waitUntil(timeout: .seconds(10)) { core.childProcessCount() == 0 })
    let hello = try #require(await core.waitReply(core.send(.hello)))
    #expect(hello.preferredModel == nil)
}

@Test("a commit IPC timeout is surfaced and restores the old file")
func settingsCommitTimeout() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-commit-timeout-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory)
    try writeProbeConfig(
        directory,
        #"{"name":"old","enabled":true,"probeCommitTimeout":true,"probePreferredModel":"new-model"}"#
    )
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let snapshot = try #require(open.settings)
    _ = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "X")
    )))
    let save = try #require(await core.waitReply(
        core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID),
        timeout: .seconds(30)
    ))
    #expect(!save.ok)
    #expect(save.error?.lowercased().contains("noreply") == true,
            "error=\(save.error ?? "nil")")
    let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile(directory))) as? [String: Any]
    #expect((stored?["config"] as? [String: Any])?["name"] as? String == "old")
    let hello = try #require(await core.waitReply(core.send(.hello)))
    #expect(hello.preferredModel == nil)
}

@Test("Core shutdown during a slow settings save does not leave its settings host behind")
func settingsShutdownDuringSave() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-shutdown-save-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await seedSettingsProbe(directory)
    try writeProbeConfig(directory, #"{"name":"probe","enabled":true,"probeSlowSave":true}"#)
    let core = try ProtocolCore(dataDirectory: directory)
    _ = try #require(await core.waitReply(core.send(.hello)))
    let open = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: "site.lingxi.probe.settings",
        viewport: SettingsViewport(width: 40, height: 12)
    )))
    let snapshot = try #require(open.settings)
    _ = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: snapshot.sessionID,
        settingsInput: SettingsInput(kind: .key, key: "char", char: "X")
    )))
    _ = core.send(.pluginSettingsSave, settingsSessionID: snapshot.sessionID)
    try await Task.sleep(for: .milliseconds(100))
    core.terminate()
    #expect(!core.isRunning)
    #expect(core.childProcessCount() == 0)
}
