import Foundation
import Testing

/// 公共 SDK 的接入面门禁（doc1 §19–§23、doc3 §2–§5、§74–§76）。
///
/// 两个 SDK 已经搬到自己的仓库。这里因此不再审「仓库里的 SDK 干不干净」——那句
/// 话由各自仓库负责——而是审三件只有主仓库能证明的事：
///
///   1. LingXiAgent 与第三方拿的是同一个公开构件：远程 `.package(url:, from:)`，
///      没有 path 依赖，也没有仓库内副本。
///   2. 被解析到的那份发布物本身仍然 Foundation-only：依赖方向没有偷偷长回来。
///   3. 官网展示的安装入口与 Package.swift 实际使用的入口一致。
struct PublicSDKConsumerGateTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static let modelSDKURL = "https://github.com/LingXiFox/LingXiModelSDK.git"
    private static let pluginSDKURL = "https://github.com/LingXiFox/LingXiPluginSDK.git"

    private static func manifest() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    }

    private static func read(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - 1. 主仓库通过公开分发消费

    @Test("LingXiAgent consumes both SDKs as public SwiftPM packages")
    func consumesPublicPackages() throws {
        let manifest = try Self.manifest()
        #expect(manifest.contains(".package(url: \"\(Self.modelSDKURL)\", from: \"0.1.0\")"),
                "模型目录 SDK 必须以公开 tag 形态接入")
        #expect(manifest.contains(".package(url: \"\(Self.pluginSDKURL)\", from: \"0.1.0\")"),
                "插件 SDK 必须以公开 tag 形态接入")
        // path 依赖会把「第三方能不能用」这件事悄悄变成「本机目录在不在」。
        #expect(!manifest.contains(".package(path:"),
                "正式清单不得提交本地 path 依赖；联合开发用 swift package edit，不改 committed 清单")
        #expect(!manifest.contains(".library(name: \"LingXiModelSDK\""),
                "本仓库不得再发布模型目录 SDK 的 product")
        #expect(!manifest.contains(".library(name: \"LingXiPluginSDK\""),
                "本仓库不得再发布插件 SDK 的 product")
    }

    @Test("consumers reference the external products, and no local copy survives")
    func externalProductsOnly() throws {
        let manifest = try Self.manifest()
        for dependency in ["LingXiModelSDK", "LingXiPluginSDK"] {
            let reference = ".product(name: \"\(dependency)\", package: \"\(dependency)\")"
            #expect(manifest.contains(reference), "\(dependency) 应作为外部 product 被引用")
        }
        let manager = FileManager.default
        for relative in ["Sources/LingXiModelSDK", "Sources/LingXiPluginSDK",
                         "Tests/LingXiModelSDKTests", "Tests/LingXiPluginSDKTests"] {
            #expect(!manager.fileExists(atPath: Self.repoRoot.appendingPathComponent(relative).path),
                    "\(relative) 仍然存在：SDK 会出现两份权威源码，必然漂移")
        }
    }

    // MARK: - 2. 解析到的发布物仍然守住边界

    /// 直接审被解析到的那份发布物：它才是第三方真正拿到的东西。
    private static func checkout(_ name: String) throws -> URL {
        let url = repoRoot.appendingPathComponent(".build/checkouts/\(name)")
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) else {
            throw NSError(domain: "gate", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "缺少 .build/checkouts/\(name)：先执行 swift package resolve 再跑门禁"])
        }
        return url
    }

    private static func swiftFiles(in directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { ($0 as? URL)?.pathExtension == "swift" ? $0 as? URL : nil }
    }

    @Test("the published SDKs stay Foundation-only in the resolved checkout")
    func publishedSDKsStayIndependent() throws {
        for sdk in ["LingXiModelSDK", "LingXiPluginSDK"] {
            let root = try Self.checkout(sdk)
            let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
            // 发布物自己的清单里不得出现任何 LingXi 运行时模块。
            for forbidden in ["LingXiAgent", "LingXiCore", "LingXiProtocol", "LingXiPlatform",
                              "LingXiClient", "LingXiApplication"] {
                #expect(!manifest.contains("\"\(forbidden)\""),
                        "\(sdk) 依赖了 \(forbidden)：公共 SDK 反向依赖运行时")
            }
            for url in Self.swiftFiles(in: root.appendingPathComponent("Sources")) {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                for line in text.split(separator: "\n") where line.hasPrefix("import ") {
                    let module = line.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
                    #expect(module == "Foundation" || module == "FoundationNetworking",
                            "\(sdk)/\(url.lastPathComponent) 导入了 \(module)")
                }
            }
        }
    }

    @Test("the plugin SDK checkout carries no Core implementation types")
    func publishedPluginSDKCarriesNoRuntime() throws {
        let root = try Self.checkout("LingXiPluginSDK")
        let forbidden = ["PermissionEngine", "ToolMutationCoordinator", "SessionStore",
                         "ContextCompactor", "ECoreObjectStore", "ModelProvider", "SessionRuntime"]
        for url in Self.swiftFiles(in: root.appendingPathComponent("Sources")) {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for name in forbidden {
                #expect(!text.contains(name), "插件 SDK 里出现了宿主实现 \(name)")
            }
        }
    }

    // MARK: - 3. 网站入口与实际依赖同源

    @Test("the model site advertises the same SDK source the manifest depends on")
    func siteAndManifestAgree() throws {
        let page = try Self.read("Server/models-site/public/index.html")
        let manifest = try Self.manifest()
        #expect(page.contains(Self.modelSDKURL), "官网必须给出真实包地址")
        #expect(page.contains("from: \"0.1.0\""), "官网必须给出真实最低版本")
        // 两处版本必须同源：网站教人 0.1.0，清单却要求 0.2.0，就是又一套真相。
        let advertised = Self.quotedVersion(in: page)
        let required = Self.quotedVersion(in: manifest)
        #expect(advertised == required,
                "官网展示的 SDK 版本 \(advertised ?? "nil") 与 Package.swift 要求的 \(required ?? "nil") 不一致")
        // 旧文案「本仓库 Package.swift 已发布该 library product」必须消失。
        #expect(!page.contains("本仓库"), "官网仍把公共 SDK 说成主仓库的 product")
    }

    private static func quotedVersion(in text: String) -> String? {
        guard let range = text.range(of: "from: \"") else { return nil }
        return String(text[range.upperBound...].prefix { $0 != "\"" })
    }

    // MARK: - 许可登记跟随源码搬家

    @Test("the license matrix no longer claims targets that left the repository")
    func matrixFollowedTheMove() throws {
        let matrix = try Self.read("LICENSE-MATRIX.md")
        for gone in ["| `LingXiModelSDK` |", "| `LingXiPluginSDK` |",
                    "| `LingXiModelSDKTests` |", "| `LingXiPluginSDKTests` |"] {
            #expect(!matrix.contains(gone), "\(gone) 已不在本仓库，许可矩阵必须撤行")
        }
        #expect(!matrix.contains("`Server/lingxi-registry/`"),
                "已删除的旧 Registry 路径不得留在许可矩阵里")
        // MIT 文件随两个 SDK 一起离开：本仓库不再有 MIT scope。
        #expect(!FileManager.default.fileExists(
            atPath: Self.repoRoot.appendingPathComponent("LICENSE-SDK").path),
            "没有 MIT-scoped target 了，LICENSE-SDK 应当删除")
    }
}
