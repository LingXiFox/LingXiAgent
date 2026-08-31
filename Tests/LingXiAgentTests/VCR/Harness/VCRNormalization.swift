import Foundation
import LingXiProtocol
@testable import LingXiCore

struct VCRSanitizer: Sendable {
    let forbiddenSecrets: [String]
    let replacements: [(String, String)]

    init(forbiddenSecrets: [String] = [], workspaceRoot: URL? = nil) {
        self.forbiddenSecrets = forbiddenSecrets.filter { !$0.isEmpty }
        var values: [(String, String)] = []
        if let workspaceRoot { values.append((workspaceRoot.standardizedFileURL.path, "<workspace>")) }
        let home = NSHomeDirectory()
        if !home.isEmpty { values.append((home, "<home>")) }
        replacements = values.sorted { $0.0.count > $1.0.count }
    }

    func sanitize(_ value: String) throws -> String {
        try auditCredentials(value)
        let result = replacements.reduce(value) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        guard !replacements.contains(where: { result.contains($0.0) }) else {
            throw CassetteMismatch(message: "private filesystem path remains after sanitization")
        }
        return result
    }

    func audit(_ value: String) throws {
        try auditCredentials(value)
        for (path, _) in replacements where value.contains(path) {
            throw CassetteMismatch(message: "private filesystem path remains in cassette")
        }
    }

    private func auditCredentials(_ value: String) throws {
        if forbiddenSecrets.contains(where: { value.contains($0) }) {
            throw CassetteMismatch(message: "secret material reached cassette sanitization")
        }
        if value.lowercased().contains("bearer ") {
            throw CassetteMismatch(message: "credential-bearing field reached cassette sanitization")
        }
        let pattern = #"\"(?:[a-z0-9_-]*?(?:api[_-]?key|access[_-]?token|client[_-]?secret|password|authorization|cookie|set-cookie))\"\s*:"#
        if try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]).firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil {
            throw CassetteMismatch(message: "credential-bearing field reached cassette sanitization")
        }
    }
}

struct VCRNormalizer {
    enum Mode: Sendable {
        case record
        case replay
    }

    let mode: Mode
    private var identifiers: [String: [String: String]] = [:]
    private let sanitizer: VCRSanitizer
    private let modelAlias: String

    init(mode: Mode = .replay, sanitizer: VCRSanitizer, modelAlias: String) {
        self.mode = mode
        self.sanitizer = sanitizer
        self.modelAlias = modelAlias
    }

    mutating func role(for executionID: AgentRunID?) -> String {
        guard let executionID else { return "anonymous" }
        return token("run", executionID.rawValue)
    }

    mutating func session(for sessionID: SessionID?) -> String {
        guard let sessionID else { return "none" }
        return token("session", sessionID.rawValue)
    }

    mutating func bindRun(_ executionID: AgentRunID?, to role: String) {
        guard let executionID else { return }
        identifiers["run", default: [:]][executionID.rawValue] = role
    }

    mutating func unbindRun(_ executionID: AgentRunID?) {
        guard let executionID else { return }
        identifiers["run"]?.removeValue(forKey: executionID.rawValue)
    }

    mutating func bindSession(_ sessionID: SessionID?, to role: String) {
        guard let sessionID else { return }
        identifiers["session", default: [:]][sessionID.rawValue] = role
    }

    func denormalizeResponseChunk(_ value: String) -> Data {
        let replacements = ["run", "session", "uuid"].flatMap { identifiers[$0] ?? [:] }.sorted { $0.value.count > $1.value.count }
        return Data(replacements.reduce(value) { partial, pair in
            partial.replacingOccurrences(of: pair.value, with: pair.key)
        }.utf8)
    }

    func sanitizeExternalText(_ value: String?) throws -> String? {
        try value.map(sanitizer.sanitize)
    }

    mutating func normalizeRequest(_ request: URLRequest, context: ProviderHTTPRequestContext) throws -> (String, String, [String: String]) {
        let bodyObject: Any
        if let bodyData = request.httpBody, !bodyData.isEmpty {
            bodyObject = try JSONSerialization.jsonObject(with: bodyData)
        } else {
            bodyObject = NSNull()
        }
        let object: [String: Any] = [
            "body": bodyObject,
            "method": request.httpMethod ?? "POST",
            "path": "<\(context.wireProtocol.rawValue)-endpoint>",
        ]
        let normalized = try canonicalJSON(normalize(object, key: nil, parent: nil))
        let fingerprint = sha256Hex("\(context.wireProtocol.rawValue)|\(modelAlias)|\(normalized)")
        return (normalized, fingerprint, try filteredHeaders(request.allHTTPHeaderFields ?? [:], response: false))
    }

