import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

struct CodingToolScenarioTests {
    private func runGit(_ arguments: [String], in root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: PortableFixture.git())
        process.arguments = arguments
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func call(_ id: String, _ tool: String, _ arguments: String) -> ToolCall {
        ToolCall(callID: ToolCallID(id), toolID: ToolID(tool), arguments: arguments)
    }

    private var shCommand: String? {
        #if os(Windows)
        let candidates = [
            "sh",
            #"C:\Program Files\Git\bin\sh.exe"#,
            #"C:\Program Files\Git\usr\bin\sh.exe"#,
            #"C:\Program Files (x86)\Git\bin\sh.exe"#
        ]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c) || LingXiPlatform.process.resolveExecutable(named: c, customSearchPaths: nil) != nil {
                return c.contains(" ") ? "\"\(c)\"" : c
            }
        }
        return nil
        #else
        return "sh"
        #endif
    }

    @Test func localCodingFixtureRunsSearchPatchTestRecoveryAndDiff() async throws {
        #if os(Windows)
        guard let sh = shCommand else { return }
        #else
        let sh = "sh"
        #endif
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "#!/bin/sh\nexpr \"$1\" - \"$2\"\n".write(to: root.appendingPathComponent("calculator.sh"), atomically: false, encoding: .utf8)
        try "#!/bin/sh\ntest \"$(sh calculator.sh 2 3)\" = 5\n".write(to: root.appendingPathComponent("test.sh"), atomically: false, encoding: .utf8)
        try runGit(["init"], in: root)
        try runGit(["config", "user.email", "fixture@example.invalid"], in: root)
        try runGit(["config", "user.name", "P15 Fixture"], in: root)
        try runGit(["add", "."], in: root)
        try runGit(["commit", "-m", "fixture"], in: root)

        let runtime = ToolRuntime(
            registry: .builtin(workspace: try WorkspaceRoot(path: root.path)),
            permissions: PermissionEngine(defaultDecision: .allow)
        )
        let grep = await runtime.execute(call("grep", "grep", #"{"pattern":" - ","glob":"*.sh"}"#), sessionID: SessionID("scenario")) { _ in }
        #expect(grep.success)
        #expect(grep.content.contains("calculator.sh"))
        let read = await runtime.execute(call("read", "read_file", #"{"path":"calculator.sh"}"#), sessionID: SessionID("scenario")) { _ in }
        #expect(read.content.contains(" - "))

        let wrongPatch = await runtime.execute(call("patch-wrong", "apply_patch", #"{"patch":"*** Begin Patch\n*** Update File: calculator.sh\n-expr \"$1\" - \"$2\"\n+expr \"$1\" * \"$2\"\n*** End Patch"}"#), sessionID: SessionID("scenario")) { _ in }
        #expect(wrongPatch.success)
        let failed = await runtime.execute(call("test-fail", "shell", #"{"command":""# + sh + #" test.sh"}"#), sessionID: SessionID("scenario")) { _ in }
        #expect(!failed.success)
        #expect(failed.exitCode != 0)

        let correctPatch = await runtime.execute(call("patch-correct", "apply_patch", #"{"patch":"*** Begin Patch\n*** Update File: calculator.sh\n-expr \"$1\" * \"$2\"\n+expr \"$1\" + \"$2\"\n*** End Patch"}"#), sessionID: SessionID("scenario")) { _ in }
        #expect(correctPatch.success)
        let passed = await runtime.execute(call("test-pass", "shell", #"{"command":""# + sh + #" test.sh"}"#), sessionID: SessionID("scenario")) { _ in }
        #expect(passed.success)
        let diff = await runtime.execute(call("diff", "git", #"{"action":"diff"}"#), sessionID: SessionID("scenario")) { _ in }
        #expect(diff.success)
        #expect(diff.diagnostics?.stdout.contains("+expr \"$1\" + \"$2\"") == true)
    }
}
