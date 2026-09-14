import Foundation

/// 插件端 STDIO / IPC 驱动器。
public actor PluginDriver {
    private let plugin: any LingXiPlugin
    private var context: PluginContext?
    private var isActivated = false

    public init(plugin: any LingXiPlugin) {
        self.plugin = plugin
    }

    /// 执行单次 IPC 请求分发（供 STDIO 循环或进程内直接驱动使用）
    public func handleRequest(_ request: PluginIPCRequest) async -> PluginIPCResponse {
        do {
            switch request.method {
            case "plugin.initialize":
                let ctx = try await getOrActivateContext()
                let tools = ctx.allTools.map {
                    PluginToolDescriptor(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
                }
                let commands = ctx.allCommands.map {
                    PluginCommandDescriptor(name: $0.name, aliases: $0.aliases, description: $0.description, category: $0.category, argumentHint: $0.argumentHint)
                }
                let result = PluginHandshakeResult(manifest: plugin.manifest, tools: tools, commands: commands)
                let data = try JSONEncoder().encode(result)
                return PluginIPCResponse(id: request.id, result: data)

            case "tool.execute":
                guard let paramsData = request.params else {
                    return PluginIPCResponse(id: request.id, error: "Missing tool.execute parameters")
                }
                let params = try JSONDecoder().decode(PluginToolCallParams.self, from: paramsData)
                let ctx = try await getOrActivateContext()
                guard let tool = ctx.tool(named: params.toolName) else {
                    return PluginIPCResponse(id: request.id, error: "Tool '\(params.toolName)' not found in plugin")
                }
                let toolExecCtx = ToolExecutionContext(
                    sessionID: params.sessionID,
                    toolCallID: params.toolCallID,
                    logger: ctx.logger
                )
                let output = try await tool.execute(arguments: params.arguments, context: toolExecCtx)
                let outputData = try JSONEncoder().encode(output)
                return PluginIPCResponse(id: request.id, result: outputData)

            case "command.execute":
                guard let paramsData = request.params else {
                    return PluginIPCResponse(id: request.id, error: "Missing command.execute parameters")
                }
                let params = try JSONDecoder().decode(PluginCommandCallParams.self, from: paramsData)
                let ctx = try await getOrActivateContext()
                guard let cmd = ctx.command(named: params.commandName) else {
                    return PluginIPCResponse(id: request.id, error: "Command '\(params.commandName)' not found in plugin")
                }
                let cmdExecCtx = CommandExecutionContext(
                    sessionID: params.sessionID,
                    info: ctx.info,
                    logger: ctx.logger
                )
                let cmdRes = try await cmd.execute(args: params.arguments, context: cmdExecCtx)
                let callResult: PluginCommandCallResult
                switch cmdRes {
                case let .message(msg, presentation, title):
                    callResult = PluginCommandCallResult(isPrompt: false, text: msg, presentation: presentation.rawValue, title: title)
                case let .prompt(p):
                    callResult = PluginCommandCallResult(isPrompt: true, text: p, presentation: PluginPresentationStyle.inline.rawValue, title: nil)
                }
                let resData = try JSONEncoder().encode(callResult)
                return PluginIPCResponse(id: request.id, result: resData)

            case "hook.emit":
                guard let paramsData = request.params else {
                    return PluginIPCResponse(id: request.id, error: "Missing hook.emit payload")
                }
                let payload = try JSONDecoder().decode(PluginHookPayload.self, from: paramsData)
                let ctx = try await getOrActivateContext()
                await ctx.executeHooks(payload)
                return PluginIPCResponse(id: request.id, result: Data())

            default:
                return PluginIPCResponse(id: request.id, error: "Unknown IPC method: \(request.method)")
            }
        } catch {
            return PluginIPCResponse(id: request.id, error: String(describing: error))
        }
    }

    /// 真实运行于独立子进程的 STDIO 通信主循环
    public func runStdio() async throws {
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput

        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty {
                // EOF 退出
                break
            }
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.subdata(in: 0..<newlineIndex)
                buffer.removeSubrange(0...newlineIndex)

                guard !lineData.isEmpty else { continue }
                if let req = try? JSONDecoder().decode(PluginIPCRequest.self, from: lineData) {
                    let res = await handleRequest(req)
                    if let resData = try? JSONEncoder().encode(res) {
                        output.write(resData)
                        output.write(Data([UInt8(ascii: "\n")]))
                    }
                }
            }
        }

        try await plugin.deactivate()
    }

    private func getOrActivateContext() async throws -> PluginContext {
        if let existing = context, isActivated {
            return existing
        }
        let ctx = context ?? PluginContext(
            pluginID: plugin.manifest.id,
            info: DefaultPluginInfoHub(),
            storage: DefaultPluginStorage(pluginID: plugin.manifest.id),
            logger: PluginLogger(pluginID: plugin.manifest.id)
        )
        self.context = ctx

        if !isActivated {
            try await plugin.activate(context: ctx)
            self.isActivated = true
        }
        return ctx
    }
}

