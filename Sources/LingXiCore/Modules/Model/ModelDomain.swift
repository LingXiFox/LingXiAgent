import Foundation
import LingXiProtocol

// LingXi 自己的模型领域模型。
// 这里没有任何 Provider 原生类型（choices / delta / finish_reason 等
// 只存在于 OpenAICompatibleProvider Adapter 内部）。

public struct ModelID: Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// 一次模型调用的 Core 身份。它不同于 AgentRun，也不同于 Provider request/response ID。
public struct ModelRequestID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }
}

public enum ModelRole: String, Sendable {
    case system
    case user
    case assistant
    case tool
}

/// 模型输入的结构化部分；Provider Adapter 再转换为厂商消息格式。
public enum ModelContentPart: Sendable, Equatable {
    case text(String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
}

/// Provider wire 只能消费此稳定投影；ToolResult 的内部诊断与持久化字段不会自动外泄。
public enum ResultMaterializationTier: String, Sendable, Codable, Equatable {
    case inlineSmall       // < 1KB: 完全内联
    case structuredDigest  // 1KB..<8KB: 结构化摘要 + ContentRef
    case previewLarge      // 8KB..<32KB: 精简预览 (Head 3/4 + Tail 1/4)
    case archiveHuge       // >= 32KB: 纯 ContentRef 引用归档
}

public struct ModelToolResultProjection: Sendable, Equatable {
    public let callID: ToolCallID
    public let toolName: String?
    public let success: Bool
    public let content: String
    public let summary: String?
    public let totalCount: Int?
    public let shownCount: Int?
    public let truncated: Bool?
    public let page: Int?
    public let cursor: String?
    public let items: [String]?

    public init(
        callID: ToolCallID,
        toolName: String?,
        success: Bool,
        content: String,
        summary: String? = nil,
        totalCount: Int? = nil,
        shownCount: Int? = nil,
        truncated: Bool? = nil,
        page: Int? = nil,
        cursor: String? = nil,
        items: [String]? = nil
    ) {
        self.callID = callID
        self.toolName = toolName
        self.success = success
        self.content = content
        self.summary = summary
        self.totalCount = totalCount
        self.shownCount = shownCount
        self.truncated = truncated
        self.page = page
        self.cursor = cursor
        self.items = items
    }

