import Foundation
import LingXiProtocol

public struct LSPPosition: Codable, Sendable, Equatable { public let line: Int; public let character: Int; public init(line: Int, character: Int) { self.line = line; self.character = character } }
public struct LSPRange: Codable, Sendable, Equatable { public let start: LSPPosition; public let end: LSPPosition; public init(start: LSPPosition, end: LSPPosition) { self.start = start; self.end = end } }
public struct LSPLocation: Codable, Sendable, Equatable { public let uri: String; public let range: LSPRange; public init(uri: String, range: LSPRange) { self.uri = uri; self.range = range } }
public struct LSPDiagnostic: Codable, Sendable, Equatable { public let range: LSPRange; public let message: String; public let severity: Int? }
public struct LSPWorkspaceSymbol: Codable, Sendable, Equatable { public let name: String; public let kind: Int; public let location: LSPLocation }
public struct LSPDocumentSymbol: Codable, Sendable, Equatable { public let name: String; public let kind: Int; public let range: LSPRange; public let selectionRange: LSPRange; public let children: [LSPDocumentSymbol]? }
public enum LSPClientState: String, Sendable, Equatable { case idle, starting, ready, degraded, stopped }
public enum LSPClientError: Error, Sendable, Equatable { case unavailable, crashed, invalidResponse }

/// Raw JSON-RPC boundary keeps the LSP process replaceable and makes server failure non-fatal.
public protocol LSPTransport: Sendable {
    func start() throws
    func stop()
    func request(id: Int, method: String, parameters: Data) throws -> Data
    func notify(method: String, parameters: Data) throws
}

public final class SourceKitLSPTransport: @unchecked Sendable, LSPTransport {
    private let executable: String
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    public init?(executable: String? = nil) {
        guard let executable = executable ?? Self.discoverExecutable() else { return nil }
        self.executable = executable
    }

    public func start() throws {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = []
        process.environment = EnvironmentSanitizer.sanitized()
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        self.process = process
        self.input = input.fileHandleForWriting
        self.output = output.fileHandleForReading
    }

    public func stop() {
        process?.terminate()
        input?.closeFile()
        output?.closeFile()
        process = nil; input = nil; output = nil
    }

    public func request(id: Int, method: String, parameters: Data) throws -> Data {
        try send(id: id, method: method, parameters: parameters)
        while let message = try readMessage() {
            guard let object = try JSONSerialization.jsonObject(with: message) as? [String: Any] else { continue }
            guard (object["id"] as? NSNumber)?.intValue == id else { continue }
            if object["error"] != nil { throw LSPClientError.crashed }
            guard let result = object["result"] else { return Data("null".utf8) }
            return try JSONSerialization.data(withJSONObject: result)
        }
        throw LSPClientError.crashed
    }

    public func notify(method: String, parameters: Data) throws { try send(id: nil, method: method, parameters: parameters) }

    private func send(id: Int?, method: String, parameters: Data) throws {
        guard let process, process.isRunning, let input else { throw LSPClientError.crashed }
        let parameters = try JSONSerialization.jsonObject(with: parameters)
        var request: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": parameters]
        if let id { request["id"] = id }
        let body = try JSONSerialization.data(withJSONObject: request)
        input.write(Data("Content-Length: \(body.count)\r\n\r\n".utf8))
        input.write(body)
    }

    private func readMessage() throws -> Data? {
        guard let output else { throw LSPClientError.crashed }
        var header = Data()
        while header.suffix(4) != Data("\r\n\r\n".utf8) {
            let byte = output.readData(ofLength: 1)
            guard !byte.isEmpty else { return nil }
            header.append(byte)
            if header.count > 16 * 1024 { throw LSPClientError.invalidResponse }
        }
        let text = String(decoding: header, as: UTF8.self)
        guard let value = text.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }), let length = Int(value.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) else { throw LSPClientError.invalidResponse }
        let body = output.readData(ofLength: length)
        guard body.count == length else { throw LSPClientError.crashed }
        return body
    }

    private static func discoverExecutable() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [environment["LINGXI_SOURCEKIT_LSP"], environment["DEVELOPER_DIR"].map { "\($0)/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp" }, "/usr/bin/sourcekit-lsp", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp", "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"].compactMap { $0 }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }
}

