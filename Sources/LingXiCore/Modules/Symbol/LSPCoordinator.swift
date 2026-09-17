import Foundation
import LingXiProtocol
import LingXiPlatform

/// 支持的编程语言及其 LSP 语言服务器配置。
public struct LSPLanguageConfig: Sendable {
    public let languageID: String
    public let extensions: Set<String>
    public let binaryNames: [String]
    public let launchArguments: [String]
    public let customSearchPaths: [String]

    public init(
        languageID: String,
        extensions: Set<String>,
        binaryNames: [String],
        launchArguments: [String] = [],
        customSearchPaths: [String] = []
    ) {
        self.languageID = languageID
        self.extensions = extensions
        self.binaryNames = binaryNames
        self.launchArguments = launchArguments
        self.customSearchPaths = customSearchPaths
    }

    /// 预置的主流编程语言支持矩阵
    public static var builtinConfigurations: [LSPLanguageConfig] {
        var swiftCustomPaths: [String] = []
        #if os(macOS)
        let env = ProcessInfo.processInfo.environment
        if let devDir = env["DEVELOPER_DIR"] {
            swiftCustomPaths.append("\(devDir)/Toolchains/XcodeDefault.xctoolchain/usr/bin")
        }
        swiftCustomPaths.append(contentsOf: [
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin",
            "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin",
            "/usr/bin",
            "/usr/local/bin"
        ])
        #else
        swiftCustomPaths.append(contentsOf: [
            "/usr/bin",
            "/usr/local/bin",
            "/usr/lib/swift/bin"
        ])
        #endif

        return [
            // 1. Swift
            LSPLanguageConfig(
                languageID: "swift",
                extensions: ["swift"],
                binaryNames: ["sourcekit-lsp"],
                launchArguments: [],
                customSearchPaths: swiftCustomPaths
            ),
            // 2. Python
            LSPLanguageConfig(
                languageID: "python",
                extensions: ["py", "pyi"],
                binaryNames: ["pyright-langserver", "pyright", "basedpyright-langserver", "pylsp"],
                launchArguments: ["--stdio"]
            ),
            // 3. TypeScript / JavaScript
            LSPLanguageConfig(
                languageID: "typescript",
                extensions: ["ts", "tsx", "js", "jsx", "mjs", "cjs"],
                binaryNames: ["vtsls", "typescript-language-server"],
                launchArguments: ["--stdio"]
            ),
            // 4. Rust
            LSPLanguageConfig(
                languageID: "rust",
                extensions: ["rs"],
                binaryNames: ["rust-analyzer"],
                launchArguments: []
            ),
            // 5. Go
            LSPLanguageConfig(
                languageID: "go",
                extensions: ["go"],
                binaryNames: ["gopls"],
                launchArguments: []
            ),
            // 6. C / C++
            LSPLanguageConfig(
                languageID: "cpp",
                extensions: ["c", "cpp", "cc", "cxx", "h", "hpp", "hh"],
                binaryNames: ["clangd"],
                launchArguments: []
            )
        ]
    }
}

/// 通用进程级 LSP Transport（基于四层 IPC 流水线）。
public final class GenericProcessLSPTransport: @unchecked Sendable, LSPTransport {
    public let executablePath: String
    public let arguments: [String]
    private let peer: JSONRPCPeer

    public init(executablePath: String, arguments: [String] = []) {
        self.executablePath = executablePath
        self.arguments = arguments
        let proc = ManagedProcess(
            executablePath: executablePath,
            arguments: arguments,
            environment: EnvironmentSanitizer.sanitized()
        )
        let transport = StdioTransport(managedProcess: proc)
        let framer = LSPContentLengthFramer()
        self.peer = JSONRPCPeer(transport: transport, framer: framer)
    }

    public func start() throws {
        try peer.start()
    }

    public func stop() {
        peer.stop()
    }

    public func request(id: Int, method: String, parameters: Data) throws -> Data {
        do {
            return try peer.requestSync(id: id, method: method, parameters: parameters)
        } catch {
            throw LSPClientError.crashed
        }
    }

    public func notify(method: String, parameters: Data) throws {
        do {
            try peer.notify(method: method, parameters: parameters)
        } catch {
            throw LSPClientError.crashed
        }
    }
}

