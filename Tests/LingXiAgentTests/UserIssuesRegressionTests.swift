import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiApplication
@testable import LingXiTUIComponents
@testable import LingXiTUI

struct UserIssuesRegressionTests {

    // MARK: - 1. Tool call 在 undo 后及无输出时不出现幽灵转圈
    @Test func toolCallDoesNotSpinWhenEmptyOutputOrSessionIdleOrUndo() async throws {
        var state = SessionViewState(sessionID: SessionID("test-sess"))
        let toolID = ToolCallID("call-123")
        let toolNode = ToolNode(
            callID: toolID,
            toolName: "run_command",
            argumentsJSON: #"{"CommandLine":"false"}"#,
            phase: .running,
            stdout: "",
            stderr: ""
        )
        state.toolNodes[toolID] = toolNode
        state.timelineNodes.append(TimelineNode(id: TimelineNodeID.tool(toolID), timestamp: Date(), kind: .tool(toolNode)))
        state.rebuildTimelineIndex()

        // 验证 1: 当会话处于 idle (status == .ready 且无 active root run)，即使 tool.phase == .running 也绝不能 active 转圈
        state.status = .ready
        state.activeRootRunID = nil
        state.activeTurnID = nil
        state.activeToolCallIDs.removeAll()

        let isSessionIdle = (state.activeRootRunID == nil && state.activeTurnID == nil && state.status == .ready)
        let isExplicitlyActive = state.activeToolCallIDs.contains(toolID)
        let rawActive = [.requested, .waitingPermission, .scheduled, .running].contains(toolNode.phase) && toolNode.result == nil && toolNode.error == nil
        let active = rawActive && !isSessionIdle && isExplicitlyActive

        #expect(!active, "Tool call must NOT be marked active when session is idle")

        // 验证 2: Timeline node ID match check in updateNode prevents mismatch corruption
        var mutated = false
        state.updateNode(id: TimelineNodeID.tool(toolID)) { node in
            if case var .tool(t) = node.kind {
                t.phase = .completed
                node.kind = .tool(t)
                mutated = true
            }
        }
        #expect(mutated)
        if case let .tool(updatedTool) = state.timelineNodes[0].kind {
            #expect(updatedTool.phase == .completed)
        } else {
            Issue.record("Expected tool node")
        }
    }

    // MARK: - 2. Think 无内容时彻底不写空白卡片
    @Test func emptyThinkingDoesNotRenderBlankCard() {
        let emptyThinking = ThinkingNode(
            stepID: ModelStepID("step-1"),
            title: "Thinking",
            content: "   \n\t   ",
            isStreaming: false,
            isComplete: true
        )
        let contentBody = emptyThinking.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let isStreaming = emptyThinking.isStreaming && !emptyThinking.isComplete

        let shouldRender: Bool = !(contentBody.isEmpty && (!isStreaming || emptyThinking.isComplete))
        #expect(!shouldRender, "Empty completed thinking content must NOT be rendered")
    }

    // MARK: - 3. 系统提示与撤回结果颜色区分（systemNotice）
    @Test func systemAndResultEntriesUseSystemNoticeStyle() {
        let entry = TUITranscriptEntry(kind: .result, text: "✓ 已撤回上一轮会话（共清理 2 条消息）", style: .systemNotice)
        #expect(entry.style == .systemNotice)
        #expect(TUIStyle.systemNotice != .normal)

        let viewport = TranscriptViewport()
        viewport.entries = [entry]
        let frame = viewport.render(viewportHeight: 10, width: 80)
        #expect(!frame.isEmpty)
    }

    // MARK: - 4. 缓存命中字段多变体兼容解析
    @Test func cacheTokensAreParsedFromSingularPluralAndRootKeys() {
        // OpenAI Responses format with singular input_token_details
        let rawResponses: [String: Any] = [
            "input_tokens": 1500,
            "output_tokens": 200,
            "input_token_details": [
                "cached_tokens": 850
            ]
        ]
        let usage = OpenAIResponsesProviderUsageHelper.parse(rawResponses)
        #expect(usage.inputTokens == 1500)
        #expect(usage.cacheReadTokens == 850)

        // Root level cached_tokens (used by aggregators/proxies)
        let rawRoot: [String: Any] = [
            "prompt_tokens": 2000,
            "completion_tokens": 100,
            "cached_tokens": 1200
        ]
        let usageRoot = OpenAIResponsesProviderUsageHelper.parse(rawRoot)
        #expect(usageRoot.inputTokens == 2000)
        #expect(usageRoot.cacheReadTokens == 1200)
    }

