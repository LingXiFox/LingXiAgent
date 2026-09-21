import Foundation
import Testing
@testable import LingXiPlatform
@testable import LingXiCore
@testable import LingXiClient
@testable import LingXiProtocol
#if canImport(SwiftUI)
@testable import LingXiFrontendKit
#endif

@Suite("Round 9 System Audit & Hard Gate Integration Tests")
struct Round9SystemAuditTests {

    // MARK: - Phase A: Platform Crypto & Streaming SHA256 Hasher

    @Test("Phase A: PlatformCrypto streaming SHA256 matches one-shot hash identically")
    func testStreamingSHA256HasherConsistency() throws {
        // Generate pseudo-random chunked data
        var fullData = Data()
        var chunks: [Data] = []
        for i in 0..<16 {
            let chunk = "ChunkPayloadIndex-\(i)-\(UUID().uuidString)-lingxiagent-audit-round9\n".data(using: .utf8)!
            chunks.append(chunk)
            fullData.append(chunk)
        }

        let expectedHex = LingXiPlatform.crypto.sha256Hex(fullData)

        // Stream via PlatformCrypto.makeSHA256Hasher()
        var hasher = LingXiPlatform.crypto.makeSHA256Hasher()
        for chunk in chunks {
            hasher.update(data: chunk)
        }
        let actualHex = hasher.finalizeHex()

        #expect(actualHex == expectedHex)
        #expect(!actualHex.isEmpty)
        #expect(actualHex.count == 64)
    }

    // MARK: - Phase B: ContentStore Large File (>8MB) Read & Metadata Persistence

    @Test("Phase B: ContentStore >8MB large upload commit maintains valid metadata and non-empty read")
    func testContentStoreLargeFileOver8MBCacheAndMetadataPersistence() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r9-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ContentStore(storageDirectory: tempDir)

        // Generate 9MB of deterministic payload (> 8MB cacheable single item threshold)
        let totalSize = 9 * 1024 * 1024 // 9MB
        let chunkSize = 1 * 1024 * 1024 // 1MB
        var testData = Data(capacity: totalSize)
        for i in 0..<totalSize {
            testData.append(UInt8(i % 251))
        }
        let expectedDigest = "sha256:" + LingXiPlatform.crypto.sha256Hex(testData)

        let beginResp = try await store.beginUpload(request: BeginContentUploadRequest(
            filename: "large_payload_9mb.bin",
            proposedMediaType: "application/octet-stream",
            expectedByteCount: totalSize,
            scope: .global
        ))

        // Upload in 1MB chunks
        for chunkIdx in 0..<9 {
            let start = chunkIdx * chunkSize
            let end = start + chunkSize
            let sub = testData.subdata(in: start..<end)
            try await store.writeChunk(uploadID: beginResp.uploadID, chunkIndex: UInt64(chunkIdx), data: sub)
        }

        let ref = try await store.commitUpload(request: CommitContentUploadRequest(
            uploadID: beginResp.uploadID,
            expectedDigest: expectedDigest
        ))

        #expect(ref.byteCount == totalSize)
        #expect(ref.digest == expectedDigest)

        // Critical Audit Gate 1: Immediate metadata() must report 9MB, NOT 0 bytes!
        let meta = try await store.metadata(id: ref.id, authorization: .system)
        #expect(meta.ref.byteCount == totalSize)
        #expect((meta.ref.byteCount ?? 0) > 8 * 1024 * 1024)

        // Critical Audit Gate 2: Immediate read() must return the full 9MB data, NOT empty Data()!
        let readData = try await store.read(id: ref.id, authorization: .system)
        #expect(readData.count == totalSize)
        #expect(readData == testData)

        // Critical Audit Gate 3: readRange() correctly seeks on disk and returns slice
        let rangeOffset = 2 * 1024 * 1024
        let rangeLength = 512 * 1024
        let slice = try await store.readRange(id: ref.id, offset: rangeOffset, length: rangeLength, authorization: .system)
        #expect(slice.count == rangeLength)
        let expectedSlice = testData.subdata(in: rangeOffset..<(rangeOffset + rangeLength))
        #expect(slice == expectedSlice)

