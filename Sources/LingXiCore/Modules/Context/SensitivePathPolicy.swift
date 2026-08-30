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
        if excludedRootPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }

        let rootPrefix = rootPath + "/"
        let components = path == rootPath ? [] : path.hasPrefix(rootPrefix)
            ? String(path.dropFirst(rootPrefix.count)).split(separator: "/").map(String.init)
            : URL(fileURLWithPath: path).pathComponents
        return components.contains { component in
            let name = component.lowercased()
            return [".ssh", ".aws", ".gnupg", ".netrc", ".npmrc", "id_rsa"].contains(name)
                || name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env")
                || name.hasSuffix(".pem") || name.hasSuffix(".key")
                || name.contains("credential") || name.contains("secret") || name.contains("token")
        }
    }

    private static func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
