import Testing
import Foundation
import LingXiProtocol
@testable import LingXiTUI
@testable import LingXiTUIComponents

@Suite("TUI Frame Diff & Row-Level Invalidation Tests (Phase 3)")
struct TUIFrameDiffTests {

    @Test("Row-level comparison correctly detects only modified rows while keeping unchanged rows skipped")
    func rowLevelDiffDetectsOnlyChangedRows() throws {
        let size = TUISize(width: 80, height: 24)
        var frame1 = TUIFrame(size: size)

        // 填充初始内容
        for row in 0..<size.height {
            for col in 0..<size.width {
                frame1.put(Character(UnicodeScalar(65 + (row % 26))!), at: TUIPoint(x: col, y: row), style: .normal)
            }
        }

        // 仅修改第 20 行（模拟 composer 单行敲入字符）
        var frame2 = frame1
        frame2.put("X", at: TUIPoint(x: 10, y: 20), style: .accent)

        // 比较逐行
        var changedRows: [Int] = []
        for row in 0..<size.height {
            var rowChanged = false
            for col in 0..<size.width {
                let idx = row * size.width + col
                if frame1.cells[idx] != frame2.cells[idx] {
                    rowChanged = true
                    break
                }
            }
            if rowChanged {
                changedRows.append(row)
            }
        }

        // 验证：24 行中仅有第 20 行变动，其余 23 行完全未改变
        #expect(changedRows == [20], "Only row 20 must be detected as changed")
        #expect(changedRows.count == 1, "Exactly 1 row changed during single character composer mutation")
    }

    @Test("Terminal backend skips redundant present when frame is completely identical")
    func terminalBackendSkipsRedundantPresentOnIdenticalFrame() throws {
        let metrics = TUIPerformanceMetrics.shared
        metrics.reset()
        metrics.isEnabled = true
        defer { metrics.isEnabled = false }

        let backend = POSIXTerminalBackend(noAltScreen: true)
        let size = TUISize(width: 80, height: 24)
        var frame = TUIFrame(size: size)
        frame.put("A", at: TUIPoint(x: 0, y: 0), style: .normal)

        // 第一次渲染（首帧全量）
        backend.render(frame)
        let initialFrames = metrics.totalFrames
        let initialSkipped = metrics.skippedFrameCount

        #expect(initialFrames == 1)
        #expect(initialSkipped == 0)

        // 第二次渲染完全相同的帧
        backend.render(frame)

        // 验证：第二帧被判定为完全相同，触发 skip，不再全量扫描重绘
        #expect(metrics.totalFrames == initialFrames, "Identical frame must not increase presented frame counter")
        #expect(metrics.skippedFrameCount == initialSkipped + 1, "Identical frame must be skipped")
    }

    @Test("Selection rect modification precisely invalidates only intersecting rows")
    func selectionRectInvalidatesOnlyIntersectingRows() throws {
        let size = TUISize(width: 80, height: 24)
        var baseFrame = TUIFrame(size: size)
        for r in 0..<size.height {
            baseFrame.put("A", at: TUIPoint(x: 0, y: r), style: .normal)
        }

        // 在第 5 行到第 7 行划选
        var selectedFrame = baseFrame
        selectedFrame.highlightSelection(TUIRect(x: 5, y: 5, width: 30, height: 3))

        var changedRows: [Int] = []
        for row in 0..<size.height {
            var rowChanged = false
            for col in 0..<size.width {
                let idx = row * size.width + col
                if baseFrame.cells[idx] != selectedFrame.cells[idx] {
                    rowChanged = true
                    break
                }
            }
            if rowChanged {
                changedRows.append(row)
            }
        }

        #expect(changedRows == [5, 6, 7], "Selection across rows 5..7 must invalidate only those 3 rows")
    }
}
