import Foundation
import Testing

/// 契约 doc3 §8 / §9:插件 SDK 必须是作者唯一需要装下的东西。
///
/// 一个只想写 LingXiAgent 插件的人,依赖应当是 `LingXiPluginSDK`,而不是整个
/// Agent 或它的协议层。这条门禁把「Foundation-only」从注释变成机器判据。
struct PluginSDKDependencyGateTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func parseGraph() throws -> [String: Set<String>] {
        let source = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        var graph: [String: Set<String>] = [:]
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let names = try NSRegularExpression(
            pattern: #"\.(?:executableTarget|testTarget|target|systemLibrary|plugin)\(\s*(?:/\*[^*]*\*/\s*)*name:\s*"([^"]+)""#)
        for m in names.matches(in: source, range: range) {
            if let r = Range(m.range(at: 1), in: source) { graph[String(source[r])] = [] }
        }
        let blocks = try NSRegularExpression(
            pattern: #"\.(?:executableTarget|testTarget|target|systemLibrary|plugin)\(\s*(?:/\*[^*]*\*/\s*)*name:\s*"([^"]+)"(?:[^d)]|d(?!ependencies:))*dependencies:\s*\[([^\]]*)\]"#,
            options: [.dotMatchesLineSeparators]
        )
        let items = try NSRegularExpression(pattern: #""([^"]+)""#)
        for m in blocks.matches(in: source, range: range) {
            guard let nameRange = Range(m.range(at: 1), in: source),
                  let depsRange = Range(m.range(at: 2), in: source) else { continue }
            let depsText = String(source[depsRange])
            let deps = items.matches(in: depsText, range: NSRange(depsText.startIndex..., in: depsText))
                .compactMap { match -> String? in
                    guard let r = Range(match.range(at: 1), in: depsText) else { return nil }
                    return String(depsText[r])
                }
            graph[String(source[nameRange])] = Set(deps)
        }
        return graph
    }

    @Test("LingXiPluginSDK depends on no other target in the repository")
    func pluginSDKIsDependencyFree() throws {
        let graph = try Self.parseGraph()
        guard graph["LingXiPluginSDK"] != nil else {
            Issue.record("Package.swift 里没有 LingXiPluginSDK target")
            return
        }
        // 直接依赖必须为空；曾经它挂着 LingXiProtocol，只因为一个文件里有一句
        // 没人用到的 import。
        #expect((graph["LingXiPluginSDK"] ?? []).isEmpty,
                "插件 SDK 不得依赖仓库内其它 target：\(graph["LingXiPluginSDK"]?.sorted() ?? [])")
    }

    @Test("the SDK sources import Foundation only")
    func importsStayMinimal() throws {
        let base = Self.repoRoot.appendingPathComponent("Sources/LingXiPluginSDK")
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            Issue.record("Sources/LingXiPluginSDK 不存在"); return
        }
        var files = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            files += 1
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") where line.hasPrefix("import ") {
                let module = line.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
                #expect(module == "Foundation",
                        "\(url.lastPathComponent) 导入了 \(module)；插件 SDK 只能依赖 Foundation")
            }
        }
        #expect(files >= 8, "插件 SDK 源文件数量异常，扫描可能什么都没做")
    }

    @Test("the plugin SDK does not grow agent runtime responsibilities")
    func runtimeTypesStayOutOfTheSDK() throws {
        // SDK 是作者接口，不是 Core 的切片。这些名字一旦出现在 SDK 源码里，
        // 就说明宿主实现被搬进了插件 SDK。
        let forbidden = ["PermissionEngine", "ToolMutationCoordinator", "SessionStore",
                         "ContextCompactor", "ECoreObjectStore", "ModelProvider", "SessionRuntime"]
        let base = Self.repoRoot.appendingPathComponent("Sources/LingXiPluginSDK")
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for name in forbidden {
                #expect(!text.contains(name), "\(url.lastPathComponent) 引用了宿主实现 \(name)")
            }
        }
    }
}
