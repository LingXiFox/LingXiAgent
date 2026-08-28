import Foundation
import Testing
@testable import LingXiProtocol

struct WireCodableTests {
    private func roundtrip(_ message: WireMessage) throws -> WireMessage {
        let data = try JSONEncoder().encode(message)
        return try JSONDecoder().decode(WireMessage.self, from: data)
    }

    @Test func requestRoundtrip() throws {
        for command in [ClientCommand.ping, .getInfo, .getState, .openTestStream] {
            let decoded = try roundtrip(.request(id: "7", command: command))
            #expect(decoded == .request(id: "7", command: command))
        }
    }

    @Test func responseRoundtrip() throws {
        let info = CoreInfo(name: "LingXiCore", version: "0.1.0", protocolVersion: "1")
        let cases: [CoreResponse] = [
            .pong,
            .info(info),
            .state(.ready),
            .streamOpened(StreamID("s-1")),
            .error(CoreError(code: .notReady, message: "未就绪")),
        ]
        for response in cases {
            let decoded = try roundtrip(.response(id: "3", response: response))
            #expect(decoded == .response(id: "3", response: response))
        }
    }

    @Test func eventRoundtrip() throws {
        #expect(try roundtrip(.event(.stateChanged(.shuttingDown))) == .event(.stateChanged(.shuttingDown)))
    }

    @Test func chunkRoundtrip() throws {
        let chunk = StreamChunk(streamID: StreamID("s-1"), index: 2, text: "DMA")
        #expect(try roundtrip(.chunk(chunk)) == .chunk(chunk))
    }

    @Test func dataPlaneFlag() {
        #expect(ClientCommand.openTestStream.isDataPlane)
        #expect(!ClientCommand.ping.isDataPlane)
    }
}
