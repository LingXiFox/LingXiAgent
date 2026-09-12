import Testing
import Foundation
import LingXiProtocol
import LingXiCore
@testable import LingXiApplication
@testable import LingXiTUI
import LingXiTUIComponents

@Suite("Resume & Config Enhancements Tests")
struct ResumeAndConfigEnhancementTests {

    @Test func sessionCatalogOrdersStrictlyByUpdatedAtDescending() {
        let now = Date()
        let sOld = SessionSummary(
            sessionID: SessionID("sess-old"),
            title: "Old Session",
            createdAt: now.addingTimeInterval(-3600),
            updatedAt: now.addingTimeInterval(-3600),
            turnCount: 2,
            mode: .build,
            reasoningEffort: .auto,
            workingDirectory: "/Volumes/Work/ProjectA",
            messageCount: 4
        )
        let sMid = SessionSummary(
            sessionID: SessionID("sess-mid"),
            title: "Mid Session",
            createdAt: now.addingTimeInterval(-1800),
            updatedAt: now.addingTimeInterval(-1800),
            turnCount: 5,
            mode: .build,
            reasoningEffort: .auto,
            workingDirectory: "/Volumes/Work/ProjectB",
            messageCount: 10
        )
        let sNewest = SessionSummary(
            sessionID: SessionID("sess-newest"),
            title: "Newest Session",
            createdAt: now,
            updatedAt: now,
            turnCount: 1,
            mode: .build,
            reasoningEffort: .auto,
            workingDirectory: "/Volumes/Work/ProjectC",
            messageCount: 2
        )

        let unordered = [sOld, sNewest, sMid]
        let sorted = SessionCatalog.groups(unordered, currentDirectory: "/unrelated").flatMap(\.sessions)

        #expect(sorted.count == 3)
        #expect(sorted[0].sessionID == SessionID("sess-newest"))
        #expect(sorted[1].sessionID == SessionID("sess-mid"))
        #expect(sorted[2].sessionID == SessionID("sess-old"))
    }

    @Test func resumeGroupsCurrentProjectAndSortsWithinEachProject() {
        let sessions = [
            SessionSummary(sessionID: SessionID("old"), updatedAt: Date(timeIntervalSince1970: 1), workingDirectory: "/work/A"),
            SessionSummary(sessionID: SessionID("other"), updatedAt: Date(timeIntervalSince1970: 9), workingDirectory: "/work/B"),
            SessionSummary(sessionID: SessionID("new"), updatedAt: Date(timeIntervalSince1970: 3), workingDirectory: "/work/A/"),
            SessionSummary(sessionID: SessionID("unknown"), updatedAt: Date(timeIntervalSince1970: 0))
        ]
        let groups = SessionCatalog.groups(sessions, currentDirectory: "/work/A")
        #expect(groups.map(\.directory) == ["/work/A", "/work/B", ""])
        #expect(groups[0].sessions.map(\.sessionID.rawValue) == ["new", "old"])
        #expect(SessionCatalog.groups(sessions, currentDirectory: "/work/A", query: "/work/B").flatMap(\.sessions).count == 1)
    }

    @Test @MainActor func resumeLayoutFitsNarrowTerminalAndKeepsSelectionVisible() {
        let sessions = (0..<24).map { i in
            SessionSummary(sessionID: SessionID("session-\(i)"), title: "中文标题\n包含换行和长文本", updatedAt: Date(timeIntervalSince1970: Double(24 - i)), workingDirectory: "/work/project")
        }
        for selected in [0, 12, 23] {
            let overlay = ApplicationTUI.sessionPickerOverlay(sessions: sessions, currentDirectory: "/work/project", activeSessionID: nil, query: "", selected: selected, size: TUISize(width: 42, height: 18))
            #expect(overlay.lines.allSatisfy { TUIDisplayWidth.width(of: $0.text) <= 36 && !$0.text.contains("\n") })
            #expect(overlay.lines.contains { $0.style == .modalHighlight })
            #expect(overlay.lines.contains { $0.style == .modalGroup })
            #expect(overlay.lines.count + 2 <= 18)
        }
    }

    @Test func configRejectsInvalidValuesAndRegistersAliases() throws {
        #expect(try UserPreferences.parseToggle("off", true) == false)
        #expect(try UserPreferences.parseToggle("toggle", false) == true)
        #expect(throws: ApplicationCommandError.self) { try UserPreferences.parseToggle("typo", false) }
        let command = try #require(BuiltinCommands.createAll().first { $0.name == "config" })
        #expect(command.aliases.contains("set"))
        #expect(command.aliases.contains("preference"))
    }

    @Test func userPreferencesStoreTogglesThinkingToolsAndSidebar() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test_prefs.json")
        let store = UserPreferencesStore(fileURL: testFile)

        // 初始为空
        let initial = store.load()
        #expect(initial.expandThinking == nil)
        #expect(initial.expandTools == nil)
        #expect(initial.showSidebar == nil)

        // 开启 thinking
        store.update(expandThinking: true)
        #expect(store.load().expandThinking == true)

        // 开启 tools，隐藏 sidebar
        store.update(expandTools: true, showSidebar: false)
        let updated = store.load()
        #expect(updated.expandThinking == true)
        #expect(updated.expandTools == true)
        #expect(updated.showSidebar == false)

        // 折叠 thinking
        store.update(expandThinking: false)
        #expect(store.load().expandThinking == false)
    }

    @Test func mcpResolverConcurrentlyResolvesDisabledAndEmptyServers() async throws {
        let emptyConfig = MCPConfiguration(servers: [
            StoredMCPServerConfiguration(id: "s1", alias: "Server1", transport: .stdio, command: "/bin/echo", arguments: ["hi"], enabled: false),
            StoredMCPServerConfiguration(id: "s2", alias: "Server2", transport: .stdio, command: "/bin/echo", arguments: ["hi"], enabled: false)
        ])
        let creds = try PlatformSecureCredentialStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let res = try await RuntimeConfigurationResolver.resolveMCP(emptyConfig, credentials: creds, discoverTools: false)
        #expect(res.configurations.count == 2)
        #expect(res.configurations.allSatisfy { !$0.enabled })
    }
}
