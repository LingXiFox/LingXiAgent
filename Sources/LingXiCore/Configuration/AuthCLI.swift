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
            if args.count > 1 && args[1] == "sync" {
                let providerID = args.count > 2 ? args[2] : nil
                return try await syncCloudCatalog(providerID: providerID)
            }
            // Machine-readable listing for shell completion: the model set is
            // discovered, so it cannot be baked into a completion script.
            if args.count > 1 && args[1] == "--ids" {
                return await renderModelIDs()
            }
            let providerID = args.count > 1 ? args[1] : nil
            return await renderModels(providerID: providerID)

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

            if isOAuth, let oauth = BuiltinProviderCatalog.metadata(for: providerID).oauth {
                fields.append(("OAuth Client", oauth.clientID))
                fields.append(("OAuth Scopes", oauth.scopes.joined(separator: ", ")))
                fields.append(("PKCE", oauth.usePKCE ? "Enabled (S256)" : "Disabled"))
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
                            if let regProd = BuiltinProviderCatalog.registryProduct(id: providerID),
                               let discovered = try? await AccountModelDiscovery.discoverAuthenticatedRemote(product: regProd, accessToken: tokenStr) {
                                _ = try? await AccountScopedCatalogCache.shared.save(
                                    productID: providerID,
                                    accountRef: accountRef,
                                    models: discovered,
                                    source: "Authenticated Remote Model Catalog"
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
        guard let oauthConfig = BuiltinProviderCatalog.metadata(for: productID).oauth,
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
        if let regProd = BuiltinProviderCatalog.registryProduct(id: productID) {
            do {
                discoveredModels = try await AccountModelDiscovery.discoverAuthenticatedRemote(
                    product: regProd,
                    accessToken: tokens.accessToken,
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
        }

        // Clean up legacy builtin entries from providers.json if previously written
        let snapshot = try await configStore.load()
        if snapshot.providers.providers[productID] != nil {
            var currentProviders = snapshot.providers.providers
            currentProviders.removeValue(forKey: productID)
            let newConfig = ProvidersConfiguration(
                schema: snapshot.providers.schema,
                version: snapshot.providers.version,
                model: snapshot.providers.model,
                providers: currentProviders
            )
            try await configStore.saveProviders(newConfig)
        }

        // The account's own listing decides availability; registry metadata
        // only enriches what is already reachable.
        let resolvedModels: [ProviderModelInfo] = {
            guard let product = BuiltinProviderCatalog.registryProduct(id: productID) else { return [] }
            return ModelAvailabilityResolver.resolve(
                product: product,
                registryModels: [],
                accountModels: discoveredModels,
                isConfigured: true
            ).models
        }()

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

        // Clean up legacy builtin entries from providers.json if previously written
        let snapshot = try await configStore.load()
        if snapshot.providers.providers[providerID] != nil {
            var currentProviders = snapshot.providers.providers
            currentProviders.removeValue(forKey: providerID)
            let newConfig = ProvidersConfiguration(
                schema: snapshot.providers.schema,
                version: snapshot.providers.version,
                model: snapshot.providers.model,
                providers: currentProviders
            )
            try await configStore.saveProviders(newConfig)
        }

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
        if snapshot.providers.providers[providerID] != nil {
            var currentProviders = snapshot.providers.providers
            currentProviders.removeValue(forKey: providerID)

            let newConfig = ProvidersConfiguration(
                schema: snapshot.providers.schema,
                version: snapshot.providers.version,
                model: snapshot.providers.model,
                providers: currentProviders
            )
            try await configStore.saveProviders(newConfig)
        }

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
        let headers = ["Product", "Protocol", "Auth", "Discovery", "Runtime", "Quirks"]
        var rows: [[String]] = []
        for p in matrix {
            let auth = p.authMethods.joined(separator: ", ")
            let discovery: String
            if let kind = p.discoveryKind {
                discovery = p.discoveryStrategy + " (" + kind + ")"
            } else {
                discovery = p.discoveryStrategy
            }
            let quirks = p.quirks.isEmpty ? "—" : p.quirks.joined(separator: ", ")
            rows.append(["\(p.displayName) (\(p.providerID))", p.protocolFamily, auth, discovery, p.runtimeSupport, quirks])
        }
        let table = CLIFormatter.renderTable(headers: headers, rows: rows, borderStyle: .rounded)
        return """
=== Provider Compatibility Matrix ===
\(table)
"""
    }

    /// Bare `product/model` references, one per line, for shell completion.
    ///
    /// Only selectable models are emitted, so completion never suggests a
    /// deprecated entry the user cannot actually choose.
    private static func renderModelIDs() async -> String {
        var ids: Set<String> = []
        if let catalog = await ModelRegistryClient.shared.catalog() {
            for m in catalog.models where m.modelStatus.isSelectable {
                ids.insert("\(m.productID)/\(m.id)")
            }
        }
        for product in BuiltinProviderCatalog.registryProducts {
            let accounts = await AccountScopedCatalogCache.shared.listAccounts(productID: product.id)
            for acc in accounts {
                if let record = await AccountScopedCatalogCache.shared.load(productID: product.id, accountRef: acc) {
                    for m in record.models where m.visibility.lowercased() != "hide" && m.visibility.lowercased() != "disabled" {
                        ids.insert("\(product.id)/\(m.id)")
                    }
                }
            }
        }
        return ids.sorted().joined(separator: "\n")
    }

    /// Lists models as published by the registry catalog or cached accounts.
    private static func renderModels(providerID: String?) async -> String {
        let catalog = await ModelRegistryClient.shared.catalog()
        let products: [RegistryProduct]
        if let catalog {
            if let providerID {
                guard let product = catalog.product(id: providerID) else {
                    return "Error: Unknown provider '\(providerID)'"
                }
                products = [product]
            } else {
                products = catalog.products.filter { $0.runtime.isRunnable }
            }
        } else {
            let builtins = BuiltinProviderCatalog.registryProducts.filter { $0.runtime.isRunnable }
            if let providerID {
                guard let product = builtins.first(where: { $0.id == providerID }) else {
                    return "Error: Unknown provider '\(providerID)'"
                }
                products = [product]
            } else {
                products = builtins
            }
        }

        let headers = ["Product", "Model ID", "Display Name", "Status", "Context", "Output"]
        var rows: [[String]] = []
        for product in products {
            let foundModels = catalog?.models(productID: product.id) ?? []
            for m in foundModels {
                let ctx = m.capabilities.contextWindow.map { "\($0 / 1000)k" } ?? "-"
                let out = m.capabilities.maxOutputTokens.map { "\($0 / 1000)k" } ?? "-"
                rows.append([product.id, m.id, m.displayName, m.status, ctx, out])
            }
            if foundModels.isEmpty {
                var seenModelIDs = Set<String>()
                let accounts = await AccountScopedCatalogCache.shared.listAccounts(productID: product.id)
                for acc in accounts {
                    if let record = await AccountScopedCatalogCache.shared.load(productID: product.id, accountRef: acc) {
                        for m in record.models {
                            guard m.visibility.lowercased() != "hide" && m.visibility.lowercased() != "disabled" else { continue }
                            if seenModelIDs.contains(m.id) { continue }
                            seenModelIDs.insert(m.id)
                            let ctx = m.contextWindow.map { "\($0 / 1000)k" } ?? "-"
                            let out = m.maxOutputTokens.map { "\($0 / 1000)k" } ?? "-"
                            rows.append([product.id, m.id, m.displayName, "active", ctx, out])
                        }
                    }
                }
            }
        }

        if rows.isEmpty {
            if catalog != nil {
                return "No runnable models found in catalog."
            } else {
                return "No models available locally. Run 'lingxiagent auth login <product>' or configure custom providers in ~/.lingxiagent/providers.json."
            }
        }

        let table = CLIFormatter.renderTable(headers: headers, rows: rows, borderStyle: .rounded)
        return """
=== Registered Models ===
\(table)
"""
    }

    /// Refreshes the unified registry catalog, optionally reporting one
    /// product's published models.
    ///
    /// Account-scoped discovery is deliberately not run here: it needs the
    /// user's credential and belongs to the login flow and the runtime, not to
    /// a catalog refresh.
    private static func syncCloudCatalog(providerID: String?) async throws -> String {
        let outcome = await ModelRegistryClient.shared.fetch(maxAge: 0)

        let catalog: RegistryCatalog
        switch outcome {
        case let .updated(fetched), let .notModified(fetched):
            catalog = fetched
        case let .stale(cached, reason):
            catalog = cached
            if providerID == nil {
                return """
                ⚠ Registry unreachable (\(reason))
                  using cached revision \(cached.metadata.catalogRevision)
                  products: \(cached.products.count)   models: \(cached.models.count)
                """
            }
        case let .unavailable(reason):
            throw CoreError(code: .provider, message: "Registry catalog unavailable: \(reason)")
        }

        guard let providerID else {
            return """
            ✓ Registry catalog synchronized
              revision: \(catalog.metadata.catalogRevision)
              products: \(catalog.products.count)   models: \(catalog.models.count)   providers: \(catalog.vendors.count)
            """
        }

        guard let product = catalog.product(id: providerID) else {
            throw CoreError(code: .provider, message: "Unknown product '\(providerID)'")
        }
        let models = catalog.models(productID: providerID)
        guard !models.isEmpty else {
            return """
            ✓ '\(providerID)' is in the catalog but publishes no models.
              discovery: \(product.discoveryStrategy) — its model list is resolved against your account.
            """
        }

        let headers = ["Model ID", "Display Name", "Status", "Context", "Metadata"]
        var rows: [[String]] = []
        for model in models {
            let context = model.capabilities.contextWindow.map { "\($0 / 1000)k" } ?? "-"
            rows.append([
                model.id,
                model.displayName,
                model.modelStatus.rawValue,
                context,
                model.metadataIncomplete ? "incomplete" : "complete"
            ])
        }
        let table = CLIFormatter.renderTable(headers: headers, rows: rows, borderStyle: .rounded)
        return """
        ✓ '\(providerID)' — \(models.count) models from the registry catalog
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
            ("models sync [provider]", "从云端权威端点拉取最新模型目录并更新本地缓存"),
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
                "  lingxiagent models openai-codex",
                "  lingxiagent models sync openai-codex"
            ])
        ]
        return CLIFormatter.renderCard(
            title: "LingXiAgent CLI",
            sections: sections,
            borderStyle: .rounded
        )
    }
}
