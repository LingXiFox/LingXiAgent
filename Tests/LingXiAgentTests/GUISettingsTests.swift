#if canImport(SwiftUI)
import Foundation
import Testing
@testable import LingXiApplication
@testable import LingXiProtocol
@testable import LingXiFrontendKit

@Suite("GUI Settings: config.json, search index, defaults")
struct GUISettingsTests {

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-settings-\(UUID().uuidString)")
            .appendingPathComponent(name)
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("Writing a key preserves unknown keys; nil removes the override and empty parents")
    func writePreservesUnknownKeys() throws {
        let url = tempURL("config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"custom":{"keep":1},"agent":{"maxSubagentDepth":5},"version":1}"#.utf8).write(to: url)

        let file = CoreConfigFile(url: url)
        #expect(file.value(at: ["agent", "maxSubagentDepth"]) as? Int == 5)

        try file.set(8, at: ["context", "l1", "target"])
        try file.set(nil, at: ["agent", "maxSubagentDepth"])

        let reread = CoreConfigFile(url: url)
        #expect(reread.value(at: ["custom", "keep"]) as? Int == 1)
        #expect(reread.value(at: ["context", "l1", "target"]) as? Int == 8)
        #expect(reread.value(at: ["agent"]) == nil)
        #expect(reread.value(at: ["version"]) as? Int == 1)
    }

    @Test("An unparseable config.json is never overwritten")
    func unparseableFileIsNotOverwritten() throws {
        let url = tempURL("config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{ hand-edited, not json".utf8)
        try original.write(to: url)

        let file = CoreConfigFile(url: url)
        #expect(!file.isReadable)
        #expect(throws: CoreConfigFile.WriteError.self) { try file.set("auto", at: ["agent", "permissionPolicy"]) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("Every exposed key exists in Core's config schema and matches the bundled default")
    func configKeysMatchCoreSchema() throws {
        let configDir = Self.repoRoot.appendingPathComponent("Sources/LingXiCore/Resources/Configuration")
        let schema = try JSONSerialization.jsonObject(
            with: Data(contentsOf: configDir.appendingPathComponent("Schemas/config.schema.json"))) as? [String: Any]
        let defaults = try JSONSerialization.jsonObject(
            with: Data(contentsOf: configDir.appendingPathComponent("Defaults/config.json"))) as? [String: Any]

        for (id, fallback) in ConfigKeys.all {
            let path = id.split(separator: ".").map(String.init)
            var node: [String: Any]? = schema
            for component in path {
                node = (node?["properties"] as? [String: Any])?[component] as? [String: Any]
            }
            #expect(node != nil, "\(id) is not defined in config.schema.json")

            var value: Any? = defaults
            for component in path { value = (value as? [String: Any])?[component] }
            guard let value, !(value is NSNull) else { continue }
            // JSON numbers and booleans arrive as NSNumber; compare as such.
            let matches = (value as? NSNumber).map { number in
                (fallback as? NSNumber).map(number.isEqual(to:)) ?? false
            } ?? ("\(value)" == "\(fallback)")
            #expect(matches, "\(id): fallback \(fallback) differs from bundled default \(value)")
        }
    }

    @Test("Search index anchors are unique and queries match titles and keywords")
    func searchIndex() {
        let items = SettingsSearchIndex.staticItems
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(items.contains { $0.matches("yolo") && $0.page == .permissions })
        #expect(items.contains { $0.matches("深色") && $0.page == .appearance })
        #expect(items.filter { $0.matches("mcp server") }.allSatisfy { $0.page == .mcp })
        #expect(SettingsPage.Group.allCases.flatMap(\.pages).count == SettingsPage.allCases.count)
    }

    @Test("Composer defaults derive from config.json and shared preferences")
    @MainActor
    func composerDefaults() throws {
        let configURL = tempURL("config.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"agent":{"permissionPolicy":"auto","executionProfile":"fullAccess","behaviorProfile":"plan"}}"#.utf8)
            .write(to: configURL)
        let prefs = UserPreferencesStore(fileURL: configURL.deletingLastPathComponent().appendingPathComponent("preferences.json"))

        let store = SettingsStore(configURL: configURL, preferencesStore: prefs)
        store.setDefaultReasoning(.med)

        let defaults = store.composerDefaults
        #expect(defaults.mode == .plan)
        #expect(defaults.permission == .yoloFullAccess)
        #expect(defaults.reasoning == .med)
        #expect(prefs.load().lastReasoningEffort == ReasoningEffort.medium.rawValue)
    }
}
#endif
