#if os(macOS)
import SwiftUI
import AppKit
import LingXiProtocol

// Every value in this file is something Core said. Two rules hold it together:
//
// 1. A number is never rendered without its provenance. `observedGranularity` is always nil in
//    Core, `structuralPrefixStability` is a Bool wearing a Double, `volatileTailBytes` is a token
//    estimate times four. Shown bare next to real measurements, those three would quietly teach an
//    operator to trust the wrong things — over a several-hundred-turn run, that is the difference
//    between a finding and a fiction.
// 2. Absence renders as absence. `nil` becomes "不可知" plus Core's own reason, never 0, never "—",
//    never an empty row that looks like a clean result.

// MARK: - Shared vocabulary

/// One labelled metric, provenance-aware.
///
/// `Value` carries the same constraints as `DebugMetric`'s plus `CustomStringConvertible`, which
/// every type actually used here (Int, Double, String, Bool) already satisfies.
struct ObservatoryMetricRow<Value: Codable & Sendable & Equatable & CustomStringConvertible>: View {
    let label: String
    let metric: DebugMetric<Value>

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LingXiMetrics.Space.xs) {
            Text(label)
                .font(LXType.meta)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let value = metric.value {
                Text(String(describing: value))
                    .font(LXType.monoSmall)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                ProvenanceBadge(provenance: metric.provenance, basis: metric.basis)
            } else {
                Text("不可知")
                    .font(LXType.meta)
                    .foregroundStyle(.tertiary)
                ProvenanceBadge(provenance: .unavailable, basis: metric.basis)
            }
        }
        .frame(minHeight: 20)
    }
}

/// A quiet marker, not a colour show: what it encodes is whether the number can be trusted as a
/// measurement, which is the one thing an engineer scanning 300 turns needs to see peripherally.
struct ProvenanceBadge: View {
    let provenance: DebugMetricProvenance
    let basis: String?

    var body: some View {
        Text(shortLabel)
            .font(LXType.micro)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 0.5))
            .help(basis.map { "\(provenance.rawValue): \($0)" } ?? provenance.rawValue)
    }

    private var shortLabel: String {
        switch provenance {
        case .measured: return "measured"
        case .coreReported: return "provider"
        case .nativeRuntime: return "native runtime"
        case .derived: return "derived"
        case .estimated: return "est"
        case .coarse: return "coarse"
        case .unavailable: return "n/a"
        case .unknown: return "?"
        }
    }

    private var color: Color {
        switch provenance {
        case .measured, .coreReported: return LXStatus.success
        case .nativeRuntime: return LXColor.accent
        case .derived: return LXColor.accent
        case .estimated, .coarse: return LXStatus.warning
        case .unavailable, .unknown: return .secondary
        }
    }
}

/// A plain key/value row for values that carry no provenance because they are strings or ids.
struct ObservatoryKV: View {
    let key: String
    let value: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LingXiMetrics.Space.xs) {
            Text(key)
                .font(LXType.meta)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value?.isEmpty == false ? value! : "不可知")
                .font(value?.isEmpty == false ? LXType.monoSmall : LXType.meta)
                .foregroundStyle(value?.isEmpty == false ? .primary : .tertiary)
                .textSelection(.enabled)
        }
        .frame(minHeight: 20)
    }
}

struct ObservatoryCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
            Text(title)
                .font(LXType.meta.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(LingXiMetrics.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lxPanel()
    }
}

// MARK: - Overview

