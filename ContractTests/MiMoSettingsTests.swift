import Foundation
import LingXiFrontendProtocol
import LingXiPluginABI
import LingXiPluginRuntime
import LingXiSettingsProtocol
import Testing

private func seedMiMoForSettings(_ directory: URL) async throws {
    let bundle = try makeBundle(
        bundleID: "site.lingxi.provider.mimo", executableName: "MiMoProvider",
        dylib: builtProduct("libMiMoProvider.dylib"),
        capabilities: ["provider.mimo", "settings.view.v1"]
    )
    let registry = try PluginRegistry(configURL: directory.appendingPathComponent("plugins.json"))
    try await registry.upsert(.init(
        bundleID: "site.lingxi.provider.mimo", version: "1.0.0",
        bundlePath: bundle.url.path, enabled: false
    ))
}

private func rowsText(_ frame: SettingsFrame) -> String {
    frame.rows.map { $0.spans.map(\.text).joined() }.joined(separator: "\n")
}

@Test("MiMo draws its own settings page and commits protocol plus thinking choices")
func mimoSettingsPage() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimo-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedMiMoForSettings(directory)

    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))

    let viewport = SettingsViewport(width: 64, height: 24)
    let open = try #require(await core.waitReply(
        core.send(.pluginSettingsOpen, bundleID: "site.lingxi.provider.mimo", viewport: viewport)
    ))
    #expect(open.ok, "\(open.error ?? "")")
    let snapshot = try #require(open.settings)
    #expect(snapshot.title == "MiMo Provider")

    // Right twice reaches Protocol, select Responses, then save.
    var session = snapshot.sessionID
    for key in ["right", "down", "enter", "right", "down", "enter", "right", "down", "enter"] {
        let reply = try #require(await core.waitReply(core.send(
            .pluginSettingsInput, settingsSessionID: session,
            settingsInput: SettingsInput(kind: .key, key: key)
        )))
        #expect(reply.ok)
        session = try #require(reply.settings).sessionID
    }
    let saved = try #require(await core.waitReply(
        core.send(.pluginSettingsSave, settingsSessionID: session)
    ))
    #expect(saved.ok, "\(saved.error ?? "")")

    let stored = directory.appendingPathComponent("plugin-settings/site.lingxi.provider.mimo.json")
    let data = try Data(contentsOf: stored)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let config = try #require(root["config"] as? [String: Any])
    #expect(config["protocolKind"] as? String == "responses")
    #expect(config["model"] as? String == "mimo-v2.6-pro")
    #expect(config["thinkingMode"] as? String == "enabled")
    // The preferred model is a hint for the TUI's next selection, never a router override.
    core.terminate()
    let restarted = try ProtocolCore(dataDirectory: directory)
    defer { restarted.terminate() }
    let hello = try #require(await restarted.waitReply(restarted.send(.hello)))
    #expect(hello.preferredModel == "mimo-v2.6-pro")
}
