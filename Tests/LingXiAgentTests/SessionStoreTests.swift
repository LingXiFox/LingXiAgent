import Foundation
import Testing
@testable import LingXiCore
import LingXiProtocol

/// InMemorySessionStore：领域行为与隔离性。
struct SessionStoreTests {
    private func makeStore() -> any SessionStore {
        InMemorySessionStore()
    }

    @Test func createSessionStartsEmpty() async throws {
        let store = makeStore()
        let session = try await store.create()
        #expect(session.messages.isEmpty)
        let loaded = try await store.session(session.id)
        #expect(loaded.id == session.id)
        #expect(loaded.messages.isEmpty)
    }

    @Test func appendPreservesOrder() async throws {
        let store = makeStore()
        let session = try await store.create()
        try await store.appendMessage(session.id, role: .user, content: "第一")
        try await store.appendMessage(session.id, role: .assistant, content: "第二")
        try await store.appendMessage(session.id, role: .user, content: "第三")

        let loaded = try await store.session(session.id)
        #expect(loaded.messages.map(\.content) == ["第一", "第二", "第三"])
        #expect(loaded.messages.map(\.role) == [.user, .assistant, .user])
        #expect(loaded.updatedAt >= loaded.createdAt)
    }

    @Test func sessionsAreIsolated() async throws {
        let store = makeStore()
        let a = try await store.create()
        let b = try await store.create()
        try await store.appendMessage(a.id, role: .user, content: "属于 A")
        try await store.appendMessage(b.id, role: .user, content: "属于 B")

        let loadedA = try await store.session(a.id)
        let loadedB = try await store.session(b.id)
        #expect(loadedA.messages.map(\.content) == ["属于 A"])
        #expect(loadedB.messages.map(\.content) == ["属于 B"])
    }

    @Test func unknownSessionThrows() async {
        do {
            _ = try await makeStore().session(SessionID("nope"))
            Issue.record("应抛 sessionNotFound")
        } catch let error as CoreError {
            #expect(error.code == .sessionNotFound)
        } catch {
            Issue.record("错误类型应为 CoreError")
        }
    }

    @Test func listSessionsReturnsAll() async throws {
        let store = makeStore()
        _ = try await store.create()
        _ = try await store.create()
        let sessions = try await store.listSessions()
        #expect(sessions.count == 2)
    }
}