struct ObservatoryOverviewPane: View {
    @ObservedObject var model: RuntimeObservatoryPresentationModel
    @ObservedObject var inspector: RuntimeInspectorPresentationModel
    let runtime: RuntimeFrontend
    /// What the operator is typing. An input draft, not a copy of Core state: the run name shown
    /// while recording is always `model.status.runName`.
    @State private var runNameDraft = ""
    @State private var recorderBusy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                if let failure = model.readFailure {
                    // Plain text rather than SettingsNotice: that view is bound to SettingsStore's
                    // notice/pendingApply machinery, and a failed debug read is not a pending
                    // configuration change.
                    HStack(alignment: .firstTextBaseline, spacing: LingXiMetrics.Space.xs) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(failure)
                        Spacer()
                    }
                    .font(LXType.meta)
                    .foregroundStyle(LXStatus.warning)
                    .padding(LingXiMetrics.Space.xs)
                    .background(LXStatus.warning.opacity(0.08))
                }
                HStack(alignment: .top, spacing: LingXiMetrics.Space.sm) {
                    sessionCard
                    runtimeCard
                }
                HStack(alignment: .top, spacing: LingXiMetrics.Space.sm) {
                    cacheCard
                    recordingCard
                }
                if let local = model.snapshot?.localRuntime {
                    LocalRuntimeCard(status: local)
                }
            }
            .padding(LingXiMetrics.Space.md)
        }
        .background(LXColor.content)
    }

    /// Session, run and turn come from the authoritative projection wherever possible; the debug
    /// snapshot only supplies what the projection does not carry.
    private var sessionCard: some View {
        ObservatoryCard(title: "会话与轮次") {
            ObservatoryKV(key: "Session", value: model.snapshot?.sessionID.rawValue)
            ObservatoryKV(key: "Run", value: model.snapshot?.runID?.rawValue ?? "不可知")
            ObservatoryKV(key: "Turn", value: model.snapshot?.turnID?.rawValue ?? "不可知")
            ObservatoryKV(key: "Revision", value: model.snapshot.map { String($0.revision) })
            ObservatoryKV(key: "Model", value: inspector.live?.modelID)
            ObservatoryKV(key: "Reasoning", value: inspector.live?.reasoning)
        }
    }

    private var runtimeCard: some View {
        ObservatoryCard(title: "运行时") {
            if let context = model.snapshot?.runtimeContextPolicy {
                ObservatoryKV(key: "Model runtime window", value: context.runtimeModelWindow.map(String.init))
                ObservatoryKV(key: "Effective policy model window", value: String(context.effectivePolicy.modelWindow))
                ObservatoryKV(key: "Reserve", value: String(context.effectivePolicy.reserve))
                ObservatoryKV(key: "Policy generation", value: String(context.generation))
                HStack {
                    Text("Runtime Policy Consistency").font(LXType.micro)
                    Spacer()
                    Text(context.isConsistent ? "CONSISTENT" : "MISMATCH")
                        .font(LXType.micro.weight(.semibold))
                        .foregroundStyle(context.isConsistent ? LXStatus.success : LXStatus.error)
                }
            }
            if let pCore = model.snapshot?.pCore {
                ObservatoryMetricRow(label: "P-Core tokens",
                                     metric: DebugMetric(value: pCore.usedTokens, provenance: .measured))
                ObservatoryKV(key: "target / soft / hard",
                              value: "\(pCore.targetTokens) / \(pCore.softLimitTokens) / \(pCore.hardLimitTokens)")
                ObservatoryMetricRow(label: "Stable prefix bytes",
                                     metric: DebugMetric(value: pCore.stablePrefixBytes, provenance: .measured))
            } else {
                ObservatoryKV(key: "P-Core", value: nil)
            }
            if let eCore = model.snapshot?.eCore {
                ObservatoryMetricRow(label: "E-Core objects",
                                     metric: DebugMetric(value: eCore.objectCount, provenance: .measured,
                                                         basis: "authoritative physical census"))
                ObservatoryMetricRow(label: "E-Core bytes",
                                     metric: DebugMetric(value: eCore.totalBytes, provenance: .measured,
                                                         basis: "authoritative physical census"))
            } else {
                ObservatoryKV(key: "E-Core", value: nil)
            }
        }
    }

    private var cacheCard: some View {
        ObservatoryCard(title: "Prefix Cache") {
            if let cache = model.snapshot?.cache {
                ObservatoryKV(key: "stablePrefixHash", value: cache.stablePrefixHash)
                ObservatoryKV(key: "epoch / reason",
                              value: cache.cacheEpoch.map { "\($0) / \(cache.epochReason ?? "—")" })
                ObservatoryMetricRow(label: "Cache debt", metric: cache.cacheDebt)
                ObservatoryMetricRow(label: "Reuse ratio", metric: cache.prefixReuseRatio)
                ObservatoryMetricRow(label: "Client bust rate", metric: cache.clientCausedBustRate)
            } else {
                ObservatoryKV(key: "Cache", value: nil)
            }
        }
    }

    /// Start/stop the persistent archive. Every row reads Core's `DebugObservatoryStatus`; the
    /// buttons only send the existing recorder commands and then show whatever Core answered.
    private var recordingCard: some View {
        ObservatoryCard(title: "Debug recording") {
            let status = model.status
            ObservatoryKV(key: "Mode", value: status.map { $0.enabled ? "ON" : "OFF" })
            ObservatoryKV(key: "Recording", value: status.map { $0.recording ? "YES" : "no" })
            ObservatoryKV(key: "Run name", value: status?.runName)
            ObservatoryMetricRow(label: "Buffered",
                                 metric: DebugMetric(value: status.map { "\($0.eventsBuffered)/\($0.ringCapacity)" },
                                                     provenance: .measured))
            ObservatoryMetricRow(label: "Ring dropped",
                                 metric: DebugMetric(value: status?.eventsDropped, provenance: .measured))
            ObservatoryMetricRow(label: "Archive failures",
                                 metric: DebugMetric(value: status?.archiveWriteFailures, provenance: .measured))
            if let failures = status?.archiveWriteFailures, failures > 0 {
                // Fail-open means the run keeps going; it must not also mean nobody notices the
                // archive is incomplete.
                warningLine("归档写入失败 \(failures) 次：JSONL 不完整，仅内存环形缓冲可信")
            }
            if status?.recording == false, let dropped = status?.eventsDropped, dropped > 0 {
                warningLine("未录制且环形缓冲已丢弃 \(dropped) 条：这些事件已无法找回")
            }
            if let failure = model.recorderActionFailure {
                warningLine(failure)
            }
            Divider()
            if status?.recording == true {
                Button(role: .destructive) {
                    runRecorder { await runtime.stopDebugRecording() }
                } label: {
                    Label("停止记录", systemImage: "stop.circle")
                }
                .disabled(recorderBusy)
            } else {
                HStack(spacing: LingXiMetrics.Space.xs) {
                    TextField("pe-qwen9b-001", text: $runNameDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(LXType.monoSmall)
                        .help("留空由 Core 生成 run-<时间戳>；只允许字母、数字、. _ -")
                    Button {
                        let name = runNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        runRecorder { await runtime.startDebugRecording(runName: name.isEmpty ? nil : name) }
                    } label: {
                        Label("开始记录", systemImage: "record.circle")
                    }
                    .disabled(recorderBusy || status?.enabled != true)
                }
            }
        }
    }

    private func warningLine(_ text: String) -> some View {
        Text(text)
            .font(LXType.micro)
            .foregroundStyle(LXStatus.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Disables the buttons until Core answers, so a double click cannot send two commands whose
    /// receipts arrive out of order.
    private func runRecorder(_ action: @escaping @MainActor () async -> Void) {
        recorderBusy = true
        Task { @MainActor in
            await action()
            recorderBusy = false
        }
    }
}

// MARK: - Local runtime

/// What the local inference server says it has loaded, and what its last response measured.
///
/// Three kinds of value share this card and each is labelled: the server's configuration
/// (`native runtime`), what a response actually carried (`measured`), and what is computed from
/// those (`derived`). A field the server did not report renders as unavailable, never as zero.
struct LocalRuntimeCard: View {
    let status: LocalRuntimeModelStatus

    var body: some View {
        ObservatoryCard(title: "Local Runtime · \(backendName)") {
            ObservatoryKV(key: "Endpoint", value: status.endpoint)
            ObservatoryKV(key: "Discovery", value: sourceText)
            if let note = status.note {
                Text(note).font(LXType.micro).foregroundStyle(LXStatus.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: LingXiMetrics.Space.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    ObservatoryKV(key: "Model", value: status.modelKey)
                    ObservatoryKV(key: "Loaded Instance", value: status.loadedInstanceID)
                    ObservatoryKV(key: "Architecture", value: status.architecture)
                    ObservatoryKV(key: "Quantization", value: status.quantization)
                    row("Runtime Context", status.runtimeContextTokens.map(grouped),
                        basis: "loaded_instances[].config.context_length — the active budget")
                    row("Model Maximum", status.modelMaxContextTokens.map(grouped),
                        basis: "max_context_length — what the weights allow, not what is loaded")
                    row("Tool Use", status.toolUse.map(yesNo))
                    row("Vision", status.vision.map(yesNo))
                    row("Reasoning", status.reasoningOptions.map { $0.joined(separator: "/") })
                    row("Reasoning Default", status.reasoningDefault)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Acceleration").font(LXType.meta.weight(.semibold)).foregroundStyle(.secondary)
                    row("Flash Attention", status.flashAttention.map(yesNo))
                    row("KV Cache GPU", status.kvCacheOnGPU.map(yesNo))
                    row("MTP", status.mtpEnabled.map(yesNo))
                    row("External Draft", status.source == .native ? (status.externalDraftModel ?? "no") : nil)
                    row("Draft Max Tokens", status.draftMaxTokens.map(String.init))
                    row("Continue Threshold", status.draftMinContinueProbability.map { String(format: "%.2f", $0) })
                    row("Speculative Mode", status.source == .native ? status.configuredSpeculativeMode.rawValue : nil,
                        basis: "configured: MTP flag or external draft model")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Observed Last Request").font(LXType.meta.weight(.semibold)).foregroundStyle(.secondary)
                    let last = status.lastSpeculative
                    measured("Mode", last?.mode.rawValue)
                    measured("Drafted", last?.draftedTokens.map(String.init))
                    measured("Accepted", last?.acceptedTokens.map(String.init))
                    measured("Rejected", last?.rejectedTokens.map(String.init))
                    ObservatoryMetricRow(label: "Acceptance",
                                         metric: DebugMetric(value: last?.acceptanceRate.map { String(format: "%.1f%%", $0 * 100) },
                                                             provenance: last?.acceptanceRate == nil ? .unavailable : .derived,
                                                             basis: last == nil ? "no response has carried draft stats yet"
                                                                 : "accepted / drafted"))
                }
            }
        }
    }

    private var backendName: String {
        switch status.backend { case .lmStudio: return "LM Studio" }
    }

    private var sourceText: String {
        switch status.source {
        case .native: return "native /api/v1/models"
        case .openAICompatibleFallback: return "fallback /v1/models (runtime state unknown)"
        case .unreachable: return "unreachable"
        }
    }

    private func row(_ label: String, _ value: String?, basis: String? = nil) -> some View {
        ObservatoryMetricRow(label: label,
                             metric: DebugMetric(value: value, provenance: value == nil ? .unavailable : .nativeRuntime,
                                                 basis: value == nil ? "not reported by the runtime" : basis))
    }

    private func measured(_ label: String, _ value: String?) -> some View {
        ObservatoryMetricRow(label: label,
                             metric: DebugMetric(value: value, provenance: value == nil ? .unavailable : .measured,
                                                 basis: value == nil ? "the last response did not carry this field"
                                                     : "stats in the last response"))
    }

    private func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
    private func grouped(_ value: Int) -> String { value.formatted(.number.grouping(.automatic)) }
}

// MARK: - P/E-Core

struct PEECorePane: View {
    @ObservedObject var model: RuntimeObservatoryPresentationModel
    @State private var showHeat = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                if let pCore = model.snapshot?.pCore { pCoreCard(pCore) }
                if let eCore = model.snapshot?.eCore {
                    eCoreCard(eCore)
                    countersCard(eCore)
                    evictionTable(eCore)
                    if showHeat, let heat = eCore.heat { heatCard(heat) }
                } else {
                    emptyReading
                }
            }
            .padding(LingXiMetrics.Space.md)
        }
        .background(LXColor.content)
    }

    private var emptyReading: some View {
        ContentUnavailableView("尚无 E-Core 读数", systemImage: "square.3.layers.3d",
                               description: Text("Core 未回报过页出或召回。跑过几轮之后再刷新。"))
    }

    private func pCoreCard(_ pCore: DebugPCorePanel) -> some View {
        ObservatoryCard(title: "P-Core") {
            ObservatoryMetricRow(label: "active tokens",
                                 metric: DebugMetric(value: pCore.usedTokens, provenance: .measured))
            ObservatoryKV(key: "target", value: String(pCore.targetTokens))
            ObservatoryKV(key: "soft limit", value: String(pCore.softLimitTokens))
            ObservatoryKV(key: "hard limit", value: String(pCore.hardLimitTokens))
            ObservatoryMetricRow(label: "stable prefix bytes",
                                 metric: DebugMetric(value: pCore.stablePrefixBytes, provenance: .measured))
            ObservatoryMetricRow(label: "growing context tokens",
                                 metric: DebugMetric(value: pCore.growingContextTokens,
                                                     provenance: .estimated,
                                                     basis: "ConservativeTokenEstimator over live entries"))
            // No invented number: Core exposes no index-projection size today.
            ObservatoryMetricRow(label: "E-Core index projection",
                                 metric: DebugMetric<Int>(value: pCore.eCoreIndexTokens,
                                                          provenance: .unavailable,
                                                          basis: "Core does not report a projection size"))
        }
    }

    private func eCoreCard(_ eCore: DebugECorePanel) -> some View {
        ObservatoryCard(title: "E-Core 储量") {
            // The headline pair is the authoritative physical census: every payload that exists,
            // from either source, deduplicated by content-addressed id. This is the number to
            // watch for unbounded growth, and it is deliberately not the metadata-index view.
            ObservatoryMetricRow(label: "object count (authoritative)",
                                 metric: DebugMetric(value: eCore.objectCount, provenance: .measured,
                                                     basis: eCore.censusIsPhysical
                                                         ? "physical payload census: store() and "
                                                           + "pageOut() union, deduplicated by objectID"
                                                         : "legacy metadata index; does NOT include "
                                                           + "page-out payloads"))
            ObservatoryMetricRow(label: "total bytes (authoritative)",
                                 metric: DebugMetric(value: eCore.totalBytes, provenance: .measured,
                                                     basis: "sum of actual payload file sizes"))
            // References are occurrence identities, not objects. Shown next to the object count on
            // purpose: a run where references grow while objects stay flat is dedupe working, and
            // an operator who reads them as the same unit will call that a leak.
            ObservatoryMetricRow(label: "references (occurrences, not objects)",
                                 metric: DebugMetric(value: eCore.referenceCount, provenance: .measured))
            Divider()
            ObservatoryMetricRow(label: "· meta-index view",
                                 metric: DebugMetric(value: eCore.metaIndexObjectCount, provenance: .derived,
                                                     basis: "what listObjects() sees: .meta.json only, "
                                                          + "so no page-out payloads"))
            ObservatoryMetricRow(label: "· invisible to it",
                                 metric: DebugMetric(value: eCore.censusBlindSpotObjectCount, provenance: .derived,
                                                     basis: "authoritative count minus meta-index count; "
                                                          + "non-zero is normal and expected"))
            ObservatoryMetricRow(label: "· page-out tallies",
                                 metric: DebugMetric(value: "\(eCore.pageOutOnlyObjectCount) objects / "
                                                          + "\(eCore.pageOutOnlyBytes) bytes",
                                                     provenance: .derived,
                                                     basis: "counted by the bypass as each pageOut "
                                                          + "happened; distinguishes one object paged "
                                                          + "out forty times from forty objects"))
            Toggle("显示热度分布（每次刷新全量重算）", isOn: $showHeat)
                .font(LXType.meta)
                .toggleStyle(.checkbox)
        }
    }

    private func countersCard(_ eCore: DebugECorePanel) -> some View {
        ObservatoryCard(title: "E-Core 生命周期计数") {
            ObservatoryMetricRow(label: "page-out", metric: DebugMetric(value: eCore.counters.pageOuts, provenance: .measured))
            ObservatoryMetricRow(label: "exact restore", metric: DebugMetric(value: eCore.counters.exactRestores, provenance: .measured))
            ObservatoryMetricRow(label: "semantic recall", metric: DebugMetric(value: eCore.counters.semanticRecalls, provenance: .measured))
            ObservatoryMetricRow(label: "restore failed · dangling ref",
                                 metric: DebugMetric(value: eCore.counters.danglingReferenceRestores,
                                                     provenance: .measured))
            ObservatoryMetricRow(label: "restore failed · payload gone",
                                 metric: DebugMetric(value: eCore.counters.payloadMissingRestores,
                                                     provenance: .measured))
            ObservatoryMetricRow(label: "objects stored",
                                 metric: DebugMetric(value: eCore.counters.objectsStored, provenance: .measured))
        }
    }

    /// The recent-eviction table.
    ///
    /// Header says "this turn" because that is what Core holds: `ContextCompactor` overwrites its
    /// trace per compaction rather than accumulating one. Labelling it 最近 would imply a history
    /// that does not exist.
    private func evictionTable(_ eCore: DebugECorePanel) -> some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
            Text("最近一次 compaction 的 eviction（Core 只保留当次）")
                .font(LXType.meta.weight(.semibold))
                .foregroundStyle(.secondary)
            Table(eCore.recentEvictions.map(EvictionRow.init)) {
                TableColumn("objectKey") { Text($0.raw.objectKey).font(LXType.monoSmall) }
                    .width(min: 120, ideal: 200)
                TableColumn("类型") { Text($0.raw.objectType).font(LXType.monoSmall) }
                    .width(min: 80, ideal: 110)
                TableColumn("tokens") { Text(String($0.raw.tokenCost)).font(LXType.monoSmall).monospacedDigit() }
                    .width(min: 60, ideal: 80)
                TableColumn("retention") { Text(String(format: "%.3f", $0.raw.retentionScore)).font(LXType.monoSmall) }
                    .width(min: 70, ideal: 90)
                TableColumn("rank") { Text($0.raw.evictionRank.map(String.init) ?? "n/a").font(LXType.monoSmall) }
                    .width(min: 45, ideal: 60)
                TableColumn("reason") { Text($0.raw.evictionReason ?? "—").font(LXType.monoSmall) }
                    .width(min: 110, ideal: 180)
                TableColumn("去向") { row in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(row.raw.enteredECore ? LXStatus.success : LXStatus.warning)
                            .frame(width: LXControl.dot, height: LXControl.dot)
                        Text(row.raw.enteredECore ? "E-Core" : "丢弃")
                            .font(LXType.meta)
                    }
                    .help(row.raw.enteredECore
                          ? "该次逐出走了 page-out，E-Core 里应有对应对象"
                          : "该次逐出没有产生 E-Core 引用")
                }
                .width(min: 70, ideal: 90)
                TableColumn("scoring") { row in
                    Text(row.raw.scoringActiveAtSessionLevel ? "retention" : "FAIL-OPEN")
                        .font(LXType.micro)
                        .foregroundStyle(row.raw.scoringActiveAtSessionLevel ? .secondary : LXStatus.error)
                        .help("scoringActive 是 Core 的会话级开关，不是逐条目判定：整轮没有可用的"
                              + " RetentionScore 时，本轮所有条目都标为 Fail-Open。")
                }
                .width(min: 80, ideal: 100)
                TableColumn("observed") { Text($0.raw.observedAt, style: .time).font(LXType.monoSmall) }
                    .width(min: 80, ideal: 95)
            }
            .frame(minHeight: 180)
            .overlay {
                if eCore.recentEvictions.isEmpty {
                    ContentUnavailableView("本轮没有 eviction", systemImage: "tray",
                                           description: Text("未触发压缩，或压缩未产生逐出记录。"))
                }
            }
        }
    }

    private func heatCard(_ heat: DebugHeatSummary) -> some View {
        ObservatoryCard(title: "热度分布（按需全量重算）") {
            ObservatoryKV(key: "objects hot / cold", value: "\(heat.hotCount) / \(heat.coldCount)")
            ObservatoryKV(key: "median / MAD", value: String(format: "%.3f / %.3f", heat.medianHeat, heat.madHeat))
            ObservatoryKV(key: "p80 / p95", value: String(format: "%.3f / %.3f", heat.p80, heat.p95))
            ForEach(heat.topObjects, id: \.objectID) { object in
                HStack(spacing: LingXiMetrics.Space.xs) {
                    Text(object.objectID)
                        .font(LXType.monoSmall)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(String(format: "%.2f", object.rawHeatScore))
                        .font(LXType.monoSmall).monospacedDigit()
                    Text(object.candidateZone)
                        .font(LXType.micro)
                        .foregroundStyle(object.candidateZone == "hot" ? LXStatus.success : .secondary)
                    Text("acc\(object.accessCount) rec\(object.recallCount)")
                        .font(LXType.meta)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Prefix Cache

struct PrefixCachePane: View {
    @ObservedObject var model: RuntimeObservatoryPresentationModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                if let audit = model.snapshot?.prefixAudit { auditCard(audit) }
                if let cache = model.snapshot?.cache { cacheCard(cache) }
                historyTable
            }
            .padding(LingXiMetrics.Space.md)
        }
        .background(LXColor.content)
    }

    /// The question the endurance test actually asks, put where it cannot be missed.
    private func auditCard(_ audit: DebugPrefixByteAudit) -> some View {
        ObservatoryCard(title: "Stable Prefix 字节审计") {
            ObservatoryMetricRow(label: "common bytes (prev → now)",
                                 metric: DebugMetric(value: audit.stablePrefixCommonBytes,
                                                     provenance: .measured))
            ObservatoryMetricRow(label: "first changed byte offset",
                                 metric: DebugMetric(value: audit.promptFirstChangedByteOffset,
                                                     provenance: .measured))
            ObservatoryMetricRow(label: "current prefix bytes",
                                 metric: DebugMetric(value: audit.stablePrefixBytes, provenance: .measured))
            ObservatoryKV(key: "previous hash", value: audit.previousStablePrefixHash)
            ObservatoryKV(key: "current hash", value: audit.currentStablePrefixHash)
            ObservatoryKV(key: "bust reason", value: audit.bustReason)
            ObservatoryMetricRow(label: "client-caused",
                                 metric: DebugMetric(value: audit.clientCaused.map { $0 ? "yes" : "no" },
                                                     provenance: .derived,
                                                     basis: "true when Core attributed the change to a "
                                                         + "client-side structural mutation"))
            ObservatoryMetricRow(label: "requestProfileHash",
                                 metric: DebugMetric(value: audit.requestProfileHash,
                                                     provenance: audit.requestProfileProvenance,
                                                     basis: "computed every turn by SessionRuntime; "
                                                         + "published nowhere before this window existed"))
            HStack(alignment: .firstTextBaseline, spacing: LingXiMetrics.Space.xs) {
                Text("canonical 定义")
                    .font(LXType.meta).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(audit.canonicalDefinition.rawValue)
                    .font(LXType.monoSmall)
                    .foregroundStyle(.primary)
                    .help("Core hashes two different strings as the stable prefix. These byte offsets are "
                          + "into the one named here. Correlating them against the other definition "
                          + "produces a confident wrong answer.")
            }
        }
    }

    private func cacheCard(_ cache: DebugCacheSample) -> some View {
        ObservatoryCard(title: "Provider Cache") {
            ObservatoryKV(key: "cacheStatus", value: cache.cacheStatus)
            ObservatoryKV(key: "epoch", value: cache.cacheEpoch.map(String.init))
            ObservatoryKV(key: "epochReason", value: cache.epochReason)
            ObservatoryMetricRow(label: "cacheDebt", metric: cache.cacheDebt)
            ObservatoryMetricRow(label: "promptTokens", metric: cache.promptTokens)
            ObservatoryMetricRow(label: "previousPromptTokens", metric: cache.previousPromptTokens)
            ObservatoryMetricRow(label: "cacheReadTokens", metric: cache.cacheReadTokens)
            ObservatoryMetricRow(label: "prefixReuseRatio", metric: cache.prefixReuseRatio)
            ObservatoryMetricRow(label: "clientCausedBustRate", metric: cache.clientCausedBustRate)
            ObservatoryMetricRow(label: "clientCausedBusts",
                                 metric: DebugMetric(value: cache.clientCausedBusts, provenance: .measured))
            ObservatoryMetricRow(label: "comparableRequests",
                                 metric: DebugMetric(value: cache.comparableRequests, provenance: .measured))
            ObservatoryMetricRow(label: "appendOnlyContextRatio", metric: cache.appendOnlyContextRatio)
            ObservatoryMetricRow(label: "appendOnlyViolations",
                                 metric: DebugMetric(value: cache.appendOnlyViolations, provenance: .measured))
            ObservatoryMetricRow(label: "volatileTailBytes", metric: cache.volatileTailBytes)
            ObservatoryMetricRow(label: "structuralPrefixStability", metric: cache.structuralPrefixStability)
            ObservatoryMetricRow(label: "observedGranularity", metric: cache.observedGranularity)
            if let diagnostics = cache.missDiagnostics {
                Text("missDiagnostics（Core 生成的人类可读文本，含截断 hash，不可解析）")
                    .font(LXType.meta).foregroundStyle(.secondary)
                Text(diagnostics)
                    .font(LXType.monoSmall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Time series rebuilt from the event ring rather than stored separately: Core keeps no cache
    /// history, and a second history in the GUI would be a second authority.
    private var historyTable: some View {
        let rows = model.events.compactMap(CacheHistoryRow.init(event:))
        return VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
            Text("Cache 时间序列（从事件环重建）")
                .font(LXType.meta.weight(.semibold))
                .foregroundStyle(.secondary)
            Table(rows) {
                TableColumn("seq") { Text(String($0.raw.sequence)).font(LXType.monoSmall) }
                    .width(min: 55, ideal: 70)
                TableColumn("时间") { Text($0.raw.timestamp, style: .time).font(LXType.monoSmall) }
                    .width(min: 85, ideal: 100)
                TableColumn("epoch") { Text($0.sample.cacheEpoch.map(String.init) ?? "—").font(LXType.monoSmall) }
                    .width(min: 55, ideal: 65)
                TableColumn("debt") { Text($0.sample.cacheDebt.value.map(String.init) ?? "n/a").font(LXType.monoSmall) }
                    .width(min: 55, ideal: 70)
                TableColumn("prompt") { Text($0.sample.promptTokens.value.map(String.init) ?? "n/a").font(LXType.monoSmall) }
                    .width(min: 65, ideal: 80)
                TableColumn("read") { Text($0.sample.cacheReadTokens.value.map(String.init) ?? "n/a").font(LXType.monoSmall) }
                    .width(min: 65, ideal: 80)
                TableColumn("hash") { Text(String($0.sample.stablePrefixHash?.prefix(12) ?? "—")).font(LXType.monoSmall) }
                    .width(min: 110, ideal: 140)
            }
            .frame(minHeight: 200)
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("尚无 cache 读数", systemImage: "lock.rectangle.stack",
                                           description: Text("完成一轮并刷新后出现。"))
                }
            }
        }
    }
}

// MARK: - Events

struct EventsRow: Identifiable {
    let raw: DebugTelemetryEvent
    var id: UInt64 { raw.sequence }
    var timestamp: Date { raw.timestamp }
}

/// Row adapter for the eviction table.
///
/// `Table` needs `Identifiable` rows and `DebugEvictionEntry` is a wire DTO with no identity of its
/// own; wrapping keeps the wire type clean instead of teaching it about SwiftUI. Same reason
/// `TraceWindowView` wraps `RuntimeTraceEvent`.
struct EvictionRow: Identifiable {
    let raw: DebugEvictionEntry
    var id: String { "\(raw.objectKey):\(raw.evictionRank.map(String.init) ?? "n")" }
}

/// Row adapter for the cache time series, built only from events that actually carry a sample.
struct CacheHistoryRow: Identifiable {
    let raw: DebugTelemetryEvent
    let sample: DebugCacheSample
    var id: UInt64 { raw.sequence }

    init?(event: DebugTelemetryEvent) {
        guard let sample = event.cacheSample else { return nil }
        self.raw = event
        self.sample = sample
    }
}

struct EventsPane: View {
    @ObservedObject var model: RuntimeObservatoryPresentationModel
    let onSelect: (UInt64) -> Void
    @State private var sortOrder = [KeyPathComparator<EventsRow>(\.timestamp, order: .reverse)]
    @State private var selection: Set<UInt64> = []

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            table
        }
    }

    private var filterBar: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            TextField("session / run / turn / objectID", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .font(LXType.body)
                .frame(maxWidth: 280)

            Menu {
                Button("全部类别") { model.selectedCategories = [] }
                Divider()
                ForEach(model.availableCategories, id: \.self) { category in
                    Button {
                        toggle(category)
                    } label: {
                        Label(category, systemImage: model.selectedCategories.contains(category)
                              ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: {
                Text(model.selectedCategories.isEmpty ? "类别：全部" : "类别：\(model.selectedCategories.count)")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Toggle("跟随尾部", isOn: $model.followTail)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(LXType.meta)

            Spacer()
            Text("\(model.visibleEvents.count) / \(model.events.count)")
                .font(LXType.monoSmall)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, LingXiMetrics.Space.md)
        .padding(.vertical, LingXiMetrics.Space.sm)
        .background(LXColor.window)
    }

    private func toggle(_ category: String) {
        if model.selectedCategories.contains(category) {
            model.selectedCategories.remove(category)
        } else {
            model.selectedCategories.insert(category)
        }
    }

    private var table: some View {
        let rows = model.visibleEvents.map(EventsRow.init)
        let sorted = rows.sorted(using: sortOrder)
        return Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("seq", value: \.id) { Text(String($0.id)).font(LXType.monoSmall) }
                .width(min: 60, ideal: 75)
            TableColumn("时间", value: \.timestamp) { Text($0.timestamp, style: .time).font(LXType.monoSmall) }
                .width(min: 90, ideal: 110)
            TableColumn("类别", value: \.raw.categoryRaw) { event in
                Text(event.raw.categoryRaw)
                    .font(LXType.monoSmall)
                    .foregroundStyle(categoryTint(event.raw.category))
            }
            .width(min: 150, ideal: 200)
            TableColumn("Session") { Text($0.raw.sessionID?.rawValue.prefix(10).description ?? "—")
                    .font(LXType.monoSmall).lineLimit(1).truncationMode(.middle) }
                .width(min: 100, ideal: 130)
            TableColumn("Turn") { Text($0.raw.turnID?.rawValue ?? "—").font(LXType.monoSmall) }
                .width(min: 70, ideal: 90)
            TableColumn("Object / Ref") { event in
                Text(event.raw.objectID ?? event.raw.referenceID ?? "—")
                    .font(LXType.monoSmall).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 140, ideal: 220)
        }
        .onChange(of: selection) {
            // Selecting a row is how the raw-JSON side panel gets its subject; nothing is written
            // back to Core from here.
            if let id = selection.max() { onSelect(id) }
        }
        .overlay {
            if sorted.isEmpty {
                ContentUnavailableView("无匹配事件", systemImage: "list.bullet.rectangle",
                                       description: Text(model.ringTruncated
                                                         ? "Core 已丢弃更早的事件。"
                                                         : "调整过滤条件，或先跑几轮。"))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.ringTruncated {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("环形缓冲已丢弃更早的事件：此处的空白不等于什么都没发生。")
                    Spacer()
                }
                .font(LXType.meta)
                .foregroundStyle(LXStatus.warning)
                .padding(.horizontal, LingXiMetrics.Space.md)
                .padding(.vertical, 6)
                .background(LXColor.window)
            }
        }
    }

    private func categoryTint(_ category: DebugTelemetryCategory) -> Color {
        switch category {
        case .cacheBust, .eCoreRecallFailed, .contextFailOpen, .recorderFault: return LXStatus.error
        case .cacheHit, .eCoreExactRestore, .eCoreSemanticRecall: return LXStatus.success
        case .eCorePageOut, .contextEviction, .cacheMiss: return LXStatus.warning
        default: return .primary
        }
    }
}

// MARK: - Raw telemetry

struct RawTelemetryPane: View {
    @ObservedObject var model: RuntimeObservatoryPresentationModel
    @Binding var selected: UInt64?
    let runtime: RuntimeFrontend
    @State private var paused = false
    @State private var parked: [DebugTelemetryEvent] = []

    var body: some View {
        HSplitView {
            list
            inspector
                .frame(minWidth: 320, maxWidth: 460)
        }
        .safeAreaInset(edge: .top) { controls }
    }

    private var shown: [DebugTelemetryEvent] { paused ? parked : model.visibleEvents }

    private var controls: some View {
        HStack(spacing: LingXiMetrics.Space.sm) {
            Button {
                if paused {
                    paused = false
                } else {
                    parked = model.visibleEvents
                    paused = true
                }
            } label: {
                Label(paused ? "继续" : "暂停", systemImage: paused ? "play" : "pause")
            }
            .controlSize(.large)
            Text(paused ? "已冻结 \(parked.count) 条" : "实时滚动中")
                .font(LXType.meta)
                .foregroundStyle(paused ? LXStatus.warning : .secondary)
            Spacer()
            Button {
                export()
            } label: {
                Label("导出 JSONL…", systemImage: "square.and.arrow.up")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, LingXiMetrics.Space.md)
        .padding(.vertical, LingXiMetrics.Space.sm)
        .background(LXColor.window)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(shown.enumerated().reversed()), id: \.element.sequence) { _, event in
                        row(event)
                            .id(event.sequence)
                            .background(selected == event.sequence ? LXColor.accent.opacity(0.12) : .clear)
                    }
                }
                .padding(.horizontal, LingXiMetrics.Space.sm)
                .padding(.vertical, LingXiMetrics.Space.xs)
            }
            .background(LXColor.content)
            .onChange(of: model.events.count) {
                // A paused view must stay put; scrolling it to the tail defeats the pause.
                guard !paused, model.followTail, let last = shown.last else { return }
                withAnimation(.none) { proxy.scrollTo(last.sequence, anchor: .bottom) }
            }
        }
    }

    private func row(_ event: DebugTelemetryEvent) -> some View {
        Button {
            selected = event.sequence
        } label: {
            HStack(spacing: LingXiMetrics.Space.xs) {
                Text("#\(event.sequence)")
                    .font(LXType.monoSmall)
                    .foregroundStyle(.secondary)
                Text(event.timestamp, style: .time)
                    .font(LXType.monoSmall)
                    .foregroundStyle(.secondary)
                Text(event.categoryRaw)
                    .font(LXType.monoSmall.weight(.semibold))
                Text(summary(event))
                    .font(LXType.monoSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func summary(_ event: DebugTelemetryEvent) -> String {
        var pieces: [String] = []
        if let audit = event.promptAudit {
            pieces.append("common=\(audit.stablePrefixCommonBytes)B")
        }
        if let cache = event.cacheSample {
            pieces.append("debt=\(cache.cacheDebt.value.map(String.init) ?? "n/a")")
        }
        if let ecore = event.eCoreEvent {
            if let phase = ecore.lifecyclePhase { pieces.append(phase) }
            if let reason = ecore.rejectionReason { pieces.append(reason) }
            pieces.append(ecore.objectID ?? ecore.referenceID ?? "")
        }
        if let eviction = event.eviction {
            pieces.append("\(eviction.objectType):\(eviction.tokenCost)t")
        }
        if let scheduler = event.scheduler {
            pieces.append("\(scheduler.kind.rawValue)")
        }
        if let object = event.objectID { pieces.append(object) }
        return pieces.filter { !$0.isEmpty }.joined(separator: " ")
    }

    @ViewBuilder private var inspector: some View {
        if let sequence = selected,
           let event = model.events.first(where: { $0.sequence == sequence }) {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                Text("事件 #\(event.sequence)")
                    .font(LXType.meta.weight(.semibold))
                ScrollView {
                    Text(Self.pretty(event) ?? "无法序列化该事件")
                        .font(LXType.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(LingXiMetrics.Space.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LXColor.window)
        } else {
            ContentUnavailableView("选择一条事件", systemImage: "curlybraces",
                                   description: Text("右侧显示 Core 返回的原始结构。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The literal DTO Core sent, with no GUI editorialising: when a reading looks wrong, the way to
    /// settle it is to see exactly what crossed the wire.
    static func pretty(_ event: DebugTelemetryEvent) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(event) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "observatory-\(Int(Date.now.timeIntervalSince1970)).jsonl"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lines = model.events.compactMap { event -> String? in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(event) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
        do {
            try lines.data(using: .utf8)?.write(to: url)
        } catch {
            runtime.actionError = "导出失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Panes over data Core already publishes
//
// These four read the same authoritative projection the main window uses. They are not debug-gated,
// because duplicating an existing Core reading behind a second transport would give the Observatory
// a number that can disagree with the product surface — and reconciling those two is exactly the
// work this window is supposed to remove.

struct AgentLoopPane: View {
    @ObservedObject var inspector: RuntimeInspectorPresentationModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                ObservatoryCard(title: "当前运行") {
                    ObservatoryKV(key: "状态", value: inspector.live?.status.rawValue)
                    ObservatoryKV(key: "Provider", value: inspector.live?.providerState?.rawValue)
                    ObservatoryKV(key: "Model", value: inspector.live?.modelID)
                    ObservatoryKV(key: "Context revision",
                                  value: inspector.live?.context.map { String($0.revision) })
                    ObservatoryKV(key: "Compaction gen",
                                  value: inspector.live?.context.map { String($0.compactionGeneration) })
                }
                ObservatoryCard(title: "分支预测 · Observation only") {
                    if let prediction = inspector.live?.context?.prediction {
                        ObservatoryKV(key: "hint", value: prediction.hint)
                        ObservatoryKV(key: "confidence", value: String(format: "%.3f", prediction.confidence))
                        ObservatoryKV(key: "support", value: String(prediction.support))
                        ObservatoryKV(key: "matchedOrder", value: "o\(prediction.matchedOrder)")
                        ObservatoryKV(key: "abstained", value: prediction.abstained ? "yes" : "no")
                        ObservatoryKV(key: "steps", value: String(prediction.steps))
                        ObservatoryKV(key: "hits / misses · hit rate", value: "\(prediction.hits) / \(prediction.misses) · \(prediction.steps > 0 ? String(format: "%.1f%%", Double(prediction.hits) / Double(prediction.steps) * 100) : "—")")
                    } else {
                        ObservatoryKV(key: "prediction", value: nil)
                    }
                }
            }
            .padding(LingXiMetrics.Space.md)
        }
        .background(LXColor.content)
    }
}

struct ToolsPane: View {
    @ObservedObject var inspector: RuntimeInspectorPresentationModel

    var body: some View {
        let tools = inspector.performance?.tools ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                ObservatoryCard(title: "本轮活跃工具（来自 Core）") {
                    if let active = inspector.live?.activeTools, !active.isEmpty {
                        ForEach(active, id: \.self) { Text($0).font(LXType.monoSmall) }
                    } else {
                        ObservatoryKV(key: "activeTools", value: "无")
                    }
                }
                ObservatoryCard(title: "上一轮工具耗时（diagnostics.performance）") {
                    if tools.isEmpty {
                        ObservatoryKV(key: "tools", value: "Core 未回报本轮工具耗时")
                    } else {
                        ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                            HStack(spacing: LingXiMetrics.Space.xs) {
                                Text("step \(tool.step)").font(LXType.meta).foregroundStyle(.secondary)
                                Text(tool.toolName).font(LXType.monoSmall)
                                Spacer()
                                Text(String(format: "%.0fms", tool.executionMilliseconds))
                                    .font(LXType.monoSmall).monospacedDigit()
                                Text(tool.permissionDecision).font(LXType.meta).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(LingXiMetrics.Space.md)
        }
        .background(LXColor.content)
    }
}

struct ProviderPane: View {
    @ObservedObject var inspector: RuntimeInspectorPresentationModel

    var body: some View {
        let calls = inspector.performance?.providerCalls ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                ObservatoryCard(title: "Provider 调用（Core 侧记录）") {
                    if calls.isEmpty {
                        ObservatoryKV(key: "providerCalls", value: "Core 未回报本轮 provider 调用")
                    } else {
                        ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                            HStack(spacing: LingXiMetrics.Space.xs) {
                                Text("#\(call.sequence)").font(LXType.meta).foregroundStyle(.secondary)
                                Text(call.model).font(LXType.monoSmall)
                                Text(call.reason).font(LXType.meta).foregroundStyle(.secondary)
                                Spacer()
                                Text("est \(call.estimatedPromptTokens) / act "
                                     + (call.actualUsage?.inputTokens.map(String.init) ?? "n/a"))
                                    .font(LXType.monoSmall).monospacedDigit()
                                Text("cache " + (call.actualUsage?.cacheReadTokens.map(String.init) ?? "n/a"))
                                    .font(LXType.monoSmall).monospacedDigit()
                            }
                        }
                    }
                }
                if let telemetry = inspector.performance?.cacheTelemetry {
                    ObservatoryCard(title: "Cache telemetry（性能报告内，Core 已算好）") {
                        ObservatoryKV(key: "raw", value: Self.summary(telemetry))
                    }
                }
            }
            .padding(LingXiMetrics.Space.md)
        }
        .background(LXColor.content)
    }

    static func summary(_ telemetry: ProviderCacheTelemetry) -> String {
        let ratio = telemetry.cacheHitRatio.map { String(format: "%.3f", $0) } ?? "n/a"
        return "read \(telemetry.cacheReadTokens.map(String.init) ?? "n/a") · "
            + "write \(telemetry.cacheWriteTokens.map(String.init) ?? "n/a") · "
            + "hit \(ratio) · epoch \(telemetry.epoch?.epoch.description ?? "n/a")"
    }
}

struct TasksPane: View {
    @ObservedObject var inspector: RuntimeInspectorPresentationModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                ObservatoryCard(title: "Subagents（Core agent tree 投影）") {
                    let rows = inspector.live?.subagents ?? []
                    if rows.isEmpty {
                        ObservatoryKV(key: "subagents", value: "无")
                    } else {
                        ForEach(rows) { row in
                            HStack(spacing: LingXiMetrics.Space.xs) {
                                Text(row.model ?? row.runID).font(LXType.monoSmall)
                                Spacer()
                                Text(row.status).font(LXType.meta).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ObservatoryCard(title: "Todos") {
                    let todos = inspector.live?.todos ?? []
                    if todos.isEmpty {
                        ObservatoryKV(key: "todos", value: "无")
                    } else {
                        ForEach(todos, id: \.id) { todo in
                            HStack(spacing: LingXiMetrics.Space.xs) {
                                Text(todo.title).font(LXType.meta)
                                Spacer()
                                Text(todo.status).font(LXType.meta).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(LingXiMetrics.Space.md)
        }
        .background(LXColor.content)
    }
}

#endif
