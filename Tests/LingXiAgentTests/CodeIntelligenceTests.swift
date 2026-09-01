import Foundation
import Testing
@testable import LingXiCore
import LingXiClient
import LingXiProtocol

private final class FixtureLSPTransport: @unchecked Sendable, LSPTransport {
    private let lock = NSLock()
    private var shouldFail = false
    func failNextRequest() { lock.lock(); shouldFail = true; lock.unlock() }
    func start() throws {}
    func stop() {}
    func notify(method: String, parameters: Data) throws {}
    func request(id: Int, method: String, parameters: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if shouldFail { shouldFail = false; throw LSPClientError.crashed }
        switch method {
        case "initialize": return Data("{}".utf8)
        case "workspace/symbol": return try JSONEncoder().encode([LSPWorkspaceSymbol(name: "Target", kind: 23, location: LSPLocation(uri: "file:///fixture/Sources/Target.swift", range: LSPRange(start: LSPPosition(line: 0, character: 7), end: LSPPosition(line: 0, character: 13))))])
        case "textDocument/definition", "textDocument/references": return try JSONEncoder().encode([LSPLocation(uri: "file:///fixture/Sources/Target.swift", range: LSPRange(start: LSPPosition(line: 0, character: 7), end: LSPPosition(line: 0, character: 13)))])
        case "textDocument/documentSymbol": return try JSONEncoder().encode([LSPDocumentSymbol(name: "Target", kind: 23, range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 16)), selectionRange: LSPRange(start: LSPPosition(line: 0, character: 7), end: LSPPosition(line: 0, character: 13)), children: nil)])
        case "textDocument/diagnostic": return try JSONEncoder().encode([LSPDiagnostic(range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 1)), message: "fixture", severity: 1)])
        default: return Data("[]".utf8)
        }
    }
}

struct CodeIntelligenceTests {
    @Test func lspProvidesSemanticResultsAndRecoversAfterCrash() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("struct Target {}\n", root, "Sources/Target.swift")
        let transport = FixtureLSPTransport()
        let intelligence = try makeIntelligence(root, lsp: LSPClient(transport: transport))

        let symbols = await intelligence.symbols("Target")
        let definition = await intelligence.definition(path: "Sources/Target.swift", line: 1, character: 8)
        let document = await intelligence.documentSymbols(path: "Sources/Target.swift")
        let diagnostics = await intelligence.diagnostics(path: "Sources/Target.swift")

        #expect(symbols.first?.source == "lsp")
        #expect(definition.first?.source == "lsp")
        #expect(document.first?.source == "lsp")
        #expect(diagnostics.map(\.message) == ["fixture"])
        transport.failNextRequest()
        _ = await intelligence.symbols("Target")
        #expect(await intelligence.status() == .degraded)
        #expect((await intelligence.symbols("Target")).first?.source == "lsp")
    }

    @Test func indexFallbackTracksMutationReferencesAndBoundedContext() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("struct Target {}\n", root, "Sources/Target.swift")
        try write("func use(_ value: Target) {}\n", root, "Sources/Use.swift")
        try write(String(repeating: "context token ", count: 80), root, "Docs/Context.md")
        let intelligence = try makeIntelligence(root, lsp: LSPClient(transport: nil))

        #expect((await intelligence.symbols("Target")).first?.source == "index")
        #expect((await intelligence.definition(path: "Sources/Use.swift", line: 1, character: 20)).contains { $0.path == "Sources/Target.swift" })
        #expect((await intelligence.references(path: "Sources/Target.swift", line: 1, character: 8)).contains { $0.path == "Sources/Use.swift" })
        let context = await intelligence.context("context token", maximumCharacters: 1_000)
        #expect(context.characters <= 1_000)
        #expect(context.bounded)

        try write("struct Replacement {}\n", root, "Sources/Target.swift")
        #expect((await intelligence.symbols("Target")).isEmpty)
        #expect((await intelligence.symbols("Replacement")).first?.path == "Sources/Target.swift")
    }

    @Test func repoMapAndUnknownLanguageDegradeWithoutFailure() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("print('hello')\n", root, "Scripts/hello.lua")
        let intelligence = try makeIntelligence(root, lsp: LSPClient(transport: nil))
        #expect((await intelligence.repoMap()).contains("lua: 1"))
        #expect(await intelligence.documentSymbols(path: "Scripts/hello.lua").isEmpty)
        #expect(await intelligence.diagnostics(path: "Scripts/hello.lua").isEmpty)
    }

    @Test func agentUsesBoundedCodeContextBeforeMutation() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("struct Existing {}\n", root, "Sources/Existing.swift")
        let workspace = try WorkspaceRoot(path: root.path)
        let scanner = ProjectScanner(root: root)
        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet(), projectCharacterBudget: 32_768)
        let intelligence = CodeIntelligence(workspace: workspace, scanner: scanner, pager: pager, lsp: LSPClient(transport: nil))
        let registry = ToolRegistry.builtin(workspace: workspace, contextPager: pager, scanner: scanner, codeIntelligence: intelligence)
        let contextCall = ToolCall(callID: ToolCallID("context"), toolID: ToolID("code_intelligence"), arguments: #"{"action":"context","query":"Existing","maximum_characters":512}"#)
        let writeCall = ToolCall(callID: ToolCallID("write"), toolID: ToolID("write_file"), arguments: #"{"path":"Sources/Result.swift","content":"struct Result {}"}"#)
        let provider = ScriptedFakeProvider(script: [
            [.toolCallStarted(callID: contextCall.callID, toolID: contextCall.toolID), .toolCallCompleted(contextCall), .completed(.toolCalls)],
            [.toolCallStarted(callID: writeCall.callID, toolID: writeCall.toolID), .toolCallCompleted(writeCall), .completed(.toolCalls)],
            [.textDelta("completed"), .completed(.stop)],
        ])
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")), workspaceRoot: workspace, permissionDecision: .allow, toolRegistry: registry)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let session = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: session, content: "Add Result")
        for try await _ in stream {}

        #expect(provider.recorder.requests.first?.tools.contains { $0.id == ToolID("code_intelligence") } == true)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Sources/Result.swift").path))
    }

    private func makeIntelligence(_ root: URL, lsp: LSPClient) throws -> CodeIntelligence {
        let workspace = try WorkspaceRoot(path: root.path)
        let scanner = ProjectScanner(root: root, minimumPageBytes: 32, maximumPageBytes: 64)
        return CodeIntelligence(workspace: workspace, scanner: scanner, pager: ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet(), projectCharacterBudget: 32_768), lsp: lsp)
    }
    private func project() throws -> URL { let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root }
    private func write(_ content: String, _ root: URL, _ path: String) throws { let url = root.appending(path: path); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(content.utf8).write(to: url) }
}
