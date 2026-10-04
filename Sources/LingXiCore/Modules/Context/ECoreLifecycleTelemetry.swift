import Foundation
import LingXiProtocol

public struct ECoreLifecycleEvent: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case pageOutAttempt, pageOutNew, pageOutDeduplicated
        case recallRequested, recallResolved, recallAdmitted, recallRejected
    }
    public let phase: Phase
    public let referenceID: String?
    public let reason: String?
}

public struct ECoreLifecycleSnapshot: Sendable {
    public var pageOutAttempt = 0, pageOutNew = 0, pageOutDeduplicated = 0
    public var recallRequested = 0, recallResolved = 0, recallAdmitted = 0, recallRejected = 0
    public var events: [ECoreLifecycleEvent] = []
    mutating func record(_ event: ECoreLifecycleEvent) {
        switch event.phase {
        case .pageOutAttempt: pageOutAttempt += 1
        case .pageOutNew: pageOutNew += 1
        case .pageOutDeduplicated: pageOutDeduplicated += 1
        case .recallRequested: recallRequested += 1
        case .recallResolved: recallResolved += 1
        case .recallAdmitted: recallAdmitted += 1
        case .recallRejected: recallRejected += 1
        }
        events.append(event)
        if events.count > 256 { events.removeFirst(events.count - 256) }
    }
}
