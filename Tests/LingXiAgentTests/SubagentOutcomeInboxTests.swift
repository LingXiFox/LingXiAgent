import Foundation
import Testing
import LingXiProtocol
import LingXiCore

/// The inbox is the only route by which an unclaimed child outcome reaches the session that
/// spawned it, so it must deliver exactly once and stay bounded.
@Suite("Subagent outcome inbox")
struct SubagentOutcomeInboxTests {
    @Test("recorded outcome is delivered once and then stays empty")
    func deliversOnce() async {
        let inbox = SubagentOutcomeInbox()
        let session = SessionID("inbox-\(UUID().uuidString)")

        await inbox.record(sessionID: session, text: "- run a1b2 status=completed: CHILD-7F3A")
        #expect(await inbox.peek(session) == ["- run a1b2 status=completed: CHILD-7F3A"])
        #expect(await inbox.drain(session).count == 1)
        #expect(await inbox.drain(session).isEmpty)
    }

    @Test("backlog keeps only the newest eight outcomes")
    func bounded() async {
        let inbox = SubagentOutcomeInbox()
        let session = SessionID("inbox-\(UUID().uuidString)")
        for index in 0..<20 {
            await inbox.record(sessionID: session, text: "outcome-\(index)")
        }

        let drained = await inbox.drain(session)
        #expect(drained.count == 8)
        #expect(drained.first == "outcome-12")
        #expect(drained.last == "outcome-19")
    }

    @Test("outcomes are keyed per owning session")
    func isolatedPerSession() async {
        let inbox = SubagentOutcomeInbox()
        let first = SessionID("inbox-a")
        let second = SessionID("inbox-b")
        await inbox.record(sessionID: first, text: "for-a")
        await inbox.record(sessionID: second, text: "for-b")

        #expect(await inbox.drain(first) == ["for-a"])
        #expect(await inbox.peek(second) == ["for-b"])
    }
}
