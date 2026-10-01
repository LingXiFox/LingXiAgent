import Foundation
import Testing
import LingXiModelSDK

/// 契约 §37 的机器判据：双 Catalog 结束、旧 Registry 生产路径清零、模型站只读
/// `/models.json`、示例只用真实 SDK。这些不是约定俗成，是扫描出来必须为真的断言。
///
/// 扫描范围区分「生产代码」与「历史记录」：Decision doc 与迁移测试可以以 legacy
/// 名义提到旧端点，运行时不可以。
@Suite("Model catalog convergence gates", .serialized)
struct ModelCatalogConvergenceGateTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/LingXiAgentTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private func text(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    private static func swiftSources(in directories: [String]) throws -> [(path: String, text: String)] {
        var found: [(String, String)] = []
        for directory in directories {
            let base = Self.root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
                found.append((url.path.replacingOccurrences(of: Self.root.path + "/", with: ""), body))
            }
        }
        return found
    }

    // MARK: - §3 / §37 旧 Unified Registry 生产路径

    @Test("no production code reads the legacy unified registry")
    func legacyRegistryHasNoProductionCaller() throws {
        let needles = ["/v1/catalog", "ModelRegistryClient", "registry-catalog.json",
                       "lingxiagent.lingxifox.cn/v1", "RegistryCatalog"]
        let offenders = try Self.swiftSources(in: ["Sources", "Apps", "Plugins", "Sidecars"])
            .filter { _, body in needles.contains(where: body.contains) }
            .map(\.path)
        #expect(offenders.isEmpty,
                "旧 Unified Model Registry 仍有生产调用点：\(offenders)")
    }

    @Test("the retired registry daemon and its data are gone from the server tree")
    func retiredServerDaemonIsRemoved() throws {
        let manager = FileManager.default
        for relative in ["Server/lingxi-registry", "Server/registry",
                         "Server/deploy/lingxi-registry.service", "Server/models-site/Caddyfile"] {
            #expect(!manager.fileExists(atPath: Self.root.appendingPathComponent(relative).path),
                    "\(relative) 只服务旧 Registry 或只是重复副本，应已删除")
        }
        // schema 文档是另一件事，必须还在。
        let schema = Self.root.appendingPathComponent(
            "Sources/LingXiCore/Resources/Configuration/Schemas/config.schema.json")
        #expect(manager.fileExists(atPath: schema.path),
                "删除 /v1/catalog 不得牵连 lingxiagent.lingxifox.cn/schema/*.json")
    }

    @Test("Caddy no longer proxies the retired catalog and still serves the schemas statically")
    func caddyfileCarriesNoRegistryRoute() throws {
        let caddy = try text("Server/deploy/Caddyfile")
        #expect(!caddy.contains("127.0.0.1:8787"), "反代到已删除的 registry daemon 会让 /v1/* 变成 502")
        #expect(!caddy.contains("handle /v1/*"), "旧的 /v1/* 路由必须摘掉")
        #expect(!caddy.contains("/summary.json"), "第二套模型投影不再发布")
        #expect(caddy.contains("root * /var/www/lingxiagent"),
                "lingxiagent.lingxifox.cn 仍作为静态宿主保留（schema $id 指向它）")
        #expect(caddy.contains("header /models.json"), "唯一发布物要有明确的缓存策略")
    }

    // MARK: - §7 / §12 / §19 网页数据源与排序

    @Test("the model site reads one document and keeps no second projection")
    func webUIDataSource() throws {
        let page = try text("Server/models-site/public/index.html")
        #expect(page.contains("const CATALOG_URL = '/models.json'"),
                "页面必须直接读 /models.json")
        for forbidden in ["summary.json", "POPULAR_PROVIDERS", "swiftDriver", "reasoningField"] {
            #expect(!page.contains(forbidden), "页面仍引用 \(forbidden)")
        }
        // 排序必须是显式稳定的规则，而不是上游遍历顺序。
        #expect(page.contains("providers.sort(compareProviders)"))
        #expect(page.contains("models.sort(compareModels)"))
        #expect(page.contains("Intl.Collator('en', { numeric: true"))
    }

    @Test("the public page carries no private relay endpoint and no fabricated runtime API")
    func publicExamplesStayHonest() throws {
        let page = try text("Server/models-site/public/index.html")
        let syncScript = try text("Server/models-site/sync-models.py")
        for forbidden in ["api.lingxifox.cn", "api.lingxifox.com", "import LingXiAgent",
                          "LingXiAgent.model(", "LingXiProvider.openAICompatible",
                          "processEnvironment"] {
            #expect(!page.contains(forbidden), "公共模型站示例不得出现 \(forbidden)")
            #expect(!syncScript.contains(forbidden), "同步脚本示例不得出现 \(forbidden)")
        }
        // §18：环境变量只能来自目录明确给出的 env，不得由 provider id 拼出来。
        #expect(!page.contains("+ '_API_KEY'"), "网页不得用 provider id 猜环境变量名")
        #expect(!page.contains("toUpperCase()"), "网页不得用 provider id 猜环境变量名")
        // §15：没有可信端点时说明「由配置决定」，不 fallback 到任何中转。
        #expect(page.contains("由 Provider 配置决定"))
    }

    /// §28 拆分后的分工：SDK 仓库证明「这些调用编译得过」
    /// （`ModelSDKExampleCompileTests`），本仓库证明「网页展示的就是那一份调用」。
    /// 两处合起来才等于原来的保证：网站既不会写着不存在的 API，也不会悄悄落后于 SDK。
    @Test("the web example is the frozen public API surface, verbatim")
    func webExampleMatchesTheFrozenPublicAPI() throws {
        let page = try text("Server/models-site/public/index.html")
        let snippets = [Self.embeddedBlock(named: "SDK_EXAMPLE", in: page),
                        Self.embeddedBlock(named: "INSTALL_EXAMPLE", in: page)]
        for block in snippets where !block.isEmpty {
            #expect(!block.contains("import LingXiAgent"), "网页示例不得再出现 import LingXiAgent")
            for forbidden in ["LingXiAgent.model(", "LingXiProvider.openAICompatible",
                              "processEnvironment", "api.lingxifox"] {
                #expect(!block.contains(forbidden), "网页示例仍包含 \(forbidden)")
            }
        }

        let api = snippets[0]
        #expect(!api.isEmpty, "网页没有 SDK 示例块")
        // 与 SDK 仓库 ModelSDKExampleCompileTests 中逐行编译的形态一致。
        for frozen in ["import LingXiModelSDK",
                       "try await LingXiModelCatalog.load()",
                       "catalog.model(provider: \"deepseek\", id: \"deepseek-v4-flash\")",
                       "model.name", "model.contextWindow", "model.maxOutputTokens",
                       "model.capabilities.reasoning", "model.capabilities.toolCalling",
                       "model.pricing.input", "model.pricing.output",
                       "catalog.models(matching: ModelFilter(",
                       "catalog.revision.catalogRevision", "catalog.revision.generatedAt"] {
            #expect(api.contains(frozen), "网页示例缺少已冻结的公共 API 形态：\(frozen)")
        }

        let install = snippets[1]
        #expect(!install.isEmpty, "网页没有安装块")
        for frozen in ["dependencies: [", ".package(", "url: \"https://github.com/LingXiFox/LingXiModelSDK.git\"",
                       "from: \"0.1.0\"", ".product(", "name: \"LingXiModelSDK\""] {
            #expect(install.contains(frozen), "安装块缺少必要形态：\(frozen)")
        }
    }

    /// 取出 `const NAME = `…`` 模板字符串的内容。
    private static func embeddedBlock(named constant: String, in text: String) -> String {
        guard let start = text.range(of: "const \(constant) = `") else { return "" }
        return String(text[start.upperBound...]).components(separatedBy: "`")[0]
    }


    /// The keys of a JSON object, in the order the document lists them.
    ///
    /// `JSONSerialization` hands back a dictionary and discards exactly the thing
    /// this gate is about, so the published order is read from the bytes instead.
    private static func orderedObjectKeys(in text: String, atKey key: String) -> [String] {
        guard let marker = text.range(of: "\"" + key + "\":") else { return [] }
        var index = text[marker.upperBound...].drop(while: { $0 == " " }).startIndex
        guard text[index] == "{" else { return [] }
        text.formIndex(after: &index)

        var keys: [String] = []
        var depth = 1
        while index < text.endIndex, depth > 0 {
            switch text[index] {
            case "\"":
                guard let read = readString(text, from: &index) else { return keys }
                // `readString` left `index` just past the closing quote, so the
                // next character decides: a colon means this string was a key.
                var probe = index
                while probe < text.endIndex, text[probe] == " " { text.formIndex(after: &probe) }
                if depth == 1, probe < text.endIndex, text[probe] == ":" { keys.append(read) }
            case "{", "[":
                depth += 1
                text.formIndex(after: &index)
            case "}", "]":
                depth -= 1
                text.formIndex(after: &index)
            default:
                text.formIndex(after: &index)
            }
        }
        return keys
    }

    /// Reads one JSON string and leaves `index` just past its closing quote.
    private static func readString(_ text: String, from index: inout String.Index) -> String? {
        var cursor = text.index(after: index)
        var value = ""
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "\\" {
                let next = text.index(after: cursor)
                guard next < text.endIndex else { break }
                value.append(text[next])
                cursor = text.index(after: next)
                continue
            }
            if character == "\"" {
                index = text.index(after: cursor)
                return value
            }
            value.append(character)
            text.formIndex(after: &cursor)
        }
        index = cursor
        return nil
    }

    // MARK: - §8 / §9 / §10 / §17 同步管线

    @Test("the sync pipeline is transactional, schema-guarded and free of runtime guessing")
    func syncPipelineShape() throws {
        let script = try text("Server/models-site/sync-models.py")
        // §10 / §17：猜驱动、猜 reasoning 字段、生成未验证示例的死代码都不许回来。
        for forbidden in ["def determine_swift_driver", "def generate_swift_code", "swift_driver",
                          "\"swiftDriver\":", "\"reasoningField\":", "\"swiftSnippet\":", "summary.json"] {
            #expect(!script.contains(forbidden), "同步脚本仍在生成运行时猜测或第二套投影：\(forbidden)")
        }
        // 这些名字只允许出现在「显式剔除」的清单里。
        #expect(script.contains("RUNTIME_GUESS_FIELDS"), "剔除运行时猜测字段要有明确清单，而不是靠巧合")
        // §8：事务化发布。
        for step in ["validate_source(", "normalize(", "validate_generated(", "tempfile.mkstemp",
                     "os.fsync", "os.replace(", "sha256_of("] {
            #expect(script.contains(step), "同步脚本缺少发布事务的一步：\(step)")
        }
        // §9 / §22：上游 schema 防线与骤降保护。
        #expect(script.contains("def check_model"))
        #expect(script.contains("guard_against_shrink"))
        #expect(script.contains("--allow-shrink"))
        // §21：schema 版本与目录修订是两个概念。
        for field in ["schemaVersion", "catalogRevision", "catalogHash", "sourceFetchedAt",
                      "sourceHash", "generatedAt"] {
            #expect(script.contains("\"\(field)\""), "发布 envelope 缺少 \(field)")
        }
    }

    /// §7 / §11 / §21 对已发布 artifact 本身的检查：它是 v2 envelope、确定性排序，
    /// 并且没有被 LingXi 运行时猜测污染。
    @Test("the published catalog is the single v2 artifact with stable ordering")
    func publishedArtifact() throws {
        let url = Self.root.appendingPathComponent("Server/models-site/public/models.json")
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("models.json 不是合法 JSON 对象"); return
        }
        for forbidden in ["\"swiftDriver\"", "\"reasoningField\"", "\"swiftSnippet\""] {
            #expect(!text.contains(forbidden), "发布物混入了运行时猜测字段 \(forbidden)")
        }
        // envelope 元信息
        #expect(object["schemaVersion"] as? String == "2.0")
        let revision = try #require(object["catalogRevision"] as? String)
        #expect(!revision.isEmpty)
        #expect(object["catalogHash"] as? String != nil)
        #expect(object["source"] as? String == "models.dev")
        #expect(object["sourceHash"] as? String != nil)
        #expect(object["sourceFetchedAt"] as? String != nil)

        let providers = try #require(object["providers"] as? [String: Any])
        #expect(!providers.isEmpty)
        #expect((object["totalProviders"] as? Int) == providers.count)
        // §7.1：不允许再有第二套完整模型投影。
        #expect(object["summary"] == nil)

        // 发布顺序即展示顺序：厂商按显示名（数字感知）稳定排列。
        var modelCount = 0
        for (pid, raw) in providers {
            guard let provider = raw as? [String: Any] else { Issue.record("\(pid) 不是对象"); continue }
            let models = provider["models"] as? [String: Any] ?? [:]
            modelCount += models.count
            #expect((provider["modelCount"] as? Int) == models.count, "\(pid) 的 modelCount 与实际不符")
            // §11：上游字段原样保留，不被无声裁掉。
            for model in models.values {
                guard let entry = model as? [String: Any] else { Issue.record("\(pid) 有非对象模型条目"); continue }
                #expect(entry["limit"] != nil || entry["id"] != nil)
            }
            if let baseURL = provider["baseURL"] as? String {
                #expect(!baseURL.contains("api.lingxifox"), "发布物不得把中转地址当作 provider 端点")
            }
        }
        #expect((object["totalModels"] as? Int) == modelCount)
        // 发布顺序必须由 SDK 公开的那一条排序规则解释——同一个规则，三处实现。
        // 键序是发布物的一部分，因此从字节里读，而不是从丢序的字典里读。
        let publishedOrder = Self.orderedObjectKeys(in: text, atKey: "providers")
        #expect(publishedOrder.count == providers.count,
                "无法从发布物里读回厂商键序，这条门禁就失去了意义")
        let sorted = publishedOrder.sorted { lhs, rhs in
            ModelCatalogOrdering.displayName(
                (providers[lhs] as? [String: Any])?["name"] as? String ?? lhs, lhs,
                (providers[rhs] as? [String: Any])?["name"] as? String ?? rhs, rhs
            ) == .orderedAscending
        }
        #expect(publishedOrder == sorted,
                "厂商发布顺序必须等于 SDK 公开排序规则的结果，前 8 个：\(publishedOrder.prefix(8))")
    }

    // MARK: - §2 / §4 语义分离

    @Test("the runtime provider contract survives; the catalog does not decide runtime behaviour")
    func responsibilitiesStaySeparated() throws {
        // BuiltinProviderCatalog 承担 auth / protocol / discovery，不能被当成公共模型数据库删掉。
        let contract = try text("Sources/LingXiCore/Configuration/BuiltinProviderCatalog.swift")
        #expect(contract.contains("protocolFamily"))
        #expect(contract.contains("discoveryProfile"))
        let catalogFile = try text("Sources/LingXiCore/Provider/Discovery/PublicModelCatalogClient.swift")
        #expect(catalogFile.contains("import LingXiModelSDK"),
                "Core 通过 SDK 消费目录，而不是自己再解一遍 JSON")
        #expect(!catalogFile.contains("Codable"), "目录 schema 不该在 Core 里重述一遍")
        // 公共目录不再携带任何 driver 字段，Core 侧也不得再读它。
        #expect(!catalogFile.contains("swiftDriver"))
    }
}
