import Foundation
import Testing
import LingXiProtocol
import LingXiClient

struct VCRQuestionClient {
    let mode: VCRMode
    let cassette: VCRCassetteStore
    let selectedOptionIndices: [Int]
    var onAnswered: (@Sendable () async -> Void)? = nil

    init(mode: VCRMode, cassette: VCRCassetteStore, selectedOptionIndices: [Int], onAnswered: (@Sendable () async -> Void)? = nil) {
        self.mode = mode
        self.cassette = cassette
        self.selectedOptionIndices = selectedOptionIndices
        self.onAnswered = onAnswered
    }

    func run(_ client: LingXiClient) async -> Task<Void, Never> {
        let events = await client.events()
        return Task {
            for await event in events {
                let request: QuestionRequest
                switch event {
                case let .questionAsked(value), let .questionEscalated(value): request = value
                default: continue
                }
                let scripted = QuestionReply(questionID: request.questionID, selectedOptionIndices: selectedOptionIndices)
                do {
                    let reply = try await cassette.answer(request, mode: mode, scripted: mode == .replay ? nil : scripted)
                    try await client.replyQuestion(reply)
                    await onAnswered?()
                } catch {
                    Issue.record(error)
                    try? await client.replyQuestion(QuestionReply(questionID: request.questionID, cancelled: true))
                    return
                }
            }
        }
    }
}
