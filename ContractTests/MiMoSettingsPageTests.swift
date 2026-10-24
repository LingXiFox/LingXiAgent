import Foundation
import LingXiFrontendProtocol
import LingXiPluginABI
import LingXiPluginRuntime
import LingXiSettingsProtocol
import Testing

/// Acceptance for the plugin-owned settings pages: the structure the plugin draws, the dirty flag it
/// reports, and mouse hit-testing with coordinates relative to its own frame. Everything here drives
/// the real Core over the frontend protocol; no frame is hand-built by the test.

private let mimoSettingsBundleID = "site.lingxi.provider.mimo"
private let probeBundleID = "site.lingxi.probe.settings"

private func seedMiMoPage(_ directory: URL) async throws {
    let bundle = try makeBundle(
        bundleID: mimoSettingsBundleID, executableName: "MiMoProvider",
        dylib: builtProduct("libMiMoProvider.dylib"),
        capabilities: ["provider.mimo", "settings.view.v1"]
    )
    let registry = try PluginRegistry(configURL: directory.appendingPathComponent("plugins.json"))
    try await registry.upsert(.init(
        bundleID: mimoSettingsBundleID, version: "1.0.0", bundlePath: bundle.url.path, enabled: false
    ))
}

private func seedProbePage(_ directory: URL) async throws {
    let bundle = try makeBundle(
        bundleID: probeBundleID, executableName: "LingXiSettingsProbe",
        dylib: builtProduct("libLingXiSettingsProbe.dylib"), capabilities: ["settings.view.v1"]
    )
    let registry = try PluginRegistry(configURL: directory.appendingPathComponent("plugins.json"))
    try await registry.upsert(.init(
        bundleID: probeBundleID, version: "1.0.0", bundlePath: bundle.url.path, enabled: false
    ))
}

private func rowsText(_ frame: SettingsFrame) -> [String] {
    frame.rows.map { $0.spans.map(\.text).joined() }
}

private func rowIndex(_ frame: SettingsFrame, containing text: String) -> Int? {
    rowsText(frame).firstIndex { $0.contains(text) }
}

/// The column of the first cell of the span that carries `needle`, in display cells. Tabs are drawn
/// as one span per title, so this is exactly the cell a real click report would carry.
private func column(of needle: String, in frame: SettingsFrame, row: Int = 0) -> Int? {
    guard frame.rows.indices.contains(row) else { return nil }
    var column = 0
    for span in frame.rows[row].spans {
        if span.text.contains(needle) { return column }
        column += SettingsFrameValidator.displayWidth(span.text)
    }
    return nil
}

@discardableResult
private func openSettings(
    _ core: ProtocolCore, bundleID: String, width: Int = 80, height: Int = 24
) async throws -> SettingsSnapshot {
    let reply = try #require(await core.waitReply(core.send(
        .pluginSettingsOpen, bundleID: bundleID,
        viewport: SettingsViewport(width: width, height: height)
    )))
    #expect(reply.ok, "\(reply.error ?? "")")
    return try #require(reply.settings)
}

private func keyInput(
    _ core: ProtocolCore, session: String, _ key: String
) async throws -> SettingsSnapshot {
    let reply = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: session,
        settingsInput: SettingsInput(kind: .key, key: key)
    )))
    #expect(reply.ok, "\(reply.error ?? "")")
    return try #require(reply.settings)
}

private func charInput(
    _ core: ProtocolCore, session: String, _ char: String
) async throws -> SettingsSnapshot {
    let reply = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: session,
        settingsInput: SettingsInput(kind: .key, key: "char", char: char)
    )))
    #expect(reply.ok, "\(reply.error ?? "")")
    return try #require(reply.settings)
}

private func mouseClick(
    _ core: ProtocolCore, session: String, row: Int, column: Int
) async throws -> SettingsSnapshot {
    let reply = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: session,
        settingsInput: SettingsInput(kind: .mouse, row: row, column: column)
    )))
    #expect(reply.ok, "\(reply.error ?? "")")
    return try #require(reply.settings)
}

