import Foundation
import Testing
@testable import LingXiClient
@testable import LingXiProtocol

@Suite("VNext Stdio Transport Request Deadline")
struct VNextStdioTransportDeadlineTests {
    /// This is the transport the shipped frontends actually use, so the same bound that
    /// `StdioConnection` learned applies here too: a CoreHost that never answers used to leave
    /// `serve` waiting inside the cold-start handshake, which is before it binds a port, so the
    /// operator saw a server that never appeared rather than a Core that never replied.
    @Test("an unanswered handshake fails with a diagnosable error instead of hanging")
    func unansweredHandshakeHitsDeadline() async throws {
        let toCore = Pipe()
        let fromCore = Pipe()
        let transport = VNextStdioTransport(
            inputHandle: toCore.fileHandleForWriting,
            outputPipe: fromCore,
            timeoutSeconds: 1
        )
        let started = Date()
        do {
            try await transport.connect()
            Issue.record("expected the deadline to end the handshake")
        } catch let error as CoreError {
            let elapsed = Date().timeIntervalSince(started)
            #expect(error.code == .transport)
            #expect(error.message.contains("1s"), "message was: \(error.message)")
            #expect(elapsed >= 0.9 && elapsed < 10, "returned after \(elapsed)s")
        }

        // Deliberately no check that the request bytes arrived: a blocking read on a pipe whose write
        // end the transport still owns waits forever, which is the very shape this test is about. The
        // round trip through a real CoreHost is covered by the VNext stdio suites.

        try? toCore.fileHandleForReading.close()
        try? fromCore.fileHandleForReading.close()
        try? fromCore.fileHandleForWriting.close()
    }
}
