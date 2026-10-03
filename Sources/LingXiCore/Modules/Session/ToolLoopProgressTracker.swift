import Foundation

/// Decides, batch by batch, whether a tool loop is making progress.
///
/// The question it replaces was "did this batch fail with the same message as the last one?",
/// which cannot tell a model stuck repeating itself from a model doing exactly the right thing:
/// `g++`, then `clang`, then `gcc`, each failing with the same environment error (an unaccepted
/// Xcode licence exits 69 for all three). Those are three strategies meeting one blocker, and
/// killing the run on the third throws away the moment the model was about to report it.
///
/// So failures are told apart by what was called, not only by what came back:
///
/// - **Exact duplicate**: the same calls (tool + arguments) failing the same way again. Nothing
///   new can come of it; stopped after `exactDuplicateLimit` consecutive batches.
/// - **Failure cluster**: different calls, same failure. Exploration, allowed; after
///   `clusterWarningAt` distinct strategies a single note asks the model to change course or
///   report the blocker, and only `clusterGraceAfterWarning` further no-progress batches after
///   that note end the run.
/// - **Progress**: a successful call, or a failure that differs from the last — the failure class
///   changed, so the model learned something. Both reset the counters and re-arm the warning.
///
/// A pure value so it can be tested without a model, a session or a tool runtime.
struct ToolLoopProgressTracker: Sendable, Equatable {
    struct CallOutcome: Sendable, Equatable {
        /// Tool id plus arguments: the same identity `failureKey(for:)` uses.
        let callKey: String
        let succeeded: Bool
        let errorMessage: String?
    }

    enum Verdict: Sendable, Equatable {
        /// Something succeeded, or the batch failed differently than the last one.
        case progress(strategyChanged: Bool)
        /// The same calls failed the same way again (`count` consecutive batches).
        case exactDuplicate(count: Int)
        /// Different calls, same failure, below the warning threshold.
        case failureCluster(distinctStrategies: Int)
        /// Inject `message` into what the model sees next. Issued once per cluster.
        case softWarning(distinctStrategies: Int, message: String)
        /// End the run. `kind` says which rule fired.
        case hardStop(kind: HardStopKind, message: String)
    }

    enum HardStopKind: String, Sendable, Equatable {
        case exactDuplicate
        case clusterAfterWarning
    }

    static let softWarningText = "多个不同策略均遇到同一个环境级阻塞。不要继续无意义更换同类命令。"
        + "请换执行路径、请求用户处理环境问题，或明确报告 blocker。"

    var exactDuplicateLimit = 3
    var clusterWarningAt = 3
    var clusterGraceAfterWarning = 2

    private(set) var lastFailure: String?
    private(set) var lastCallKeys: [String] = []
    private(set) var exactDuplicates = 0
    private(set) var clusterStrategies: Set<String> = []
    private(set) var clusterBatches = 0
    private(set) var warnedAtBatch: Int?

    init(exactDuplicateLimit: Int = 3, clusterWarningAt: Int = 3, clusterGraceAfterWarning: Int = 2) {
        self.exactDuplicateLimit = exactDuplicateLimit
        self.clusterWarningAt = clusterWarningAt
        self.clusterGraceAfterWarning = clusterGraceAfterWarning
    }

    mutating func record(_ batch: [CallOutcome]) -> Verdict {
        let failures = batch.compactMap(\.errorMessage).joined(separator: ";")
        let keys = batch.map(\.callKey)
        let anySuccess = batch.contains(where: \.succeeded)

        // Any success, or a batch that did not fail at all, is progress.
        guard !failures.isEmpty, !anySuccess else {
            let changed = lastFailure != nil
            reset(keys: keys)
            return .progress(strategyChanged: changed)
        }
        // A different failure is new information: the failure class changed.
        guard failures == lastFailure else {
            let hadFailure = lastFailure != nil
            reset(keys: keys)
            lastFailure = failures
            exactDuplicates = 1
            clusterStrategies = [keys.joined(separator: "\u{1F}")]
            clusterBatches = 1
            return hadFailure ? .progress(strategyChanged: true) : .failureCluster(distinctStrategies: 1)
        }

        clusterBatches += 1
        if keys == lastCallKeys {
            exactDuplicates += 1
            if exactDuplicates >= exactDuplicateLimit {
                return .hardStop(kind: .exactDuplicate,
                                 message: "连续 \(exactDuplicates) 次以完全相同的 ToolCall 遇到相同失败：\(failures)")
            }
            if let warnedAtBatch, clusterBatches - warnedAtBatch > clusterGraceAfterWarning {
                return clusterStop(failures)
            }
            return .exactDuplicate(count: exactDuplicates)
        }

        lastCallKeys = keys
        exactDuplicates = 1
        clusterStrategies.insert(keys.joined(separator: "\u{1F}"))
        if let warnedAtBatch {
            if clusterBatches - warnedAtBatch > clusterGraceAfterWarning {
                return clusterStop(failures)
            }
            return .failureCluster(distinctStrategies: clusterStrategies.count)
        }
        if clusterStrategies.count >= clusterWarningAt {
            warnedAtBatch = clusterBatches
            return .softWarning(distinctStrategies: clusterStrategies.count, message: Self.softWarningText)
        }
        return .failureCluster(distinctStrategies: clusterStrategies.count)
    }

    private func clusterStop(_ failures: String) -> Verdict {
        .hardStop(kind: .clusterAfterWarning,
                  message: "\(clusterStrategies.count) 个不同策略在提示后仍持续遇到同一阻塞：\(failures)")
    }

    private mutating func reset(keys: [String]) {
        lastFailure = nil
        lastCallKeys = keys
        exactDuplicates = 0
        clusterStrategies = []
        clusterBatches = 0
        warnedAtBatch = nil
    }
}
