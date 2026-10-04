import Foundation
import Testing
@testable import LingXiCore
#if canImport(SwiftUI)
@testable import LingXiFrontendKit
#endif

struct PEConfigKeyCompatibilityTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test("Agent settings use one canonical P/E budget schema")
    func agentBudgetKeys() throws {
        let base = #""maxConcurrentSubagents":4,"maxSubagentDepth":3,"maxTotalRunsPerRootRun":32"#
        let settings = try decode(AgentSettings.self, "{\(base),\"pCoreProjectMaxCharacters\":1234,\"eCoreRecallMaxCharacters\":5678}")
        #expect(settings.pCoreProjectMaxCharacters == 1234)
        #expect(settings.eCoreRecallMaxCharacters == 5678)
        let defaults = try decode(AgentSettings.self, "{\(base)}")
        #expect(defaults.pCoreProjectMaxCharacters == 32 * 1024)
        #expect(defaults.eCoreRecallMaxCharacters == 256 * 1024)
        #expect(try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test("P/E configuration preserves each distinct budget on round trip")
    func cacheBudgetKeys() throws {
        let config = try decode(ContextCacheConfiguration.self, #"{"pCore":{"target":100,"softLimit":110,"hardLimit":120},"eCore":{"storageBudget":300,"recallBudget":200,"pressureThreshold":0.85,"useRemainingBudget":false}}"#)
        #expect(config.pCore.target == 100)
        #expect(config.pCore.softLimit == 110)
        #expect(config.pCore.hardLimit == 120)
        #expect(config.eCore.recallBudget == 200)
        #expect(config.eCore.storageBudget == 300)
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(ContextCacheConfiguration.self, from: data) == config)
        let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(keys.keys) == ["addressableBudget", "reserve", "economicThreshold", "pCore", "eCore", "fabric"])
    }

    @Test("Bundled defaults and schema expose canonical P/E keys")
    func bundledResourcesUsePENames() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Sources/LingXiCore/Resources/Configuration")
        let defaults = try String(contentsOf: directory.appendingPathComponent("Defaults/config.json"), encoding: .utf8)
        #expect(ContextObjectFabricConfiguration().eCorePersistenceEnabled)
        let schema = try String(contentsOf: directory.appendingPathComponent("Schemas/config.schema.json"), encoding: .utf8)
        for key in ["pCoreProjectMaxCharacters", "eCoreRecallMaxCharacters", "eCorePersistenceEnabled"] {
            if key != "eCorePersistenceEnabled" { #expect(defaults.contains(key)) }
            #expect(schema.contains(key))
        }
    }

#if canImport(SwiftUI)
    @Test("GUI settings edit and reset the canonical draft budget without changing other keys")
    func guiBudgetKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lx-pe-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        try Data(#"{"agent":{"pCoreProjectMaxCharacters":4096},"version":1}"#.utf8).write(to: url)
        let file = CoreConfigFile(url: url)
        let key = ConfigKeys.pCoreProjectMaxCharacters
        #expect(key.resolve(in: file) == 4_096)
        #expect(key.isOverridden(in: file))
        try file.set(8_192, at: key.path)
        let reread = CoreConfigFile(url: url)
        #expect(key.resolve(in: reread) == 8_192)
        for path in key.clearPaths { try reread.set(nil, at: path) }
        let cleared = CoreConfigFile(url: url)
        #expect(key.resolve(in: cleared) == 32_768)
        #expect(cleared.value(at: ["version"]) as? Int == 1)
    }
#endif
}
