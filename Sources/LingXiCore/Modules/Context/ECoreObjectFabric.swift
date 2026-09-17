import Foundation
import LingXiProtocol

/// 强类型上下文对象唯一标识符
public struct ContextObjectID: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public var description: String { rawValue }

    public init(_ rawValue: String) throws {
        // 安全防御：严格禁止路径穿越，只允许字母数字短横线与下划线
        guard !rawValue.isEmpty,
              rawValue.count <= 128,
              rawValue.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            throw CoreError(code: .toolArgumentInvalid, message: "Invalid ContextObjectID: \(rawValue)")
        }
        self.rawValue = rawValue
    }

    public init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        try self.init(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// 依据工具调用与内容哈希确定性生成 ContextObjectID
    public static func generate(toolName: String, callID: ToolCallID, content: String) -> ContextObjectID {
        let sanitizedTool = toolName.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let cleanTool = sanitizedTool.isEmpty ? "obj" : sanitizedTool
        let cleanCall = callID.rawValue.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }.prefix(12)

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let hashStr = String(format: "%08llx", hash)
        return ContextObjectID(unchecked: "obj_\(cleanTool)_\(cleanCall)_\(hashStr)")
    }
}

/// 外部权威观测对象元数据（E-Core Context Object Metadata）
public struct ObservationMetadata: Sendable, Equatable, Codable {
    public let objectID: ContextObjectID
    public let toolCallID: ToolCallID
    public let toolName: String
    public let contentType: String
    public let totalLines: Int
    public let totalBytes: Int
    public let createdAt: Date
    public let contentHash: String

    public init(
        objectID: ContextObjectID,
        toolCallID: ToolCallID,
        toolName: String,
        contentType: String = "text/plain",
        totalLines: Int,
        totalBytes: Int,
        createdAt: Date = .now,
        contentHash: String
    ) {
        self.objectID = objectID
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.contentType = contentType
        self.totalLines = totalLines
        self.totalBytes = totalBytes
        self.createdAt = createdAt
        self.contentHash = contentHash
    }
}

/// 召回切片数据传输对象
public struct RecallChunk: Sendable, Equatable, Codable {
    public let objectID: ContextObjectID
    public let offsetBytes: Int
    public let lengthBytes: Int
    public let content: String
    public let hasMore: Bool
    public let startLine: Int
    public let endLine: Int
    public let totalLines: Int
    public let totalBytes: Int

    public init(
        objectID: ContextObjectID,
        offsetBytes: Int,
        lengthBytes: Int,
        content: String,
        hasMore: Bool,
        startLine: Int,
        endLine: Int,
        totalLines: Int,
        totalBytes: Int
    ) {
        self.objectID = objectID
        self.offsetBytes = offsetBytes
        self.lengthBytes = lengthBytes
        self.content = content
        self.hasMore = hasMore
        self.startLine = startLine
        self.endLine = endLine
        self.totalLines = totalLines
        self.totalBytes = totalBytes
    }
}

/// 会话级外部存储指标（O(1) 维护，避免重复整盘扫描）
public struct SessionStorageMetrics: Sendable, Equatable {
    public let count: Int
    public let totalBytes: Int

    public init(count: Int = 0, totalBytes: Int = 0) {
        self.count = count
        self.totalBytes = totalBytes
    }
}

