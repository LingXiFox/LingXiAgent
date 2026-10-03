import Foundation
import LingXiProtocol

/// Append-only JSONL recorder for a debug run.
///
/// Every method is fire-and-forget from the caller's point of view and none can fail the run. The
/// recorder sits downstream of the agent loop, so a full disk, a permissions problem or a torn
/// write has to cost exactly one thing: the archive. The telemetry stays in memory, the counters
/// stay accurate, and the failure is reported through `failureCount` so the Observatory can say
/// "the archive is behind" instead of looking healthy while silently not recording.
///
/// Writes are batched. A per-event `write()` on the path an agent loop takes would put disk latency
/// in front of the next model request, and on a several-hundred-turn run that is the difference
/// between measuring the system and measuring the storage.
public actor DebugRunRecorder {
    public struct Fault: Sendable, Equatable {
        public let at: Date
        public let stage: String
        public let detail: String
    }

    private let directory: URL
    private let fileName: String
    private let batchSize: Int

    private var buffer: [Data] = []
    private var handle: FileHandle?
    private var failures: Int = 0
    private var linesWritten: Int = 0
    private var faults: [Fault] = []

    /// `directory` need not exist; it is created on `start()`. Creation failures degrade recording
    /// rather than throwing, for the same reason writes do.
    public init(directory: URL, fileName: String = "telemetry.jsonl", batchSize: Int = 64) {
        self.directory = directory
        self.fileName = fileName
        self.batchSize = max(1, batchSize)
    }

    private var fileURL: URL { directory.appendingPathComponent(fileName, isDirectory: false) }

    /// Opens the archive. Returns false, never throws, when it cannot be opened.
    @discardableResult
    public func start(runName: String?, manifest: Data?) async -> Bool {
        guard handle == nil else { return true }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let manifest {
                try manifest.write(to: directory.appendingPathComponent("manifest.json", isDirectory: false),
                                   options: .atomic)
            }
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let opened = FileHandle(forWritingAtPath: fileURL.path) else {
                record(Fault(at: .now, stage: "open", detail: "no write handle for \(fileURL.lastPathComponent)"))
                return false
            }
            try opened.seekToEnd()
            self.handle = opened
            _ = runName
            return true
        } catch {
            record(Fault(at: .now, stage: "open", detail: String(describing: error)))
            return false
        }
    }

    /// Queues one line. Flushes when the batch is full, so callers never block on disk.
    public func append(_ data: Data) {
        buffer.append(data)
        if buffer.count >= batchSize {
            flush()
        }
    }

    /// Queues a batch already serialised by the hub. The whole batch counts against `batchSize`
    /// once, so a burst flushes immediately instead of dribbling out over many calls.
    public func appendBatch(_ lines: [Data]) {
        guard !lines.isEmpty else { return }
        buffer.append(contentsOf: lines)
        if buffer.count >= batchSize {
            flush()
        }
    }

    /// Writes whatever is buffered. Any error stops this write, not the run.
    public func flush() {
        defer { buffer.removeAll(keepingCapacity: true) }
        guard !buffer.isEmpty else { return }
        guard let handle else {
            // Without a handle the batch is lost. Count it, so the gap is visible in the status
            // rather than reconstructed from missing sequence numbers.
            record(Fault(at: .now, stage: "flush", detail: "archive not open; lost \(buffer.count) line(s)"))
            return
        }
        do {
            for line in buffer {
                try handle.write(contentsOf: line)
            }
            linesWritten += buffer.count
        } catch {
            record(Fault(at: .now, stage: "write", detail: String(describing: error)))
        }
    }

    public func stop() {
        flush()
        try? handle?.close()
        handle = nil
    }

    public func snapshot() -> (failures: Int, linesWritten: Int, buffered: Int, faults: [Fault]) {
        (failures, linesWritten, buffer.count, faults)
    }

    private func record(_ fault: Fault) {
        failures &+= 1
        // Keep the fault list bounded: a disk that stays broken for 500 turns must not turn the
        // recorder itself into the thing that grows without limit.
        if faults.count < 64 {
            faults.append(fault)
        }
    }
}
