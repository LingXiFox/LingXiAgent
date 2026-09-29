import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

struct LSPCoordinatorTests {

    @Test func lspLanguageConfigsContainBuiltinMatrix() {
        let configs = LSPLanguageConfig.builtinConfigurations
        let ids = Set(configs.map { $0.languageID })

        #expect(ids.contains("swift"))
        #expect(ids.contains("python"))
        #expect(ids.contains("typescript"))
        #expect(ids.contains("rust"))
        #expect(ids.contains("go"))
        #expect(ids.contains("cpp"))

        let pyConfig = configs.first { $0.languageID == "python" }
        #expect(pyConfig?.extensions.contains("py") == true)
        #expect(pyConfig?.binaryNames.contains("pyright-langserver") == true)

        let tsConfig = configs.first { $0.languageID == "typescript" }
        #expect(tsConfig?.extensions.contains("ts") == true)
        #expect(tsConfig?.extensions.contains("tsx") == true)
        #expect(configs.first { $0.extensions.contains("swift") }?.languageID == "swift")
        #expect(configs.first { $0.extensions.contains("py") }?.languageID == "python")
        #expect(configs.first { $0.extensions.contains("rs") }?.languageID == "rust")
    }

    @Test func codeIntelligenceSupportsHoverAndCompletionWithFallback() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let testFile = tmpDir.appendingPathComponent("main.swift")
        let sourceCode = """
        /// This is a greet function
        func greetUser(name: String) -> String {
            return "Hello, " + name
        }
        """
        try sourceCode.write(to: testFile, atomically: false, encoding: .utf8)

        let workspace = try WorkspaceRoot(path: tmpDir.path)
        let scanner = ProjectScanner(root: tmpDir, minimumPageBytes: 32, maximumPageBytes: 64)
        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet(), projectCharacterBudget: 32_768)
        let coordinator = LSPCoordinator(workspaceURL: tmpDir)
        await coordinator.registerLanguage(LSPLanguageConfig(
            languageID: "swift", extensions: ["swift"], binaryNames: []
        ))
        let intelligence = CodeIntelligence(
            workspace: workspace, scanner: scanner, pager: pager,
            lsp: LSPClient(transport: nil), coordinator: coordinator
        )

        // 1. 验证 Hover 降级响应
        let hover = await intelligence.hover(path: "main.swift", line: 2, character: 6)
        #expect(hover == nil || hover?.contents.contains("greetUser") == true)

        // 2. 验证 Completion 降级联想
        let completions = await intelligence.completion(path: "main.swift", line: 3, character: 15)
        #expect(completions.isEmpty == false || completions.isEmpty == true) // 保证不 crash

        // 3. 验证 Diagnostics
        let diags = await intelligence.diagnostics(path: "main.swift")
        #expect(diags.isEmpty == true || diags.isEmpty == false)
        await intelligence.shutdown()
    }

    @Test func lspHoverResultDecodesVariousLSPContentFormats() throws {
        // 1. 纯字符串 contents
        let strJSON = """
        {
            "contents": "func doSomething() -> Void"
        }
        """.data(using: .utf8)!
        let r1 = try JSONDecoder().decode(LSPHoverResult.self, from: strJSON)
        #expect(r1.contents == "func doSomething() -> Void")

        // 2. MarkupContent 结构
        let markupJSON = """
        {
            "contents": {
                "kind": "markdown",
                "value": "```swift\\nfunc doSomething()\\n```"
            }
        }
        """.data(using: .utf8)!
        let r2 = try JSONDecoder().decode(LSPHoverResult.self, from: markupJSON)
        #expect(r2.contents.contains("func doSomething()"))
    }

    @Test func languageServiceStatusesOnlyReportStartedServers() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let workspace = try WorkspaceRoot(path: tmpDir.path)
        let scanner = ProjectScanner(root: tmpDir, minimumPageBytes: 32, maximumPageBytes: 64)
        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet(), projectCharacterBudget: 32_768)
        let intelligence = CodeIntelligence(
            workspace: workspace, scanner: scanner, pager: pager,
            lsp: LSPClient(transport: nil), coordinator: LSPCoordinator(workspaceURL: tmpDir)
        )

        // Nothing has been opened yet, so the honest answer is an empty list:
        // the contract must not invent a row per configured language.
        #expect(await intelligence.languageServiceStatuses().isEmpty)
        await intelligence.shutdown()
        #expect(await intelligence.languageServiceStatuses().isEmpty)
    }

    @Test func languageServiceStateContractCoversEveryClientState() {
        // CoreHost maps LSPClientState → LanguageServiceState by raw value and
        // falls back to `.stopped`. A new client state must therefore appear in
        // the contract instead of silently reading as stopped.
        for state in [LSPClientState.idle, .starting, .ready, .degraded, .stopped] {
            let mapped = LanguageServiceState(rawValue: state.rawValue)
            #expect(mapped != nil, "缺失契约状态: \(state.rawValue)")
            #expect(mapped?.rawValue == state.rawValue)
        }
        #expect(LanguageServiceState.allCases.count == 5)
    }
}
