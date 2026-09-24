import Foundation
import Testing

/// Machine-enforced boundary gate for the repository's Ring Architecture.
///
/// Parses `Package.swift` dependency closures directly (not import text) and asserts:
/// 1. Reachable targets from `LingXiCore`, `LingXiProtocol`, `LingXiClient`, and
///    `LingXiApplication` NEVER include UI framework targets (`LingXiFrontendKit`,
///    `Apps/**`, etc.).
/// 2. `LingXiTUI` NEVER depends on `LingXiCore` (transitive closure).
///
/// Exceptions must be explicitly declared in the allow-list with a mandatory reason.
struct CoreDependencyGraphGateTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ContractTests/LingXiPlatformContractTests
            .deletingLastPathComponent() // ContractTests
            .deletingLastPathComponent() // Repo root
    }

    struct ArchitectureException: Hashable {
        let fromTarget: String
        let toTarget: String
        let reason: String
    }

    /// Explicit allow-list for architecture exceptions. Each exception requires a concrete rationale.
    private static let allowList: [ArchitectureException] = [
        // lingxiagent-ops links Core for backend administration and diagnostics commands (doctor, auth, mcp, smoke).
        ArchitectureException(
            fromTarget: "lingxiagent-ops",
            toTarget: "LingXiCore",
            reason: "Operations and diagnostics CLI links Core directly for offline admin commands"
        )
    ]


    /// Target and its declared dependency target names.
    private static func parseDependencyGraph() throws -> [String: Set<String>] {
        let packageURL = repoRoot.appendingPathComponent("Package.swift")
        let source = try String(contentsOf: packageURL, encoding: .utf8)

        var graph: [String: Set<String>] = [:]
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)

        // 1. Discover all target names
        let namePattern = #"\.(?:executableTarget|testTarget|target|systemLibrary|plugin)\(\s*(?:/\*[^*]*\*/\s*)*name:\s*"([^"]+)""#
        let nameRegex = try NSRegularExpression(pattern: namePattern)
        for m in nameRegex.matches(in: source, range: fullRange) {
            if let r = Range(m.range(at: 1), in: source) {
                graph[String(source[r])] = []
            }
        }

        // 2. Discover target blocks with dependencies: [...]
        let targetRegex = try NSRegularExpression(
            pattern: #"\.(?:executableTarget|testTarget|target|systemLibrary|plugin)\(\s*(?:/\*[^*]*\*/\s*)*name:\s*"([^"]+)"(?:[^d)]|d(?!ependencies:))*dependencies:\s*\[([^\]]*)\]"#,
            options: [.dotMatchesLineSeparators]
        )

        let matches = targetRegex.matches(in: source, range: fullRange)
        let depItemRegex = try NSRegularExpression(pattern: #""([^"]+)""#)

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let depsRange = Range(match.range(at: 2), in: source) else {
                continue
            }
            let targetName = String(source[nameRange])
            let depsString = String(source[depsRange])

            var deps = Set<String>()
            let itemMatches = depItemRegex.matches(in: depsString, range: NSRange(depsString.startIndex..<depsString.endIndex, in: depsString))
            for item in itemMatches {
                if let r = Range(item.range(at: 1), in: depsString) {
                    let depName = String(depsString[r])
                    deps.insert(depName)
                }
            }
            graph[targetName] = deps
        }

        return graph
    }

    /// Computes full transitive closure of reachable targets for a given root.
    private static func computeClosure(from root: String, graph: [String: Set<String>]) -> Set<String> {
        var visited = Set<String>()
        var queue = Array(graph[root] ?? [])

        while !queue.isEmpty {
            let current = queue.removeFirst()
            if visited.insert(current).inserted {
                if let nextLevel = graph[current] {
                    for dep in nextLevel where !visited.contains(dep) {
                        queue.append(dep)
                    }
                }
            }
        }
        return visited
    }

    @Test("Core and infrastructure layers never reach frontend UI targets")
    func coreNeverReachesFrontendKit() throws {
        let graph = try Self.parseDependencyGraph()
        let forbiddenTargets: Set<String> = [
            "LingXiFrontendKit",
            "LingXiTUI",
            "LingXiTUIApp",
            "LingXiTUIComponents"
        ]

        let coreRoots = ["LingXiProtocol", "LingXiPlatform", "LingXiCore", "LingXiClient", "LingXiApplication"]

        for root in coreRoots {
            guard graph[root] != nil else {
                Issue.record("Target \(root) not found in dependency graph")
                continue
            }
            let closure = Self.computeClosure(from: root, graph: graph)
            let violated = closure.intersection(forbiddenTargets)
            #expect(violated.isEmpty, "Architecture violation: \(root) transitively reaches UI target(s): \(violated.sorted())")
        }
    }

    @Test("LingXiTUI never transitively depends on LingXiCore")
    func tuiNeverDependsOnCore() throws {
        let graph = try Self.parseDependencyGraph()
        let closure = Self.computeClosure(from: "LingXiTUI", graph: graph)
        #expect(!closure.contains("LingXiCore"), "Architecture violation: LingXiTUI must not depend on LingXiCore; communication must happen exclusively via LingXiClient / IPC")
    }

    @Test("LingXiApplication never transitively depends on LingXiCore")
    func appNeverDependsOnCore() throws {
        let graph = try Self.parseDependencyGraph()
        let closure = Self.computeClosure(from: "LingXiApplication", graph: graph)
        #expect(!closure.contains("LingXiCore"), "Architecture violation: LingXiApplication must not depend on LingXiCore")
    }

    @Test("all architecture exceptions have non-empty valid reasons")
    func allowListReasonsAreValid() {
        for exc in Self.allowList {
            #expect(!exc.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Exception \(exc.fromTarget) -> \(exc.toTarget) missing reason")
        }
    }
}
