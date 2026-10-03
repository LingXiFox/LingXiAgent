import Foundation
import LingXiProtocol

/// Developer Debug Mode and the Runtime Observatory's read surface.
///
/// Every method here is a door onto state Core already holds or has been told by the bypass. None
/// of them compute anything Core does not already know, and none of them write anything a decision
/// path reads. That is the whole contract of this file: switching debug mode on is allowed to
/// change what can be *seen*, and nothing else.
///
/// While debug mode is off the hub does not exist, so the read methods throw `unsupportedCommand`
/// rather than answering with an empty page or a zeroed snapshot. Those are different facts —
/// "no Observatory is running" versus "an Observatory is running and found nothing" — and
/// collapsing them is the fabrication `getProviderMetrics` and `getRunTrace` already refuse to
/// commit for the same reason.
extension CoreHost {

    // MARK: - Status

    /// Answers even while disabled, which is the one deliberate exception to the rule above.
    ///
    /// It is how a client discovers whether this Core has an Observatory at all. A disabled
    /// Observatory reporting `enabled: false` is information; making it throw instead would make a
    /// switched-off Observatory indistinguishable from an old Core that never had the method.
    public func debugStatus(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<DebugObservatoryStatus> {
        let status = debugHub?.status() ?? DebugObservatoryStatus(
            enabled: false,
            recording: false,
            runName: nil,
            ringCapacity: DebugTelemetryHub.defaultCapacity,
            eventsBuffered: 0,
            eventsDropped: 0,
            archiveWriteFailures: 0
        )
        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: status
        )
    }

    // MARK: - Mode, recording, archive

    /// The only writer of debug mode.
    ///
    /// Its receipt carries the authoritative post-change status, so "re-read Core after a
    /// successful write" happens by reading the result Core handed over. That is deliberate: the
    /// alternative is a GUI that flips its own toggle and hopes Core agreed.
    public func debugModeUpdate(envelope: CommandEnvelope<UpdateDebugModeRequest>) async throws -> CommandReceipt<DebugObservatoryStatus> {
        await inFlightLock.acquire(commandID: envelope.commandID)
        defer { Task { await inFlightLock.release(commandID: envelope.commandID) } }

        if let cached = try await checkIdempotency(envelope: envelope, commandName: "debugModeUpdate",
                                                   as: DebugObservatoryStatus.self) {
            return cached
        }

        let status: DebugObservatoryStatus
        switch envelope.payload.action {
        case .setEnabled:
            guard let wanted = envelope.payload.enabled else {
                throw CoreError(code: .commandFailed,
                                message: "setEnabled 需要 enabled 字段；缺省不当作 false，那是两条不同的指令。")
            }
            status = await applyDebugMode(wanted)

        case .startRecording:
            status = try await startDebugRecording(runName: envelope.payload.runName)

        case .stopRecording:
            let hub = try requireDebugHub()
            // Awaited, so the receipt's `recording: false` means the archive is flushed and closed.
            await hub.detachRecorder()
            status = hub.status()

        case .clear:
            let hub = try requireDebugHub()
            hub.clear()
            status = hub.status()

        case .export:
            let hub = try requireDebugHub()
            try await exportDebugRun(hub: hub, to: envelope.payload.destinationPath,
                                     runName: envelope.payload.runName)
            status = hub.status()

        case .unknown:
            // A request this Core cannot parse is not executed. Falling back to any destructive
            // action here would let a version skew delete an archive nobody asked about.
            throw CoreError(code: .unsupportedCommand,
                            message: "无法识别的 debug action，未执行任何操作。")
        }

        let watermark = await runtimeEventLog.currentWatermark()
        let receipt = CommandReceipt<DebugObservatoryStatus>(
            commandID: envelope.commandID,
            applied: true,
            revision: nextRevision(),
            observedThrough: [watermark],
            result: status
        )
        try await recordIdempotency(envelope: envelope, commandName: "debugModeUpdate", receipt: receipt)
        return receipt
    }

    // MARK: - Reads

