import Foundation
@testable import LingXiCore

enum VCRMode: String, Sendable, Codable {
    case record
    case replay
}

enum VCRReplayTiming: String, Sendable, Codable {
    case instant
    case timed
}

struct CassetteMismatch: Error, Sendable, Equatable, CustomStringConvertible {
    let message: String
    var description: String { "CassetteMismatch: \(message)" }
}

struct VCRCassetteManifest: Sendable, Codable, Equatable {
    let cassetteVersion: Int
    let createdAt: String
    let lingXiVersion: String
    let lingXiCommit: String
    let wire: ModelWireProtocol
    let modelAlias: String
    let scenario: String
    let sanitizationVersion: Int
    let contextProfile: ModelContextProfile

    init(wire: ModelWireProtocol, modelAlias: String, scenario: String, lingXiCommit: String, contextProfile: ModelContextProfile = ModelContextProfile(contextWindowTokens: 128_000, maxOutputTokens: 4_096, recommendedOutputReserveTokens: 4_096, source: "vcr-manifest"), createdAt: String = ISO8601DateFormatter().string(from: Date())) {
        cassetteVersion = 1
        self.createdAt = createdAt
        lingXiVersion = CoreHost.coreVersion
        self.lingXiCommit = lingXiCommit
        self.wire = wire
        self.modelAlias = modelAlias
        self.scenario = scenario
        sanitizationVersion = 1
        self.contextProfile = contextProfile
    }
}

struct VCRWireChunk: Sendable, Codable, Equatable {
    let index: Int
    let offsetMilliseconds: Int
    let data: String
}

enum VCRStreamTermination: String, Sendable, Codable, Equatable {
    case completed
    case failed
}

struct VCRWireExchange: Sendable, Codable, Equatable {
    let sequence: Int
    let role: String
    let roleSequence: Int
    let step: Int
    let wire: ModelWireProtocol
    let model: String
    let requestFingerprint: String
    let normalizedRequest: String
    let requestHeaders: [String: String]
    let status: Int
    let responseHeaders: [String: String]
    let chunks: [VCRWireChunk]
    let terminalOffsetMilliseconds: Int
    let termination: VCRStreamTermination
}

struct VCRInteraction: Sendable, Codable, Equatable {
    let sequence: Int
    let fingerprint: String
    let originSession: String
    let originRun: String?
    let selectedOptionIndices: [Int]
    let text: String?
    let cancelled: Bool
}

struct VCRPreparedRequest: Sendable {
    let sequence: Int
    let role: String
    let roleSequence: Int
    let fingerprint: String
    let normalized: String
    let headers: [String: String]
}
