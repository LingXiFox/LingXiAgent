import LingXiProtocol

/// 交互式问题的挂起答复表；QuestionTool 可通过 CoreHost.questions 使用它。
public actor QuestionRuntime {
    private struct Pending {
        let request: QuestionRequest
        let continuation: CheckedContinuation<QuestionReply, Error>?
        let onReply: (@Sendable (QuestionRequest, QuestionReply) async -> Void)?
    }

    public let interactive: Bool
    private var pending: [QuestionID: Pending] = [:]
    private var onQuestionAsked: (@Sendable (QuestionRequest) async -> Void)?

    public init(interactive: Bool = false) {
        self.interactive = interactive
    }

    public func setEventSink(_ sink: @escaping @Sendable (QuestionRequest) async -> Void) {
        onQuestionAsked = sink
    }

    public func ask(_ request: QuestionRequest) async throws -> QuestionReply {
        guard interactive else {
            throw CoreError(code: .questionUnavailable, message: "当前 Core 不支持交互式问题")
        }
        guard pending[request.questionID] == nil else {
            throw CoreError(code: .questionUnavailable, message: "问题 ID 已在等待答复: \(request.questionID.rawValue)")
        }
        let contextual = if let context = AgentExecutionContext.current {
            QuestionRequest(questionID: request.questionID, question: request.question, options: request.options, allowsMultiple: request.allowsMultiple, allowsFreeText: request.allowsFreeText, originSessionID: context.sessionID, originRunID: context.runID, rootSessionID: context.rootSessionID, parentSessionID: context.parentSessionID)
        } else { request }
        let observer = ToolExecutionContext.observer
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[contextual.questionID] = Pending(request: contextual, continuation: continuation, onReply: observer?.questionResolved)
                Task {
                    await observer?.questionAsked(contextual)
                    await onQuestionAsked?(contextual)
                }
            }
        } onCancel: {
            Task { await self.cancel(contextual.questionID) }
        }
    }

    /// Re-register a durable question after restart. Its reply resumes the owning scheduler, not a lost continuation.
    public func register(_ request: QuestionRequest, onReply: @escaping @Sendable (QuestionRequest, QuestionReply) async -> Void) {
        guard pending[request.questionID] == nil else { return }
        pending[request.questionID] = Pending(request: request, continuation: nil, onReply: onReply)
        Task { await onQuestionAsked?(request) }
    }

    public func reply(_ reply: QuestionReply) async throws {
        guard let waiting = pending[reply.questionID] else {
            throw CoreError(code: .questionUnavailable, message: "问题不存在或已结束: \(reply.questionID.rawValue)")
        }
        try validate(reply, for: waiting.request)
        pending.removeValue(forKey: reply.questionID)
        await waiting.onReply?(waiting.request, reply)
        waiting.continuation?.resume(returning: reply)
    }

    public func request(_ questionID: QuestionID) -> QuestionRequest? { pending[questionID]?.request }

    public func close() {
        for waiting in pending.values {
            waiting.continuation?.resume(throwing: CoreError(code: .questionUnavailable, message: "Core 已关闭"))
        }
        pending.removeAll()
    }

    private func cancel(_ questionID: QuestionID) {
        guard let waiting = pending.removeValue(forKey: questionID) else { return }
        waiting.continuation?.resume(throwing: CancellationError())
    }

    private func validate(_ reply: QuestionReply, for request: QuestionRequest) throws {
        if reply.cancelled {
            guard reply.selectedOptionIndices.isEmpty, reply.text == nil else {
                throw CoreError(code: .questionUnavailable, message: "取消答复不能包含选项或文本")
            }
            return
        }
        guard reply.selectedOptionIndices.allSatisfy({ request.options.indices.contains($0) }) else {
            throw CoreError(code: .questionUnavailable, message: "问题选项下标无效")
        }
        guard request.allowsMultiple || reply.selectedOptionIndices.count <= 1 else {
            throw CoreError(code: .questionUnavailable, message: "该问题不支持多选")
        }
        if let text = reply.text {
            guard request.allowsFreeText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CoreError(code: .questionUnavailable, message: "该问题不接受此文本答复")
            }
        }
        guard !reply.selectedOptionIndices.isEmpty || reply.text != nil else {
            throw CoreError(code: .questionUnavailable, message: "问题答复不能为空")
        }
    }
}
