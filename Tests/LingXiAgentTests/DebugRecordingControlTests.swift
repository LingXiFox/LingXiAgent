import Foundation
import Testing
@testable import LingXiCore
import LingXiClient
import LingXiProtocol

/// Persistent debug recording, as the Observatory now drives it.
///
/// A several-hundred-turn run overflows the 4096-event ring, so the JSONL archive is the only
/// complete record. These tests pin the two properties an operator relies on when pressing stop:
/// that "stopped" means "everything is on disk", and that a refused command leaves Core's real
/// state on screen.
@Suite("Debug recording control", .serialized)
struct DebugRecordingControlTests {

    /// `setRecorder(nil, ...)` used to close the recorder on an unawaited task, dropping whatever
    /// the drain had not yet handed over. Repeated because the loss was a race, not a constant.
    @Test("stopping returns only after every accepted event is in the JSONL")
    func detachFlushesEverything() async throws {
        for round in 0..<20 {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("lx-rec-flush-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }

            let hub = DebugTelemetryHub(capacity: 512)
            let recorder = DebugRunRecorder(directory: dir)
            #expect(await recorder.start(runName: "flush", manifest: nil))
            hub.setRecorder(recorder, runName: "flush")

            // Not a multiple of the 64-line batch, so a partial batch is always left buffered.
            let count = 301
            for _ in 0..<count {
                hub.record(.cacheMiss, sessionID: SessionID("s-flush"))
            }
            await hub.detachRecorder()

            let text = try String(contentsOf: dir.appendingPathComponent("telemetry.jsonl"), encoding: .utf8)
            let lines = text.split(separator: "\n")
            #expect(lines.count == count, "第 \(round) 轮停止后 JSONL 只有 \(lines.count)/\(count) 行")
            let decoder = DebugTelemetryHub.archiveDecoder()
            let sequences = try lines.map { try decoder.decode(DebugTelemetryEvent.self, from: Data($0.utf8)).sequence }
            #expect(sequences == Array(1...UInt64(count)), "第 \(round) 轮序号缺失或乱序")
            #expect(hub.status().archiveWriteFailures == 0, "正常停止不应计入归档失败")
            #expect(hub.status().recording == false)
        }
    }

    @Test("Core refuses a run name that could leave the archive root, and state stays real")
    func invalidRunNameIsRefused() async throws {
        let fixture = try await DebugObservatorySurfaceTests.makeFixture(provider: ObservatoryFakeProvider())
        defer {
            Task { await fixture.host.shutdown() }
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: fixture.workspace)
        }
        _ = try await fixture.client.debug.setEnabled(true)

        for bad in ["../escape", "a/b", ".hidden", "空格 name"] {
            await #expect(throws: (any Error).self, "非法运行名 \(bad) 被接受了") {
                _ = try await fixture.client.debug.startRecording(runName: bad)
            }
            let status = try await fixture.client.debug.status()
            #expect(status.recording == false && status.runName == nil,
                    "被拒绝后 Core 状态不该变：\(status)")
        }

        let started = try await fixture.client.debug.startRecording(runName: "pe-qwen9b-001")
        #expect(started.recording && started.runName == "pe-qwen9b-001")
        let stopped = try await fixture.client.debug.stopRecording()
        #expect(stopped.recording == false && stopped.runName == nil)
        #expect(stopped.archiveWriteFailures == 0)

        let archived = FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "telemetry.jsonl" && $0.path.contains("pe-qwen9b-001") } ?? []
        #expect(archived.count == 1, "录制目录没落在 debug archive 下：\(archived)")
    }

    /// The card must send the existing commands and display Core's status. A local `recording`
    /// flag would be a second authority that can disagree with Core after a rejection.
    @Test("the recording card drives the existing commands and keeps no local recording state")
    func recordingCardUsesCoreCommands() throws {
        let panes = try DebugObservatorySurfaceTests.source("Apps/macOS/FrontendKit/Components/RuntimeObservatoryPanes.swift")
        let frontend = try DebugObservatorySurfaceTests.source("Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift")

        #expect(panes.contains("runtime.startDebugRecording(") && panes.contains("runtime.stopDebugRecording()"),
                "录制卡片没有接到现有的 start/stop 命令")
        #expect(panes.contains("status?.recording == true"), "录制状态应直接读 Core 的 status")
        for forbidden in ["@State private var isRecording", "@State private var recording",
                          "DebugRunRecorder("] {
            #expect(!panes.contains(forbidden), "Observatory 出现了本地录制权威或第二套 recorder：\(forbidden)")
        }
        // A rejection must re-read Core instead of leaving whatever the button implied.
        guard let start = frontend.range(of: "private func runDebugRecorderAction"),
              let end = frontend.range(of: "public func compactCurrentContext", range: start.upperBound..<frontend.endIndex) else {
            Issue.record("找不到 runDebugRecorderAction")
            return
        }
        let body = frontend[start.lowerBound..<end.lowerBound]
        #expect(body.contains("await probeObservatory()"), "命令被拒绝后没有回读 Core 状态")
    }
}
