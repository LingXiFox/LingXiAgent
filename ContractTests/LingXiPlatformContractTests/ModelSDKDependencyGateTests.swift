import Foundation
import Testing

/// 契约 §26 / §37 的依赖方向门禁：`models.dev → models.json → LingXiModelSDK →
/// LingXiAgent`，单向。
///
/// SDK 是第三方查一个模型上下文窗口时唯一需要装下的东西。它一旦反向依赖 Agent
/// Runtime、Session、Tool、P/E Core 或任何前端，"公共模型目录 SDK" 就退化成了
/// Agent 的附属品，而这正是本轮要结束的旧状态。
struct ModelSDKDependencyGateTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ContractTests/LingXiPlatformContractTests
            .deletingLastPathComponent()   // ContractTests
            .deletingLastPathComponent()   // repo root
    }

    /// Same manifest parse as the ring-architecture gate: declared edges, not imports.
    private static func parseDependencyGraph() throws -> [String: Set<String>] {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        var graph: [String: Set<String>] = [:]
        let namePattern = #"\.(?:executableTarget|testTarget|target|systemLibrary|plugin)\(\s*(?:/\*[^*]*\*/\s*)*name:\s*"([^"]+)""#
        let nameRegex = try NSRegularExpression(pattern: namePattern)
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in nameRegex.matches(in: source, range: fullRange) {
            if let r = Range(match.range(at: 1), in: source) { graph[String(source[r])] = [] }
        }
        let targetRegex = try NSRegularExpression(
            pattern: #"\.(?:executableTarget|testTarget|target|systemLibrary|plugin)\(\s*(?:/\*[^*]*\*/\s*)*name:\s*"([^"]+)"(?:[^d)]|d(?!ependencies:))*dependencies:\s*\[([^\]]*)\]"#,
            options: [.dotMatchesLineSeparators]
        )
        let itemRegex = try NSRegularExpression(pattern: #""([^"]+)""#)
        for match in targetRegex.matches(in: source, range: fullRange) {
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let depsRange = Range(match.range(at: 2), in: source) else { continue }
            let targetName = String(source[nameRange])
            // Bind the slice once: an index taken from one copy of a String is not
            // valid for another, and `.description` makes a fresh copy per call.
            let depsText = String(source[depsRange])
            var deps: Set<String> = []
            for item in itemRegex.matches(in: depsText, range: NSRange(depsText.startIndex..., in: depsText)) {
                if let r = Range(item.range(at: 1), in: depsText) { deps.insert(String(depsText[r])) }
            }
            graph[targetName] = deps
        }
        return graph
    }

    private static func closure(from root: String, graph: [String: Set<String>]) -> Set<String> {
        var visited = Set<String>()
        var queue = Array(graph[root] ?? [])
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if visited.insert(current).inserted {
                queue.append(contentsOf: (graph[current] ?? []).filter { !visited.contains($0) })
            }
        }
        return visited
    }

    @Test("LingXiModelSDK depends on nothing in this repository")
    func sdkIsStandalone() throws {
        let graph = try Self.parseDependencyGraph()
        guard graph["LingXiModelSDK"] != nil else {
            Issue.record("Package.swift 里没有 LingXiModelSDK target：它会在门禁之外自由生长")
            return
        }
        let reached = Self.closure(from: "LingXiModelSDK", graph: graph)
        #expect(reached.isEmpty,
                "模型目录 SDK 不得依赖仓库内任何其它 target，否则会把它重新变成 Agent 的附属品：\(reached.sorted())")
    }

    @Test("the SDK sources import only Foundation")
    func sdkImportsStayMinimal() throws {
        let directory = Self.repoRoot.appendingPathComponent("Sources/LingXiModelSDK")
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            Issue.record("Sources/LingXiModelSDK 不存在"); return
        }
        var files = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            files += 1
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") where line.hasPrefix("import ") {
                let trimmed = line.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
                let module = String(trimmed.components(separatedBy: " ").first ?? trimmed)
                #expect(["Foundation", "FoundationNetworking"].contains(module),
                        "LingXiModelSDK 只能依赖 Foundation：\(url.lastPathComponent) import 了 \(module)")
            }
        }
        #expect(files > 0, "SDK 源文件缺失")
    }

    @Test("LingXiAgent consumes the catalog through the SDK, not through its own decoder")
    func coreConsumesThroughSDK() throws {
        let graph = try Self.parseDependencyGraph()
        #expect(graph["LingXiCore"]?.contains("LingXiModelSDK") == true,
                "Core 必须经 LingXiModelSDK 读 models.json")
        let client = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Sources/LingXiCore/Provider/Discovery/PublicModelCatalogClient.swift"),
            encoding: .utf8)
        #expect(client.contains("import LingXiModelSDK"))
        // 第二套 schema 理解不允许存在：Core 不再自己解 catalog JSON。
        #expect(!client.contains("JSONDecoder"),
                "Core 里不得再解一遍 models.json 的 schema")
        #expect(!client.contains("Codable"),
                "Core 里不得重述目录的数据结构")
    }
}
