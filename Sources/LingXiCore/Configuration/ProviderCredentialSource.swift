import Foundation
import LingXiProtocol

/// The credential source a saved provider's `options.apiKey` may name.
///
/// Four forms are readable, and only two of them are writable by a product path:
///
/// - `{vault:REF}` — the durable source. `updateSecret` is the only writer, and it always produces
///   this form, which is why the other three below can only arrive through a hand-edited file.
/// - `{oauth:REF}` — a vault entry holding `OAuthTokens` rather than a bare key.
/// - `{env:NAME}` — a variable the *file* points at. Readable, and it stays that way for CLI and CI,
///   but it is not a durable source for a GUI: see ``ProviderCredentialOverride``.
/// - anything else — a value the file carries itself. Kept readable so an existing install does not
///   lose its endpoint mid-session; nothing writes it, because the decoder gate in
///   `PublicProviderOptions.init(from:)` refuses it on the way in.
enum ProviderCredentialSource: Equatable, Sendable {
    case vault(CredentialRef)
    case oauth(CredentialRef)
    case environment(String)
    case literal(String)
    case absent

    init(_ raw: String?) {
        guard let raw, !raw.isEmpty else { self = .absent; return }
        if raw.hasPrefix("{vault:"), raw.hasSuffix("}") {
            self = .vault(CredentialRef(String(raw.dropFirst(7).dropLast())))
        } else if raw.hasPrefix("{oauth:"), raw.hasSuffix("}") {
            self = .oauth(CredentialRef(String(raw.dropFirst(7).dropLast())))
        } else if raw.hasPrefix("{env:"), raw.hasSuffix("}") {
            self = .environment(String(raw.dropFirst(5).dropLast()))
        } else {
            self = .literal(raw)
        }
    }

    /// The reference to delete this source's secret by, or nil when the file itself holds the value.
    var credentialReference: CredentialRef? {
        switch self {
        case .vault(let ref), .oauth(let ref): return ref
        case .environment, .literal, .absent: return nil
        }
    }
}

/// The explicit environment override: the top of the credential resolution order.
///
/// `LINGXI_<PROVIDER_ID>_API_KEY` beats whatever `options.apiKey` names, so a developer or a CI job
/// can swap one account's key for a single run without touching the file — and without the file
/// having to point at an environment variable permanently, which is exactly the shape that breaks
/// under a Dock-launched GUI.
enum ProviderCredentialOverride {
    static func variableName(providerID: String) -> String {
        // Only [A-Z0-9_] survives as a variable name; anything else becomes a separator, so an id
        // like `openai-codex` and one like `openai codex` cannot collide into two spellings of one key.
        var name = "LINGXI_"
        for scalar in providerID.unicodeScalars {
            let value = scalar.value
            let isAlphanumeric = (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
            name.append(isAlphanumeric ? Character(scalar) : "_")
        }
        return name.uppercased() + "_API_KEY"
    }

    static func secret(providerID: String,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let value = environment[variableName(providerID: providerID)]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// The one-time repair of a hand-written `{env:NAME}` account.
///
/// `{env:NAME}` is not a durable credential source for a GUI: a Dock/Finder-launched process inherits
/// launchd's environment, and the login shell that exported the variable is not in that chain. Nothing
/// in the product writes the form — `updateSecret` only ever produces `{vault:…}` — so it arrives
/// exclusively through an edited file, and the repair is to move it into the vault the first time a run
/// can actually see the value.
///
/// This runs from the product entry points that read `providers.json` to boot something real, and from
/// nowhere else. `CoreHost.start()` deliberately does not call it: the test binary boots hundreds of
/// hosts, several pointed at the developer's own data root on purpose, and a startup write there
/// mutates a live profile from a test run.
public enum ProviderCredentialMigration {
    /// The backup that holds the file as it was before the first migration. Created once and never
    /// overwritten, so a second run cannot replace the only pre-change copy.
    public static let backupFilename = "providers.json.bak-pre-credential-migration"

    /// Returns one line per migrated account, naming the provider and both sides of the pointer.
    /// Never includes a credential value.
    @discardableResult
    public static func apply(configurationStore: ConfigurationStore,
                             credentialStore: any CredentialStore,
                             environment: [String: String] = ProcessInfo.processInfo.environment) async -> [String] {
        guard var snapshot = try? await configurationStore.load() else { return [] }
        var migrated: [String] = []
        for (providerID, provider) in snapshot.providers.providers {
            guard case .environment(let name) = ProviderCredentialSource(provider.options.apiKey),
                  let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            let ref = CredentialRef("provider-\(providerID)-key")
            do {
                try await credentialStore.setSecret(value, for: ref)
            } catch {
                continue  // The vault is unavailable; leave the pointer rather than lose the key.
            }
            var updated = provider
            updated.options.apiKey = "{vault:\(ref.rawValue)}"
            snapshot.providers.providers[providerID] = updated
            migrated.append("\(providerID): {env:\(name)} → {vault:\(ref.rawValue)}")
        }
        guard !migrated.isEmpty else { return [] }
        // An entry whose variable is absent is left byte-for-byte alone: rewriting that pointer would
        // destroy the only place the key is written down.
        let root = configurationStore.dataRoot
        let backup = root.appendingPathComponent(backupFilename)
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: root.appendingPathComponent("providers.json"), to: backup)
        }
        do {
            try await configurationStore.saveProviders(snapshot.providers)
        } catch {
            FileHandle.standardError.write(Data(
                "[CORE] credential migration rolled back, providers.json untouched: \(error)\n".utf8))
            return []
        }
        FileHandle.standardError.write(Data(
            "[CORE] credential migration (\(root.path)): \(migrated.joined(separator: "; "))\n".utf8))
        return migrated
    }
}
