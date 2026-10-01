import Foundation
import LingXiProtocol
import LingXiPlatform
import LingXiPluginSDK

private final class PluginProcessState: @unchecked Sendable {
    var process: Process?
    var stdinHandle: FileHandle?
    var stdoutHandle: FileHandle?
    var errorHandle: FileHandle?
    private let lock = NSLock()

    func store(process: Process, stdin: FileHandle, stdout: FileHandle, error: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
        self.stdinHandle = stdin
        self.stdoutHandle = stdout
        self.errorHandle = error
    }

    func getHandles() -> (stdin: FileHandle, stdout: FileHandle, isRunning: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard let inH = stdinHandle, let outH = stdoutHandle, let proc = process, proc.isRunning else {
            return nil
        }
        return (inH, outH, true)
    }

    func closeHandles() {
        let (inH, outH, errH) = lock.withLock {
            let ih = stdinHandle
            let oh = stdoutHandle
            let eh = errorHandle
            stdinHandle = nil
            stdoutHandle = nil
            errorHandle = nil
            return (ih, oh, eh)
        }

        try? inH?.close()
        try? outH?.close()
        try? errH?.close()
    }

    func terminate(timeout: TimeInterval = 0.4) async {
        let proc = lock.withLock {
            let p = process
            process = nil
            return p
        }

        // Close stdin first so process can detect EOF and exit gracefully
        let (inH, outH, errH) = lock.withLock {
            let ih = stdinHandle
            let oh = stdoutHandle
            let eh = errorHandle
            stdinHandle = nil
            stdoutHandle = nil
            errorHandle = nil
            return (ih, oh, eh)
        }
        try? inH?.close()

        guard let proc, proc.isRunning else {
            try? outH?.close()
            try? errH?.close()
            return
        }

        proc.terminate()
        let start = Date()
        while proc.isRunning && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        if proc.isRunning {
            LingXiPlatform.process.terminateProcessTree(pid: proc.processIdentifier, force: true)
            proc.waitUntilExit()
        }

        try? outH?.close()
        try? errH?.close()
    }

    func killForcefully() {
        let proc = lock.withLock {
            let p = process
            process = nil
            return p
        }

        let (inH, outH, errH) = lock.withLock {
            let ih = stdinHandle
            let oh = stdoutHandle
            let eh = errorHandle
            stdinHandle = nil
            stdoutHandle = nil
            errorHandle = nil
            return (ih, oh, eh)
        }
        try? inH?.close()

        guard let proc, proc.isRunning else {
            try? outH?.close()
            try? errH?.close()
            return
        }
        proc.terminate()
        LingXiPlatform.process.terminateProcessTree(pid: proc.processIdentifier, force: true)
        proc.waitUntilExit()
        try? outH?.close()
        try? errH?.close()
    }
}