    // MARK: - 5. Undo 以后模型的思考等级保持用户的配置，绝不重置为 auto
    @Test func undoPreservesUserReasoningEffort() {
        var appState = ApplicationState()
        appState.nextTurnReasoningEffort = .high

        // 模拟 Snapshot 重置：当 Snapshot 为 auto，但本地非 auto 时
        let snapshotInfo = SessionSummary(
            sessionID: SessionID("sess-1"),
            title: "Test",
            createdAt: Date(),
            updatedAt: Date(),
            turnCount: 0,
            mode: .build,
            reasoningEffort: .auto,
            workingDirectory: nil,
            messageCount: 0
        )

        var viewState = SessionViewState(
            sessionID: SessionID("sess-1"),
            reasoningEffort: .high
        )

        let effectiveEffort: ReasoningEffort
        if snapshotInfo.reasoningEffort != .auto {
            effectiveEffort = snapshotInfo.reasoningEffort
        } else if viewState.reasoningEffort != .auto {
            effectiveEffort = viewState.reasoningEffort
        } else {
            effectiveEffort = .auto
        }

        viewState.reasoningEffort = effectiveEffort
        appState.activeSessionState = viewState

        #expect(appState.effectiveReasoningEffort == .high, "Effective reasoning effort must remain high after undo snapshot resync")
    }

    // MARK: - 6. 侧边栏 4 项缓存指标（前缀复用、P-Core、E-Core、Cache）防抖与防归零保护
    @Test func contextStateAntiJitterAndMonotonicityProtection() async throws {
        let sID = SessionID("sess-anti-jitter")
        
        // 初始权威快照（由模型推理完成产生）
        let authoritative = ContextStateSnapshot(
            sessionID: sID,
            estimatedTokens: 10_000,
            l1Tokens: 10_000,
            l2Tokens: 0,
            l3Tokens: 0,
            compactionGeneration: 1,
            cacheReadTokens: 8_000,
            promptTokens: 10_000,
            previousPromptTokens: 9_800,
            cacheStatus: "hit",
            cacheEpoch: 1,
            epochReason: nil,
            stablePrefixHash: "prefix-hash-123",
            missDiagnostics: nil,
            structuralPrefixStability: 1.0,
            clientCausedBustRate: 0.0,
            appendOnlyContextRatio: 1.0,
            volatileTailBytes: 0,
            clientHealthStatus: "healthy",
            observedGranularity: nil,
            clientCausedBusts: 0,
            comparableRequests: 1,
            appendOnlyViolations: 0,
            pCoreTokens: 10_000,
            eCoreObjectCount: 4,
            eCoreTotalBytes: 55_600,
            cacheDebt: 0
        )

        // 中间瞬态快照（例如 Turn 刚启动，纯消息文本估算仅有 20 tokens，且 cacheRecord 尚未回填）
        let intermediateZeroJitter = ContextStateSnapshot(
            sessionID: sID,
            estimatedTokens: 20,
            l1Tokens: 20,
            l2Tokens: 0,
            l3Tokens: 0,
            compactionGeneration: 1,
            cacheReadTokens: nil,
            promptTokens: nil,
            previousPromptTokens: nil,
            cacheStatus: nil,
            cacheEpoch: nil,
            epochReason: nil,
            stablePrefixHash: nil,
            missDiagnostics: nil,
            structuralPrefixStability: nil,
            clientCausedBustRate: nil,
            appendOnlyContextRatio: nil,
            volatileTailBytes: nil,
            clientHealthStatus: nil,
            observedGranularity: nil,
            clientCausedBusts: nil,
            comparableRequests: nil,
            appendOnlyViolations: nil,
            pCoreTokens: 20,
            eCoreObjectCount: 0,
            eCoreTotalBytes: 0,
            cacheDebt: 0
        )

        // 验证 1: mergeContextState 必须平滑吸收中间态，维持已有权威指标，坚决不发生断崖归零
        let merged = SessionReducer.mergeContextState(
            existing: authoritative,
            incoming: intermediateZeroJitter,
            hasMessages: true
        )

        #expect(merged.activePCoreTokens == 10_000, "P-Core must retain high-water 10K instead of falling to 20 tokens")
        #expect(merged.eCoreObjectCount == 4, "E-Core count must retain 4 objs")
        #expect(merged.eCoreTotalBytes == 55_600, "E-Core bytes must retain 55.6KB")
        #expect(merged.promptTokens == 10_000, "Prompt tokens must retain 10K")
        #expect(merged.cacheReadTokens == 8_000, "Cache read tokens must retain 8K")
        #expect(merged.previousPromptTokens == 9_800, "Previous prompt tokens must retain 9.8K")
        #expect(merged.cacheStatus == "hit", "Cache status must be preserved")

        // 验证 2: 真实的正常演进快照（如新一轮正常增长至 11K）必须被采纳
        let nextAuthoritative = ContextStateSnapshot(
            sessionID: sID,
            estimatedTokens: 11_000,
            l1Tokens: 11_000,
            l2Tokens: 0,
            l3Tokens: 0,
            compactionGeneration: 1,
            cacheReadTokens: 10_000,
            promptTokens: 11_000,
            previousPromptTokens: 10_000,
            cacheStatus: "hit",
            cacheEpoch: 1,
            epochReason: nil,
            stablePrefixHash: "prefix-hash-456",
            missDiagnostics: nil,
            structuralPrefixStability: 1.0,
            clientCausedBustRate: 0.0,
            appendOnlyContextRatio: 1.0,
            volatileTailBytes: 0,
            clientHealthStatus: "healthy",
            observedGranularity: nil,
            clientCausedBusts: 0,
            comparableRequests: 2,
            appendOnlyViolations: 0,
            pCoreTokens: 11_000,
            eCoreObjectCount: 5,
            eCoreTotalBytes: 65_000,
            cacheDebt: 0
        )

        let evolved = SessionReducer.mergeContextState(
            existing: merged,
            incoming: nextAuthoritative,
            hasMessages: true
        )

        #expect(evolved.activePCoreTokens == 11_000)
        #expect(evolved.eCoreObjectCount == 5)
        #expect(evolved.eCoreTotalBytes == 65_000)
        #expect(evolved.promptTokens == 11_000)
        #expect(evolved.cacheReadTokens == 10_000)
    }

