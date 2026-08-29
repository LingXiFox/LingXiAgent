import Foundation
import LingXiClient
import LingXiProtocol

// LingXiAgent Reference TUI（Session Chat）。
// 通路：LingXiTUI → LingXiClient → LingXiProtocol → Core。
// TUI 不知道 Core 内部实现，不保存权威会话历史——历史查询走 getSession。

private let dim = "\u{1B}[2m"
private let reset = "\u{1B}[0m"

private func emit(_ text: String) {
    print(text, terminator: "")
    fflush(stdout)
}

// MARK: - 启动横幅

func showBanner(_ client: LingXiClient) async -> Bool {
    do {
        let state = try await client.coreState()
        guard state == .ready else {
            FileHandle.standardError.write(Data("Core 状态异常: \(state.rawValue)\n".utf8))
            return false
        }
        print("Core Ready")

        let info = try await client.coreInfo()
        print("Core Version: \(info.version)")
        try await client.ping()
        print("Ping: Pong")

        let status = try await client.providerStatus()
        if status.configured {
            print("Provider: configured")
            print("Model: \(status.model ?? "?")")
        } else {
            print("Provider: not configured")
            print("\(dim)缺少环境变量: \(status.missingRequirements.joined(separator: ", "))\(reset)")
        }
        return true
    } catch {
        FileHandle.standardError.write(Data("TUI 启动失败: \(error)\n".utf8))
        return false
    }
}

// MARK: - 一轮对话（reasoning / text 分流显示）

func runTurn(_ client: LingXiClient, sessionID: SessionID, content: String) async {
    do {
        let stream = try await client.sendMessage(sessionID: sessionID, content: content)
        var currentKind: StreamChunkKind?
        for try await chunk in stream {
            if chunk.kind != currentKind {
                if currentKind != nil { emit("\n") }
                currentKind = chunk.kind
                switch chunk.kind {
                case .reasoning: emit("thinking:\n")
                case .text: emit("assistant:\n")
                }
            }
            emit(chunk.text)
        }
        print()
    } catch let error as CoreError {
        print("\(dim)[error: \(error.code.rawValue): \(error.message)]\(reset)")
    } catch {
        print("\(dim)[error: \(error)]\(reset)")
    }
}

// MARK: - history

func showHistory(_ client: LingXiClient, sessionID: SessionID) async {
    do {
        let snapshot = try await client.session(sessionID)
        print("\(dim)Session \(snapshot.id.rawValue) (\(snapshot.messages.count) messages)\(reset)")
        for message in snapshot.messages {
            let who: String
            switch message.role {
            case .user: who = "user"
            case .assistant: who = "assistant"
            case .tool: who = "tool"
            }
            let content = message.content.replacingOccurrences(of: "\n", with: " ")
            print("\(dim)[\(who)] \(content)\(reset)")
        }
    } catch {
        print("\(dim)[history 失败: \(error)]\(reset)")
    }
}

func showContext(_ client: LingXiClient, sessionID: SessionID) async {
    do {
        guard let snapshot = try await client.context(sessionID) else {
            print("\(dim)[尚无 L1 Context snapshot]\(reset)")
            return
        }
        print("L1 Context")
        print("Revision: \(snapshot.revision)")
        print("Messages: \(snapshot.messageCount)")
        print("Parts: \(snapshot.partCount)")
        print("Characters: \(snapshot.characterCount)")
        print("Session characters: \(snapshot.sessionCharacterCount)")
        print("Project pages: \(snapshot.projectPageCount)")
        print("Project characters: \(snapshot.projectCharacterCount)")
        for key in snapshot.sourceCounts.keys.sorted() { print("\(key): \(snapshot.sourceCounts[key] ?? 0)") }
        try await showCache(client)
    } catch { print("\(dim)[context 失败: \(error)]\(reset)") }
}

func showCache(_ client: LingXiClient) async throws {
    let cache = try await client.projectCache()
    print("L2: \(cache.l2Pages) pages / \(cache.l2Characters) chars / hit rate \(cache.l2HitRate.map { String(format: "%.1f", $0 * 100) + "%" } ?? "-")")
    print("L3: \(cache.l3Pages) pages / \(cache.symbolCount) symbols in \(cache.symbolIndexedFiles) Swift files / \(cache.referenceCount) references / \(cache.dependencyCount) dependencies / stale rebuilds \(cache.staleRebuilds)")
}

