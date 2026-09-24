import Foundation

/// 托管外部子进程的生命周期抽象。
/// 负责进程的配置、启动、运行状态检测与进程树安全销毁。
public final class ManagedProcess: @unchecked Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL?

    private var process: Process?
    private let lock = NSLock()

    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment ?? ProcessInfo.processInfo.environment
        self.workingDirectory = workingDirectory
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    public var processIdentifier: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return process?.processIdentifier
    }

    /// 启动子进程并绑定输入输出管道
    public func launch(
        inputPipe: Pipe,
        outputPipe: Pipe,
        errorPipe: Pipe? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        guard process == nil else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        proc.environment = environment
        if let workingDirectory {
            proc.currentDirectoryURL = workingDirectory
        }

        proc.standardInput = inputPipe
        proc.standardOutput = outputPipe
        if let errorPipe {
            proc.standardError = errorPipe
        }

        try proc.run()
        self.process = proc
    }

    /// 安全终止子进程及其所有派生子进程树（级联销毁）
    public func terminate(force: Bool = true) {
        lock.lock()
        defer { lock.unlock() }

        guard let proc = process else { return }
        if proc.isRunning {
            LingXiPlatform.process.terminateProcessTree(pid: proc.processIdentifier, force: force)
            let deadline = Date().addingTimeInterval(0.5)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if proc.isRunning {
                LingXiPlatform.process.terminateProcessTree(pid: proc.processIdentifier, force: true)
                proc.waitUntilExit()
            }
        }
        process = nil
    }
}
