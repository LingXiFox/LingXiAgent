import Foundation
import LingXiProtocol

// MARK: - Turn latency trace
//
// 「发出请求 → 上游首包」 used to be one number, so a slow image turn could not be told apart
// from a slow model: was it the upload, or the provider sitting on a request it already had?
// This records the turn's milestones from wherever they happen — attachment preparation, the
// agent loop, the HTTP transport — keyed by run id, and when the turn ends lays them out as
// per-phase and cumulative durations with the two cases the question is about kept apart:
//
//   A. upload  — request body (or a provider file upload) still on the wire
//   B. provider — body fully sent, waiting for the first response byte / first delta
//
// Nothing here changes behaviour; it only measures.

/// Milestones in the order a turn passes them. Raw values are what reports print.
public enum LatencyPhase: String, CaseIterable, Sendable {
    case attachmentSelected = "attachment_selected"
    case preprocessStarted = "preprocess_started"
    case preprocessDone = "preprocess_done"
    case uploadStarted = "upload_started"
    case uploadBodyDone = "upload_body_done"
    case providerFileReady = "provider_file_ready"
    case messageSendRequested = "message_send_requested"
    case attachmentsResolved = "attachments_resolved"
    case inferenceRequestStarted = "inference_request_started"
    case connectionReady = "connection_ready"
    case requestBodySent = "request_body_sent"
    case responseStart = "response_start"
    case firstReasoningDelta = "first_reasoning_delta"
    case firstTextDelta = "first_text_delta"
    case completed = "completed"
}

/// What the transport learned about one HTTP exchange.
public struct TransportTiming: Sendable, Equatable {
    public var requestStarted: Date?
    public var connectionReady: Date?
    public var bodySent: Date?
    public var responseStart: Date?
    public var requestBodyBytes: Int64 = 0
    public var reusedConnection: Bool?

    public init() {}
}

public actor TurnLatencyRecorder {
    public static let shared = TurnLatencyRecorder()

    private var marks: [String: [LatencyPhase: Date]] = [:]
    private var notes: [String: [String: String]] = [:]
    private var transports: [String: TransportTiming] = [:]
    private var steps: [String: Int] = [:]

    /// Records the first time a run reaches a phase; later hits of the same phase (a second
    /// model step, a second attachment) do not move it.
    public func mark(_ phase: LatencyPhase, run: String, at date: Date = Date()) {
        if marks[run]?[phase] == nil { marks[run, default: [:]][phase] = date }
    }

    /// Keeps the earliest/latest of an attachment-side phase across several attachments.
    public func mergeAttachment(_ phase: LatencyPhase, run: String, at date: Date, latest: Bool) {
        if let existing = marks[run]?[phase] {
            marks[run]![phase] = latest ? max(existing, date) : min(existing, date)
        } else {
            marks[run, default: [:]][phase] = date
        }
    }

    public func note(_ key: String, _ value: String, run: String) {
        notes[run, default: [:]][key] = value
    }

    public func noteStep(run: String) {
        steps[run, default: 0] += 1
    }

    /// The first provider exchange of the run is what decides time to first byte.
    public func recordTransport(_ timing: TransportTiming, run: String) {
        guard transports[run] == nil else { return }
        transports[run] = timing
        if let ready = timing.connectionReady { mark(.connectionReady, run: run, at: ready) }
        if let sent = timing.bodySent { mark(.requestBodySent, run: run, at: sent) }
        if let start = timing.responseStart { mark(.responseStart, run: run, at: start) }
    }

    public func finish(run: String) -> TurnLatencyReport? {
        defer {
            marks[run] = nil
            notes[run] = nil
            transports[run] = nil
            steps[run] = nil
        }
        guard let recorded = marks[run], !recorded.isEmpty else { return nil }
        return TurnLatencyReport(run: run, marks: recorded, transport: transports[run],
                                 notes: notes[run] ?? [:], modelSteps: steps[run] ?? 0)
    }
}

public struct TurnLatencyReport: Sendable {
    public struct Row: Sendable, Equatable {
        public let phase: LatencyPhase
        public let at: Date
        public let sincePreviousMs: Int
        public let cumulativeMs: Int
    }

    public let run: String
    public let rows: [Row]
    public let transport: TransportTiming?
    public let notes: [String: String]
    public let modelSteps: Int

