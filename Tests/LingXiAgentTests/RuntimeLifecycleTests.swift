import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

struct RuntimeLifecycleTests {
    @Test func stoppedCoreRejectsBusinessCommands() async throws {
        let host = try CoreHost()
        await host.start()
        await host.shutdown()

        await #expect(throws: CoreError.self) {
            try await host.handle(.createSession)
        }
        await #expect(throws: CoreError.self) {
            try await host.openDataStream(.openTestStream)
        }
        #expect(try await host.handle(.getState) == .state(.stopped))
    }

    @Test func cancelledPermissionAndQuestionRejectLateReplies() async throws {
        let permissions = PermissionEngine(configuration: .strict)
        let permissionID = PermissionID("permission")
        let permission = PermissionRequest(permissionID: permissionID, sessionID: SessionID("session"), toolCallID: ToolCallID("call"), toolID: ToolID("tool"), capabilities: [.projectRead], resource: "resource", description: "test")
        let permissionTask = Task { await permissions.resolve(permission) {} }
        try await Task.sleep(for: .milliseconds(10))
        permissionTask.cancel()
        #expect(await permissionTask.value.decision == .deny)
        await #expect(throws: CoreError.self) { try await permissions.reply(PermissionReply(permissionID: permissionID, decision: .allow)) }

        let questions = QuestionRuntime(interactive: true)
        let questionID = QuestionID("question")
        let questionTask = Task { try await questions.ask(QuestionRequest(questionID: questionID, question: "Continue?", options: ["Yes"])) }
        try await Task.sleep(for: .milliseconds(10))
        questionTask.cancel()
        await #expect(throws: CancellationError.self) { try await questionTask.value }
        await #expect(throws: CoreError.self) { try await questions.reply(QuestionReply(questionID: questionID, selectedOptionIndices: [0])) }
    }

    @Test func subagentActionsDecodeSnakeCaseAndUsePermissionEngine() async throws {
        let permissions = PermissionEngine(configuration: .strict)
        let service = SubagentToolService()
        let childRun = AgentRunInfo(runID: AgentRunID("child-run"), sessionID: SessionID("child-session"), projectID: nil, parentRunID: AgentRunID("parent-run"), rootRunID: AgentRunID("parent-run"), agentKind: .subagent, status: .completed, modelSelection: ModelSelection(modelID: "model"))
        await service.bind(
            spawn: { _, _, _, _, selection, _, _ in
                #expect(selection == nil)
                return (childRun.sessionID, childRun)
            },
            status: { id, requester in #expect(id == childRun.runID); #expect(requester == AgentRunID("parent-run")); return childRun },
            result: { id, _ in SubagentResult(childSessionID: childRun.sessionID, runID: id, status: .completed) },
            cancel: { id, _ in #expect(id == childRun.runID) },
            message: { id, _, content in #expect(id == childRun.sessionID); #expect(content == "next"); return childRun }
        )
        let runtime = ToolRuntime(registry: ToolRegistry([]), permissions: permissions, subagents: service)
        let call = ToolCall(callID: ToolCallID("spawn"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"inspect"}"#)
        let outcome = await AgentExecutionContext.$current.withValue((SessionID("parent-session"), AgentRunID("parent-run"), SessionID("parent-session"), nil)) {
            await runtime.executeWithMetrics(call, sessionID: SessionID("parent-session")) { request in
                try? await permissions.reply(PermissionReply(permissionID: request.permissionID, decision: .allow))
            }
        }
        #expect(outcome.result.success)
        #expect(outcome.permissionAsked)

        let status = try await AgentExecutionContext.$current.withValue((SessionID("parent-session"), AgentRunID("parent-run"), SessionID("parent-session"), nil)) {
            try await service.execute(arguments: #"{"action":"status","run_id":"child-run"}"#, sessionID: SessionID("parent-session"), callID: ToolCallID("status"))
        }
        #expect(status.contains("child-run"))
        _ = try await AgentExecutionContext.$current.withValue((SessionID("parent-session"), AgentRunID("parent-run"), SessionID("parent-session"), nil)) {
            try await service.execute(arguments: #"{"action":"message","session_id":"child-session","content":"next"}"#, sessionID: SessionID("parent-session"), callID: ToolCallID("message"))
        }

        await #expect(throws: CoreError.self) {
            try await AgentExecutionContext.$current.withValue((SessionID("parent-session"), AgentRunID("parent-run"), SessionID("parent-session"), nil)) {
                try await service.execute(arguments: #"{"action":"spawn","task":"inspect","model_id":"model"}"#, sessionID: SessionID("parent-session"), callID: ToolCallID("partial"))
            }
        }
    }

    @Test func mcpRejectsExpiredLeaseAndDropsOldSchemaVersions() async throws {
        let schemas = MCPToolSchemaStore()
        let pager = MCPToolPager(schemaStore: schemas)
        let server = MCPServerID("server")
        let toolID = ToolID("server::tool")
        func tool(hash: String) -> MCPDiscoveredTool {
            MCPDiscoveredTool(entry: MCPToolCatalogEntry(toolID: toolID, serverID: server, serverAlias: "server", upstreamName: "tool", title: "Tool", shortDescription: "Tool", tags: [], annotations: MCPToolAnnotations(), schemaHash: hash, era: .modern, available: true, stale: false, cacheScope: .public, authContextID: nil, lastSeen: .now), inputSchema: .object(["type": .string("object")]))
        }
        try await pager.replaceCatalog(serverID: server, tools: [tool(hash: "v1")])
        try await pager.replaceCatalog(serverID: server, tools: [tool(hash: "v2")])
        #expect(await schemas.count() == 1)

        _ = await pager.search(sessionID: SessionID("session"), projectID: ProjectID("project"), query: "tool")
        let lease = try await pager.load(sessionID: SessionID("session"), toolID: toolID, schemaTokenBudget: 100)
        await #expect(throws: MCPToolPagerError.leaseExpired) {
            try await pager.resolve(sessionID: SessionID("session"), providerToolID: ToolID(lease.providerName), now: lease.expiresAt.addingTimeInterval(1))
        }
        #expect(await pager.leaseCount(sessionID: SessionID("session")) == 0)
    }
}
