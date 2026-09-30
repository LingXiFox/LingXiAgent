import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

private actor ApprovalCount {
    var count = 0
    func record() { count += 1 }
}

struct ShellWorkspaceBoundaryTests {
    @Test func literalsAreCheckedWithoutTreatingEchoTextAsAccess() {
        #expect(ShellLaunch.literalFileOperands(command: "ls -la '/outside/a b'; cat ../file") == ["/outside/a b", "../file"])
        #expect(ShellLaunch.literalFileOperands(command: "echo '/outside/text'") == [])
        #expect(ShellLaunch.literalFileOperands(command: "echo ok > '/outside/file'") == ["/outside/file"])
        #expect(ShellLaunch.literalFileOperands(command: "echo ok\nls /outside") == ["/outside"])
        #expect(ShellLaunch.literalFileOperands(executable: "/bin/sh", arguments: ["-c", "ls /outside"]) == ["/outside"])
    }

    @Test func scopeIsEnforcedBeforeApprovalAndFullAccessRemainsExplicit() async throws {
        #if !os(Windows)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("shell-boundary-\(UUID().uuidString)")
        let root = base.appendingPathComponent("project")
        let outside = base.appendingPathComponent("outside file.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "outside-approved".write(to: outside, atomically: false, encoding: .utf8)
        try "inside-approved".write(to: root.appendingPathComponent("inside.txt"), atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        let workspace = try WorkspaceRoot(path: root.path)
        let engine = PermissionEngine(configuration: .askWorkspace)
        let runtime = ToolRuntime(registry: .builtin(workspace: workspace), permissions: engine)
        let approvals = ApprovalCount()
        func arguments(_ values: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
        }
        let deniedCalls: [(String, [String: Any])] = [
            ("shell", ["command": "ls -la '\(outside.path)'"]),
            ("shell", ["command": "cat escape"]),
            ("shell", ["command": "echo ok > '../new-file.txt'"]),
            ("shell", ["executable": "/bin/cat", "arguments": [outside.path]]),
            ("process", ["action": "start", "executable": "/bin/cat", "arguments": [outside.path]]),
            ("run_background_command", ["command": "cat '\(outside.path)'", "timeout_seconds": 10])
        ]
        for (index, entry) in deniedCalls.enumerated() {
            let result = await runtime.execute(ToolCall(callID: ToolCallID("denied-\(index)"), toolID: ToolID(entry.0), arguments: try arguments(entry.1)), sessionID: SessionID("scope-test")) { request in
                await approvals.record()
                try? await engine.reply(PermissionReply(permissionID: request.permissionID, decision: .allow))
            }
            #expect(result.error?.code == CoreError.Code.workspaceViolation.rawValue, "\(entry.0): \(result.content)")
            #expect(result.error?.message.contains("FullAccess") == true || result.error?.message.contains("敏感") == true)
        }
        #expect(await approvals.count == 0)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("new-file.txt").path))

        let inside = await runtime.execute(ToolCall(callID: ToolCallID("inside"), toolID: ToolID("shell"), arguments: try arguments(["command": "cat inside.txt"])), sessionID: SessionID("scope-test")) { request in
            #expect(request.description.contains("不扩大 Workspace"))
            await approvals.record()
            try? await engine.reply(PermissionReply(permissionID: request.permissionID, decision: .allow))
        }
        #expect(inside.success, "\(inside.content)")
        #expect(inside.content.contains("inside-approved"))
        #expect(await approvals.count == 1)

        let full = await runtime.execute(ToolCall(callID: ToolCallID("full"), toolID: ToolID("shell"), arguments: try arguments(["command": "cat '\(outside.path)'"])), sessionID: SessionID("scope-test"), permissionConfiguration: .askFullAccess) { request in
            await approvals.record()
            try? await engine.reply(PermissionReply(permissionID: request.permissionID, decision: .allow))
        }
        #expect(full.success, "\(full.content)")
        #expect(full.content.contains("outside-approved"))
        #expect(await approvals.count >= 2)
        #endif
    }
}
