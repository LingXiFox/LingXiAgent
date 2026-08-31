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

private actor QuestionCapture {
    private var request: QuestionRequest?

    func record(_ request: QuestionRequest) { self.request = request }

    func wait() async -> QuestionRequest {
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

    private func runtime(root: URL, decision: PermissionDecision = .allow, sensitivePathPolicy: SensitivePathPolicy? = nil) throws -> ToolRuntime {
        let workspace = try WorkspaceRoot(path: root.path, sensitivePathPolicy: sensitivePathPolicy)
        return ToolRuntime(registry: .builtin(workspace: workspace), permissions: PermissionEngine(defaultDecision: decision))
    }

    private func call(_ tool: String, _ path: String = "README.md") -> ToolCall {
        ToolCall(callID: ToolCallID("call-1"), toolID: ToolID(tool), arguments: #"{"path":""# + path + #""}"#)
    }

    @Test func definitionsAndRegistryAreStable() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try runtime(root: root)
        #expect(runtime.definitions.map(\.id.rawValue) == ["apply_patch", "edit_file", "git", "glob", "grep", "list_directory", "process", "question", "read_file", "shell", "skill", "write_file"])
        #expect(await runtime.availableDefinitions().map(\.id.rawValue).contains("search_tools"))
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

    @Test func schemaValidationRejectsTypeEnumAndRangeBeforeExecution() throws {
        let schema = ToolInputSchema(
            properties: [
                "mode": ToolInputProperty(type: .string, description: "mode", enumValues: ["exact"]),
                "limit": ToolInputProperty(type: .integer, description: "limit", minimum: 1, maximum: 10),
            ],
            required: ["mode", "limit"]
        )
        #expect(throws: CoreError.self) { try ToolSchemaValidator.validate(arguments: #"{"mode":"prefix","limit":11}"#, schema: schema) }
        #expect(throws: CoreError.self) { try ToolSchemaValidator.validate(arguments: #"{"mode":"exact","limit":"1"}"#, schema: schema) }
        #expect(throws: Never.self) { try ToolSchemaValidator.validate(arguments: #"{"mode":"exact","limit":1}"#, schema: schema) }
        #expect(throws: CoreError.self) { try ToolSchemaValidator.validate(arguments: #"{"mode":"exact","limit":true}"#, schema: schema) }
    }

    @Test func readFileAndListDirectoryStayInsideWorkspace() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "LingXiAgent".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        let runtime = try runtime(root: root)

        let read = await runtime.execute(call("read_file"), sessionID: SessionID("s")) { _ in }
        #expect(read == ToolResult(callID: ToolCallID("call-1"), success: true, content: "LingXiAgent", toolName: "read_file"))

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

    @Test func builtinReadAndListHideSensitiveSentinelsWithoutEchoingPaths() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataRoot = root.appendingPathComponent("runtime-data", isDirectory: true)
        let sensitivePaths = [
            ".ssh/config", ".aws/config", ".gnupg/private.key", ".netrc", ".npmrc",
            ".env.local", "develop.env", "db-credentials.json", "service-secret.txt", "api-token.txt",
            "runtime-data/blobs/page.txt",
        ]
        for path in sensitivePaths {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "sensitive-sentinel".write(to: file, atomically: true, encoding: .utf8)
        }
        try "visible".write(to: root.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        let policy = SensitivePathPolicy(root: root, excluding: [dataRoot])
        let runtime = try runtime(root: root, sensitivePathPolicy: policy)

        let listed = await runtime.execute(call("list_directory", "."), sessionID: SessionID("s")) { _ in }
        #expect(listed.content == "visible.txt\tfile\t7")
        for path in sensitivePaths {
            let read = await runtime.execute(call("read_file", path), sessionID: SessionID("s")) { _ in }
            #expect(read.error?.code == CoreError.Code.workspaceViolation.rawValue)
            #expect(read.error?.message == "不允许访问敏感路径")
            #expect(read.error?.message.contains(path) == false)
        }
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
        #expect(await pending.value == ToolResult(callID: ToolCallID("call-1"), success: true, content: "approved", toolName: "read_file"))
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

    @Test func questionToolWaitsForValidatedInteractiveReply() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let questions = QuestionRuntime(interactive: true)
        let capture = QuestionCapture()
        await questions.setEventSink { request in await capture.record(request) }
        let runtime = ToolRuntime(
            registry: .builtin(workspace: try WorkspaceRoot(path: root.path), questions: questions),
            permissions: PermissionEngine(defaultDecision: .allow)
        )
        #expect(await runtime.availableDefinitions().contains(where: { $0.id == ToolID("question") }) == false)
        #expect(await runtime.availableDefinitions(interactive: true).contains(where: { $0.id == ToolID("question") }))

        let task = Task {
            await runtime.execute(
                ToolCall(callID: ToolCallID("question"), toolID: ToolID("question"), arguments: #"{"question":"继续吗？","options":["是","否"]}"#),
                sessionID: SessionID("s")
            ) { _ in }
        }
        let request = await capture.wait()
        try await questions.reply(QuestionReply(questionID: request.questionID, selectedOptionIndices: [0]))
        let result = await task.value
        #expect(result.success)
        #expect(result.content.contains("是"))
    }

    @Test func workspaceShellRunsInsideWorkspaceAndStripsSecretEnvironment() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(EnvironmentSanitizer.sanitized(from: ["PATH": "/usr/bin:/bin", "LINGXI_TEST_SENTINEL": "secret"])["LINGXI_TEST_SENTINEL"] == nil)
        let runtime = try runtime(root: root)
        let result = await runtime.execute(
            ToolCall(callID: ToolCallID("shell"), toolID: ToolID("shell"), arguments: #"{"command":"printf sandboxed > output.txt","timeout_ms":15000}"#),
            sessionID: SessionID("s")
        ) { _ in }
        #expect(result.success)
        #expect(try String(contentsOf: root.appendingPathComponent("output.txt"), encoding: .utf8) == "sandboxed")
    }

    @Test func writeAndEditRequireCurrentVersionUnlessExplicitlyOverwritten() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try "before".write(to: file, atomically: true, encoding: .utf8)
        let runtime = try runtime(root: root)

        let missingVersion = await runtime.execute(ToolCall(callID: ToolCallID("write-missing"), toolID: ToolID("write_file"), arguments: #"{"path":"file.txt","content":"after"}"#), sessionID: SessionID("s")) { _ in }
        #expect(missingVersion.error?.code == CoreError.Code.contentChanged.rawValue)
        let stale = await runtime.execute(ToolCall(callID: ToolCallID("write-stale"), toolID: ToolID("write_file"), arguments: #"{"path":"file.txt","content":"after","expected_hash":"stale"}"#), sessionID: SessionID("s")) { _ in }
        #expect(stale.error?.code == CoreError.Code.contentChanged.rawValue)
        let current = sha256Hex("before")
        let write = await runtime.execute(ToolCall(callID: ToolCallID("write"), toolID: ToolID("write_file"), arguments: "{\"path\":\"file.txt\",\"content\":\"after\",\"expected_hash\":\"\(current)\"}"), sessionID: SessionID("s")) { _ in }
        #expect(write.success)
        let edit = await runtime.execute(ToolCall(callID: ToolCallID("edit"), toolID: ToolID("edit_file"), arguments: #"{"path":"file.txt","old_string":"after","new_string":"done"}"#), sessionID: SessionID("s")) { _ in }
        #expect(edit.error?.code == CoreError.Code.contentChanged.rawValue)
        let overwrite = await runtime.execute(ToolCall(callID: ToolCallID("overwrite"), toolID: ToolID("write_file"), arguments: #"{"path":"file.txt","content":"done","overwrite":true}"#), sessionID: SessionID("s")) { _ in }
        #expect(overwrite.success)
    }

    @Test func secretPathsAndFailedPatchDoNotExposeOrLeavePartialChanges() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".aws"), withIntermediateDirectories: true)
        try "secret".write(to: root.appendingPathComponent(".aws/credentials"), atomically: true, encoding: .utf8)
        let runtime = try runtime(root: root)
        let secret = await runtime.execute(call("read_file", ".aws/credentials"), sessionID: SessionID("s")) { _ in }
        #expect(secret.error?.code == CoreError.Code.workspaceViolation.rawValue)

        ApplyPatchFailpoint.fail(after: 2)
        defer { ApplyPatchFailpoint.fail(after: nil) }
        let patch = await runtime.execute(ToolCall(callID: ToolCallID("patch"), toolID: ToolID("apply_patch"), arguments: #"{"patch":"*** Begin Patch\n*** Add File: first.txt\n+first\n*** Add File: second.txt\n+second\n*** End Patch"}"#), sessionID: SessionID("s")) { _ in }
        #expect(!patch.success)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("first.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("second.txt").path))
    }

    @Test func shellTimeoutAndManagedProcessLifecycleAreEnforced() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try runtime(root: root)
        let timeout = await runtime.execute(ToolCall(callID: ToolCallID("timeout"), toolID: ToolID("shell"), arguments: #"{"command":"while :; do :; done","timeout_ms":10}"#), sessionID: SessionID("s")) { _ in }
        #expect(timeout.outcome == .timedOut)

        let start = await runtime.execute(ToolCall(callID: ToolCallID("start"), toolID: ToolID("process"), arguments: #"{"action":"start","id":"managed","executable":"/bin/sh","arguments":["-c","read value; printf '%s' \"$value\""]}"#), sessionID: SessionID("s")) { _ in }
        #expect(start.success)
        let input = await runtime.execute(ToolCall(callID: ToolCallID("input"), toolID: ToolID("process"), arguments: #"{"action":"input","id":"managed","input":"ready\n"}"#), sessionID: SessionID("s")) { _ in }
        #expect(input.success)
        var status: ProcessStatus?
        for _ in 0..<100 {
            let poll = await runtime.execute(ToolCall(callID: ToolCallID("poll"), toolID: ToolID("process"), arguments: #"{"action":"poll","id":"managed"}"#), sessionID: SessionID("s")) { _ in }
            status = try? JSONDecoder().decode(ProcessStatus.self, from: Data(poll.content.utf8))
            if status?.running == false { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(status?.stdout.text == "ready")
        #expect(status?.running == false)
    }

    @Test func skillToolOmittedWhenNoSkillsAvailable() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try runtime(root: root)
        let ids = await runtime.availableDefinitions().map(\.id.rawValue)
        #expect(!ids.contains("skill"))
    }

    @Test func skillToolExposedWithCorrectEnumWhenSkillsExist() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let skillsDir = root.appendingPathComponent(".lingxi/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try "alpha skill".write(to: skillsDir.appendingPathComponent("alpha/SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: skillsDir.appendingPathComponent("beta"), withIntermediateDirectories: true)
        try "beta skill".write(to: skillsDir.appendingPathComponent("beta/SKILL.md"), atomically: true, encoding: .utf8)
        let runtime = try runtime(root: root)
        let skillDef = try #require(await runtime.availableDefinitions().first { $0.id == ToolID("skill") })
        #expect(skillDef.inputSchema.properties["name"]?.enumValues == ["alpha", "beta"])
    }

    @Test func skillToolExposureUpdatesDynamicallyWithWorkspaceChanges() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try runtime(root: root)
        let beforeIds = await runtime.availableDefinitions().map(\.id.rawValue)
        #expect(!beforeIds.contains("skill"))
        let skillsDir = root.appendingPathComponent(".lingxi/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir.appendingPathComponent("gamma"), withIntermediateDirectories: true)
        try "gamma skill".write(to: skillsDir.appendingPathComponent("gamma/SKILL.md"), atomically: true, encoding: .utf8)
        let afterIds = await runtime.availableDefinitions().map(\.id.rawValue)
        #expect(afterIds.contains("skill"))
        let skillDef = try #require(await runtime.availableDefinitions().first { $0.id == ToolID("skill") })
        #expect(skillDef.inputSchema.properties["name"]?.enumValues == ["gamma"])
    }

    @Test func allBuiltinToolsProduceToolResultsWithConsistentToolNameOnSuccessAndFailure() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello world".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let toolRuntime = try runtime(root: root)

        // Success path: read_file
        let readOutcome = await toolRuntime.executeWithMetrics(ToolCall(callID: ToolCallID("c1"), toolID: ToolID("read_file"), arguments: #"{"path":"README.md"}"#), sessionID: SessionID("s")) { _ in }
        #expect(readOutcome.result.success)
        #expect(readOutcome.result.toolName == "read_file")
        #expect(readOutcome.toolName == "read_file")

        // Success path: write_file
        let writeOutcome = await toolRuntime.executeWithMetrics(ToolCall(callID: ToolCallID("c2"), toolID: ToolID("write_file"), arguments: #"{"path":"out.txt","content":"abc"}"#), sessionID: SessionID("s")) { _ in }
        #expect(writeOutcome.result.success)
        #expect(writeOutcome.result.toolName == "write_file")
        #expect(writeOutcome.toolName == "write_file")

        // Success path: glob
        let globOutcome = await toolRuntime.executeWithMetrics(ToolCall(callID: ToolCallID("c3"), toolID: ToolID("glob"), arguments: #"{"pattern":"*.md"}"#), sessionID: SessionID("s")) { _ in }
        #expect(globOutcome.result.success)
        #expect(globOutcome.result.toolName == "glob")
        #expect(globOutcome.toolName == "glob")

        // Error path: permission denied
        let denyRuntime = try runtime(root: root, decision: .deny)
        let denyOutcome = await denyRuntime.executeWithMetrics(ToolCall(callID: ToolCallID("c4"), toolID: ToolID("read_file"), arguments: #"{"path":"README.md"}"#), sessionID: SessionID("s")) { _ in }
        #expect(!denyOutcome.result.success)
        #expect(denyOutcome.result.toolName == "read_file")
        #expect(denyOutcome.toolName == "read_file")

        // Error path: schema validation failure
        let invalidOutcome = await toolRuntime.executeWithMetrics(ToolCall(callID: ToolCallID("c5"), toolID: ToolID("read_file"), arguments: #"{}"#), sessionID: SessionID("s")) { _ in }
        #expect(!invalidOutcome.result.success)
        #expect(invalidOutcome.result.toolName == "read_file")
        #expect(invalidOutcome.toolName == "read_file")

        // Error path: non-existent file
        let missingOutcome = await toolRuntime.executeWithMetrics(ToolCall(callID: ToolCallID("c6"), toolID: ToolID("read_file"), arguments: #"{"path":"nonexistent.txt"}"#), sessionID: SessionID("s")) { _ in }
        #expect(!missingOutcome.result.success)
        #expect(missingOutcome.result.toolName == "read_file")
        #expect(missingOutcome.toolName == "read_file")
    }

    @Test func questionToolExecutionOutcomeAndResultConsistentlyPopulatesToolName() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let questions = QuestionRuntime(interactive: true)
        await questions.setEventSink { request in
            try? await questions.reply(QuestionReply(questionID: request.questionID, selectedOptionIndices: [0]))
        }
        let workspace = try WorkspaceRoot(path: root.path)
        let runtime = ToolRuntime(registry: .builtin(workspace: workspace, questions: questions), permissions: PermissionEngine(defaultDecision: .allow))

        let questionOutcome = await runtime.executeWithMetrics(
            ToolCall(callID: ToolCallID("q1"), toolID: ToolID("question"), arguments: #"{"question":"Proceed?","options":["Yes","No"]}"#),
            sessionID: SessionID("s")
        ) { _ in }

        #expect(questionOutcome.result.success)
        #expect(questionOutcome.result.toolName == "question")
        #expect(questionOutcome.toolName == "question")
    }
}
