import Foundation
import LingXiProtocol
@testable import LingXiCore

actor VCRCassetteStore {
    private let directory: URL
    private let providerFile: URL
    private let interactionsFile: URL
    private let manifest: VCRCassetteManifest
    private let sanitizer: VCRSanitizer
    private var normalizer: VCRNormalizer
    private var exchanges: [VCRWireExchange]
    private let comparableRequests: [Int: (normalized: String, fingerprint: String)]
    private var interactions: [VCRInteraction]
    private var consumedSequences = Set<Int>()
    private var reservedSequences = Set<Int>()
    private var reservationExecutions: [Int: String] = [:]
    private var consumedInteractionSequences = Set<Int>()
    private var boundRoles: [String: String] = [:]
    private var roleBindings: [String: String] = [:]
    private var boundSessions: [String: String] = [:]
    private var sessionBindings: [String: String] = [:]
    private var replayedRoleCounts: [String: Int] = [:]
    private var recordedRoleCounts: [String: Int] = [:]
    private var nextRecordingSequence: Int

    init(directory: URL, manifest: VCRCassetteManifest, forbiddenSecrets: [String] = [], workspaceRoot: URL? = nil, create: Bool) throws {
        self.directory = directory
        providerFile = directory.appendingPathComponent("provider.jsonl")
        interactionsFile = directory.appendingPathComponent("interactions.jsonl")
        self.manifest = manifest
        let sanitizer = VCRSanitizer(forbiddenSecrets: forbiddenSecrets, workspaceRoot: workspaceRoot)
        self.sanitizer = sanitizer
        normalizer = VCRNormalizer(mode: create ? .record : .replay, sanitizer: sanitizer, modelAlias: manifest.modelAlias)
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in [providerFile, interactionsFile] where (try? Data(contentsOf: file).isEmpty) == false {
                throw CassetteMismatch(message: "record output must not contain an existing cassette")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            if !FileManager.default.fileExists(atPath: providerFile.path) { try Data().write(to: providerFile) }
            if !FileManager.default.fileExists(atPath: interactionsFile.path) { try Data().write(to: interactionsFile) }
        }
        let loadedExchanges = try Self.readJSONL(VCRWireExchange.self, from: providerFile).sorted { $0.sequence < $1.sequence }
        exchanges = loadedExchanges
        let comparisonNormalizer = VCRNormalizer(mode: .replay, sanitizer: sanitizer, modelAlias: manifest.modelAlias)
        comparableRequests = Dictionary(uniqueKeysWithValues: try loadedExchanges.map { exchange in
            let request = try comparisonNormalizer.renormalizeRequest(exchange.normalizedRequest, wire: exchange.wire)
            return (exchange.sequence, (request.0, request.1))
        })
        interactions = try Self.readJSONL(VCRInteraction.self, from: interactionsFile)
        nextRecordingSequence = (exchanges.map(\.sequence).max() ?? 0) + 1
    }

    var hasChildExchanges: Bool {
        exchanges.contains { $0.role != "run-1" && $0.role != "run-2" && $0.role != "run-3" }
    }

    func prepareRecording(_ request: URLRequest, context: ProviderHTTPRequestContext) throws -> VCRPreparedRequest {
        let role = normalizer.role(for: context.executionID)
        let roleSequence = recordedRoleCounts[role, default: 0] + 1
        recordedRoleCounts[role] = roleSequence
        let normalized = try normalizer.normalizeRequest(request, context: context)
        defer { nextRecordingSequence += 1 }
        return VCRPreparedRequest(sequence: nextRecordingSequence, role: role, roleSequence: roleSequence, fingerprint: normalized.1, normalized: normalized.0, headers: normalized.2)
    }

    func normalizeRecordingChunk(_ data: Data, responseHeaders: [String: String]) throws -> String {
        let contentType = responseHeaders.first { $0.key.caseInsensitiveCompare("content-type") == .orderedSame }?.value ?? "application/json"
        return try normalizer.normalizeResponseChunk(data, contentType: contentType)
    }

    func record(
        prepared: VCRPreparedRequest,
        context: ProviderHTTPRequestContext,
        status: Int,
        responseHeaders: [String: String],
        chunks: [VCRWireChunk],
        terminalOffsetMilliseconds: Int,
        termination: VCRStreamTermination
    ) throws {
        let exchange = VCRWireExchange(
            sequence: prepared.sequence,
            role: prepared.role,
            roleSequence: prepared.roleSequence,
            step: context.step,
            wire: context.wireProtocol,
            model: manifest.modelAlias,
            requestFingerprint: prepared.fingerprint,
            normalizedRequest: prepared.normalized,
            requestHeaders: prepared.headers,
            status: status,
            responseHeaders: try normalizer.normalizeHeaders(responseHeaders, response: true),
            chunks: chunks,
            terminalOffsetMilliseconds: terminalOffsetMilliseconds,
            termination: termination
        )
        try append(exchange, to: providerFile)
        exchanges.append(exchange)
    }

    func replay(_ request: URLRequest, context: ProviderHTTPRequestContext) throws -> VCRWireExchange {
        guard context.model == manifest.modelAlias else {
            throw CassetteMismatch(message: "model=\(context.model) expected=\(manifest.modelAlias)")
        }
        let normalized = try normalizer.normalizeRequest(request, context: context)
        let execution = context.executionID?.rawValue ?? "anonymous"
        let boundRole = boundRoles[execution]
        let candidates = exchanges.filter { exchange in
            guard !consumedSequences.contains(exchange.sequence), !reservedSequences.contains(exchange.sequence),
                  exchange.wire == context.wireProtocol,
                  exchange.model == manifest.modelAlias,
                  exchange.step == context.step,
                  exchange.requestHeaders == normalized.2,
                  boundRole == nil || exchange.role == boundRole,
                  roleBindings[exchange.role] == nil || roleBindings[exchange.role] == execution,
                  let request = comparableRequests[exchange.sequence]
            else { return false }
            return request.fingerprint == normalized.1 && request.normalized == normalized.0
        }
        guard let match = candidates.min(by: { $0.sequence < $1.sequence }) else {
            let sameRole = exchanges.filter { $0.wire == context.wireProtocol && $0.step == context.step && $0.role == (boundRole ?? normalizer.role(for: context.executionID)) }
            let fingerprints = sameRole.map { "\($0.sequence):\($0.requestFingerprint.prefix(12))" }.joined(separator: ",")
            let difference = sameRole.first.flatMap { comparableRequests[$0.sequence].flatMap { Self.firstDifferencePath(recorded: $0.normalized, replayed: normalized.0) } } ?? "none"
            throw CassetteMismatch(message: "wire=\(context.wireProtocol.rawValue) step=\(context.step) role=\(boundRole ?? "unbound") fingerprint=\(normalized.1.prefix(12)) candidates=[\(fingerprints)] difference=\(difference)")
        }
        let expectedRoleSequence = replayedRoleCounts[match.role, default: 0] + 1
        guard match.roleSequence == expectedRoleSequence else {
            throw CassetteMismatch(message: "role=\(match.role) expected sequence=\(expectedRoleSequence) cassette sequence=\(match.roleSequence)")
        }
        boundRoles[execution] = match.role
        roleBindings[match.role] = execution
        normalizer.bindRun(context.executionID, to: match.role)
        replayedRoleCounts[match.role] = expectedRoleSequence
        reservedSequences.insert(match.sequence)
        reservationExecutions[match.sequence] = execution
        return match
    }

    func finishReplay(sequence: Int) {
        reservedSequences.remove(sequence)
        reservationExecutions.removeValue(forKey: sequence)
        consumedSequences.insert(sequence)
    }

    func cancelReplay(sequence: Int) {
        guard reservedSequences.remove(sequence) != nil,
              let execution = reservationExecutions.removeValue(forKey: sequence),
              let exchange = exchanges.first(where: { $0.sequence == sequence })
        else { return }
        let active = exchanges.filter { $0.role == exchange.role && (consumedSequences.contains($0.sequence) || reservedSequences.contains($0.sequence)) }
        replayedRoleCounts[exchange.role] = active.map(\.roleSequence).max() ?? 0
        if active.isEmpty {
            boundRoles.removeValue(forKey: execution)
            roleBindings.removeValue(forKey: exchange.role)
            normalizer.unbindRun(AgentRunID(execution))
        }
    }

    func answer(_ request: QuestionRequest, mode: VCRMode, scripted: QuestionReply?) throws -> QuestionReply {
        let fingerprint = try normalizer.questionFingerprint(request)
        switch mode {
        case .record:
            guard let scripted else { throw CassetteMismatch(message: "recording question has no deterministic answer") }
            let interaction = VCRInteraction(sequence: interactions.count + 1, fingerprint: fingerprint, originSession: normalizer.session(for: request.originSessionID), originRun: request.originRunID.map { normalizer.role(for: $0) }, selectedOptionIndices: scripted.selectedOptionIndices, text: try normalizer.sanitizeExternalText(scripted.text), cancelled: scripted.cancelled)
            try append(interaction, to: interactionsFile)
            interactions.append(interaction)
            return QuestionReply(questionID: request.questionID, selectedOptionIndices: scripted.selectedOptionIndices, text: scripted.text, cancelled: scripted.cancelled)
        case .replay:
            let actualRun = request.originRunID?.rawValue
            guard let runRole = actualRun.flatMap({ boundRoles[$0] }) else {
                throw CassetteMismatch(message: "question origin run is not bound to a provider role")
            }
            let actualSession = request.originSessionID?.rawValue ?? "none"
            let sessionRole = boundSessions[actualSession]
            let matches = interactions.filter {
                !consumedInteractionSequences.contains($0.sequence) && $0.fingerprint == fingerprint && $0.originRun == runRole &&
                (sessionRole == nil || $0.originSession == sessionRole) &&
                (sessionBindings[$0.originSession] == nil || sessionBindings[$0.originSession] == actualSession)
            }
            guard let interaction = matches.min(by: { $0.sequence < $1.sequence }) else {
                throw CassetteMismatch(message: "question interaction did not match")
            }
            boundSessions[actualSession] = interaction.originSession
            sessionBindings[interaction.originSession] = actualSession
            normalizer.bindSession(SessionID(actualSession), to: interaction.originSession)
            consumedInteractionSequences.insert(interaction.sequence)
            return QuestionReply(questionID: request.questionID, selectedOptionIndices: interaction.selectedOptionIndices, text: interaction.text, cancelled: interaction.cancelled)
        }
    }

    func assertFullyConsumed() throws {
        guard consumedSequences.count == exchanges.count else {
            throw CassetteMismatch(message: "consumed \(consumedSequences.count) of \(exchanges.count) provider exchanges")
        }
        guard consumedInteractionSequences.count == interactions.count else {
            throw CassetteMismatch(message: "consumed \(consumedInteractionSequences.count) of \(interactions.count) interactions")
        }
    }

    func replayChunk(_ value: String) -> Data {
        normalizer.denormalizeResponseChunk(value)
    }

    func audit() throws {
        for file in [directory.appendingPathComponent("manifest.json"), providerFile, interactionsFile] where FileManager.default.fileExists(atPath: file.path) {
            try sanitizer.audit(String(decoding: try Data(contentsOf: file), as: UTF8.self))
        }
    }

    private func append<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func readJSONL<T: Decodable>(_ type: T.Type, from file: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try String(decoding: Data(contentsOf: file), as: UTF8.self)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }

    private static func firstDifferencePath(recorded: String, replayed: String) -> String? {
        guard let left = try? JSONSerialization.jsonObject(with: Data(recorded.utf8)), let right = try? JSONSerialization.jsonObject(with: Data(replayed.utf8)) else { return "invalid-json" }
        return firstDifferencePath(left, right, path: "$")
    }

    private static func firstDifferencePath(_ left: Any, _ right: Any, path: String) -> String? {
        if String(describing: left) == String(describing: right) { return nil }
        if let left = left as? [String: Any], let right = right as? [String: Any] {
            for key in Set(left.keys).union(right.keys).sorted() {
                guard let a = left[key], let b = right[key] else { return "\(path).\(key)[recorded=\(left[key] != nil),replayed=\(right[key] != nil)]" }
                if let difference = firstDifferencePath(a, b, path: "\(path).\(key)") { return difference }
            }
            return nil
        }
        if let left = left as? [Any], let right = right as? [Any] {
            guard left.count == right.count else { return "\(path).count" }
            for index in left.indices {
                if let difference = firstDifferencePath(left[index], right[index], path: "\(path)[\(index)]") { return difference }
            }
            return nil
        }
        if let left = left as? String, let right = right as? String,
           let leftData = left.data(using: .utf8), let rightData = right.data(using: .utf8),
           let leftJSON = try? JSONSerialization.jsonObject(with: leftData), let rightJSON = try? JSONSerialization.jsonObject(with: rightData) {
            return firstDifferencePath(leftJSON, rightJSON, path: "\(path)<json>")
        }
        if let left = left as? String, let right = right as? String,
           [left, right].allSatisfy({ $0.hasPrefix("session-") || $0.hasPrefix("child-session-") || $0.hasPrefix("run-") }) {
            return "\(path)[\(left)!=\(right)]"
        }
        return String(describing: left) == String(describing: right) ? nil : "\(path)<\(type(of: left))!=\(type(of: right))>"
    }
}