public actor LSPClient {
    private let transport: (any LSPTransport)?
    private var state: LSPClientState = .idle
    private var nextID = 1
    private var workspace: URL?
    private var openVersions: [URL: Int] = [:]

    public init(transport: (any LSPTransport)? = SourceKitLSPTransport()) { self.transport = transport }
    public func lifecycle() -> LSPClientState { state }

    public func start(workspace: URL) async {
        guard state != .ready || self.workspace != workspace else { return }
        self.workspace = workspace
        guard let transport else { state = .degraded; return }
        state = .starting
        do {
            try transport.start()
            let parameters = try JSONSerialization.data(withJSONObject: ["processId": NSNull(), "rootUri": workspace.absoluteString, "capabilities": [String: String]()])
            _ = try requestSync("initialize", parameters) as JSONValue
            try transport.notify(method: "initialized", parameters: Data("{}".utf8))
            state = .ready
        } catch { transport.stop(); state = .degraded }
    }

    public func stop() { transport?.stop(); openVersions.removeAll(); state = .stopped }

    public func request<Result: Decodable>(_ method: String, parameters: Data, as type: Result.Type) async -> Result? {
        guard let workspace else { state = .degraded; return nil }
        await start(workspace: workspace)
        guard state == .ready else { return nil }
        do { return try requestSync(method, parameters) } catch { transport?.stop(); state = .degraded; return nil }
    }

    public func openDocument(_ url: URL, language: String, text: String) async {
        guard let workspace else { return }
        await start(workspace: workspace)
        guard state == .ready, let transport else { return }
        do {
            let version = (openVersions[url] ?? 0) + 1
            let method = openVersions[url] == nil ? "textDocument/didOpen" : "textDocument/didChange"
            let parameters: [String: Any] = method == "textDocument/didOpen"
                ? ["textDocument": ["uri": url.absoluteString, "languageId": language, "version": version, "text": text]]
                : ["textDocument": ["uri": url.absoluteString, "version": version], "contentChanges": [["text": text]]]
            try transport.notify(method: method, parameters: JSONSerialization.data(withJSONObject: parameters))
            openVersions[url] = version
        } catch { transport.stop(); state = .degraded }
    }

    private func requestSync<Result: Decodable>(_ method: String, _ parameters: Data) throws -> Result {
        guard let transport else { throw LSPClientError.unavailable }
        defer { nextID += 1 }
        return try JSONDecoder().decode(Result.self, from: transport.request(id: nextID, method: method, parameters: parameters))
    }
}

public struct CodeIntelligenceLocation: Codable, Sendable, Equatable { public let path: String; public let line: Int; public let character: Int; public let source: String }
public struct CodeIntelligenceSymbol: Codable, Sendable, Equatable { public let name: String; public let kind: String; public let path: String; public let line: Int; public let source: String }
public struct CodeIntelligenceContext: Codable, Sendable, Equatable { public let paths: [String]; public let characters: Int; public let bounded: Bool }

