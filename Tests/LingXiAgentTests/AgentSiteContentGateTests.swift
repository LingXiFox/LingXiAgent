import Foundation
import Testing

/// agent-site 的内容门禁（契约 §43–§62、§79）。
///
/// 这里的每一条都对应一个「网页曾经比代码先说了一件不存在的事」的历史教训，
/// 所以判据是扫描页面文本，而不是人工承诺。允许旧词出现的唯一情形：它出现在
/// 一句明确的否认句里（「不驱动」「已废弃」「不是 JSON-RPC 2.0」）。
@Suite("Agent site content gates", .serialized)
struct AgentSiteContentGateTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/LingXiAgentTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private static let pages = ["index.html", "docs.html", "sdk.html"]

    private func text(_ name: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent("Server/agent-site/public/\(name)"), encoding: .utf8)
    }

    /// 旧词只允许活在否定句里。
    private func assertOnlyDenied(_ haystack: String, needles: [String], page: String) {
        let denials = ["不", "没有", "废弃", "禁止", "never", "not ", "No ", "而非"]
        var offenders: [String] = []
        for line in haystack.split(separator: "\n") {
            guard let hit = needles.first(where: { line.contains($0) }) else { continue }
            if denials.contains(where: { line.contains($0) }) { continue }
            offenders.append("\(page): \(hit) → \(line.prefix(90))")
        }
        #expect(offenders.isEmpty, "陈旧文案未被明确否认：\(offenders)")
    }

    // MARK: - §46 / §47 / §49 旧上下文架构

    @Test("legacy L1/L2/L3 context architecture is not taught as current")
    func legacyContextTiersAreGone() throws {
        for page in Self.pages {
            // 数字边界避免命中 SVG 路径里的 "L14" 之类坐标。
            let body = try text(page)
            let lines = body.split(separator: "\n").filter { !$0.contains("<svg") && !$0.contains("path d=") }
            let joined = lines.joined(separator: "\n")
            assertOnlyDenied(joined, needles: ["三级上下文", "三级流控", "三级缓存", "Hot Working Set", "Warm Cache", "Cold Store"], page: page)
            #expect(!joined.contains("L1/L2/L3") || joined.contains("已废弃"),
                    "\(page) 仍把 L1/L2/L3 当作现行架构描述")
        }
    }

    @Test("homepage describes the frozen P-Core / E-Core split")
    func homepageCarriesCurrentArchitecture() throws {
        let body = try text("index.html")
        #expect(body.contains("id=\"architecture\""), "首页缺少上下文架构章节")
        #expect(body.contains("Stable Prefix") && body.contains("Growing Context") && body.contains("E-Core Index Projection"))
        #expect(body.contains("Exact Restore") && body.contains("Semantic Recall"))
        #expect(body.contains("不驱动 P-Core eviction") || body.contains("does not drive"))
    }

    // MARK: - §43 / §44 / §56 / §57 版本与发布事实

    @Test("no invented release version and no stale Windows text")
    func releaseFactsAreHonest() throws {
        for page in Self.pages {
            let body = try text(page)
            assertOnlyDenied(body, needles: ["v2.0 Native", "LingXiAgent 2.0 发布", "V1.0.0 暂无", "Windows 实验性", "Windows (PowerShell 实验性)"], page: page)
        }
        let installer = try String(
            contentsOf: Self.root.appendingPathComponent("Server/agent-site/public/install.ps1"), encoding: .utf8)
        assertOnlyDenied(installer, needles: ["not published for V1.0.0", "returns in V1.1.0", "暂未提供 Windows"], page: "install.ps1")
        // 首页版本槽位存在，并由 GitHub Releases API 填充。
        let home = try text("index.html")
        #expect(home.contains("id=\"release-version\"") && home.contains("api.github.com/repos/LingXiFox/LingXiAgent/releases/latest"),
                "首页 Release 区域必须来自 GitHub Releases 事实，而不是手写版本号")
    }

    @Test("prebuilt assets named on the site match the release asset naming")
    func releaseAssetNamesAreReal() throws {
        let body = try text("index.html")
        for asset in ["lingxiagent-macos-arm64.tar.gz", "lingxiagent-linux-x86_64.tar.gz", "lingxiagent-windows-x86_64.zip"] {
            #expect(body.contains(asset), "首页未列出真实发布资产 \(asset)")
        }
        #expect(body.contains("Support levels") || body.contains("能力差异"),
                "首页必须区分预编译可用性、源码构建可用性与能力差异")
    }

    // MARK: - §52 / §53 / §54 不可复现数字与夸张宣传

    @Test("no unreproducible benchmark numbers or absolutist provider claims")
    func hypeIsRemoved() throws {
        for page in Self.pages {
            let body = try text(page)
            assertOnlyDenied(body, needles: ["~10ms", "10ms /", "35MB", "60FPS", "60 FPS", "85% 以上", "反封锁", "反检测", "指纹一致", "杜绝风控", "白嫖", "75+"], page: page)
        }
    }

    @Test("model counts are not hardcoded; the catalog is the source")
    func noHardcodedModelCount() throws {
        let body = try text("index.html")
        #expect(!body.contains("75+ models") && !body.contains("75+ 通用大模型") && !body.contains("通用模型生态 (75"))
        #expect(body.contains("models.lingxifox.cn"), "模型生态应指向 Models Hub 而非自报数字")
    }

    // MARK: - §19 / §20 / §40 / §41 插件 IPC 命名诚实

    @Test("plugin IPC is named as JSON Lines and uses the real method set")
    func pluginIpcNamingIsCorrect() throws {
        let body = try text("sdk.html")
        #expect(!body.contains("tool.call"), "tool.call 不是真实方法名")
        for method in ["host.snapshot", "plugin.initialize", "tool.execute", "command.execute", "hook.emit"] {
            #expect(body.contains(method), "IPC 方法表缺少 \(method)")
        }
        #expect(body.contains("JSON Lines"))
        let jsonRpcLines = body.split(separator: "\n").filter { $0.contains("JSON-RPC") }
        for line in jsonRpcLines {
            #expect(line.contains("不是") || line.contains("no ") || line.contains("not"),
                    "JSON-RPC 只能出现在否认句里：\(line.prefix(80))")
        }
    }

    // MARK: - §34 / §50 / §61 / §9 两个 SDK 的安装入口与职责

    @Test("site install snippets agree with the root Package.swift dependency graph")
    func installBlocksMatchPackageManifest() throws {
        let manifest = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        for (name, url) in [("LingXiModelSDK", "https://github.com/LingXiFox/LingXiModelSDK.git"),
                            ("LingXiPluginSDK", "https://github.com/LingXiFox/LingXiPluginSDK.git")] {
            #expect(manifest.contains(url), "Package.swift 应以远程 package 形式引用 \(name)")
            guard let range = manifest.range(of: url) else { continue }
            let tail = manifest[range.upperBound...].prefix(80)
            #expect(tail.contains("from: \"0.1.0\""), "\(name) 的最低版本应与网站一致：\(tail)")

            let pages = try Self.pages.map { try text($0) }
            let mentioned = pages.filter { $0.contains(url) }
            #expect(!mentioned.isEmpty, "\(name) 的网站安装块缺失")
            for page in pages where page.contains(url) {
                let occurrences = page.components(separatedBy: url).dropFirst()
                for tail in occurrences {
                    #expect(tail.prefix(80).contains("0.1.0"), "\(name) 安装块未使用 0.1.0")
                }
            }
        }
        // 插件文档不得再把 LingXiAgent 仓库当依赖入口。
        let sdk = try text("sdk.html")
        #expect(!sdk.contains("package: \"LingXiAgent\""), "sdk.html 仍把 PluginSDK 描述为 LingXiAgent 仓库内的 product")
        #expect(!sdk.contains("branch: \"main\""), "sdk.html 仍要求跟踪 LingXiAgent main 分支")
    }

    @Test("the two SDKs are presented with distinct responsibilities")
    func sdkRolesAreDistinguished() throws {
        let body = try text("index.html")
        #expect(body.contains("id=\"sdks\""), "首页缺少 Developer SDKs 区域")
        #expect(body.contains("面向模型目录消费者") && body.contains("面向插件作者"))
        #expect(body.contains("https://github.com/LingXiFox/LingXiPluginSDK"))
    }

    @Test("module boundary separates internal runtime from public SDKs")
    func moduleBoundaryIsStated() throws {
        let body = try text("index.html")
        #expect(body.contains("Internal Runtime Modules") && body.contains("Public Developer SDKs"))
    }

    // MARK: - §60 canonical navigation

    @Test("navigation uses one canonical convention")
    func canonicalLinks() throws {
        for page in Self.pages {
            let body = try text(page)
            #expect(!body.contains("\"/docs\"") && !body.contains("\"/sdk\""),
                    "\(page) 混用了 /docs 与 /docs.html 两套链接")
            #expect(body.contains("/docs.html") || page == "docs.html")
        }
    }

    @Test("every in-page and cross-page anchor resolves to a real id")
    func anchorsResolve() throws {
        var bodies: [String: String] = [:]
        for page in Self.pages { bodies[page] = try text(page) }
        for (page, body) in bodies {
            for target in Set(extractAnchors(body, pattern: "href=\"#([A-Za-z0-9_\\-]+)\"")) {
                #expect(bodies[page]!.contains("id=\"\(target)\""), "\(page) 的导航指向不存在的 #\(target)")
            }
            for (otherPage, target) in extractCrossAnchors(body) {
                let haystack = bodies[otherPage] ?? ""
                #expect(haystack.contains("id=\"\(target)\""), "\(page) 指向 \(otherPage)#\(target)，但该锚点不存在")
            }
        }
    }

    private func extractAnchors(_ body: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(body.startIndex..., in: body)
        return regex.matches(in: body, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: body) else { return nil }
            return String(body[r])
        }
    }

    private func extractCrossAnchors(_ body: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: "href=\"/([a-z]+\\.html)#([A-Za-z0-9_\\-]+)\"") else { return [] }
        let range = NSRange(body.startIndex..., in: body)
        return regex.matches(in: body, range: range).compactMap { match in
            guard let a = Range(match.range(at: 1), in: body), let b = Range(match.range(at: 2), in: body) else { return nil }
            return (String(body[a]), String(body[b]))
        }
    }

    // MARK: - §71 / §79 文档不得先于代码发明事实

    @Test("documented CLI forms exist in the shipped binaries")
    func documentedCLIFormsAreReal() throws {
        let parser = try String(contentsOf: Self.root.appendingPathComponent("Sources/LingXiTUI/CLIParser.swift"), encoding: .utf8)
        for page in Self.pages {
            let body = try text(page)
            // ops 动词由 lingxiagent-ops 提供；网页写成 `lingxiagent <verb>` 就是假示例。
            for verb in ["auth", "acp", "review", "doctor", "exec", "resume", "mcp", "skills", "models"] {
                guard parser.contains("case \(verb)") || parser.contains("\"\(verb)\"") else { continue }
                let wrong = "lingxiagent \(verb) "
                #expect(!body.contains(wrong), "\(page) 把 ops 子命令写成了 \(wrong.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    @Test("config examples contain no plaintext credentials")
    func examplesCarryNoSecrets() throws {
        for page in Self.pages {
            let body = try text(page)
            for needle in ["sk-your", "ghp_", "\"apiKey\": \"sk", "Bearer sk-"] {
                #expect(!body.contains(needle), "\(page) 的配置示例出现明文凭据形态 \(needle)")
            }
        }
    }

    @Test("documented config keys exist in the bundled schema")
    func documentedConfigKeysAreReal() throws {
        let schemaURL = Self.root.appendingPathComponent(
            "Sources/LingXiCore/Resources/Configuration/Schemas/config.schema.json")
        let schemaText = try String(contentsOf: schemaURL, encoding: .utf8)
        let docs = try text("docs.html")
        #expect(docs.contains("lingxiagent.lingxifox.cn/schema/config.json"))
        for key in ["objectizationThreshold", "pCoreProjectMaxCharacters", "eCoreRecallMaxCharacters",
                    "permissionPolicy", "executionProfile"] {
            #expect(schemaText.contains(key), "\(key) 已不在 config schema 里，文档必须同步")
            #expect(docs.contains(key), "docs.html 未覆盖 \(key)")
        }
    }

    @Test("the security page does not promise an OS sandbox")
    func securityClaimsAreAccurate() throws {
        let body = try text("sdk.html")
        assertOnlyDenied(body, needles: ["完全 OS sandbox", "绝对无法读取", "任何越界"], page: "sdk.html")
        #expect(body.contains("OS-level syscall") || body.contains("OS 级"),
                "sdk.html 应明确说明不存在 syscall 级沙箱")
    }
}
