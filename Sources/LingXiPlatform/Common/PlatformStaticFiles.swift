import Foundation

/// A file that passed the traversal checks and may be sent to a client.
struct PlatformStaticAsset: Sendable {
    let url: URL
    let contentType: String
    let cacheControl: String
    let fileSize: Int
}

/// Maps file extensions to media types for static responses.
enum PlatformHTTPMediaType {
    /// Extensions whose bodies are text and therefore need an explicit charset.
    private static let textTypes: Set<String> = ["html", "htm", "css", "js", "mjs", "json",
                                                 "svg", "txt", "map", "md", "xml", "webmanifest"]

    private static let types: [String: String] = [
        "html": "text/html",
        "htm": "text/html",
        "css": "text/css",
        "js": "text/javascript",
        "mjs": "text/javascript",
        "json": "application/json",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "ico": "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "txt": "text/plain",
        "map": "application/json",
        "md": "text/markdown",
        "xml": "application/xml",
        "webmanifest": "application/manifest+json",
        "gif": "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "wasm": "application/wasm",
    ]

    static func forFile(named name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        guard let base = types[ext] else { return "application/octet-stream" }
        return textTypes.contains(ext) ? "\(base); charset=utf-8" : base
    }
}

/// Turns a request path into a file inside a mounted directory, or into nothing at all.
///
/// Every refusal answers 404 at the caller: a 403 carrying a reason would tell an attacker
/// which of their guesses about the layout on disk happened to be right.
enum PlatformStaticFileResolver {
    private static let maxComponentLength = 255

    /// `relativePath` arrives percent-decoded exactly once by `PlatformHTTPParser`; decoding
    /// it a second time here would turn a literal "%2e%2e" into ".." and re-open the escape.
    static func resolve(root: URL, relativePath: String, cacheMaxAgeSeconds: Int) -> PlatformStaticAsset? {
        guard !relativePath.contains("\\"), !relativePath.contains("\0") else { return nil }
        let rootURL = root.standardizedFileURL
        let rootPath = rootURL.path
        guard !rootPath.isEmpty else { return nil }
        // A mounted root that is itself a symlink resolves once, up front, so the comparison
        // below compares like with like.
        let realRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path

        var components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.isEmpty { components = ["index.html"] }

        var candidate = rootURL
        for component in components {
            // ".." is the escape attempt and "." is noise; a dot-prefixed name never reaches
            // the wire either, so a stray .env inside a web root stays private.
            guard !component.isEmpty, component != "..", component != ".", !component.hasPrefix("."),
                  component.utf8.count <= maxComponentLength, !component.contains("\0") else { return nil }
            candidate = candidate.appendingPathComponent(component)
        }
        let standardized = candidate.standardizedFileURL
        guard isInside(standardized.path, rootPath: rootPath) else { return nil }

        var file = standardized
        if !isRegularFile(file) {
            // Only a directory answers with its index.html, and the child is re-checked.
            guard isDirectory(file) else { return nil }
            file = file.appendingPathComponent("index.html").standardizedFileURL
            guard isInside(file.path, rootPath: rootPath), isRegularFile(file) else { return nil }
        }

        let realPath = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard isInside(realPath, rootPath: realRoot), let size = regularFileSize(realPath) else { return nil }

        let name = file.lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        // HTML/CSS/JS are the app's own un-fingerprinted sources: `serve --assets` points at a
        // tree that changes under a running instance, and a long max-age makes a reload keep
        // executing yesterday's script. Fingerprinted binaries below stay cacheable.
        let cacheControl = ["html", "htm", "js", "mjs", "css"].contains(ext)
            ? "no-cache"
            : "public, max-age=\(max(0, cacheMaxAgeSeconds))"
        return PlatformStaticAsset(url: URL(fileURLWithPath: realPath),
                                   contentType: PlatformHTTPMediaType.forFile(named: name),
                                   cacheControl: cacheControl,
                                   fileSize: size)
    }

    private static func isInside(_ path: String, rootPath: String) -> Bool {
        if path == rootPath { return true }
        let root = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return path.hasPrefix(root + "/")
    }

    private static func attributeType(of url: URL) -> FileAttributeType? {
        let values = try? FileManager.default.attributesOfItem(atPath: url.path)
        return values?[.type] as? FileAttributeType
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        attributeType(of: url) == .typeRegular
    }

    private static func isDirectory(_ url: URL) -> Bool {
        attributeType(of: url) == .typeDirectory
    }

    /// A FIFO would block the connection thread forever and a device node is never an asset,
    /// so only regular files pass.
    private static func regularFileSize(_ path: String) -> Int? {
        let values = try? FileManager.default.attributesOfItem(atPath: path)
        guard (values?[.type] as? FileAttributeType) == .typeRegular else { return nil }
        // `.size` is an NSNumber on the ObjC runtimes and a plain Int where Foundation
        // boxes it natively; reading only one of the two 404s every asset on that platform.
        if let number = values?[.size] as? NSNumber { return number.intValue }
        return values?[.size] as? Int
    }
}
