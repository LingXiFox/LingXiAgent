import Foundation
import LingXiProtocol

/// LingXiACPServer: Agent Client Protocol (ACP) 服务端驱动器。
/// 专为 Zed IDE、JetBrains IDE 等支持 ACP 标准的外部编辑器提供挂载与流式交互。
public actor LingXiACPServer {
    private let service: any LingXiProtocolService
    private var isRunning = false
    private var activeSessions: Set<String> = []

    public init(service: any LingXiProtocolService) {
        self.service = service
    }

    /// 真实运行于 Stdio 管道的主循环
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async throws {
        isRunning = true
        var buffer = Data()

        while isRunning {
            let chunk = input.availableData
            if chunk.isEmpty {
                // EOF 外部编辑器断开管道
                break
            }
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.subdata(in: 0..<newlineIndex)
                buffer.removeSubrange(0...newlineIndex)

                guard !lineData.isEmpty else { continue }
                if let req = try? JSONDecoder().decode(ACPRequest.self, from: lineData) {
                    await handleRequest(req, output: output)
                }
            }
        }
    }

    /// 停止服务端主循环
    public func stop() {
        isRunning = false
    }

    /// 分发单个 ACP 请求
    public func handleRequest(_ request: ACPRequest, output: FileHandle) async {
        do {
            switch request.method {
            case "initialize":
                let res = ACPInitializeResult(
                    agentInfo: ACPAgentInfo(name: "LingXiAgent", version: "1.0.0"),
                    capabilities: ACPAgentCapabilities(modes: ["default", "architect", "code"], loadSession: true, streaming: true),
                    protocolVersion: ACPSpecRevision.modern
                )
                try sendResult(id: request.id, result: res, output: output)

            case "session/new":
                guard let params = try request.decodeParams(as: ACPSessionNewParams.self) else {
                    throw ACPError(code: -32602, message: "Missing session/new params")
                }
                let envelope = CommandEnvelope(payload: CreateSessionRequest(workspace: params.cwd))
                let receipt = try await service.createSession(envelope: envelope)
                guard let summary = receipt.result else {
                    throw ACPError(code: -32603, message: "Failed to create session")
                }
                let sid = summary.sessionID.rawValue
                activeSessions.insert(sid)
                let res = ACPSessionNewResult(sessionId: sid)
                try sendResult(id: request.id, result: res, output: output)

            case "session/load":
                guard let params = try request.decodeParams(as: ACPSessionNewParams.self) else {
                    throw ACPError(code: -32602, message: "Missing session/load params")
                }
                let envelope = QueryEnvelope(payload: GetSessionRequest(sessionID: SessionID(params.cwd)))
                let resp = try await service.getSession(envelope: envelope)
                let sid = resp.payload.sessionID.rawValue
                activeSessions.insert(sid)
                try sendResult(id: request.id, result: ACPSessionNewResult(sessionId: sid), output: output)

            case "session/cancel":
                guard let params = try request.decodeParams(as: ACPSessionCancelParams.self) else {
                    throw ACPError(code: -32602, message: "Missing session/cancel params")
                }
                let sid = SessionID(params.sessionId)
                if let snap = try? await service.getSessionSnapshot(envelope: QueryEnvelope(payload: GetSessionSnapshotRequest(sessionID: sid))).payload {
                    if let run = snap.activeRootRun {
                        _ = try? await service.cancelRun(envelope: CommandEnvelope(payload: CancelRunRequest(sessionID: sid, runID: run.runID)))
                    }
                    if let lastTurn = snap.recentTurns.last, lastTurn.status == .running || lastTurn.status == .queued {
                        _ = try? await service.cancelTurn(envelope: CommandEnvelope(payload: CancelTurnRequest(sessionID: sid, turnID: lastTurn.turnID)))
                    }
                }
                try sendResult(id: request.id, result: ["cancelled": true], output: output)

            case "session/prompt":
                guard let params = try request.decodeParams(as: ACPSessionPromptParams.self) else {
                    throw ACPError(code: -32602, message: "Missing session/prompt params")
                }
                let sid = SessionID(params.sessionId)

                // 启动后台流式事件监听并实时推送 session/update 通知
                let streamTask = Task {
                    do {
                        let stream = try await service.subscribeSessionEvents(sessionID: sid, after: nil)
                        for await envelope in stream {
                            let event = envelope.payload
                            let updatePayload: ACPSessionUpdatePayload?
                            switch event {
                            case let .turnCreated(turn):
                                updatePayload = ACPSessionUpdatePayload(type: "state_change", content: "turnCreated:\(turn.turnID.rawValue)")
                            case let .assistantMessageCommitted(_, content, _):
                                updatePayload = ACPSessionUpdatePayload(type: "agent_message_chunk", content: content)
                            case let .toolRequested(inv):
                                updatePayload = ACPSessionUpdatePayload(type: "tool_call", toolCallId: inv.callID.rawValue, name: inv.toolID.rawValue, arguments: inv.argumentsSummary)
                            case let .toolCompleted(callID, res, _, _):
                                updatePayload = ACPSessionUpdatePayload(type: "tool_result", toolCallId: callID.rawValue, output: res.preview ?? res.summary)
                            case .turnCompleted:
                                updatePayload = ACPSessionUpdatePayload(type: "state_change", content: "completed")
                            case let .turnFailed(_, err):
                                updatePayload = ACPSessionUpdatePayload(type: "state_change", content: "failed:\(err.message)")
                            default:
                                updatePayload = nil
                            }

                            if let updatePayload {
                                let updateNotification = try? ACPRequest(
                                    id: nil,
                                    method: "session/update",
                                    paramsPayload: ACPSessionUpdateParams(sessionId: params.sessionId, update: updatePayload)
                                )
                                if let updateNotification, let lineData = try? JSONEncoder().encode(updateNotification) {
                                    try? output.write(contentsOf: lineData)
                                    try? output.write(contentsOf: Data([UInt8(ascii: "\n")]))
                                }
                            }
                        }
                    } catch {
                        // 忽略流式断开
                    }
                }

                // 提交 Turn 运行
                let turnEnvelope = CommandEnvelope(payload: SubmitTurnRequest(
                    sessionID: sid,
                    input: UserInput(text: params.prompt)
                ))
                _ = try await service.submitTurn(envelope: turnEnvelope)
                streamTask.cancel()

                try sendResult(id: request.id, result: ACPSessionPromptResult(status: "completed"), output: output)

            default:
                let err = ACPError(code: -32601, message: "Method not found: \(request.method)")
                try sendError(id: request.id, error: err, output: output)
            }
        } catch let err as ACPError {
            try? sendError(id: request.id, error: err, output: output)
        } catch {
            let err = ACPError(code: -32603, message: "Internal error: \(error.localizedDescription)")
            try? sendError(id: request.id, error: err, output: output)
        }
    }

    private func sendResult<T: Encodable>(id: ACPID?, result: T, output: FileHandle) throws {
        let resp = try ACPResponse(id: id, resultPayload: result)
        let lineData = try JSONEncoder().encode(resp)
        try output.write(contentsOf: lineData)
        try output.write(contentsOf: Data([UInt8(ascii: "\n")]))
    }

    private func sendError(id: ACPID?, error: ACPError, output: FileHandle) throws {
        let resp = ACPResponse(id: id, result: nil, error: error)
        let lineData = try JSONEncoder().encode(resp)
        try output.write(contentsOf: lineData)
        try output.write(contentsOf: Data([UInt8(ascii: "\n")]))
    }
}