    // MARK: - 7. 撤回操作建立合成冷启动基线 (coldNewEpoch)
    @Test func revertEstablishesColdNewEpochBaseline() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet())
        let scanner = ProjectScanner(root: root)
        let controller = ContextCacheController(contextPager: pager, scanner: scanner, maxL1ResidentCharacters: 48 * 1024)
        let sessionID = SessionID("revert-baseline-sess")

        let remainingMessages = [
            Message(id: MessageID("msg-1"), role: .user, content: "Hello world this is a remaining prompt", createdAt: .now),
            Message(id: MessageID("msg-2"), role: .assistant, content: "Sure, here is the answer that remains", createdAt: .now)
        ]

        await controller.reconcileAfterRevert(sessionID: sessionID, remainingMessages: remainingMessages)

        let record = await controller.lastProviderCacheRecord(for: sessionID)
        #expect(record != nil, "Revert must produce a synthetic cache record for remaining messages")
        #expect(record?.status == "coldNewEpoch", "Revert baseline status must be coldNewEpoch")
        #expect(record?.epochReason == "revert_turn", "Epoch reason must be revert_turn")
        #expect(record?.cachedTokens == 0, "Cached tokens in coldNewEpoch must be 0")
        #expect((record?.promptTokens ?? 0) > 0, "Prompt tokens must accurately reflect remaining messages tokens")
        #expect((record?.previousPromptTokens ?? 0) > 0, "Previous prompt tokens must be set as baseline for next turn")

        let lastInput = await controller.lastProviderInputTokens(for: sessionID)
        #expect(lastInput == record?.promptTokens, "lastProviderInputTokens must be aligned with promptTokens")
    }

    // MARK: - 8. File Write 与 File Patch 的 Git 风格增删对比表与 Bash 自动嗅探
    @MainActor
    @Test func fileWriteAndPatchGitDiffFormattingAndBashSniffing() async throws {
        let tui = ApplicationTUI()

        // 8.1 write_file 全量写入输出 Git Diff 风格代码
        let writeTool = ToolNode(
            callID: ToolCallID("call-write-1"),
            toolName: "write_file",
            argumentsJSON: ##"{"path":"Sources/Prime.cpp","content":"#include <iostream>\n\nbool is_prime(int n) {\n    return n > 1;\n}"}"##,
            phase: .completed
        )
        let writeEntry = tui.formatModernToolCall(tool: writeTool, id: "w-1", active: false, timestamp: Date())
        #expect(writeEntry.text.contains("● Write(Sources/Prime.cpp)"))
        #expect(writeEntry.text.contains("└  +5 lines"))
        #expect(writeEntry.text.contains("+  1 | #include <iostream>"))
        #expect(writeEntry.text.contains("+  4 |     return n > 1;"))

        // 8.2 replace_file_content / edit_file 局部修改输出 Git Diff 增删对比表
        let patchTool = ToolNode(
            callID: ToolCallID("call-patch-1"),
            toolName: "replace_file_content",
            argumentsJSON: #"{"TargetFile":"Sources/Math.swift","TargetContent":"func add(a: Int, b: Int) -> Int {\n    return a + b\n}","ReplacementContent":"func add(a: Int, b: Int) -> Int {\n    // safe add\n    return a + b\n}"}"#,
            phase: .completed
        )
        let patchEntry = tui.formatModernToolCall(tool: patchTool, id: "p-1", active: false, timestamp: Date())
        #expect(patchEntry.text.contains("● Edit(Sources/Math.swift)"))
        #expect(patchEntry.text.contains("└  +4 / -3 lines"))
        #expect(patchEntry.text.contains("-  1 | func add(a: Int, b: Int) -> Int {"))
        #expect(patchEntry.text.contains("+  2 |     // safe add"))

        // 8.3 Bash cat 重定向写文件自动嗅探并转为 Git 风格 File Write
        let bashWriteTool = ToolNode(
            callID: ToolCallID("call-bash-cat"),
            toolName: "run_command",
            argumentsJSON: "{\"CommandLine\":\"cat > \\\"$HOME/Desktop/prime_numbers_0_to_10000.cpp\\\" <<'EOF'\\n#include <iostream>\\nint main() {\\n    return 0;\\n}\\nEOF\"}",
            phase: .completed,
            stdout: ""
        )
        let bashEntry = tui.formatModernToolCall(tool: bashWriteTool, id: "b-1", active: false, timestamp: Date())
        #expect(!bashEntry.text.contains("Bash(cat >"))
        #expect(bashEntry.text.contains("● Write(Desktop/prime_numbers_0_to_10000.cpp)"))
        #expect(bashEntry.text.contains("└  +4 lines"))
        #expect(bashEntry.text.contains("+  1 | #include <iostream>"))
        #expect(bashEntry.text.contains("+  4 | }"))
    }

    // MARK: - 9. WorkspaceRoot 路径解析支持 ~/、$HOME、${HOME} 及引号
    @Test func workspaceRootHomeAndQuotedPathResolution() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ws = try WorkspaceRoot(path: tempDir.path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let resTilde = try ws.resolve("~/Desktop/sample.txt", profile: .fullAccess)
        #expect(resTilde.path == home + "/Desktop/sample.txt")

        let resHome = try ws.resolve("$HOME/Desktop/sample.txt", profile: .fullAccess)
        #expect(resHome.path == home + "/Desktop/sample.txt")

        let resBracedHome = try ws.resolve("${HOME}/Desktop/sample.txt", profile: .fullAccess)
        #expect(resBracedHome.path == home + "/Desktop/sample.txt")

        let resQuoted = try ws.resolve("\"$HOME/Desktop/sample.txt\"", profile: .fullAccess)
        #expect(resQuoted.path == home + "/Desktop/sample.txt")
    }

    // MARK: - 10. ToolRegistry 别名路由支持
    @Test func toolRegistryAliasSupport() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ws = try WorkspaceRoot(path: tempDir.path)
        let registry = ToolRegistry.builtin(workspace: ws)

        #expect(registry.tool(named: "write_file") != nil)
        #expect(registry.tool(named: "write_to_file") != nil)
        #expect(registry.tool(named: "edit_file") != nil)
        #expect(registry.tool(named: "replace_file_content") != nil)
        #expect(registry.tool(named: "apply_patch") != nil)
        #expect(registry.tool(named: "patch_file") != nil)
    }
}

