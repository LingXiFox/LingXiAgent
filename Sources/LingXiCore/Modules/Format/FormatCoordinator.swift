import Foundation
import LingXiPlatform
import LingXiProtocol

/// 跨语言代码格式化编排器 (FormatCoordinator)。
/// 负责跨平台自动探测本地与全局格式化器、安全调度进程、进行文件格式化并平滑降级。
public actor FormatCoordinator {
    public static let shared = FormatCoordinator()

    private var configurations: [FormatterConfig]
    private var isAutoFormatEnabled: Bool

    public init(
        configurations: [FormatterConfig] = FormatterConfig.builtinConfigurations,
        isAutoFormatEnabled: Bool = true
    ) {
        self.configurations = configurations
        self.isAutoFormatEnabled = isAutoFormatEnabled
    }

    /// 更新格式化配置
    public func updateConfigurations(_ configs: [FormatterConfig]) {
        self.configurations = configs
    }

    /// 设置是否在写盘/编辑后自动触发格式化
    public func setAutoFormatEnabled(_ enabled: Bool) {
        self.isAutoFormatEnabled = enabled
    }

    public func autoFormatEnabled() -> Bool {
        self.isAutoFormatEnabled
    }

    /// 为指定文件匹配可用的格式化配置
    public func matchingConfig(for fileURL: URL) -> FormatterConfig? {
        let ext = fileURL.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return configurations.first { $0.enabled && $0.extensions.contains(ext) }
    }

    /// 格式化指定文件
    public func format(fileURL: URL, workspaceRoot: URL? = nil) async -> FormatterResult {
        guard let config = matchingConfig(for: fileURL) else {
            return FormatterResult(
                path: fileURL.path,
                formatterName: "none",
                success: true,
                changed: false,
                message: "No matching formatter configured for .\(fileURL.pathExtension)"
            )
        }

        let startTime = Date().timeIntervalSinceReferenceDate
        let initialData = (try? Data(contentsOf: fileURL)) ?? Data()

        // 尝试主命令
        var runOutcome = await executeCommand(config.command, fileURL: fileURL, workspaceRoot: workspaceRoot)
        var usedFormatter = config.name

        // 若主命令失败且有备用命令（如 ruff -> black, prettier -> biome），尝试 fallback
        if !runOutcome.success, let fallback = config.fallbackCommand, !fallback.isEmpty {
            let fallbackOutcome = await executeCommand(fallback, fileURL: fileURL, workspaceRoot: workspaceRoot)
            if fallbackOutcome.success {
                runOutcome = fallbackOutcome
                usedFormatter = "\(config.name) (fallback: \(fallback.first ?? "unknown"))"
            }
        }

        let elapsedMs = (Date().timeIntervalSinceReferenceDate - startTime) * 1000.0

        guard runOutcome.success else {
            return FormatterResult(
                path: fileURL.path,
                formatterName: usedFormatter,
                success: false,
                changed: false,
                message: runOutcome.errorOutput ?? "Formatter command failed",
                durationMs: elapsedMs
            )
        }

        let finalData = (try? Data(contentsOf: fileURL)) ?? Data()
        let changed = (initialData != finalData)

        return FormatterResult(
            path: fileURL.path,
            formatterName: usedFormatter,
            success: true,
            changed: changed,
            message: changed ? "Formatted successfully" : "Already well-formatted",
            durationMs: elapsedMs
        )
    }

    /// 批量格式化多个文件
    public func format(files: [URL], workspaceRoot: URL? = nil) async -> [FormatterResult] {
        var results: [FormatterResult] = []
        for file in files {
            let res = await format(fileURL: file, workspaceRoot: workspaceRoot)
            results.append(res)
        }
        return results
    }

    // MARK: - Private Execution Helper

    private struct CommandRunOutcome {
        let success: Bool
        let errorOutput: String?
    }

    private func executeCommand(_ rawCommand: [String], fileURL: URL, workspaceRoot: URL?) async -> CommandRunOutcome {
        guard let binaryName = rawCommand.first, !binaryName.isEmpty else {
            return CommandRunOutcome(success: false, errorOutput: "Empty formatter command")
        }

        let resolvedExecutable = resolveExecutablePath(binaryName: binaryName, workspaceRoot: workspaceRoot)
        guard let executablePath = resolvedExecutable else {
            return CommandRunOutcome(success: false, errorOutput: "Formatter executable '\(binaryName)' not found in PATH or project local environment")
        }

        // 替换 $FILE 占位符
        var args = Array(rawCommand.dropFirst())
        var replaced = false
        args = args.map { arg in
            if arg.contains("$FILE") {
                replaced = true
                return arg.replacingOccurrences(of: "$FILE", with: fileURL.path)
            }
            return arg
        }
        if !replaced {
            args.append(fileURL.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        process.environment = EnvironmentSanitizer.sanitized()
        if let workspaceRoot {
            process.currentDirectoryURL = workspaceRoot
        } else {
            process.currentDirectoryURL = fileURL.deletingLastPathComponent()
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()

            // 设置执行超时，防止格式化器挂起（最大 15 秒）
            let task = Task {
                process.waitUntilExit()
            }

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if process.isRunning {
                    LingXiPlatform.process.terminateProcessTree(pid: process.processIdentifier, force: true)
                }
            }

            _ = await task.result
            timeoutTask.cancel()

            let exitCode = process.terminationStatus
            if exitCode == 0 {
                return CommandRunOutcome(success: true, errorOutput: nil)
            } else {
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return CommandRunOutcome(success: false, errorOutput: errStr?.isEmpty == false ? errStr : "Process exited with code \(exitCode)")
            }
        } catch {
            return CommandRunOutcome(success: false, errorOutput: error.localizedDescription)
        }
    }

    /// 解析可执行文件路径（优先检查项目 node_modules、.venv，其次为系统全局 PATH）
    private func resolveExecutablePath(binaryName: String, workspaceRoot: URL?) -> String? {
        if LingXiPlatform.path.isAbsolute(binaryName) {
            return FileManager.default.isExecutableFile(atPath: binaryName) ? binaryName : nil
        }

        if let workspaceRoot {
            // 1. 检查 Node 本地依赖: node_modules/.bin/<name>
            let nodeBin = workspaceRoot.appendingPathComponent("node_modules/.bin/\(binaryName)").path
            if FileManager.default.isExecutableFile(atPath: nodeBin) {
                return nodeBin
            }

            // 2. 检查 Python 虚拟环境: .venv/bin/<name> 或 venv/bin/<name>
            let venvBin1 = workspaceRoot.appendingPathComponent(".venv/bin/\(binaryName)").path
            if FileManager.default.isExecutableFile(atPath: venvBin1) {
                return venvBin1
            }
            let venvBin2 = workspaceRoot.appendingPathComponent("venv/bin/\(binaryName)").path
            if FileManager.default.isExecutableFile(atPath: venvBin2) {
                return venvBin2
            }
        }

        // 3. 全局探测 (macOS/Linux/Windows 跨平台抽象)
        return LingXiPlatform.process.resolveExecutable(named: binaryName, customSearchPaths: nil)
    }
}
