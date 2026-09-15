import Testing
import Foundation
@testable import LingXiCore
@testable import LingXiProtocol

@Suite("WebTools Suite")
struct WebToolsTests {
    @Test("WebHTMLCleaner removes noise scripts and preserves markdown headers")
    func testHTMLCleaner() {
        let sampleHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>OpenCode Documentation</title>
            <style>body { color: red; }</style>
            <script>console.log("noisy tracking script");</script>
        </head>
        <body>
            <header><nav>Navigation Bar</nav></header>
            <h1>OpenCode Zen</h1>
            <p>Welcome to <strong>OpenCode</strong> &amp; Zen models.</p>
            <ul>
                <li>High speed</li>
                <li>Low cost</li>
            </ul>
            <pre><code>let x = 42;</code></pre>
            <footer>Copyright 2026</footer>
        </body>
        </html>
        """

        let (title, markdown) = WebHTMLCleaner.clean(sampleHTML)
        #expect(title == "OpenCode Documentation")
        #expect(!markdown.contains("console.log"))
        #expect(!markdown.contains("Navigation Bar"))
        #expect(!markdown.contains("Copyright 2026"))
        #expect(markdown.contains("# OpenCode Zen"))
        #expect(markdown.contains("- High speed"))
        #expect(markdown.contains("let x = 42;"))
        #expect(markdown.contains("**OpenCode** & Zen models"))
    }

    @Test("WebFetchTool resource and capability definition")
    func testWebFetchDefinition() throws {
        let tool = WebFetchTool()
        #expect(tool.definition.id.rawValue == "web_fetch")
        #expect(tool.definition.capability.readOnly == true)
    }

    @Test("WebSearchTool definition and graceful fallback notice")
    func testWebSearchFallback() async throws {
        let tool = WebSearchTool()
        #expect(tool.definition.id.rawValue == "web_search")
        let args = "{\"query\": \"test query\"}"
        let profile = ExecutionProfile.workspace
        let output = try await tool.execute(arguments: args, profile: profile)
        #expect(output.contains("WebSearch Unavailable") || output.contains("Search Query"))
    }
}
