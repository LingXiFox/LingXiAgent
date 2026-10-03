import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

@Suite("Generic tool choice and action completion")
struct ToolChoiceTests {
    static let write = ToolDefinition(id: ToolID("write_file"), description: "Write a file",
                                     inputSchema: ToolInputSchema(properties: [:], required: []),
                                     capability: ToolCapability(readOnly: false))

    @Test(arguments: [ToolChoice.auto, .none, .required, .function(name: "write_file")])
    func wireSemantics(choice: ToolChoice) throws {
        let request = ModelRequest(model: ModelID("any-model"), messages: [], tools: [Self.write], toolChoice: choice)
        func object(_ data: Data) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
        let chat = try object(OpenAICompatibleProvider.makeRequestBody(request))
        let responses = try object(OpenAIResponsesProvider.makeRequestBody(request))
        let anthropic = try object(AnthropicMessagesProvider.makeRequestBody(request))
        switch choice {
        case .auto:
            #expect(chat["tool_choice"] == nil && responses["tool_choice"] == nil && anthropic["tool_choice"] == nil)
        case .none, .required:
            let value = choice == .none ? "none" : "required"
            #expect(chat["tool_choice"] as? String == value)
            #expect(responses["tool_choice"] as? String == value)
            #expect((anthropic["tool_choice"] as? [String: String])?["type"] == (choice == .required ? "any" : value))
        case let .function(name):
            #expect(((chat["tool_choice"] as? [String: Any])?["function"] as? [String: String])?["name"] == name)
            #expect((responses["tool_choice"] as? [String: String])?["name"] == name)
            #expect((anthropic["tool_choice"] as? [String: String])?["name"] == name)
        }
        #expect(ModelRequest(model: ModelID("m"), messages: []).toolChoice == .auto)
    }

    @Test func invalidChoiceFailsBeforeSending() {
        for choice in [ToolChoice.required, .function(name: "missing")] {
            let request = ModelRequest(model: ModelID("m"), messages: [], toolChoice: choice)
            #expect(throws: CoreError.self) { try OpenAICompatibleProvider.makeRequestBody(request) }
            #expect(throws: CoreError.self) { try OpenAIResponsesProvider.makeRequestBody(request) }
            #expect(throws: CoreError.self) { try AnthropicMessagesProvider.makeRequestBody(request) }
        }
    }

    @Test(arguments: ["你好", "解释如何创建文件", "How do I compile a project?", "请给我一个运行脚本的示例", "不要修改文件", "Write a poem", "请写一段故事"])
    func informationalRequestsStayAuto(task: String) throws {
        var guardState = ActionCompletionGuard(task: task)
        #expect(guardState.requiredEffects.isEmpty)
        let retry = guardState.retryChoice(firstResponse: true, hasTools: true)
        #expect(!retry)
        try guardState.validateCompletion("Here is an explanation.")
    }

    @Test(arguments: ["创建文件", "请在 /tmp 创建 hello.txt", "Can you run the tests?", "编译项目", "Please modify the file", "创建文件并运行测试并编译项目", "只需运行一次测试", "帮我把 hello.txt 修改一下", "请使用 Swift 编译项目", "解释构建流程，然后创建 hello.txt"])
    func actionRequestsGetOnlyOneRetry(task: String) {
        var guardState = ActionCompletionGuard(task: task)
        #expect(!guardState.requiredEffects.isEmpty)
        let later = guardState.retryChoice(firstResponse: false, hasTools: true)
        let noTools = guardState.retryChoice(firstResponse: true, hasTools: false)
        let first = guardState.retryChoice(firstResponse: true, hasTools: true)
        let repeated = guardState.retryChoice(firstResponse: true, hasTools: true)
        #expect(!later && !noTools && first && !repeated)
        #expect(throws: CoreError.self) { try guardState.validateCompletion("done") }
    }

    @Test(arguments: ["已创建文件", "已运行测试", "已编译项目", "已修改代码", "I've created the file.", "The file has been modified.", "Build succeeded.", "编译失败，但已修改文件。", "已创建文件但没有运行测试。", "Created the file.", "文件修改成功"])
    func unsupportedClaimsCannotComplete(text: String) {
        let guardState = ActionCompletionGuard(task: "hi")
        #expect(throws: CoreError.self) { try guardState.validateCompletion(text) }
    }