/// E-Core 对象 Fabric 存储器：负责管理会话级外部持久化对象。
/// 遵循三大纪律八项注意：
/// 1. Fail-Open：所有写入与读取异常降级处理，绝不崩溃智能体主流程。
/// 2. 安全防路径穿越：严密过滤 objectID 字符。
/// 3. 原子写入与去重。
public actor ECoreObjectStore {
    public let baseDirectory: URL
    public let configuration: ContextObjectFabricConfiguration
    public let telemetryLogger: ECoreTelemetryLogger
    private var metadataCache: [SessionID: [ContextObjectID: ObservationMetadata]] = [:]
    private var heatStates: [SessionID: [ContextObjectID: ECoreHeatState]] = [:]
    private var projectionCounts: [SessionID: [ContextObjectID: Int]] = [:]
    private var cachedMetrics: [SessionID: SessionStorageMetrics] = [:]

    public init(
        baseDirectory: URL? = nil,
        configuration: ContextObjectFabricConfiguration = ContextObjectFabricConfiguration(),
        telemetryLogger: ECoreTelemetryLogger? = nil
    ) {
        self.configuration = configuration
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.baseDirectory = home.appendingPathComponent(".lingxiagent", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        }
        self.telemetryLogger = telemetryLogger ?? ECoreTelemetryLogger(baseDirectory: self.baseDirectory)
    }

    /// 获取特定 Session 的对象存储根目录
    private func sessionObjectsDirectory(sessionID: SessionID) -> URL {
        let safeSessionID = sessionID.rawValue.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return baseDirectory
            .appendingPathComponent(safeSessionID, isDirectory: true)
            .appendingPathComponent("objects", isDirectory: true)
    }

    /// 旁路存储对象：如果超过阈值且开启了 ecoreStorageEnabled，则持久化到磁盘
    @discardableResult
    public func store(
        sessionID: SessionID,
        toolCallID: ToolCallID,
        toolName: String,
        content: String,
        contentType: String = "text/plain",
        force: Bool = false
    ) async -> ObservationMetadata? {
        guard configuration.ecoreStorageEnabled else { return nil }
        let byteCount = content.utf8.count
        guard force || byteCount >= configuration.objectizationThreshold else {
            return nil
        }

        let objectID = ContextObjectID.generate(toolName: toolName, callID: toolCallID, content: content)

        // 计算行数
        var lineCount = 0
        for byte in content.utf8 {
            if byte == 10 { // '\n'
                lineCount += 1
            }
        }
        if !content.isEmpty && !content.hasSuffix("\n") {
            lineCount += 1
        }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let contentHash = String(format: "%016llx", hash)

        let metadata = ObservationMetadata(
            objectID: objectID,
            toolCallID: toolCallID,
            toolName: toolName,
            contentType: contentType,
            totalLines: max(1, lineCount),
            totalBytes: byteCount,
            createdAt: .now,
            contentHash: contentHash
        )

        // Fail-Open 磁盘写入
        do {
            let objectsDir = sessionObjectsDirectory(sessionID: sessionID)
            try FileManager.default.createDirectory(at: objectsDir, withIntermediateDirectories: true)

            let targetURL = objectsDir.appendingPathComponent("\(objectID.rawValue).txt", isDirectory: false)
            let tempURL = objectsDir.appendingPathComponent(".\(objectID.rawValue).\(UUID().uuidString).tmp", isDirectory: false)
            let metaURL = objectsDir.appendingPathComponent("\(objectID.rawValue).meta.json", isDirectory: false)

            if !FileManager.default.fileExists(atPath: targetURL.path) {
                try content.write(to: tempURL, atomically: true, encoding: .utf8)
                _ = try? FileManager.default.removeItem(at: targetURL)
                try FileManager.default.moveItem(at: tempURL, to: targetURL)
            }

            let metaData = try JSONEncoder().encode(metadata)
            try metaData.write(to: metaURL, options: .atomic)

            if metadataCache[sessionID] == nil {
                metadataCache[sessionID] = [:]
            }
            let previousMeta = metadataCache[sessionID]?[objectID]
            metadataCache[sessionID]?[objectID] = metadata

            if var existing = cachedMetrics[sessionID] {
                if let previousMeta {
                    existing = SessionStorageMetrics(
                        count: existing.count,
                        totalBytes: max(0, existing.totalBytes - previousMeta.totalBytes + byteCount)
                    )
                } else {
                    existing = SessionStorageMetrics(
                        count: existing.count + 1,
                        totalBytes: existing.totalBytes + byteCount
                    )
                }
                cachedMetrics[sessionID] = existing
            } else {
                cachedMetrics[sessionID] = SessionStorageMetrics(count: 1, totalBytes: byteCount)
            }

            if configuration.heatTrackingEnabled {
                let event = ECoreAccessEvent(
                    sessionID: sessionID,
                    objectID: objectID,
                    eventType: .objectStored,
                    timestamp: .now,
                    offsetBytes: 0,
                    requestedBytes: byteCount,
                    returnedBytes: byteCount,
                    toolCallID: toolCallID
                )
                let logger = self.telemetryLogger
                Task {
                    await logger.appendEvent(event)
                }

                if heatStates[sessionID] == nil {
                    heatStates[sessionID] = [:]
                }
                let weight = configuration.heatWeightPolicy.weight(for: .objectStored)
                if var existing = heatStates[sessionID]?[objectID] {
                    existing.rawHeatScore = ECoreHeatScorer.accumulate(
                        currentScore: existing.rawHeatScore,
                        lastUpdatedAt: existing.lastAccessedAt,
                        now: .now,
                        eventWeight: weight,
                        halfLifeSeconds: configuration.heatDecayHalfLifeSeconds
                    )
                    existing.accessCount += 1
                    existing.lastAccessedAt = .now
                    heatStates[sessionID]?[objectID] = existing
                } else {
                    let initialHeat = (weight.isFinite && weight >= 0) ? weight : 0.0
                    heatStates[sessionID]?[objectID] = ECoreHeatState(
                        objectID: objectID,
                        accessCount: 1,
                        recallCount: 0,
                        lastAccessedAt: .now,
                        rawHeatScore: initialHeat,
                        percentile: 0.5,
                        robustZScore: 0.0,
                        candidateZone: .cold
                    )
                }
            }

            return metadata
        } catch {
            // Fail-open: 记录警告但不中断
            FileHandle.standardError.write(Data("[E-CORE WARNING] Failed to persist object \(objectID.rawValue): \(error)\n".utf8))
            return nil
        }
    }

    /// 旁路记录对象投影观测事件（Phase 0.6: 纯观测，零阻塞，零热度权重贡献）
    public func recordProjection(
        sessionID: SessionID,
        objectID: ContextObjectID,
        originalBytes: Int,
        turnID: String? = nil,
        revision: Int? = nil
    ) {
        guard configuration.heatTrackingEnabled else { return }

        let meta = metadataCache[sessionID]?[objectID]
        let createdAt = meta?.createdAt ?? .now
        let objectAge = max(0.0, Date.now.timeIntervalSince(createdAt))

        let currentCount = (projectionCounts[sessionID]?[objectID] ?? 0) + 1
        if projectionCounts[sessionID] == nil {
            projectionCounts[sessionID] = [:]
        }
        projectionCounts[sessionID]?[objectID] = currentCount

        let event = ECoreAccessEvent(
            sessionID: sessionID,
            objectID: objectID,
            eventType: .objectProjected,
            timestamp: .now,
            offsetBytes: 0,
            requestedBytes: originalBytes,
            returnedBytes: originalBytes,
            toolCallID: meta?.toolCallID,
            turnID: turnID,
            revision: revision,
            projectionCount: currentCount,
            objectAge: objectAge,
            originalBytes: originalBytes
        )
        let logger = self.telemetryLogger
        Task {
            await logger.appendEvent(event)
        }
        // 注意红线：绝对不增加任何 Heat Weight，不改变 candidateZone
    }

    /// 获取完整对象内容
    public func fetch(sessionID: SessionID, objectID: ContextObjectID) async throws -> String? {
        let objectsDir = sessionObjectsDirectory(sessionID: sessionID)
        let fileURL = objectsDir.appendingPathComponent("\(objectID.rawValue).txt", isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    /// 精确范围召回（context_recall 核心调用）
    public func recall(
        sessionID: SessionID,
        objectID: ContextObjectID,
        offsetBytes: Int = 0,
        limitBytes: Int? = nil,
        limitLines: Int? = nil
    ) async throws -> RecallChunk? {
        guard let content = try await fetch(sessionID: sessionID, objectID: objectID) else {
            if configuration.heatTrackingEnabled {
                let missEvent = ECoreAccessEvent(
                    sessionID: sessionID,
                    objectID: objectID,
                    eventType: .recallMiss,
                    timestamp: .now,
                    offsetBytes: offsetBytes,
                    requestedBytes: limitBytes
                )
                let logger = self.telemetryLogger
                Task {
                    await logger.appendEvent(missEvent)
                }

                let missWeight = configuration.heatWeightPolicy.weight(for: .recallMiss)
                if missWeight > 0, var state = heatStates[sessionID]?[objectID] {
                    state.rawHeatScore = ECoreHeatScorer.accumulate(
                        currentScore: state.rawHeatScore,
                        lastUpdatedAt: state.lastAccessedAt,
                        now: .now,
                        eventWeight: missWeight,
                        halfLifeSeconds: configuration.heatDecayHalfLifeSeconds
                    )
                    state.lastAccessedAt = .now
                    heatStates[sessionID]?[objectID] = state
                }
            }
            return nil
        }

        let maxBytes = min(limitBytes ?? configuration.recallMaxBytes, configuration.recallMaxBytes)
        let maxLines = min(limitLines ?? configuration.recallMaxLines, configuration.recallMaxLines)

        let totalBytes = content.utf8.count
        guard offsetBytes >= 0, offsetBytes < totalBytes else {
            return RecallChunk(
                objectID: objectID,
                offsetBytes: offsetBytes,
                lengthBytes: 0,
                content: "",
                hasMore: false,
                startLine: 1,
                endLine: 1,
                totalLines: 1,
                totalBytes: totalBytes
            )
        }

        let utf8Data = Data(content.utf8)
        let startIdx = offsetBytes
        let endIdx = min(totalBytes, startIdx + maxBytes)
        let sliceData = utf8Data.subdata(in: startIdx..<endIdx)

        let sliceString = String(decoding: sliceData, as: UTF8.self)

        // 截断至指定行数限制
        let lines = sliceString.components(separatedBy: "\n")
        let finalSlice: String
        let actualLinesUsed: Int
        if lines.count > maxLines {
            var sliceWithNewline = lines.prefix(maxLines).joined(separator: "\n")
            if startIdx + sliceWithNewline.utf8.count < totalBytes && utf8Data[startIdx + sliceWithNewline.utf8.count] == 10 {
                sliceWithNewline.append("\n")
            }
            finalSlice = sliceWithNewline
            actualLinesUsed = maxLines
        } else {
            finalSlice = sliceString
            actualLinesUsed = lines.count
        }

        let actualLength = finalSlice.utf8.count
        let hasMore = (startIdx + actualLength) < totalBytes

        // 计算当前 offset 处的行号
        let prefixData = utf8Data.prefix(startIdx)
        var startLine = 1
        for b in prefixData {
            if b == 10 { startLine += 1 }
        }
        let endLine = startLine + max(0, actualLinesUsed - 1)

        var totalLines = 0
        for b in utf8Data {
            if b == 10 { totalLines += 1 }
        }
        if !content.isEmpty && !content.hasSuffix("\n") {
            totalLines += 1
        }

        let chunk = RecallChunk(
            objectID: objectID,
            offsetBytes: startIdx,
            lengthBytes: actualLength,
            content: finalSlice,
            hasMore: hasMore,
            startLine: startLine,
            endLine: endLine,
            totalLines: max(1, totalLines),
            totalBytes: totalBytes
        )

        if configuration.heatTrackingEnabled {
            let recallEvent = ECoreAccessEvent(
                sessionID: sessionID,
                objectID: objectID,
                eventType: .objectRecalled,
                timestamp: .now,
                offsetBytes: startIdx,
                requestedBytes: maxBytes,
                returnedBytes: actualLength
            )
            let logger = self.telemetryLogger
            Task {
                await logger.appendEvent(recallEvent)
            }

            let weight = configuration.heatWeightPolicy.weight(for: .objectRecalled)
            var state = heatStates[sessionID]?[objectID] ?? ECoreHeatState(
                objectID: objectID,
                accessCount: 0,
                recallCount: 0,
                lastAccessedAt: .now,
                rawHeatScore: 0.0,
                percentile: 0.5,
                robustZScore: 0.0,
                candidateZone: .cold
            )
            state.rawHeatScore = ECoreHeatScorer.accumulate(
                currentScore: state.rawHeatScore,
                lastUpdatedAt: state.lastAccessedAt,
                now: .now,
                eventWeight: weight,
                halfLifeSeconds: configuration.heatDecayHalfLifeSeconds
            )
            state.accessCount += 1
            state.recallCount += 1
            state.lastAccessedAt = .now
            if heatStates[sessionID] == nil {
                heatStates[sessionID] = [:]
            }
            heatStates[sessionID]?[objectID] = state
        }

        return chunk
    }

    /// 获取对象元数据
    public func metadata(sessionID: SessionID, objectID: ContextObjectID) async -> ObservationMetadata? {
        if let cached = metadataCache[sessionID]?[objectID] {
            return cached
        }
        let objectsDir = sessionObjectsDirectory(sessionID: sessionID)
        let metaURL = objectsDir.appendingPathComponent("\(objectID.rawValue).meta.json", isDirectory: false)
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(ObservationMetadata.self, from: data) else {
            return nil
        }
        if metadataCache[sessionID] == nil {
            metadataCache[sessionID] = [:]
        }
        metadataCache[sessionID]?[objectID] = meta
        return meta
    }

    /// 检查对象是否存在
    public func hasObject(sessionID: SessionID, objectID: ContextObjectID) async -> Bool {
        let objectsDir = sessionObjectsDirectory(sessionID: sessionID)
        let fileURL = objectsDir.appendingPathComponent("\(objectID.rawValue).txt", isDirectory: false)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// 列出指定会话下所有沉淀的 E-Core 观测对象元数据
    public func listObjects(sessionID: SessionID) async -> [ObservationMetadata] {
        let objectsDir = sessionObjectsDirectory(sessionID: sessionID)
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: objectsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return Array(metadataCache[sessionID]?.values ?? [:].values)
        }

        var results: [ObservationMetadata] = []
        for url in fileURLs where url.lastPathComponent.hasSuffix(".meta.json") {
            let baseName = url.deletingPathExtension().deletingPathExtension().lastPathComponent
            if let objID = try? ContextObjectID(baseName) {
                if let meta = await metadata(sessionID: sessionID, objectID: objID) {
                    results.append(meta)
                }
            }
        }
        if results.isEmpty, let cached = metadataCache[sessionID] {
            return Array(cached.values)
        }
        return results
    }

    /// 依据保留的 ToolCallIDs 裁剪废弃的观测对象文件与缓存（用于撤回或会话状态协同）
    public func prune(sessionID: SessionID, keepingToolCallIDs: Set<ToolCallID>) async {
        if keepingToolCallIDs.isEmpty {
            await cleanSession(sessionID: sessionID)
            return
        }
        let objectsDir = sessionObjectsDirectory(sessionID: sessionID)
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: objectsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in fileURLs where url.lastPathComponent.hasSuffix(".meta.json") {
            let baseName = url.deletingPathExtension().deletingPathExtension().lastPathComponent
            guard let objID = try? ContextObjectID(baseName),
                  let meta = await metadata(sessionID: sessionID, objectID: objID) else { continue }
            if !keepingToolCallIDs.contains(meta.toolCallID) {
                metadataCache[sessionID]?.removeValue(forKey: objID)
                heatStates[sessionID]?.removeValue(forKey: objID)
                projectionCounts[sessionID]?.removeValue(forKey: objID)
                let txtURL = objectsDir.appendingPathComponent("\(objID.rawValue).txt", isDirectory: false)
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: txtURL)
            }
        }
        if projectionCounts[sessionID]?.isEmpty == true {
            projectionCounts.removeValue(forKey: sessionID)
        }
        if let remaining = metadataCache[sessionID]?.values {
            cachedMetrics[sessionID] = SessionStorageMetrics(
                count: remaining.count,
                totalBytes: remaining.reduce(0) { $0 + $1.totalBytes }
            )
        } else {
            cachedMetrics[sessionID] = SessionStorageMetrics(count: 0, totalBytes: 0)
        }
    }

    /// 重置或清理 session 存储
    public func cleanSession(sessionID: SessionID) async {
        metadataCache.removeValue(forKey: sessionID)
        heatStates.removeValue(forKey: sessionID)
        projectionCounts.removeValue(forKey: sessionID)
        cachedMetrics.removeValue(forKey: sessionID)
        let objectsDir = sessionObjectsDirectory(sessionID: sessionID)
        try? FileManager.default.removeItem(at: objectsDir)
    }

    /// 获取会话级外部存储指标（O(1) 内存访问，仅冷启动时扫描一次）
    public func storageMetrics(for sessionID: SessionID) async -> SessionStorageMetrics {
        if let cached = cachedMetrics[sessionID] {
            return cached
        }
        let objects = await listObjects(sessionID: sessionID)
        let metrics = SessionStorageMetrics(
            count: objects.count,
            totalBytes: objects.reduce(0) { $0 + $1.totalBytes }
        )
        cachedMetrics[sessionID] = metrics
        return metrics
    }

    /// 获取特定对象的投影计数（供测试与诊断使用）
    public func projectionCount(sessionID: SessionID, objectID: ContextObjectID) -> Int? {
        projectionCounts[sessionID]?[objectID]
    }

    /// 获取特定会话的全部投影计数状态（供测试与诊断使用）
    public func allProjectionCounts(sessionID: SessionID) -> [ContextObjectID: Int]? {
        projectionCounts[sessionID]
    }

    /// 获取当前内存中的热度状态（Derived State，供可观测性与测试使用）
    public func heatState(
        sessionID: SessionID,
        objectID: ContextObjectID,
        now: Date? = nil
    ) -> ECoreHeatState? {
        guard var state = heatStates[sessionID]?[objectID] else { return nil }
        if let now {
            let elapsed = max(0.0, now.timeIntervalSince(state.lastAccessedAt))
            state.rawHeatScore = ECoreHeatScorer.decayedScore(
                currentScore: state.rawHeatScore,
                elapsedSeconds: elapsed,
                halfLifeSeconds: configuration.heatDecayHalfLifeSeconds
            )
        }
        return state
    }

    /// 生成当前会话的 E-Core 热度调试与可观测性快照（Phase 0 惰性统计计算，按需全量计算）
    public func heatSnapshot(
        sessionID: SessionID,
        topN: Int = 10,
        now: Date = .now
    ) async -> ECoreHeatSnapshot? {
        guard configuration.heatTrackingEnabled else { return nil }
        guard var states = heatStates[sessionID], !states.isEmpty else {
            return nil
        }

        // 1. 基于当前时间计算每个对象的有效衰减热度（纯时间流逝衰减，不增加事件权重）
        for (id, var s) in states {
            let elapsed = max(0.0, now.timeIntervalSince(s.lastAccessedAt))
            s.rawHeatScore = ECoreHeatScorer.decayedScore(
                currentScore: s.rawHeatScore,
                elapsedSeconds: elapsed,
                halfLifeSeconds: configuration.heatDecayHalfLifeSeconds
            )
            states[id] = s
        }

        let allScores = states.values.map(\.rawHeatScore).sorted()
        let median = RobustDistributionCalculator.median(allScores)
        let mad = RobustDistributionCalculator.mad(allScores, median: median)

        let p50 = RobustDistributionCalculator.quantile(0.50, sortedValues: allScores)
        let p70 = RobustDistributionCalculator.quantile(0.70, sortedValues: allScores)
        let p80 = RobustDistributionCalculator.quantile(0.80, sortedValues: allScores)
        let p90 = RobustDistributionCalculator.quantile(0.90, sortedValues: allScores)
        let p95 = RobustDistributionCalculator.quantile(0.95, sortedValues: allScores)

        // 2. 为每个对象计算 percentile、robustZScore 和 candidateZone
        // 约定：percentile >= 0.8 为 hot，否则为 cold
        var hotCount = 0
        var coldCount = 0

        for (id, var s) in states {
            let rank = RobustDistributionCalculator.percentileRank(value: s.rawHeatScore, sortedValues: allScores)
            let zScore = RobustDistributionCalculator.robustZScore(value: s.rawHeatScore, median: median, mad: mad)
            s.percentile = rank
            s.robustZScore = zScore
            if rank >= 0.8 {
                s.candidateZone = .hot
                hotCount += 1
            } else {
                s.candidateZone = .cold
                coldCount += 1
            }
            states[id] = s
        }
        heatStates[sessionID] = states

        // 3. 排序提取 Top-N Hottest
        let sortedByHeat = states.values.sorted {
            if $0.rawHeatScore != $1.rawHeatScore {
                return $0.rawHeatScore > $1.rawHeatScore
            }
            return $0.lastAccessedAt > $1.lastAccessedAt
        }
        let topHottest = Array(sortedByHeat.prefix(max(1, topN)))

        return ECoreHeatSnapshot(
            sessionID: sessionID,
            objectCount: states.count,
            hotCount: hotCount,
            coldCount: coldCount,
            medianHeat: median,
            madHeat: mad,
            p50: p50,
            p70: p70,
            p80: p80,
            p90: p90,
            p95: p95,
            topHottestObjects: topHottest
        )
    }

    /// 导出当前会话的 E-Core 观测期统计指标（完全只读、旁路）
    public func exportObservationMetrics(
        sessionID: SessionID,
        now: Date = .now
    ) async -> ECoreObservationMetrics {
        let events = await telemetryLogger.readEvents(for: sessionID)
        let metas = await listObjects(sessionID: sessionID)
        return ECoreObservationAnalyzer.analyze(
            events: events,
            metadataList: metas,
            now: now,
            halfLifeSeconds: configuration.heatDecayHalfLifeSeconds,
            weightPolicy: configuration.heatWeightPolicy
        )
    }

    /// 导出所有会话全局聚合的 E-Core 观测期统计指标（完全只读、旁路）
    public func exportGlobalObservationMetrics(
        now: Date = .now
    ) async -> ECoreObservationMetrics {
        return ECoreObservationAnalyzer.analyzeDirectory(
            baseDirectory: baseDirectory,
            now: now,
            halfLifeSeconds: configuration.heatDecayHalfLifeSeconds,
            weightPolicy: configuration.heatWeightPolicy
        )
    }
}
