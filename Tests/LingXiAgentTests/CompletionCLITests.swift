import Foundation
import Testing
@testable import LingXiCore

@Suite struct CompletionCLITests {
    @Test func completionZshGeneratesValidScript() {
        let script = CompletionCLI.run(arguments: ["completion", "zsh"])
        #expect(script.contains("#compdef lingxiagent"))
        #expect(script.contains("_lingxiagent()"))
        #expect(script.contains("--yolo"))
        #expect(script.contains("--model"))
        #expect(script.contains("auth:"))
        #expect(script.contains("mcp:"))
        #expect(script.contains("skills:"))
        #expect(script.contains("exec:"))
        #expect(script.contains("review:"))
        #expect(script.contains("doctor:"))
    }

    @Test func completionBashGeneratesValidScript() {
        let script = CompletionCLI.run(arguments: ["completion", "bash"])
        #expect(script.contains("_lingxiagent_completion()"))
        #expect(script.contains("complete -F _lingxiagent_completion lingxiagent"))
    }

    @Test func completionFishGeneratesValidScript() {
        let script = CompletionCLI.run(arguments: ["completion", "fish"])
        #expect(script.contains("complete -c lingxiagent"))
        #expect(script.contains("-l yolo"))
    }

    @Test func unsupportedShellReportsError() {
        let output = CompletionCLI.run(arguments: ["completion", "powershell"])
        #expect(output.contains("Unsupported shell 'powershell'"))
        #expect(output.contains("Supported shells: zsh, bash, fish"))
    }
}