    @Test func onlyMatchingSuccessfulExecutorResultsCount() throws {
        let call = ToolCall(callID: ToolCallID("write"), toolID: Self.write.id, arguments: "{}")
        var guardState = ActionCompletionGuard(task: "创建文件")
        for result in [ToolResult(callID: call.callID, success: false, content: "denied"),
                       ToolResult(callID: ToolCallID("other"), success: true, content: "ok"),
                       ToolResult(callID: call.callID, success: true, content: "unknown", metadata: ["verificationRequired": "true"])] {
            guardState.record(call: call, result: result, definition: Self.write)
        }
        #expect(guardState.evidencedEffects.isEmpty)
        guardState.record(call: call, result: ToolResult(callID: call.callID, success: true, content: "written"), definition: Self.write)
        try guardState.validateCompletion("已创建文件")
        #expect(throws: CoreError.self) { try guardState.validateCompletion("已编译项目") }
    }

    @Test func commandMustActuallyBuildAndExitSuccessfully() throws {
        let shell = ToolDefinition(id: ToolID("shell"), description: "execute", inputSchema: Self.write.inputSchema,
                                   capability: ToolCapability([.processExecute]))
        var guardState = ActionCompletionGuard(task: "编译项目")
        for (command, exit) in [("echo 'swift build'", 0), ("swift build || true", 0), ("swift build; true", 0), ("swift build", 1)] {
            let args = try JSONSerialization.data(withJSONObject: ["command": command])
            let call = ToolCall(callID: ToolCallID("shell"), toolID: shell.id, arguments: String(decoding: args, as: UTF8.self))
            guardState.record(call: call, result: ToolResult(callID: call.callID, success: true, content: "", exitCode: exit), definition: shell)
        }
        #expect(throws: CoreError.self) { try guardState.validateCompletion("已编译") }
        let call = ToolCall(callID: ToolCallID("build"), toolID: shell.id, arguments: #"{"command":"cd project && swift build"}"#)
        guardState.record(call: call, result: ToolResult(callID: call.callID, success: true, content: "Build complete", exitCode: 0), definition: shell)
        try guardState.validateCompletion("已编译项目")
    }

    @Test func backgroundEvidenceBelongsToTheCurrentTurnAndRequiresSuccessfulExit() throws {
        let definition = ToolDefinition(id: ToolID("background"), description: "execute",
                                        inputSchema: Self.write.inputSchema, capability: ToolCapability([.processExecute]))
        let call = ToolCall(callID: ToolCallID("bg"), toolID: definition.id, arguments: #"{"command":"swift build"}"#)
        var guardState = ActionCompletionGuard(task: "编译项目")
        func snapshot(id: String, status: BackgroundTaskStatus, exit: Int32?) -> BackgroundTaskSnapshot {
            BackgroundTaskSnapshot(id: id, command: "swift build", cwd: "/tmp", timeoutSeconds: 30,
                                   startedAt: .now, completedAt: nil, status: status, pid: 123, exitCode: exit,
                                   description: nil, stdout: "", stderr: "", stdoutCursor: 0, stderrCursor: 0,
                                   elapsedSeconds: 0, remainingTimeoutSeconds: 30)
        }
        guardState.recordBackground([snapshot(id: "old", status: .exited, exit: 0)])
        #expect(guardState.evidencedEffects.isEmpty)
        let result = ToolResult(callID: call.callID, success: true, content: #"{"id":"current","command":"swift build","status":"running"}"#)
        guardState.record(call: call, result: result, definition: definition)
        guardState.recordBackground([snapshot(id: "current", status: .running, exit: nil),
                                     snapshot(id: "current", status: .exited, exit: 1)])
        #expect(guardState.evidencedEffects.isEmpty)
        guardState.recordBackground([snapshot(id: "current", status: .exited, exit: 0)])
        try guardState.validateCompletion("已编译项目")
    }
}