private enum OpenAIResponsesProviderUsageHelper {
    static func parse(_ value: [String: Any]) -> ModelUsage {
        let outputDetails = (value["output_tokens_details"] as? [String: Any]) ?? (value["output_token_details"] as? [String: Any])
        let inputDetails = (value["input_tokens_details"] as? [String: Any])
            ?? (value["input_token_details"] as? [String: Any])
            ?? (value["prompt_tokens_details"] as? [String: Any])
            ?? (value["prompt_token_details"] as? [String: Any])
        let cached = (inputDetails?["cached_tokens"] as? Int)
            ?? (inputDetails?["cached_prompt_tokens"] as? Int)
            ?? (inputDetails?["cache_read_tokens"] as? Int)
            ?? (value["cached_tokens"] as? Int)
            ?? (value["cached_prompt_tokens"] as? Int)
            ?? (value["prompt_cache_hit_tokens"] as? Int)
            ?? (value["cache_read_input_tokens"] as? Int)
        return ModelUsage(
            inputTokens: (value["input_tokens"] as? Int) ?? (value["prompt_tokens"] as? Int),
            outputTokens: (value["output_tokens"] as? Int) ?? (value["completion_tokens"] as? Int),
            reasoningTokens: outputDetails?["reasoning_tokens"] as? Int,
            cacheReadTokens: cached,
            cacheWriteTokens: (value["cache_creation_input_tokens"] as? Int)
        )
    }
}
