import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

@Suite struct ContextProjectionTests {

    @Test func fullSendCountMaintainsFullContentForFirstTwoTurns() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            eCorePersistenceEnabled: true,
            observationProjectionEnabled: true,
            objectizationThreshold: 10_240, // 10KB
            fullSendCount: 2
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let projection = ContextProjection(configuration: config)

        let sID = SessionID("proj-session-1")
        let toolCallID = ToolCallID("call_full_send")
        let largeContent = String(repeating: "Row data content 1234567890\n", count: 400) // ~11KB

        let toolResult = ToolResult(
            callID: toolCallID,
            success: true,
            content: largeContent,
            toolName: "shell"
        )
        let toolMsg = Message(
            id: MessageID("msg_tool_1"),
            role: .tool,
            parts: [.toolResult(toolResult)],
            createdAt: .now
        )
        let entry = ContextEntry(
            messageID: toolMsg.id,
            role: .tool,
            source: .toolResult,
            part: .toolResult(toolResult)
        )

        // Turn 1: 0 assistant messages after toolMsg
        let session1 = Session(id: sID, createdAt: .now, messages: [toolMsg])
        let projected1 = await projection.project(entries: [entry], session: session1, ecoreStore: store)
        try #require(projected1.count == 1)
        if case let .toolResult(res1) = projected1[0].part {
            #expect(res1.content == largeContent) // Full content!
            #expect(res1.content.contains("Row data content") == true)
        } else {
            Issue.record("Expected toolResult part")
        }

        // Turn 2: 1 assistant message after toolMsg
        let asstMsg1 = Message(id: MessageID("msg_asst_1"), role: .assistant, parts: [.text("First step done")], createdAt: .now)
        let session2 = Session(id: sID, createdAt: .now, messages: [toolMsg, asstMsg1])
        let projected2 = await projection.project(entries: [entry], session: session2, ecoreStore: store)
        if case let .toolResult(res2) = projected2[0].part {
            #expect(res2.content == largeContent) // Still full content!
        } else {
            Issue.record("Expected toolResult part")
        }