    public func debugSnapshot(envelope: QueryEnvelope<GetObservatoryRequest>) async throws -> ResponseEnvelope<RuntimeObservatorySnapshot> {
        let hub = try requireDebugHub()
        let sessionID = envelope.payload.sessionID
        // An unknown session has to fail rather than hand back an empty panel, or a mistyped
        // session id reads as "this session has no cache activity".
        let coord = try await coordinator(for: sessionID)
        let topN = min(max(1, envelope.payload.topN), 100)

        // The same authoritative projection `context.state` serves; the debug surface re-reads Core
        // rather than keeping its own copy of any of it.
        let context = await contextStateSnapshot(sessionID: sessionID)
        let (runID, turnID) = hub.correlation(sessionID: sessionID)

        let eCore = await buildECorePanel(hub: hub, sessionID: sessionID, topN: topN)
        let cursor = await coord.eventLog.currentCursor()
        let runtime = runtimeContextSnapshot
        let policy = runtime.policy
        let pCore: DebugPCorePanel?
        if let core = context.pCore {
            pCore = DebugPCorePanel(
                usedTokens: core.usedTokens,
                targetTokens: policy.pCoreTarget,
                softLimitTokens: policy.pCoreSoftLimit,
                hardLimitTokens: policy.pCoreHardLimit,
                stablePrefixBytes: hub.stablePrefixBytes(sessionID: sessionID),
                growingContextTokens: context.estimatedTokens,
                eCoreIndexTokens: nil
            )
        } else {
            pCore = nil
        }

        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: cursor,
            payload: RuntimeObservatorySnapshot(
                generatedAt: .now,
                sessionID: sessionID,
                revision: context.revision,
                runID: runID,
                turnID: turnID,
                pCore: pCore,
                eCore: eCore,
                cache: hub.cacheSample(sessionID: sessionID) ?? DebugCacheSampleMapper.from(context: context),
                prefixAudit: hub.prefixAudit(sessionID: sessionID),
                scheduler: hub.schedulerDecision(sessionID: sessionID),
                prediction: context.prediction,
                localRuntime: currentProviderID.flatMap { localRuntimeRegistry.status(providerID: $0) },
                runtimeContextPolicy: DebugRuntimeContextPolicy(
                    runtimeModelWindow: runtime.assembly?.contextProfile.contextWindowTokens,
                    effectivePolicy: ContextCachePolicySnapshot(policy: policy), generation: runtime.generation)
            )
        )
    }

    public func debugEvents(envelope: QueryEnvelope<GetObservatoryEventsRequest>) async throws -> ResponseEnvelope<DebugEventPage> {
        let hub = try requireDebugHub()
        let request = envelope.payload
        let limit = min(max(1, request.limit), 2000)
        let after = request.afterSequence ?? 0

        var fetched = hub.events(after: after, limit: limit)
        if let sessionFilter = request.sessionID {
            fetched = fetched.filter { $0.sessionID == sessionFilter }
        }
        if let runFilter = request.runID {
            fetched = fetched.filter { $0.runID == runFilter }
        }
        if let turnFilter = request.turnID {
            fetched = fetched.filter { $0.turnID == turnFilter }
        }
        if let categories = request.categories, !categories.isEmpty {
            let wanted = Set(categories)
            fetched = fetched.filter { wanted.contains($0.categoryRaw) }
        }

        return ResponseEnvelope(
            requestID: envelope.requestID,
            revision: currentRevision,
            eventCursor: await runtimeEventLog.currentCursor(),
            payload: DebugEventPage(
                events: fetched,
                latestSequence: hub.latestSequence(),
                // A gap is reported, never papered over: an empty page following a discarded range
                // has to look different from a genuinely idle stretch.
                truncated: hub.hasGap(before: after)
            )
        )
    }

    // MARK: - Assembly

    /// Flips the flag and builds or destroys the hub.
    ///
    /// Switching debug off drops the ring with it. Nothing is archived on the way out — silently
    /// writing a dump nobody asked for is a surprise, and `export` exists for that.
    private func applyDebugMode(_ enabled: Bool) async -> DebugObservatoryStatus {
        if enabled, debugHub == nil {
            let hub = DebugTelemetryHub()
            installDebugHub(hub)
            await propagateDebugHub(hub)
        } else if !enabled {
            await debugHub?.detachRecorder()
            installDebugHub(nil)
            await propagateDebugHub(nil)
        }
        // The save result is deliberately not acted on. A mode that will not persist is still the
        // mode Core is running right now; reporting it as anything else would be the invention this
        // whole surface exists to avoid.
        _ = debugModeStore.save(enabled: enabled)
        return debugHub?.status()
            ?? DebugObservatoryStatus(enabled: false, ringCapacity: DebugTelemetryHub.defaultCapacity)
    }

    /// Hands the hub to the subsystems that record into it.
    ///
    /// Two targets, both reached through the controller that owns them, so no other constructor in
    /// the product has to learn that debug mode exists. Passing nil detaches, which is what makes
    /// the disabled path a plain nil check at each recording site rather than a flag test.
    private func propagateDebugHub(_ hub: DebugTelemetryHub?) async {
        await cacheController.attachDebugHub(hub)
        await cacheController.ecoreStore.attachDebugHub(hub)
        // Loop verdicts are already traced by the session; with debug on they also become
        // categories in the ring. Off, the store has no observer and nothing changes.
        await diagnosticsStoreForDebug.setObserver(hub.map { hub in
            { @Sendable event in
                guard event.event.hasPrefix("agent.loop."),
                      let category = DebugTelemetryCategory(rawValue: event.event) else { return }
                hub.record(category, sessionID: event.sessionID, runID: event.runID)
            }
        })
    }

    /// Maps Core's own lifecycle events onto debug categories.
    ///
    /// Reads only: it takes what `broadcast` was already going to broadcast. The value is
    /// correlation — with these in the ring, an E-Core page-out and a cache bust can be placed
    /// inside the same turn rather than being lined up by eye against a clock.
    func recordDebugCoreEvent(_ event: CoreEvent) {
        guard let hub = debugHub else { return }
        let sessionID = eventSessionID(event)
        switch event {
        case .turnStarted:
            if let sessionID {
                hub.beginTurn(sessionID: sessionID, runID: nil, turnID: nil)
                hub.record(.agentTurnStarted, sessionID: sessionID)
            }
        case .turnCompleted:
            hub.record(.agentTurnCompleted, sessionID: sessionID)
            // Post-turn is where provider token counts finally exist, so the cache panel is
            // re-sampled from the authoritative snapshot rather than left at the pre-request view
            // recorded during fingerprinting.
            if let sessionID {
                Task { [weak self] in
                    guard let self, let hub = await self.debugHub else { return }
                    let snapshot = await self.contextStateSnapshot(sessionID: sessionID)
                    hub.recordCache(DebugCacheSampleMapper.from(context: snapshot),
                                    sessionID: sessionID)
                }
            }
        case .turnFailed:
            hub.record(.agentTurnCompleted, sessionID: sessionID)
        case .toolCallCompleted, .toolResult:
            hub.record(.toolCompleted, sessionID: sessionID)
        case .toolExecutionClaimed:
            hub.record(.toolStarted, sessionID: sessionID)
        case let .providerActivityChanged(activity):
            hub.record(.providerRequestStarted, sessionID: activity.sessionID)
        default:
            break
        }
    }

    private func requireDebugHub() throws -> DebugTelemetryHub {
        guard let hub = debugHub else {
            throw CoreError(code: .unsupportedCommand,
                            message: "开发者调试模式未开启；先经 debug.mode.update 打开。")
        }
        return hub
    }

    private func startDebugRecording(runName: String?) async throws -> DebugObservatoryStatus {
        let hub = try requireDebugHub()
        let name = runName?.isEmpty == false ? runName! : "run-\(Self.runNameStamp(.now))"
        // The name becomes a directory under the archive root, and it now arrives from a text
        // field. Anything that could leave that root, or hide itself there, is refused outright.
        guard Self.isValidRunName(name) else {
            throw CoreError(code: .commandFailed,
                            message: "运行名只能包含字母、数字、. _ -，且不能以 . 开头：\(name)")
        }
        let recorder = DebugRunRecorder(
            directory: storageLayout.debugArchive.appendingPathComponent(name, isDirectory: true)
        )
        let manifest = try? JSONEncoder.lingxiDebugManifest().encode(DebugRunManifest(
            runName: name,
            startedAt: .now,
            hubSchemaVersion: DebugTelemetryHub.schemaVersion,
            ringCapacity: hub.status().ringCapacity
        ))
        let opened = await recorder.start(runName: name, manifest: manifest)
        hub.setRecorder(recorder, runName: name)
        if !opened {
            // The archive did not open but the hub is attached. Surface it as an archive failure
            // rather than failing the request: the ring is still valid and a run must not be
            // punished for a storage problem.
            let reported = await recorder.snapshot().failures
            hub.noteArchiveFailures(reported + 1)
        }
        return hub.status()
    }

    static func isValidRunName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128, !name.hasPrefix(".") else { return false }
        return name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "." || $0 == "_" || $0 == "-"
        }
    }

    /// Pull-only, on explicit request. The recorder is flushed first so an exported run contains
    /// everything the ring already accepted.
    private func exportDebugRun(hub: DebugTelemetryHub, to destinationPath: String?,
                                runName: String?) async throws {
        guard let destinationPath, !destinationPath.isEmpty else {
            throw CoreError(code: .commandFailed, message: "export 需要 destinationPath。")
        }
        if let recorder = hub.activeRecorder() {
            await recorder.flush()
        }
        let url = URL(fileURLWithPath: destinationPath, isDirectory: true)
        let events = hub.events(after: 0, limit: Int.max)
        var payload = Data()
        // Same encoder as the live archive, so an exported run and a recorded one are byte-for-byte
        // comparable.
        let encoder = DebugTelemetryHub.archiveEncoder()
        for event in events {
            guard let line = try? encoder.encode(event) else { continue }
            payload.append(line)
            payload.append(0x0A)
        }
        let suffix = runName.map { "-\($0)" } ?? ""
        let fileURL = url.appendingPathComponent("telemetry\(suffix)-\(Self.runNameStamp(.now)).jsonl",
                                                isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try payload.write(to: fileURL, options: .atomic)
        } catch {
            throw CoreError(code: .persistence, message: "导出调试数据失败：\(String(describing: error))")
        }
    }

    /// E-Core census, assembled only when someone asks.
    ///
    /// These pulls are expensive by design: `heatSnapshot` recomputes the full distribution,
    /// `listObjects` scans the directory and reads one metadata file per object, and
    /// `storageMetrics` may scan once per session on cold start. None of them may happen on a
    /// per-turn path, which is why they live behind this RPC instead of in an event payload.
    private func buildECorePanel(hub: DebugTelemetryHub, sessionID: SessionID,
                                 topN: Int) async -> DebugECorePanel {
        let metrics = await ecoreStoreRef.storageMetrics(for: sessionID)
        let references = await ecoreStoreRef.references(sessionID: sessionID)
        let trace = await compactor.evictionTrace(sessionID: sessionID)
        let scoringActive = await compactor.evictionScoringActive(sessionID: sessionID)
        let heat = await cacheController.eCoreHeatSnapshot(sessionID: sessionID, topN: topN)
        let census = hub.pageOutCensus(sessionID: sessionID)

        // The compactor keeps only the most recent turn's trace, so "recent evictions" is honest
        // about that rather than implying a history Core does not hold.
        let evictions = trace.suffix(topN).map {
            DebugEvictionMapper.from($0, scoringActive: scoringActive)
        }

        // The metadata index is the old, narrower view: it enumerates `.meta.json` and so never
        // saw a page-out payload. Read alongside the census it becomes the reconciliation the
        // operator can check, instead of a silent undercount.
        let metaObjects = await ecoreStoreRef.listObjects(sessionID: sessionID)
        let (pageOutObjects, pageOutBytes) = census
        return DebugECorePanel(
            objectCount: metrics.count,
            totalBytes: metrics.totalBytes,
            referenceCount: references.count,
            metaIndexObjectCount: metaObjects.count,
            metaIndexTotalBytes: metaObjects.reduce(0) { $0 + $1.totalBytes },
            pageOutOnlyObjectCount: pageOutObjects,
            pageOutOnlyBytes: pageOutBytes,
            // Deprecated, literal: the meta index still cannot see page-outs. The authoritative
            // total above no longer depends on it, which is what `censusIsPhysical` states.
            pageOutsVisibleViaMetaIndex: false,
            censusIsPhysical: true,
            counters: hub.eCoreCounters(sessionID: sessionID),
            recentEvictions: evictions,
            heat: heat.map(DebugHeatMapper.from),
            heatTrackingEnabled: heat != nil
        )
    }

    private static func runNameStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