/// 单个外部二进制插件的进程宿主代理。
public actor PluginProcessHost {
    public let binaryURL: URL
    public let scope: ExtensionScope
    private let permissions: PermissionEngine
    private let watchdogTimeout: Double
    private let coreVersion: String

    private let state = PluginProcessState()
    private var isTerminated = false

    /// Core 侧权威运行快照来源。未接入时插件读到的是 unavailable,而不是假数据。
    private var snapshotProvider: (any PluginRuntimeSnapshotProviding)?

    public private(set) var handshakeResult: PluginHandshakeResult?

    public init(
        binaryURL: URL,
        scope: ExtensionScope = .project,
        permissions: PermissionEngine,
        watchdogTimeout: Double = 3.0,
        coreVersion: String = CoreHost.coreVersion
    ) {
        self.binaryURL = binaryURL
        self.scope = scope
        self.permissions = permissions
        self.watchdogTimeout = watchdogTimeout
        self.coreVersion = coreVersion
    }

    /// 接入 Core 的运行快照来源。晚于 start() 设置也有效:握手后的每次调用都会重新推送。
    public func setSnapshotProvider(_ provider: (any PluginRuntimeSnapshotProviding)?) {
        self.snapshotProvider = provider
    }

    deinit {
        state.killForcefully()
    }

    /// 启动子进程并完成握手
    public func start() async throws -> PluginHandshakeResult {
        guard !isTerminated else {
            throw CoreError(code: .processNotRunning, message: "Plugin process already terminated: \(binaryURL.lastPathComponent)")
        }

        let proc = Process()
        proc.executableURL = binaryURL
        proc.currentDirectoryURL = binaryURL.deletingLastPathComponent()
        // Plugins must never inherit the host's provider credentials or the vault passphrase.
        // Leaving `environment` unset makes Foundation forward every parent var, including
        // LINGXI_CREDENTIALS_PASSPHRASE that CoreHost/main.swift puts into the process env.
        proc.environment = EnvironmentSanitizer.sanitized()

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw CoreError(code: .commandFailed, message: "Failed to spawn plugin process: \(error.localizedDescription)")
        }

        let inH = inPipe.fileHandleForWriting
        let outH = outPipe.fileHandleForReading
        let errH = errPipe.fileHandleForReading
        state.store(process: proc, stdin: inH, stdout: outH, error: errH)

        // 持续 Drain stderr 防止 64KB pipe 缓冲区写满导致插件进程挂死
        let drainThread = Thread { [weak errH] in
            while let chunk = try? errH?.read(upToCount: 16384), !chunk.isEmpty {}
        }
        drainThread.name = "org.lingxi.plugin.stderrDrain"
        drainThread.start()

        // 握手前先推送权威快照:插件在 activate(context:) 里读 info 时也不能拿到默认值。
        await pushSnapshot(sessionID: nil)

        // 发起握手,并声明宿主协议版本,两端不兼容时在此明确失败。
        let initializeParams = try JSONEncoder().encode(
            PluginInitializeParams(coreVersion: coreVersion)
        )
        let responseData = try await sendRawRequest(
            method: PluginIPC.Method.initialize.rawValue, params: initializeParams)
        let handshake = try JSONDecoder().decode(PluginHandshakeResult.self, from: responseData)

        // 协议兼容按 ipcVersion 判定,不比较 Core 的版本字符串:版本不匹配的插件
        // 必须在这里失败,而不是等到某次 command 解码不出来。
        guard PluginIPC.isCompatible(handshake.ipcVersion) else {
            await terminate()
            throw CoreError(code: .commandFailed, message: """
            Plugin '\(handshake.manifest.id)' speaks LingXi Plugin IPC v\(handshake.ipcVersion); \
            this Core supports \(PluginIPC.supportedVersions.sorted()).
            """)
        }

        // 验证申请的能力是否允许（PermissionEngine 预审）
        for capability in handshake.manifest.capabilities {
            let toolCap: ToolCapabilityKind
            switch capability {
            case .projectRead: toolCap = .projectRead
            case .projectWrite: toolCap = .projectWrite
            case .processExecution: toolCap = .processExecute
            case .networkAccess: toolCap = .networkAccess
            }
            let req = PermissionRequest(
                permissionID: PermissionID("plugin-perm-\(UUID().uuidString)"),
                sessionID: SessionID("plugin-\(handshake.manifest.id)"),
                toolCallID: ToolCallID("init-\(UUID().uuidString)"),
                toolID: ToolID(handshake.manifest.id),
                capabilities: [toolCap],
                resource: binaryURL.path,
                description: "Plugin initialization capability request: \(capability.rawValue)"
            )
            let decision = await permissions.check(req)
            if decision.decision == .deny {
                await terminate()
                throw CoreError(code: .permissionDenied, message: "Plugin '\(handshake.manifest.id)' capability denied: \(capability.rawValue)")
            }
        }

        self.handshakeResult = handshake
        return handshake
    }

    /// 执行插件暴露的 Tool
    public func executeTool(name: String, arguments: String, sessionID: String, toolCallID: String) async throws -> String {
        guard let handshake = handshakeResult else {
            throw CoreError(code: .notReady, message: "Plugin not initialized")
        }
        guard handshake.tools.contains(where: { $0.name == name }) else {
            throw CoreError(code: .toolNotFound, message: "Tool '\(name)' not found in plugin '\(handshake.manifest.id)'")
        }

        // 每次调用前刷新,插件在工具里读到的运行时信息才不会是上一次会话的残留。
        await pushSnapshot(sessionID: SessionID(sessionID))
        let params = PluginToolCallParams(toolName: name, arguments: arguments, sessionID: sessionID, toolCallID: toolCallID)
        let paramsData = try JSONEncoder().encode(params)
        let resData = try await sendRawRequest(method: PluginIPC.Method.toolExecute.rawValue, params: paramsData)
        return try JSONDecoder().decode(String.self, from: resData)
    }

    /// 执行插件暴露的 Command
    public func executeCommand(name: String, arguments: [String], sessionID: String?) async throws -> PluginCommandCallResult {
        guard let handshake = handshakeResult else {
            throw CoreError(code: .notReady, message: "Plugin not initialized")
        }
        guard handshake.commands.contains(where: { $0.name == name || $0.aliases.contains(name) }) else {
            throw CoreError(code: .unsupportedCommand, message: "Command '\(name)' not found in plugin '\(handshake.manifest.id)'")
        }

        await pushSnapshot(sessionID: sessionID.map(SessionID.init))
        let params = PluginCommandCallParams(commandName: name, arguments: arguments, sessionID: sessionID)
        let paramsData = try JSONEncoder().encode(params)
        let resData = try await sendRawRequest(method: PluginIPC.Method.commandExecute.rawValue, params: paramsData)
        return try JSONDecoder().decode(PluginCommandCallResult.self, from: resData)
    }

    /// 广播生命周期 Hook
    public func emitHook(_ payload: PluginHookPayload) async {
        guard handshakeResult != nil else { return }
        await pushSnapshot(sessionID: payload.metadata["sessionID"].map(SessionID.init))
        if let paramsData = try? JSONEncoder().encode(payload) {
            _ = try? await sendRawRequest(method: PluginIPC.Method.hookEmit.rawValue, params: paramsData)
        }
    }

    /// Core → Plugin 的单向快照推送。推送失败不升级为调用失败:快照缺失由插件
    /// 侧以 `PluginInfoUnavailable` 表现,而工具调用本身该不该成功是另一件事。
    private func pushSnapshot(sessionID: SessionID?) async {
        guard let snapshotProvider else { return }
        let snapshot = await snapshotProvider.snapshot(sessionID: sessionID)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        _ = try? await sendRawRequest(method: PluginIPC.Method.snapshot.rawValue, params: data)
    }

    /// 安全终止或熔断强杀
    public func terminate() async {
        guard !isTerminated else { return }
        isTerminated = true
        await state.terminate()
    }

    /// 同步尽力终止与强杀（供 deinit / 同步清理路径使用）
    public nonisolated func terminateSync() {
        state.killForcefully()
    }

    // MARK: - Private IPC Exchange

    private func sendRawRequest(method: String, params: Data?) async throws -> Data {
        guard let handles = state.getHandles() else {
            throw CoreError(code: .processNotRunning, message: "Plugin process is not running")
        }

        let inHandle = handles.stdin
        let outHandle = handles.stdout

        let requestID = UUID().uuidString
        let request = PluginIPCRequest(id: requestID, method: method, params: params)
        let lineData = try JSONEncoder().encode(request) + Data([UInt8(ascii: "\n")])

        inHandle.write(lineData)

        // 读回响应（单行 JSON，带超时限制，严格走非阻塞 LineReader 杜绝线程池饥饿挂死）
        do {
            let result = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    for try await line in LingXiPlatform.lineReader.lines(from: outHandle) {
                        try Task.checkCancellation()
                        guard let lineData = line.data(using: .utf8) else { continue }
                        let resp = try JSONDecoder().decode(PluginIPCResponse.self, from: lineData)
                        if let error = resp.error {
                            throw CoreError(code: .commandFailed, message: "Plugin IPC Error: \(error)")
                        }
                        return resp.result ?? Data()
                    }
                    throw CoreError(code: .transport, message: "Plugin process closed stdout unexpectedly")
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(self.watchdogTimeout))
                    throw CoreError(code: .commandTimedOut, message: "Plugin IPC call timed out after \(self.watchdogTimeout)s")
                }

                let res = try await group.next()!
                group.cancelAll()
                return res
            }
            return result
        } catch {
            await terminate()
            throw error
        }
    }
}