    func renormalizeRequest(_ value: String, wire: ModelWireProtocol) throws -> (String, String) {
        let object = try JSONSerialization.jsonObject(with: Data(value.utf8))
        var questionIDs: [String: String] = [:]
        let normalized = try canonicalJSON(normalizeStoredIdentifiers(object, key: nil, questionIDs: &questionIDs))
        return (normalized, sha256Hex("\(wire.rawValue)|\(modelAlias)|\(normalized)"))
    }

    mutating func normalizeResponseChunk(_ data: Data, contentType: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CassetteMismatch(message: "provider response was not UTF-8")
        }
        if contentType.lowercased().contains("text/event-stream") {
            let hadTrailingNewline = text.hasSuffix("\n")
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for index in lines.indices {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data:") else { continue }
                let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]", payload.first == "{" || payload.first == "[" else { continue }
                lines[index] = "data: \(try normalizeJSONData(Data(payload.utf8)))"
            }
            var result = lines.joined(separator: "\n")
            if hadTrailingNewline, !result.hasSuffix("\n") { result += "\n" }
            return try sanitizer.sanitize(result)
        }
        if let first = text.first, first == "{" || first == "[" {
            return try normalizeJSONData(data)
        }
        return try sanitizer.sanitize(text)
    }

    mutating func normalizeHeaders(_ headers: [String: String], response: Bool) throws -> [String: String] {
        try filteredHeaders(headers, response: response)
    }

    mutating func questionFingerprint(_ request: QuestionRequest) throws -> String {
        let value: [String: Any] = [
            "question": request.question,
            "options": request.options,
            "multiple": request.allowsMultiple,
            "freeText": request.allowsFreeText,
        ]
        let normalized = try canonicalJSON(normalize(value, key: nil, parent: nil))
        return sha256Hex(normalized)
    }

    private mutating func filteredHeaders(_ headers: [String: String], response: Bool) throws -> [String: String] {
        let allowed = response
            ? ["content-type", "x-request-id", "openai-request-id", "request-id", "cf-ray"]
            : ["content-type", "accept", "anthropic-version"]
        var result: [String: String] = [:]
        for (name, value) in headers where allowed.contains(name.lowercased()) {
            let key = name.lowercased()
            result[key] = try sanitizer.sanitize(key.contains("request-id") || key == "cf-ray" ? token("request", value) : value)
        }
        return result
    }

    private mutating func normalizeJSONData(_ data: Data) throws -> String {
        let value = try JSONSerialization.jsonObject(with: data)
        return try canonicalJSON(normalize(value, key: nil, parent: nil))
    }