    public static func project(_ result: ToolResult, budget: ToolResultBudget = .default) -> Self {
        guard result.success else {
            let error = result.error ?? ToolError(code: "toolExecutionFailed", message: "Tool 执行失败")
            let retryability: Retryability = {
                if result.outcome == .denied { return .afterUserAction }
                if result.outcome == .timedOut || result.outcome == .idleTimedOut { return .transient }
                if result.metadata["retryability"] == Retryability.transient.rawValue { return .transient }
                if result.metadata["retryability"] == Retryability.afterDelay.rawValue { return .afterDelay }
                return .none
            }()
            let errorKind = result.metadata["errorKind"] ?? error.code
            let summary: (String) -> String = { String($0.replacingOccurrences(of: "\n", with: " ").prefix(240)) }
            let projection: [String: Any] = [
                "error": ["code": error.code, "message": error.message],
                "errorKind": errorKind,
                "retryability": retryability.rawValue,
                "durationMilliseconds": result.timing.milliseconds,
                "exitCode": result.exitCode.map { $0 as Any } ?? NSNull(),
                "stdoutSummary": summary(result.diagnostics?.stdout ?? ""),
                "stderrSummary": summary(result.diagnostics?.stderr ?? ""),
                "permissionDenied": result.outcome == .denied,
                "scopeDenied": result.metadata["scopeDenied"] == "true"
            ]
            let content = (try? String(decoding: JSONSerialization.data(withJSONObject: projection, options: [.sortedKeys]), as: UTF8.self)) ?? error.message
            return Self(callID: result.callID, toolName: result.toolName, success: false, content: content, summary: error.message)
        }

        let tool = (result.toolName ?? "").lowercased()

        // 1. Glob
        if tool == "glob" {
            var paths: [String] = []
            if let data = result.content.data(using: .utf8),
               let list = try? JSONDecoder().decode([String].self, from: data) {
                paths = list
            } else {
                paths = result.content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            }
            let total = paths.count
            let shown = min(total, budget.maxShown)
            let truncated = total > shown || result.content.count > budget.maxCharacters
            let summary = "Glob · \(total) matches\(truncated ? " · showing \(shown)" : "")"
            let shownPaths = Array(paths.prefix(shown))
            let projectedJSON: String
            if truncated {
                let dict: [String: Any] = [
                    "summary": summary,
                    "totalCount": total,
                    "shownCount": shown,
                    "truncated": true,
                    "page": 1,
                    "matches": shownPaths
                ]
                if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                   let str = String(data: data, encoding: .utf8) {
                    projectedJSON = str
                } else {
                    projectedJSON = summary + "\n" + shownPaths.joined(separator: "\n")
                }
            } else {
                projectedJSON = result.content
            }
            return Self(
                callID: result.callID,
                toolName: result.toolName,
                success: true,
                content: projectedJSON,
                summary: summary,
                totalCount: total,
                shownCount: shown,
                truncated: truncated,
                page: 1,
                cursor: truncated ? String(shown) : nil,
                items: shownPaths
            )
        }

        // 2. ListDirectory
        if tool == "list_directory" {
            let lines = result.content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let total = lines.count
            let shown = min(total, budget.maxShown)
            let truncated = total > shown || result.content.count > budget.maxCharacters
            let summary = "ListDirectory · \(total) entries\(truncated ? " · showing \(shown)" : "")"
            let shownEntries = Array(lines.prefix(shown))
            let projectedJSON: String
            if truncated {
                let dict: [String: Any] = [
                    "summary": summary,
                    "totalCount": total,
                    "shownCount": shown,
                    "truncated": true,
                    "page": 1,
                    "entries": shownEntries
                ]
                if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                   let str = String(data: data, encoding: .utf8) {
                    projectedJSON = str
                } else {
                    projectedJSON = summary + "\n" + shownEntries.joined(separator: "\n")
                }
            } else {
                projectedJSON = result.content
            }
            return Self(
                callID: result.callID,
                toolName: result.toolName,
                success: true,
                content: projectedJSON,
                summary: summary,
                totalCount: total,
                shownCount: shown,
                truncated: truncated,
                page: 1,
                cursor: truncated ? String(shown) : nil,
                items: shownEntries
            )
        }

        // 3. Grep
        if tool == "grep" {
            if let data = result.content.data(using: .utf8),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let total = list.count
                let shown = min(total, budget.maxShown)
                let truncated = total > shown || result.content.count > budget.maxCharacters
                let summary = "Grep · \(total) matches\(truncated ? " · showing \(shown)" : "")"
                let shownMatches = Array(list.prefix(shown))
                let projectedJSON: String
                if truncated {
                    let dict: [String: Any] = [
                        "summary": summary,
                        "totalCount": total,
                        "shownCount": shown,
                        "truncated": true,
                        "page": 1,
                        "matches": shownMatches
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                       let str = String(data: data, encoding: .utf8) {
                        projectedJSON = str
                    } else {
                        projectedJSON = summary
                    }
                } else {
                    projectedJSON = result.content
                }
                return Self(
                    callID: result.callID,
                    toolName: result.toolName,
                    success: true,
                    content: projectedJSON,
                    summary: summary,
                    totalCount: total,
                    shownCount: shown,
                    truncated: truncated,
                    page: 1,
                    cursor: truncated ? String(shown) : nil
                )
            }
        }

        // 4. Read (read_file / read)
        if tool == "read_file" || tool == "read" {
            // 4.1 如果已经是结构化 ReadPage JSON，尊重其已有分页元数据，不要二次破坏
            if let data = result.content.data(using: .utf8),
               let pageDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawLines = pageDict["lines"] as? [[String: Any]] {
                let startLine = pageDict["startLine"] as? Int ?? 1
                let endLine = pageDict["endLine"] as? Int ?? rawLines.count
                let nextLine = pageDict["nextLine"] as? Int
                let truncated = pageDict["truncated"] as? Bool ?? false
                let lineTexts = rawLines.compactMap { dict -> String? in
                    if let num = dict["number"] as? Int, let c = dict["content"] as? String {
                        return "\(num)\t\(c)"
                    }
                    return dict["content"] as? String
                }
                let summary = "ReadFile · lines \(startLine)-\(endLine) (truncated: \(truncated))"
                return Self(
                    callID: result.callID,
                    toolName: result.toolName,
                    success: true,
                    content: result.content,
                    summary: summary,
                    totalCount: rawLines.count,
                    shownCount: rawLines.count,
                    truncated: truncated,
                    page: max(1, startLine / max(1, rawLines.count)),
                    cursor: nextLine.map(String.init),
                    items: lineTexts
                )
            }

            // 4.2 普通全文读取：提供合理的单次阅读视窗（默认 60 行）
            let lines = result.content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let total = lines.count
            let maxLines = max(budget.maxShown, 60)
            let shown = min(total, maxLines)
            let truncated = total > shown || result.content.count > budget.maxCharacters
            let summary = truncated ? "ReadFile · \(total) lines · showing \(shown)" : result.summary
            let shownLines = Array(lines.prefix(shown))
            let projectedContent: String
            if truncated {
                let dict: [String: Any] = [
                    "summary": summary,
                    "totalCount": total,
                    "shownCount": shown,
                    "truncated": true,
                    "page": 1,
                    "nextLine": shown + 1,
                    "tip": "File truncated at line \(shown). Use read_file with start_line=\(shown + 1) to read further.",
                    "lines": shownLines
                ]
                if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                   let str = String(data: data, encoding: .utf8) {
                    projectedContent = str
                } else {
                    projectedContent = summary + "\n" + shownLines.joined(separator: "\n")
                }
            } else {
                projectedContent = result.content
            }
            return Self(
                callID: result.callID,
                toolName: result.toolName,
                success: true,
                content: projectedContent,
                summary: summary,
                totalCount: total,
                shownCount: shown,
                truncated: truncated,
                page: 1,
                cursor: truncated ? String(shown + 1) : nil,
                items: shownLines
            )
        }

        // 5. Search (search_tools / search)
        if tool == "search_tools" || tool == "search" {
            if let data = result.content.data(using: .utf8),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let total = list.count
                let shown = min(total, budget.maxShown)
                let truncated = total > shown || result.content.count > budget.maxCharacters
                let summary = truncated ? "Search · \(total) results · showing \(shown)" : result.summary
                let shownItems = Array(list.prefix(shown))
                let projectedJSON: String
                if truncated {
                    let dict: [String: Any] = [
                        "summary": summary,
                        "totalCount": total,
                        "shownCount": shown,
                        "truncated": true,
                        "page": 1,
                        "results": shownItems
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                       let str = String(data: data, encoding: .utf8) {
                        projectedJSON = str
                    } else {
                        projectedJSON = summary
                    }
                } else {
                    projectedJSON = result.content
                }
                return Self(
                    callID: result.callID,
                    toolName: result.toolName,
                    success: true,
                    content: projectedJSON,
                    summary: summary,
                    totalCount: total,
                    shownCount: shown,
                    truncated: truncated,
                    page: 1,
                    cursor: truncated ? String(shown) : nil
                )
            }
        }

        // 6. Generic bounded character budget & Multi-Tier Materialization
        if result.content.count >= 32 * 1024 {
            let head = result.content.prefix(512)
            let tail = result.content.suffix(256)
            let dropped = result.content.count - head.count - tail.count
            let truncatedContent = "\(head)\n... [\(dropped) characters truncated for prefix-cache efficiency · tier: archiveHuge] ...\n\(tail)"
            let summary = "ToolResult · \(result.toolName ?? "output") · Archived · \(result.content.count) chars"
            return Self(
                callID: result.callID,
                toolName: result.toolName,
                success: true,
                content: truncatedContent,
                summary: summary,
                truncated: true
            )
        } else if result.content.count > budget.maxCharacters {
            let maxKeep = budget.maxCharacters
            let headSize = min(result.content.count, maxKeep * 3 / 4)
            let tailSize = min(result.content.count - headSize, maxKeep / 4)
            let head = result.content.prefix(headSize)
            let tail = result.content.suffix(tailSize)
            let dropped = result.content.count - headSize - tailSize
            let truncatedContent = "\(head)\n... [\(dropped) characters truncated for prefix-cache efficiency] ...\n\(tail)"
            return Self(
                callID: result.callID,
                toolName: result.toolName,
                success: true,
                content: truncatedContent,
                summary: result.summary,
                truncated: true
            )
        }

        return Self(callID: result.callID, toolName: result.toolName, success: true, content: result.content, summary: result.summary)
    }

