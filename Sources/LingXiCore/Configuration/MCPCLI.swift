import Foundation
import LingXiProtocol

public enum MCPCLI {

    public static func run(
        arguments: [String],
        dataRoot: URL? = nil,
        credentialStore: CredentialStore? = nil,
        configurationStore: ConfigurationStore? = nil,
        inputReader: (@Sendable (String) -> String?)? = nil,
        secretResolver: (any SecretResolver)? = nil
    ) async throws -> String {
        let root = dataRoot ?? LingXiDataRootResolver.resolve(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let credStore: CredentialStore
        if let credentialStore {
            credStore = credentialStore
        } else {
            credStore = try PlatformSecureCredentialStore(
                dataRoot: root,
                passphrase: ProcessInfo.processInfo.environment["LINGXI_CREDENTIALS_PASSPHRASE"]
            )
        }
        let configStore = try configurationStore ?? ConfigurationStore(dataRoot: root)

        var args = arguments
        if args.first == "mcp" {
            args.removeFirst()
        }

        let subcommand = args.first ?? "list"

        switch subcommand {
        case "list":
            return try await listServers(configStore: configStore)

        case "status":
            let serverName = args.count > 1 ? args[1] : nil
            return try await statusServers(
                serverName: serverName,
                configStore: configStore,
                credStore: credStore,
                secretResolver: secretResolver
            )

        case "enable":
            guard args.count > 1 else {
                return "Error: MCP server ID or alias is required. Usage: lingxiagent mcp enable <name>"
            }
            return try await setServerEnabled(name: args[1], enabled: true, configStore: configStore)

        case "disable":
            guard args.count > 1 else {
                return "Error: MCP server ID or alias is required. Usage: lingxiagent mcp disable <name>"
            }
            return try await setServerEnabled(name: args[1], enabled: false, configStore: configStore)

        case "login":
            guard args.count > 1 else {
                return "Error: MCP server ID or alias is required. Usage: lingxiagent mcp login <name>"
            }
            let serverName = args[1]
            return try await loginServer(
                serverName: serverName,
                configStore: configStore,
                credStore: credStore,
                inputReader: inputReader ?? AuthCLI.readPrompt
            )

        case "auth":
            guard args.count > 1 else {
                return "Error: MCP server ID or alias is required. Usage: lingxiagent mcp auth <name> [options]"
            }
            let serverName = args[1]
            let remainingArgs = Array(args.dropFirst(2))
            return try await configureAuth(
                serverName: serverName,
                arguments: remainingArgs,
                configStore: configStore,
                credStore: credStore,
                inputReader: inputReader ?? AuthCLI.readSecretWithoutEcho
            )

        case "add":
            let addArgs = Array(args.dropFirst())
            return try await addServer(arguments: addArgs, configStore: configStore)

        case "remove", "rm", "delete":
            guard args.count > 1 else {
                return "Error: MCP server ID or alias is required. Usage: lingxiagent mcp remove <name>"
            }
            return try await removeServer(name: args[1], configStore: configStore)

        case "help", "--help", "-h":
            return renderHelp()

        default:
            return "Unknown MCP command: '\(subcommand)'.\n\n\(renderHelp())"
        }
    }

    // MARK: - Subcommand Handlers

    private static func listServers(configStore: ConfigurationStore) async throws -> String {
        let snapshot = try await loadMCPConfig(configStore: configStore)
        if snapshot.servers.isEmpty {
            return """
            No MCP servers configured.
            To add a server, use:
              lingxiagent mcp add <id> --command <path>
              lingxiagent mcp add <id> --transport http --endpoint <url>
            """
        }

        var rows: [[String]] = []
        for s in snapshot.servers {
            let status = s.enabled ? "● Enabled" : "○ Disabled"
            let target: String
            switch s.transport {
            case .stdio:
                target = s.command ?? "-"
            case .streamableHTTP:
                target = s.endpoint ?? "-"
            }

            let authStr: String
            switch s.authentication.kind {
            case .none:
                authStr = "none"
            case .bearer:
                authStr = "Bearer"
            case .header:
                authStr = "Header(\(s.authentication.headerName ?? "auth"))"
            }

            rows.append([
                s.id,
                s.alias,
                s.transport.rawValue,
                target,
                status,
                authStr,
                "\(Int(s.timeoutSeconds))s"
            ])
        }

        let table = CLIFormatter.renderTable(
            headers: ["ID", "ALIAS", "TRANSPORT", "COMMAND / ENDPOINT", "STATUS", "AUTH", "TIMEOUT"],
            rows: rows
        )

        return """
        Configured MCP Servers (\(snapshot.servers.count)):
        \(table)
        """
    }

    private static func setServerEnabled(name: String, enabled: Bool, configStore: ConfigurationStore) async throws -> String {
        var config = try await loadMCPConfig(configStore: configStore)
        guard let index = config.servers.firstIndex(where: { $0.id == name || $0.alias.lowercased() == name.lowercased() }) else {
            return "Error: MCP server '\(name)' not found."
        }

        config.servers[index].enabled = enabled
        try await configStore.saveMCP(config)

        let action = enabled ? "enabled" : "disabled"
        return "✓ MCP server '\(config.servers[index].id)' \(action)."
    }

    private static func configureAuth(
        serverName: String,
        arguments: [String],
        configStore: ConfigurationStore,
        credStore: CredentialStore,
        inputReader: @Sendable (String) -> String?
    ) async throws -> String {
        var config = try await loadMCPConfig(configStore: configStore)
        guard let index = config.servers.firstIndex(where: { $0.id == serverName || $0.alias.lowercased() == serverName.lowercased() }) else {
            return "Error: MCP server '\(serverName)' not found."
        }
        let server = config.servers[index]

        var token: String?
        var headerName: String?

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "--token" || arg == "--bearer" {
                if i + 1 < arguments.count {
                    token = arguments[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            } else if arg == "--header" {
                if i + 1 < arguments.count {
                    headerName = arguments[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            } else if arg == "--value" {
                if i + 1 < arguments.count {
                    token = arguments[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        }

        let authKind: StoredMCPAuthenticationKind
        let secretValue: String
        let resolvedHeader: String?

        if let token, !token.isEmpty {
            if let headerName, !headerName.isEmpty {
                authKind = .header
                resolvedHeader = headerName
                secretValue = token
            } else {
                authKind = .bearer
                resolvedHeader = nil
                secretValue = token
            }
        } else {
            // Interactive prompts
            let choice = (inputReader("Select auth method for '\(server.id)':\n  1) Browser OAuth (Web Login - Recommended)\n  2) Bearer Token\n  3) Custom HTTP Header\nEnter choice (1, 2, or 3): ") ?? "1").trimmingCharacters(in: .whitespacesAndNewlines)
            if choice == "1" && server.transport == .streamableHTTP {
                return try await loginServer(
                    serverName: serverName,
                    configStore: configStore,
                    credStore: credStore,
                    inputReader: inputReader
                )
            } else if choice == "3" {
                authKind = .header
                let hName = inputReader("Enter HTTP Header Name (e.g. X-API-Key): ")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "X-API-Key"
                resolvedHeader = hName.isEmpty ? "X-API-Key" : hName
                guard let val = inputReader("Enter Secret Value for header '\(resolvedHeader!)': ")?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty else {
                    return "Error: Secret value cannot be empty."
                }
                secretValue = val
            } else {
                authKind = .bearer
                resolvedHeader = nil
                guard let val = inputReader("Enter Bearer Token: ")?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty else {
                    return "Error: Bearer token cannot be empty."
                }
                secretValue = val
            }
        }

        let ref = CredentialRef("mcp-\(server.id)-secret")
        try await credStore.setSecret(secretValue, for: ref)

        config.servers[index].authentication = MCPAuthenticationConfiguration(
            kind: authKind,
            headerName: resolvedHeader,
            credential: ref
        )
        try await configStore.saveMCP(config)

        return CLIFormatter.renderTree(
            header: "✓ Successfully configured authentication for MCP server '\(server.id)'",
            items: [
                ("Auth Kind", authKind.rawValue),
                ("Header", resolvedHeader ?? "Authorization: Bearer <token>"),
                ("Vault Ref", "\(ref.rawValue) (stored in encrypted vault)")
            ]
        )
    }

    private static func loginServer(
        serverName: String,
        configStore: ConfigurationStore,
        credStore: CredentialStore,
        inputReader: @Sendable (String) -> String?
    ) async throws -> String {
        var config = try await loadMCPConfig(configStore: configStore)
        guard let index = config.servers.firstIndex(where: { $0.id == serverName || $0.alias.lowercased() == serverName.lowercased() }) else {
            return "Error: MCP server '\(serverName)' not found."
        }
        let server = config.servers[index]
        guard server.transport == .streamableHTTP, let endpointStr = server.endpoint, let endpointURL = URL(string: endpointStr) else {
            return "Error: MCP OAuth login is only supported for streamableHTTP transport servers with an endpoint."
        }

        FileHandle.standardError.write(Data("🔍 Discovering OAuth endpoints for '\(server.id)' via RFC 9728 & RFC 8414...\n".utf8))
        let endpoints = try await MCPOAuthClient.discoverEndpoints(for: endpointURL)

        // 1. Start Loopback server
        let loopback = try LoopbackOAuthServer(preferredPort: 54321)
        let redirectURI = URL(string: "http://localhost:\(loopback.port)/callback")!

        // 2. Dynamic Client Registration (RFC 7591)
        var clientID = "LingXiAgent"
        var clientSecret: String?
        var authMethod: String?

        if let regEndpoint = endpoints.registrationEndpoint {
            FileHandle.standardError.write(Data("📝 Registering dynamic client with authorization server...\n".utf8))
            if let regResp = try? await MCPOAuthClient.registerClient(registrationEndpoint: regEndpoint, redirectURI: redirectURI) {
                clientID = regResp.clientID
                clientSecret = regResp.clientSecret
                authMethod = regResp.tokenEndpointAuthMethod
            }
        }

        // 3. Generate PKCE & Authorization URL
        let state = PKCE.generateVerifier(length: 16)
        let verifier = PKCE.generateVerifier(length: 32)
        let challenge = PKCE.challenge(for: verifier)

        var authComp = URLComponents(url: endpoints.authorizationEndpoint, resolvingAgainstBaseURL: true)!
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope", value: endpoints.scopes.joined(separator: " "))
        ]
        authComp.queryItems = queryItems
        guard let authorizeURL = authComp.url else {
            loopback.closeServer()
            return "Error: Failed to construct authorization URL."
        }

        let browserMsg = """
        🌐 Opening browser for authorization:
          \(authorizeURL.absoluteString)

        Waiting for browser callback on \(redirectURI.absoluteString) ...

        """
        FileHandle.standardError.write(Data(browserMsg.utf8))
        MCPOAuthClient.openURLInBrowser(authorizeURL)

        // 4. Wait for authorization code via loopback server
        let code: String
        do {
            code = try await loopback.waitForCallback(expectedState: state, timeoutSeconds: 180.0)
        } catch {
            loopback.closeServer()
            return "OAuth authorization failed: \(error.localizedDescription)"
        }

        FileHandle.standardError.write(Data("🔑 Exchanging authorization code for access token...\n".utf8))
        let token: String
        do {
            token = try await MCPOAuthClient.exchangeCodeForToken(
                tokenEndpoint: endpoints.tokenEndpoint,
                clientID: clientID,
                clientSecret: clientSecret,
                authMethod: authMethod,
                redirectURI: redirectURI,
                code: code,
                codeVerifier: verifier
            )
        } catch {
            return "OAuth token exchange failed: \(error.localizedDescription)"
        }

        let ref = CredentialRef("mcp-\(server.id)-secret")
        try await credStore.setSecret(token, for: ref)

        config.servers[index].authentication = MCPAuthenticationConfiguration(
            kind: .bearer,
            headerName: nil,
            credential: ref
        )
        try await configStore.saveMCP(config)

        let probeResult = await probeServerSummary(server: config.servers[index], credStore: credStore, secretResolver: nil)

        return CLIFormatter.renderTree(
            header: "✓ Successfully authorized MCP server '\(server.id)' via OAuth 2.1",
            items: [
                ("Provider", endpoints.resourceName ?? server.id),
                ("Token Endpoint", endpoints.tokenEndpoint.absoluteString),
                ("Vault Ref", "\(ref.rawValue) (stored in encrypted vault)"),
                ("Health", probeResult.health),
                ("Discovered Tools", probeResult.toolCount)
            ]
        )
    }

    private static func statusServers(
        serverName: String?,
        configStore: ConfigurationStore,
        credStore: CredentialStore,
        secretResolver: (any SecretResolver)?
    ) async throws -> String {
        let config = try await loadMCPConfig(configStore: configStore)

        if let serverName {
            guard let server = config.servers.first(where: { $0.id == serverName || $0.alias.lowercased() == serverName.lowercased() }) else {
                return "Error: MCP server '\(serverName)' not found."
            }
            return await probeSingleServer(server: server, credStore: credStore, secretResolver: secretResolver)
        } else {
            if config.servers.isEmpty {
                return "No MCP servers configured."
            }

            var rows: [[String]] = []
            for server in config.servers {
                let statusStr = server.enabled ? "● Enabled" : "○ Disabled"
                let probeResult = await probeServerSummary(server: server, credStore: credStore, secretResolver: secretResolver)
                let endpointStr = server.transport == .stdio ? (server.command ?? "-") : (server.endpoint ?? "-")
                rows.append([
                    server.id,
                    server.transport.rawValue,
                    statusStr,
                    probeResult.health,
                    probeResult.toolCount,
                    endpointStr
                ])
            }

            let table = CLIFormatter.renderTable(
                headers: ["SERVER", "TRANSPORT", "STATUS", "HEALTH", "TOOLS", "TARGET"],
                rows: rows
            )
            return """
            MCP Servers Health & Discovery:
            \(table)
            """
        }
    }

    private static func probeServerSummary(
        server: StoredMCPServerConfiguration,
        credStore: CredentialStore,
        secretResolver: (any SecretResolver)?
    ) async -> (health: String, toolCount: String) {
        guard server.enabled else {
            return ("○ Disabled", "-")
        }

        do {
            let tools = try await probeTools(server: server, credStore: credStore, secretResolver: secretResolver)
            return ("✓ Healthy", "\(tools.count) tools")
        } catch let err as CoreError {
            if err.message.contains("OAuth") || err.message.contains("Authentication") || err.code == .permissionDenied {
                return ("🔑 Auth Required", "auth needed")
            }
            return ("⚠ Error", "failed")
        } catch {
            return ("⚠ Error", "failed")
        }
    }

    private static func probeSingleServer(
        server: StoredMCPServerConfiguration,
        credStore: CredentialStore,
        secretResolver: (any SecretResolver)?
    ) async -> String {
        let statusStr = server.enabled ? "● Enabled" : "○ Disabled"
        guard server.enabled else {
            return CLIFormatter.renderTree(
                header: "MCP Server Status: \(server.id) (\(statusStr))",
                items: [
                    ("Alias", server.alias),
                    ("Transport", server.transport.rawValue),
                    ("Status", "Disabled (Use 'lingxiagent mcp enable \(server.id)' to enable)")
                ]
            )
        }

        do {
            let tools = try await probeTools(server: server, credStore: credStore, secretResolver: secretResolver)
            var items: [(String, String)] = [
                ("Alias", server.alias),
                ("Transport", server.transport.rawValue),
                ("Health", "✓ Healthy"),
                ("Target", server.transport == .stdio ? (server.command ?? "-") : (server.endpoint ?? "-")),
                ("Discovered Tools", "\(tools.count)")
            ]
            for tool in tools.prefix(10) {
                let desc = tool.entry.shortDescription.isEmpty ? tool.entry.title : tool.entry.shortDescription
                items.append(("  • \(tool.entry.upstreamName)", desc))
            }
            if tools.count > 10 {
                items.append(("  ...", "and \(tools.count - 10) more tools"))
            }

            return CLIFormatter.renderTree(
                header: "MCP Server Status: \(server.id) (● Healthy)",
                items: items
            )
        } catch {
            let errorMessage: String = (error as? CoreError)?.message ?? error.localizedDescription
            let isAuthRequired = errorMessage.lowercased().contains("oauth") || errorMessage.lowercased().contains("authentication required")
            let headerStatus = isAuthRequired ? "🔑 Auth Required" : "✕ Connection Failed"
            let healthText = isAuthRequired ? "🔑 Requires OAuth / Authentication" : "✕ Unavailable"
            return CLIFormatter.renderTree(
                header: "MCP Server Status: \(server.id) (\(headerStatus))",
                items: [
                    ("Alias", server.alias),
                    ("Transport", server.transport.rawValue),
                    ("Health", healthText),
                    ("Error", errorMessage)
                ]
            )
        }
    }

    private static func probeTools(
        server: StoredMCPServerConfiguration,
        credStore: CredentialStore,
        secretResolver: (any SecretResolver)?
    ) async throws -> [MCPDiscoveredTool] {
        var secretDict: [String: String] = [:]
        if let credRef = server.authentication.credential {
            if let secret = try? await credStore.secret(for: credRef), !secret.isEmpty {
                secretDict[credRef.rawValue] = secret
            }
        }
        for envItem in server.environment {
            if let secret = try? await credStore.secret(for: envItem.credential), !secret.isEmpty {
                secretDict[envItem.credential.rawValue] = secret
            }
        }

        struct ChainedSecretResolver: SecretResolver, Sendable {
            let primary: any SecretResolver
            let fallback: any SecretResolver
            func resolve(_ ref: SecretRef) throws -> String? {
                if let val = try primary.resolve(ref), !val.isEmpty { return val }
                return try fallback.resolve(ref)
            }
        }
        let fallback = InMemorySecretResolver(secretDict)
        let resolver: any SecretResolver = secretResolver.map { ChainedSecretResolver(primary: $0, fallback: fallback) } ?? fallback

        switch server.transport {
        case .streamableHTTP:
            guard let endpointStr = server.endpoint, let url = URL(string: endpointStr) else {
                throw CoreError(code: .mcpServerUnavailable, message: "Invalid endpoint URL: \(server.endpoint ?? "")")
            }
            let auth: MCPAuthentication
            switch server.authentication.kind {
            case .none:
                auth = .none
            case .bearer:
                auth = server.authentication.credential.map { .bearer(SecretRef($0.rawValue)) } ?? .none
            case .header:
                if let name = server.authentication.headerName, let cred = server.authentication.credential {
                    auth = .header(name: name, value: SecretRef(cred.rawValue))
                } else {
                    auth = .none
                }
            }

            let runtimeConfig = MCPServerConfiguration(
                serverID: MCPServerID(server.id),
                alias: server.alias,
                transport: .streamableHTTP,
                endpoint: url,
                enabled: server.enabled,
                auth: auth,
                timeoutSeconds: server.timeoutSeconds
            )
            let transport = MCPStreamableHTTPTransport(configuration: runtimeConfig, resolver: resolver)
            return try await transport.listTools()

        case .stdio:
            guard let cmd = server.command else {
                throw CoreError(code: .mcpServerUnavailable, message: "Missing stdio command for server \(server.id)")
            }
            guard cmd.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: cmd) else {
                throw CoreError(code: .mcpServerUnavailable, message: "Command not found or not executable: \(cmd)")
            }

            var envMap: [String: SecretRef] = [:]
            for envItem in server.environment {
                envMap[envItem.name] = SecretRef(envItem.credential.rawValue)
            }

            let runtimeConfig = MCPServerConfiguration(
                serverID: MCPServerID(server.id),
                alias: server.alias,
                transport: .stdio,
                command: cmd,
                arguments: server.arguments,
                enabled: server.enabled,
                environment: envMap,
                timeoutSeconds: server.timeoutSeconds
            )
            let transport = MCPStdioTransport(configuration: runtimeConfig, resolver: resolver)
            return try await transport.listTools()
        }
    }

    private static func addServer(arguments: [String], configStore: ConfigurationStore) async throws -> String {
        var config = try await loadMCPConfig(configStore: configStore)

        guard let first = arguments.first, !first.hasPrefix("-") else {
            return """
            Error: Server ID is required.
            Usage:
              lingxiagent mcp add <id> --command <path> [--arg <arg>...] [--alias <alias>]
              lingxiagent mcp add <id> --transport http --endpoint <url> [--alias <alias>]
            """
        }
        let id = first

        guard !config.servers.contains(where: { $0.id == id }) else {
            return "Error: MCP server '\(id)' already exists."
        }

        var alias = id
        var transportKind: StoredMCPTransport = .stdio
        var command: String?
        var argsList: [String] = []
        var endpoint: String?
        var timeout: Double = 60

        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "--alias" && i + 1 < arguments.count {
                alias = arguments[i + 1]
                i += 2
            } else if (arg == "--transport" || arg == "-t") && i + 1 < arguments.count {
                let t = arguments[i + 1].lowercased()
                if t == "http" || t == "streamablehttp" {
                    transportKind = .streamableHTTP
                } else {
                    transportKind = .stdio
                }
                i += 2
            } else if (arg == "--command" || arg == "-c") && i + 1 < arguments.count {
                command = arguments[i + 1]
                i += 2
            } else if (arg == "--endpoint" || arg == "-u") && i + 1 < arguments.count {
                endpoint = arguments[i + 1]
                transportKind = .streamableHTTP
                i += 2
            } else if arg == "--arg" && i + 1 < arguments.count {
                argsList.append(arguments[i + 1])
                i += 2
            } else if arg == "--timeout" && i + 1 < arguments.count {
                if let t = Double(arguments[i + 1]), t > 0 {
                    timeout = t
                }
                i += 2
            } else {
                i += 1
            }
        }

        if transportKind == .stdio && command == nil {
            return "Error: Stdio transport requires --command <path>."
        }
        if transportKind == .streamableHTTP && endpoint == nil {
            return "Error: HTTP transport requires --endpoint <url>."
        }

        let newServer = StoredMCPServerConfiguration(
            id: id,
            alias: alias,
            transport: transportKind,
            command: command,
            arguments: argsList,
            endpoint: endpoint,
            enabled: true,
            timeoutSeconds: timeout
        )

        config.servers.append(newServer)
        try await configStore.saveMCP(config)

        return "✓ Added MCP server '\(id)' (\(transportKind.rawValue))."
    }

    private static func removeServer(name: String, configStore: ConfigurationStore) async throws -> String {
        var config = try await loadMCPConfig(configStore: configStore)
        guard let index = config.servers.firstIndex(where: { $0.id == name || $0.alias.lowercased() == name.lowercased() }) else {
            return "Error: MCP server '\(name)' not found."
        }
        let removedID = config.servers[index].id
        config.servers.remove(at: index)
        try await configStore.saveMCP(config)
        return "✓ Removed MCP server '\(removedID)'."
    }

    private static func loadMCPConfig(configStore: ConfigurationStore) async throws -> MCPConfiguration {
        do {
            let snapshot = try await configStore.load()
            return snapshot.mcp
        } catch {
            return MCPConfiguration(servers: [])
        }
    }

    public static func renderHelp() -> String {
        """
        MCP Server Management Commands:

        USAGE:
          lingxiagent mcp list                      列出所有已配置的 MCP 服务器
          lingxiagent mcp status [name]             检测指定或全部 MCP 服务的连通性与工具发现
          lingxiagent mcp enable <name>             启用指定 MCP 服务器
          lingxiagent mcp disable <name>            禁用指定 MCP 服务器
          lingxiagent mcp login <name>              通过 OAuth 2.1 (浏览器免密网页授权) 登录 MCP 服务
          lingxiagent mcp auth <name> [options]     配置 MCP 服务器认证凭据 (Bearer Token / Custom Header)
          lingxiagent mcp add <id> [options]        添加新的 MCP 服务器
          lingxiagent mcp remove <name>             删除指定的 MCP 服务器
          lingxiagent mcp help                      显示此帮助信息

        AUTH OPTIONS:
          --token <token>                           指定 Bearer Token
          --header <name> --value <token>           指定自定义 HTTP Header 及其 Secret

        ADD OPTIONS:
          --alias <alias>                           指定服务器别名 (默认与 ID 相同)
          --transport <stdio|http>                  指定传输类型 (默认 stdio)
          --command <path>                          stdio 可执行程序绝对路径
          --arg <arg>                               向 stdio 传递命令行参数 (可重复)
          --endpoint <url>                          HTTP 端点 URL (例如 https://example.com/mcp)
          --timeout <seconds>                       超时时间 (默认 60 秒)
        """
    }
}
