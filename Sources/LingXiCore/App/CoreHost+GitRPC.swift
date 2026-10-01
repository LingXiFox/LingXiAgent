import Foundation
import LingXiProtocol

// Git RPC namespace（契约第十四至十八节）。
//
// 三条入口 —— Agent Tool、GUI、RPC —— 必须汇进同一条 git 执行路径：
// `GitRunner` 出 argv，`ToolMutationCoordinator` 串行化写，`PermissionEngine` 管授权。
// 这里不拼 argv、不 fork 进程、不允许仓库定位参数。

extension CoreHost {

    // MARK: - Read RPC

    /// `git.status`：计数来自 Core 解析后的 porcelain records，前端不再自己数行（契约第二十二节）。
    public func gitStatus(envelope: QueryEnvelope<GitQueryRequest>) async throws -> ResponseEnvelope<GitStatusResult> {
        let payload = try await gitService.status(workingDirectory: envelope.payload.workingDirectory)
        return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision,
                                eventCursor: await runtimeEventLog.currentCursor(), payload: payload)
    }

    public func gitDiff(envelope: QueryEnvelope<GitDiffRequest>) async throws -> ResponseEnvelope<GitDiffResult> {
        let payload = try await gitService.diff(envelope.payload)
        return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision,
                                eventCursor: await runtimeEventLog.currentCursor(), payload: payload)
    }

    public func gitLog(envelope: QueryEnvelope<GitQueryRequest>) async throws -> ResponseEnvelope<GitTextResult> {
        let payload = try await gitService.log(limit: envelope.payload.limit,
                                               workingDirectory: envelope.payload.workingDirectory)
        return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision,
                                eventCursor: await runtimeEventLog.currentCursor(), payload: payload)
    }

    public func gitShow(envelope: QueryEnvelope<GitQueryRequest>) async throws -> ResponseEnvelope<GitTextResult> {
        let payload = try await gitService.show(reference: envelope.payload.reference ?? "HEAD",
                                                workingDirectory: envelope.payload.workingDirectory)
        return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision,
                                eventCursor: await runtimeEventLog.currentCursor(), payload: payload)
    }

    public func gitBranch(envelope: QueryEnvelope<GitQueryRequest>) async throws -> ResponseEnvelope<GitTextResult> {
        let payload = try await gitService.branch(workingDirectory: envelope.payload.workingDirectory)
        return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision,
                                eventCursor: await runtimeEventLog.currentCursor(), payload: payload)
    }

    // MARK: - Mutation RPC

    public func gitAdd(envelope: CommandEnvelope<GitMutationRequest>) async throws -> CommandReceipt<GitMutationResult> {
        try await gitMutation(envelope, action: .add, commandName: "gitAdd")
    }

    public func gitRestore(envelope: CommandEnvelope<GitMutationRequest>) async throws -> CommandReceipt<GitMutationResult> {
        try await gitMutation(envelope, action: .restore, commandName: "gitRestore")
    }

    public func gitCheckout(envelope: CommandEnvelope<GitMutationRequest>) async throws -> CommandReceipt<GitMutationResult> {
        try await gitMutation(envelope, action: .checkout, commandName: "gitCheckout")
    }

    public func gitSwitch(envelope: CommandEnvelope<GitMutationRequest>) async throws -> CommandReceipt<GitMutationResult> {
        try await gitMutation(envelope, action: .switch, commandName: "gitSwitch")
    }

    public func gitCommit(envelope: CommandEnvelope<GitMutationRequest>) async throws -> CommandReceipt<GitMutationResult> {
        try await gitMutation(envelope, action: .commit, commandName: "gitCommit")
    }

    public func gitFetch(envelope: CommandEnvelope<GitRemoteRequest>) async throws -> CommandReceipt<GitMutationResult> {
        try await gitMutation(envelope.mapped(to: .fetch), action: .fetch, commandName: "gitFetch")
    }

    public func gitPull(envelope: CommandEnvelope<GitRemoteRequest>) async throws -> CommandReceipt<GitMutationResult> {
        try await gitMutation(envelope.mapped(to: .pull), action: .pull, commandName: "gitPull")
    }

    public func gitPush(envelope: CommandEnvelope<GitRemoteRequest>) async throws -> CommandReceipt<GitMutationResult> {
        try await gitMutation(envelope.mapped(to: .push), action: .push, commandName: "gitPush")
    }

    /// 所有 Git 写操作的唯一落点：串行化 + 授权 + 身份审计（契约第十五、十六节）。
    /// GUI 的点击不伪装成 Agent Tool Call，但它仍然带着 `toolCallID` 进来，用于 cancelPending、
    /// mutation coordination 与日志关联；Agent 发起时带真实 sessionID / toolCallID。
    private func gitMutation(
        _ envelope: CommandEnvelope<GitMutationRequest>,
        action: GitAction,
        commandName: String
    ) async throws -> CommandReceipt<GitMutationResult> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: commandName, as: GitMutationResult.self) {
            return cached
        }
        let payload = envelope.payload
        let toolCallID = payload.toolCallID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolCallID.isEmpty else {
            throw CoreError(code: .toolArgumentInvalid, message: "Git 写操作必须携带调用身份 toolCallID")
        }
        let sessionID = payload.sessionID ?? CoreHost.guiSessionID
        let request = payload.gitRequest(action: action)
        let operationRisk = GitRiskPolicy.classify(for: request)
        let risk = operationRisk.level
        let capabilities = operationRisk.capabilities

        // fetch/pull 的缺省目标由 service 补全；push 不猜目标，缺 upstream 直接失败（契约第二至四节）。
        let resolvedRequest = try await gitService.resolved(request)
        try await gitService.validatePush(resolvedRequest)
        let resolvedRisk = GitRiskPolicy.classify(for: resolvedRequest)
        let resolvedCapabilities = resolvedRisk.capabilities

        return try await sessionMutationLock.withExclusiveMutation(sessionID) {
            // 同一个 request 对象既用于判定也用于广播：permissionID 必须与 pending 表一致，
            // 否则客户端回答的是一个从未登记的 ID，问题会一直挂着。
            let permission = PermissionRequest(
                permissionID: PermissionID(UUID().uuidString),
                sessionID: sessionID,
                runID: nil,
                toolCallID: ToolCallID(toolCallID),
                toolID: ToolID("git"),
                capabilities: capabilities,
                resource: Self.gitResourceLabel(request),
                description: "Git \(action.rawValue)（\(risk.rawValue)）"
            )
            let permissionStart = Date()
            let resolution = await permissionEngine.resolve(permission, configuration: nil) { [weak self] in
                await self?.broadcast(.permissionAsked(permission))
            }
            guard resolution.decision == .allow else {
                throw CoreError(
                    code: .permissionDenied,
                    message: "Git \(action.rawValue) 未获授权（decision=\(resolution.decision.rawValue)，等待 \(Int(Date().timeIntervalSince(permissionStart) * 1000))ms）"
                )
            }

            // 写操作进唯一的 mutation 串行化路径：GUI 的 git add 与 Agent 的 git commit
            // 不会同时改同一个 repository index。
            // 所有 Git 写 —— 本地与远程 —— 都在同一个 coordinator 里串行（契约第六节）。
            let output = try await mutationCoordinator.execute {
                try await self.gitService.execute(resolvedRequest).trimmedStdout
            }
            let revision = await self.mutationCoordinator.currentRevision
            let receipt = CommandReceipt<GitMutationResult>(
                commandID: envelope.commandID,
                applied: true,
                revision: self.nextRevision(),
                observedThrough: [await self.runtimeEventLog.currentWatermark()],
                result: GitMutationResult(
                    action: action.rawValue,
                    output: output,
                    risk: resolvedRisk.level.rawValue,
                    mutationRevision: revision
                )
            )
            try await self.recordIdempotency(envelope: envelope, commandName: commandName, receipt: receipt)
            return receipt
        }
    }

    // MARK: - 身份与风险

    /// GUI 主动点击且当前没有 GUI Session 时的归属 Session。
    /// 权限引擎要求一个 sessionID；用一个稳定的合成值，而不是借用某个 Agent 的 Session。
    static let guiSessionID = SessionID("gui")

    static func gitResourceLabel(_ request: GitRequest) -> String {
        let targets = request.paths.isEmpty ? [request.reference, request.branch, request.message].compactMap { $0 } : request.paths
        return targets.prefix(4).joined(separator: ", ")
    }
}

