import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

private actor ParentChildProvider: ModelProvider {
    private let spawn = ToolCall(callID: ToolCallID("spawn-child"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"inspect child","title":"Child"}"#)

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let firstUser = request.messages.first(where: { $0.role == .user })?.content
        let events: [ModelEvent]
        if firstUser == "inspect child" {
            events = [.textDelta("child result"), .completed(.stop)]
        } else if request.messages.contains(where: { $0.role == .tool }) {
            events = [.textDelta("parent result"), .completed(.stop)]
        } else {
            events = [.toolCallCompleted(spawn), .completed(.toolCalls)]
        }
        let stream = AsyncThrowingStream<ModelEvent, Error>(bufferingPolicy: .unbounded) { continuation in
            for event in events { _ = continuation.yield(event) }
            continuation.finish()
        }
        return stream
    }
}

private actor ChildQuestionProvider: ModelProvider {
    private let spawn = ToolCall(callID: ToolCallID("spawn-child"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"ask child"}"#)
    private let question = ToolCall(callID: ToolCallID("child-question"), toolID: ToolID("question"), arguments: #"{"question":"Continue child?","options":["Yes","No"]}"#)

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let child = request.messages.first(where: { $0.role == .user })?.content == "ask child"
        let hasResult = request.messages.contains { $0.role == .tool }
        let events: [ModelEvent] = child
            ? (hasResult ? [.textDelta("child answered"), .completed(.stop)] : [.toolCallCompleted(question), .completed(.toolCalls)])
            : (hasResult ? [.textDelta("parent done"), .completed(.stop)] : [.toolCallCompleted(spawn), .completed(.toolCalls)])
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

struct SubagentRuntimeTests {
    @Test func spawnCreatesIndependentChildSessionAndRunResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: ParentChildProvider(), modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let primary = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: primary, content: "parent task")
        for try await _ in stream {}

        let deadline = Date().addingTimeInterval(2)
        var tree = try await client.getAgentTree(primary)
        while tree.children.first?.latestRun?.status != .completed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            tree = try await client.getAgentTree(primary)
        }
        let child = try #require(tree.children.first)
        let childRun = try #require(child.latestRun)
        #expect(child.session.kind == .subagent)
        #expect(child.session.parentSessionID == primary)
        #expect(child.session.rootSessionID == primary)
        #expect(childRun.sessionID == child.session.id)
        #expect(childRun.status == .completed)
        #expect(try await client.subagentResult(childRun.runID).finalText == "child result")
        #expect((try await client.session(primary)).messages.allSatisfy { !$0.content.contains("child result") })
    }

    @Test func modelResolverRejectsUnallowedChildModel() async {
        let resolver = SubagentModelResolver(defaultRuntime: ModelRuntimeAssembly(provider: ParentChildProvider(), modelID: ModelID("luna")), allowedModels: ["luna"])
        await #expect(throws: CoreError.self) {
            try await resolver.resolve(ModelSelection(modelID: "terra"))
        }
    }

    @Test func childQuestionEscalatesWithOriginAndResumesRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: ChildQuestionProvider(), modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow, interactive: true)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let reply = Task { () -> QuestionRequest? in
            for await event in await client.events() {
                guard case let .questionEscalated(request) = event, let runID = request.originRunID else { continue }
                #expect(request.originSessionID != request.rootSessionID)
                #expect(request.parentSessionID == request.rootSessionID)
                #expect(try await client.getAgentRun(runID).status == .waitingForUser)
                try await client.replyQuestion(QuestionReply(questionID: request.questionID, selectedOptionIndices: [0]))
                return request
            }
            return nil
        }
        await Task.yield()
        let primary = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: primary, content: "parent task") {}
        let request = try #require(await reply.value)
        let runID = try #require(request.originRunID)
        let deadline = Date().addingTimeInterval(2)
        while try await client.getAgentRun(runID).status != .completed, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await client.getAgentRun(runID).status == .completed)
    }
    @Test func invalidProfileSpawnFailureLeavesZeroChildSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: InvalidProfileProvider(), modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let primary = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: primary, content: "start") {}

        let tree = try await client.getAgentTree(primary)
        #expect(tree.children.isEmpty)
        let children = try await client.listChildSessions(primary)
        #expect(children.isEmpty)
    }

    @Test func invalidModelSelectionSpawnFailureLeavesZeroChildSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: InvalidModelProvider(), modelID: ModelID("allowed-model")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let primary = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: primary, content: "start") {}

        let tree = try await client.getAgentTree(primary)
        #expect(tree.children.isEmpty)
        let children = try await client.listChildSessions(primary)
        #expect(children.isEmpty)
    }

    @Test func createRunFailureInjectionRollsBackChildSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: dataRoot)
        }
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: ParentChildProvider(), modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: dataRoot, permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        await host.persistence?.armFailpoint(.beforeSaveAgentRun(.subagent))
        let client = LingXiClient.inProcess(endpoint: host)
        let primary = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: primary, content: "start") {}

        let tree = try await client.getAgentTree(primary)
        #expect(tree.children.isEmpty)
        let children = try await client.listChildSessions(primary)
        #expect(children.isEmpty)
        let persistedSessions = try await host.persistence?.loadSessions() ?? []
        #expect(persistedSessions.filter { $0.kind == .subagent }.isEmpty)
        let persistedRuns = try await host.persistence?.loadAgentRuns() ?? []
        #expect(persistedRuns.filter { $0.agentKind == .subagent }.isEmpty)
    }

    @Test func successfulParallelFooAndBarCreatesExactlyTwoChildrenAndTwoRuns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: ParallelFooBarProvider(), modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let primary = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: primary, content: "start") {}

        let deadline = Date().addingTimeInterval(2)
        var tree = try await client.getAgentTree(primary)
        while (tree.children.count < 2 || tree.children.contains { $0.latestRun?.status != .completed }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            tree = try await client.getAgentTree(primary)
        }
        #expect(tree.children.count == 2)
        #expect(tree.children.allSatisfy { $0.latestRun?.status == .completed })
        let children = try await client.listChildSessions(primary)
        #expect(children.count == 2)
        for child in children {
            let runs = try await client.listAgentRuns(child.id)
            #expect(runs.count == 1)
            #expect(runs.first?.status == .completed)
        }
    }

    @Test func retryFailedSpawnDoesNotCreateOrphanOrDuplicateChildren() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: RetrySpawnProvider(), modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let primary = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: primary, content: "start") {}

        let deadline = Date().addingTimeInterval(2)
        var tree = try await client.getAgentTree(primary)
        while (tree.children.count < 1 || tree.children.contains { $0.latestRun?.status != .completed }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            tree = try await client.getAgentTree(primary)
        }
        #expect(tree.children.count == 1)
        let child = try #require(tree.children.first)
        #expect(child.session.title == "ValidChild")
        #expect(child.latestRun?.status == .completed)
        let children = try await client.listChildSessions(primary)
        #expect(children.count == 1)
    }

    @Test func restartAfterFailedPreCommitSpawnHasNoOrphanChildren() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: dataRoot)
        }
        let assembly = ModelRuntimeAssembly(provider: InvalidProfileProvider(), modelID: ModelID("fake"))
        let firstHost = try CoreHost(providerAssembly: assembly, workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: dataRoot, permissionDecision: .allow)
        await firstHost.start()
        let firstClient = LingXiClient.inProcess(endpoint: firstHost)
        let primary = try await firstClient.createSession()
        for try await _ in try await firstClient.sendMessage(sessionID: primary, content: "start") {}
        let firstTree = try await firstClient.getAgentTree(primary)
        #expect(firstTree.children.isEmpty)
        await firstHost.shutdown()

        let secondHost = try CoreHost(providerAssembly: assembly, workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: dataRoot, permissionDecision: .allow)
        await secondHost.start()
        defer { Task { await secondHost.shutdown() } }
        let secondClient = LingXiClient.inProcess(endpoint: secondHost)
        let secondTree = try await secondClient.getAgentTree(primary)
        #expect(secondTree.children.isEmpty)
        let secondChildren = try await secondClient.listChildSessions(primary)
        #expect(secondChildren.isEmpty)
        let persistedSessions = try await secondHost.persistence?.loadSessions() ?? []
        #expect(persistedSessions.filter { $0.kind == .subagent }.isEmpty)
        let persistedRuns = try await secondHost.persistence?.loadAgentRuns() ?? []
        #expect(persistedRuns.filter { $0.agentKind == .subagent }.isEmpty)
    }

    @Test func childQuestionEscalationDoesNotMutateRootSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: ChildQuestionProvider(), modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow, interactive: true)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let primary = try await client.createSession()

        let replyTask = Task { () -> QuestionRequest? in
            for await event in await client.events() {
                guard case let .questionEscalated(request) = event else { continue }
                #expect(request.originSessionID != request.rootSessionID)
                #expect(request.rootSessionID == primary)
                let rootSessionDuringAsk = try await client.session(primary)
                #expect(rootSessionDuringAsk.messages.allSatisfy { !$0.content.contains("Continue child?") })
                try await client.replyQuestion(QuestionReply(questionID: request.questionID, selectedOptionIndices: [0]))
                return request
            }
            return nil
        }
        await Task.yield()

        for try await _ in try await client.sendMessage(sessionID: primary, content: "parent task") {}
        let request = try #require(await replyTask.value)
        let runID = try #require(request.originRunID)
        let deadline = Date().addingTimeInterval(2)
        while try await client.getAgentRun(runID).status != .completed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await client.getAgentRun(runID).status == .completed)

        let rootSessionAfterAnswer = try await client.session(primary)
        #expect(rootSessionAfterAnswer.messages.allSatisfy { !$0.content.contains("Continue child?") && !$0.content.contains("child answered") })
        let originChildSessionID = try #require(request.originSessionID)
        let childSession = try await client.session(originChildSessionID)
        #expect(childSession.messages.contains { $0.parts.contains { if case let .toolCall(c) = $0 { c.toolID == ToolID("question") } else { false } } })
    }

    @Test func childQuestionAndAnswerExcludedFromNextRootModelRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RequestRecorder()
        let provider = RecordingChildQuestionProvider(recorder: recorder)
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow, interactive: true)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let primary = try await client.createSession()

        let replyTask = Task { () -> QuestionRequest? in
            for await event in await client.events() {
                guard case let .questionEscalated(request) = event else { continue }
                try await client.replyQuestion(QuestionReply(questionID: request.questionID, selectedOptionIndices: [0]))
                return request
            }
            return nil
        }
        await Task.yield()

        for try await _ in try await client.sendMessage(sessionID: primary, content: "start flow") {}
        let request = try #require(await replyTask.value)
        let runID = try #require(request.originRunID)
        let deadline = Date().addingTimeInterval(2)
        while try await client.getAgentRun(runID).status != .completed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        for try await _ in try await client.sendMessage(sessionID: primary, content: "next prompt in root") {}

        let rootRequests = recorder.requests.filter { req in req.messages.contains { $0.content.contains("next prompt in root") } }
        let turn2Request = try #require(rootRequests.first)
        #expect(!turn2Request.messages.contains(where: { $0.content.contains("Continue child?") }))
        #expect(!turn2Request.messages.contains(where: { $0.content.contains("child answered") }))
    }

    @Test func concurrentChildQuestionsRouteSeparatelyWithoutContamination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: ConcurrentChildQuestionProvider(), modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow, interactive: true)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let primary = try await client.createSession()

        let replyTask = Task { () -> [QuestionRequest] in
            var answered: [QuestionRequest] = []
            for await event in await client.events() {
                guard case let .questionEscalated(req) = event else { continue }
                if req.question.contains("Child A") {
                    try await client.replyQuestion(QuestionReply(questionID: req.questionID, selectedOptionIndices: [0]))
                    answered.append(req)
                } else if req.question.contains("Child B") {
                    try await client.replyQuestion(QuestionReply(questionID: req.questionID, selectedOptionIndices: [1]))
                    answered.append(req)
                }
                if answered.count == 2 { return answered }
            }
            return answered
        }
        await Task.yield()

        for try await _ in try await client.sendMessage(sessionID: primary, content: "spawn two") {}
        let requests = try await replyTask.value
        #expect(requests.count == 2)

        let reqA = try #require(requests.first { $0.question.contains("Child A") })
        let reqB = try #require(requests.first { $0.question.contains("Child B") })
        #expect(reqA.originSessionID != reqB.originSessionID)

        let runA = try #require(reqA.originRunID)
        let runB = try #require(reqB.originRunID)
        let deadline = Date().addingTimeInterval(2)
        var statusA = try await client.getAgentRun(runA).status
        var statusB = try await client.getAgentRun(runB).status
        while (statusA != .completed || statusB != .completed), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            statusA = try await client.getAgentRun(runA).status
            statusB = try await client.getAgentRun(runB).status
        }
        #expect(statusA == .completed)
        #expect(statusB == .completed)

        let sessionA = try await client.session(try #require(reqA.originSessionID))
        let sessionB = try await client.session(try #require(reqB.originSessionID))

        #expect(sessionA.messages.contains { $0.content.contains("A1-selected") })
        #expect(sessionA.messages.allSatisfy { !$0.content.contains("B2-selected") && !$0.content.contains("Child B") })

        #expect(sessionB.messages.contains { $0.content.contains("B2-selected") })
        #expect(sessionB.messages.allSatisfy { !$0.content.contains("A1-selected") && !$0.content.contains("Child A") })

        let rootSession = try await client.session(primary)
        #expect(rootSession.messages.allSatisfy { !$0.content.contains("A1-selected") && !$0.content.contains("B2-selected") })
    }

    @Test func nestedChildQuestionBelongsOnlyToOriginGrandchild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: NestedChildQuestionProvider(), modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow, interactive: true)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let primary = try await client.createSession()

        let replyTask = Task { () -> QuestionRequest? in
            for await event in await client.events() {
                guard case let .questionEscalated(req) = event else { continue }
                #expect(req.rootSessionID == primary)
                #expect(req.parentSessionID != primary)
                #expect(req.originSessionID != req.parentSessionID)
                try await client.replyQuestion(QuestionReply(questionID: req.questionID, selectedOptionIndices: [0]))
                return req
            }
            return nil
        }
        await Task.yield()

        for try await _ in try await client.sendMessage(sessionID: primary, content: "start nested") {}
        let req = try #require(await replyTask.value)

        let grandchildSessionID = try #require(req.originSessionID)
        let childSessionID = try #require(req.parentSessionID)

        let deadline = Date().addingTimeInterval(2)
        var grandchildRuns = try await client.listAgentRuns(grandchildSessionID)
        while grandchildRuns.first?.status != .completed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            grandchildRuns = try await client.listAgentRuns(grandchildSessionID)
        }
        #expect(grandchildRuns.first?.status == .completed)

        let grandchildSession = try await client.session(grandchildSessionID)
        #expect(grandchildSession.messages.contains { $0.parts.contains { if case let .toolCall(c) = $0 { c.toolID == ToolID("question") } else { false } } })

        let childSession = try await client.session(childSessionID)
        #expect(childSession.messages.allSatisfy { !$0.content.contains("Grandchild Question") })

        let rootSession = try await client.session(primary)
        #expect(rootSession.messages.allSatisfy { !$0.content.contains("Grandchild Question") })
    }

    @Test func restartWhileWaitingForQuestionRehydratesAndRoutesCleanly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: dataRoot)
        }
        let assembly = ModelRuntimeAssembly(provider: ChildQuestionProvider(), modelID: ModelID("fake"))
        let firstHost = try CoreHost(providerAssembly: assembly, workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: dataRoot, permissionDecision: .allow, interactive: true)
        await firstHost.start()
        let firstClient = LingXiClient.inProcess(endpoint: firstHost)
        let primary = try await firstClient.createSession()

        let questionReceived = Task { () -> QuestionRequest? in
            for await event in await firstClient.events() {
                if case let .questionEscalated(req) = event { return req }
            }
            return nil
        }
        await Task.yield()

        let sendTask = Task {
            for try await _ in try await firstClient.sendMessage(sessionID: primary, content: "parent task") {}
        }
        let req = try #require(await questionReceived.value)
        let childRunID = try #require(req.originRunID)

        let deadline = Date().addingTimeInterval(2)
        while try await firstClient.getAgentRun(childRunID).status != .waitingForUser, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await firstClient.getAgentRun(childRunID).status == .waitingForUser)
        sendTask.cancel()

        await firstHost.shutdown()

        let secondHost = try CoreHost(providerAssembly: assembly, workspaceRoot: try WorkspaceRoot(path: root.path), dataRoot: dataRoot, permissionDecision: .allow, interactive: true)
        await secondHost.start()
        defer { Task { await secondHost.shutdown() } }
        let secondClient = LingXiClient.inProcess(endpoint: secondHost)

        let rootSession = try await secondClient.session(primary)
        #expect(rootSession.messages.allSatisfy { !$0.content.contains("Continue child?") })

        let childSessionID = try #require(req.originSessionID)
        let childRuns = try await secondClient.listAgentRuns(childSessionID)
        #expect(childRuns.first?.status == .waitingForUser)
        #expect(childRuns.first?.runID == childRunID)
        try await secondClient.replyQuestion(QuestionReply(questionID: req.questionID, selectedOptionIndices: [0]))
        let resumedDeadline = Date().addingTimeInterval(2)
        var resumed = try await secondClient.getAgentRun(childRunID)
        while resumed.status != .completed, Date() < resumedDeadline {
            try await Task.sleep(for: .milliseconds(10))
            resumed = try await secondClient.getAgentRun(childRunID)
        }
        #expect(resumed.sessionID == childSessionID)
        #expect(resumed.status == .completed)
    }

    @Test func contextProfileOmittedInheritsEndpointAndPasses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: ParentChildProvider(), modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let primary = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: primary, content: "start") {}

        let deadline = Date().addingTimeInterval(2)
        var tree = try await client.getAgentTree(primary)
        while tree.children.first?.latestRun?.status != .completed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            tree = try await client.getAgentTree(primary)
        }
        let child = try #require(tree.children.first)
        #expect(child.latestRun?.status == .completed)
        #expect(tree.children.count == 1)
    }

    @Test func contextProfileBelowMinimumViableFailsPreFlightAndLeavesZeroChildren() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for smallContext in ["1", "4096"] {
            let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: ContextProfileTooSmallProvider(contextWindow: smallContext), modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
            await host.start()
            let client = LingXiClient.inProcess(endpoint: host)
            let primary = try await client.createSession()
            for try await _ in try await client.sendMessage(sessionID: primary, content: "start") {}

            let tree = try await client.getAgentTree(primary)
            #expect(tree.children.isEmpty)
            let children = try await client.listChildSessions(primary)
            #expect(children.isEmpty)
            await host.shutdown()
        }
    }

    @Test func exactMinimumViableContextWindowSpawnsAndCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let estimator = ConservativeTokenEstimator()
        let policy = ContextBudgetPolicy()
        let task = "inspect exact"
        let mandatoryTokens = await L1ContextEngine().initialMandatoryTokens(task: task, estimator: estimator)
        let workspace = try WorkspaceRoot(path: root.path)
        let reserve = 4_096
        let provider = ExactMinimumViableContextProvider(task: task)
        let endpointProfile = ModelContextProfile(contextWindowTokens: 128_000, maxOutputTokens: 4_096, recommendedOutputReserveTokens: reserve)
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake"), contextProfile: endpointProfile)
        let host = try CoreHost(providerAssembly: assembly, workspaceRoot: workspace, permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let primary = try await client.createSession()

        let childTools = await host.toolRuntimeRef.availableDefinitions(sessionID: primary, interactive: false, executionProfile: nil)
        let toolTokens = estimator.estimate(tools: childTools)
        let exactWindow = mandatoryTokens + reserve + policy.fixedOverheadTokens + toolTokens + policy.safetyMarginTokens
        await provider.setExactWindow(exactWindow)

        for try await _ in try await client.sendMessage(sessionID: primary, content: "start") {}

        let deadline = Date().addingTimeInterval(2)
        var tree = try await client.getAgentTree(primary)
        while tree.children.first?.latestRun?.status != .completed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            tree = try await client.getAgentTree(primary)
        }
        let child = try #require(tree.children.first)
        #expect(child.latestRun?.status == .completed)
        #expect(tree.children.count == 1)
    }

    @Test func parallelChildrenOneValidOneInvalidSmallProfileLeavesOnlyValidChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: ParallelValidAndInvalidSmallContextProvider(), modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let primary = try await client.createSession()
        for try await _ in try await client.sendMessage(sessionID: primary, content: "start") {}

        let deadline = Date().addingTimeInterval(2)
        var tree = try await client.getAgentTree(primary)
        while tree.children.first?.latestRun?.status != .completed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            tree = try await client.getAgentTree(primary)
        }
        #expect(tree.children.count == 1)
        let validChild = try #require(tree.children.first)
        #expect(validChild.session.title == "ValidChild")
        #expect(validChild.latestRun?.status == .completed)
        let allChildren = try await client.listChildSessions(primary)
        #expect(allChildren.count == 1)
    }

    @Test func budgetProfileOverrideDoesNotAlterPhysicalHardLimit() {
        let planner = ContextBudgetPlanner()
        let profile = ModelContextProfile(contextWindowTokens: 128_000, maxOutputTokens: 4_096, recommendedOutputReserveTokens: 4_096)
        let originalBudget = planner.plan(profile: profile, toolTokens: 1_000)
        let overriddenPlanner = planner.with(preferredActiveTokens: 500)
        let overriddenBudget = overriddenPlanner.plan(profile: profile, toolTokens: 1_000)

        #expect(overriddenBudget.hardInputLimit == originalBudget.hardInputLimit)
        #expect(overriddenBudget.preferredActiveTokens == 500)
        #expect(originalBudget.preferredActiveTokens == min(planner.policy.defaultActiveCeiling, Int(Double(originalBudget.hardInputLimit) * planner.policy.preferredRatio)))
    }

    @Test func vcrManifestContextProfileConsistency() throws {
        let profile = ModelContextProfile(contextWindowTokens: 64_000, maxOutputTokens: 2_048, recommendedOutputReserveTokens: 2_048, source: "test-manifest")
        let manifest = VCRCassetteManifest(wire: .responses, modelAlias: "gpt-test", scenario: "test", lingXiCommit: "abc", contextProfile: profile)
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(VCRCassetteManifest.self, from: data)
        #expect(decoded.contextProfile == profile)
        #expect(decoded.contextProfile.contextWindowTokens == 64_000)
        #expect(decoded.contextProfile.maxOutputTokens == 2_048)
        #expect(decoded.contextProfile.recommendedOutputReserveTokens == 2_048)
    }
}