    init(run: String, marks: [LatencyPhase: Date], transport: TransportTiming?, notes: [String: String], modelSteps: Int) {
        self.run = run
        self.transport = transport
        self.notes = notes
        self.modelSteps = modelSteps
        let ordered = marks.sorted { $0.value == $1.value
            ? LatencyPhase.allCases.firstIndex(of: $0.key)! < LatencyPhase.allCases.firstIndex(of: $1.key)!
            : $0.value < $1.value }
        let origin = ordered.first!.value
        var previous = origin
        rows = ordered.map { phase, date in
            defer { previous = date }
            return Row(phase: phase, at: date,
                       sincePreviousMs: Self.ms(date.timeIntervalSince(previous)),
                       cumulativeMs: Self.ms(date.timeIntervalSince(origin)))
        }
    }

    private static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1_000).rounded()) }

    private func at(_ phase: LatencyPhase) -> Date? { rows.first { $0.phase == phase }?.at }

    private func span(_ from: LatencyPhase, _ to: LatencyPhase) -> Int? {
        guard let a = at(from), let b = at(to) else { return nil }
        return Self.ms(b.timeIntervalSince(a))
    }

    /// A: bytes on the wire inside the inference request (inline attachments ride here).
    public var inlineUploadMs: Int? { span(.inferenceRequestStarted, .requestBodySent) }
    /// A, done ahead of time: a provider file upload finished before or during the send.
    public var preUploadMs: Int? { span(.uploadStarted, .providerFileReady) }
    /// B: the request is fully sent; everything until the first byte is the provider's.
    public var providerWaitMs: Int? { span(.requestBodySent, .responseStart) }
    /// B: first byte to the first thing the user can see.
    public var firstDeltaAfterResponseMs: Int? {
        guard let start = at(.responseStart) else { return nil }
        let first = [at(.firstReasoningDelta), at(.firstTextDelta)].compactMap { $0 }.min()
        return first.map { Self.ms($0.timeIntervalSince(start)) }
    }

    /// Which side the wait to first byte belongs to, stated only when both spans were measured.
    public var verdict: String {
        guard let upload = inlineUploadMs, let wait = providerWaitMs else { return "insufficient-data" }
        if upload >= wait { return "A: request upload dominates (\(upload)ms upload vs \(wait)ms provider wait)" }
        return "B: provider/model prefill dominates (\(wait)ms after the body was sent vs \(upload)ms upload)"
    }

    /// Flat key/value form for the runtime trace. Keys avoid the words the diagnostics store
    /// redacts (`header`, `token`, `content`, `body` prefixed by `request_`).
    public var traceMetadata: [String: String] {
        var values: [String: String] = ["verdict": verdict, "modelSteps": String(modelSteps)]
        for (index, row) in rows.enumerated() {
            values[String(format: "%02d.%@", index, row.phase.rawValue)] = "+\(row.sincePreviousMs)ms (Σ\(row.cumulativeMs)ms)"
        }
        if let inline = inlineUploadMs { values["A.inlineUploadMs"] = String(inline) }
        if let pre = preUploadMs { values["A.preUploadMs"] = String(pre) }
        if let wait = providerWaitMs { values["B.providerWaitMs"] = String(wait) }
        if let first = firstDeltaAfterResponseMs { values["B.firstDeltaAfterResponseMs"] = String(first) }
        if let transport {
            values["wire.sentBytes"] = String(transport.requestBodyBytes)
            if let reused = transport.reusedConnection { values["wire.reusedConnection"] = String(reused) }
        }
        for (key, value) in notes { values["note.\(key)"] = value }
        return values
    }

    /// One JSON object per turn, for `logs/latency.jsonl`.
    public var jsonLine: String {
        var object: [String: Any] = [
            "run": run, "verdict": verdict, "modelSteps": modelSteps,
            "phases": rows.map { ["phase": $0.phase.rawValue, "sincePreviousMs": $0.sincePreviousMs,
                                  "cumulativeMs": $0.cumulativeMs,
                                  "at": ISO8601DateFormatter().string(from: $0.at)] },
            "notes": notes,
        ]
        if let inline = inlineUploadMs { object["inlineUploadMs"] = inline }
        if let pre = preUploadMs { object["preUploadMs"] = pre }
        if let wait = providerWaitMs { object["providerWaitMs"] = wait }
        if let first = firstDeltaAfterResponseMs { object["firstDeltaAfterResponseMs"] = first }
        if let transport {
            object["requestBodyBytes"] = transport.requestBodyBytes
            if let reused = transport.reusedConnection { object["reusedConnection"] = reused }
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