/// `manifest.json` beside an archived run, so a directory recovered weeks later says what it is.
struct DebugRunManifest: Codable, Sendable, Equatable {
    let runName: String
    let startedAt: Date
    let hubSchemaVersion: Int
    let ringCapacity: Int
}

extension JSONEncoder {
    /// Manifest sidecar for an archived run. Delegates to the archive encoder so every file inside
    /// one debug run agrees on date formatting.
    static func lingxiDebugManifest() -> JSONEncoder {
        DebugTelemetryHub.archiveEncoder()
    }
}

/// Maps Core's eviction entry onto the wire shape.
enum DebugEvictionMapper {
    static func from(_ entry: ContextEvictionTraceEntry, scoringActive: Bool) -> DebugEvictionEntry {
        DebugEvictionEntry(
            // Named `observedAt`, not `evictedAt`: Core's entry has no timestamp, so this is the
            // hub's clock at record time and nothing more.
            observedAt: .now,
            objectKey: entry.objectKey,
            objectType: entry.objectType,
            tokenCost: entry.tokenCost,
            retentionValue: entry.retentionValue,
            retentionScore: entry.retentionScore,
            evictionRank: entry.evictionRank,
            evictionReason: entry.evictionReason,
            // A `scorerUnavailable-` reason prefix is Core's own marker for the Fail-Open path.
            enteredECore: entry.evictionReason?.contains("scorerUnavailable") == false,
            scoringActiveAtSessionLevel: scoringActive
        )
    }
}