func showPerformance(_ client: LingXiClient, sessionID: SessionID) async {
    do {
        guard let report = try await client.performance(sessionID) else {
            print("\(dim)[性能调试未开启或尚无报告；设置 LINGXI_PERF_DEBUG=1]\(reset)")
            return
        }
        print("LingXi Performance Report")
        print("Turn total: \(String(format: "%.2f", report.totalMilliseconds)) ms")
        print("Core overhead: \(String(format: "%.2f", report.coreOverheadMilliseconds)) ms")
        print("Steps: \(report.stepCount)")
        if let firstText = report.firstTextMilliseconds { print("TTFT: \(String(format: "%.2f", firstText)) ms") }
        if let firstReasoning = report.firstReasoningMilliseconds { print("First reasoning: \(String(format: "%.2f", firstReasoning)) ms") }
        print("DMA text: \(report.textChunks) chunks / \(report.textCharacters) chars")
        print("DMA reasoning: \(report.reasoningChunks) chunks / \(report.reasoningCharacters) chars")
        if let rate = report.textCharactersPerSecond { print("Text throughput: \(String(format: "%.1f", rate)) chars/s") }
        if let rate = report.outputTokensPerSecond { print("Output throughput: \(String(format: "%.1f", rate)) tok/s") }
        if let paging = report.contextPaging {
            print("Context Paging")
            print("Context Query: \(paging.queryCharacters) chars / \(paging.queryTerms) terms")
            let turn = paging.turn
            let turnRate = turn.lookups == 0 ? "-" : String(format: "%.1f%%", Double(turn.hits) / Double(turn.lookups) * 100)
            print("L2 Turn: lookup \(turn.lookups) / hit \(turn.hits) / miss \(turn.misses) / hit rate \(turnRate)")
            print("L2 Turn: promotions \(turn.promotions) / evictions \(turn.evictions) / faults \(turn.pageFaults)")
            if let rate = paging.l2HitRate { print("L2 Project: lookup \(paging.l2Lookups) / hit \(paging.l2Hits) / miss \(paging.l2Misses) / hit rate \(String(format: "%.1f", rate * 100))%") }
            print("L2 Project: working set \(paging.l2Pages) pages / \(paging.l2Characters) chars / promotions \(paging.promotions) / evictions \(paging.evictions)")
            print("L3: \(paging.l3Pages) pages / initial files \(paging.initialIndexedFiles) / stale rebuilds \(paging.staleRebuilds)")
            print("Symbol Query Turn: hints \(turn.symbolHints) / exact \(turn.symbolExactMatches) [qualified \(turn.symbolQualifiedExactMatches) / fallback \(turn.symbolFallbackExactMatches)] / prefix \(turn.symbolPrefixMatches) / symbol pages \(turn.symbolCandidatePages)")
            print("Symbol Query Time: hints \(String(format: "%.2f", turn.symbolHintExtractionMilliseconds)) / exact \(String(format: "%.2f", turn.symbolExactLookupMilliseconds)) / prefix \(String(format: "%.2f", turn.symbolPrefixLookupMilliseconds)) / merge \(String(format: "%.2f", turn.symbolCandidateMergeMilliseconds)) / ranking \(String(format: "%.2f", turn.symbolRankingMilliseconds)) / total \(String(format: "%.2f", turn.symbolTotalMilliseconds)) ms")
            print("Reference Index: \(paging.referenceCount) references / resolved \(paging.resolvedReferenceCount) / ambiguous \(paging.ambiguousReferenceCount) / unresolved \(paging.unresolvedReferenceCount) / dependencies \(paging.dependencyCount) / files \(paging.referenceIndexedFiles)")
            print("Reference Query Turn: hints \(turn.relationHints) / direct \(turn.directReferenceHits) / dependency \(turn.dependencyHits) / related pages \(turn.relatedPages)")
            print("Reference Query Time: resolution \(turn.referenceResolutionMilliseconds) / expansion \(turn.referenceExpansionMilliseconds) ms")
            print("Retrieval Turn: lexical \(turn.lexicalCandidatePages) / source \(turn.currentSourceCandidates) / docs \(turn.documentationCandidates) / reference \(turn.referenceCandidates)")
            print("Scanner Turn: checked \(turn.scannerChecked) / rebuilt \(turn.scannerRebuilt) / \(turn.scannerMilliseconds) ms")
            print("Scanner Project: checked \(paging.filesChecked) / rebuilt \(paging.filesRebuilt) / \(paging.scanMilliseconds) ms")
            print("Pager Turn: candidates \(turn.candidatePages) / \(turn.candidateCharacters) chars; selected \(turn.selectedPages) / \(turn.selectedCharacters) chars; injected \(turn.injectedPages) / \(turn.injectedCharacters) chars")
            print("Retrieval: \(String(format: "%.2f", paging.retrievalMilliseconds)) ms / materialize: \(String(format: "%.2f", paging.materializationMilliseconds)) ms")
        }
        print("Permissions: auto \(report.permissions.autoApproved) / asked \(report.permissions.asked) / denied \(report.permissions.denied) / wait \(String(format: "%.2f", report.permissions.waitMilliseconds)) ms")
        for step in report.steps {
            print("Step \(step.step): dispatch \(String(format: "%.2f", step.modelDispatchMilliseconds)) ms / active \(String(format: "%.2f", step.streamMilliseconds)) ms / first event \(step.firstEventMilliseconds.map { String(format: "%.2f", $0) } ?? "-") ms / text \(step.firstTextMilliseconds.map { String(format: "%.2f", $0) } ?? "-") ms / reasoning \(step.firstReasoningMilliseconds.map { String(format: "%.2f", $0) } ?? "-") ms / tools \(step.toolCallCount)")
        }
        for tool in report.tools {
            print("Step \(tool.step) \(tool.toolName): permission \(String(format: "%.2f", tool.permissionWaitMilliseconds)) ms / execution \(String(format: "%.2f", tool.executionMilliseconds)) ms")
        }
    } catch { print("\(dim)[perf 失败: \(error)]\(reset)") }
}

