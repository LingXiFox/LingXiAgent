import Foundation
import LingXiPlatform
import LingXiProtocol


final class BackgroundTaskRecord: @unchecked Sendable {
    let id: String
    let command: String
    let cwd: URL
    let timeoutSeconds: Int
    let startedAt: Date
    var completedAt: Date?
    var status: BackgroundTaskStatus
    var description: String?
    var hasBeenObserved: Bool
    var noticeCount: Int
    let process: ManagedToolProcess
    var timeoutTask: Task<Void, Never>?
    var watchExitTask: Task<Void, Never>?
    var cachedExitCode: Int32?

    init(
        id: String,
        command: String,
        cwd: URL,
        timeoutSeconds: Int,
        startedAt: Date = Date(),
        description: String? = nil,
        process: ManagedToolProcess
    ) {
        self.id = id
        self.command = command
        self.cwd = cwd
        self.timeoutSeconds = timeoutSeconds
        self.startedAt = startedAt
        self.status = .running
        self.description = description
        self.hasBeenObserved = false
        self.noticeCount = 0
        self.process = process
    }
}

public actor BackgroundCommandManager {
    private var tasks: [String: BackgroundTaskRecord] = [:]
    private var taskOrder: [String] = []
    private var lastRemindedStep: Int = -1
    private var completionContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init() {}

    public var hasRunningTasks: Bool {
        for record in tasks.values {
            updateStatusIfExited(record)
        }
        return tasks.values.contains { $0.status == .running }
    }

    public var runningTasksCount: Int {
        for record in tasks.values {
            updateStatusIfExited(record)
        }
        return tasks.values.filter { $0.status == .running }.count
    }

    public func waitForTaskCompletion() async {
        if !hasRunningTasks { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.completionContinuations[id] = continuation
            }
        } onCancel: {
            Task { [weak self] in
                await self?.removeWaiter(id: id)
            }
        }
    }

    private func removeWaiter(id: UUID) {
        completionContinuations.removeValue(forKey: id)?.resume()
    }

    private func notifyWaiters() {
        let waiters = completionContinuations.values
        completionContinuations.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }

    public func spawn(
        command: String,
        timeoutSeconds: Int?,
        cwd: URL,
        workspace: WorkspaceRoot,
        profile: ExecutionProfile,
        description: String? = nil,
        customID: String? = nil,
        lifecycleTrace: ToolLifecycleTrace? = nil
    ) async throws -> BackgroundTaskSnapshot {
        guard let timeout = timeoutSeconds, timeout > 0 else {
            throw CoreError(
                code: .toolArgumentInvalid,
                message: "后台命令必须显式配置有效超时时间 timeout_seconds（单位秒，例如 60-3600），未配置超时的后台任务禁止创建"
            )
        }
        guard timeout <= 7200 else {
            throw CoreError(
                code: .toolArgumentInvalid,
                message: "后台命令超时时间 timeout_seconds 不能超过 7200 秒 (2小时)"
            )
        }
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw CoreError(code: .toolArgumentInvalid, message: "command 不能为空")
        }

        let taskID = customID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? customID!
            : "bg-" + UUID().uuidString.prefix(8).lowercased()

        guard tasks[taskID] == nil else {
            throw CoreError(code: .toolArgumentInvalid, message: "后台任务 ID 已存在: \(taskID)")
        }

        let shellExecutable: String
        let shellArgs: [String]
        #if os(Windows)
        let resolvedShell = LingXiPlatform.process.resolveExecutable(named: "powershell.exe", customSearchPaths: nil) ?? "C:\\Windows\\System32\\cmd.exe"
        let isPowerShell = resolvedShell.lowercased().contains("powershell")
        shellExecutable = resolvedShell
        shellArgs = isPowerShell ? ["-NoProfile", "-NonInteractive", "-Command", trimmedCommand] : ["/c", trimmedCommand]
        #else
        shellExecutable = LingXiPlatform.process.resolveExecutable(named: "sh", customSearchPaths: ["/bin", "/usr/bin"]) ?? "/bin/sh"
        shellArgs = ["-c", trimmedCommand]
        #endif

        let setup = try processSetup(executable: shellExecutable, arguments: shellArgs, workspace: workspace, cwd: cwd, profile: profile)
        let process = ManagedToolProcess(invocation: setup.0, cwd: cwd, environment: setup.1, lifecycleTrace: lifecycleTrace)
        try process.launch()

        let record = BackgroundTaskRecord(
            id: taskID,
            command: trimmedCommand,
            cwd: cwd,
            timeoutSeconds: timeout,
            description: description,
            process: process
        )

        record.timeoutTask = Task { [weak self, weak record, taskID] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.handleTimeout(taskID: taskID, expectedRecord: record)
        }

        record.watchExitTask = Task { [weak self, weak record, taskID] in
            await record?.process.waitForExit()
            guard !Task.isCancelled else { return }
            await self?.handleProcessExit(taskID: taskID, expectedRecord: record)
        }

        tasks[taskID] = record
        taskOrder.append(taskID)

        return snapshot(for: record, stdoutCursor: nil, stderrCursor: nil)
    }

    private func handleTimeout(taskID: String, expectedRecord: BackgroundTaskRecord?) {
        guard let record = tasks[taskID], record === expectedRecord, record.status == .running else { return }
        record.status = .timedOut
        record.completedAt = Date()
        record.watchExitTask?.cancel()
        record.watchExitTask = nil
        record.process.terminate(timedOut: true)
        if let pid = record.process.snapshot(id: taskID, stdoutCursor: nil, stderrCursor: nil).pid {
            LingXiPlatform.process.terminateProcessTree(pid: pid, force: true)
        }
        notifyWaiters()
    }

    private func handleProcessExit(taskID: String, expectedRecord: BackgroundTaskRecord?) {
        guard let record = tasks[taskID], record === expectedRecord, record.status == .running else { return }
        updateStatusIfExited(record)
        notifyWaiters()
    }

    public func poll(id: String, stdoutCursor: Int? = nil, stderrCursor: Int? = nil) throws -> BackgroundTaskSnapshot {
        guard let record = tasks[id] else {
            throw CoreError(code: .processNotFound, message: "后台任务不存在: \(id)")
        }
        updateStatusIfExited(record)
        if record.status != .running {
            record.hasBeenObserved = true
        }
        return snapshot(for: record, stdoutCursor: stdoutCursor, stderrCursor: stderrCursor)
    }

    public func input(id: String, text: String, stdoutCursor: Int? = nil, stderrCursor: Int? = nil) throws -> BackgroundTaskSnapshot {
        guard let record = tasks[id] else {
            throw CoreError(code: .processNotFound, message: "后台任务不存在: \(id)")
        }
        guard record.status == .running else {
            throw CoreError(code: .processNotRunning, message: "后台任务已处于非运行状态 (\(record.status.rawValue))，无法输入")
        }
        try record.process.write(text)
        return snapshot(for: record, stdoutCursor: stdoutCursor, stderrCursor: stderrCursor)
    }

    public func terminate(id: String, stdoutCursor: Int? = nil, stderrCursor: Int? = nil) throws -> BackgroundTaskSnapshot {
        guard let record = tasks[id] else {
            throw CoreError(code: .processNotFound, message: "后台任务不存在: \(id)")
        }
        if record.status == .running {
            record.status = .terminated
            record.completedAt = Date()
            record.timeoutTask?.cancel()
            record.timeoutTask = nil
            record.watchExitTask?.cancel()
            record.watchExitTask = nil
            record.process.terminate()
            if let pid = record.process.snapshot(id: id, stdoutCursor: nil, stderrCursor: nil).pid {
                LingXiPlatform.process.terminateProcessTree(pid: pid, force: true)
            }
            notifyWaiters()
        }
        record.hasBeenObserved = true
        return snapshot(for: record, stdoutCursor: stdoutCursor, stderrCursor: stderrCursor)
    }

    public func list() -> [BackgroundTaskSnapshot] {
        taskOrder.compactMap { tasks[$0] }.map { record in
            updateStatusIfExited(record)
            return snapshot(for: record, stdoutCursor: nil, stderrCursor: nil)
        }
    }

    public func terminateAll() async {
        for id in taskOrder {
            guard let record = tasks[id] else { continue }
            record.timeoutTask?.cancel()
            record.timeoutTask = nil
            record.watchExitTask?.cancel()
            record.watchExitTask = nil
            if record.status == .running {
                record.status = .terminated
                record.completedAt = Date()
                record.process.terminate()
                if let pid = record.process.snapshot(id: id, stdoutCursor: nil, stderrCursor: nil).pid {
                    LingXiPlatform.process.terminateProcessTree(pid: pid, force: true)
                }
            }
        }
        for record in tasks.values {
            await record.process.waitForExit()
        }
        tasks.removeAll()
        taskOrder.removeAll()
        notifyWaiters()
    }

    public func generateSystemNotice(currentStep: Int) -> String? {
        // Refresh statuses of all tasks
        for record in tasks.values {
            updateStatusIfExited(record)
        }

        // 1. Highest Priority: Unobserved Completed Tasks
        let unobserved = taskOrder.compactMap { tasks[$0] }.filter {
            $0.status != .running && !$0.hasBeenObserved
        }

        if !unobserved.isEmpty {
            var lines = [
                "[SYSTEM NOTICE: 后台命令执行状态更新]",
                "检测到以下后台任务已结束执行，但模型前台尚未调取其最终结果：",
            ]
            for task in unobserved {
                let dur = String(format: "%.1fs", max(0, (task.completedAt ?? Date()).timeIntervalSince(task.startedAt)))
                let desc = task.description.map { " (\($0))" } ?? ""
                let codeStr = task.cachedExitCode.map { "退出码: \($0)" } ?? "无"
                lines.append("• 任务 [\(task.id)]\(desc): 状态: \(task.status.rawValue) | 耗时: \(dur) | \(codeStr)")
                lines.append("  命令行: `\(task.command)`")
                let snap = snapshot(for: task, stdoutCursor: nil, stderrCursor: nil)
                if !snap.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("  [标准输出 stdout]:\n```\n\(snap.stdout.prefix(4000))\n```")
                }
                if !snap.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("  [标准错误 stderr]:\n```\n\(snap.stderr.prefix(2000))\n```")
                }
                task.noticeCount += 1
                if task.noticeCount >= 2 {
                    task.hasBeenObserved = true
                }
            }
            lines.append("【强制提示】请立即调用 `manage_background_command(action: \"poll\", task_id: \"...\")` 查看输出日志，严禁凭空臆测命令执行结果！")
            return lines.joined(separator: "\n")
        }

        // 2. Cadence Reminder: Running Tasks
        let runningTasks = taskOrder.compactMap { tasks[$0] }.filter { $0.status == .running }
        guard !runningTasks.isEmpty else { return nil }

        // Trigger every 2 steps or on the very first step
        if lastRemindedStep < 0 || currentStep - lastRemindedStep >= 2 {
            lastRemindedStep = currentStep
            var lines = [
                "[SYSTEM NOTICE: 后台命令正在运行中]",
                "当前有 \(runningTasks.count) 个后台任务正在异步执行：",
            ]
            for task in runningTasks {
                let elapsed = Date().timeIntervalSince(task.startedAt)
                let remaining = max(0, Double(task.timeoutSeconds) - elapsed)
                let desc = task.description.map { " (\($0))" } ?? ""
                lines.append("• 任务 [\(task.id)]\(desc): 已运行 \(Int(elapsed))s / 超时上限 \(task.timeoutSeconds)s (剩余 \(Int(remaining))s)")
                lines.append("  命令行: `\(task.command)`")
            }
            lines.append("提示：前台可继续执行无冲突操作；若后续操作依赖上述命令产物，请适时调用 `manage_background_command` 轮询检查。")
            return lines.joined(separator: "\n")
        }

        return nil
    }

    private func updateStatusIfExited(_ record: BackgroundTaskRecord) {
        guard record.status == .running else { return }
        let procSnap = record.process.snapshot(id: record.id, stdoutCursor: nil, stderrCursor: nil)
        if !procSnap.running {
            record.status = .exited
            record.completedAt = Date()
            record.cachedExitCode = procSnap.exitCode
            record.timeoutTask?.cancel()
            record.timeoutTask = nil
            record.watchExitTask?.cancel()
            record.watchExitTask = nil
        }
    }

    private func snapshot(for record: BackgroundTaskRecord, stdoutCursor: Int?, stderrCursor: Int?) -> BackgroundTaskSnapshot {
        updateStatusIfExited(record)
        let procSnap = record.process.snapshot(id: record.id, stdoutCursor: stdoutCursor, stderrCursor: stderrCursor)
        let now = Date()
        let elapsed = (record.completedAt ?? now).timeIntervalSince(record.startedAt)
        let remaining = max(0, Double(record.timeoutSeconds) - elapsed)
        return BackgroundTaskSnapshot(
            id: record.id,
            command: record.command,
            cwd: record.cwd.path,
            timeoutSeconds: record.timeoutSeconds,
            startedAt: record.startedAt,
            completedAt: record.completedAt,
            status: record.status,
            pid: procSnap.pid,
            exitCode: record.cachedExitCode ?? procSnap.exitCode,
            description: record.description,
            stdout: procSnap.stdout.text,
            stderr: procSnap.stderr.text,
            stdoutCursor: procSnap.stdout.cursor,
            stderrCursor: procSnap.stderr.cursor,
            elapsedSeconds: elapsed,
            remainingTimeoutSeconds: remaining
        )
    }
}
