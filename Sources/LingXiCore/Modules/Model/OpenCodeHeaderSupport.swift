import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiPlatform

/// 针对 OpenCode (OpenCode Zen / OpenCode Go) 服务的协议头自动兼容支持。
/// OpenCode 官方服务端自 2026 年 9 月起要求 free-tier 及 Zen 请求必须携带有效的
/// `x-opencode-session` 及 CLI 客户端标识，否则返回 400 MissingSessionID 错误。
public enum OpenCodeHeaderSupport {
    public static func injectHeadersIfNeeded(into request: inout URLRequest, modelRequest: ModelRequest) {
        guard let host = request.url?.host?.lowercased(), host.contains("opencode.ai") || host.contains("opencode") else {
            return
        }

        let rawSession = modelRequest.executionID?.rawValue ?? modelRequest.requestID.rawValue
        let sessionUUID = formatUUID(from: rawSession)
        let projectUUID = formatUUID(from: FileManager.default.currentDirectoryPath)

        if request.value(forHTTPHeaderField: "x-opencode-session") == nil {
            request.setValue(sessionUUID, forHTTPHeaderField: "x-opencode-session")
        }
        if request.value(forHTTPHeaderField: "x-opencode-client") == nil {
            request.setValue("cli", forHTTPHeaderField: "x-opencode-client")
        }
        if request.value(forHTTPHeaderField: "x-opencode-project") == nil {
            request.setValue(projectUUID, forHTTPHeaderField: "x-opencode-project")
        }
        if request.value(forHTTPHeaderField: "x-opencode-request") == nil {
            request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "x-opencode-request")
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil || request.value(forHTTPHeaderField: "User-Agent")?.contains("opencode") == false {
            request.setValue("opencode/latest/1.3.15/cli", forHTTPHeaderField: "User-Agent")
        }
    }

    private static func formatUUID(from string: String) -> String {
        if let uuid = UUID(uuidString: string) {
            return uuid.uuidString.lowercased()
        }
        let hash = LingXiPlatform.crypto.sha256(Data(string.utf8))
        let b = Array(hash.prefix(16))
        return String(format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                      b[0], b[1], b[2], b[3],
                      b[4], b[5],
                      b[6], b[7],
                      b[8], b[9],
                      b[10], b[11], b[12], b[13], b[14], b[15])
    }
}
