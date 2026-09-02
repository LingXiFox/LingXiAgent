import Foundation
import Testing
import LingXiProtocol
import LingXiClient
@testable import LingXiCore

struct PersistenceTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func rootBindingsFilesAndSessionsSurviveReopenAndRelocation() async throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let data = fixture.appendingPathComponent("data", isDirectory: true)
        let rootA = fixture.appendingPathComponent("RootA", isDirectory: true)
        let rootB = fixture.appendingPathComponent("RootB", isDirectory: true)
        let childA = fixture.appendingPathComponent("ChildA", isDirectory: true)
        let childB = fixture.appendingPathComponent("ChildB", isDirectory: true)
        for root in [rootA, rootB, childA, childB] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

        let first = try SQLitePersistenceStore(dataRoot: data, mainRoot: rootA)
        let projectID = first.projectID
        let main = try await first.mainRootBinding()
        let child = try await first.addChildRoot(kind: .sandbox, absoluteRoot: childA)
        let initialPath = try ProjectRelativePath("Sources/A/Foo.swift")
        let file = try await first.upsertFile(rootBindingID: main.id, relativePath: initialPath, contentHash: "same", version: "v1")
        let sessionStore = PersistentSessionStore(persistence: first)
        let session = try await sessionStore.create()
        _ = try await sessionStore.appendMessage(session.id, role: .user, content: "Anchor-Persist-729")
        let page = DerivedContextPage(sessionID: session.id, sourceKind: .user, content: String(repeating: "Anchor-Persist-729 ", count: 600), messageID: nil, tokenEstimate: 100)
        try await first.saveDerived(page)
        try await first.rebindRoot(projectID: projectID, rootBindingID: main.id, newAbsoluteRoot: rootB)
        try await first.rebindRoot(projectID: projectID, rootBindingID: child.id, newAbsoluteRoot: childB)
        try await first.relocateFile(file.id, rootBindingID: main.id, relativePath: try ProjectRelativePath("Sources/B/Foo.swift"))

        let second = try SQLitePersistenceStore(dataRoot: data, mainRoot: rootB, projectID: projectID)
        let resolvedMain = try await WorkspaceResolver(store: second).resolve(rootBindingID: main.id, relativePath: try ProjectRelativePath("Sources/B/Foo.swift"))
        let resolvedChild = try await WorkspaceResolver(store: second).resolve(rootBindingID: child.id, relativePath: .root)
        let restoredFile = try #require(await second.file(file.id))
        let restoredSession = try #require((try await PersistentSessionStore(persistence: second).listSessions()).first)
        let restoredDerived = try await second.loadDerived()
        let movedPath = try ProjectRelativePath("Sources/B/Foo.swift")

        #expect(second.projectID == projectID)
        #expect(restoredFile.id == file.id)
        #expect(restoredFile.relativePath == movedPath)
        #expect(restoredSession.id == session.id)
        #expect(restoredSession.messages.first?.content == "Anchor-Persist-729")
        #expect(restoredDerived.contains { $0.content.contains("Anchor-Persist-729") })
        #expect(resolvedMain.path.hasPrefix(rootB.path))
        #expect(resolvedChild == childB.standardizedFileURL.resolvingSymlinksInPath())
        #expect(try await second.integrityCheck())
    }

    @Test func resolverRejectsEscapesAndAmbiguousMovesAreNotInferred() async throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLitePersistenceStore(dataRoot: fixture.appendingPathComponent("data"), mainRoot: root)
        let main = try await store.mainRootBinding()
        #expect(throws: WorkspaceResolutionError.self) {
            _ = try ProjectRelativePath("../escape")
        }
        await #expect(throws: WorkspaceResolutionError.self) {
            _ = try await WorkspaceResolver(store: store).resolve(rootBindingID: main.id, relativePath: ProjectRelativePath(rawValue: "../../escape"))
        }
    }

    @Test func uniqueHashMoveKeepsPageSymbolAndReferenceIdentity() async throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Root", isDirectory: true)
        let sourceA = root.appendingPathComponent("Sources/A", isDirectory: true)
        let sourceB = root.appendingPathComponent("Sources/B", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceB, withIntermediateDirectories: true)
        let oldURL = sourceA.appendingPathComponent("Foo.swift")
        try "struct Foo {}\nstruct Uses { let value: Foo }\n".write(to: oldURL, atomically: true, encoding: .utf8)

        let persistence = try SQLitePersistenceStore(dataRoot: fixture.appendingPathComponent("data"), mainRoot: root)
        let pages = ProjectPageStore(persistence: persistence)
        let scanner = ProjectScanner(root: root, minimumPageBytes: 1, maximumPageBytes: 128)
        _ = try await pages.rebuildStaleFiles(using: scanner)
        let before = await pages.resources(projectRoot: root)
        let beforeCache = try await persistence.cacheCounts()
        let file = try #require((try await persistence.files()).first)
        try FileManager.default.moveItem(at: oldURL, to: sourceB.appendingPathComponent("Foo.swift"))
        _ = try await pages.rebuildStaleFiles(using: scanner)
        let after = await pages.resources(projectRoot: root)
        let moved = try #require(await persistence.file(file.id))
        let movedPath = try ProjectRelativePath("Sources/B/Foo.swift")

        #expect(moved.id == file.id)
        #expect(moved.relativePath == movedPath)
        #expect(Set(before.pages.map(\.id)) == Set(after.pages.map(\.id)))
        #expect(Set(before.symbols.map(\.id)) == Set(after.symbols.map(\.id)))
        #expect(Set(before.references.map(\.id)) == Set(after.references.map(\.id)))
        #expect(after.pages.allSatisfy { $0.fileID == file.id })
        #expect(after.symbols.allSatisfy { $0.fileID == file.id })
        #expect(after.references.allSatisfy { $0.sourceFileID == file.id })
        #expect(beforeCache.pages == before.pages.count)
        #expect(beforeCache.symbols == before.symbols.count)
        #expect(beforeCache.references == before.references.count)
    }

    @Test func structuredPathAuditExcludesOnlyRootBindingAbsoluteLocator() async throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let rootA = fixture.appendingPathComponent("ROOT_A_SENTINEL", isDirectory: true)
        let rootB = fixture.appendingPathComponent("ROOT_B_SENTINEL", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let store = try SQLitePersistenceStore(dataRoot: fixture.appendingPathComponent("data"), mainRoot: rootA)
        let main = try await store.mainRootBinding()
        let sessionStore = PersistentSessionStore(persistence: store)
        let session = try await sessionStore.create()
        // User content is deliberately excluded from a structured locator audit.
        _ = try await sessionStore.appendMessage(session.id, role: .user, content: rootA.path)
        try await store.saveDerived(DerivedContextPage(sessionID: session.id, sourceKind: .user, content: rootB.path, messageID: nil, tokenEstimate: 1))
        _ = try await store.upsertFile(rootBindingID: main.id, relativePath: try ProjectRelativePath("Sources/File.swift"), contentHash: "h", version: "v")
        try await store.rebindRoot(projectID: store.projectID, rootBindingID: main.id, newAbsoluteRoot: rootB)

        #expect(try await store.structuredAbsolutePathViolations(containing: ["ROOT_A_SENTINEL", "ROOT_B_SENTINEL"]).isEmpty)
    }

    @Test func cacheRowsSurviveReopenAndFormatMismatchOnlyDropsCaches() async throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "struct CacheAnchor {}\n".write(to: root.appendingPathComponent("Anchor.swift"), atomically: true, encoding: .utf8)
        let data = fixture.appendingPathComponent("data", isDirectory: true)
        let first = try SQLitePersistenceStore(dataRoot: data, mainRoot: root)
        let projectID = first.projectID
        let pages = ProjectPageStore(persistence: first)
        _ = try await pages.rebuildStaleFiles(using: ProjectScanner(root: root, minimumPageBytes: 1, maximumPageBytes: 128))
        let before = try await first.cacheCounts()
        #expect(before.pages == 1)

        let second = try SQLitePersistenceStore(dataRoot: data, mainRoot: root, projectID: projectID)
        #expect(try await second.cacheCounts().pages == before.pages)
        try await second.setCacheFormatVersionForTesting(0)
        #expect(try await second.invalidateCachesIfFormatMismatch())
        #expect(try await second.cacheCounts().pages == 0)
        #expect(try await second.files().count == 1)
    }

    @Test func compactionTransactionRollsBackDerivedAndResidency() async throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLitePersistenceStore(dataRoot: fixture.appendingPathComponent("data"), mainRoot: root)
        let session = try await PersistentSessionStore(persistence: store).create()
        let page = DerivedContextPage(sessionID: session.id, sourceKind: .user, content: "rollback-anchor", messageID: nil, tokenEstimate: 1)
        await store.armFailpoint(.beforeCompactionCommit)
        await #expect(throws: PersistenceError.self) {
            try await store.saveCompaction(sessionID: session.id, generation: 1, residencies: [ContextUnitDebugSnapshot(messageID: MessageID("m"), residency: .derived, derivedPageID: page.id)], derivedPages: [page])
        }
        #expect(try await store.loadDerived().isEmpty)
        #expect(try await store.compaction(sessionID: session.id) == nil)
        #expect((try await PersistentSessionStore(persistence: store).session(session.id)).messages.isEmpty)
    }

    @Test func migrationRunnerKeepsDurableDataWhenMigrationIsRejected() async throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = fixture.appendingPathComponent("data", isDirectory: true)
        let store = try SQLitePersistenceStore(dataRoot: data, mainRoot: root)
        let session = try await PersistentSessionStore(persistence: store).create()
        _ = try await PersistentSessionStore(persistence: store).appendMessage(session.id, role: .user, content: "migration-anchor")
        var migrated = false
        try MigrationRunner.migrate(from: 0) { migrated = true }
        #expect(migrated)
        #expect(throws: PersistenceMigrationError.self) {
            try MigrationRunner.migrate(from: SQLitePersistenceStore.databaseSchemaVersion + 1) {}
        }
        let reopened = try SQLitePersistenceStore(dataRoot: data, mainRoot: root, projectID: store.projectID)
        #expect(try await PersistentSessionStore(persistence: reopened).session(session.id).messages.first?.content == "migration-anchor")
    }

    @Test func agentRunAccountSelectionSurvivesReopen() async throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = fixture.appendingPathComponent("data", isDirectory: true)
        let first = try SQLitePersistenceStore(dataRoot: data, mainRoot: root)
        let session = try await PersistentSessionStore(persistence: first).create()
        let runID = AgentRunID("account-run")
        let profile = SubagentExecutionProfile(permissionProfile: "readOnly", toolProfile: ["read_file"], budgetProfile: "2048", contextProfile: "8192", maxSteps: 3, timeoutSeconds: 20)
        try await first.saveAgentRun(AgentRunInfo(
            runID: runID,
            sessionID: session.id,
            projectID: first.projectID,
            rootRunID: runID,
            agentKind: .primary,
            status: .completed,
            modelSelection: ModelSelection(providerID: "custom", accountID: "account", profileID: "profile", modelID: "model")
        ), profile: profile)

        let second = try SQLitePersistenceStore(dataRoot: data, mainRoot: root, projectID: first.projectID)
        #expect(try await second.loadAgentRuns().first?.modelSelection.accountID == "account")
        #expect(try await second.loadAgentRuns().first?.modelSelection.profileID == "profile")
        #expect(try await second.agentRunProfile(runID) == profile)
    }

    @Test func pendingAndSettledToolBatchesRecoverWithoutReplay() async throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = fixture.appendingPathComponent("data", isDirectory: true)
        let first = try SQLitePersistenceStore(dataRoot: data, mainRoot: root)
        let session = try await PersistentSessionStore(persistence: first).create()
        let call = ToolCall(callID: ToolCallID("call"), toolID: ToolID("readFile"), arguments: "{}")
        let assistant = Message(id: MessageID("assistant"), role: .assistant, parts: [.toolCall(call)], createdAt: .now)
        let pending = ToolExchangeBatch(batchID: "pending", sessionID: session.id, assistantMessageID: assistant.id, toolCalls: [call], toolCallStates: [], providerStep: 1, state: .pending, estimatedTokens: 1)
        try await first.appendAssistantMessageAndBatch(sessionID: session.id, message: assistant, batch: pending)
        let settledCall = ToolCall(callID: ToolCallID("settled-call"), toolID: ToolID("readFile"), arguments: "{}")
        let settledAssistant = Message(id: MessageID("settled-assistant"), role: .assistant, parts: [.toolCall(settledCall)], createdAt: .now)
        let continuationRequestID = ModelRequestID("provider-request")
        let unsettled = ToolExchangeBatch(batchID: "settled", sessionID: session.id, assistantMessageID: settledAssistant.id, toolCalls: [settledCall], toolCallStates: [], continuationRequestID: continuationRequestID, providerStep: 2, state: .pending, estimatedTokens: 1)
        try await first.appendAssistantMessageAndBatch(sessionID: session.id, message: settledAssistant, batch: unsettled)
        let result = ToolResult(callID: settledCall.callID, success: true, content: "settled")
        let tool = Message(id: MessageID("tool"), role: .tool, parts: [.toolResult(result)], createdAt: .now)
        let settled = unsettled.with(state: .settledAwaitingConsumption, resultMessageID: tool.id, toolResults: [result])
        try await first.appendToolResultMessageAndSettle(sessionID: session.id, message: tool, batch: settled)

        let second = try SQLitePersistenceStore(dataRoot: data, mainRoot: root, projectID: first.projectID)
        let recovered = try await second.toolBatches(sessionID: session.id)
        #expect(recovered.first { $0.batchID == "pending" }?.state == .recoveryRequired)
        #expect(recovered.first { $0.batchID == "pending" }?.toolResults.isEmpty == true)
        #expect(recovered.first { $0.batchID == "pending" }?.toolCalls == [call])
        #expect(recovered.first { $0.batchID == "settled" }?.state == .settledAwaitingConsumption)
        #expect(recovered.first { $0.batchID == "settled" }?.toolResults == [result])
        #expect(recovered.first { $0.batchID == "settled" }?.continuationRequestID == continuationRequestID)
    }

    @Test func durableToolCallsPreserveCompletedAndHITLStateWhileOnlyMutationClaimsRequireRecovery() async throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = fixture.appendingPathComponent("data", isDirectory: true)
        let first = try SQLitePersistenceStore(dataRoot: data, mainRoot: root)
        let session = try await PersistentSessionStore(persistence: first).create()
        let calls = ["completed", "waiting", "read", "mutation"].map { ToolCall(callID: ToolCallID($0), toolID: ToolID($0), arguments: "{}") }
        let provenance = { (_: ToolCall) in ToolCallProvenance(batchID: "durable", sessionID: session.id, agentRunID: AgentRunID("child-run"), providerRequestID: ModelRequestID("request"), providerStep: 1) }
        let permission = PermissionRequest(permissionID: PermissionID("permission"), sessionID: session.id, toolCallID: calls[1].callID, toolID: calls[1].toolID, resource: "README.md", description: "read")
        let result = ToolResult(callID: calls[0].callID, success: true, content: "done")
        let states = [
            DurableToolCall(call: calls[0], state: .completed, provenance: provenance(calls[0]), result: result),
            DurableToolCall(call: calls[1], state: .waitingForHuman, request: .permission(permission), reply: .permission(PermissionReply(permissionID: permission.permissionID, decision: .allow)), provenance: provenance(calls[1])),
            DurableToolCall(call: calls[2], state: .executing, executionClaim: ToolExecutionClaim(claimID: "read-claim", mutatesProject: false), provenance: provenance(calls[2])),
            DurableToolCall(call: calls[3], state: .executing, executionClaim: ToolExecutionClaim(claimID: "mutation-claim", mutatesProject: true), provenance: provenance(calls[3])),
        ]
        let batch = ToolExchangeBatch(batchID: "durable", sessionID: session.id, assistantMessageID: MessageID("assistant"), toolCalls: calls, toolCallStates: states, continuationRequestID: ModelRequestID("request"), providerStep: 1, state: .pending, estimatedTokens: 1)
        try await first.saveToolBatch(batch)

        let second = try SQLitePersistenceStore(dataRoot: data, mainRoot: root, projectID: first.projectID)
        let recovered = try #require(try await second.toolBatches(sessionID: session.id).first)
        let recoveredState = { id in recovered.toolCallStates.first { $0.call.callID == ToolCallID(id) } }
        #expect(recoveredState("completed")?.state == .completed)
        #expect(recoveredState("completed")?.result == result)
        #expect(recoveredState("waiting")?.state == .waitingForHuman)
        #expect(recoveredState("waiting")?.request == .permission(permission))
        #expect(recoveredState("waiting")?.reply == .permission(PermissionReply(permissionID: permission.permissionID, decision: .allow)))
        #expect(recoveredState("read")?.state == .requested)
        #expect(recoveredState("mutation")?.state == .recoveryRequired)
        #expect(recovered.state == .recoveryRequired)
    }

    @Test func childRunAndTerminalResultCommitAtomically() async throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Root", isDirectory: true)
        let data = fixture.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLitePersistenceStore(dataRoot: data, mainRoot: root)
        let parent = try await PersistentSessionStore(persistence: store).create()
        let binding = try await store.mainRootBinding()
        let child = Session(id: SessionID("child"), createdAt: .now, kind: .subagent, parentSessionID: parent.id, rootSessionID: parent.id, spawnedByRunID: AgentRunID("parent-run"), cwdRootBindingID: binding.id)
        let starting = AgentRunInfo(runID: AgentRunID("child-run"), sessionID: child.id, projectID: store.projectID, parentRunID: AgentRunID("parent-run"), rootRunID: AgentRunID("parent-run"), agentKind: .subagent, status: .starting, modelSelection: ModelSelection(modelID: "model"))

        await store.armFailpoint(.beforeSaveAgentRun(.subagent))
        await #expect(throws: PersistenceError.self) {
            try await store.createChildSessionAndRun(child, run: starting)
        }
        #expect(try await store.loadSessions().contains { $0.id == child.id } == false)
        #expect(try await store.loadAgentRuns().contains { $0.runID == starting.runID } == false)

        try await store.createChildSessionAndRun(child, run: starting)
        let completed = AgentRunInfo(runID: starting.runID, sessionID: child.id, projectID: store.projectID, parentRunID: starting.parentRunID, rootRunID: starting.rootRunID, agentKind: .subagent, status: .completed, modelSelection: starting.modelSelection, startedAt: starting.startedAt, finishedAt: .now, latestActivityAt: .now)
        let result = SubagentResult(childSessionID: child.id, runID: completed.runID, status: .completed, finalText: "complete")
        try await store.saveTerminalAgentRun(completed, result: result)
        #expect(try await store.loadAgentRuns().first { $0.runID == completed.runID }?.status == .completed)
        #expect(try await store.agentRunResult(completed.runID)?.status == .completed)
        #expect(try await store.agentRunResult(completed.runID)?.finalText == "complete")
    }

    @Test func fullCoreRestartRestoresSessionAndDerivedRehydratesThroughL2() async throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Root", isDirectory: true)
        let data = fixture.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try WorkspaceRoot(path: root.path)

        let first = try CoreHost(workspaceRoot: workspace, dataRoot: data)
        await first.start()
        let client = LingXiClient.inProcess(endpoint: first)
        let sessionID = try await client.createSession()
        let store = try #require(await first.persistence)
        let page = DerivedContextPage(sessionID: sessionID, sourceKind: .user, content: "PersistAnchor-729", messageID: nil, tokenEstimate: 5)
        try await store.saveCompaction(sessionID: sessionID, generation: 1, residencies: [ContextUnitDebugSnapshot(messageID: MessageID("anchor"), residency: .derived, derivedPageID: page.id)], derivedPages: [page])
        await first.shutdown()

        let second = try CoreHost(workspaceRoot: workspace, dataRoot: data)
        await second.start()
        let restored = try await LingXiClient.inProcess(endpoint: second).session(sessionID)
        #expect(restored.id == sessionID)
        let derived = DerivedContextStore(persistence: await second.persistence!)
        try await derived.restore()
        let rehydrated = await derived.search(sessionID: sessionID, query: "PersistAnchor-729", limit: 1)
        #expect(rehydrated.map(\.content) == ["PersistAnchor-729"])
        #expect((await derived.metrics(sessionID: sessionID)).l2Pages == 1)
        await second.shutdown()
    }
}
