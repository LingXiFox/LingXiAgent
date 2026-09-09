import Foundation
import LingXiProtocol
import LingXiClient

public enum ExecCLI {

    public static func run(arguments: [String]) async throws {
        var args = arguments
        if args.first == "exec" || args.first == "e" {
            args.removeFirst()
        }

        var isYoloMode = false
        var modelID: String?
        var workingDir: String?
        var effort: ReasoningEffort?
        var isJSON = false
        var promptWords: [String] = []

        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "-y" || arg == "--yolo" {
                isYoloMode = true
                i += 1
            } else if arg == "-m" || arg == "--model" {
                if i + 1 < args.count {
                    modelID = args[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            } else if arg.hasPrefix("--model=") {
                modelID = String(arg.dropFirst("--model=".count))
                i += 1
            } else if arg == "-C" || arg == "--cd" {
                if i + 1 < args.count {
                    workingDir = args[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            } else if arg.hasPrefix("--cd=") {
                workingDir = String(arg.dropFirst("--cd=".count))
                i += 1
            } else if arg == "-e" || arg == "--effort" {
                if i + 1 < args.count {
                    effort = ReasoningEffort(rawValue: args[i + 1].lowercased())
                    i += 2
                } else {
                    i += 1
                }
            } else if arg.hasPrefix("--effort=") {
                effort = ReasoningEffort(rawValue: String(arg.dropFirst("--effort=".count)).lowercased())
                i += 1
            } else if arg == "--json" {
                isJSON = true
                i += 1
            } else if arg == "-h" || arg == "--help" {
                print(renderHelp())
                return
            } else if arg == "--" {
                i += 1
                while i < args.count {
                    promptWords.append(args[i])
                    i += 1
                }
                break
            } else if arg.hasPrefix("-") {
                i += 1
            } else {
                promptWords.append(arg)
                i += 1
            }
        }

        // Check if there is piped stdin input
        var pipeInput: String?
        if isatty(STDIN_FILENO) == 0 {
            let stdinData = FileHandle.standardInput.readDataToEndOfFile()
            if let str = String(data: stdinData, encoding: .utf8), !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pipeInput = str
            }
        }

        let argPrompt = promptWords.isEmpty ? nil : promptWords.joined(separator: " ")
        let finalPrompt: String

        if let pipe = pipeInput, let prompt = argPrompt {
            finalPrompt = "\(prompt)\n\nInput Context:\n```\n\(pipe)\n```"
        } else if let pipe = pipeInput {
            finalPrompt = pipe
        } else if let prompt = argPrompt {
            finalPrompt = prompt
        } else {
            FileHandle.standardError.write(Data("Error: No prompt provided.\nUsage: lingxiagent exec [options] <prompt>\n".utf8))
            exit(1)
        }

        if let workingDir, !workingDir.isEmpty {
            FileManager.default.changeCurrentDirectoryPath(workingDir)
        }

        let store = try await ApplicationStore.stdio(interactive: false, autoConnect: true)

        if isYoloMode {
            await store.dispatch(.setPermissionConfiguration(.yoloFullAccess))
        }
        if let modelID {
            await store.dispatch(.selectModel(modelID))
        }
        if let effort {
            await store.dispatch(.setReasoningEffort(effort))
        }

        await store.dispatch(.submitPrompt(finalPrompt))

        var printedCharsCount = 0
        var reportedToolCalls = Set<ToolCallID>()
        var hasStartedRunning = false

        let stream = await store.stateUpdates
        for await state in stream {
            // Check YOLO permissions
            if isYoloMode, let interaction = state.activeInteraction, interaction.kind == .permission {
                await store.dispatch(.grantPermission(interactionID: interaction.interactionID, decision: .allow))
            }

            guard let session = state.activeSessionState else { continue }

            if session.activeTurnID != nil {
                hasStartedRunning = true
            }

            // Report active tools
            for (callID, node) in session.toolNodes {
                if !reportedToolCalls.contains(callID) {
                    reportedToolCalls.insert(callID)
                    if !isJSON {
                        FileHandle.standardError.write(Data("\n⚡ [Tool: \(node.toolName)]\n".utf8))
                    }
                }
            }

            // Extract assistant text from timeline
            var combinedText = ""
            for node in session.timelineNodes {
                if case let .message(msg) = node.kind, msg.role == .assistant {
                    combinedText += msg.content
                }
            }

            if combinedText.count > printedCharsCount {
                let startIndex = combinedText.index(combinedText.startIndex, offsetBy: printedCharsCount)
                let delta = String(combinedText[startIndex...])
                printedCharsCount = combinedText.count

                if !isJSON {
                    print(delta, terminator: "")
                    fflush(stdout)
                }
            }

            // Detect turn completion
            if hasStartedRunning && session.activeTurnID == nil && session.queuedTurns.isEmpty {
                if !isJSON {
                    print("\n")
                } else {
                    let jsonResult: [String: Any] = [
                        "session_id": session.sessionID.rawValue,
                        "response": combinedText,
                        "tools_used": session.toolNodes.values.map(\.toolName)
                    ]
                    if let jsonData = try? JSONSerialization.data(withJSONObject: jsonResult, options: [.prettyPrinted, .sortedKeys]) {
                        print(String(decoding: jsonData, as: UTF8.self))
                    }
                }
                break
            }
        }

        await store.dispatch(.disconnect)
    }

    public static func renderHelp() -> String {
        """
        Run Agent in Headless / Non-Interactive Mode:

        USAGE:
          lingxiagent exec [options] <prompt>
          cat <file> | lingxiagent exec [options] [prompt]

        OPTIONS:
          -y, --yolo                  全自动执行模式（自动放行所有文件修改与终端命令）
          -m, --model <id>            指定执行模型
          -C, --cd <dir>              指定执行工作目录
          -e, --effort <effort>       推理深度 (auto | low | medium | high | max)
              --json                  以 JSON 格式输出最终执行结果
          -h, --help                  显示此帮助信息

        EXAMPLES:
          lingxiagent exec "分析当前目录的代码结构并总结"
          lingxiagent exec --yolo "修复 Package.swift 的所有编译报错"
          git diff | lingxiagent exec "检查这批代码改动是否有潜在缺陷"
        """
    }
}