private actor RecordingChildQuestionProvider: ModelProvider {
    let recorder: RequestRecorder
    private let spawn = ToolCall(callID: ToolCallID("spawn-child"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"ask child"}"#)
    private let question = ToolCall(callID: ToolCallID("child-question"), toolID: ToolID("question"), arguments: #"{"question":"Continue child?","options":["Yes","No"]}"#)

    init(recorder: RequestRecorder) {
        self.recorder = recorder
    }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        recorder.record(request)
        let child = request.messages.first(where: { $0.role == .user })?.content == "ask child"
        let isRootTurn2 = request.messages.contains(where: { $0.content.contains("next prompt in root") })
        let hasResult = request.messages.contains { $0.role == .tool }
        let events: [ModelEvent]
        if child {
            events = hasResult ? [.textDelta("child answered"), .completed(.stop)] : [.toolCallCompleted(question), .completed(.toolCalls)]
        } else if isRootTurn2 {
            events = [.textDelta("turn 2 answered"), .completed(.stop)]
        } else {
            events = hasResult ? [.textDelta("parent done"), .completed(.stop)] : [.toolCallCompleted(spawn), .completed(.toolCalls)]
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor ConcurrentChildQuestionProvider: ModelProvider {
    private let spawnA = ToolCall(callID: ToolCallID("spawn-a"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"task A","title":"ChildA"}"#)
    private let spawnB = ToolCall(callID: ToolCallID("spawn-b"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"task B","title":"ChildB"}"#)
    private let questionA = ToolCall(callID: ToolCallID("q-a"), toolID: ToolID("question"), arguments: #"{"question":"Question for Child A","options":["A1","A2"]}"#)
    private let questionB = ToolCall(callID: ToolCallID("q-b"), toolID: ToolID("question"), arguments: #"{"question":"Question for Child B","options":["B1","B2"]}"#)

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let firstUser = request.messages.first(where: { $0.role == .user })?.content
        let toolResults = request.messages.flatMap(\.parts).compactMap { if case let .toolResult(r) = $0 { r } else { nil } }
        let events: [ModelEvent]
        if firstUser == "task A" {
            if let result = toolResults.first {
                let text = result.content.contains("A1") ? "A1-selected" : "A2-selected"
                events = [.textDelta(text), .completed(.stop)]
            } else {
                events = [.toolCallCompleted(questionA), .completed(.toolCalls)]
            }
        } else if firstUser == "task B" {
            if let result = toolResults.first {
                let text = result.content.contains("B2") ? "B2-selected" : "B1-selected"
                events = [.textDelta(text), .completed(.stop)]
            } else {
                events = [.toolCallCompleted(questionB), .completed(.toolCalls)]
            }
        } else if !toolResults.isEmpty {
            events = [.textDelta("parent done"), .completed(.stop)]
        } else {
            events = [.toolCallCompleted(spawnA), .toolCallCompleted(spawnB), .completed(.toolCalls)]
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor NestedChildQuestionProvider: ModelProvider {
    private let spawnChild = ToolCall(callID: ToolCallID("spawn-c"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"task depth 1","title":"Child1"}"#)
    private let spawnGrandchild = ToolCall(callID: ToolCallID("spawn-gc"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"task depth 2","title":"Grandchild"}"#)
    private let question = ToolCall(callID: ToolCallID("gc-q"), toolID: ToolID("question"), arguments: #"{"question":"Grandchild Question","options":["G1","G2"]}"#)

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let firstUser = request.messages.first(where: { $0.role == .user })?.content
        let hasResult = request.messages.contains { $0.role == .tool }
        let events: [ModelEvent]
        if firstUser == "task depth 2" {
            events = hasResult ? [.textDelta("grandchild done"), .completed(.stop)] : [.toolCallCompleted(question), .completed(.toolCalls)]
        } else if firstUser == "task depth 1" {
            events = hasResult ? [.textDelta("child1 done"), .completed(.stop)] : [.toolCallCompleted(spawnGrandchild), .completed(.toolCalls)]
        } else {
            events = hasResult ? [.textDelta("root done"), .completed(.stop)] : [.toolCallCompleted(spawnChild), .completed(.toolCalls)]
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor InvalidProfileProvider: ModelProvider {
    private let spawn = ToolCall(callID: ToolCallID("spawn-invalid"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"invalid child","permission_profile":"unknownPermission"}"#)

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let events: [ModelEvent]
        if request.messages.contains(where: { $0.role == .tool }) {
            events = [.textDelta("spawn failed as expected"), .completed(.stop)]
        } else {
            events = [.toolCallCompleted(spawn), .completed(.toolCalls)]
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor InvalidModelProvider: ModelProvider {
    private let spawn = ToolCall(callID: ToolCallID("spawn-invalid-model"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"invalid model child","model_id":"disallowed-model"}"#)

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let events: [ModelEvent]
        if request.messages.contains(where: { $0.role == .tool }) {
            events = [.textDelta("model spawn failed as expected"), .completed(.stop)]
        } else {
            events = [.toolCallCompleted(spawn), .completed(.toolCalls)]
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor ParallelFooBarProvider: ModelProvider {
    private let spawnFoo = ToolCall(callID: ToolCallID("spawn-foo"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"inspect foo","title":"Foo"}"#)
    private let spawnBar = ToolCall(callID: ToolCallID("spawn-bar"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"inspect bar","title":"Bar"}"#)

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let firstUser = request.messages.first(where: { $0.role == .user })?.content
        let events: [ModelEvent]
        if firstUser == "inspect foo" {
            events = [.textDelta("FooAnchor-729"), .completed(.stop)]
        } else if firstUser == "inspect bar" {
            events = [.textDelta("BarAnchor-729"), .completed(.stop)]
        } else if request.messages.contains(where: { $0.role == .tool }) {
            events = [.textDelta("parent completed both"), .completed(.stop)]
        } else {
            events = [.toolCallCompleted(spawnFoo), .toolCallCompleted(spawnBar), .completed(.toolCalls)]
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor RetrySpawnProvider: ModelProvider {
    private let spawnInvalid = ToolCall(callID: ToolCallID("spawn-invalid"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"retry child","permission_profile":"unknownPermission"}"#)
    private let spawnValid = ToolCall(callID: ToolCallID("spawn-valid"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"retry child","title":"ValidChild"}"#)

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let firstUser = request.messages.first(where: { $0.role == .user })?.content
        let events: [ModelEvent]
        if firstUser == "retry child" {
            events = [.textDelta("child result"), .completed(.stop)]
        } else {
            let toolResults = request.messages.filter { $0.role == .tool }
            if toolResults.isEmpty {
                events = [.toolCallCompleted(spawnInvalid), .completed(.toolCalls)]
            } else if toolResults.count == 1 {
                events = [.toolCallCompleted(spawnValid), .completed(.toolCalls)]
            } else {
                events = [.textDelta("retry succeeded"), .completed(.stop)]
            }
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor ContextProfileTooSmallProvider: ModelProvider {
    let contextWindow: String

    init(contextWindow: String) {
        self.contextWindow = contextWindow
    }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let events: [ModelEvent]
        if request.messages.contains(where: { $0.role == .tool }) {
            events = [.textDelta("parent handled spawn failure"), .completed(.stop)]
        } else {
            let spawn = ToolCall(callID: ToolCallID("spawn-small"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"small child","context_profile":"\#(contextWindow)"}"#)
            events = [.toolCallCompleted(spawn), .completed(.toolCalls)]
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor ExactMinimumViableContextProvider: ModelProvider {
    var contextWindow: Int
    let task: String

    init(contextWindow: Int = 128_000, task: String) {
        self.contextWindow = contextWindow
        self.task = task
    }

    func setExactWindow(_ window: Int) {
        self.contextWindow = window
    }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let firstUser = request.messages.first(where: { $0.role == .user })?.content
        let events: [ModelEvent]
        if firstUser == task {
            events = [.textDelta("exact child success"), .completed(.stop)]
        } else if request.messages.contains(where: { $0.role == .tool }) {
            events = [.textDelta("parent success"), .completed(.stop)]
        } else {
            let spawn = ToolCall(callID: ToolCallID("spawn-exact"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"\#(task)","context_profile":"\#(contextWindow)"}"#)
            events = [.toolCallCompleted(spawn), .completed(.toolCalls)]
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor ParallelValidAndInvalidSmallContextProvider: ModelProvider {
    private let spawnValid = ToolCall(callID: ToolCallID("spawn-v"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"valid child","title":"ValidChild"}"#)
    private let spawnInvalid = ToolCall(callID: ToolCallID("spawn-i"), toolID: ToolID("subagent"), arguments: #"{"action":"spawn","task":"invalid child","title":"InvalidChild","context_profile":"1"}"#)

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let firstUser = request.messages.first(where: { $0.role == .user })?.content
        let events: [ModelEvent]
        if firstUser == "valid child" {
            events = [.textDelta("valid child done"), .completed(.stop)]
        } else if request.messages.contains(where: { $0.role == .tool }) {
            events = [.textDelta("parent done"), .completed(.stop)]
        } else {
            events = [.toolCallCompleted(spawnValid), .toolCallCompleted(spawnInvalid), .completed(.toolCalls)]
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
