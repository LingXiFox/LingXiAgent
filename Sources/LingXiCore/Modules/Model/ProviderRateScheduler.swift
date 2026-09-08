import Foundation
import LingXiProtocol

public struct ProviderRetryPolicy: Sendable, Equatable, Codable {
    public let maxRetries: Int
    public let initialDelayMilliseconds: Int
    public let maxDelayMilliseconds: Int
    public let jitterRatio: Double

    public init(maxRetries: Int = 5, initialDelayMilliseconds: Int = 2_000, maxDelayMilliseconds: Int = 30_000, jitterRatio: Double = 0.25) {
        self.maxRetries = max(0, maxRetries)
        self.initialDelayMilliseconds = max(0, initialDelayMilliseconds)
        self.maxDelayMilliseconds = max(initialDelayMilliseconds, maxDelayMilliseconds)
        self.jitterRatio = min(1, max(0, jitterRatio))
    }

    private enum CodingKeys: String, CodingKey { case maxRetries, initialDelayMilliseconds, maxDelayMilliseconds, jitterRatio }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxRetries: try values.decodeIfPresent(Int.self, forKey: .maxRetries) ?? 5,
            initialDelayMilliseconds: try values.decodeIfPresent(Int.self, forKey: .initialDelayMilliseconds) ?? 2_000,
            maxDelayMilliseconds: try values.decodeIfPresent(Int.self, forKey: .maxDelayMilliseconds) ?? 30_000,
            jitterRatio: try values.decodeIfPresent(Double.self, forKey: .jitterRatio) ?? 0.25
        )
    }
}

public struct ProviderRateLimits: Sendable, Equatable, Codable {
    public let tpm: Int?
    public let rpm: Int?
    public let maxConcurrentRequests: Int?
    public let retryPolicy: ProviderRetryPolicy

    public init(tpm: Int? = nil, rpm: Int? = nil, maxConcurrentRequests: Int? = nil, retryPolicy: ProviderRetryPolicy = ProviderRetryPolicy()) {
        self.tpm = tpm.flatMap { $0 > 0 ? $0 : nil }
        self.rpm = rpm.flatMap { $0 > 0 ? $0 : nil }
        self.maxConcurrentRequests = maxConcurrentRequests.flatMap { $0 > 0 ? $0 : nil }
        self.retryPolicy = retryPolicy
    }

    private enum CodingKeys: String, CodingKey { case tpm, rpm, maxConcurrentRequests, retryPolicy }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tpm: try values.decodeIfPresent(Int.self, forKey: .tpm),
            rpm: try values.decodeIfPresent(Int.self, forKey: .rpm),
            maxConcurrentRequests: try values.decodeIfPresent(Int.self, forKey: .maxConcurrentRequests),
            retryPolicy: try values.decodeIfPresent(ProviderRetryPolicy.self, forKey: .retryPolicy) ?? ProviderRetryPolicy()
        )
    }
}

public struct ProviderRateLimitError: Error, Sendable {
    public let statusCode: Int
    public let retryAfter: Duration?
    public let underlying: CoreError

    public init(statusCode: Int, retryAfter: Duration? = nil, underlying: CoreError) {
        self.statusCode = statusCode
        self.retryAfter = retryAfter
        self.underlying = underlying
    }

    static func from(statusCode: Int, headers: [String: String], body: String, underlying: CoreError) -> Error {
        let normalized = body.lowercased()
        let exhausted = statusCode == 429
            || normalized.contains("429001")
            || normalized.contains("inference tpm exhausted")
            || (normalized.contains("inference") && normalized.contains("tpm") && normalized.contains("exhaust"))
        guard exhausted else { return underlying }
        return ProviderRateLimitError(statusCode: statusCode, retryAfter: retryAfter(headers), underlying: underlying)
    }

