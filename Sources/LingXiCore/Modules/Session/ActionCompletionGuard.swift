import Foundation
import LingXiProtocol

/// A turn may promise effects only when this turn has executor-produced evidence.
/// Intent detection is deliberately conservative; informational requests keep auto.
struct ActionCompletionGuard {
    enum Effect: String, Hashable {
        case mutation, execution, compilation
    }

    let requiredEffects: Set<Effect>
    private(set) var evidencedEffects: Set<Effect> = []
    private(set) var retriedRequired = false
    private var backgroundCommands: [String: String] = [:]

    init(task: String) {
        requiredEffects = Self.requestedEffects(task)
    }

    mutating func retryChoice(firstResponse: Bool, hasTools: Bool) -> Bool {
        guard firstResponse, hasTools, !requiredEffects.isEmpty, !retriedRequired else { return false }
        retriedRequired = true
        return true
    }

    mutating func record(call: ToolCall, result: ToolResult, definition: ToolDefinition?) {
        guard result.callID == call.callID, result.success, result.outcome == .success,
              result.metadata["executionState"] != "unknown",
              result.metadata["verificationRequired"] != "true" else { return }
        if !result.fileMutations.isEmpty { evidencedEffects.insert(.mutation) }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
        if args?["action"] as? String == "spawn",
           let spawn = try? JSONDecoder().decode(SubagentSpawnResponse.self, from: Data(result.content.utf8)),
           !spawn.run.runID.rawValue.isEmpty {
            evidencedEffects.insert(.execution)
        }
        guard let kinds = definition?.capability.kinds else { return }
        if !kinds.isDisjoint(with: [.projectWrite, .repositoryWrite, .repositoryRemoteWrite, .destructive]) {
            evidencedEffects.insert(.mutation)
        }
        if kinds.contains(.processExecute) {
            let command = result.diagnostics?.command ?? args?["command"] as? String ?? ""
            if result.exitCode == 0 { recordSuccessfulCommand(command) }
            // A spawn result binds an executor-created task to this turn. Polls of old tasks
            // cannot establish that binding, even though they also return snapshots.
            if let requestedCommand = args?["command"] as? String,
               let object = (try? JSONSerialization.jsonObject(with: Data(result.content.utf8))) as? [String: Any],
               let id = object["id"] as? String, let observedCommand = object["command"] as? String,
               requestedCommand.trimmingCharacters(in: .whitespacesAndNewlines) == observedCommand {
                backgroundCommands[id] = observedCommand
            }
        }
    }

    mutating func recordBackground(_ snapshots: [BackgroundTaskSnapshot]) {
        for snapshot in snapshots where backgroundCommands[snapshot.id] == snapshot.command {
            if snapshot.status == .exited, snapshot.exitCode == 0 {
                recordSuccessfulCommand(snapshot.command)
            }
        }
    }