/// Maps Core's heat snapshot onto the wire shape.
enum DebugHeatMapper {
    static func from(_ snapshot: ECoreHeatSnapshot) -> DebugHeatSummary {
        DebugHeatSummary(
            objectCount: snapshot.objectCount,
            hotCount: snapshot.hotCount,
            coldCount: snapshot.coldCount,
            medianHeat: snapshot.medianHeat,
            madHeat: snapshot.madHeat,
            p80: snapshot.p80,
            p95: snapshot.p95,
            topObjects: snapshot.topHottestObjects.map {
                DebugHeatObject(objectID: $0.objectID.rawValue,
                                accessCount: $0.accessCount,
                                recallCount: $0.recallCount,
                                lastAccessedAt: $0.lastAccessedAt,
                                rawHeatScore: $0.rawHeatScore,
                                percentile: $0.percentile,
                                candidateZone: $0.candidateZone.rawValue)
            }
        )
    }
}

/// Fallback cache panel from the authoritative `ContextStateSnapshot`, used when the bypass has not
/// sampled this session yet — first snapshot after enabling, or a session with no completed turn.
///
/// The provenance tags are the point. `observedGranularity` is hardcoded nil in Core and nothing
/// produces it; `structuralPrefixStability` is a Double that can only be 0.0 or 1.0;
/// `volatileTailBytes` is a token estimate times four. Carrying them with those notes is what stops
/// a reader three hundred turns in from trusting them as measurements.
enum DebugCacheSampleMapper {
    /// From the structural health Core computed for this very turn.
    ///
    /// Richer than the snapshot-derived form: this is the same object Core's own bust accounting
    /// reads, sampled at the moment it was decided rather than reconstructed afterwards. The
    /// provider-reported token counts are absent here because they arrive later, from the response,
    /// and are filled in by the snapshot form.
    static func from(health: ClientStructuralCacheHealth, audit: DebugPrefixByteAudit?) -> DebugCacheSample {
        DebugCacheSample(
            cacheEpoch: health.cacheEpoch,
            epochReason: audit?.bustReason,
            cacheStatus: health.status,
            stablePrefixHash: health.stablePrefixHash,
            missDiagnostics: nil,
            cacheDebt: .unavailable(because: "debt lives on the scheduler, not on structural health"),
            promptTokens: .unavailable(because: "provider usage is recorded on the response path"),
            previousPromptTokens: .unavailable(because: "provider usage is recorded on the response path"),
            cacheReadTokens: .unavailable(because: "provider usage is recorded on the response path"),
            prefixReuseRatio: .unavailable(because: "needs two provider-reported token counts"),
            clientCausedBustRate: DebugMetric(value: health.clientCausedBustRate, provenance: .measured,
                                              basis: "clientCausedBusts / comparableRequests within this epoch"),
            clientCausedBusts: health.clientCausedBusts,
            comparableRequests: health.comparableRequests,
            appendOnlyContextRatio: DebugMetric(value: health.appendOnlyRatio, provenance: .coarse,
                                                basis: "Core assigns 1.0 when the turn appended and 0.5 when it "
                                                    + "did not, so this is a two-state flag scaled to a Double"),
            appendOnlyViolations: health.appendOnlyViolations,
            volatileTailBytes: DebugMetric(value: health.volatileTailBytes, provenance: .estimated,
                                           basis: "current-turn token estimate multiplied by four; "
                                                + "not a measured byte count"),
            structuralPrefixStability: DebugMetric(
                value: health.prefixMutationDetected ? 0.0 : 1.0, provenance: .coarse,
                basis: "derived from a Bool: 0.0 means a mutation was detected, 1.0 means none was. "
                     + "It is not a proportion and cannot express partial prefix survival — "
                     + "DebugPrefixByteAudit's common-byte count is what answers that."),
            observedGranularity: .unavailable(because: "Core hardcodes this nil and no code path produces "
                                                      + "a value; provider block granularity is an external fact")
        )
    }

