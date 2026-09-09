import Foundation
import LingXiProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum AuthCLI {
    public static func installSignalHandlers() {
        #if os(macOS) || os(Linux)
        signal(SIGINT) { _ in
            var term = termios()
            if tcgetattr(STDIN_FILENO, &term) == 0 {
                term.c_lflag |= tcflag_t(ECHO | ICANON | ISIG)
                _ = tcsetattr(STDIN_FILENO, TCSANOW, &term)
            }
            FileHandle.standardError.write(Data("\n".utf8))
            _exit(130)
        }
        signal(SIGTERM) { _ in
            _exit(143)
        }
        #endif
    }

    @Sendable public static func readPrompt(prompt: String) -> String? {
        FileHandle.standardError.write(Data(prompt.utf8))
        return readLine(strippingNewline: true)
    }

    @Sendable public static func readSecretWithoutEcho(prompt: String) -> String? {
        FileHandle.standardError.write(Data(prompt.utf8))
        #if os(macOS) || os(Linux)
        if isatty(STDIN_FILENO) == 1 {
            var original = termios()
            if tcgetattr(STDIN_FILENO, &original) == 0 {
                var raw = original
                // Disable ECHO, but explicitly preserve ISIG (Ctrl+C generates SIGINT) and ICANON
                raw.c_lflag &= ~tcflag_t(ECHO)
                raw.c_lflag |= tcflag_t(ISIG)
                _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
                defer {
                    var restore = original
                    _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
                    FileHandle.standardError.write(Data("\n".utf8))
                }
                return readLine(strippingNewline: true)
            }
        }
        #endif
        return readLine(strippingNewline: true)
    }

    public static func run(
        arguments: [String],
        dataRoot: URL? = nil,
        credentialStore: CredentialStore? = nil,
        configurationStore: ConfigurationStore? = nil,
        inputReader: (@Sendable (String) -> String?)? = nil,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async throws -> String {
        installSignalHandlers()
        let root = dataRoot ?? LingXiDataRootResolver.resolve(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let credStore: CredentialStore
        if let credentialStore {
            credStore = credentialStore
        } else {
            credStore = try PlatformSecureCredentialStore(dataRoot: root, passphrase: ProcessInfo.processInfo.environment["LINGXI_CREDENTIALS_PASSPHRASE"])
        }
        let configStore = try configurationStore ?? ConfigurationStore(dataRoot: root)

        var args = arguments
        if args.first == "auth" {
            args.removeFirst()
        }

        let subcommand = args.first ?? "list"

        switch subcommand {
        case "list":
            return try await listProviders(configStore: configStore, credStore: credStore)

        case "status":
            let providerID = args.count > 1 ? args[1] : nil
            return try await statusProviders(providerID: providerID, configStore: configStore, credStore: credStore)

        case "login":
            guard args.count > 1 else {
                return "Error: Provider ID is required for login. Usage: lingxiagent auth login <product>"
            }
            let providerID = args[1]
            return try await loginProvider(
                providerID: providerID,
                configStore: configStore,
                credStore: credStore,
                inputReader: inputReader,
                httpClient: httpClient
            )

        case "logout":
            guard args.count > 1 else {
                return "Error: Provider ID is required for logout. Usage: lingxiagent auth logout <product>"
            }
            let providerID = args[1]
            return try await logoutProvider(providerID: providerID, configStore: configStore, credStore: credStore)

        case "matrix", "compat":
            return renderMatrix()

        case "models":
            let providerID = args.count > 1 ? args[1] : nil
            return renderModels(providerID: providerID)

        case "set":
            guard args.count > 1 else {
                return "Error: Credential reference is required. Usage: lingxiagent auth set <key> [value]"
            }
            let key = args[1]
            let val: String
            if args.count > 2 {
                val = args[2]
            } else {
                guard let input = (inputReader ?? AuthCLI.readSecretWithoutEcho)("Enter secret value for '\(key)': "), !input.isEmpty else {
                    return "Error: Secret value cannot be empty."
                }
                val = input
            }
            try await credStore.setSecret(val, for: CredentialRef(key))
            return "✓ Successfully stored credential for '\(key)' in encrypted vault."

        case "import-env":
            guard args.count > 1 else {
                return "Error: Environment variable name is required. Usage: lingxiagent auth import-env <ENV_VAR_NAME> [target_key]"
            }
            let envName = args[1]
            let targetKey = args.count > 2 ? args[2] : envName
            guard let envVal = ProcessInfo.processInfo.environment[envName], !envVal.isEmpty else {
                return "Error: Environment variable '\(envName)' is not set or empty in current process."
            }
            try await credStore.setSecret(envVal, for: CredentialRef(targetKey))
            if targetKey != "env:\(envName)" {
                try await credStore.setSecret(envVal, for: CredentialRef("env:\(envName)"))
            }
            return "✓ Successfully imported '\(envName)' into encrypted vault (as '\(targetKey)' and 'env:\(envName)')."

        case "help", "--help", "-h":
            return renderHelp()

        default:
            // Support shorthand: lingxiagent auth <product>
            if BuiltinProviderCatalog.profile(for: subcommand) != nil {
                return try await loginProvider(
                    providerID: subcommand,
                    configStore: configStore,
                    credStore: credStore,
                    inputReader: inputReader,
                    httpClient: httpClient
                )
            }
            return renderHelp()
        }
    }

    private static func listProviders(configStore: ConfigurationStore, credStore: CredentialStore) async throws -> String {
        let snapshot = try await configStore.load()
        var rows: [[String]] = []

        for profile in BuiltinProviderCatalog.profiles {
            let isLocalNoAuth = profile.authMethods.contains("none")
            let isOAuth = profile.authMethods.contains("oauth")
            let configured = snapshot.providers.providers[profile.id]
            var authStatus = "○ Unauthenticated"

            if isLocalNoAuth {
                authStatus = "⚡ No Auth Needed"
            } else if isOAuth {
                let ref = CredentialRef("provider-\(profile.id)-oauth")
                if let secret = try? await credStore.secret(for: ref), !secret.isEmpty {
                    authStatus = "✓ OAuth Authenticated"
                } else {
                    authStatus = "○ OAuth Required"
                }
            } else if configured?.options.apiKey != nil {
                authStatus = "✓ Authenticated"
            } else {
                let ref = CredentialRef("provider-\(profile.id)-key")
                if let secret = try? await credStore.secret(for: ref), !secret.isEmpty {
                    authStatus = "✓ Authenticated"
                }
            }

            let modelCount = "\(profile.models.count) models"
            rows.append([profile.id, profile.protocolFamily, authStatus, modelCount])
        }

        let table = CLIFormatter.renderTable(
            headers: ["Product / Provider", "Protocol", "Auth Status", "Models"],
            rows: rows,
            minColumnWidths: [22, 20, 22, 10],
            borderStyle: .rounded
        )

        return """
=== Available Providers ===
\(table)

💡 Next Steps:
  • To authenticate: lingxiagent auth login <product> (or shorthand: lingxiagent auth <product>)
  • Inspect details: lingxiagent auth status <product>
  • Compatibility:   lingxiagent matrix
"""
    }

    private static func statusProviders(providerID: String?, configStore: ConfigurationStore, credStore: CredentialStore) async throws -> String {
        let snapshot = try await configStore.load()

        if let providerID {
            guard let profile = BuiltinProviderCatalog.profile(for: providerID) else {
                return "Error: Unknown provider or product '\(providerID)'"
            }
            let configured = snapshot.providers.providers[providerID]
            let isLocalNoAuth = profile.authMethods.contains("none")
            let isOAuth = profile.authMethods.contains("oauth")
            let keyRef = CredentialRef("provider-\(providerID)-key")
            let oauthRef = CredentialRef("provider-\(providerID)-oauth")

            let hasKeySecret = (try? await credStore.secret(for: keyRef)) != nil || configured?.options.apiKey != nil
            let hasOAuthSecret = (try? await credStore.secret(for: oauthRef)) != nil

            let statusText: String
            if isLocalNoAuth {
                statusText = "⚡ No Auth Needed (Local Runtime)"
            } else if isOAuth {
                if hasOAuthSecret {
                    statusText = "✓ OAuth Authenticated (Tokens Securely Stored)"
                } else {
                    statusText = "○ OAuth Required (Not Logged In)"
                }
            } else if hasKeySecret {
                statusText = "✓ Authenticated (Credentials Securely Stored)"
            } else {
                statusText = "○ Unauthenticated"
            }

            var fields: [(label: String, value: String)] = [
                ("Product", "\(profile.displayName) (\(profile.id))"),
                ("Vendor", profile.vendor),
                ("Protocol", profile.protocolFamily),
                ("Endpoint", configured?.options.baseURL ?? profile.endpoint),
                ("Auth Mode", profile.authMethods.joined(separator: ", ")),
                ("Status", statusText)
            ]

            if isOAuth {
                let genProduct = BuiltinProviderCatalog.catalog?.products.first(where: { $0.id == providerID })
                if let oauth = genProduct?.oauth {
                    fields.append(("OAuth Client", oauth.clientID))
                    fields.append(("OAuth Scopes", oauth.scopes.joined(separator: ", ")))
                    fields.append(("PKCE", oauth.usePKCE ? "Enabled (S256)" : "Disabled"))
                }
            }

            var displayModels: [String] = []
            if profile.modelDiscovery == .authenticatedRemote && hasOAuthSecret {
                var accountRef = providerID
                if let secret = try? await credStore.secret(for: oauthRef), !secret.isEmpty {
                    accountRef = AccountScopedCatalogCache.accountHash(fromTokenOrIdentifier: secret)
                    var cached = await AccountScopedCatalogCache.shared.load(productID: providerID, accountRef: accountRef)
                    if (cached == nil || cached?.models.isEmpty == true) {
                        let accessToken: String? = {
                            if let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: Data(secret.utf8)) {
                                return tokens.accessToken
                            }
                            if let json = try? JSONSerialization.jsonObject(with: Data(secret.utf8)) as? [String: Any] {
                                return (json["accessToken"] as? String) ?? (json["access_token"] as? String)
                            }
                            return secret.contains("{") ? nil : secret
                        }()
                        if let tokenStr = accessToken, !tokenStr.isEmpty {
                            let tokens = OAuthTokens(accessToken: tokenStr)
                            if let discovered = try? await CodexRemoteModelDiscovery.discoverModels(tokens: tokens) {
                                _ = try? await AccountScopedCatalogCache.shared.save(
                                    productID: providerID,
                                    accountRef: accountRef,
                                    models: discovered,
                                    source: "ChatGPT Remote Model Catalog"
                                )
                                cached = await AccountScopedCatalogCache.shared.load(productID: providerID, accountRef: accountRef)
                            }
                        }
                    }
                    if let record = cached {
                        displayModels = record.models.map { m -> String in
                            let reasoning = m.supportedReasoningEfforts.isEmpty ? "none" : m.supportedReasoningEfforts.map(\.rawValue).joined(separator: ", ")
                            let tools = m.toolCalling ? "tools: yes" : "tools: no"
                            let vision = m.vision ? ", vision: yes" : ""
                            return "  • \(m.id) (\(m.displayName)) [reasoning: \(reasoning), \(tools)\(vision)]"
                        }
                    }
                }
            } else {
                displayModels = profile.models.map { m -> String in
                    let reasoning = m.reasoningCapability?.mode.rawValue ?? "none"
                    let tools = m.toolCall ? "tools: yes" : "tools: no"
                    let vision = m.vision ? ", vision: yes" : ""
                    return "  • \(m.id) (\(m.displayName)) [reasoning: \(reasoning), \(tools)\(vision)]"
                }
            }

            let footer: String
            if hasKeySecret || hasOAuthSecret {
                footer = "Run 'lingxiagent auth logout \(profile.id)' to remove credentials."
            } else if !isLocalNoAuth {
                footer = "Run 'lingxiagent auth login \(profile.id)' (or 'lingxiagent auth \(profile.id)') to authenticate."
            } else {
                footer = "Ready to use without authentication."
            }

            return CLIFormatter.renderCard(
                title: "Provider: \(profile.displayName) (\(profile.id))",
                fields: fields,
                sections: [("Models (\(displayModels.count)):", displayModels)],
                footer: footer,
                borderStyle: .rounded
            )
        } else {
            return try await listProviders(configStore: configStore, credStore: credStore)
        }
    }

    private static func loginProvider(
        providerID: String,
        configStore: ConfigurationStore,
        credStore: CredentialStore,
        inputReader: (@Sendable (String) -> String?)?,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    ) async throws -> String {
        guard let profile = BuiltinProviderCatalog.profile(for: providerID) else {
            return "Error: Unknown provider or product '\(providerID)'"
        }

        if profile.authMethods.contains("none") {
            return "Provider '\(providerID)' is a local runtime and does not require authentication."
        }

        let isOAuth = profile.authMethods.contains("oauth")

        if isOAuth {
            return try await loginOAuthProduct(
                profile: profile,
                configStore: configStore,
                credStore: credStore,
                inputReader: inputReader ?? { @Sendable in readPrompt(prompt: $0) },
                httpClient: httpClient
            )
        } else {
            return try await loginAPIKeyProduct(
                profile: profile,
                configStore: configStore,
                credStore: credStore,
                inputReader: inputReader ?? { @Sendable in readSecretWithoutEcho(prompt: $0) }
            )
        }
    }

    private static func loginOAuthProduct(
        profile: BuiltinProviderCatalog.ProviderProfile,
        configStore: ConfigurationStore,
        credStore: CredentialStore,
        inputReader: @Sendable (String) -> String?,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    ) async throws -> String {
        let productID = profile.id
        let genProduct = BuiltinProviderCatalog.catalog?.products.first(where: { $0.id == productID })
        guard let oauthConfig = genProduct?.oauth,
              let authURL = URL(string: oauthConfig.authURL),
              let tokenURL = URL(string: oauthConfig.tokenURL) else {
            return "Error: Incomplete OAuth configuration for '\(productID)'"
        }

        let redirectURI = URL(string: oauthConfig.redirectURI ?? "http://localhost:1455/auth/callback")!
        let authResult = OAuthFlowCoordinator.makeAuthorizationURL(
            authEndpoint: authURL,
            clientID: oauthConfig.clientID,
            redirectURI: redirectURI,
            scopes: oauthConfig.scopes,
            usePKCE: oauthConfig.usePKCE
        )

        let prompt = """
[OAuth Authorization]
Please open this authorization URL in your browser:
\(authResult.authorizeURL.absoluteString)

Note: After logging in and approving access in your browser, your browser will redirect to \(redirectURI.absoluteString).
If the browser displays 'Unable to connect' (because no background server is running), simply copy the FULL URL from the browser's address bar (containing '?code=...&state=...') and paste it below.

Enter the authorization callback URL or code (press Enter to cancel): 
"""

        guard let input = inputReader(prompt)?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
            return "OAuth authorization cancelled."
        }

        let code: String
        if input.hasPrefix("http://") || input.hasPrefix("https://") {
            let cbURL = URL(string: input)!
            let cbServer = OAuthCallbackServer(expectedState: authResult.state)
            let res = await cbServer.handleCallbackURL(cbURL)
            switch res {
            case .success(let c):
                code = c
            case .error(let err):
                return "OAuth authorization failed: \(err)"
            case .stateMismatch:
                return "OAuth authorization failed: State validation mismatch (potential CSRF attack)."
            }
        } else {
            code = input
        }

        let tokens: OAuthTokens
        do {
            tokens = try await OAuthFlowCoordinator.exchangeCodeForTokens(
                tokenEndpoint: tokenURL,
                clientID: oauthConfig.clientID,
                redirectURI: redirectURI,
                code: code,
                codeVerifier: authResult.codeVerifier,
                client: httpClient
            )
        } catch {
            return "OAuth token exchange failed: \(error.localizedDescription)"
        }

        let ref = CredentialRef("provider-\(productID)-oauth")
        let serialized = try JSONEncoder().encode(tokens)
        if let tokenStr = String(data: serialized, encoding: .utf8) {
            try await credStore.setSecret(tokenStr, for: ref)
        }

        // Account-scoped identity hash
        let accountRef = AccountScopedCatalogCache.accountHash(fromTokenOrIdentifier: tokens.accessToken)

        // Perform authenticated remote model discovery
        var discoveredModels: [DiscoveredRemoteModel] = []
        var discoveryError: String? = nil
        do {
            discoveredModels = try await CodexRemoteModelDiscovery.discoverModels(
                tokens: tokens,
                endpoint: nil,
                requestProfile: genProduct?.requestProfiles.values.first,
                httpClient: httpClient
            )
            try await AccountScopedCatalogCache.shared.save(
                productID: productID,
                accountRef: accountRef,
                models: discoveredModels
            )
        } catch {
            discoveryError = error.localizedDescription
            await AccountScopedCatalogCache.shared.markStale(productID: productID, accountRef: accountRef)
            if let cached = await AccountScopedCatalogCache.shared.load(productID: productID, accountRef: accountRef) {
                discoveredModels = cached.models
            }
        }

        let snapshot = try await configStore.load()
        var currentProviders = snapshot.providers.providers

        let adapterName: String
        switch profile.protocolFamily {
        case "openai_responses": adapterName = "openai-responses"
        case "anthropic_messages": adapterName = "anthropic-messages"
        default: adapterName = "openai-compatible"
        }

        // providers.json is configuration only; models are stored in account-scoped cache
        currentProviders[productID] = PublicProviderConfiguration(
            name: profile.displayName,
            adapter: adapterName,
            options: PublicProviderOptions(
                baseURL: profile.endpoint,
                apiKey: "{oauth:\(ref.rawValue)}"
            ),
            models: [:]
        )

        let newConfig = ProvidersConfiguration(
            schema: snapshot.providers.schema,
            version: snapshot.providers.version,
            model: snapshot.providers.model,
            providers: currentProviders
        )
        try await configStore.saveProviders(newConfig)

        let resolvedModels = ResolvedModelCatalogResolver.resolve(
            productID: productID,
            authenticatedModels: discoveredModels,
            staticCatalog: BuiltinProviderCatalog.catalog
        )

        let expiryDesc = tokens.expiresAt.map { "expires at \($0)" } ?? "no expiration"
        let statusDesc = discoveryError == nil ? "Authenticated remote catalog synced (\(discoveredModels.count) models)" : "Discovery warning: \(discoveryError!) (using cached)"
        let treeOutput = CLIFormatter.renderTree(
            header: "✓ Successfully authenticated \(profile.displayName) via OAuth!",
            items: [
                ("Product", productID),
                ("Account", "Scoped ID: \(accountRef)"),
                ("Security", "OAuth tokens securely saved in AES-256 / Keychain vault (\(ref.rawValue))"),
                ("Tokens", "Access token (\(expiryDesc)), Refresh token: \(tokens.refreshToken != nil ? "present (rotating)" : "none")"),
                ("Catalog Cache", "~/.lingxiagent/cache/provider-catalog/\(productID)/\(accountRef).json"),
                ("Discovery", statusDesc),
                ("Configuration", "Clean provider configuration written to ~/.lingxiagent/config.json (models detached)")
            ]
        )

        let modelLines: String
        if resolvedModels.isEmpty {
            modelLines = "  (No remote models discovered yet; check account entitlements)"
        } else {
            modelLines = resolvedModels.map { m in
                let note = m.metadataIncomplete ? " [new model / metadata pending]" : ""
                return "  • \(m.id) (\(m.displayName))\(note)"
            }.joined(separator: "\n")
        }

        return """
\(treeOutput)
Available models:
\(modelLines)
"""
    }

    private static func loginAPIKeyProduct(
        profile: BuiltinProviderCatalog.ProviderProfile,
        configStore: ConfigurationStore,
        credStore: CredentialStore,
        inputReader: @Sendable (String) -> String?
    ) async throws -> String {
        let providerID = profile.id
        let prompt = "Enter API Key for \(profile.displayName) (\(providerID)): "
        guard let secret = inputReader(prompt)?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty else {
            return "Error: API Key cannot be empty."
        }

        let ref = CredentialRef("provider-\(providerID)-key")
        try await credStore.setSecret(secret, for: ref)

        let snapshot = try await configStore.load()
        var currentProviders = snapshot.providers.providers

        var modelsDict: [String: PublicModelConfiguration] = [:]
        for m in profile.models {
            modelsDict[m.id] = PublicModelConfiguration(
                name: m.displayName,
                reasoning: m.reasoningCapability != nil,
                limit: PublicModelLimit(context: m.contextWindow ?? 128_000, output: m.maxOutputTokens ?? 4096),
                toolCalling: m.toolCall,
                vision: m.vision,
                reasoningCapability: m.reasoningCapability
            )
        }

        let adapterName: String
        switch profile.protocolFamily {
        case "openai_responses": adapterName = "openai-responses"
        case "anthropic_messages": adapterName = "anthropic-messages"
        default: adapterName = "openai-compatible"
        }

        let apiKeyHeaderName: String?
        if BuiltinProviderCatalog.hasQuirk(providerID: providerID, quirk: "customApiKeyHeader") {
            apiKeyHeaderName = "api-key"
        } else if profile.protocolFamily == "anthropic_messages" {
            apiKeyHeaderName = "x-api-key"
        } else {
            apiKeyHeaderName = nil
        }

        currentProviders[providerID] = PublicProviderConfiguration(
            name: profile.displayName,
            adapter: adapterName,
            options: PublicProviderOptions(
                baseURL: profile.endpoint,
                apiKey: "{vault:\(ref.rawValue)}",
                apiKeyHeader: apiKeyHeaderName
            ),
            models: modelsDict
        )

        let newConfig = ProvidersConfiguration(
            schema: snapshot.providers.schema,
            version: snapshot.providers.version,
            model: snapshot.providers.model,
            providers: currentProviders
        )
        try await configStore.saveProviders(newConfig)

        let treeOutput = CLIFormatter.renderTree(
            header: "✓ Successfully authenticated \(profile.displayName)!",
            items: [
                ("Provider", providerID),
                ("Security", "Credential saved to encrypted AES-256-GCM vault (\(ref.rawValue))"),
                ("Configuration", "Active provider record written to ~/.lingxiagent/config.json"),
                ("Registered", "\(profile.models.count) models available")
            ]
        )

        let modelList = profile.models.map { "  • \(providerID)/\($0.id) (\($0.displayName))" }.joined(separator: "\n")

        return """
\(treeOutput)
Available models:
\(modelList)
"""
    }

    private static func logoutProvider(
        providerID: String,
        configStore: ConfigurationStore,
        credStore: CredentialStore
    ) async throws -> String {
        let keyRef = CredentialRef("provider-\(providerID)-key")
        let oauthRef = CredentialRef("provider-\(providerID)-oauth")
        try await credStore.removeSecret(for: keyRef)
        try await credStore.removeSecret(for: oauthRef)

        let snapshot = try await configStore.load()
        var currentProviders = snapshot.providers.providers
        currentProviders.removeValue(forKey: providerID)

        let newConfig = ProvidersConfiguration(
            schema: snapshot.providers.schema,
            version: snapshot.providers.version,
            model: snapshot.providers.model,
            providers: currentProviders
        )
        try await configStore.saveProviders(newConfig)

        return CLIFormatter.renderTree(
            header: "✓ Successfully logged out from '\(providerID)'.",
            items: [
                ("Security", "Credentials removed from secure vault"),
                ("Configuration", "Provider configuration unlinked from active profile")
            ]
        )
    }

    private static func renderMatrix() -> String {
        let matrix = ProviderCompatibilityMatrix.generateMatrix()
        let headers = ["Provider", "Protocol Family", "Auth", "Reasoning", "Tools", "Vision", "Cache"]
        var rows: [[String]] = []
        for p in matrix {
            let auth = p.authMethods.joined(separator: ", ")
            let reasoning = Set(p.models.map(\.reasoningMode)).sorted().joined(separator: ", ")
            let tools = p.models.contains(where: \.toolCall) ? "✅" : "❌"
            let vision = p.models.contains(where: \.vision) ? "✅" : "❌"
            let cache = p.models.contains(where: \.cache) ? "✅" : "❌"
            rows.append(["\(p.displayName) (\(p.providerID))", p.protocolFamily, auth, reasoning, tools, vision, cache])
        }
        let table = CLIFormatter.renderTable(headers: headers, rows: rows, borderStyle: .rounded)
        return """
=== Provider Compatibility Matrix ===
\(table)
"""
    }

    private static func renderModels(providerID: String?) -> String {
        let headers = ["Provider", "Model ID", "Display Name", "Context", "Output", "Features"]
        var rows: [[String]] = []

        let profiles: [BuiltinProviderCatalog.ProviderProfile]
        if let providerID {
            if let p = BuiltinProviderCatalog.profile(for: providerID) {
                profiles = [p]
            } else {
                return "Error: Unknown provider '\(providerID)'"
            }
        } else {
            profiles = BuiltinProviderCatalog.profiles
        }

        for p in profiles {
            for m in p.models {
                let ctx = m.contextWindow.map { "\($0 / 1000)k" } ?? "-"
                let out = m.maxOutputTokens.map { "\($0 / 1000)k" } ?? "-"
                var feats: [String] = []
                if m.reasoningCapability != nil { feats.append("🧠") }
                if m.toolCall { feats.append("🛠️") }
                if m.vision { feats.append("👁️") }
                if m.cache { feats.append("⚡") }
                let featStr = feats.isEmpty ? "-" : feats.joined(separator: " ")
                rows.append([p.id, m.id, m.displayName, ctx, out, featStr])
            }
        }

        let table = CLIFormatter.renderTable(headers: headers, rows: rows, borderStyle: .rounded)
        return """
=== Registered Models ===
\(table)
"""
    }

    private static func renderHelp() -> String {
        let commands = [
            ("auth list", "列出所有内置 Provider 及 OAuth Product 当前认证状态"),
            ("auth status [product]", "查看指定 Provider / OAuth 产品详情与模型规格"),
            ("auth login <product>", "进行 OAuth 授权登录或录入 API Key"),
            ("auth <product>", "login 命令快捷方式 (如: lingxiagent auth openai-codex)"),
            ("auth set <key> [val]", "将任意自定义凭据/Token安全写入加密保险箱"),
            ("auth import-env <name>", "从当前环境自动导入指定环境变量至加密保险箱"),
            ("auth logout <product>", "清除凭据并解绑 Provider 配置"),
            ("matrix", "展示所有 Provider 的协议、推理等级与特性兼容矩阵"),
            ("models [provider]", "展示模型上下文窗口、输出上限及特性标志"),
            ("help", "查看本帮助指南")
        ]
        let sections = [
            ("Commands", commands.map { "  lingxiagent \($0.0)  - \($0.1)" }),
            ("Examples", [
                "  lingxiagent auth list",
                "  lingxiagent auth openai-codex",
                "  lingxiagent auth login gemini-code-assist",
                "  lingxiagent auth set env:ALIBABA_CLOUD_ACCESS_KEY_ID",
                "  lingxiagent auth import-env ALIBABA_CLOUD_ACCESS_KEY_ID",
                "  lingxiagent auth status antigravity",
                "  lingxiagent auth login deepseek-api",
                "  lingxiagent matrix",
                "  lingxiagent models anthropic-api"
            ])
        ]
        return CLIFormatter.renderCard(
            title: "LingXiAgent CLI",
            sections: sections,
            borderStyle: .rounded
        )
    }
}