    private mutating func recordSuccessfulCommand(_ command: String) {
        evidencedEffects.insert(.execution)
        // Shell success does not prove a build hidden behind a fallback or pipeline.
        guard !Self.matches(command, #"[;|\n`]|\$\(|(?:^|\s)(?:--?version|--?help|--dry-run|-n|-license|-list|-showsdks|clean)(?:\s|$)"#) else { return }
        if Self.matches(command, #"^\s*(?:cd\s+[^;&|\n]+&&\s*)?(?:swift\s+build\b|swiftc\b|xcodebuild\b|(?:cargo|go|dotnet)\s+build\b|(?:npm|pnpm|yarn)\s+(?:run\s+)?build\b|make\b|cmake\s+--build\b|ninja\b|(?:g\+\+|clang\+\+|c\+\+)(?:\s|$)|gcc\b|clang\b|cc\b)"#) {
            evidencedEffects.insert(.compilation)
        }
    }

    func hasUnsupportedClaims(_ text: String) -> Bool {
        !Self.claimedEffects(text).subtracting(evidencedEffects).isEmpty
    }

    func validateCompletion(_ text: String) throws {
        let missing = requiredEffects.union(Self.claimedEffects(text)).subtracting(evidencedEffects)
        guard missing.isEmpty else {
            throw CoreError(code: .toolExecutionFailed,
                            message: "Action completion blocked: no successful ToolResult / mutation evidence for \(missing.map(\.rawValue).sorted().joined(separator: ", ")). The requested action is not verified as complete.")
        }
    }

    private static func requestedEffects(_ task: String) -> Set<Effect> {
        let cleaned = prose(task).trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare English verb is not an explicit effect request without an object.
        if ["start", "write", "run", "execute"].contains(cleaned.lowercased()) { return [] }
        let clauses = cleaned.components(separatedBy: CharacterSet(charactersIn: "。！？;；，,\n"))
        var effects: Set<Effect> = []
        let prefix = #"(?:^|\band\s+|并|然后)(?:\s*(?:请|帮我|实际|直接|立即|为我|只需|仅需|仅|麻烦|please\s+|can you\s+|could you\s+|help me\s+))*(?:(?:在|把|使用)[^。！？;；\n]{0,80}?)?"#
        for text in clauses {
            // Questions, examples and plans do not authorize side effects.
            if matches(text, #"^\s*(?:请)?(?:解释|说明|如何|怎么|为什么|给.*(?:示例|例子|方案)|不要|无需|explain\b|how\b|why\b|show\b|describe\b|plan\b|计划|规划|讨论|do not\b|don't\b)"#) { continue }
            if matches(text, prefix + #"(?:创建|新建|写入|修改|编辑|删除|保存|更新|重命名|移动|create\b|write\b|edit\b|modify\b|delete\b|save\b|update\b|rename\b|move\b)"#) {
                // Text composition is a normal answer, not a workspace mutation.
                if !matches(text, #"(?:写|write|create).{0,15}(?:诗|故事|作文|文案|答案|poem\b|story\b|essay\b|answer\b)"#) { effects.insert(.mutation) }
            }
            if matches(text, prefix + #"(?:运行|执行|启动|run\b|execute\b|start\b)"#) { effects.insert(.execution) }
            if matches(text, prefix + #"(?:编译|构建|compile\b|build\b)"#) { effects.insert(.compilation) }
        }
        return effects
    }

    private static func claimedEffects(_ response: String) -> Set<Effect> {
        let text = prose(response).replacingOccurrences(
            of: #"(?:尚未|未曾|没有|并未|无法|不能|未)(?:确认|声称|保证)?(?:已经|已|成功)?(?:创建|新建|写入|修改|编辑|删除|保存|更新|运行|执行|启动|编译|构建)"#,
            with: "", options: .regularExpression)
        var effects: Set<Effect> = []
        let affirmative = #"(?:已(?:经)?(?:成功)?|成功|(?:(?:I|we)(?:\s+have|'ve)?\s+|have\s+)(?:successfully\s+)?)"#
        if matches(text, affirmative + #"(?:创建|新建|写入|修改|编辑|删除|保存|更新|created\b|written\b|modified\b|edited\b|deleted\b|saved\b|updated\b)"#) { effects.insert(.mutation) }
        if matches(text, affirmative + #"(?:运行|执行|启动|run\b|ran\b|executed\b|started\b)"#) { effects.insert(.execution) }
        if matches(text, affirmative + #"(?:编译|构建|compiled\b|built\b)"#) { effects.insert(.compilation) }
        // Passive completion claims are promises too.
        if matches(text, #"\b(?:file|files|project|code)\b[^.\n]{0,60}\b(?:was|were|has been|have been)\s+(?:created|written|modified|updated|saved)\b"#) { effects.insert(.mutation) }
        if matches(text, #"\b(?:build|compilation)\s+(?:succeeded|passed|completed)\b"#) { effects.insert(.compilation) }
        if matches(text, #"(?:创建|修改|写入|保存|更新).{0,20}(?:完成|成功)|(?:^|[.!\n]\s*)(?:created|modified|updated|compiled|built)\b"#) {
            if matches(text, #"(?:创建|修改|写入|保存|更新).{0,20}(?:完成|成功)|(?:^|[.!\n]\s*)(?:created|modified|updated)\b"#) { effects.insert(.mutation) }
            if matches(text, #"(?:^|[.!\n]\s*)(?:compiled|built)\b"#) { effects.insert(.compilation) }
        }
        return effects
    }

    private static func prose(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?s)```.*?```|`[^`\n]*`"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*>.*$"#, with: "", options: .regularExpression)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
