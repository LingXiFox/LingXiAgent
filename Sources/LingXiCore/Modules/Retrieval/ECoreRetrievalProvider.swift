import Foundation
import LingXiProtocol

/// E-Core 工具大输出只读检索适配器 (ECoreRetrievalProvider)
/// 负责将落盘的超大 ToolResult 对象以受控尺寸和行边界安全切分为多个可索引的 RetrievalChunk
///
/// 架构原则：
/// 1. 不得只索引首尾 512 字节或占位符，保证对象中部的编译错误、符号名、日志内容完整可检索；
/// 2. 每个 Chunk 的 RawSourceHandle 均记录精确的 offsetBytes 与 lengthBytes，可通过现有 context_recall 物理无损重现；
/// 3. Fail-Open 铁律：任何文件丢失、损坏或编码异常均安全跳过，绝不阻断流程。
public struct ECoreRetrievalProvider: RetrievalProvider, Sendable {
    public let sourceType: RetrievalSourceType = .ecoreToolResult
    public let ecoreStore: ECoreObjectStore
    public let softChunkBytes: Int
    public let hardChunkBytes: Int
    public let overlapBytes: Int

    public init(
        ecoreStore: ECoreObjectStore,
        softChunkBytes: Int = 2048,
        hardChunkBytes: Int = 3072,
        overlapBytes: Int = 256
    ) {
        self.ecoreStore = ecoreStore
        let safeSoft = max(512, softChunkBytes)
        self.softChunkBytes = safeSoft
        self.hardChunkBytes = max(safeSoft, hardChunkBytes)
        self.overlapBytes = max(0, min(overlapBytes, safeSoft / 2))
    }

    /// 兼容 Phase R0 初始化签名
    public init(
        ecoreStore: ECoreObjectStore,
        targetChunkBytes: Int,
        overlapBytes: Int = 256
    ) {
        self.init(
            ecoreStore: ecoreStore,
            softChunkBytes: targetChunkBytes,
            hardChunkBytes: Int(Double(targetChunkBytes) * 1.5),
            overlapBytes: overlapBytes
        )
    }

    /// 遍历 E-Core 存储的对象并切分为 RetrievalChunk
    /// - Parameters:
    ///   - projectRoot: 工作区根目录
    ///   - sessionID: 指定 SessionID，若为 nil 则扫描 E-Core 根目录下的所有可用会话
    public func enumerateChunks(
        projectRoot: URL,
        sessionID: SessionID? = nil
    ) async throws -> [RetrievalChunk] {
        let baseDir = ecoreStore.baseDirectory
        var sessionDirsToScan: [URL] = []

        if let sessionID {
            let safeSessionID = sessionID.rawValue.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            let sDir = baseDir.appendingPathComponent(safeSessionID, isDirectory: true)
            if FileManager.default.fileExists(atPath: sDir.path) {
                sessionDirsToScan.append(sDir)
            }
        } else {
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: baseDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                sessionDirsToScan = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            }
        }

        var chunks: [RetrievalChunk] = []
        let standardMetaDecoder = JSONDecoder()
        let isoMetaDecoder = JSONDecoder()
        isoMetaDecoder.dateDecodingStrategy = .iso8601

        for sDir in sessionDirsToScan {
            let objectsDir = sDir.appendingPathComponent("objects", isDirectory: true)
            guard FileManager.default.fileExists(atPath: objectsDir.path),
                  let files = try? FileManager.default.contentsOfDirectory(
                    at: objectsDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            for metaFile in files where metaFile.lastPathComponent.hasSuffix(".meta.json") {
                do {
                    let metaData = try Data(contentsOf: metaFile)
                    let meta: ObservationMetadata
                    if let decoded = try? standardMetaDecoder.decode(ObservationMetadata.self, from: metaData) {
                        meta = decoded
                    } else if let isoDecoded = try? isoMetaDecoder.decode(ObservationMetadata.self, from: metaData) {
                        meta = isoDecoded
                    } else {
                        continue
                    }

                    let textFile = objectsDir.appendingPathComponent("\(meta.objectID.rawValue).txt", isDirectory: false)
                    guard FileManager.default.fileExists(atPath: textFile.path) else { continue }
                    let rawData = try Data(contentsOf: textFile)

                    let objectChunks = makeChunks(
                        sessionID: sDir.lastPathComponent,
                        metadata: meta,
                        data: rawData
                    )
                    chunks.append(contentsOf: objectChunks)
                } catch {
                    // Fail-Open: 静默捕获损坏或格式不兼容的对象
                    continue
                }
            }
        }

        return chunks
    }

