import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient
#if canImport(SwiftUI)
@testable import LingXiFrontendKit
import LingXiApplication
#endif

/// Agent file mutations are shown from Core's own before/after capture, not from Git.
///
/// Real smoke test: the agent created `~/Desktop/primes.cpp` and the GUI showed no diff — the
/// Desktop is not a repository, and `git diff` would not list an untracked file anyway.
@Suite("File mutation diff", .serialized)
struct FileMutationDiffTests {

    // MARK: - 16–18. The diff itself

    @Test("a created file is all additions")
    func createIsAllGreen() {
        let diff = FileMutationDiffer.diff(path: "primes.cpp", before: nil, after: "int main() {\n  return 0;\n}\n")
        #expect(diff.kind == .created)
        #expect(diff.additions == 3 && diff.deletions == 0)
        #expect(diff.unifiedDiff.hasPrefix("--- /dev/null\n+++ b/primes.cpp\n@@ -0,0 +1,3 @@"))
        let body = diff.unifiedDiff.split(separator: "\n").dropFirst(3)
        #expect(body.allSatisfy { $0.hasPrefix("+") }, "新文件只能有绿色行")
    }

    @Test("an edit shows the removed line red and the new line green, with context")
    func editIsRedAndGreen() {
        let before = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let after = before.replacingOccurrences(of: "line 5\n", with: "line five\n")
        let diff = FileMutationDiffer.diff(path: "a.txt", before: before, after: after)
        #expect(diff.kind == .modified)
        #expect(diff.additions == 1 && diff.deletions == 1)
        #expect(diff.unifiedDiff.contains("\n-line 5\n+line five\n"))
        #expect(diff.unifiedDiff.contains("@@ -2,7 +2,7 @@"), "\(diff.unifiedDiff)")
    }

    @Test("a deleted file is all deletions")
    func deleteIsAllRed() {
        let diff = FileMutationDiffer.diff(path: "old.txt", before: "a\nb\n", after: nil)
        #expect(diff.kind == .deleted)
        #expect(diff.additions == 0 && diff.deletions == 2)
        #expect(diff.unifiedDiff.contains("+++ /dev/null"))
        #expect(diff.unifiedDiff.split(separator: "\n").dropFirst(3).allSatisfy { $0.hasPrefix("-") })
    }

    // MARK: - 19–21. Through Core, with and without Git

    private func workspace(git: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lx-mut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if git { try run(["git", "init", "-q"], in: url) }
        return url
    }

    @discardableResult
    private func run(_ argv: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func toolStep(_ id: String, _ tool: String, _ arguments: [String: Any]) throws -> [ModelEvent] {
        let json = String(data: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), encoding: .utf8)!
        let call = ToolCall(callID: ToolCallID(id), toolID: ToolID(tool), arguments: json)
        return [.toolCallStarted(callID: call.callID, toolID: call.toolID), .toolCallCompleted(call), .completed(.toolCalls)]
    }

    /// Runs the scripted steps and returns every persisted tool result in order.
    private func results(in root: URL, steps: [[ModelEvent]]) async throws -> [ToolResult] {
        let provider = ScriptedFakeProvider(script: steps + [[.textDelta("done"), .completed(.stop)]])
        let host = try CoreHost(
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake-model")),
            workspaceRoot: try WorkspaceRoot(path: root.path),
            permissionDecision: .allow,
            interactive: false
        )
        await host.start()
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: sessionID, content: "write") {}
        let snapshot = try await client.session(sessionID)
        return snapshot.messages.flatMap(\.parts).compactMap { part in
            if case let .toolResult(result) = part { return result } else { return nil }
        }
    }

    @Test("create, edit and delete in a non-Git workspace each carry a real diff")
    func nonGitWorkspaceShowsMutations() async throws {
        let root = try workspace(git: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let results = try await results(in: root, steps: [
            try toolStep("w1", "write_file", ["path": "primes.cpp", "content": "int main() {\n  return 0;\n}\n"]),
            try toolStep("e1", "edit_file", ["path": "primes.cpp", "old_string": "return 0;", "new_string": "return 1;", "overwrite": true]),
            try toolStep("p1", "apply_patch", ["patch": "*** Begin Patch\n*** Delete File: primes.cpp\n*** End Patch"]),
        ])
        #expect(results.count == 3, "\(results.map { "\($0.toolName ?? "") \($0.success) \($0.error?.message ?? "") \($0.content.prefix(120))" })")
        let created = try #require(results.first?.fileMutations.first)
        #expect(created.kind == .created && created.path == "primes.cpp" && created.additions == 3)
        let edited = try #require(results.dropFirst().first?.fileMutations.first)
        #expect(edited.kind == .modified && edited.additions == 1 && edited.deletions == 1)
        #expect(edited.unifiedDiff.contains("-  return 0;") && edited.unifiedDiff.contains("+  return 1;"))
        let deleted = try #require(results.last?.fileMutations.first)
        #expect(deleted.kind == .deleted && deleted.deletions == 3)
    }

    @Test("in a Git workspace the new file gets a diff and the index is not touched")
    func gitWorkspaceIndexUntouched() async throws {
        let root = try workspace(git: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let results = try await results(in: root, steps: [
            try toolStep("w1", "write_file", ["path": "primes.cpp", "content": "int main() { return 0; }\n"]),
        ])
        #expect(results.first?.fileMutations.count == 1, "一次变更只应产生一条 diff")
        #expect(results.first?.fileMutations.first?.kind == .created)
        #expect(try run(["git", "diff", "--cached", "--name-only"], in: root).isEmpty, "不得为了显示 diff 修改 git index")
        #expect(try run(["git", "status", "--porcelain"], in: root).contains("?? primes.cpp"), "新文件应保持 untracked")
    }

    @Test("a read-only tool and a failed write carry no mutation")
    func noMutationWithoutChange() async throws {
        let root = try workspace(git: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try "same\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let results = try await results(in: root, steps: [
            try toolStep("r1", "read_file", ["path": "a.txt"]),
            try toolStep("w1", "write_file", ["path": "a.txt", "content": "same\n", "overwrite": "x"]),
        ])
        #expect(results.allSatisfy { $0.fileMutations.isEmpty })
    }

    #if canImport(SwiftUI)
    /// 20: the GUI projects exactly one diff row per mutation, from Core, with stable ids.
    @Test("the timeline projects one diff row per mutation and reuses the diff item kind")
    func projectionEmitsDiffRows() {
        let diff = FileMutationDiffer.diff(path: "primes.cpp", before: nil, after: "x\n")
        var tool = ToolNode(callID: ToolCallID("w1"), toolName: "write_file", argumentsJSON: #"{"path":"primes.cpp"}"#, phase: .completed)
        tool.result = ToolResultSnapshot(callID: ToolCallID("w1"), toolName: "write_file", success: true, summary: "", fileMutations: [diff])
        let node = TimelineNode(id: .tool(ToolCallID("w1"), modelStepID: nil), kind: .tool(tool))
        let first = CoreProjection.mutationDiffs(for: node)
        let again = CoreProjection.mutationDiffs(for: node)
        #expect(first.count == 1)
        #expect(first.map(\.id) == again.map(\.id), "重复投影不得产生新条目")
        guard case let .diff(path, content)? = first.first?.kind else {
            Issue.record("应复用现有 .diff 条目，从而由 FileDiffRow 渲染")
            return
        }
        #expect(path == "primes.cpp" && content == diff.unifiedDiff)
    }
    #endif
}
