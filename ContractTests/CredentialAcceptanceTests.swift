import Foundation
import LingXiFrontendProtocol
import LingXiPluginABI
import LingXiPluginRuntime
import Testing

private let keychainEnabled = ProcessInfo.processInfo.environment["LINGXI_RUN_KEYCHAIN_TESTS"] == "1"
private let ptyEnabled = ProcessInfo.processInfo.environment["LINGXI_RUN_TUI_PTY_TEST"] == "1"

@Test("AUTH-002 real Core preserves Keychain state across restart and plugin disable", .enabled(if: keychainEnabled))
func AUTH_002_coreKeychainRestart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("auth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedTUICore(directory)
    let service = "site.lingxi.credentials.test.\(UUID().uuidString)"
    let firstKey = "first-core-sentinel-\(UUID().uuidString)"
    let newKey = "second-core-sentinel-\(UUID().uuidString)"
    let first = try ProtocolCore(dataDirectory: directory, keychainService: service)
    let setID = first.send(.authSet, provider: "mimo", secret: firstKey)
    let set = try #require(await first.waitReply(setID))
    #expect(set.ok, "\(set.error ?? "")")
    #expect(set.credentials?.first?.source == "keychain")
    // A restarted Core must actually decrypt the item, not only report its metadata.
    first.terminate()

    let second = try ProtocolCore(dataDirectory: directory, keychainService: service)
    defer { second.terminate() }
    let statusID = second.send(.authStatus, provider: "mimo")
    #expect(try #require(await second.waitReply(statusID)).credentials?.first?.configured == true)
    let chatStart = second.snapshot().count
    let chatID = second.send(.chatSend, model: "mimo-v2.6-flash", text: "Keychain restart probe")
    #expect(try #require(await second.waitReply(chatID)).ok)
    let chatEnd = try #require(await second.waitEvent("run.terminal", after: chatStart))
    #expect(chatEnd.status == "completed" && chatEnd.cause == "completedWithText")
    let updateID = second.send(.authSet, provider: "mimo", secret: newKey)
    #expect(try #require(await second.waitReply(updateID)).ok)
    let disableID = second.send(.pluginDisable, bundleID: "site.lingxi.provider.mimo")
    #expect(try #require(await second.waitReply(disableID)).ok)
    let disabledID = second.send(.authStatus, provider: "mimo")
    #expect(try #require(await second.waitReply(disabledID)).credentials?.first?.configured == true)
    let enableID = second.send(.pluginEnable, bundleID: "site.lingxi.provider.mimo")
    #expect(try #require(await second.waitReply(enableID)).ok)
    let statusAfterID = second.send(.authStatus, provider: "mimo")
    #expect(try #require(await second.waitReply(statusAfterID)).credentials?.first?.configured == true)
    let removeID = second.send(.authRemove, provider: "mimo")
    #expect(try #require(await second.waitReply(removeID)).credentials?.first?.configured == false)
    let transcript = second.snapshot().map { String(decoding: $0, as: UTF8.self) }.joined() + second.stderrText
    #expect(!transcript.contains(firstKey) && !transcript.contains(newKey))
    let registry = try String(contentsOf: directory.appendingPathComponent("plugins.json"), encoding: .utf8)
    let journal = try String(contentsOf: directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
    #expect(!journal.contains(firstKey) && !journal.contains(newKey))
    #expect(!registry.contains(firstKey) && !registry.contains(newKey))
}

@Test("AUTH-003 PTY hides keys, updates/removes them and never turns cancellation/paste into chat", .enabled(if: keychainEnabled && ptyEnabled))
func AUTH_003_hiddenInputPTY() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("auth-pty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedTUI(directory)
    let service = "site.lingxi.credentials.test.\(UUID().uuidString)"
    var environment = ProcessInfo.processInfo.environment
    environment["LINGXI_DATA_DIR"] = directory.path
    environment["LINGXI_CORE_HOST"] = builtProduct("LingXiCoreHost").path
    environment["LINGXI_PLUGIN_POLICY"] = "development"
    environment["LINGXI_KEYCHAIN_SERVICE"] = service
    environment["TERM"] = "xterm-256color"
    environment.removeValue(forKey: "LINGXI_CREDENTIAL_SOURCE")
    environment.removeValue(forKey: "MIMO_API_KEY")
    let first = try PTYProcess(environment: environment)
    defer { first.terminate() }
    try #require(await first.waitFor("mimo-v2.6-flash"))
    first.write("/auth mimo\r")
    try #require(await first.waitFor("MiMo API Key：隐藏输入中"))
    let key = "pty-first-sentinel-\(UUID().uuidString)"
    first.write(key + "\r")
    try #require(await first.waitFor("可立即发送新请求"))
    #expect(!first.transcript.contains(key))
    first.write("/quit\r")
    #expect(await waitUntil { !first.isRunning })

    let second = try PTYProcess(environment: environment)
    defer { second.terminate() }
    try #require(await second.waitFor("mimo-v2.6-flash"))
    second.write("/auth mimo status\r")
    try #require(await second.waitFor("mimo：已配置（keychain）"))
    second.write("/auth mimo update\r")
    try #require(await second.waitFor("MiMo API Key：隐藏输入中"))
    let newKey = "pty-updated-sentinel-\(UUID().uuidString)"
    second.write("\u{1B}[200~multiline-secret\nsecond-line\u{1B}[201~\r")
    try #require(await second.waitFor("Key 不能为空或包含空白"))
    second.write(newKey + "\r")
    try #require(await second.waitFor("可立即发送新请求"))
    second.write("/auth mimo remove\r")
    try #require(await second.waitFor("mimo：未配置"))
    let cancelStart = second.transcript.count
    second.write("/auth mimo\r")
    try #require(await second.waitFor("MiMo API Key：隐藏输入中", after: cancelStart))
    let cancelledKey = "cancelled-hidden-sentinel"
    second.write(cancelledKey + "\u{1B}")
    try #require(await second.waitFor("已取消凭据输入"))
    #expect(!second.transcript.contains(cancelledKey))
    second.write("你好\r")
    try #require(await second.waitFor("pong"))
    second.write("/quit\r")
    #expect(await waitUntil { !second.isRunning })
    #expect(!second.transcript.contains(key) && !second.transcript.contains(newKey))
    for name in ["events.jsonl", "plugins.json"] {
        let contents = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        #expect(!contents.contains(key) && !contents.contains(newKey))
    }
}
