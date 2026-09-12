import Foundation
import LingXiProtocol

/// Centralized client fingerprinting and official client camouflage utility.
///
/// Designed with defensive OPSEC principles:
/// - Avoids blind hardcoding of Linux/Windows strings on macOS to prevent catastrophic
///   mismatches between HTTP User-Agent and TCP/TLS JA3/JA4 fingerprints at the WAF level.
/// - Dynamically resolves host OS and architecture while precisely matching official CLI versioning.
/// - Supports runtime environment overrides for version bump and custom fingerprint testing.
public enum ClientFingerprint {

    // MARK: - Platform Identification

    public struct PlatformInfo: Sendable, Equatable {
        public let osName: String          // e.g. "darwin", "linux", "windows"
        public let capitalizedOS: String   // e.g. "Darwin", "Linux", "Windows"
        public let arch: String            // e.g. "arm64", "x86_64"
        public let term: String            // e.g. "xterm-256color"

        public init(osName: String, capitalizedOS: String, arch: String, term: String) {
            self.osName = osName
            self.capitalizedOS = capitalizedOS
            self.arch = arch
            self.term = term
        }
    }

    public static func currentPlatform() -> PlatformInfo {
        let env = ProcessInfo.processInfo.environment

        let osName: String
        let capitalizedOS: String
        if let customOS = env["LINGXI_CLIENT_OS"], !customOS.isEmpty {
            osName = customOS.lowercased()
            capitalizedOS = customOS.prefix(1).uppercased() + customOS.dropFirst()
        } else {
            #if os(macOS)
            osName = "darwin"
            capitalizedOS = "Darwin"
            #elseif os(Linux)
            osName = "linux"
            capitalizedOS = "Linux"
            #elseif os(Windows)
            osName = "windows"
            capitalizedOS = "Windows"
            #else
            osName = "darwin"
            capitalizedOS = "Darwin"
            #endif
        }

        let arch: String
        if let customArch = env["LINGXI_CLIENT_ARCH"], !customArch.isEmpty {
            arch = customArch
        } else {
            #if arch(arm64)
            arch = "arm64"
            #elseif arch(x86_64)
            arch = "x86_64"
            #else
            arch = "arm64"
            #endif
        }

        let term = env["TERM"] ?? "xterm-256color"
        return PlatformInfo(osName: osName, capitalizedOS: capitalizedOS, arch: arch, term: term)
    }

    // MARK: - Official Versions

    public static func codexVersion() -> String {
        let env = ProcessInfo.processInfo.environment
        return env["CODEX_CLI_VERSION"] ?? "0.154.0"
    }

    public static func claudeVersion() -> String {
        let env = ProcessInfo.processInfo.environment
        return env["CLAUDE_CLI_VERSION"] ?? env["SUB2API_CLAUDE_CLI_VERSION"] ?? "2.1.258"
    }

    public static func antigravityVersion() -> String {
        let env = ProcessInfo.processInfo.environment
        return env["ANTIGRAVITY_VERSION"] ?? "2.9.1"
    }

    public static func geminiCLIVersion() -> String {
        let env = ProcessInfo.processInfo.environment
        return env["GEMINI_CLI_VERSION"] ?? "0.1.5"
    }

    public static func grokCLIVersion() -> String {
        let env = ProcessInfo.processInfo.environment
        return env["XAI_GROK_CLI_VERSION"] ?? "0.2.120"
    }

    // MARK: - User-Agent Formulation

    public static func userAgent(for productID: String) -> String {
        let platform = currentPlatform()
        let env = ProcessInfo.processInfo.environment

        switch productID {
        case "openai-codex":
            let flavor = env["CODEX_CLIENT_FLAVOR"]?.lowercased() ?? "codex-cli"
            let version = codexVersion()
            if flavor == "codex-tui" {
                return "codex-tui/\(version) (\(platform.capitalizedOS); \(platform.arch)) \(platform.term)"
            } else {
                return "codex-cli/\(version) (\(platform.osName); \(platform.arch))"
            }

        case "anthropic-claude-subscription":
            // Matches official Claude Code CLI: claude-cli/2.1.258 (external, cli)
            return "claude-cli/\(claudeVersion()) (external, cli)"

        case "antigravity":
            // Matches official Antigravity CLI/IDE format: antigravity/2.9.1 darwin/arm64
            return "antigravity/\(antigravityVersion()) \(platform.osName)/\(platform.arch)"

        case "gemini-code-assist":
            // Matches official Gemini Code Assist CLI format: GeminiCLI/0.1.5 (Darwin; arm64)
            return "GeminiCLI/\(geminiCLIVersion()) (\(platform.capitalizedOS); \(platform.arch))"

        case "xai-grok-subscription":
            // Matches official Grok CLI format: xai-grok-workspace/0.2.120
            return "xai-grok-workspace/\(grokCLIVersion())"

        default:
            return "LingXiAgent/1.0 (\(platform.osName); \(platform.arch))"
        }
    }

    // MARK: - Complete Official Headers

    public static func headers(
        for productID: String,
        authToken: String? = nil,
        isStream: Bool = false
    ) -> [String: String] {
        var headers: [String: String] = [:]

        // 1. User-Agent
        let ua = userAgent(for: productID)
        headers["User-Agent"] = ua

        // 2. Official accompanying headers per channel
        switch productID {
        case "openai-codex":
            let env = ProcessInfo.processInfo.environment
            let flavor = env["CODEX_CLIENT_FLAVOR"]?.lowercased() ?? "codex-cli"
            headers["originator"] = flavor
            headers["OpenAI-Beta"] = "responses=v1"
            headers["Accept"] = isStream ? "text/event-stream" : "application/json"
            if let token = authToken, let accountID = CodexRemoteModelDiscovery.extractChatGPTAccountID(from: token) {
                headers["chatgpt-account-id"] = accountID
            }

        case "anthropic-claude-subscription":
            headers["anthropic-version"] = "2023-06-01"
            headers["anthropic-beta"] = "prompt-caching-2024-07-31,computer-use-2024-10-22,interleaved-thinking-2025-02-14"
            headers["anthropic-client"] = "claude-code/\(claudeVersion())"
            headers["Accept"] = isStream ? "text/event-stream" : "application/json"

        case "anthropic-api":
            // Claude API Key transparent mode: official API headers without impersonating Claude Code CLI
            headers["anthropic-version"] = "2023-06-01"

        case "antigravity":
            headers["X-Goog-Api-Client"] = "antigravity/\(antigravityVersion())"
            headers["Content-Type"] = "application/json"
            headers["Accept"] = "application/json"

        case "gemini-code-assist":
            headers["X-Goog-Api-Client"] = "gl-swift/5.x gccl/\(geminiCLIVersion())"
            headers["Content-Type"] = "application/json"
            headers["Accept"] = "application/json"

        case "xai-grok-subscription":
            headers["Accept"] = "application/json"

        default:
            break
        }

        return headers
    }
}
