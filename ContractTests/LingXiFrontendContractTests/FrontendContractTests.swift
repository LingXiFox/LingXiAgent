import Foundation
import Testing
import LingXiProtocol
import LingXiClient

struct FrontendContractTests {

    @Test("Frontend client connection states adhere to protocol contracts")
    func frontendConnectionStates() {
        let v1_1 = ProtocolVersion(major: 1, minor: 1)
        let state = ConnectionState.connected(version: v1_1, capabilities: RuntimeCapabilities())
        #expect(state.status == .connected)
        #expect(state.protocolVersion == v1_1)
    }
}