    public static func projectToolResult(_ result: ToolResult, budget: ToolResultBudget = .default) -> ToolResult {
        guard result.success else { return result }
        let projected = project(result, budget: budget)
        let outMeta = ToolOutputMetadata(
            truncated: projected.truncated ?? false,
            totalCharacters: result.content.count,
            visibleCharacters: projected.content.count
        )
        return result.withContent(projected.content, summary: projected.summary, output: outMeta)
    }
}

public struct ModelMessage: Sendable, Equatable {
    public let role: ModelRole
    public let parts: [ModelContentPart]

    public var content: String {
        parts.compactMap { if case let .text(text) = $0 { text } else { nil } }.joined()
    }

    public init(role: ModelRole, content: String) {
        self.init(role: role, parts: [.text(content)])
    }

    public init(role: ModelRole, parts: [ModelContentPart]) {
        self.role = role
        self.parts = parts
    }
}

public struct ModelRequest: Sendable, Equatable {
    public let requestID: ModelRequestID
    public let continuationOf: ModelRequestID?
    public let model: ModelID
    public let executionID: AgentRunID?
    public let system: String?
    public let messages: [ModelMessage]
    public let tools: [ToolDefinition]
    public let reasoning: String?
    public let debugStep: Int?
    public let overallTimeoutSeconds: Double?
    public let idleTimeoutSeconds: Double?
    public let cachePlan: CanonicalCachePlan?

