import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

struct CodingToolContractTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func runtime(root: URL, decision: PermissionDecision = .allow, rules: [PermissionResourceRule] = []) throws -> ToolRuntime {
        ToolRuntime(
            registry: .builtin(workspace: try WorkspaceRoot(path: root.path)),
            permissions: PermissionEngine(resourceRules: rules, defaultDecision: decision)
        )
    }

    private func call(_ id: String, _ tool: String, _ arguments: String) -> ToolCall {
        ToolCall(callID: ToolCallID(id), toolID: ToolID(tool), arguments: arguments)
    }

    private func object(_ content: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
    }

    private func arguments(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    @Test func readRangePaginatesAndGuardsBinarySensitiveAndExternalPaths() async throws {
        let root = try fixture()
        let external = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
        try (1...5).map(String.init).joined(separator: "\n").write(to: root.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)
        try Data([0, 1]).write(to: root.appendingPathComponent("binary.bin"))
        try "secret".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "outside".write(to: external.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        let tools = try runtime(root: root)

        let page = await tools.execute(call("read", "read_file", #"{"path":"large.txt","start_line":2,"max_lines":2,"line_numbers":true}"#), sessionID: SessionID("s")) { _ in }
        let pageObject = try object(page.content)
        #expect(pageObject["truncated"] as? Bool == true)
        #expect(pageObject["nextLine"] as? Int == 4)
        #expect((pageObject["lines"] as? [[String: Any]])?.map { $0["number"] as? Int } == [2, 3])
        let binary = await tools.execute(call("binary", "read_file", #"{"path":"binary.bin","max_lines":1}"#), sessionID: SessionID("s")) { _ in }
        #expect(binary.error?.code == CoreError.Code.binaryFileUnsupported.rawValue)
        let sensitive = await tools.execute(call("sensitive", "read_file", #"{"path":".env"}"#), sessionID: SessionID("s")) { _ in }
        #expect(sensitive.error?.code == CoreError.Code.workspaceViolation.rawValue)
        let outsideRead = await tools.execute(call("outside", "read_file", #"{"path":"../outside.txt"}"#), sessionID: SessionID("s")) { _ in }
        #expect(outsideRead.error?.code == CoreError.Code.workspaceViolation.rawValue)
    }

    @Test func searchUsesGitignoreFiltersAndReportsTruncation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "ignored.txt\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "needle\n".write(to: root.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        try "needle\n".write(to: root.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)
        try "needle\n".write(to: root.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        let tools = try runtime(root: root)

        let glob = await tools.execute(call("glob", "glob", #"{"pattern":"*.txt","max_results":1}"#), sessionID: SessionID("s")) { _ in }
        let globPaths = try #require(JSONSerialization.jsonObject(with: Data(glob.content.utf8)) as? [String])
        #expect(globPaths == ["second.txt"])
        let grep = await tools.execute(call("grep", "grep", #"{"pattern":"needle","glob":"*.txt","max_results":10}"#), sessionID: SessionID("s")) { _ in }
        let paths = (try #require(JSONSerialization.jsonObject(with: Data(grep.content.utf8)) as? [[String: Any]])).compactMap { $0["path"] as? String }
        #expect(paths == ["second.txt", "visible.txt"])
    }

    @Test func mutationsArePreciseTransactionalAndConflictSafe() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try "one\none\n".write(to: file, atomically: true, encoding: .utf8)
        let tools = try runtime(root: root)
        let hash = sha256Hex("one\none\n")

        let duplicate = await tools.execute(call("duplicate", "edit_file", try arguments(["path": "file.txt", "old_string": "one", "new_string": "two", "expected_hash": hash])), sessionID: SessionID("s")) { _ in }
        #expect(duplicate.error?.code == CoreError.Code.ambiguousEdit.rawValue)
        let zero = await tools.execute(call("zero", "edit_file", try arguments(["path": "file.txt", "old_string": "missing", "new_string": "two", "expected_hash": hash])), sessionID: SessionID("s")) { _ in }
        #expect(zero.error?.code == CoreError.Code.contentChanged.rawValue)
        let writeFirst = try arguments(["path": "file.txt", "content": "first", "expected_hash": hash])
        let writeSecond = try arguments(["path": "file.txt", "content": "second", "expected_hash": hash])
        async let first = tools.execute(call("first", "write_file", writeFirst), sessionID: SessionID("s")) { _ in }
        async let second = tools.execute(call("second", "write_file", writeSecond), sessionID: SessionID("s")) { _ in }
        let results = await [first, second]
        #expect(results.filter(\.success).count == 1)
        #expect(results.contains { $0.error?.code == CoreError.Code.contentChanged.rawValue })

        let patch = await tools.execute(call("patch", "apply_patch", #"{"patch":"*** Begin Patch\n*** Add File: first.txt\n+first\n*** Add File: second.txt\n+second\n*** End Patch"}"#), sessionID: SessionID("s")) { _ in }
        #expect(patch.success)
        #expect(patch.changedFiles == ["first.txt", "second.txt"])
        ApplyPatchFailpoint.fail(after: 2)
        defer { ApplyPatchFailpoint.fail(after: nil) }
        let rollback = await tools.execute(call("rollback", "apply_patch", #"{"patch":"*** Begin Patch\n*** Update File: first.txt\n-first\n+changed\n*** Update File: second.txt\n-second\n+changed\n*** End Patch"}"#), sessionID: SessionID("s")) { _ in }
        #expect(!rollback.success)
        #expect(try String(contentsOf: root.appendingPathComponent("first.txt"), encoding: .utf8) == "first\n")
        let escaped = await tools.execute(call("escape", "apply_patch", #"{"patch":"*** Begin Patch\n*** Add File: ../escape.txt\n+x\n*** End Patch"}"#), sessionID: SessionID("s")) { _ in }
        #expect(escaped.error?.code == CoreError.Code.workspaceViolation.rawValue)
    }

    @Test func permissionsAndShellDiagnosticsAreResourceScoped() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "original".write(to: root.appendingPathComponent("protected.txt"), atomically: true, encoding: .utf8)
        let tools = try runtime(root: root, rules: [
            PermissionResourceRule(action: .edit, resourcePattern: "*/protected.txt", decision: .deny),
            PermissionResourceRule(action: .shell, resourcePattern: "*blocked*", decision: .deny)
        ])
        let write = await tools.execute(call("write", "write_file", #"{"path":"protected.txt","content":"changed","overwrite":true}"#), sessionID: SessionID("s")) { _ in }
        #expect(write.error?.code == CoreError.Code.permissionDenied.rawValue)
        let shell = await tools.execute(call("shell", "shell", #"{"command":"printf out; printf err >&2; exit 7"}"#), sessionID: SessionID("s")) { _ in }
        #expect(shell.exitCode == 7)
        #expect(shell.diagnostics?.stdout == "out")
        #expect(shell.diagnostics?.stderr == "err")
        let denied = await tools.execute(call("deny", "shell", #"{"command":"printf blocked"}"#), sessionID: SessionID("s")) { _ in }
        #expect(denied.error?.code == CoreError.Code.permissionDenied.rawValue)
    }
}