private func mouseWheel(
    _ core: ProtocolCore, session: String, delta: Int
) async throws -> SettingsSnapshot {
    let reply = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: session,
        settingsInput: SettingsInput(kind: .mouse, delta: delta)
    )))
    #expect(reply.ok, "\(reply.error ?? "")")
    return try #require(reply.settings)
}

/// A wheel report as the terminal actually sends it: the cell under the pointer plus the notch.
private func mouseWheelAt(
    _ core: ProtocolCore, session: String, row: Int, column: Int, delta: Int
) async throws -> SettingsSnapshot {
    let reply = try #require(await core.waitReply(core.send(
        .pluginSettingsInput, settingsSessionID: session,
        settingsInput: SettingsInput(kind: .mouse, row: row, column: column, delta: delta)
    )))
    #expect(reply.ok, "\(reply.error ?? "")")
    return try #require(reply.settings)
}

private func savedConfig(_ directory: URL, bundleID: String) throws -> [String: Any] {
    let file = directory.appendingPathComponent("plugin-settings/\(bundleID).json")
    let data = try Data(contentsOf: file)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(root["config"] as? [String: Any])
}

private func clickTab(
    _ core: ProtocolCore, session: String, title: String, in snapshot: SettingsSnapshot
) async throws -> SettingsSnapshot {
    let column = try #require(column(of: title, in: snapshot.frame))
    return try await mouseClick(core, session: session, row: 0, column: column)
}

// MARK: - MiMo page

@Test("MIMO-SET-001 the page opens on Connection with four tabs, a concise status line and a clean draft")
func mimoSettingsPageStructure() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimo-page-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedMiMoPage(directory)

    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))

    let snapshot = try await openSettings(core, bundleID: mimoSettingsBundleID)
    #expect(snapshot.title == "MiMo Provider")
    #expect(snapshot.dirty == false)
    let rows = rowsText(snapshot.frame)
    for tab in ["Connection", "Protocol", "Model", "Advanced"] {
        #expect(rows[0].contains(tab), "tab row: \(rows[0])")
    }
    // One status line carries the dirty marker and the effective summary.
    #expect(rows[1].contains("已保存"), "status row: \(rows[1])")
    #expect(rows[1].contains("Chat"))
    #expect(rows[1].contains("mimo-v2.6-flash"))
    #expect(rows[1].contains("思考:服务端默认"))
    // Connection selection 0 is still the credential update the PTY contract expects.
    let updateRow = try #require(rowIndex(snapshot.frame, containing: "更新凭据"))
    #expect(rows[updateRow].contains("▸"))
    // No decorative blank rows: every row carries content in the plugin's own layout.
    #expect(snapshot.frame.rows.allSatisfy { !$0.spans.map(\.text).joined().isEmpty })
    #expect(snapshot.frame.rows.count <= 10)
}

@Test("MIMO-SET-002 clicking a tab switches the page without touching the draft")
func mimoSettingsMouseTabs() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimo-tabs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedMiMoPage(directory)

    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    var snapshot = try await openSettings(core, bundleID: mimoSettingsBundleID)
    let session = snapshot.sessionID

    snapshot = try await clickTab(core, session: session, title: "Model", in: snapshot)
    #expect(rowsText(snapshot.frame).contains { $0.contains("mimo-v2.6-pro") })
    #expect(snapshot.dirty == false)

    snapshot = try await clickTab(core, session: session, title: "Protocol", in: snapshot)
    #expect(rowsText(snapshot.frame).contains { $0.contains("API Protocol") })
    #expect(snapshot.dirty == false)

    snapshot = try await clickTab(core, session: session, title: "Advanced", in: snapshot)
    #expect(rowsText(snapshot.frame).contains { $0.contains("Thinking") })
    #expect(snapshot.dirty == false)

    snapshot = try await clickTab(core, session: session, title: "Connection", in: snapshot)
    #expect(rowsText(snapshot.frame).contains { $0.contains("更新凭据") })
    #expect(snapshot.dirty == false)
}

