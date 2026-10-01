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

    /// A forbidden target reached from `root` is excused only when the root itself declares the
    /// exception. Without this the allow-list is decoration: an entry can exist, be validated for
    /// a reason string, and still never be consulted.
    private static func excuse(forbidden: String, from root: String) -> ArchitectureException? {
        allowList.first { $0.fromTarget == root && $0.toTarget == forbidden }
    }

    /// Removes the excused targets from a violation set and reports which excuses were consumed.
    private static func filterViolations(_ reached: Set<String>, forbidden: Set<String>, root: String) -> Set<String> {
        var violations = reached.intersection(forbidden)
        violations = violations.filter { excuse(forbidden: $0, from: root) == nil }
        return violations
    }

    @Test("every declared exception corresponds to a real dependency edge")
    func declaredExceptionsAreRealEdges() throws {
        // An exception whose edge no longer exists is worse than no exception: it claims to govern
        // a breach that has already been removed, and the next reader trusts a dead allowance.
        let graph = try Self.parseDependencyGraph()
        for exc in Self.allowList {
            let deps = graph[exc.fromTarget]
            #expect(deps != nil, "Exception declares unknown target \(exc.fromTarget)")
            #expect(deps?.contains(exc.toTarget) == true,
                    "Stale exception: \(exc.fromTarget) no longer depends directly on \(exc.toTarget)")
        }
    }

    @Test("the macOS frontend never reaches Core or another frontend")
    func frontendNeverReachesCoreOrAnotherFrontend() throws {
        // The boundary that actually matters for the GUI is that business state arrives through the
        // client contract, not by linking the engine. `LingXiFrontendKit` is declared only under
        // `#if os(macOS)` in Package.swift, so a missing target here would silently skip the gate.
        let graph = try Self.parseDependencyGraph()
        guard graph["LingXiFrontendKit"] != nil else {
            Issue.record("Target LingXiFrontendKit not found in dependency graph; the GUI would be outside this gate")
            return
        }
        let forbidden: Set<String> = [
            "LingXiCore",
            "LingXiTUI",
            "LingXiTUIApp",
            "LingXiTUIComponents",
            "LingXiWebUI"
        ]
        let closure = Self.computeClosure(from: "LingXiFrontendKit", graph: graph)
        let violated = Self.filterViolations(closure, forbidden: forbidden, root: "LingXiFrontendKit")
        #expect(violated.isEmpty,
                "Architecture violation: LingXiFrontendKit transitively reaches \(violated.sorted()); GUI state must come from the client contract")
    }

    @Test("the macOS frontend does not reach for the platform layer itself")
    func frontendDoesNotDependOnPlatformDirectly() throws {
        // LingXiFrontendKit -> LingXiApplication -> LingXiPlatform is the accepted shape: the
        // assembly layer legitimately needs host services and the GUI inherits the link without
        // using a single platform symbol. What must stay forbidden is the GUI depending on the
        // platform layer directly, which would let view code call host APIs around the contract.
        let graph = try Self.parseDependencyGraph()
        let direct = graph["LingXiFrontendKit"] ?? []
        #expect(!direct.contains("LingXiPlatform"),
                "Architecture violation: LingXiFrontendKit depends on LingXiPlatform directly; host services belong to LingXiApplication")
        #expect(!direct.contains("LingXiCore"),
                "Architecture violation: LingXiFrontendKit depends on LingXiCore directly")
    }

    @Test("Core and infrastructure layers never reach frontend UI targets")
    func coreNeverReachesFrontendKit() throws {
        let graph = try Self.parseDependencyGraph()
        let forbiddenTargets: Set<String> = [
            "LingXiFrontendKit",
            "LingXiTUI",
            "LingXiTUIApp",
            "LingXiTUIComponents",
            "LingXiWebUI"
        ]

        let coreRoots = ["LingXiProtocol", "LingXiPlatform", "LingXiCore", "LingXiClient", "LingXiApplication"]

        for root in coreRoots {
            guard graph[root] != nil else {
                Issue.record("Target \(root) not found in dependency graph")
                continue
            }
            let closure = Self.computeClosure(from: root, graph: graph)
            let violated = Self.filterViolations(closure, forbidden: forbiddenTargets, root: root)
            #expect(violated.isEmpty, "Architecture violation: \(root) transitively reaches UI target(s): \(violated.sorted())")
        }
    }

    @Test("LingXiWebUI reaches the runtime only through the shared frontend contract")
    func webUINeverReachesCore() throws {
        let graph = try Self.parseDependencyGraph()
        guard graph["LingXiWebUI"] != nil else {
            Issue.record("Target LingXiWebUI not found in dependency graph: the web front end would be outside this gate")
            return
        }
        let closure = Self.computeClosure(from: "LingXiWebUI", graph: graph)
        #expect(Self.filterViolations(closure, forbidden: ["LingXiCore"], root: "LingXiWebUI").isEmpty,
                "Architecture violation: LingXiWebUI transitively reaches LingXiCore instead of the Application contract")
        #expect(Self.filterViolations(closure, forbidden: ["LingXiTUI", "LingXiFrontendKit"], root: "LingXiWebUI").isEmpty,
                "Architecture violation: a front end must not depend on another front end: \(closure.sorted())")
    }

    @Test("LingXiTUI never transitively depends on LingXiCore")
    func tuiNeverDependsOnCore() throws {
        let graph = try Self.parseDependencyGraph()
        let closure = Self.computeClosure(from: "LingXiTUI", graph: graph)
        #expect(Self.filterViolations(closure, forbidden: ["LingXiCore"], root: "LingXiTUI").isEmpty,
                "Architecture violation: LingXiTUI must not depend on LingXiCore; communication must happen exclusively via LingXiClient / IPC")
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
