import Foundation
import LingXiProtocol
import LingXiPlatform
import LingXiPluginSDK

/// 单个外部二进制插件的进程宿主代理。
public actor PluginProcessHost {
    public let binaryURL: URL
    public let scope: ExtensionScope
    private let permissions: PermissionEngine
    private let watchdogTimeout: Double

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
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

        self.process = proc
        self.stdinHandle = inPipe.fileHandleForWriting
        self.stdoutHandle = outPipe.fileHandleForReading

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
                terminate()
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
    public func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        if let proc = process, proc.isRunning {
            proc.terminate()
            // 延时强杀
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                if proc.isRunning {
                    LingXiPlatform.process.terminateProcessTree(pid: proc.processIdentifier, force: true)
                }
            }
        }
        stdinHandle = nil
        stdoutHandle = nil
        process = nil
    }

    // MARK: - Private IPC Exchange

    private func sendRawRequest(method: String, params: Data?) async throws -> Data {
        guard let inHandle = stdinHandle, let outHandle = stdoutHandle, let proc = process, proc.isRunning else {
            throw CoreError(code: .processNotRunning, message: "Plugin process is not running")
        }

        let requestID = UUID().uuidString
        let request = PluginIPCRequest(id: requestID, method: method, params: params)
        let lineData = try JSONEncoder().encode(request) + Data([UInt8(ascii: "\n")])

        inHandle.write(lineData)

        // 读回响应（单行 JSON，带超时限制）
        return try await withThrowingTaskGroup(of: Data.self) { group in
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

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