@Test("MIMO-SET-003 clicking a thinking radio changes the frame, reports dirty, and reverting clears it")
func mimoSettingsMouseThinkingRadio() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimo-radio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedMiMoPage(directory)

    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    var snapshot = try await openSettings(core, bundleID: mimoSettingsBundleID)
    let session = snapshot.sessionID
    snapshot = try await clickTab(core, session: session, title: "Advanced", in: snapshot)

    let enabledRow = try #require(rowIndex(snapshot.frame, containing: "开启思考"))
    snapshot = try await mouseClick(core, session: session, row: enabledRow, column: 4)
    let enabledRowNow = try #require(rowIndex(snapshot.frame, containing: "开启思考"))
    #expect(rowsText(snapshot.frame)[enabledRowNow].contains("(•)"), "row: \(rowsText(snapshot.frame)[enabledRowNow])")
    #expect(snapshot.dirty == true)
    #expect(rowsText(snapshot.frame)[1].contains("● 未保存"), "status: \(rowsText(snapshot.frame)[1])")

    // Selecting the plugin's own saved mode again is not a dirty draft.
    let defaultRow = try #require(rowIndex(snapshot.frame, containing: "服务端默认"))
    snapshot = try await mouseClick(core, session: session, row: defaultRow, column: 4)
    #expect(snapshot.dirty == false)
    #expect(rowsText(snapshot.frame)[1].contains("已保存"))
}

@Test("MIMO-SET-004 Chat hides effort; Responses with thinking enabled reveals it after expanding")
func mimoSettingsProtocolAwareEffort() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimo-effort-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedMiMoPage(directory)

    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    var snapshot = try await openSettings(core, bundleID: mimoSettingsBundleID)
    let session = snapshot.sessionID

    // Chat Completions: thinking mode only, never an effort list.
    snapshot = try await clickTab(core, session: session, title: "Protocol", in: snapshot)
    let chatRow = try #require(rowIndex(snapshot.frame, containing: "Chat Completions"))
    snapshot = try await mouseClick(core, session: session, row: chatRow, column: 4)
    snapshot = try await clickTab(core, session: session, title: "Advanced", in: snapshot)
    #expect(!rowsText(snapshot.frame).contains { $0.contains("高级 effort") })
    #expect(!rowsText(snapshot.frame).contains { $0.contains("→ low") })

    // Responses with the saved "default" mode: effort stays hidden until thinking is enabled.
    snapshot = try await clickTab(core, session: session, title: "Protocol", in: snapshot)
    let responsesRow = try #require(rowIndex(snapshot.frame, containing: "Responses"))
    snapshot = try await mouseClick(core, session: session, row: responsesRow, column: 4)
    snapshot = try await clickTab(core, session: session, title: "Advanced", in: snapshot)
    #expect(!rowsText(snapshot.frame).contains { $0.contains("高级 effort") })

    let enabledRow = try #require(rowIndex(snapshot.frame, containing: "开启思考"))
    snapshot = try await mouseClick(core, session: session, row: enabledRow, column: 4)
    let expandRow = try #require(rowIndex(snapshot.frame, containing: "高级 effort"))
    // Collapsed by default: the row is there, the effort radios are not.
    #expect(!rowsText(snapshot.frame).contains { $0.contains("→ low") })

    snapshot = try await mouseClick(core, session: session, row: expandRow, column: 4)
    let expanded = rowsText(snapshot.frame)
    #expect(expanded.contains { $0.contains("→ low") })
    #expect(expanded.contains { $0.contains("→ high") })
    #expect(expanded.filter { $0.contains("服务端默认") }.count >= 2)
    #expect(snapshot.dirty == true)

    // Picking an effort updates the one-line summary.
    let mediumRow = try #require(rowIndex(snapshot.frame, containing: " medium "))
    snapshot = try await mouseClick(core, session: session, row: mediumRow, column: 4)
    #expect(rowsText(snapshot.frame)[1].contains("effort=medium"), "status: \(rowsText(snapshot.frame)[1])")
}

