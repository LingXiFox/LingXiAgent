import Foundation

public struct SensitivePathPolicy: Sendable {
    private let rootPath: String
    private let excludedRootPaths: [String]

    public init(root: URL, excluding excludedRoots: [URL] = []) {
        rootPath = Self.resolvedPath(root)
        excludedRootPaths = excludedRoots.map(Self.resolvedPath)
    }

    public func isSensitive(_ url: URL) -> Bool {
        let path = Self.resolvedPath(url)
        let fileURL = URL(fileURLWithPath: path)
        let filename = fileURL.lastPathComponent.lowercased()

        // 1. Explicit credentials and secret stores are always blocked.
        if isExplicitCredential(url: fileURL, path: path, filename: filename) {
            return true
        }

        // 2. Normal model configuration directories and model config files are NOT sensitive.
        if Self.isModelConfigurationPath(fileURL) {
            return false
        }

        // 3. Excluded root paths specified by caller (e.g. internal runtime data directories).
        if excludedRootPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }

        // 4. Check general workspace sensitive files.
        return checkGeneralSensitivePath(path: path)
    }

    /// Determines if a given URL is a legitimate model configuration directory or file.
    public static func isModelConfigurationPath(_ url: URL) -> Bool {
        let path = resolvedPath(url)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        let globalConfigDir = home + "/.lingxiagent"

        if path == globalConfigDir || path.hasPrefix(globalConfigDir + "/") {
            return true
        }

        let components = URL(fileURLWithPath: path).pathComponents
        if components.contains(".lingxiagent") {
            return true
        }

        return false
    }

    /// Determines if a given URL is an explicit credential file or system credential directory.
    private func isExplicitCredential(url: URL, path: String, filename: String) -> Bool {
        // 1. Explicit environment credential files (.env, .env.local, develop.env, etc.)
        if filename == ".env" || filename.hasPrefix(".env.") || filename.hasSuffix(".env") {
            return true
        }

        // 2. Vault stores and master encryption keys
        if filename == "credentials.vault" || filename == ".vault_key" || filename == ".master_key" {
            return true
        }

        // 3. Private keys and certificates
        if ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"].contains(filename)
            || filename.hasSuffix(".pem")
            || filename.hasSuffix(".key") {
            return true
        }

        // 4. System-level credential directories and package manager auth files
        let components = url.pathComponents.map { $0.lowercased() }
        if components.contains(where: { [".ssh", ".aws", ".gnupg", ".netrc", ".npmrc"].contains($0) }) {
            return true
        }

        // 5. Explicitly named credential files and directories
        if components.contains("private-secret") {
            return true
        }

        let credentialExactNames: Set<String> = [
            "credential.json", "credentials.json", "db-credentials.json",
            "service-secret.txt", "api-token.txt"
        ]
        if credentialExactNames.contains(filename) {
            return true
        }

        if filename.hasPrefix("credential.") || filename.hasPrefix("credentials.")
            || filename.contains("-credentials.") || filename.contains("_credentials.")
            || filename.contains("-secret.") || filename.contains("_secret.")
            || filename.contains("-token.") || filename.contains("_token.") {
            return true
        }

        return false
    }

    private func checkGeneralSensitivePath(path: String) -> Bool {
        let rootPrefix = rootPath + "/"
        let components = path == rootPath ? [] : path.hasPrefix(rootPrefix)
            ? String(path.dropFirst(rootPrefix.count)).split(separator: "/").map(String.init)
            : URL(fileURLWithPath: path).pathComponents

        return components.contains { component in
            let name = component.lowercased()
            return [".ssh", ".aws", ".gnupg", ".netrc", ".npmrc", "id_rsa"].contains(name)
                || name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env")
                || name.hasSuffix(".pem") || name.hasSuffix(".key")
                || name == "credential.json" || name == "credentials.json"
                || name == "db-credentials.json" || name == "service-secret.txt" || name == "api-token.txt"
                || name == "private-secret"
        }
    }

    private static func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

