import Foundation
import LingXiProtocol

/// 任务持久化服务协议
public protocol TaskPersistence: Sendable {
    func saveCapsule(_ capsule: TaskCapsule) async throws
    func loadCapsule(taskID: TaskID) async throws -> TaskCapsule?
    func listCapsules(sessionID: SessionID?) async throws -> [TaskCapsule]
    func recordEvent(taskID: TaskID, event: String, fromState: TaskState?, toState: TaskState, payload: [String: String]) async throws
    func loadEvents(taskID: TaskID) async throws -> [TaskEventPayload]
}