    public init(
        requestID: ModelRequestID = ModelRequestID(),
        continuationOf: ModelRequestID? = nil,
        model: ModelID,
        executionID: AgentRunID? = nil,
        system: String? = nil,
        messages: [ModelMessage],
        tools: [ToolDefinition] = [],
        reasoning: String? = nil,
        debugStep: Int? = nil,
        overallTimeoutSeconds: Double? = nil,
        idleTimeoutSeconds: Double? = nil,
        cachePlan: CanonicalCachePlan? = nil
    ) {
        self.requestID = requestID
        self.continuationOf = continuationOf
        self.model = model
        self.executionID = executionID
        self.system = system
        self.messages = messages
        self.tools = tools
        self.reasoning = reasoning
        self.debugStep = debugStep
        self.overallTimeoutSeconds = overallTimeoutSeconds
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.cachePlan = cachePlan
    }
}

public enum ProviderTraceSanitizer {
    public static func requestID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = String(value.prefix(128))
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) })
        else { return nil }
        return trimmed
    }
}

/// 模型推理事件流。高频 delta 走 DMA，started/usage/completed/failed 由 Agent 分流到控制面。
public enum ModelEvent: Sendable, Equatable {
    /// Provider HTTP 响应提供的可审计请求 ID，已在 adapter 边界完成清洗。
    case providerRequestID(String)
    /// Provider 连接建立、推理即将开始。
    case started
    case textDelta(String)
    /// 推理内容 delta；Provider 不支持时不会出现。
    case reasoningDelta(String)
    case toolCallStarted(callID: ToolCallID, toolID: ToolID)
    case toolCallDelta(callID: ToolCallID, arguments: String)
    case toolCallCompleted(ToolCall)
    case usage(ModelUsage)
    case completed(ModelFinishReason)
    /// 流中途失败（Model Stream Error）。
    case failed(CoreError)
}
