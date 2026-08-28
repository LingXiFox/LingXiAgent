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
            let who = message.role == .user ? "user" : "assistant"
            let content = message.content.replacingOccurrences(of: "\n", with: " ")
            print("\(dim)[\(who)] \(content)\(reset)")
        }
    } catch {
        print("\(dim)[history 失败: \(error)]\(reset)")
    }
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
    print("\(dim)输入 prompt 开始对话；new=新建 Session；history=查看消息；quit=退出。\(reset)")

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
        default:
            await runTurn(client, sessionID: sessionID, content: line)
        }
    }
    await client.close()
    eventLoop.cancel()
}

await runTUI()