        // Turn 3: 2 assistant messages after toolMsg -> Transition to Placeholder!
        let asstMsg2 = Message(id: MessageID("msg_asst_2"), role: .assistant, parts: [.text("Second step done")], createdAt: .now)
        let session3 = Session(id: sID, createdAt: .now, messages: [toolMsg, asstMsg1, asstMsg2])
        let projected3 = await projection.project(entries: [entry], session: session3, ecoreStore: store)
        if case let .toolResult(res3) = projected3[0].part {
            #expect(res3.content != largeContent)
            #expect(res3.content.contains("[Context Object:") == true)
            #expect(res3.content.contains("To retrieve additional lines or full content, use `context_recall") == true)
            #expect(res3.content.count < 1500) // ~1KB placeholder
        } else {
            Issue.record("Expected toolResult part")
        }
    }

    @Test func contextRecallToolExecution() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            eCorePersistenceEnabled: true,
            objectizationThreshold: 1024
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let sID = SessionID("s-recall-tool")

        // 存储一个大对象
        var lines: [String] = []
        for i in 1...100 {
            lines.append("Item #\(i): Important log entry details")
        }
        let fullText = lines.joined(separator: "\n") + "\n"

        let meta = await store.store(
            sessionID: sID,
            toolCallID: ToolCallID("call_log"),
            toolName: "shell",
            content: fullText,
            force: true
        )
        guard let objectID = meta?.objectID else {
            Issue.record("Failed to save object")
            return
        }

        let recallTool = ContextRecallTool(ecoreStore: store)

        // 1. 成功召回切片
        let callArgs = "{\"id\":\"\(objectID.rawValue)\",\"offset\":0,\"limit_bytes\":1000,\"limit_lines\":20}"
        let output = try await ToolExecutionContext.$sessionID.withValue(sID) {
            try await recallTool.execute(arguments: callArgs, profile: .workspace)
        }

        #expect(output.contains("[Context Object Slice: \(objectID.rawValue)]"))
        #expect(output.contains("Lines: 1 - 20 of 100"))
        #expect(output.contains("Has More: true"))
        #expect(output.contains("Item #1:"))
        #expect(output.contains("Item #20:"))

        // 2. 召回不存在的对象 -> 友好提示
        let notFoundArgs = "{\"id\":\"obj_unknown_call999_00000000\"}"
        let notFoundOut = try await ToolExecutionContext.$sessionID.withValue(sID) {
            try await recallTool.execute(arguments: notFoundArgs, profile: .workspace)
        }
        #expect(notFoundOut.contains("not found"))

        // 3. 非法字符 ID -> 错误提示
        let invalidArgs = "{\"id\":\"../evil_path\"}"
        let invalidOut = try await ToolExecutionContext.$sessionID.withValue(sID) {
            try await recallTool.execute(arguments: invalidArgs, profile: .workspace)
        }
        #expect(invalidOut.contains("Invalid ContextObjectID format"))
    }

    @Test func observationProjectionFeatureFlagDisabled() async {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            eCorePersistenceEnabled: true,
            observationProjectionEnabled: false, // OFF
            objectizationThreshold: 10_240,
            fullSendCount: 2
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let projection = ContextProjection(configuration: config)

        let sID = SessionID("proj-session-off")
        let toolCallID = ToolCallID("call_off")
        let largeContent = String(repeating: "Row data content\n", count: 800) // ~13KB

        let toolResult = ToolResult(
            callID: toolCallID,
            success: true,
            content: largeContent,
            toolName: "shell"
        )
        let toolMsg = Message(id: MessageID("msg_tool_off"), role: .tool, parts: [.toolResult(toolResult)], createdAt: .now)
        let asst1 = Message(id: MessageID("msg_asst_1"), role: .assistant, parts: [.text("1")], createdAt: .now)
        let asst2 = Message(id: MessageID("msg_asst_2"), role: .assistant, parts: [.text("2")], createdAt: .now)
        let asst3 = Message(id: MessageID("msg_asst_3"), role: .assistant, parts: [.text("3")], createdAt: .now)
        let session = Session(id: sID, createdAt: .now, messages: [toolMsg, asst1, asst2, asst3])

        let entry = ContextEntry(messageID: toolMsg.id, role: .tool, source: .toolResult, part: .toolResult(toolResult))
        let projected = await projection.project(entries: [entry], session: session, ecoreStore: store)

        // Feature flag is off, so full content must always be returned
        if case let .toolResult(res) = projected[0].part {
            #expect(res.content == largeContent)
        } else {
            Issue.record("Expected toolResult")
        }
    }

    // MARK: - E-Core 对象来源（PE/Git 语义冻结 第八、九节）

    /// 冻结语义：objectID 只是内容身份；来源、session、turn 属于引用层。
    @Test func objectIdentityIsContentAddressedAndReferenceCarriesProvenance() throws {
        let content = "同一份被移出的工具输出"
        let fromMessage = ContextObjectID.identify(content: content)
        let fromTool = ContextObjectID.identify(content: content)
        #expect(fromMessage == fromTool, "相同 payload 必须得到同一对象身份，与来源无关")
        #expect(try ContextObjectID(fromMessage.rawValue).rawValue == fromMessage.rawValue, "ID 必须通过非丢弃式校验器")
        #expect(fromMessage.rawValue.count <= 128)

        let different = ContextObjectID.identify(content: content + "!")
        #expect(different != fromMessage, "内容变化必须改变身份，否则去重会吞掉差异")

        // 引用层承载来源语义：同一 payload 的两个不同引用各自独立，互不覆盖。
        let toolRef = ECoreReference(
            objectID: fromMessage, sessionID: SessionID("s1"), origin: .toolCall,
            contextOccurrenceID: "occ-a", evictionEpoch: 1, summary: "shell 输出摘要", toolCallID: ToolCallID("call_a"), toolName: "shell"
        )
        let messageRef = ECoreReference(
            objectID: fromMessage, sessionID: SessionID("s1"), origin: .message,
            contextOccurrenceID: "occ-b", evictionEpoch: 1, summary: "历史消息摘要", createdTurn: 12
        )
        #expect(toolRef.referenceID != messageRef.referenceID)
        #expect(toolRef.objectID == messageRef.objectID, "两条引用共享对象，但各自保留自己的来源元数据")
        #expect(messageRef.toolCallID == nil, "非工具引用不得伪造 toolCallID")

        // 重试幂等：同一 occurrence、同一 epoch 得到同一引用。
        let retry = ECoreReference(
            objectID: fromMessage, sessionID: SessionID("s1"), origin: .message,
            contextOccurrenceID: "occ-b", evictionEpoch: 1, summary: "换了摘要", createdTurn: 12
        )
        #expect(retry.referenceID == messageRef.referenceID, "同一次 page-out 重试必须落回同一条引用")

        // occurrence 身份：同一 occurrence 在更晚的淘汰事件里再被移出，是第二条引用，对象仍是同一个。
        let laterEpoch = ECoreReference(
            objectID: fromMessage, sessionID: SessionID("s1"), origin: .message,
            contextOccurrenceID: "occ-b", evictionEpoch: 2, summary: "Turn 40 再次移出", createdTurn: 40
        )
        #expect(laterEpoch.referenceID != messageRef.referenceID, "不同 page-out occurrence 不得合并成一条引用")
        #expect(laterEpoch.objectID == messageRef.objectID, "occurrence 不同但 payload 相同，对象必须仍是同一个")
    }

    /// 磁盘上已存在的 .meta.json 不含 origin 字段。旧格式必须继续可解码并被当作工具产物处理，
    /// 否则本次扩展就是一次不兼容的持久化变更。
    @Test func legacyMetadataFileWithoutOriginStillDecodesAsToolArtifact() throws {
        let current = ObservationMetadata(
            objectID: ContextObjectID(unchecked: "obj_read_file_call_a1b2_0000dead"),
            toolCallID: ToolCallID("call_a1b2"),
            toolName: "read_file",
            totalLines: 10,
            totalBytes: 100,
            contentHash: "beef",
            origin: .message
        )
        let payload = try #require(
            (try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        )
        // 先确认新格式确实带 origin，去掉它才等价于改动前写入的旧文件。
        #expect(payload["origin"] != nil)
        var legacyPayload = payload
        legacyPayload.removeValue(forKey: "origin")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyPayload)

        let decoded = try JSONDecoder().decode(ObservationMetadata.self, from: legacyData)
        #expect(decoded.origin == nil)
        #expect(decoded.isToolArtifact, "无 origin 的历史对象仍应随 toolCallID 生死")

        let roundTrip = try JSONDecoder().decode(ObservationMetadata.self, from: JSONEncoder().encode(current))
        #expect(roundTrip.origin == .message)
        #expect(!roundTrip.isToolArtifact)
    }

    /// 冻结语义：E-Core 是必选逻辑核心。关闭的只能是持久化能力，不是 E-Core 本身 ——
    /// persistence=false 时 store() 仍必须返回稳定 ECoreObjectID，page-out → Exact Restore 生命周期不变。
    @Test func persistenceDisabledStillYieldsStableIDsAndExactRestore() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            eCorePersistenceEnabled: false,
            observationProjectionEnabled: true,
            objectizationThreshold: 1,
            fullSendCount: 2
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let session = SessionID("in-memory-ecore")
        let content = "被移出 P-Core 的历史工具输出，只能活在内存里"

        let meta = try #require(await store.store(sessionID: session, toolCallID: ToolCallID("call_mem"), toolName: "shell", content: content, force: true),
                                            "关闭持久化不得让 store() 拒绝写入")

        // ID 必须与后端选择无关：同样的内容在持久化后端上得到同一个 objectID，
        // 否则 Index 投影与 Exact Restore 会随配置漂移。
        let tempDir2 = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir2) }
        let diskBacked = ECoreObjectStore(baseDirectory: tempDir2, configuration: ContextObjectFabricConfiguration(
            eCorePersistenceEnabled: true,
            observationProjectionEnabled: true,
            objectizationThreshold: 1,
            fullSendCount: 2
        ))
        let diskMeta = try #require(await diskBacked.store(sessionID: session, toolCallID: ToolCallID("call_mem"), toolName: "shell", content: content, force: true))
        #expect(meta.objectID == diskMeta.objectID, "objectID 不得随持久化后端改变")

        let restored = try await store.fetch(sessionID: session, objectID: meta.objectID)
        #expect(restored == content, "persistence=false 仍必须能按 objectID 精确取回")
        #expect(await store.hasObject(sessionID: session, objectID: meta.objectID))

        let diskRestored = try await diskBacked.fetch(sessionID: session, objectID: diskMeta.objectID)
        #expect(diskRestored == content)

        // 关闭持久化 = 载荷不落盘。遥测事件另算，所以只断言没有载荷文件。
        let scanned = FileManager.default.enumerator(
            at: tempDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )?.allObjects as? [URL] ?? []
        let strayPayloads = scanned.map(\.lastPathComponent).filter {
            $0.hasSuffix(".txt") || $0.hasSuffix(".meta.json")
        }
        #expect(strayPayloads.isEmpty, "persistence=false 不应落盘载荷：\(strayPayloads)")

        // 会话结束载荷消失是明确语义，不是运行期数据丢失。
        await store.cleanSession(sessionID: session)
        #expect(try await store.fetch(sessionID: session, objectID: meta.objectID) == nil)
    }

    /// rewind 的 prune 只能裁剪工具产物。P-Core 移出的 Message 若被一起删，
    /// Exact Restore 会在一次撤回之后静默失效。
    @Test func pruneKeepsPageOutMessagesAndStillDropsForeignToolArtifacts() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            eCorePersistenceEnabled: true,
            observationProjectionEnabled: true,
            objectizationThreshold: 1,
            fullSendCount: 2
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let session = SessionID("prune-origin-test")

        let kept = ToolCallID("call_kept")
        let foreign = ToolCallID("call_foreign")
        #expect(await store.store(sessionID: session, toolCallID: kept, toolName: "shell", content: "kept artifact", force: true) != nil)
        #expect(await store.store(sessionID: session, toolCallID: foreign, toolName: "shell", content: "foreign artifact", force: true) != nil)

        let objectsDir = try #require(Self.findObjectsDirectory(under: tempDir))
        let messageID = ContextObjectID.identify(content: "被移出的历史用户消息")
        try "被移出的历史用户消息".write(to: objectsDir.appending(path: "\(messageID.rawValue).txt"), atomically: false, encoding: .utf8)
        let messageMeta = ObservationMetadata(
            objectID: messageID,
            toolCallID: ToolCallID("msg-7"),
            toolName: "message",
            totalLines: 1,
            totalBytes: 27,
            contentHash: "deadbeef",
            origin: .message
        )
        try JSONEncoder().encode(messageMeta).write(to: objectsDir.appending(path: "\(messageID.rawValue).meta.json"), options: [])

        // 先确认 prune 真的能看见这个手写对象，否则下面的"存活"断言是空转通过。
        let visibleBeforePrune = await store.hasObject(sessionID: session, objectID: messageID)
        #expect(visibleBeforePrune, "测试前置失败：prune 根本扫不到该对象，下面的断言将失去意义")

        await store.prune(sessionID: session, keepingToolCallIDs: [kept])

        // Object identity is content-addressed for every new write
        // (`ECoreObjectID = SHA256(canonicalPayloadBytes)`), so the test resolves the same bytes
        // the two `store()` calls above wrote rather than re-deriving a legacy tool-scoped id.
        let keptID = ContextObjectID.identify(content: "kept artifact")
        let foreignID = ContextObjectID.identify(content: "foreign artifact")
        let messageSurvives = await store.hasObject(sessionID: session, objectID: messageID)
        let foreignSurvives = await store.hasObject(sessionID: session, objectID: foreignID)
        let keptSurvives = await store.hasObject(sessionID: session, objectID: keptID)

        #expect(messageSurvives, "非工具来源对象不得被 rewind 裁剪删除")
        #expect(!foreignSurvives, "外来工具产物仍应被裁剪")
        #expect(keptSurvives)
    }

    /// 冻结：payload 去重不得合并、覆盖或跨 session 串用引用元数据；
    /// 且只有最后一个引用消失时才回收 payload。
    @Test func pageOutDeduplicatesPayloadWithoutMergingReferences() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            eCorePersistenceEnabled: true, observationProjectionEnabled: true, objectizationThreshold: 1, fullSendCount: 2
        )
        let store = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let session = SessionID("dedup-test")
        let payload = "同一份被两次移出的测试日志"

        let first = await store.pageOut(sessionID: session, content: payload, origin: .message, contextOccurrenceID: "msg-1", evictionEpoch: 1, summary: "第一次移出的摘要", createdTurn: 3)
        let second = await store.pageOut(sessionID: session, content: payload, origin: .page, contextOccurrenceID: "page-9", evictionEpoch: 1, summary: "第二次移出的摘要", createdTurn: 7)

        #expect(first.objectID == second.objectID, "相同 payload 必须去重到同一对象")
        #expect(first.referenceID != second.referenceID, "两次 occurrence 必须是两条独立引用")
        #expect(first.summary != second.summary, "摘要不得被后一次覆盖")

        // 契约的头号例子：同一 occurrence 在更晚的淘汰事件里再被移出 → 新引用、同对象。
        let reEvicted = await store.pageOut(sessionID: session, content: payload, origin: .message, contextOccurrenceID: "msg-1", evictionEpoch: 2, summary: "Turn 40 再次移出", createdTurn: 40)
        #expect(reEvicted.referenceID != first.referenceID, "occurrence 生命周期不得因 payload 去重而合并")
        #expect(reEvicted.objectID == first.objectID)
        #expect(await store.references(sessionID: session).count == 3)

        // payload 只落一份文件。
        let payloadsDir = Self.storePayloadsDir(under: tempDir, session: "dedup-test")
        let objectFiles = try FileManager.default.contentsOfDirectory(
            at: payloadsDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "txt" }.map(\.lastPathComponent)
        #expect(objectFiles.count == 1, "去重后同一 session 内只应有一份 payload 文件：\(objectFiles)")

        // 引用计数逐级递减时 payload 必须存活，直到最后一条引用消失才回收。
        await store.dropReference(sessionID: session, referenceID: first.referenceID)
        #expect(try await store.restore(sessionID: session, referenceID: second.referenceID) == payload, "仍有引用指向时 payload 不得被回收")
        await store.dropReference(sessionID: session, referenceID: second.referenceID)
        #expect(try await store.restore(sessionID: session, referenceID: reEvicted.referenceID) == payload, "最后一条引用仍在时 payload 不得被回收")
        await store.dropReference(sessionID: session, referenceID: reEvicted.referenceID)
        #expect(await store.references(sessionID: session).isEmpty)
        #expect(try await store.restore(sessionID: session, referenceID: reEvicted.referenceID) == nil, "最后一个引用消失后 payload 应回收")
    }

    /// Exact Restore 必须跨重启成立：Index 里留的 referenceID 是持久标识，不是进程内句柄。
    @Test func exactRestoreSurvivesRestartWithoutSemanticSearch() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ContextObjectFabricConfiguration(
            eCorePersistenceEnabled: true, observationProjectionEnabled: true, objectizationThreshold: 1, fullSendCount: 2
        )
        let payload = "需要按原样取回的完整上下文对象"
        let reference = await ECoreObjectStore(baseDirectory: tempDir, configuration: config)
            .pageOut(sessionID: SessionID("restore-test"), content: payload, origin: .toolCall, contextOccurrenceID: "occ_1", evictionEpoch: 1, summary: "s", toolCallID: ToolCallID("call_1"), toolName: "shell")

        // 全新实例：模拟进程重启，只有 referenceID 可用。
        let reopened = ECoreObjectStore(baseDirectory: tempDir, configuration: config)
        let restored = try await reopened.restore(sessionID: SessionID("restore-test"), referenceID: reference.referenceID)
        #expect(restored == payload, "Exact Restore 必须逐字还原，不能靠检索近似")

        // 跨 session 不可见。
        let other = try await reopened.restore(sessionID: SessionID("someone-else"), referenceID: reference.referenceID)
        #expect(other == nil, "引用不得跨 session 解析")
    }

    private static func storePayloadsDir(under root: URL, session: String) -> URL {
        root.appending(path: session, directoryHint: .isDirectory).appending(path: "objects", directoryHint: .isDirectory)
    }

    /// `sessionObjectsDirectory` 是私有的，测试按磁盘布局定位对象目录，不为此放宽生产可见性。
    private static func findObjectsDirectory(under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".meta.json") {
            return url.deletingLastPathComponent()
        }
        return nil
    }
}