    private static func retryAfter(_ headers: [String: String]) -> Duration? {
        if let value = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After-Ms") == .orderedSame })?.value.trimmingCharacters(in: .whitespacesAndNewlines), let milliseconds = Double(value), milliseconds >= 0 {
            return .milliseconds(Int(milliseconds))
        }
        guard let value = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = Double(value), seconds >= 0 { return .milliseconds(Int(seconds * 1_000)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return .milliseconds(max(0, Int(date.timeIntervalSinceNow * 1_000)))
    }
}

public struct ProviderRateMetrics: Sendable, Equatable {
    public let retryCount: Int
    public let rateWaitMilliseconds: Int
    public let rateLimit429Count: Int
}

actor ProviderRateScheduler {
    static let shared = ProviderRateScheduler()

    private struct Key: Hashable {
        let provider: String
        let model: String
        let account: String?
    }

    private struct Workload {
        let requestID: ModelRequestID
        let timestamp: Date
        let tokens: Int
    }

    private var workloads: [Key: [Workload]] = [:]
    private var active: [Key: Int] = [:]
    private var blockedUntil: [Key: Date] = [:]
    private var metrics: [ModelRequestID: ProviderRateMetrics] = [:]

    func admit(endpoint: ResolvedModelEndpoint, requestID: ModelRequestID, estimatedTokens: Int) async throws {
        let key = Key(provider: endpoint.providerID, model: endpoint.modelID.rawValue, account: endpoint.accountID)
        let limits = endpoint.rateLimits
        let clock = ContinuousClock()
        let started = clock.now
        while true {
            try Task.checkCancellation()
            prune(key)
            if let blocked = blockedUntil[key], blocked > .now {
                try await Task.sleep(for: .milliseconds(max(1, Int(blocked.timeIntervalSinceNow * 1_000))))
                continue
            }
            let current = workloads[key] ?? []
            let concurrent = active[key, default: 0]
            if concurrent < (limits.maxConcurrentRequests ?? .max),
               current.count < (limits.rpm ?? .max),
               canAdmitTokens(current, estimate: estimatedTokens, limit: limits.tpm) {
                workloads[key, default: []].append(Workload(requestID: requestID, timestamp: .now, tokens: estimatedTokens))
                active[key, default: 0] += 1
                let elapsed = started.duration(to: clock.now).components
                let waited = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
                if waited > 0 { addWait(requestID, milliseconds: Int(waited)) }
                return
            }
            try await Task.sleep(for: waitDuration(current, concurrent: concurrent, limits: limits, estimate: estimatedTokens))
        }
    }

    func release(endpoint: ResolvedModelEndpoint) {
        let key = Key(provider: endpoint.providerID, model: endpoint.modelID.rawValue, account: endpoint.accountID)
        active[key] = max(0, active[key, default: 0] - 1)
    }

    func recordRetry(requestID: ModelRequestID) {
        let current = metrics[requestID] ?? ProviderRateMetrics(retryCount: 0, rateWaitMilliseconds: 0, rateLimit429Count: 0)
        metrics[requestID] = ProviderRateMetrics(retryCount: current.retryCount + 1, rateWaitMilliseconds: current.rateWaitMilliseconds, rateLimit429Count: current.rateLimit429Count)
    }

    func recordRateLimit(endpoint: ResolvedModelEndpoint, requestID: ModelRequestID, cooldown: Duration) {
        let current = metrics[requestID] ?? ProviderRateMetrics(retryCount: 0, rateWaitMilliseconds: 0, rateLimit429Count: 0)
        metrics[requestID] = ProviderRateMetrics(retryCount: current.retryCount, rateWaitMilliseconds: current.rateWaitMilliseconds, rateLimit429Count: current.rateLimit429Count + 1)
        let components = cooldown.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let key = Key(provider: endpoint.providerID, model: endpoint.modelID.rawValue, account: endpoint.accountID)
        blockedUntil[key] = max(blockedUntil[key] ?? .distantPast, .now.addingTimeInterval(seconds))
    }

    func recordWait(requestID: ModelRequestID, duration: Duration) {
        let components = duration.components
        let milliseconds = Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
        if milliseconds > 0 { addWait(requestID, milliseconds: milliseconds) }
    }

    func recordUsage(endpoint: ResolvedModelEndpoint, requestID: ModelRequestID, usage: ModelUsage) {
        let actualTokens = [usage.inputTokens, usage.outputTokens, usage.reasoningTokens].compactMap { $0 }.reduce(0, +)
        guard actualTokens > 0 else { return }
        let key = Key(provider: endpoint.providerID, model: endpoint.modelID.rawValue, account: endpoint.accountID)
        workloads[key] = workloads[key, default: []].map {
            $0.requestID == requestID ? Workload(requestID: $0.requestID, timestamp: $0.timestamp, tokens: actualTokens) : $0
        }
    }

    func metrics(for requestID: ModelRequestID) -> ProviderRateMetrics {
        metrics[requestID] ?? ProviderRateMetrics(retryCount: 0, rateWaitMilliseconds: 0, rateLimit429Count: 0)
    }

    private func addWait(_ requestID: ModelRequestID, milliseconds: Int) {
        let current = metrics[requestID] ?? ProviderRateMetrics(retryCount: 0, rateWaitMilliseconds: 0, rateLimit429Count: 0)
        metrics[requestID] = ProviderRateMetrics(retryCount: current.retryCount, rateWaitMilliseconds: current.rateWaitMilliseconds + milliseconds, rateLimit429Count: current.rateLimit429Count)
    }

    private func prune(_ key: Key) {
        let cutoff = Date.now.addingTimeInterval(-60)
        workloads[key] = workloads[key, default: []].filter { $0.timestamp > cutoff }
        if (blockedUntil[key] ?? .distantPast) <= .now { blockedUntil[key] = nil }
    }

    private func canAdmitTokens(_ workloads: [Workload], estimate: Int, limit: Int?) -> Bool {
        guard let limit else { return true }
        return estimate > limit || workloads.reduce(0) { $0 + $1.tokens } + estimate <= limit
    }

    private func waitDuration(_ workloads: [Workload], concurrent: Int, limits: ProviderRateLimits, estimate: Int) -> Duration {
        if let maximum = limits.maxConcurrentRequests, concurrent >= maximum { return .milliseconds(10) }
        if let rpm = limits.rpm, workloads.count >= rpm, let oldest = workloads.map(\.timestamp).min() {
            return .milliseconds(max(1, Int(oldest.addingTimeInterval(60).timeIntervalSinceNow * 1_000)))
        }
        if let tpm = limits.tpm, estimate <= tpm {
            var total = workloads.reduce(0) { $0 + $1.tokens }
            for workload in workloads.sorted(by: { $0.timestamp < $1.timestamp }) where total + estimate > tpm {
                total -= workload.tokens
                if total + estimate <= tpm {
                    return .milliseconds(max(1, Int(workload.timestamp.addingTimeInterval(60).timeIntervalSinceNow * 1_000)))
                }
            }
        }
        return .milliseconds(10)
    }
}
