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

        closeHandles()
        guard let proc, proc.isRunning else { return }

        proc.terminate()
        let didExit: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let start = Date()
                while proc.isRunning && Date().timeIntervalSince(start) < timeout {
                    usleep(20_000)
                }
                continuation.resume(returning: !proc.isRunning)
            }
        }

        if !didExit && proc.isRunning {
            LingXiPlatform.process.terminateProcessTree(pid: proc.processIdentifier, force: true)
            proc.waitUntilExit()
        }
    }

    func killForcefully() {
        let proc = lock.withLock {
            let p = process
            process = nil
            return p
        }

        closeHandles()
        guard let proc, proc.isRunning else { return }
        proc.terminate()
        LingXiPlatform.process.terminateProcessTree(pid: proc.processIdentifier, force: true)
    }
}

/// 单个外部二进制插件的进程宿主代理。
public actor PluginProcessHost {
    public let binaryURL: URL
    public let scope: ExtensionScope
    private let permissions: PermissionEngine
    private let watchdogTimeout: Double

    private let state = PluginProcessState()
    private var isTerminated = false

    public private(set) var handshakeResult: PluginHandshakeResult?

    public init(
        binaryURL: URL,
        scope: ExtensionScope = .project,
        permissions: PermissionEngine,
        watchdogTimeout: Double = 10.0
    ) {
        self.binaryURL = binaryURL
        self.scope = scope
        self.permissions = permissions
        self.watchdogTimeout = watchdogTimeout
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
            while let chunk = errH?.availableData, !chunk.isEmpty {}
        }
        drainThread.name = "org.lingxi.plugin.stderrDrain"
        drainThread.start()

        // 发起握手
        let responseData = try await sendRawRequest(method: "plugin.initialize", params: nil)
        let handshake = try JSONDecoder().decode(PluginHandshakeResult.self, from: responseData)

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

        let params = PluginToolCallParams(toolName: name, arguments: arguments, sessionID: sessionID, toolCallID: toolCallID)
        let paramsData = try JSONEncoder().encode(params)
        let resData = try await sendRawRequest(method: "tool.execute", params: paramsData)
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

        let params = PluginCommandCallParams(commandName: name, arguments: arguments, sessionID: sessionID)
        let paramsData = try JSONEncoder().encode(params)
        let resData = try await sendRawRequest(method: "command.execute", params: paramsData)
        return try JSONDecoder().decode(PluginCommandCallResult.self, from: resData)
    }

    /// 广播生命周期 Hook
    public func emitHook(_ payload: PluginHookPayload) async {
        guard handshakeResult != nil else { return }
        if let paramsData = try? JSONEncoder().encode(payload) {
            _ = try? await sendRawRequest(method: "hook.emit", params: paramsData)
        }
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

        // 读回响应（单行 JSON，带超时限制）
        do {
            let result = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    var buffer = Data()
                    while true {
                        try Task.checkCancellation()
                        let chunk = outHandle.availableData
                        if chunk.isEmpty {
                            throw CoreError(code: .transport, message: "Plugin process closed stdout unexpectedly")
                        }
                        buffer.append(chunk)
                        if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                            let line = buffer.subdata(in: 0..<newline)
                            let resp = try JSONDecoder().decode(PluginIPCResponse.self, from: line)
                            if let error = resp.error {
                                throw CoreError(code: .commandFailed, message: "Plugin IPC Error: \(error)")
                            }
                            return resp.result ?? Data()
                        }
                    }
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
            // 打破孤儿读取线程的阻塞，清理失联或超时的插件进程
            try? outHandle.close()
            if let coreErr = error as? CoreError, coreErr.code == .commandTimedOut {
                await terminate()
            }
            throw error
        }
    }
}