    /// 将单个 E-Core 对象的原始数据流安全切分为多个具有重叠边界的 RetrievalChunk
    public func makeChunks(
        sessionID: String,
        metadata: ObservationMetadata,
        data: Data
    ) -> [RetrievalChunk] {
        let totalBytes = data.count
        guard totalBytes > 0 else { return [] }

        // 小于或等于软限制的对象直接作为一个完整 Chunk
        if totalBytes <= softChunkBytes {
            let text = String(decoding: data, as: UTF8.self)
            let handle = RawSourceHandle.ecore(
                objectID: metadata.objectID,
                offsetBytes: 0,
                lengthBytes: totalBytes
            )
            return [
                RetrievalChunk(
                    chunkID: "ecore:\(metadata.objectID.rawValue)#offset_0_\(totalBytes)",
                    sourceType: .ecoreToolResult,
                    sourceID: metadata.objectID.rawValue,
                    rawSourceHandle: handle,
                    indexableText: text,
                    symbolHints: extractHints(from: text),
                    path: nil,
                    timestamp: metadata.createdAt,
                    metadata: [
                        "session_id": sessionID,
                        "tool_name": metadata.toolName,
                        "tool_call_id": metadata.toolCallID.rawValue,
                        "total_bytes": String(metadata.totalBytes),
                        "content_type": metadata.contentType
                    ]
                )
            ]
        }

        var result: [RetrievalChunk] = []
        var currentOffset = 0

        while currentOffset < totalBytes {
            let remaining = totalBytes - currentOffset
            var sliceEnd: Int

            if remaining <= softChunkBytes {
                sliceEnd = totalBytes
            } else {
                let softEnd = min(totalBytes, currentOffset + softChunkBytes)
                let hardEnd = min(totalBytes, currentOffset + hardChunkBytes)

                // 1. 优先在 [softEnd - 200, hardEnd] 范围内寻找行边界 '\n' (byte 10)
                let searchStart = max(currentOffset + 1, softEnd - 200)
                var bestNewline = -1

                for idx in stride(from: hardEnd - 1, through: searchStart, by: -1) {
                    if data[idx] == 10 { // '\n'
                        bestNewline = idx + 1 // 包含换行符
                        break
                    }
                }

                if bestNewline > currentOffset && bestNewline <= hardEnd {
                    sliceEnd = bestNewline
                } else {
                    // 2. 超长单行保护：直到 hardEnd 仍无换行，强制在 hardEnd 截断
                    // 必须对齐到合法的 UTF-8 字符边界，避免切碎多字节字符（中文/Emoji 等）
                    sliceEnd = alignToUTF8Boundary(data: data, targetOffset: hardEnd, totalBytes: totalBytes, currentOffset: currentOffset)
                }
            }

            if sliceEnd <= currentOffset {
                // 极端安全兜底：向前推进至少 1 字节，防止死循环
                sliceEnd = min(totalBytes, currentOffset + 1)
            }

            let sliceData = data.subdata(in: currentOffset..<sliceEnd)
            let sliceText = String(decoding: sliceData, as: UTF8.self)
            let sliceLength = sliceData.count

            let handle = RawSourceHandle.ecore(
                objectID: metadata.objectID,
                offsetBytes: currentOffset,
                lengthBytes: sliceLength
            )

            let chunk = RetrievalChunk(
                chunkID: "ecore:\(metadata.objectID.rawValue)#offset_\(currentOffset)_\(sliceLength)",
                sourceType: .ecoreToolResult,
                sourceID: metadata.objectID.rawValue,
                rawSourceHandle: handle,
                indexableText: sliceText,
                symbolHints: extractHints(from: sliceText),
                path: nil,
                timestamp: metadata.createdAt,
                metadata: [
                    "session_id": sessionID,
                    "tool_name": metadata.toolName,
                    "tool_call_id": metadata.toolCallID.rawValue,
                    "offset_bytes": String(currentOffset),
                    "length_bytes": String(sliceLength),
                    "total_bytes": String(metadata.totalBytes)
                ]
            )
            result.append(chunk)

            if sliceEnd >= totalBytes {
                break
            }

            // 计算下一个起始偏移，应用 overlap，同时确保 UTF-8 边界对齐
            var nextOffset = sliceEnd - overlapBytes
            if nextOffset <= currentOffset {
                nextOffset = sliceEnd
            } else {
                nextOffset = alignToUTF8Boundary(data: data, targetOffset: nextOffset, totalBytes: totalBytes, currentOffset: currentOffset)
                if nextOffset <= currentOffset {
                    nextOffset = sliceEnd
                }
            }
            currentOffset = nextOffset
        }

        return result
    }

    /// 在 UTF-8 字节流中将偏移量对齐到合法的字符起始边界（字节最高两位不是 10，即 (byte & 0xC0) != 0x80）
    private func alignToUTF8Boundary(data: Data, targetOffset: Int, totalBytes: Int, currentOffset: Int) -> Int {
        guard targetOffset < totalBytes else { return totalBytes }
        var offset = targetOffset

        // UTF-8 continuation byte 的特征是 0b10xxxxxx（0x80 ... 0xBF）
        // 若切点落在延续字节上，向前回退寻找 leading byte（最多回退 3 字节）
        var steps = 0
        while offset > currentOffset && steps < 4 && (data[offset] & 0xC0) == 0x80 {
            offset -= 1
            steps += 1
        }

        if offset <= currentOffset {
            // 如果回退到了起点或超越当前起点，则改向后寻找下一个字符起始
            offset = targetOffset
            while offset < totalBytes && (data[offset] & 0xC0) == 0x80 {
                offset += 1
            }
        }

        return min(totalBytes, offset)
    }

    /// 从文本切片中快速提取高置信度的报错关键词或符号线索
    private func extractHints(from text: String) -> [String] {
        var hints: Set<String> = []
        let lines = text.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("error:") || trimmed.contains("warning:") || trimmed.contains("fatal:") {
                let parts = trimmed.split(separator: " ").prefix(8).map(String.init)
                hints.insert(parts.joined(separator: " "))
            }
            if trimmed.hasPrefix("func ") || trimmed.hasPrefix("class ") || trimmed.hasPrefix("struct ") || trimmed.hasPrefix("actor ") || trimmed.hasPrefix("enum ") {
                let tokens = trimmed.split(separator: " ")
                if tokens.count >= 2 {
                    let name = tokens[1].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    if !name.isEmpty {
                        hints.insert(String(name))
                    }
                }
            }
        }

        return Array(hints).sorted()
    }
}