// MARK: - 主流程

func runTUI() async {
    let client: LingXiClient
    do {
        client = try LingXiClient.stdioCore()
    } catch {
        FileHandle.standardError.write(Data("无法启动 LingXiCoreHost: \(error)\n".utf8))
        return
    }

    guard await showBanner(client) else { return }

    // 控制面事件：turn 结果异步打印。
    let eventLoop = Task {
        for await event in await client.events() {
            switch event {
            case let .turnCompleted(result):
                if let usage = result.usage {
                    var parts: [String] = []
                    if let input = usage.inputTokens { parts.append("in \(input)") }
                    if let output = usage.outputTokens { parts.append("out \(output)") }
                    if let reasoning = usage.reasoningTokens { parts.append("reasoning \(reasoning)") }
                    if !parts.isEmpty { print("\(dim)[usage: \(parts.joined(separator: " / "))]\(reset)") }
                }
                if let finish = result.finishReason {
                    print("\(dim)[finish: \(finish.rawValue)]\(reset)")
                }
            case let .turnFailed(failure):
                print("\(dim)[turn failed: \(failure.error.message)]\(reset)")
            case let .toolCallCompleted(call):
                print("\(dim)[tool call: \(call.toolID.rawValue)]\(reset)")
            case let .toolResult(result):
                let status = result.success ? "ok" : result.error?.message ?? "failed"
                print("\(dim)[tool result: \(status)]\(reset)")
            case let .permissionAsked(request):
                print("\nPermission required:")
                print("Tool: \(request.toolID.rawValue)")
                print("Path: \(request.resource)")
                print("[a] allow once  [d] deny")
                let decision: PermissionDecision = readLine()?.lowercased() == "a" ? .allow : .deny
                do {
                    try await client.replyPermission(PermissionReply(permissionID: request.permissionID, decision: decision))
                } catch {
                    print("\(dim)[permission reply failed: \(error)]\(reset)")
                }
            case .sessionCreated, .turnStarted, .stateChanged:
                break
            }
        }
    }

    var sessionID: SessionID
    do {
        sessionID = try await client.createSession()
    } catch {
        FileHandle.standardError.write(Data("创建 Session 失败: \(error)\n".utf8))
        return
    }
    print("Session: \(sessionID.rawValue)")
    print("\(dim)输入 prompt 开始对话；new/history/context/perf/permission/mode/cache/quit。\(reset)")

    while let raw = readLine() {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { continue }
        switch line {
        case "quit", "exit":
            await client.close()
            eventLoop.cancel()
            return
        case "new":
            do {
                sessionID = try await client.createSession()
                print("Session: \(sessionID.rawValue)")
            } catch {
                print("\(dim)[新建 Session 失败: \(error)]\(reset)")
            }
        case "history":
            await showHistory(client, sessionID: sessionID)
        case "context":
            await showContext(client, sessionID: sessionID)
        case "perf":
            await showPerformance(client, sessionID: sessionID)
        case "cache":
            do { try await showCache(client) }
            catch { print("\(dim)[cache 失败: \(error)]\(reset)") }
        case "permission":
            do {
                let configuration = try await client.permissionConfiguration()
                print("Policy: \(configuration.policy.rawValue)")
                print("Profile: \(configuration.profile.rawValue)")
            } catch { print("\(dim)[permission 失败: \(error)]\(reset)") }
        case let command where command.hasPrefix("permission "):
            let values = command.split(separator: " ")
            guard values.count == 3,
                  let policy = PermissionPolicy(rawValue: String(values[1])),
                  let profile = ExecutionProfile(rawValue: String(values[2]))
            else { print("用法: permission ask|auto readOnly|workspace|fullAccess"); continue }
            do { try await client.setPermissionConfiguration(PermissionConfiguration(policy: policy, profile: profile)) }
            catch { print("\(dim)[permission 失败: \(error)]\(reset)") }
        case let command where command.hasPrefix("mode "):
            let preset = command.dropFirst("mode ".count)
            let configuration: PermissionConfiguration?
            switch preset {
            case "strict": configuration = .strict
            case "agent": configuration = .agent
            case "yolo": configuration = .yolo
            default: configuration = nil
            }
            guard let configuration else { print("用法: mode strict|agent|yolo"); continue }
            do { try await client.setPermissionConfiguration(configuration) }
            catch { print("\(dim)[mode 失败: \(error)]\(reset)") }
        default:
            await runTurn(client, sessionID: sessionID, content: line)
        }
    }
    await client.close()
    eventLoop.cancel()
}

await runTUI()