    private mutating func normalize(_ value: Any, key: String?, parentKey: String? = nil, parent: [String: Any]?) throws -> Any {
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for name in object.keys.sorted() where !isCredentialKey(name) {
                result[name] = try normalize(object[name]!, key: name, parentKey: key, parent: object)
            }
            return result
        }
        if let array = value as? [Any] {
            return try array.map { try normalize($0, key: key, parentKey: parentKey, parent: parent) }
        }
        let effectiveKey = (key?.lowercased() == "rawvalue" || key?.lowercased() == "raw_value") ? (parentKey ?? key) : key
        if value is NSNumber, let effectiveKey, isTimestamp(effectiveKey) {
            return 0
        }
        guard let string = value as? String else { return value }
        if !string.isEmpty, let effectiveKey, ["model", "modelid"].contains(effectiveKey.replacingOccurrences(of: "_", with: "").lowercased()) { return modelAlias }
        if let effectiveKey, isTimestamp(effectiveKey) { return "<timestamp>" }
        if let effectiveKey, ["encrypted_content", "signature"].contains(effectiveKey.lowercased()) {
            let clean: String
            if string.hasPrefix("<opaque-") && string.hasSuffix(">") {
                clean = String(string.dropFirst("<opaque-".count).dropLast())
            } else {
                clean = string
            }
            return "<opaque-\(token("opaque", clean))>"
        }
        if !string.isEmpty, let category = identifierCategory(key: effectiveKey, value: string, parent: parent) {
            return token(category, string)
        }
        if (string.hasPrefix("{") || string.hasPrefix("[")), let data = string.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
            return try canonicalJSON(normalize(json, key: nil, parent: nil))
        }
        let sanitized = try sanitizer.sanitize(string)
        let identifiersApplied = identifiers.values.flatMap { $0 }.sorted { $0.key.count > $1.key.count }.reduce(sanitized) { partial, pair in
            partial.replacingOccurrences(of: pair.key, with: pair.value)
        }
        return replaceUUIDs(identifiersApplied)
    }

    private mutating func replaceUUIDs(_ value: String) -> String {
        guard value.contains("-") else { return value }
        let pattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        let regex = try? NSRegularExpression(pattern: pattern)
        guard let regex else { return value }
        var result = value
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed()
        for match in matches {
            guard let range = Range(match.range, in: value) else { continue }
            let token = self.token("uuid", String(value[range]))
            result.replaceSubrange(range, with: token)
        }
        return result
    }

    private func identifierCategory(key: String?, value: String, parent: [String: Any]?) -> String? {
        guard let rawKey = key else { return nil }
        let key = rawKey.replacingOccurrences(of: "_", with: "").lowercased()
        if ["callid", "toolcallid", "tooluseid"].contains(key) { return "call" }
        if ["itemid"].contains(key) { return "item" }
        if ["sessionid", "childsessionid", "originsessionid", "rootsessionid"].contains(key) { return "session" }
        if ["runid", "agentrunid", "executionid", "parentrunid", "rootrunid", "originrunid"].contains(key) { return "run" }
        if key == "questionid" { return "question" }
        if ["projectid"].contains(key) { return "project" }
        if ["previousresponseid", "responseid"].contains(key) { return "response" }
        if key == "id" {
            let type = (parent?["type"] as? String)?.lowercased()
            if type == "function_call" || type == "tool_use" { return "item" }
            if value.hasPrefix("resp_") || value.hasPrefix("response_") { return "response" }
            if value.range(of: "^[0-9a-fA-F]{8,64}$", options: .regularExpression) != nil { return "hash" }
        }
        return nil
    }

    private func isTimestamp(_ key: String) -> Bool {
        let key = key.lowercased()
        return key.contains("timestamp") || key == "created_at" || key == "updated_at"
            || ["startedat", "finishedat", "latestactivityat", "lastseen"].contains(key)
    }

    private func isCredentialKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return normalized.contains("api_key") || normalized.contains("apikey") || normalized.contains("access_token") || normalized.contains("accesstoken") || normalized.contains("client_secret") || normalized.contains("clientsecret") || ["password", "authorization", "cookie", "set_cookie"].contains(normalized)
    }

    private func isCanonicalToken(category: String, value: String) -> Bool {
        guard value.hasPrefix("\(category)-") else { return false }
        let suffix = value.dropFirst(category.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    private func normalizeStoredIdentifiers(_ value: Any, key: String?, questionIDs: inout [String: String]) throws -> Any {
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for name in object.keys.sorted() { result[name] = try normalizeStoredIdentifiers(object[name]!, key: name, questionIDs: &questionIDs) }
            return result
        }
        if let array = value as? [Any] {
            var result: [Any] = []
            for item in array { result.append(try normalizeStoredIdentifiers(item, key: key, questionIDs: &questionIDs)) }
            return result
        }
        guard let string = value as? String else { return value }
        if let key {
            let normalizedKey = key.replacingOccurrences(of: "_", with: "").lowercased()
            if !string.isEmpty, ["model", "modelid"].contains(normalizedKey) { return modelAlias }
            if !string.isEmpty, normalizedKey == "questionid" {
                if let existing = questionIDs[string] { return existing }
                let token = "question-\(questionIDs.count + 1)"
                questionIDs[string] = token
                return token
            }
        }
        if (string.hasPrefix("{") || string.hasPrefix("[")), let data = string.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
            return try canonicalJSON(normalizeStoredIdentifiers(json, key: nil, questionIDs: &questionIDs))
        }
        return string
    }

    private mutating func token(_ category: String, _ value: String) -> String {
        if let existing = identifiers[category]?[value] { return existing }

        switch mode {
        case .record:
            let nextIndex = (identifiers[category]?.count ?? 0) + 1
            let result = "\(category)-\(nextIndex)"
            identifiers[category, default: [:]][value] = result
            return result

        case .replay:
            if isCanonicalToken(category: category, value: value) {
                identifiers[category, default: [:]][value] = value
                return value
            }
            let nextIndex = (identifiers[category]?.count ?? 0) + 1
            let result = "\(category)-\(nextIndex)"
            identifiers[category, default: [:]][value] = result
            return result
        }
    }


    private func canonicalJSON(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