    static func from(context: ContextStateSnapshot) -> DebugCacheSample {
        let cache = context.providerCache
        let promptTokens = cache?.promptTokens
        let previousPromptTokens = cache?.previousPromptTokens
        let cacheReadTokens = cache?.cacheReadTokens

        let reuse: DebugMetric<Double>
        if let read = cacheReadTokens, let previous = previousPromptTokens, previous > 0 {
            reuse = DebugMetric(value: min(1.0, Double(read) / Double(previous)),
                                provenance: .coreReported,
                                basis: "cacheReadTokens / previousPromptTokens, both as reported by the provider")
        } else {
            reuse = .unavailable(because: "needs two provider-reported token counts in the same epoch")
        }

        return DebugCacheSample(
            cacheEpoch: cache?.cacheEpoch,
            epochReason: cache?.epochReason,
            cacheStatus: cache?.cacheStatus,
            stablePrefixHash: cache?.stablePrefixHash,
            missDiagnostics: cache?.missDiagnostics,
            cacheDebt: DebugMetric(value: cache?.cacheDebt, provenance: .measured,
                                   basis: "CacheAwareContextScheduler debt counter"),
            promptTokens: promptTokens.map { DebugMetric(value: $0, provenance: .coreReported) }
                ?? .unavailable(because: "provider reported no usage for this turn"),
            previousPromptTokens: previousPromptTokens.map { DebugMetric(value: $0, provenance: .coreReported) }
                ?? .unavailable(because: "no previous turn in this epoch"),
            cacheReadTokens: cacheReadTokens.map { DebugMetric(value: $0, provenance: .coreReported) }
                ?? .unavailable(because: "provider reported no cached tokens"),
            prefixReuseRatio: reuse,
            clientCausedBustRate: DebugMetric(value: context.clientCausedBustRate, provenance: .measured,
                                              basis: "client-caused busts over comparable requests, epoch-scoped"),
            clientCausedBusts: context.clientCausedBusts,
            comparableRequests: context.comparableRequests,
            appendOnlyContextRatio: DebugMetric(value: context.appendOnlyContextRatio, provenance: .measured,
                                                basis: "append-only turns over comparable requests, epoch-scoped"),
            appendOnlyViolations: context.appendOnlyViolations,
            volatileTailBytes: DebugMetric(value: context.volatileTailBytes, provenance: .estimated,
                                           basis: "current-turn token estimate multiplied by four; "
                                                + "not a measured byte count"),
            structuralPrefixStability: DebugMetric(value: context.structuralPrefixStability, provenance: .coarse,
                                                   basis: "typed Double but Core can only ever report "
                                                        + "0.0 (mutation detected) or 1.0 (none); it is not a ratio"),
            observedGranularity: .unavailable(because: "Core hardcodes this nil and no code path produces "
                                                      + "a value; provider block granularity is an external fact")
        )
    }
}
