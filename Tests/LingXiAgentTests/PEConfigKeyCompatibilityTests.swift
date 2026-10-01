import Foundation
import Testing
@testable import LingXiCore
#if canImport(SwiftUI)
@testable import LingXiFrontendKit
#endif

/// 契约第十一节：旧用户配置不能静默失效。读取优先级固定为 新 P/E 键 → legacy L 键 → 默认值，
/// 写入只落新键，GUI 只展示 P/E 术语。
struct PEConfigKeyCompatibilityTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test("AgentSettings reads the new P/E keys and still honors the legacy L keys")
    func agentSettingsKeyPrecedence() throws {
        let base = #""maxConcurrentSubagents":4,"maxSubagentDepth":3,"maxTotalRunsPerRootRun":32"#

        let legacyOnly = try decode(AgentSettings.self, "{\(base),\"l1ProjectMaxCharacters\":1234,\"l2MaxCharacters\":5678}")
        #expect(legacyOnly.pCoreProjectMaxCharacters == 1234)
        #expect(legacyOnly.eCoreRecallMaxCharacters == 5678)

        let both = try decode(AgentSettings.self, "{\(base),\"l1ProjectMaxCharacters\":1234,\"pCoreProjectMaxCharacters\":999,\"l2MaxCharacters\":5678,\"eCoreRecallMaxCharacters\":888}")
        #expect(both.pCoreProjectMaxCharacters == 999, "新键必须优先于旧键")
        #expect(both.eCoreRecallMaxCharacters == 888)

        let none = try decode(AgentSettings.self, "{\(base)}")
        #expect(none.pCoreProjectMaxCharacters == 32 * 1024)
        #expect(none.eCoreRecallMaxCharacters == 256 * 1024)

        // 兼容周期内旧名仍可用，且指向同一个存储值。
        var alias = try decode(AgentSettings.self, "{\(base),\"l1ProjectMaxCharacters\":4242}")
        #expect(alias.l1ProjectMaxCharacters == 4242)
        alias.l1ProjectMaxCharacters = 777
        #expect(alias.pCoreProjectMaxCharacters == 777)

        // 写回只落新键：旧键不得再被复制进用户配置。
        let encoded = String(data: try JSONEncoder().encode(legacyOnly), encoding: .utf8) ?? ""
        #expect(encoded.contains("pCoreProjectMaxCharacters"))
        #expect(!encoded.contains("l1ProjectMaxCharacters"))
    }

    @Test("Fabric config renames ecoreStorageEnabled to eCorePersistenceEnabled without breaking old files")
    func fabricPersistenceKeyPrecedence() throws {
        let legacy = try decode(ContextObjectFabricConfiguration.self, #"{"ecoreStorageEnabled":false}"#)
        #expect(legacy.eCorePersistenceEnabled == false, "E-Core 只有关不关持久化，不存在关掉 E-Core")

        let both = try decode(ContextObjectFabricConfiguration.self, #"{"ecoreStorageEnabled":true,"eCorePersistenceEnabled":false}"#)
        #expect(both.eCorePersistenceEnabled == false)

        let none = try decode(ContextObjectFabricConfiguration.self, "{}")
        #expect(none.eCorePersistenceEnabled)

        var alias = legacy
        #expect(alias.ecoreStorageEnabled == false)
        alias.ecoreStorageEnabled = true
        #expect(alias.eCorePersistenceEnabled == true)

        let encoded = String(data: try JSONEncoder().encode(legacy), encoding: .utf8) ?? ""
        #expect(encoded.contains("eCorePersistenceEnabled"))
        #expect(!encoded.contains("ecoreStorageEnabled"))
    }

    @Test("Cache budget keeps the L1/L2/L3 fallback that the P/E fields replaced")
    func cacheBudgetKeyPrecedence() throws {
        let legacy = try decode(ContextCacheConfiguration.self, #"{"l1":{"target":100,"softLimit":110,"hardLimit":120},"l2":{"max":200},"l3":{"max":300}}"#)
        #expect(legacy.pCore.target == 100)
        #expect(legacy.pCore.softLimit == 110)
        #expect(legacy.pCore.hardLimit == 120)
        #expect(legacy.eCore.recallBudget == 200)
        #expect(legacy.eCore.storageBudget == 300)

        let both = try decode(ContextCacheConfiguration.self, #"{"l1":{"target":100,"softLimit":110,"hardLimit":120},"pCore":{"target":1000,"softLimit":1100,"hardLimit":1200}}"#)
        #expect(both.pCore.target == 1_000, "新键优先")
    }

    @Test("Bundled defaults and schema carry the new P/E keys")
    func bundledResourcesUsePENames() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configDir = root.appendingPathComponent("Sources/LingXiCore/Resources/Configuration")
        let defaults = String(data: try Data(contentsOf: configDir.appendingPathComponent("Defaults/config.json")), encoding: .utf8) ?? ""
        #expect(defaults.contains("pCoreProjectMaxCharacters"))
        #expect(defaults.contains("eCoreRecallMaxCharacters"))
        #expect(!defaults.contains("l1ProjectMaxCharacters"), "默认文件不该再生产旧键")

        let schema = String(data: try Data(contentsOf: configDir.appendingPathComponent("Schemas/config.schema.json")), encoding: .utf8) ?? ""
        for key in ["pCoreProjectMaxCharacters", "eCoreRecallMaxCharacters", "eCorePersistenceEnabled", "l1ProjectMaxCharacters", "l2MaxCharacters", "ecoreStorageEnabled"] {
            #expect(schema.contains(key), "旧键必须仍被 schema 接受，兼容周期内不能报错：\(key)")
        }
    }

#if canImport(SwiftUI)
    @Test("GUI settings resolve the new key first, fall back to the legacy key, and write only the new one")
    func guiKeyResolutionOrder() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-pe-compat-\(UUID().uuidString)")
            .appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data(#"{"agent":{"l1ProjectMaxCharacters":4096},"version":1}"#.utf8).write(to: url)

        let file = CoreConfigFile(url: url)
        let key = ConfigKeys.pCoreProjectMaxCharacters
        #expect(key.resolve(in: file) == 4_096, "旧配置文件里的值必须继续生效")
        #expect(key.isOverridden(in: file))
        #expect(ConfigKeys.eCoreRecallMaxCharacters.resolve(in: file) == 262_144)
        #expect(!ConfigKeys.eCoreRecallMaxCharacters.isOverridden(in: file))

        try file.set(8_192, at: key.path)
        let reread = CoreConfigFile(url: url)
        #expect(key.resolve(in: reread) == 8_192, "新键一旦写入就压过旧键")

        for path in key.clearPaths {
            try reread.set(nil, at: path)
        }
        let cleared = CoreConfigFile(url: url)
        #expect(key.resolve(in: cleared) == 32_768, "重置必须连旧键一起清掉")
        #expect(cleared.value(at: ["version"]) as? Int == 1, "未知键不得被顺手删掉")
    }
#endif
}
