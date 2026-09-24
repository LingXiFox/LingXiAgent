import Foundation
import LingXiProtocol

public struct MultiRunDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func compare(
        prompt: String,
        modelIDs: [String],
        systemPrompt: String? = nil
    ) async throws -> MultiRunCompareResult {
        let req = MultiRunCompareRequest(prompt: prompt, modelIDs: modelIDs, systemPrompt: systemPrompt)
        let resp = try await transport.compareMultiRuns(envelope: CommandEnvelope(payload: req))
        return resp.result ?? MultiRunCompareResult(runs: [:])
    }

}
