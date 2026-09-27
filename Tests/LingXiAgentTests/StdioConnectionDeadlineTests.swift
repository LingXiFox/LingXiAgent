import Foundation
import Testing
@testable import LingXiClient
@testable import LingXiProtocol

@Suite("Stdio Connection Request Deadline")
struct StdioConnectionDeadlineTests {

    /// One connection outcome the test can observe without awaiting the request itself.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?

        func set(_ value: String) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// A frame that decodes for real, addressed to an id no request is waiting on. Hand-written wire
    /// JSON here is how a test ends up asserting nothing because the line failed to parse; encoding a
    /// `WireMessage` is the same length and cannot drift from the codec.
    private static func unrelatedFrame() throws -> String {
        let message = WireMessage.response(id: "unrelated", response: .pong)
        return String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
    }

    /// A Core that never answers used to leave the caller parked forever: `failConnection` is only
    /// reached once the read loop sees EOF, and on Windows the reader can be starved of a
    /// cooperative-pool worker before it gets there. The wait now ends, with a reason.
    @Test("An unanswered request fails with a diagnosable error instead of hanging")
    func unansweredRequestHitsDeadline() async throws {
        let pipe = Pipe()
        // Writing into `pipe.fileHandleForWriting` goes to a reader that never answers.
        let connection = StdioConnection(input: pipe.fileHandleForWriting, timeoutSeconds: 1)
        let started = Date()
        do {
            _ = try await connection.send(.ping)
            Issue.record("expected the deadline to end the request")
        } catch let error as CoreError {
            let elapsed = Date().timeIntervalSince(started)
            #expect(error.code == .transport)
            #expect(error.message.contains("1s"), "message was: \(error.message)")
            #expect(elapsed >= 0.9 && elapsed < 10, "returned after \(elapsed)s")
        }
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }

    /// The deadline bounds silence, not work. `compactSession` really can take minutes on a live
    /// connection, and a fixed cap there would be a new defect dressed up as a timeout -- so the
    /// window only closes once nothing has arrived for it.
    @Test("A busy connection is not failed for being slow")
    func framesArrivingPostponeTheDeadline() async throws {
        let pipe = Pipe()
        let connection = StdioConnection(input: pipe.fileHandleForWriting, timeoutSeconds: 1)
        let outcome = Outcome()
        let sender = Task {
            do {
                _ = try await connection.send(.ping)
                outcome.set("answered")
            } catch {
                outcome.set("failed")
            }
        }
        defer { sender.cancel() }

        let frame = try Self.unrelatedFrame()
        var elapsedMs = 0
        while elapsedMs < 2_500 {
            try await Task.sleep(for: .milliseconds(300))
            await connection.handle(line: frame)
            elapsedMs += 300
            #expect(outcome.value == nil,
                    "the request ended after \(elapsedMs)ms of frames still arriving: \(outcome.value ?? "pending")")
        }

        // Silence from here, and the same one-second window must now be enough to end it.
        var waitedMs = 0
        while outcome.value == nil && waitedMs < 4_000 {
            try await Task.sleep(for: .milliseconds(200))
            waitedMs += 200
        }
        #expect(outcome.value == "failed",
                "after the frames stopped the request still had not been ended (waited \(waitedMs)ms, outcome \(outcome.value ?? "pending"))")
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }

    /// The double-resume guard: a response arriving after the deadline has already fired must not
    /// resume the same continuation a second time, which would trap the process.
    @Test("A late answer after the deadline does not resume twice")
    func lateAnswerIsIgnored() async throws {
        let pipe = Pipe()
        let connection = StdioConnection(input: pipe.fileHandleForWriting, timeoutSeconds: 1)
        do {
            _ = try await connection.send(.ping)
        } catch {
            // expected: the deadline
        }
        // The id the connection used first ("1"): before the claim existed this reached a continuation
        // that had already been resumed.
        await connection.handle(line: try Self.unrelatedFrame())
        await connection.handle(line: #"{"kind":"response","id":"1","response":"pong"}"#)
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}
