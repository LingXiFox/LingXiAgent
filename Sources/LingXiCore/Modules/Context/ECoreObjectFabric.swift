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

/// E-Core 对象 Fabric 存储器：负责管理会话级外部持久化对象。
/// 遵循三大纪律八项注意：
/// 1. Fail-Open：所有写入与读取异常降级处理，绝不崩溃智能体主流程。
/// 2. 安全防路径穿越：严密过滤 objectID 字符。
/// 3. 原子写入与去重。
public actor ECoreObjectStore {
    public let baseDirectory: URL
    public let configuration: ContextObjectFabricConfiguration
    private var metadataCache: [SessionID: [ContextObjectID: ObservationMetadata]] = [:]

    public init(
        baseDirectory: URL? = nil,
        configuration: ContextObjectFabricConfiguration = ContextObjectFabricConfiguration()
    ) {
        self.configuration = configuration
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.baseDirectory = home.appendingPathComponent(".lingxiagent", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        }
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
            metadataCache[sessionID]?[objectID] = metadata
            return metadata
        } catch {
            // Fail-open: 记录警告但不中断
            FileHandle.standardError.write(Data("[E-CORE WARNING] Failed to persist object \(objectID.rawValue): \(error)\n".utf8))
            return nil
        }
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

        return RecallChunk(
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
        for url in fileURLs where url.pathExtension == "json" && url.lastPathComponent.contains(".meta.") {
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

        for url in fileURLs where url.pathExtension == "json" && url.lastPathComponent.contains(".meta.") {
            let baseName = url.deletingPathExtension().deletingPathExtension().lastPathComponent
            guard let objID = try? ContextObjectID(baseName),
                  let meta = await metadata(sessionID: sessionID, objectID: objID) else { continue }
            if !keepingToolCallIDs.contains(meta.toolCallID) {
                metadataCache[sessionID]?.removeValue(forKey: objID)
                let txtURL = objectsDir.appendingPathComponent("\(objID.rawValue).txt", isDirectory: false)
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: txtURL)
            }
        }
    }

    /// 重置或清理 session 存储
    public func cleanSession(sessionID: SessionID) async {
        metadataCache.removeValue(forKey: sessionID)
        let objectsDir = sessionObjectsDirectory(sessionID: sessionID)
        try? FileManager.default.removeItem(at: objectsDir)
    }
}
