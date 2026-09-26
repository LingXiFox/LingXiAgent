import Foundation
import Testing
import LingXiProtocol
import LingXiApplication

/// §4.3 audit items that are about the *contract*, not about any one front end: a browser must
/// survive a Core that grows a new case, must survive fields it has never heard of, and must not
/// be able to reach a bind address the operator did not agree to.
@Suite("FrontendContractAuditTests")
struct FrontendContractAuditTests {

    // MARK: - Forward compatibility

    @Test("An event kind this build does not know decodes as .unknown instead of failing the stream")
    func unknownEventKindIsSafe() throws {
        let payload = try FrontendWire.makeDecoder().decode(
            SessionEventPayload.self,
            from: Data(#"{"kind":"quantumTunnelOpened","someBrandNewField":42}"#.utf8))
        #expect(payload == .unknown("quantumTunnelOpened"))

        // The same fact inside an envelope: one future event must not poison a replay.
        let envelope = try FrontendWire.makeDecoder().decode(
            SessionEventEnvelope.self,
            from: Data(#"""
            {"cursor":{"generationID":{"rawValue":"g1"},"sequence":7},
             "timestamp":700000000,
             "causal":{"sessionID":{"rawValue":"s1"}},
             "payload":{"kind":"quantumTunnelOpened"}}
            """#.utf8))
        #expect(envelope.payload == .unknown("quantumTunnelOpened"))
    }

    @Test("A state payload carrying fields this build has not seen still decodes")
    func extraStateKeysAreIgnored() throws {
        let session = SessionViewState(sessionID: SessionID("audit-session"))
        var json = try JSONSerialization.jsonObject(
            with: FrontendWire.makeEncoder().encode(session)) as? [String: Any]
        json?["futureSessionField"] = ["nested": 1]
        json?["goal"] = ["text": "from a future Core", "since": 1, "steps": 2]
        let rebuilt = try JSONSerialization.data(withJSONObject: json ?? [:])

        let decoded = try FrontendWire.makeDecoder().decode(SessionViewState.self, from: rebuilt)
        #expect(decoded.sessionID == session.sessionID)
        // A known field still wins over being ignored wholesale: the goal is part of the contract.
        #expect(decoded.goal?.text == "from a future Core")
    }

    // MARK: - Serve binding intent

    @Test("A non-loopback bind is refused unless the operator opts in explicitly")
    func remoteBindNeedsOptIn() {
        let remote = WebUIServeOptions(host: "10.0.0.5")
        #expect(!remote.isLoopbackHost)
        #expect(remote.bindHost == "10.0.0.5")
        #expect(WebUIServeOptions().isLoopbackHost)

        // The refusal itself lives in ServeCLI; here the contract is that `isLoopbackHost` is the
        // only thing that decides it, so a spelling cannot sneak past the gate.
        #expect(WebUIServeOptions(host: "localhost").isLoopbackHost)
        #expect(WebUIServeOptions(host: "0.0.0.0").isLoopbackHost == false, "all-interfaces is a remote bind")
        #expect(WebUIServeOptions(host: "192.168.1.7").isLoopbackHost == false)
    }

    @Test("Every loopback spelling binds and advertises the same reachable address")
    func loopbackSpellingsAgree() {
        for spelling in ["127.0.0.1", "localhost", "LOCALHOST", "::1", "[::1]"] {
            let options = WebUIServeOptions(host: spelling)
            #expect(options.bindHost == "127.0.0.1", "\(spelling) must bind to the v4 loopback")
            #expect(options.displayHost == "127.0.0.1",
                    "\(spelling) must advertise where it actually listens")
        }
    }
}
