import Foundation
import Testing
import LingXiProtocol
import LingXiPlatform

struct IPCRobustnessContractTests {

    @Test("ProtocolConstants define max frame size to prevent OOM DOS attacks")
    func maxFrameSizeContract() {
        #expect(ProtocolConstants.maxFrameBytes == 32 * 1024 * 1024)
        #expect(ProtocolConstants.maxFrameBytes > 1024 * 1024)
    }
}
