import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

private actor PermissionCapture {
    private var request: PermissionRequest?

    func record(_ request: PermissionRequest) { self.request = request }

    func wait() async -> PermissionRequest {
        while request == nil { await Task.yield() }
        return request!
    }
}

struct ToolRuntimeTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func runtime(root: URL, decision: PermissionDecision = .allow) throws -> ToolRuntime {
        let workspace = try WorkspaceRoot(path: root.path)
        return ToolRuntime(registry: .builtin(workspace: workspace), permissions: PermissionEngine(defaultDecision: decision))
    }

    private func call(_ tool: String, _ path: String = "README.md") -> ToolCall {
        ToolCall(callID: ToolCallID("call-1"), toolID: ToolID(tool), arguments: #"{"path":""# + path + #""}"#)
    }

    @Test func definitionsAndRegistryAreStable() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try runtime(root: root)
        #expect(runtime.definitions.map(\.id.rawValue) == ["list_directory", "read_file"])
    }

    @Test func unknownToolAndInvalidArgumentsAreNormalized() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try runtime(root: root)
        let unknown = await runtime.execute(
            ToolCall(callID: ToolCallID("x"), toolID: ToolID("unknown"), arguments: "{}"), sessionID: SessionID("s")
        ) { _ in }
        #expect(unknown.error?.code == CoreError.Code.toolNotFound.rawValue)
        let invalid = await runtime.execute(
            ToolCall(callID: ToolCallID("x"), toolID: ToolID("read_file"), arguments: "not-json"), sessionID: SessionID("s")
        ) { _ in }
        #expect(invalid.error?.code == CoreError.Code.toolArgumentInvalid.rawValue)
    }

    @Test func readFileAndListDirectoryStayInsideWorkspace() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "LingXiAgent".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        let runtime = try runtime(root: root)

        let read = await runtime.execute(call("read_file"), sessionID: SessionID("s")) { _ in }
        #expect(read == ToolResult(callID: ToolCallID("call-1"), success: true, content: "LingXiAgent"))

        let listed = await runtime.execute(call("list_directory", "."), sessionID: SessionID("s")) { _ in }
        #expect(listed.success)
        #expect(listed.content.split(separator: "\n").map(String.init) == ["README.md\tfile\t11", "a.txt\tfile\t1", "dir\tdirectory\t-"])
    }

    @Test func readFileNormalizesErrorsAndRejectsEscapes() async throws {
        let root = try fixture()
        let outside = try fixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: ReadFileTool.maximumBytes + 1).write(to: root.appendingPathComponent("large.txt"))
        try "outside".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: outside.path)
        let runtime = try runtime(root: root)

        let missing = await runtime.execute(call("read_file", "missing.txt"), sessionID: SessionID("s")) { _ in }
        #expect(missing.error?.code == CoreError.Code.toolExecutionFailed.rawValue)
        let directory = await runtime.execute(call("read_file", "folder"), sessionID: SessionID("s")) { _ in }
        #expect(directory.error?.code == CoreError.Code.toolExecutionFailed.rawValue)
        let large = await runtime.execute(call("read_file", "large.txt"), sessionID: SessionID("s")) { _ in }
        #expect(large.error?.code == CoreError.Code.toolExecutionFailed.rawValue)
        let traversal = await runtime.execute(call("read_file", "../secret.txt"), sessionID: SessionID("s")) { _ in }
        #expect(traversal.error?.code == CoreError.Code.workspaceViolation.rawValue)
        let symlink = await runtime.execute(call("read_file", "escape/secret.txt"), sessionID: SessionID("s")) { _ in }
        #expect(symlink.error?.code == CoreError.Code.workspaceViolation.rawValue)
    }

    @Test func listDirectoryRejectsFilesAndEscape() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let runtime = try runtime(root: root)
        let file = await runtime.execute(call("list_directory", "file.txt"), sessionID: SessionID("s")) { _ in }
        #expect(file.error?.code == CoreError.Code.toolExecutionFailed.rawValue)
        let escape = await runtime.execute(call("list_directory", ".."), sessionID: SessionID("s")) { _ in }
        #expect(escape.error?.code == CoreError.Code.workspaceViolation.rawValue)
    }

    @Test func askContainsResolvedResourceAndAllowOnceExecutes() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "approved".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let workspace = try WorkspaceRoot(path: root.path)
        let engine = PermissionEngine(defaultDecision: .ask)
        let runtime = ToolRuntime(registry: .builtin(workspace: workspace), permissions: engine)
        let capture = PermissionCapture()
        let pending = Task {
            await runtime.execute(call("read_file"), sessionID: SessionID("session-1")) { request in
                await capture.record(request)
            }
        }
        let request = await capture.wait()
        #expect(request.resource == root.appendingPathComponent("README.md").path)
        #expect(request.toolID == ToolID("read_file"))
        try await engine.reply(PermissionReply(permissionID: request.permissionID, decision: .allow))
        #expect(await pending.value == ToolResult(callID: ToolCallID("call-1"), success: true, content: "approved"))
    }

    @Test func denyDoesNotExecuteTool() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try runtime(root: root, decision: .deny)
        let result = await runtime.execute(call("read_file", "missing.txt"), sessionID: SessionID("s")) { _ in }
        #expect(result.success == false)
        #expect(result.error?.code == CoreError.Code.permissionDenied.rawValue)
    }

    @Test func autoAllowsUnlessExplicitlyDenied() async {
        let engine = PermissionEngine(
            rules: [PermissionRule(toolID: ToolID("blocked"), decision: .deny)],
            configuration: .agent
        )
        let allowed = PermissionRequest(permissionID: PermissionID("allow"), sessionID: SessionID("s"), toolCallID: ToolCallID("c"), toolID: ToolID("read_file"), resource: "/workspace/a", description: "read")
        let denied = PermissionRequest(permissionID: PermissionID("deny"), sessionID: SessionID("s"), toolCallID: ToolCallID("c"), toolID: ToolID("blocked"), resource: "/workspace/b", description: "read")
        #expect(await engine.request(allowed) {} == .allow)
        #expect(await engine.request(denied) {} == .deny)
        #expect(await engine.currentConfiguration() == .agent)
    }

    @Test func autoPermissionDoesNotReportAnInteractiveAsk() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "ok".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let runtime = ToolRuntime(
            registry: .builtin(workspace: try WorkspaceRoot(path: root.path)),
            permissions: PermissionEngine(configuration: .agent)
        )

        let outcome = await runtime.executeWithMetrics(call("read_file"), sessionID: SessionID("s")) { _ in }

        #expect(outcome.result.success)
        #expect(!outcome.permissionAsked)
    }

    @Test func fullAccessKeepsCanonicalizationAndSensitiveFileGuard() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.deletingLastPathComponent().appendingPathComponent("lingxi-external-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: external) }
        try "external".write(to: external, atomically: true, encoding: .utf8)
        let runtime = ToolRuntime(
            registry: .builtin(workspace: try WorkspaceRoot(path: root.path)),
            permissions: PermissionEngine(configuration: .yolo)
        )
        let allowed = await runtime.execute(call("read_file", external.path), sessionID: SessionID("s")) { _ in }
        #expect(allowed.content == "external")
        try "secret".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let sensitive = await runtime.execute(call("read_file", ".env"), sessionID: SessionID("s")) { _ in }
        #expect(sensitive.error?.code == CoreError.Code.workspaceViolation.rawValue)
    }
}