@Test("MIMO-SET-005 the wheel moves the selection without applying it")
func mimoSettingsMouseWheel() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimo-wheel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedMiMoPage(directory)

    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    var snapshot = try await openSettings(core, bundleID: mimoSettingsBundleID)
    let session = snapshot.sessionID

    snapshot = try await mouseWheel(core, session: session, delta: -1)
    var removeRow = try #require(rowIndex(snapshot.frame, containing: "删除凭据"))
    #expect(rowsText(snapshot.frame)[removeRow].contains("▸"))
    #expect(snapshot.dirty == false)

    snapshot = try await mouseWheel(core, session: session, delta: 1)
    let updateRow = try #require(rowIndex(snapshot.frame, containing: "更新凭据"))
    #expect(rowsText(snapshot.frame)[updateRow].contains("▸"))
    #expect(snapshot.dirty == false)

    // A real terminal wheel carries the cell under the pointer. A notch over the tab row must move
    // the selection, never switch the tab or apply the radio underneath it.
    snapshot = try await mouseWheelAt(core, session: session, row: 0, column: 3, delta: -1)
    removeRow = try #require(rowIndex(snapshot.frame, containing: "删除凭据"))
    #expect(rowsText(snapshot.frame)[removeRow].contains("▸"))
    #expect(rowsText(snapshot.frame).contains { $0.contains("API Protocol") } == false)
    #expect(snapshot.command == nil)
    #expect(snapshot.dirty == false)
}

@Test("MIMO-SET-006 saving the redesigned page persists it and a reopened page is clean")
func mimoSettingsSaveAndReopen() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimo-save-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedMiMoPage(directory)

    do {
        let core = try ProtocolCore(dataDirectory: directory)
        defer { core.terminate() }
        _ = try #require(await core.waitReply(core.send(.hello)))
        var snapshot = try await openSettings(core, bundleID: mimoSettingsBundleID)
        let session = snapshot.sessionID

        snapshot = try await clickTab(core, session: session, title: "Model", in: snapshot)
        let proRow = try #require(rowIndex(snapshot.frame, containing: "mimo-v2.6-pro"))
        snapshot = try await mouseClick(core, session: session, row: proRow, column: 4)

        snapshot = try await clickTab(core, session: session, title: "Protocol", in: snapshot)
        let responsesRow = try #require(rowIndex(snapshot.frame, containing: "Responses"))
        snapshot = try await mouseClick(core, session: session, row: responsesRow, column: 4)

        snapshot = try await clickTab(core, session: session, title: "Advanced", in: snapshot)
        let enabledRow = try #require(rowIndex(snapshot.frame, containing: "开启思考"))
        snapshot = try await mouseClick(core, session: session, row: enabledRow, column: 4)
        #expect(snapshot.dirty == true)

        let save = try #require(await core.waitReply(
            core.send(.pluginSettingsSave, settingsSessionID: session)
        ))
        #expect(save.ok, "\(save.error ?? "")")
        #expect(save.preferredModel == "mimo-v2.6-pro")

        let config = try savedConfig(directory, bundleID: mimoSettingsBundleID)
        #expect(config["protocolKind"] as? String == "responses")
        #expect(config["model"] as? String == "mimo-v2.6-pro")
        #expect(config["thinkingMode"] as? String == "enabled")
    }

    let restarted = try ProtocolCore(dataDirectory: directory)
    defer { restarted.terminate() }
    _ = try #require(await restarted.waitReply(restarted.send(.hello)))
    let reopened = try await openSettings(restarted, bundleID: mimoSettingsBundleID)
    #expect(reopened.dirty == false)
    let status = rowsText(reopened.frame)[1]
    #expect(status.contains("Responses"))
    #expect(status.contains("mimo-v2.6-pro"))
    #expect(status.contains("思考:开启"))
}