/// 默认的私有存储实现（本地文件目录）
public actor DefaultPluginStorage: PluginStorage {
    private let directory: URL

    public init(pluginID: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.directory = home.appendingPathComponent(".lingxiagent/plugin-data/\(pluginID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func get(key: String) async throws -> String? {
        let file = directory.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(key: String, value: String) async throws {
        let file = directory.appendingPathComponent(key)
        try Data(value.utf8).write(to: file, options: .atomic)
    }

    public func remove(key: String) async throws {
        let file = directory.appendingPathComponent(key)
        try? FileManager.default.removeItem(at: file)
    }
}

/// 默认信息枢纽（支持后续跨进程反向查询或使用宿主注入）
public actor DefaultPluginInfoHub: PluginInfoHub {
    private var contextState: PluginContextStateInfo
    private var peCore: PluginPECoreInfo
    private var performance: PluginPerformanceInfo
    private var workspace: PluginWorkspaceInfo

    public init(
        contextState: PluginContextStateInfo = PluginContextStateInfo(activeModelID: "unknown", totalTokenUsage: 0, contextWindowPercentage: 0.0, isCompacted: false, messageCount: 0),
        peCore: PluginPECoreInfo = PluginPECoreInfo(pCoreRole: "idle", eCoreRole: "idle", reasoningEffort: "medium", pCoreToECoreTimeRatio: 1.0, cacheDebt: 0.0, backgroundTaskCount: 0),
        performance: PluginPerformanceInfo = PluginPerformanceInfo(timeToFirstTokenMs: 0, reasoningDurationMs: 0, toolExecutionDurationMs: 0, providerLatencyAverageMs: 0, isRateLimited: false),
        workspace: PluginWorkspaceInfo = PluginWorkspaceInfo(rootPath: FileManager.default.currentDirectoryPath, isGitRepository: false, currentGitBranch: nil, dirtyFileCount: 0, primaryLanguages: [], coreVersion: "1.0.0")
    ) {
        self.contextState = contextState
        self.peCore = peCore
        self.performance = performance
        self.workspace = workspace
    }

    public func update(
        contextState: PluginContextStateInfo? = nil,
        peCore: PluginPECoreInfo? = nil,
        performance: PluginPerformanceInfo? = nil,
        workspace: PluginWorkspaceInfo? = nil
    ) {
        if let contextState { self.contextState = contextState }
        if let peCore { self.peCore = peCore }
        if let performance { self.performance = performance }
        if let workspace { self.workspace = workspace }
    }

    public func getContextState() async throws -> PluginContextStateInfo {
        return contextState
    }

    public func getPECoreInfo() async throws -> PluginPECoreInfo {
        return peCore
    }

    public func getPerformanceInfo() async throws -> PluginPerformanceInfo {
        return performance
    }

    public func getWorkspaceInfo() async throws -> PluginWorkspaceInfo {
        return workspace
    }
}