        // Critical Audit Gate 4: Restart store on same directory (Cold read & metadata)
        let coldStore = ContentStore(storageDirectory: tempDir)
        let coldMeta = try await coldStore.metadata(id: ref.id, authorization: .system)
        #expect(coldMeta.ref.byteCount == totalSize)

        let coldRead = try await coldStore.read(id: ref.id, authorization: .system)
        #expect(coldRead.count == totalSize)
        #expect(coldRead == testData)
    }

    @Test("Phase B: ContentStore duplicate chunk handling and payload conflict detection")
    func testContentStoreDuplicateChunkConflict() async throws {
        let store = ContentStore()
        let beginResp = try await store.beginUpload(request: BeginContentUploadRequest(
            filename: "conflict_test.txt",
            proposedMediaType: "text/plain",
            expectedByteCount: 200,
            scope: .global
        ))

        let chunk0 = Data("First chunk data for index 0".utf8)
        try await store.writeChunk(uploadID: beginResp.uploadID, chunkIndex: 0, data: chunk0)

        // Case 1: Identical chunk re-transmitted -> idempotent success
        try await store.writeChunk(uploadID: beginResp.uploadID, chunkIndex: 0, data: chunk0)

        // Case 2: Conflicting chunk re-transmitted -> throws chunkConflict
        let conflictingChunk0 = Data("Different conflicting data for index 0".utf8)
        do {
            try await store.writeChunk(uploadID: beginResp.uploadID, chunkIndex: 0, data: conflictingChunk0)
            Issue.record("Expected chunkConflict error on conflicting chunk payload")
        } catch let err as RuntimeError {
            #expect(err.code == "chunkConflict")
        }
    }

    @Test("Phase B: ContentStore metadata corrupted fail-closed rejection")
    func testContentStoreMetadataFailClosed() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r9-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ContentStore(storageDirectory: tempDir)
        let ref = try await store.store(data: Data("Sensitive private data".utf8), scope: .global)

        // Corrupt the metadata file by overwriting with invalid JSON
        let metaURL = tempDir.appendingPathComponent("\(ref.id.rawValue).meta.json")
        try Data("corrupted invalid json content".utf8).write(to: metaURL, options: .atomic)

        // Create fresh store to bypass memory cache
        let freshStore = ContentStore(storageDirectory: tempDir)
        do {
            _ = try await freshStore.metadata(id: ref.id, authorization: .system)
            Issue.record("Expected corruptedContentMetadata rejection")
        } catch let err as RuntimeError {
            #expect(err.code == "corruptedContentMetadata")
        }
    }

    // MARK: - Phase C: VNext IPC Concurrency & Wire Framing

    @Test("Phase C: VNext transport enforces frame limitation")
    func testVNextFrameSizeLimitation() async throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let transport = VNextStdioTransport(inputHandle: inputPipe.fileHandleForWriting, outputPipe: outputPipe)

        // 仅分配刚超过 32MB 上限的轻量 payload，杜绝双 Base64 产生数百 MB 临时内存 (Audit Round 10 Phase E)
        let oversizedData = Data(count: ProtocolConstants.maxFrameBytes + 128)
        do {
            try await transport.uploadContentChunk(uploadID: "oversized-test", chunkIndex: 0, data: oversizedData)
            Issue.record("Expected frame limitation error to be thrown")
        } catch let err as CoreError {
            #expect(err.code == .transport)
        }
        await transport.disconnect()
    }

    // MARK: - Phase D: Workspace Transaction Atomicity & Gate Cancellation

    @Test("Phase D: Workspace transition failure preserves original CoreHost state atomically")
    func testWorkspaceTransitionAtomicityOnFailure() async throws {
        let validTemp = FileManager.default.temporaryDirectory.appendingPathComponent("audit-r9-valid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: validTemp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: validTemp) }

        try await withTestCoreHost(workspaceRoot: validTemp) { host in
            let initialRevision = await host.currentWorkspaceRevision
            let initialURL = await host.workspaceURL
            #expect(initialRevision == 1)
            #expect(initialURL.standardizedFileURL.path == validTemp.standardizedFileURL.path)

            // Attempt transition to a nonexistent / restricted directory that fails WorkspaceRoot validation
            let invalidURL = URL(fileURLWithPath: "/dev/null/forbidden_path_\(UUID().uuidString)")
            do {
                try await host.applyWorkspaceTransition(to: invalidURL)
                Issue.record("Expected workspace transition to throw on invalid directory")
            } catch {
                // Expected failure
            }

            // Verification: CoreHost state is 100% untouched; revision and workspaceURL remain valid
            let afterRevision = await host.currentWorkspaceRevision
            let afterURL = await host.workspaceURL
            #expect(afterRevision == initialRevision)
            #expect(afterURL == initialURL)
        }
    }

    @Test("Phase D: MutationGate is cancellation-aware and unblocks cleanly without leaks")
    func testMutationGateCancellationAwareness() async throws {
        let coordinator = ToolMutationCoordinator()

        let (gateAcquiredStream, gateAcquiredContinuation) = AsyncStream<Void>.makeStream()
        let (releaseTask1Stream, releaseTask1Continuation) = AsyncStream<Void>.makeStream()

        // Task 1 holds the gate until explicitly released after task2 cancellation verification
        let task1 = Task {
            try await coordinator.execute {
                gateAcquiredContinuation.yield()
                for await _ in releaseTask1Stream { break }
                return "result-1"
            }
        }

        // Wait until task1 has acquired the gate
        for await _ in gateAcquiredStream { break }

        // Task 2 attempts to acquire gate while task1 is holding it, then gets cancelled
        let task2 = Task {
            try await coordinator.execute {
                return "result-2-should-not-run"
            }
        }

        // Give Task 2 a moment to queue into waiters
        try? await Task.sleep(nanoseconds: 20_000_000)
        task2.cancel()

        do {
            _ = try await task2.value
            Issue.record("Expected task2 to throw CancellationError")
        } catch is CancellationError {
            // Success: cleanly cancelled without waiting for task1 to finish!
        } catch {
            Issue.record("Unexpected error from task2: \(error)")
        }

        // Signal Task 1 to release the gate and finish normally
        releaseTask1Continuation.yield()
        let res1 = try await task1.value
        #expect(res1 == "result-1")

        // Task 3 can subsequently acquire the gate without being blocked by dead waiters
        let res3 = try await coordinator.execute {
            return "result-3"
        }
        #expect(res3 == "result-3")
    }

    // MARK: - Phase E: macOS GUI Phase 0 Semantics & Synchronization

    #if canImport(SwiftUI)
    @Test("Phase E: RuntimeInspector telemetry correctly separates P-Core working set from Codebase Graph")
    @MainActor
    func testGUIPhase0InspectorSemantics() throws {
        let telemetry = RuntimeInspectorPresentation(
            residentTokens: 64000,
            workingSetCapacity: 128000,
            contextWindowUsage: 0.50,
            codebaseNodes: 1800,
            codebaseEdges: 4200
        )

        // P-Core Working Set verification
        #expect(telemetry.residentTokens == 64000)
        #expect(telemetry.workingSetCapacity == 128000)
        #expect(telemetry.contextWindowUsage == 0.50)

        // Codebase Graph verification (Independent semantic structure)
        #expect(telemetry.codebaseNodes == 1800)
        #expect(telemetry.codebaseEdges == 4200)
    }

    @Test("Phase E: ConversationPresentationModel coalesces high-speed streaming chunks smoothly")
    @MainActor
    func testStreamingChunkCoalescing() throws {
        let conversation = ConversationPresentationModel(sessionID: "sess-coalesce")
        #expect(conversation.items.isEmpty)

        // Rapidly append 10 chunks within coalesce interval
        for i in 0..<10 {
            conversation.appendOrUpdateStreamingChunk(chunk: "chunk_\(i) ")
        }

        // Finalize flushes buffer cleanly
        conversation.finalizeStreaming()
        #expect(conversation.items.count == 1)
        if case .assistant(let text, let isStreaming) = conversation.items.first?.kind {
            #expect(!isStreaming)
            #expect(text.contains("chunk_0"))
            #expect(text.contains("chunk_9"))
        } else {
            Issue.record("Expected assistant timeline item")
        }
    }
    #endif
}