@Test("MIMO-SET-007 Connection selection 0 asks the host to update the credential, selection 1 to remove it")
func mimoSettingsCredentialCommands() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimo-cred-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedMiMoPage(directory)

    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    var snapshot = try await openSettings(core, bundleID: mimoSettingsBundleID)
    let session = snapshot.sessionID
    #expect(snapshot.command == nil)

    snapshot = try await keyInput(core, session: session, "enter")
    #expect(snapshot.command?.type == "credential.update")
    #expect(snapshot.command?.providerID == "mimo")
    #expect(snapshot.dirty == false)

    snapshot = try await keyInput(core, session: session, "down")
    snapshot = try await keyInput(core, session: session, "enter")
    #expect(snapshot.command?.type == "credential.remove")
    #expect(snapshot.command?.providerID == "mimo")
}

// MARK: - probe page

@Test("PROBE-SET-001 probe rows are clickable and dirty tracks exactly what a save would persist")
func probeSettingsMouseAndDirty() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("probe-page-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedProbePage(directory)

    do {
        let core = try ProtocolCore(dataDirectory: directory)
        defer { core.terminate() }
        _ = try #require(await core.waitReply(core.send(.hello)))
        var snapshot = try await openSettings(core, bundleID: probeBundleID, width: 40, height: 12)
        #expect(snapshot.dirty == false)
        #expect(rowsText(snapshot.frame).contains { $0.contains("Settings Probe") })
        #expect(rowsText(snapshot.frame).contains { $0.contains("已保存") })
        let session = snapshot.sessionID

        // The enabled toggle is a real click target.
        let enabledRow = try #require(rowIndex(snapshot.frame, containing: "启用示例选项"))
        snapshot = try await mouseClick(core, session: session, row: enabledRow, column: 2)
        #expect(rowsText(snapshot.frame).contains { $0.contains("[ ] 启用示例选项") })
        #expect(snapshot.dirty == true)
        #expect(rowsText(snapshot.frame).contains { $0.contains("● 未保存") })

        snapshot = try await mouseClick(core, session: session, row: enabledRow, column: 2)
        #expect(rowsText(snapshot.frame).contains { $0.contains("[x] 启用示例选项") })
        #expect(snapshot.dirty == false)

        // The name row is a click target too; typing keeps the existing probe semantics.
        let nameRow = try #require(rowIndex(snapshot.frame, containing: "名称"))
        snapshot = try await mouseClick(core, session: session, row: nameRow, column: 2)
        snapshot = try await charInput(core, session: session, "X")
        #expect(rowsText(snapshot.frame).contains { $0.contains("probeX") })
        #expect(snapshot.dirty == true)

        let save = try #require(await core.waitReply(
            core.send(.pluginSettingsSave, settingsSessionID: session)
        ))
        #expect(save.ok, "\(save.error ?? "")")
        let config = try savedConfig(directory, bundleID: probeBundleID)
        #expect(config["name"] as? String == "probeX")
    }

    // Reopening reads the committed file, and cancel discards a later edit without dirtying it.
    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }
    _ = try #require(await core.waitReply(core.send(.hello)))
    var snapshot = try await openSettings(core, bundleID: probeBundleID, width: 40, height: 12)
    #expect(snapshot.dirty == false)
    #expect(rowsText(snapshot.frame).contains { $0.contains("probeX") })
    let session = snapshot.sessionID
    snapshot = try await charInput(core, session: session, "Y")
    #expect(snapshot.dirty == true)
    _ = try #require(await core.waitReply(core.send(
        .pluginSettingsCancel, settingsSessionID: session
    )))

    let reopened = try await openSettings(core, bundleID: probeBundleID, width: 40, height: 12)
    #expect(reopened.dirty == false)
    #expect(rowsText(reopened.frame).contains { $0.contains("probeX") })
    #expect(!rowsText(reopened.frame).contains { $0.contains("probeXY") })
}
