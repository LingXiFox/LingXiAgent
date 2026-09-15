import Foundation
import LingXiProtocol

/// 浏览器页面导航工具 (browser_navigate)
public struct BrowserNavigateTool: ToolExecutor {
    public let definition: ToolDefinition

    public init() {
        self.definition = ToolDefinition(
            id: ToolID("browser_navigate"),
            name: "browser_navigate",
            description: "Navigate browser session to a specified URL and capture current page elements",
            inputSchema: ToolInputSchema(
                properties: [
                    "url": ToolInputProperty(type: .string, description: "Target URL to navigate to")
                ],
                required: ["url"]
            ),
            capability: ToolCapability([.networkAccess, .userInteraction])
        )
    }

    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = json["url"] as? String else {
            return "browser://navigate"
        }
        return url
    }

    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = json["url"] as? String else {
            throw CoreError(code: .toolArgumentInvalid, message: "Missing required 'url' parameter")
        }

        let sessionID = ToolExecutionContext.sessionID?.rawValue ?? "default-session"
        return try await BrowserSessionManager.shared.navigate(sessionID: sessionID, url: url)
    }
}

/// 浏览器交互动作执行工具 (browser_act)
public struct BrowserActTool: ToolExecutor {
    public let definition: ToolDefinition

    public init() {
        self.definition = ToolDefinition(
            id: ToolID("browser_act"),
            name: "browser_act",
            description: "Perform an interaction action (click, type, hover) on a browser element ref",
            inputSchema: ToolInputSchema(
                properties: [
                    "action": ToolInputProperty(type: .string, description: "Action type: click, type, or hover", enumValues: ["click", "type", "hover"]),
                    "ref": ToolInputProperty(type: .string, description: "Element reference label, e.g. ref_1 or ref_2"),
                    "text": ToolInputProperty(type: .string, description: "Text content to input (required for type action)")
                ],
                required: ["action"]
            ),
            capability: ToolCapability([.networkAccess, .userInteraction])
        )
    }

    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        "browser://act"
    }

    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            throw CoreError(code: .toolArgumentInvalid, message: "Missing required 'action' parameter")
        }

        let ref = json["ref"] as? String
        let text = json["text"] as? String
        let sessionID = ToolExecutionContext.sessionID?.rawValue ?? "default-session"

        return try await BrowserSessionManager.shared.act(
            sessionID: sessionID,
            actionType: action,
            refString: ref,
            text: text
        )
    }
}