/// 多语言 LSP 编排器（与后台命令系统协同，管理多语言 LSP 服务器生命周期与语义路由）。
public actor LSPCoordinator {
    private let workspaceURL: URL
    private var clientsByLanguage: [String: LSPClient] = [:]
    private var configsByLanguage: [String: LSPLanguageConfig] = [:]
    private var extToLanguage: [String: String] = [:]
    private var backgroundManager: BackgroundCommandManager?

    public init(workspaceURL: URL, backgroundManager: BackgroundCommandManager? = nil) {
        self.workspaceURL = workspaceURL
        self.backgroundManager = backgroundManager

        for config in LSPLanguageConfig.builtinConfigurations {
            self.configsByLanguage[config.languageID] = config
            for ext in config.extensions {
                self.extToLanguage[ext.lowercased()] = config.languageID
            }
        }
    }

    /// 注册额外的自定义语言服务器配置
    public func registerLanguage(_ config: LSPLanguageConfig) {
        self.configsByLanguage[config.languageID] = config
        for ext in config.extensions {
            self.extToLanguage[ext.lowercased()] = config.languageID
        }
    }

    /// 获取或按需拉起对应语言的 LSPClient
    public func getOrStartClient(for url: URL) async -> (client: LSPClient, languageID: String)? {
        let ext = url.pathExtension.lowercased()
        guard let langID = extToLanguage[ext], let config = configsByLanguage[langID] else {
            return nil
        }

        if let existing = clientsByLanguage[langID] {
            await existing.start(workspace: workspaceURL)
            return (existing, langID)
        }

        // 探测二进制文件
        guard let binPath = resolveBinary(for: config) else {
            return nil
        }

        let transport = GenericProcessLSPTransport(
            executablePath: binPath,
            arguments: config.launchArguments
        )
        let client = LSPClient(transport: transport)
        await client.start(workspace: workspaceURL)
        clientsByLanguage[langID] = client
        return (client, langID)
    }

    /// 查询所有已激活的 LSP 状态
    public func statusAll() async -> [String: LSPClientState] {
        var statuses: [String: LSPClientState] = [:]
        for (lang, client) in clientsByLanguage {
            statuses[lang] = await client.lifecycle()
        }
        return statuses
    }

    /// 关闭所有常驻的 LSP 服务端进程
    public func shutdownAll() async {
        for client in clientsByLanguage.values {
            await client.stop()
        }
        clientsByLanguage.removeAll()
    }

    // MARK: - 语义核心能力网关 (6大能力)

    /// 1. Definition (跳转定义)
    public func definition(file: URL, line: Int, character: Int) async -> [LSPLocation]? {
        guard let (client, _) = await getOrStartClient(for: file) else { return nil }
        let params: [String: Any] = [
            "textDocument": ["uri": file.absoluteString],
            "position": ["line": max(0, line - 1), "character": max(0, character)]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
        return await client.request("textDocument/definition", parameters: data, as: [LSPLocation].self)
    }

    /// 2. References (符号引用查找)
    public func references(file: URL, line: Int, character: Int) async -> [LSPLocation]? {
        guard let (client, _) = await getOrStartClient(for: file) else { return nil }
        let params: [String: Any] = [
            "textDocument": ["uri": file.absoluteString],
            "position": ["line": max(0, line - 1), "character": max(0, character)],
            "context": ["includeDeclaration": true]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
        return await client.request("textDocument/references", parameters: data, as: [LSPLocation].self)
    }

    /// 3. Document Symbols (文档大纲符号)
    public func documentSymbols(file: URL) async -> [LSPDocumentSymbol]? {
        guard let (client, _) = await getOrStartClient(for: file) else { return nil }
        let params: [String: Any] = ["textDocument": ["uri": file.absoluteString]]
        let data = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
        return await client.request("textDocument/documentSymbol", parameters: data, as: [LSPDocumentSymbol].self)
    }

    /// 4. Workspace Symbols (工作区全域符号搜索)
    public func workspaceSymbols(query: String) async -> [LSPWorkspaceSymbol]? {
        for (_, client) in clientsByLanguage {
            let params: [String: Any] = ["query": query]
            let data = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
            if let symbols = await client.request("workspace/symbol", parameters: data, as: [LSPWorkspaceSymbol].self), !symbols.isEmpty {
                return symbols
            }
        }
        return nil
    }

    /// 5. Diagnostics (静态代码诊断/报错)
    public func diagnostics(file: URL) async -> [LSPDiagnostic]? {
        guard let (client, _) = await getOrStartClient(for: file) else { return nil }
        let params: [String: Any] = ["textDocument": ["uri": file.absoluteString]]
        let data = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
        return await client.request("textDocument/diagnostic", parameters: data, as: [LSPDiagnostic].self)
    }

    /// 6. Hover (悬停文档与类型签名)
    public func hover(file: URL, line: Int, character: Int) async -> LSPHoverResult? {
        guard let (client, _) = await getOrStartClient(for: file) else { return nil }
        let params: [String: Any] = [
            "textDocument": ["uri": file.absoluteString],
            "position": ["line": max(0, line - 1), "character": max(0, character)]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
        return await client.request("textDocument/hover", parameters: data, as: LSPHoverResult.self)
    }

    /// 7. Completion (代码智能补全建议)
    public func completion(file: URL, line: Int, character: Int) async -> [LSPCompletionItem]? {
        guard let (client, _) = await getOrStartClient(for: file) else { return nil }
        let params: [String: Any] = [
            "textDocument": ["uri": file.absoluteString],
            "position": ["line": max(0, line - 1), "character": max(0, character)]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
        if let list = await client.request("textDocument/completion", parameters: data, as: LSPCompletionList.self) {
            return list.items
        }
        return await client.request("textDocument/completion", parameters: data, as: [LSPCompletionItem].self)
    }

    /// 同步文件最新内容给对应语言服务器
    public func syncDocument(file: URL, text: String) async {
        guard let (client, langID) = await getOrStartClient(for: file) else { return }
        await client.openDocument(file, language: langID, text: text)
    }

    // MARK: - Private Helper

    private func resolveBinary(for config: LSPLanguageConfig) -> String? {
        for name in config.binaryNames {
            if let resolved = LingXiPlatform.process.resolveExecutable(named: name, customSearchPaths: config.customSearchPaths) {
                return resolved
            }
        }
        return nil
    }
}