extension GitQueryRequest {
    /// 结构化读参数 → 权威动作模型。RPC 不传 argv，转换只发生在这里。
    func gitRequest(action: GitAction) -> GitRequest {
        GitRequest(action: action, paths: paths, reference: reference, limit: limit, workingDirectory: workingDirectory)
    }
}

extension GitMutationRequest {
    func gitRequest(action: GitAction) -> GitRequest {
        GitRequest(
            action: action,
            paths: paths,
            reference: reference,
            branch: branch,
            message: message,
            createBranch: createBranch,
            force: force,
            stagedOnly: stagedOnly,
            all: all,
            remote: remote,
            prune: prune,
            setUpstream: setUpstream,
            workingDirectory: workingDirectory
        )
    }
}

extension CommandEnvelope where Payload == GitRemoteRequest {
    /// 远程动作的参数比本地多 remote / prune / setUpstream，其余身份与协调字段完全一致：
    /// 映射成一个内部 mutation request，让 mutation 路径保持单一。
    func mapped(to action: GitAction) -> CommandEnvelope<GitMutationRequest> {
        CommandEnvelope<GitMutationRequest>(
            commandID: commandID,
            issuedAt: issuedAt,
            expectedRevision: expectedRevision,
            payload: GitMutationRequest(
                sessionID: payload.sessionID,
                toolCallID: payload.toolCallID,
                reference: payload.reference,
                branch: payload.branch,
                remote: payload.remote,
                prune: payload.prune,
                setUpstream: payload.setUpstream,
                workingDirectory: payload.workingDirectory
            )
        )
    }
}
