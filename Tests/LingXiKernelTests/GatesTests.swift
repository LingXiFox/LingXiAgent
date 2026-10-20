import Foundation
import LingXiKernel
import Testing

private let repoRoot: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}()

private let kernelSourceDirectory = repoRoot.appendingPathComponent("Sources/LingXiKernel")

private func kernelSources() throws -> [(url: URL, text: String)] {
    let files = try FileManager.default.contentsOfDirectory(
        at: kernelSourceDirectory,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" }
    return try files.map { (url: $0, text: try String(contentsOf: $0, encoding: .utf8)) }
}

@Test("L0 the kernel target declares no dependencies")
func L0_kernelHasNoDependencies() throws {
    let manifest = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    let line = try #require(
        manifest.split(separator: "\n").first { $0.contains(".target(name: \"LingXiKernel\"") }
    )
    #expect(!line.contains("dependencies"))
}

@Test("L0 the license matrix registers exactly the declared targets")
func L0_licenseMatrixMatchesDeclaredTargets() throws {
    let manifest = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    let matrix = try String(contentsOf: repoRoot.appendingPathComponent("LICENSE-MATRIX.md"), encoding: .utf8)

    let declared = matches(in: manifest, pattern: "(?:target|executableTarget|testTarget)\\(name: \"([^\"]+)\"")

    let table = matrix.components(separatedBy: "## SPM targets")[1].components(separatedBy: "\n---")[0]
    let registered = matches(in: table, pattern: "^\\| `([^`]+)`")

    #expect(declared == registered, "Package.swift and LICENSE-MATRIX.md disagree: \(declared.symmetricDifference(registered))")
}

private func matches(in text: String, pattern: String) -> Set<String> {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return Set(
        expression.matches(in: text, range: range).compactMap { match in
            guard let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    )
}

@Test("L0 the kernel contains no provider, tool or plugin implementation")
func L0_kernelHasNoVendorOrLoadingCode() throws {
    let forbidden = [
        "Anthropic", "OpenAI", "DeepSeek", "Gemini", "Mistral",
        "URLSession", "dlopen", "dlsym", "@_cdecl", "LingXiPlugin_Init",
        "SQLite", "SwiftUI", "AppKit",
    ]
    for (url, text) in try kernelSources() {
        for token in forbidden {
            #expect(!text.contains(token), "\(url.lastPathComponent) must not mention \(token)")
        }
    }
}

@Test("L0 the kernel only reaches outside itself through its own ports")
func L0_kernelImportsOnlyFoundation() throws {
    for (_, text) in try kernelSources() {
        let imports = text.split(separator: "\n").filter { $0.hasPrefix("import ") }
        for line in imports {
            #expect(line == "import Foundation", "unexpected import: \(line)")
        }
    }
}

@Test("QA-013 with no provider the run reports guidance without touching the journal")
func QA_013_emptyCoreDoesNotPolluteJournal() async throws {
    let log = try DurableEventLog(sink: MemorySink())
    let runs = RunRegistry()
    let store = SessionStore()
    let loop = AgentLoop(
        router: ModelRouter(),
        toolRegistry: ToolRegistry(),
        executor: RecordingExecutor(),
        log: log,
        runs: runs,
        store: store,
        instructions: "instructions"
    )
    let request = RunRequest(
        sessionID: "boot",
        turnID: "boot",
        runID: "run-boot",
        executionID: "exec-boot",
        model: "any-model",
        prompt: "hello"
    )

    let result = await loop.run(request, policy: LoopPolicy())

    #expect(result.status == .failed)
    #expect(result.cause == .runtimeFailure)
    #expect(result.detail?.contains("No provider plugin is active") == true)
    #expect(!result.terminalCommitted)
    // A core without a provider must not write a meaningless failed run into the journal.
    #expect(await log.recordCount == 0)
    #expect(try await log.events().isEmpty)
    #expect(await runs.record(request.runID) == nil)
    #expect(await store.sessionIDs().isEmpty)
}

@Test("CTX-018 structural gate: the loop revalidates the budgeted request before sending it")
func CTX_018_postBudgetValidationGatePresent() throws {
    let agentLoop = try String(
        contentsOf: kernelSourceDirectory.appendingPathComponent("AgentLoop.swift"),
        encoding: .utf8
    )
    #expect(
        agentLoop.contains("try ContextRequestValidator.validate(plan.selected, placement: capabilities.toolResultPlacement)"),
        "the post-budget protocol gate must stay in the request path; it is defense-in-depth against an invalid plan"
    )
}
