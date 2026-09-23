import Foundation
import Testing
import LingXiProtocol

struct EnumDecoderRobustnessTests {

    @Test("RunStatus decodes unknown string values to .unknown instead of throwing")
    func runStatusDecodesUnknownGracefully() throws {
        let json = #""some_future_status_from_v2""#
        let decoded = try JSONDecoder().decode(RunStatus.self, from: Data(json.utf8))
        #expect(decoded == .unknown)
        #expect(!decoded.isTerminal)
    }

    @Test("AgentMode decodes unknown string values to .unknown instead of throwing")
    func agentModeDecodesUnknownGracefully() throws {
        let json = #""autonomous_super_mode""#
        let decoded = try JSONDecoder().decode(AgentMode.self, from: Data(json.utf8))
        #expect(decoded == .unknown)
        #expect(decoded.displayName == "Unknown")
    }

    @Test("ProtocolFeature decodes unknown string values to .unknown instead of throwing")
    func protocolFeatureDecodesUnknownGracefully() throws {
        let json = #""experimental.quantum_leap""#
        let decoded = try JSONDecoder().decode(ProtocolFeature.self, from: Data(json.utf8))
        #expect(decoded == .unknown)
    }

    @Test("RuntimeTraceKind decodes unknown string values to .unknown instead of throwing")
    func runtimeTraceKindDecodesUnknownGracefully() throws {
        let json = #""actionFlow_v2""#
        let decoded = try JSONDecoder().decode(RuntimeTraceKind.self, from: Data(json.utf8))
        #expect(decoded == .unknown)
    }

    @Test("Standard known cases decode to their exact enum values")
    func knownCasesDecodeCorrectly() throws {
        let runStatusJSON = #""running""#
        #expect(try JSONDecoder().decode(RunStatus.self, from: Data(runStatusJSON.utf8)) == .running)

        let agentModeJSON = #""build""#
        #expect(try JSONDecoder().decode(AgentMode.self, from: Data(agentModeJSON.utf8)) == .build)

        let featureJSON = #""task.pause""#
        #expect(try JSONDecoder().decode(ProtocolFeature.self, from: Data(featureJSON.utf8)) == .taskPause)
    }
}