/// LSP is preferred for semantic answers. The existing project index remains the deterministic fallback.
public actor CodeIntelligence {
    private let workspace: WorkspaceRoot
    private let scanner: ProjectScanner
    private let pager: ContextPager
    private let lsp: LSPClient

    public init(workspace: WorkspaceRoot, scanner: ProjectScanner, pager: ContextPager, lsp: LSPClient = LSPClient()) { self.workspace = workspace; self.scanner = scanner; self.pager = pager; self.lsp = lsp }

    public func status() async -> LSPClientState { await lsp.lifecycle() }
    public func refresh() async { _ = try? await pager.rebuildStaleFiles(using: scanner) }

    public func symbols(_ query: String) async -> [CodeIntelligenceSymbol] {
        await refresh()
        await prepareLSP()
        if let symbols: [LSPWorkspaceSymbol] = await lsp.request("workspace/symbol", parameters: Self.json(["query": query]), as: [LSPWorkspaceSymbol].self) {
            return symbols.prefix(64).map { symbol in CodeIntelligenceSymbol(name: symbol.name, kind: String(symbol.kind), path: Self.path(symbol.location.uri, workspace: workspace), line: symbol.location.range.start.line + 1, source: "lsp") }
        }
        return (await pager.symbolLookup(projectRoot: workspace.url, query: query, mode: "prefix")).prefix(64).map { CodeIntelligenceSymbol(name: $0.qualifiedName, kind: $0.kind.rawValue, path: $0.path, line: $0.line, source: "index") }
    }

    public func definition(path: String, line: Int, character: Int) async -> [CodeIntelligenceLocation] { await locations(method: "textDocument/definition", path: path, line: line, character: character) }
    public func references(path: String, line: Int, character: Int) async -> [CodeIntelligenceLocation] { await locations(method: "textDocument/references", path: path, line: line, character: character) }

    public func documentSymbols(path: String) async -> [CodeIntelligenceSymbol] {
        await refresh()
        await prepareLSP()
        let file = try? workspace.resolve(path)
        if let file, let text = try? String(contentsOf: file, encoding: .utf8) { await lsp.openDocument(file, language: language(for: file), text: text) }
        if let lspSymbols: [LSPDocumentSymbol] = await lsp.request("textDocument/documentSymbol", parameters: Self.json(["textDocument": ["uri": file?.absoluteString ?? ""]]), as: [LSPDocumentSymbol].self) {
            return lspSymbols.flatMap(Self.flatten).map { CodeIntelligenceSymbol(name: $0.name, kind: String($0.kind), path: path, line: $0.selectionRange.start.line + 1, source: "lsp") }
        }
        return (await pager.symbolLookup(projectRoot: workspace.url, query: "", mode: "prefix")).filter { $0.path == path }.map { CodeIntelligenceSymbol(name: $0.qualifiedName, kind: $0.kind.rawValue, path: $0.path, line: $0.line, source: "index") }
    }

    public func diagnostics(path: String) async -> [LSPDiagnostic] {
        await refresh()
        await prepareLSP()
        guard let file = try? workspace.resolve(path), let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        await lsp.openDocument(file, language: language(for: file), text: text)
        return await lsp.request("textDocument/diagnostic", parameters: Self.json(["textDocument": ["uri": file.absoluteString]]), as: [LSPDiagnostic].self) ?? []
    }

    public func context(_ query: String, maximumCharacters: Int) async -> CodeIntelligenceContext {
        await refresh()
        let result = await pager.query(projectRoot: workspace.url, query: query, limit: 20)
        var used = 0, paths: [String] = []
        for page in result.pages where used + page.characterCount <= max(0, maximumCharacters) { used += page.characterCount; paths.append(page.path) }
        return CodeIntelligenceContext(paths: paths, characters: used, bounded: result.characterCount > used)
    }

    public func repoMap() async -> String {
        await refresh()
        let scan = try? scanner.scanManifest()
        let files = scan?.files ?? []
        let groups = Dictionary(grouping: files, by: { URL(fileURLWithPath: $0.path).pathExtension.lowercased().isEmpty ? "other" : URL(fileURLWithPath: $0.path).pathExtension.lowercased() })
        let summary = groups.keys.sorted().map { "\($0): \(groups[$0]?.count ?? 0)" }.joined(separator: ", ")
        return "files=\(files.count); languages=\(summary); roots=\(Set(files.map { $0.path.split(separator: "/").first.map(String.init) ?? "." }).sorted().prefix(16).joined(separator: ","))"
    }

    private func locations(method: String, path: String, line: Int, character: Int) async -> [CodeIntelligenceLocation] {
        await refresh()
        await prepareLSP()
        guard let file = try? workspace.resolve(path), let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        await lsp.openDocument(file, language: language(for: file), text: text)
        let parameters: [String: Any] = method == "textDocument/references"
            ? ["textDocument": ["uri": file.absoluteString], "position": ["line": max(0, line - 1), "character": max(0, character)], "context": ["includeDeclaration": true]]
            : ["textDocument": ["uri": file.absoluteString], "position": ["line": max(0, line - 1), "character": max(0, character)]]
        if let result: [LSPLocation] = await lsp.request(method, parameters: Self.json(parameters), as: [LSPLocation].self) {
            return result.prefix(128).map { CodeIntelligenceLocation(path: Self.path($0.uri, workspace: workspace), line: $0.range.start.line + 1, character: $0.range.start.character, source: "lsp") }
        }
        let token = Self.token(in: text, line: line, character: character)
        let symbols = await pager.symbolLookup(projectRoot: workspace.url, query: token, mode: "exact")
        if method == "textDocument/definition" { return symbols.map { CodeIntelligenceLocation(path: $0.path, line: $0.line, character: 0, source: "index") } }
        return await withTaskGroup(of: [CodeIntelligenceLocation].self) { group in
            for symbol in symbols { group.addTask { [pager, workspace] in
                await pager.references(projectRoot: workspace.url, symbolID: symbol.id).map { CodeIntelligenceLocation(path: $0.sourcePath, line: $0.sourceLine, character: 0, source: "index") }
            } }
            var locations: [CodeIntelligenceLocation] = []
            for await matches in group { locations += matches }
            return locations.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
        }
    }

    private func language(for url: URL) -> String { url.pathExtension.lowercased() == "swift" ? "swift" : "plaintext" }
    private func prepareLSP() async { await lsp.start(workspace: workspace.url) }
    private static func path(_ uri: String, workspace: WorkspaceRoot) -> String {
        let url = URL(string: uri) ?? URL(fileURLWithPath: uri)
        let root = workspace.url.path.hasSuffix("/") ? workspace.url.path : workspace.url.path + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
    }
    private static func token(in text: String, line: Int, character: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard line > 0, line <= lines.count else { return "" }
        let characters = Array(lines[line - 1]); guard !characters.isEmpty else { return "" }
        let index = min(max(0, character), characters.count - 1)
        var start = index, end = index
        while start > 0 && (characters[start - 1].isLetter || characters[start - 1].isNumber || characters[start - 1] == "_") { start -= 1 }
        while end + 1 < characters.count && (characters[end + 1].isLetter || characters[end + 1].isNumber || characters[end + 1] == "_") { end += 1 }
        return String(characters[start...end])
    }
    private static func flatten(_ symbol: LSPDocumentSymbol) -> [LSPDocumentSymbol] { [symbol] + (symbol.children ?? []).flatMap(flatten) }
    private static func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8) }
}
