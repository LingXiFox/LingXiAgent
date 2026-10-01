import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiPlatform
import LingXiModelSDK
import LingXiProtocol

public enum AuthCLI {
    public static func installSignalHandlers() {
        LingXiPlatform.terminal.installSignalHandlers()
    }

    @Sendable public static func readPrompt(prompt: String) -> String? {
        FileHandle.standardError.write(Data(prompt.utf8))
        return readLine(strippingNewline: true)
    }

    @Sendable public static func readSecretWithoutEcho(prompt: String) -> String? {
        LingXiPlatform.terminal.readSecretLine(prompt: prompt)
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
                return try await refreshModelCatalog(providerID: providerID)
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
                catalogModels: [],
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
        for product in BuiltinProviderCatalog.registryProducts where product.runtime.isRunnable {
            for record in await PublicModelCatalogClient.shared.publishedRecords(forProduct: product.id)
            where record.modelStatus.isSelectable {
                ids.insert("\(product.id)/\(record.id)")
            }
            let accounts = await AccountScopedCatalogCache.shared.listAccounts(productID: product.id)
            for account in accounts {
                guard let cached = await AccountScopedCatalogCache.shared.load(
                    productID: product.id, accountRef: account) else { continue }
                for model in cached.models
                where model.visibility.lowercased() != "hide" && model.visibility.lowercased() != "disabled" {
                    ids.insert("\(product.id)/\(model.id)")
                }
            }
        }
        return ids.sorted().joined(separator: "\n")
    }

    /// Lists models as the public catalog publishes them, or as the user's own
    /// account reported them.
    private static func renderModels(providerID: String?) async -> String {
        let headers = ["Product", "Model ID", "Display Name", "Status", "Context", "Output"]
        var rows: [[String]] = []

        let builtins = BuiltinProviderCatalog.registryProducts.filter { $0.runtime.isRunnable }
        if let providerID {
            if !builtins.contains(where: { $0.id == providerID }) {
                // Not a curated product: it may still be a published provider.
                guard let published = await PublicModelCatalogClient.shared.provider(providerID) else {
                    return "Error: Unknown provider '\(providerID)'"
                }
                rows = publishedRows(published)
                return rows.isEmpty ? "No models published for '\(providerID)'." : render(rows, headers)
            }
            rows = await modelRows(forProduct: providerID)
            return rows.isEmpty
                ? "No runnable models published for '\(providerID)'. Run 'lingxiagent auth login \(providerID)' to discover the models your account can reach."
                : render(rows, headers)
        }

        for product in builtins {
            rows.append(contentsOf: await modelRows(forProduct: product.id))
        }
        guard !rows.isEmpty else {
            return "No models available locally. Run 'lingxiagent auth login <product>' or configure custom providers in ~/.lingxiagent/providers.json."
        }
        return render(rows, headers)
    }

    /// One product's models: what the public catalog states, and when the
    /// catalog has nothing for it, what the user's account already reported.
    private static func modelRows(forProduct productID: String) async -> [[String]] {
        let published = await PublicModelCatalogClient.shared.publishedRecords(forProduct: productID)
        if !published.isEmpty {
            var rows: [[String]] = []
            for record in published {
                rows.append([
                    productID,
                    record.id,
                    record.displayName,
                    record.modelStatus.rawValue,
                    record.capabilities.contextWindow.map { "\($0 / 1000)k" } ?? "-",
                    record.capabilities.maxOutputTokens.map { "\($0 / 1000)k" } ?? "-"
                ])
            }
            return rows
        }
        var seen: Set<String> = []
        var rows: [[String]] = []
        for account in await AccountScopedCatalogCache.shared.listAccounts(productID: productID) {
            guard let cached = await AccountScopedCatalogCache.shared.load(productID: productID, accountRef: account) else { continue }
            for model in cached.models {
                guard model.visibility.lowercased() != "hide", model.visibility.lowercased() != "disabled",
                      !seen.contains(model.id) else { continue }
                seen.insert(model.id)
                rows.append([
                    productID,
                    model.id,
                    model.displayName,
                    "active",
                    model.contextWindow.map { "\($0 / 1000)k" } ?? "-",
                    model.maxOutputTokens.map { "\($0 / 1000)k" } ?? "-"
                ])
            }
        }
        return rows
    }

    private static func publishedRows(_ provider: CatalogProvider) -> [[String]] {
        provider.models.map { model in
            [
                provider.id,
                model.id,
                model.name,
                model.status.rawValue,
                model.contextWindow.map { "\($0 / 1000)k" } ?? "-",
                model.maxOutputTokens.map { "\($0 / 1000)k" } ?? "-"
            ]
        }
    }

    private static func render(_ rows: [[String]], _ headers: [String]) -> String {
        """
        === Registered Models ===
        \(CLIFormatter.renderTable(headers: headers, rows: rows, borderStyle: .rounded))
        """
    }

    /// Refreshes the public model catalog, optionally reporting one product's
    /// published models.
    ///
    /// Account-scoped discovery is deliberately not run here: it needs the
    /// user's credential and belongs to the login flow and the runtime, not to
    /// a catalog refresh.
    private static func refreshModelCatalog(providerID: String?) async throws -> String {
        guard let catalog = await PublicModelCatalogClient.shared.refresh(force: true) else {
            throw CoreError(code: .provider, message: "公共模型目录不可用：网络请求失败，且本地没有任何缓存副本")
        }
        let revision = catalog.revision
        guard let providerID else {
            return """
            ✓ 公共模型目录已同步
              revision: \(revision.catalogRevision)   schema: \(revision.schemaVersion)
              source: \(revision.source ?? "-")   hash: \(revision.catalogHash ?? "-")
              providers: \(revision.totalProviders)   models: \(revision.totalModels)
            """
        }
        guard catalog.provider(providerID) != nil
            || BuiltinProviderCatalog.registryProduct(id: providerID) != nil else {
            throw CoreError(code: .provider, message: "Unknown product '\(providerID)'")
        }
        let models = await PublicModelCatalogClient.shared.publishedRecords(forProduct: providerID)
        guard !models.isEmpty else {
            let discovery = BuiltinProviderCatalog.registryProduct(id: providerID)?.discoveryStrategy ?? "account"
            return """
            ✓ '\(providerID)' 在公共目录里没有模型列表。
              discovery: \(discovery) — 它的模型清单按你的账号实际可达范围解析。
            """
        }
        let headers = ["Model ID", "Display Name", "Status", "Context", "Metadata"]
        var rows: [[String]] = []
        for model in models {
            rows.append([
                model.id,
                model.displayName,
                model.modelStatus.rawValue,
                model.capabilities.contextWindow.map { "\($0 / 1000)k" } ?? "-",
                model.metadataIncomplete ? "incomplete" : "complete"
            ])
        }
        return """
        ✓ '\(providerID)' — 公共模型目录里的 \(models.count) 个模型
        \(CLIFormatter.renderTable(headers: headers, rows: rows, borderStyle: .rounded))
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
            ("models [provider]", "展示公共目录中的模型上下文窗口、输出上限与状态"),
            ("models sync [provider]", "刷新公共模型目录（models.lingxifox.cn/models.json）并更新本地缓存"),
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
