import Foundation

/// 插件端 STDIO / IPC 驱动器。
public actor PluginDriver {
    private let plugin: any LingXiPlugin
    private let infoHub: DefaultPluginInfoHub
    private var context: PluginContext?
    private var isActivated = false

    public init(plugin: any LingXiPlugin, infoHub: DefaultPluginInfoHub = DefaultPluginInfoHub()) {
        self.plugin = plugin
        self.infoHub = infoHub
    }

    /// 执行单次 IPC 请求分发(供 STDIO 循环或进程内直接驱动使用)
    public func handleRequest(_ request: PluginIPCRequest) async -> PluginIPCResponse {
        do {
            switch request.method {
            case PluginIPC.Method.snapshot.rawValue:
                guard let paramsData = request.params else {
                    return PluginIPCResponse(id: request.id, error: "host.snapshot requires a snapshot payload")
                }
                let snapshot = try JSONDecoder().decode(PluginRuntimeSnapshot.self, from: paramsData)
                // 协议版本不兼容时明确拒绝:让插件带着说不通的快照跑下去,只会在
                // 更远的地方以更难诊断的形式失败。
                guard PluginIPC.isCompatible(snapshot.ipcVersion) else {
                    return PluginIPCResponse(id: request.id, error: """
                    Unsupported host IPC version \(snapshot.ipcVersion); \
                    this plugin speaks \(PluginIPC.supportedVersions.sorted()).
                    """)
                }
                await infoHub.apply(snapshot)
                return PluginIPCResponse(id: request.id, result: Data())

            case PluginIPC.Method.initialize.rawValue:
                // Core 先声明协议版本;两端没有共同版本就在此失败。
                if let paramsData = request.params,
                   let params = try? JSONDecoder().decode(PluginInitializeParams.self, from: paramsData),
                   !PluginIPC.isCompatible(params.hostIPCVersion) {
                    return PluginIPCResponse(id: request.id, error: """
                    Unsupported host IPC version \(params.hostIPCVersion); \
                    plugin supports \(PluginIPC.supportedVersions.sorted()).
                    """)
                }
                let ctx = try await getOrActivateContext()
                let tools = ctx.allTools.map {
                    PluginToolDescriptor(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
                }
                let commands = ctx.allCommands.map {
                    PluginCommandDescriptor(name: $0.name, aliases: $0.aliases, description: $0.description, category: $0.category, argumentHint: $0.argumentHint)
                }
                let result = PluginHandshakeResult(
                    manifest: plugin.manifest,
                    tools: tools,
                    commands: commands,
                    supportedHooks: ctx.registeredHookEvents.map(\.rawValue)
                )
                let data = try JSONEncoder().encode(result)
                return PluginIPCResponse(id: request.id, result: data)

            case PluginIPC.Method.toolExecute.rawValue:
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

            case PluginIPC.Method.commandExecute.rawValue:
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

            case PluginIPC.Method.hookEmit.rawValue:
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
            info: infoHub,
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

/// 默认的私有存储实现(本地文件目录)
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

/// Core 权威快照的本地持有者。
///
/// 它不产生任何数据:没有收到 `host.snapshot` 之前,四个段落一律 `unavailable`。
/// 曾经这里预置了 `activeModelID = "unknown"`、P/E `idle`、TTFT `0`、workspace
/// 取当前目录 —— 插件因此无法区分「宿主停着」和「宿主没告诉我」。
public actor DefaultPluginInfoHub: PluginInfoHub {
    private var snapshot: PluginRuntimeSnapshot?

    public init() {}

    /// 最近一次权威快照;`nil` 表示这条链路上还没有推送过。
    public var latestSnapshot: PluginRuntimeSnapshot? { snapshot }

    /// Core → Plugin 的快照落地点。较新的快照覆盖较旧的,乱序到达时保留更新的。
    public func apply(_ next: PluginRuntimeSnapshot) {
        if let existing = snapshot, existing.observedAt > next.observedAt { return }
        snapshot = next
    }

    public func getContextState() async throws -> PluginContextStateInfo {
        try value(\PluginRuntimeSnapshot.contextState, field: .contextState)
    }

    public func getPECoreInfo() async throws -> PluginPECoreInfo {
        try value(\PluginRuntimeSnapshot.peCore, field: .peCore)
    }

    public func getPerformanceInfo() async throws -> PluginPerformanceInfo {
        try value(\PluginRuntimeSnapshot.performance, field: .performance)
    }

    public func getWorkspaceInfo() async throws -> PluginWorkspaceInfo {
        try value(\PluginRuntimeSnapshot.workspace, field: .workspace)
    }

    private func value<T>(_ keyPath: KeyPath<PluginRuntimeSnapshot, T?>, field: PluginInfoField) throws -> T {
        guard let section = snapshot?[keyPath: keyPath] else {
            throw PluginInfoUnavailable(field: field, lastObservedAt: snapshot?.observedAt)
        }
        return section
    }
}
