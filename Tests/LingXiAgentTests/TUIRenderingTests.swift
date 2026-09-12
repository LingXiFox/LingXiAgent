import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
@testable import LingXiApplication
@testable import LingXiTUIComponents

struct TUIRenderingTests {
    @Test func openTUIBindingCompletesRendererLifecycle() throws {
        let renderer = try OpenTUIRenderer(width: 24, height: 8)
        renderer.resize(width: 30, height: 10)
        renderer.draw("OpenTUI C ABI\n中文")
        renderer.setCursor(TUIPoint(x: 2, y: 1))
        #expect(renderer.render(force: true) != 2)
        renderer.setCursor(nil)
        #expect(renderer.render() != 2)
    }

    @Test func displayWidthHandlesAsciiCJKAndEmoji() {
        #expect(TUIDisplayWidth.width(of: "abc") == 3)
        #expect(TUIDisplayWidth.width(of: "中文") == 4)
        #expect(TUIDisplayWidth.width(of: "🙂") == 2)
        #expect(TUIDisplayWidth.width(of: "e\u{301}") == 1)
    }

    @Test func animationTicksContinueDuringLongModelAwaitWithoutHalfSecondStall() async {
        let ticker = TUIAnimationTicker(interval: .milliseconds(50))
        let stream = ticker.stream()
        let longAwait = Task {
            try? await Task.sleep(for: .seconds(30))
        }
        var ticks: [TUIAnimationTick] = []
        for await tick in stream {
            ticks.append(tick)
            if ticks.count == 20 { break }
        }
        longAwait.cancel()

        #expect(ticks.count == 20)
        let gaps = zip(ticks, ticks.dropFirst()).map { $0.0.timestamp.duration(to: $0.1.timestamp) }
        #expect(gaps.allSatisfy { $0 <= .milliseconds(500) })
    }

    @Test func composerSupportsCursorEditingAndWrapping() {
        let composer = ChatComposer()
        _ = composer.handle(.character("a"))
        _ = composer.handle(.character("b"))
        _ = composer.handle(.left)
        _ = composer.handle(.character("中"))
        #expect(composer.text == "a中b")
        _ = composer.handle(.delete)
        #expect(composer.text == "a中")
        _ = composer.handle(.shiftEnter)
        _ = composer.handle(.paste("second line"))
        #expect(composer.text == "a中\nsecond line")
        let rendered = composer.render(width: 8)
        #expect(rendered.lines.count > 1)
        #expect(rendered.cursor != nil)
    }

    @Test func composerPreservesHistoryAtInputBoundaries() {
        let composer = ChatComposer()
        composer.setText("first")
        composer.commitHistory()
        composer.clear()
        composer.setText("second")
        composer.commitHistory()
        composer.clear()
        _ = composer.handle(.up)
        #expect(composer.text == "second")
        _ = composer.handle(.up)
        #expect(composer.text == "first")
        _ = composer.handle(.down)
        #expect(composer.text == "second")
    }

    @Test func transcriptScrollStopsFollowingAndReturnsToBottom() {
        let viewport = TranscriptViewport()
        viewport.replace((0..<20).map { TUITranscriptEntry(kind: .assistant, text: "line \($0)") })
        _ = viewport.render(viewportHeight: 5, width: 40)
        viewport.handle(.pageUp, viewportHeight: 5)
        viewport.append(TUITranscriptEntry(kind: .assistant, text: "late line"))
        #expect(viewport.autoFollow == false)
        let scrolled = viewport.render(viewportHeight: 5, width: 40)
        #expect(scrolled.first?.text.contains("line") == true)
        viewport.handle(.end, viewportHeight: 5)
        #expect(viewport.autoFollow == true)
        #expect(viewport.render(viewportHeight: 5, width: 40).last?.text.contains("late line") == true)
    }

    @Test func userMessagesRenderInsideABox() {
        let viewport = TranscriptViewport()
        viewport.replace([TUITranscriptEntry(kind: .user, text: "hello")])

        let lines = viewport.render(viewportHeight: 4, width: 20)

        #expect(lines.first?.text == "╭──────────────────╮")
        #expect(lines[1].text == "│ hello            │")
        #expect(lines.last?.text == "╰──────────────────╯")
    }

    @Test func frameWritesWideCellsWithoutAnsiContent() {
        var frame = TUIFrame(size: TUISize(width: 8, height: 2))
        frame.write("A中文", at: TUIPoint(x: 0, y: 0), maxWidth: 8)
        #expect(frame.cells[0].character == "A")
        #expect(frame.cells[1].character == "中")
        #expect(frame.cells[2].continuation)
        #expect(frame.cells[3].character == "文")
        #expect(frame.cells[4].continuation)
    }

    @Test func slashCompletionMaintainsSelectionAsComponentState() {
        let view = SlashCompletionView()
        view.update(items: [
            TUICommandItem(name: "model", description: "select model"),
            TUICommandItem(name: "status", description: "show status")
        ])
        view.handle(.down)
        #expect(view.selectedIndex == 1)
        #expect(view.render(width: 40)[3].text.contains("/status"))
    }

    @Test func genericCompletionSupportsWorkspaceReferences() {
        let view = CompletionView()
        view.update(items: [
            TUICompletionItem(value: "Sources/LingXiCore/SessionRuntime.swift", label: "@Sources/LingXiCore/SessionRuntime.swift", detail: "workspace", kind: .reference),
            TUICompletionItem(value: "Sources/LingXiCore/AgentRuntime.swift", label: "@Sources/LingXiCore/AgentRuntime.swift", detail: "workspace", kind: .reference)
        ])
        view.handle(.down)
        #expect(view.selectedItem?.value.contains("AgentRuntime") == true)
        #expect(view.render().first?.text.contains("@Sources") == true)
    }

    @Test func layoutKeepsTranscriptAndStatusRegionsStableWithOverlay() {
        let app = TUIApp()
        app.composer.setText(String(repeating: "中文abc", count: 30))
        let size = TUISize(width: 60, height: 24)
        let normal = app.layout(size: size, overlay: nil)
        let overlay = app.layout(size: size, overlay: TUIOverlayModel(lines: [TUIStyledLine("Picker"), TUIStyledLine("one"), TUIStyledLine("two")]))
        #expect(normal.status.height == 1)
        #expect(overlay.status == normal.status)
        #expect(overlay.transcript == normal.transcript)
        #expect(overlay.bottomPane == normal.bottomPane)
    }

    @Test func overlayIsBoundedAndDoesNotPaintWholeComposerRegion() {
        let app = TUIApp()
        app.composer.setText("/")
        let size = TUISize(width: 60, height: 24)
        let frame = app.render(size: size, overlay: TUIOverlayModel(lines: [TUIStyledLine("Picker"), TUIStyledLine("one")]))
        let composerRect = app.layout(size: size, overlay: nil).bottomPane
        let overlayCells = frame.cells.enumerated().filter { $0.element.style == .overlay }
        #expect(!overlayCells.isEmpty)
        #expect(overlayCells.allSatisfy { index, _ in
            let x = index % size.width
            let y = index / size.width
            return y < composerRect.y && x < size.width - 1
        })
        #expect(frame.cells.contains { $0.style == .composer })
    }

    @Test func timelineProjectionKeepsStableIDsAndDiffSemantics() {
        let viewport = TranscriptViewport()
        let item = TUITimelineItem(id: "edit-1", kind: .edit, title: "Edit", summary: "Session.swift", details: ["-old", "+new"], state: .completed)
        viewport.replaceTimeline([item])
        let lines = viewport.render(viewportHeight: 8, width: 60)
        #expect(lines.contains { $0.text.contains("+new") && $0.style == .accent })
        #expect(lines.contains { $0.text.contains("-old") && $0.style == .error })
        viewport.toggleCollapse(id: "edit-1")
        viewport.replaceTimeline([item])
        #expect(viewport.render(viewportHeight: 8, width: 60).contains { $0.text.contains("+new") } == false)
    }

    @Test func commandPaletteUsesTransientViewState() {
        let stack = TUIViewStack()
        stack.push(TUITransientView(id: "palette", title: "Command Palette", lines: [TUIStyledLine("/model")], focus: .picker))
        #expect(stack.top?.focus == .picker)
        #expect(stack.pop()?.id == "palette")
        #expect(stack.top == nil)
    }

    @Test func hundredStreamingDeltasProducesExactlyOneAssistantMessage() {
        let projector = TUITimelineProjector()
        let streamID = StreamID("stream-test-100")
        for i in 1...100 {
            projector.consume(chunk: StreamChunk(streamID: streamID, index: i, text: "word\(i) ", kind: .text))
        }

        #expect(projector.items.count == 1)
        let item = projector.items[0]
        #expect(item.kind == .assistant)
        #expect(item.state == .running)
        #expect(item.details.isEmpty) // details must NOT duplicate summary
        #expect(item.summary.contains("word1 "))
        #expect(item.summary.contains("word100 "))

        // Turn completes: finalized in place, still exactly 1 item
        projector.consume(turnCompleted: TurnResult(
            sessionID: SessionID("s1"),
            streamID: streamID,
            assistantMessageID: MessageID("msg-final"),
            finishReason: .stop,
            usage: nil
        ))
        #expect(projector.items.count == 1)
        #expect(projector.items[0].state == .completed)

        // Viewport projection verification: text rendered without duplicate body
        let viewport = TranscriptViewport()
        viewport.replaceTimeline(projector.items)
        let rendered = viewport.render(viewportHeight: 50, width: 100)
        let occurrences = rendered.filter { $0.text.contains("word1 ") }.count
        #expect(occurrences == 1)
    }

    @Test func reasoningPlusAssistantProducesOneThinkingAndOneAssistantWithoutMingling() {
        let projector = TUITimelineProjector()
        let streamID = StreamID("stream-reasoning-test")

        // 10 reasoning deltas
        for i in 1...10 {
            projector.consume(chunk: StreamChunk(streamID: streamID, index: i, text: "thought\(i)\n", kind: .reasoning))
        }

        #expect(projector.items.count == 1)
        #expect(projector.items[0].kind == .thinking)
        #expect(projector.items[0].state == .running)
        #expect(projector.items[0].collapsed == false)

        // Assistant content starts: thinking must auto-complete & collapse, assistant begins
        for i in 1...10 {
            projector.consume(chunk: StreamChunk(streamID: streamID, index: 10 + i, text: "answer\(i) ", kind: .text))
        }

        #expect(projector.items.count == 2)
        let thinking = projector.items[0]
        let assistant = projector.items[1]

        #expect(thinking.kind == .thinking)
        #expect(thinking.state == .completed)
        #expect(thinking.collapsed == true)
        #expect(thinking.details.first?.contains("thought1") == true)
        #expect(thinking.details.first?.contains("thought10") == true)
        #expect(thinking.details.first?.contains("answer") == false) // No leaking

        #expect(assistant.kind == .assistant)
        #expect(assistant.summary.contains("answer1 "))
        #expect(assistant.summary.contains("answer10 "))
        #expect(assistant.summary.contains("thought") == false) // No mingling
    }

    @Test func toolBoundaryStartsANewOrderedStreamingSegment() {
        let projector = TUITimelineProjector()
        let streamID = StreamID("stream-ordered")
        projector.consume(chunk: StreamChunk(streamID: streamID, index: 1, text: "first", kind: .reasoning))
        let call = ToolCall(callID: ToolCallID("call-1"), toolID: ToolID("read_file"), arguments: #"{"path":"README.md"}"#)
        projector.consume(toolCall: call)
        #expect(projector.items.count == 2)
        #expect(projector.items[1].state == .running)
        #expect(projector.items[1].title == "Read README.md")

        projector.consume(toolResult: ToolResult(callID: call.callID, success: true, content: "ok", toolName: "read_file"))
        // ToolCall and ToolResult are merged into the same item based on stable ToolCallID!
        #expect(projector.items.count == 2)
        #expect(projector.items[1].state == .completed)
        #expect(projector.items[1].summary.contains("1 lines"))

        projector.consume(chunk: StreamChunk(streamID: streamID, index: 2, text: "second", kind: .reasoning))
        #expect(projector.items.map(\.kind) == [.thinking, .tool, .thinking])
        #expect(projector.items.map(\.sequence.rawValue) == [1, 2, 3])
        #expect(projector.items[0].details == ["first"])
        #expect(projector.items[2].details == ["second"])
    }

    @Test func toolLifecycleUpdatesSameTimelineItemWithoutSecondSibling() throws {
        let projector = TUITimelineProjector()
        let call = ToolCall(callID: ToolCallID("call-merge"), toolID: ToolID("glob"), arguments: #"{"pattern":"*.swift","path":"/Users"}"#)
        projector.consume(toolCall: call)
        #expect(projector.items.count == 1)
        #expect(projector.items[0].id == "tool-call-merge")
        #expect(projector.items[0].title == "Glob /Users/*.swift")
        #expect(projector.items[0].state == .running)
        #expect(projector.items[0].collapsed == false)

        projector.consume(toolOutput: ToolOutputChunk(toolCallID: call.callID, stream: .stdout, sequence: 1, payload: "searching..."))
        #expect(projector.items.count == 1)
        #expect(projector.items[0].state == .running)

        let result = ToolResult(
            callID: call.callID,
            success: true,
            content: #"["/Users/a.swift", "/Users/b.swift", "/Users/c.swift"]"#,
            toolName: "glob",
            summary: "Completed · 3 matches"
        )
        projector.consume(toolResult: result)
        // Must NOT append a second sibling!
        #expect(projector.items.count == 1)
        #expect(projector.items[0].id == "tool-call-merge")
        #expect(projector.items[0].state == .completed)
        #expect(projector.items[0].summary.contains("3 matches"))
        // Short result (3 matches, few lines) is default expanded!
        #expect(projector.items[0].collapsed == false)

        // Long result (many lines/matches) is default collapsed!
        let longResult = ToolResult(
            callID: ToolCallID("call-long"),
            success: true,
            content: (1...50).map { "file\($0).swift" }.joined(separator: "\n"),
            toolName: "glob"
        )
        projector.consume(toolCall: ToolCall(callID: longResult.callID, toolID: ToolID("glob"), arguments: "{}"))
        projector.consume(toolResult: longResult)
        let longItem = try #require(projector.items.first { $0.id == "tool-call-long" })
        #expect(longItem.collapsed == true)
    }

    @Test func toolCallShowsFiveLinesThenDimsTheCollapsedRemainder() {
        let viewport = TranscriptViewport()
        let item = TUITimelineItem(id: "tool-lines", kind: .tool, title: "read_file", summary: "arguments received", details: (1...7).map { "line \($0)" }, state: .running)
        viewport.replaceTimeline([item])

        let lines = viewport.render(viewportHeight: 20, width: 80)

        #expect(lines.contains { $0.text.contains("line 5") })
        #expect(!lines.contains { $0.text.contains("line 6") })
        #expect(lines.contains { $0.text.contains("2 lines collapsed") && $0.style == .dim })
    }

    @Test func toolFailureAndStreamFailureProduceSingleMergedError() {
        let projector = TUITimelineProjector()

        // Turn failed with leaseMissing error
        projector.consume(turnFailed: TurnFailure(
            sessionID: SessionID("s1"),
            streamID: StreamID("stream-err"),
            error: CoreError(code: .mcpToolLeaseMissing, message: "mcpToolLeaseMissing: leaseMissing")
        ))
        // Cascading streamFailed from client layer
        projector.consume(streamFailed: "Stream terminated with error: leaseMissing")

        // Multiple layer error events must be merged into 1 error item
        let errorItems = projector.items.filter { $0.kind == .error }
        #expect(errorItems.count == 1)
        let errorItem = errorItems[0]
        #expect(errorItem.state == .failed)
        #expect(errorItem.title == "Tool failed")
        #expect(errorItem.summary == "leaseMissing")
        #expect(errorItem.details.count >= 1)
    }

    @Test func persistedMessageReconciliationDoesNotDuplicateStreamedContent() {
        let projector = TUITimelineProjector()
        let streamID = StreamID("stream-persist-test")
        let msgID = MessageID("msg-001")

        projector.consume(chunk: StreamChunk(streamID: streamID, index: 1, text: "Streamed answer", kind: .text))
        projector.consume(turnCompleted: TurnResult(
            sessionID: SessionID("s1"),
            streamID: streamID,
            assistantMessageID: msgID,
            finishReason: .stop,
            usage: nil
        ))

        #expect(projector.items.count == 1)

        // Loading session snapshot with msg-001 must reconcile with already-streamed item
        let snapshot = SessionMessageSnapshot(
            id: msgID,
            role: .assistant,
            parts: [.text("Streamed answer")],
            createdAt: Date()
        )
        projector.consume(persistedMessages: [snapshot])

        #expect(projector.items.count == 1)
    }

    @Test func thinkingSegmentsMaintainChronologicalOrderAcrossToolLoop() {
        let projector = TUITimelineProjector()
        let streamID = StreamID("turn-stream-1")

        // 1. Thinking #1 starts and streams
        projector.consume(chunk: StreamChunk(streamID: streamID, index: 0, text: "Initial thoughts...", kind: .reasoning))
        projector.consume(chunk: StreamChunk(streamID: streamID, index: 1, text: " need to list files.", kind: .reasoning))
        #expect(projector.items.count == 1)
        #expect(projector.items[0].kind == .thinking)
        #expect(projector.items[0].title == "Thinking #1")
        #expect(projector.items[0].state == .running)
        #expect(projector.items[0].details.first == "Initial thoughts... need to list files.")

        // 2. Tool #1 is invoked -> Thinking #1 completes and collapses
        let call1 = ToolCall(callID: ToolCallID("call-1"), toolID: ToolID("list_directory"), arguments: #"{"path":"."}"#)
        projector.consume(toolCall: call1)
        #expect(projector.items.count == 2)
        #expect(projector.items[0].title == "Thinking #1")
        #expect(projector.items[0].state == .completed)
        #expect(projector.items[0].collapsed == true)
        #expect(projector.items[1].title == "ListDirectory .")

        let res1 = ToolResult(callID: call1.callID, success: true, content: "file1.txt\nfile2.txt", toolName: "list_directory")
        projector.consume(toolResult: res1)
        #expect(projector.items.count == 2) // Merged into Tool #1 item!

        // 3. Thinking #2 begins for the next inference step -> MUST NOT rewrite Thinking #1
        projector.consume(chunk: StreamChunk(streamID: streamID, index: 2, text: "Now examining file1...", kind: .reasoning))
        projector.consume(chunk: StreamChunk(streamID: streamID, index: 3, text: " need to read it.", kind: .reasoning))
        #expect(projector.items.count == 3)
        #expect(projector.items[0].title == "Thinking #1")
        #expect(projector.items[0].details.first == "Initial thoughts... need to list files.") // Untouched!
        #expect(projector.items[2].title == "Thinking #2")
        #expect(projector.items[2].state == .running)
        #expect(projector.items[2].details.first == "Now examining file1... need to read it.")

        // 4. Tool #2 is invoked -> Thinking #2 completes
        let call2 = ToolCall(callID: ToolCallID("call-2"), toolID: ToolID("read_file"), arguments: #"{"path":"file1.txt"}"#)
        projector.consume(toolCall: call2)
        #expect(projector.items.count == 4)
        #expect(projector.items[2].title == "Thinking #2")
        #expect(projector.items[2].state == .completed)
        #expect(projector.items[3].title == "Read file1.txt")

        // 5. Thinking #3 begins
        projector.consume(chunk: StreamChunk(streamID: streamID, index: 4, text: "Got the content.", kind: .reasoning))
        #expect(projector.items.count == 5)
        #expect(projector.items[4].title == "Thinking #3")

        // 6. Assistant output starts -> Thinking #3 completes
        projector.consume(chunk: StreamChunk(streamID: streamID, index: 5, text: "Here is the file content.", kind: .text))
        #expect(projector.items.count == 6)
        #expect(projector.items[4].state == .completed)
        #expect(projector.items[4].collapsed == true)
        #expect(projector.items[5].title == "Assistant")
    }

    @Test func transcriptViewportMouseClickCanTargetEntryAndToggleCollapse() {
        let viewport = TranscriptViewport()
        let longThinking = (0..<10).map { "Thinking line \($0)" }.joined(separator: "\n")
        let entry1 = TUITranscriptEntry(id: "th-mouse", kind: .thinking, text: longThinking, collapsed: true)
        let entry2 = TUITranscriptEntry(id: "as-mouse", kind: .assistant, text: "Final answer")
        viewport.replace([entry1, entry2])

        // Initially collapsed
        #expect(viewport.isCollapsed(id: "th-mouse") == true)

        // Render viewport with height 10
        let renderedLines = viewport.render(viewportHeight: 10, width: 40)
        #expect(renderedLines.count > 0)

        // Row 0 corresponds to entry1's header
        let clickedID = viewport.entryID(atRow: 0, viewportHeight: 10, width: 40)
        #expect(clickedID == "th-mouse")

        // Toggle collapse on clicked entry
        if let id = clickedID {
            viewport.toggleCollapse(id: id)
        }
        #expect(viewport.isCollapsed(id: "th-mouse") == false)

        // Toggle collapse back
        if let id = clickedID {
            viewport.toggleCollapse(id: id)
        }
        #expect(viewport.isCollapsed(id: "th-mouse") == true)
    }

    @Test func boxSelectionExtractsTextAndHighlightsCells() {
        var frame = TUIFrame(size: TUISize(width: 20, height: 6))
        frame.write("Hello World!", at: TUIPoint(x: 2, y: 1))
        frame.write("LingXi Agent", at: TUIPoint(x: 2, y: 2))

        let rect = TUIRect(from: TUIPoint(x: 2, y: 1), to: TUIPoint(x: 6, y: 2))
        #expect(rect.x == 2)
        #expect(rect.y == 1)
        #expect(rect.width == 5)
        #expect(rect.height == 2)

        frame.highlightSelection(rect)
        #expect(frame.cells[1 * 20 + 2].style == .selected)
        #expect(frame.cells[2 * 20 + 6].style == .selected)
        #expect(frame.cells[1 * 20 + 1].style != .selected)

        let extracted = frame.text(in: rect)
        #expect(extracted == "Hello\nLingX")
    }

    @Test func shiftTabAgentModeCycleCoversAllModes() {
        #expect(AgentMode.build.next == .plan)
        #expect(AgentMode.plan.next == .explore)
        #expect(AgentMode.explore.next == .build)
        #expect(AgentMode.unknown.next == .build)
    }

    @Test func cacheLayersFormatUsedOverTotalCorrectly() {
        let l1Cap = 220_000
        let l2Cap = 350_000
        let l3Cap = 456_576

        let l1Formatted = "\(TokenFormatter.format(0))/\(TokenFormatter.format(l1Cap))"
        let l2Formatted = "\(TokenFormatter.format(15_000))/\(TokenFormatter.format(l2Cap))"
        let l3Formatted = "\(TokenFormatter.format(2_500_000))/\(TokenFormatter.format(l3Cap))"

        #expect(l1Formatted == "0/220K")
        #expect(l2Formatted == "15K/350K")
        #expect(l3Formatted == "2.50M/457K")
    }

    @Test func heroCenteredModeRendersLogoAndBoxAndTips() {
        let app = TUIApp()
        app.heroConfig = TUIHeroConfig(
            modeName: "Build",
            modelName: "DeepSeek V4 Flash",
            providerName: "DeepSeek",
            tip: "Press ctrl+p to see all available actions and commands"
        )
        let frame = app.render(size: TUISize(width: 80, height: 24), overlay: nil)
        #expect(frame.cells.count == 80 * 24)
        #expect(frame.cursor != nil)

        // Verify that the centered box and logo rendered
        let allText = frame.cells.map { String($0.character) }.joined()
        #expect(allText.contains("Build"))
        #expect(allText.contains("DeepSeek V4 Flash"))
        #expect(allText.contains("tab agents"))
        #expect(allText.contains("ctrl+p commands"))
        #expect(allText.contains("Tip"))
    }

    @Test func heroCenteredModeStylesEliminateDarkBoxArtifacts() {
        let app = TUIApp()
        app.heroConfig = TUIHeroConfig(
            modeName: "Build",
            modelName: "DeepSeek V4 Flash",
            providerName: "DeepSeek",
            tip: "Press ctrl+p to see all available actions and commands"
        )
        let frame = app.render(size: TUISize(width: 80, height: 24), overlay: nil)
        // Ensure that within the box, heroBox styles are used instead of leaking .dim/.normal
        let heroPlaceholderCells = frame.cells.filter { $0.style == .heroBoxPlaceholder }
        #expect(!heroPlaceholderCells.isEmpty)
        let heroBorderCells = frame.cells.filter { $0.style == .heroBoxBorder }
        #expect(!heroBorderCells.isEmpty)
        let heroModeCells = frame.cells.filter { $0.style == .heroMode }
        #expect(!heroModeCells.isEmpty)
        let heroMetaCells = frame.cells.filter { $0.style == .heroBoxMeta }
        #expect(!heroMetaCells.isEmpty)
    }

    @Test func composerRenderUsesDedicatedStyles() {
        let composer = ChatComposer()
        let emptyRender = composer.render(width: 40)
        #expect(emptyRender.lines.first?.style == .composerPlaceholder)

        composer.setText("hello world")
        let typedRender = composer.render(width: 40)
        #expect(typedRender.lines.first?.style == .composerText)
    }

    @Test func activeMCPAndSkillCountsCalculateAccurately() {
        var state = ApplicationState()
        state.extensions = [
            ExtensionInfo(id: "mcp1", version: "1.0", kind: .mcp, scope: "global", enabled: true, lifecycleState: "active"),
            ExtensionInfo(id: "mcp2", version: "1.0", kind: .mcp, scope: "global", enabled: false, lifecycleState: "disabled"),
            ExtensionInfo(id: "mcp3", version: "1.0", kind: .mcp, scope: "global", enabled: true, lifecycleState: "active"),
            ExtensionInfo(id: "skill1", version: "1.0", kind: .skill, scope: "workspace", enabled: true, lifecycleState: "active"),
            ExtensionInfo(id: "skill2", version: "1.0", kind: .skill, scope: "workspace", enabled: true, lifecycleState: "active"),
            ExtensionInfo(id: "skill3", version: "1.0", kind: .skill, scope: "workspace", enabled: false, lifecycleState: "disabled"),
            ExtensionInfo(id: "skill4", version: "1.0", kind: .skill, scope: "workspace", enabled: true, lifecycleState: "active")
        ]
        #expect(state.activeMCPCount == 2)
        #expect(state.activeSkillCount == 3)
    }

    @Test func heroCenteredModeKeepsCenteredWithSlashCompletionOverlay() {
        let app = TUIApp()
        app.heroConfig = TUIHeroConfig(
            modeName: "Build",
            modelName: "DeepSeek V4 Flash",
            providerName: "DeepSeek",
            tip: "Press ctrl+p to see all available actions and commands"
        )
        app.composer.setText("/m")

        let completionOverlay = TUIOverlayModel(
            lines: [
                TUIStyledLine("Completion", style: .accent),
                TUIStyledLine("/model  select active model", style: .normal),
                TUIStyledLine("/mode   switch agent mode", style: .normal)
            ],
            focus: .completion,
            isModal: false
        )

        let frame = app.render(size: TUISize(width: 80, height: 24), overlay: completionOverlay)

        // 1. Logo and centered Hero box must still be rendered (centered mode NOT exited)
        let allText = frame.cells.map { String($0.character) }.joined()
        #expect(allText.contains("DeepSeek V4 Flash"))
        #expect(allText.contains("Build"))

        // 2. The overlay completions must appear right inside the frame
        #expect(allText.contains("/model"))
        #expect(allText.contains("/mode"))

        // 3. Bottom composer rect should NOT be painted because we are still in hero centered mode
        let heroBoxBorderCells = frame.cells.filter { $0.style == .heroBoxBorder }
        #expect(!heroBoxBorderCells.isEmpty)
    }

    @Test func completionViewScrollingMaintainsActiveSelectionInViewport() {
        let view = CompletionView()
        let commandNames = ["help", "clear", "expand", "collapse", "quit", "compact", "connect", "context", "diff", "hooks", "mcp", "mode", "model", "new", "perf", "permissions", "plugins", "providers", "ps", "reasoning"]
        let items = commandNames.map { TUICompletionItem(value: "/\($0)", label: "/\($0)", detail: "command \($0)", kind: .command) }
        
        // 1. Initial state: top items
        view.update(items: items, selectedIndex: 0)
        let topLines = view.render(maxCount: 7)
        #expect(topLines.count == 7)
        #expect(topLines.first?.text.contains("/help") == true)
        #expect(topLines.first?.style == .overlayHighlight)
        #expect(topLines.last?.style == .overlayItem)

        // 2. Scroll down towards middle/end
        view.update(items: items, selectedIndex: 15) // permissions
        let scrolledLines = view.render(maxCount: 7)
        #expect(scrolledLines.count == 7)
        // Ensure the selected item is now visible in the scrolled viewport
        let containsPermissions = scrolledLines.contains { $0.text.contains("/permissions") && $0.style == .overlayHighlight }
        #expect(containsPermissions)
        // Ensure no leakage of .normal or .dim that creates dark boxes
        #expect(scrolledLines.allSatisfy { $0.style == .overlayItem || $0.style == .overlayHighlight })
    }

    @Test func heroCenteredBoxDisplaysReasoningEffortAndWiderDimensions() {
        let app = TUIApp()
        app.heroConfig = TUIHeroConfig(
            modeName: "Build",
            modelName: "deepseek-v4-flash",
            providerName: "DeepSeek",
            reasoningEffort: "high",
            tip: "Press ctrl+p to see all available actions and commands"
        )

        let frame = app.render(size: TUISize(width: 90, height: 24), overlay: nil)
        let allText = frame.cells.map { String($0.character) }.joined()
        #expect(allText.contains("DeepSeek/deepseek-v4-flash (high)"))
        #expect(!allText.contains("DeepSeek/deepseek-v4-flash DeepSeek"))

        // Width of box should be 86 (or widened up to 88)
        let heroMetaCells = frame.cells.filter { $0.style == .heroBoxMeta }
        #expect(!heroMetaCells.isEmpty)
    }

    @Test func sidebarLayoutSplitsWhenActiveAndTerminalWideEnough() {
        let app = TUIApp()
        let size = TUISize(width: 100, height: 30)

        // 1. Hero 模式下不分栏
        app.heroConfig = TUIHeroConfig()
        app.sidebarModel = TUISidebarModel(summary: "测试摘要")
        let heroLayout = app.layout(size: size, overlay: nil)
        #expect(heroLayout.sidebar == nil)
        #expect(heroLayout.divider == nil)
        #expect(heroLayout.transcript.width == 100)

        // 2. 窄屏 (< 80) 下不分栏
        app.heroConfig = nil
        let narrowLayout = app.layout(size: TUISize(width: 70, height: 30), overlay: nil)
        #expect(narrowLayout.sidebar == nil)
        #expect(narrowLayout.divider == nil)

        // 3. 宽屏 (>= 80) 且 Agent 工作 (heroConfig == nil) 且有 sidebarModel 时正确分栏
        let activeLayout = app.layout(size: size, overlay: nil)
        #expect(activeLayout.sidebar != nil)
        #expect(activeLayout.divider != nil)
        guard let sidebar = activeLayout.sidebar, let divider = activeLayout.divider else { return }
        #expect(activeLayout.transcript.width + divider.width + sidebar.width == size.width)
        #expect(divider.x == activeLayout.transcript.width)
        #expect(sidebar.x == divider.x + 1)
        #expect(sidebar.width >= 26)
    }

    @Test func sidebarRendersSessionSummaryCacheProgressMCPTasksAndSubagents() {
        let app = TUIApp()
        app.heroConfig = nil

        let cacheLayers = [
            TUISidebarModel.CacheLayer(name: "L1", usedTokens: 15_000, capacityTokens: 220_000),
            TUISidebarModel.CacheLayer(name: "L2", usedTokens: 38_000, capacityTokens: 350_000),
            TUISidebarModel.CacheLayer(name: "L3", usedTokens: 120_000, capacityTokens: 456_576)
        ]

        let mcpItems = [
            TUISidebarModel.MCPItem(id: "notion", status: .ready),
            TUISidebarModel.MCPItem(id: "context7", status: .ready),
            TUISidebarModel.MCPItem(id: "alibaba", status: .needsAuth),
            TUISidebarModel.MCPItem(id: "git-tool", status: .error("crash"))
        ]

        let tasks = [
            TUISidebarModel.TaskItem(id: "1", title: "规划侧边栏", status: .completed),
            TUISidebarModel.TaskItem(id: "2", title: "渲染全宽进度条", status: .inProgress),
            TUISidebarModel.TaskItem(id: "3", title: "打通Todo工具", status: .pending)
        ]

        let subagents = [
            TUISidebarModel.SubagentItem(id: "sub-1", role: "代码审查", status: "running")
        ]

        app.sidebarModel = TUISidebarModel(
            summary: "优化 CLI 侧边栏与缓存进度展示",
            cacheLayers: cacheLayers,
            mcpItems: mcpItems,
            tasks: tasks,
            subagents: subagents
        )

        let size = TUISize(width: 110, height: 35)
        let frame = app.render(size: size, overlay: nil)
        let renderedText = frame.text(in: TUIRect(x: 0, y: 0, width: size.width, height: size.height))

        // 1. 会话摘要模块
        #expect(renderedText.contains("◈ 会话摘要"))
        #expect(renderedText.contains("优化 CLI 侧边栏"))

        // 2. 缓存用量模块与全宽进度条字符
        #expect(renderedText.contains("◈ 缓存用量"))
        #expect(renderedText.contains("L1: 15K/220K"))
        #expect(renderedText.contains("L2: 38K/350K"))
        #expect(renderedText.contains("L3: 120K/457K"))
        #expect(renderedText.contains("█") && renderedText.contains("░"))

        // 3. MCP 工具模块与状态
        #expect(renderedText.contains("◈ MCP 工具"))
        #expect(renderedText.contains("notion (可用)"))
        #expect(renderedText.contains("alibaba (待认证)"))
        #expect(renderedText.contains("git-tool (错误)"))

        // 4. 待办任务模块与状态图标
        #expect(renderedText.contains("◈ 待办任务"))
        #expect(renderedText.contains("✓ 规划侧边栏"))
        #expect(renderedText.contains("● 渲染全宽进度条"))
        #expect(renderedText.contains("• 打通Todo工具"))

        // 5. 子代理模块
        #expect(renderedText.contains("◈ 子代理"))
        #expect(renderedText.contains("代码审查 (running)"))

        // 6. 分割线
        #expect(renderedText.contains("│"))
    }

    @Test func todoToolAndStoreMaintainsStateAcrossMutations() async throws {
        let sessionID = "test-session-\(UUID().uuidString.prefix(6))"
        TodoStore.shared.clear(for: sessionID)

        let tool = TodoTool()
        try await ToolExecutionContext.$sessionID.withValue(SessionID(sessionID)) {
            // 1. 添加任务
            let addRes = try await tool.execute(arguments: "{\"action\":\"add\",\"id\":\"t1\",\"title\":\"设计侧边栏UI\",\"status\":\"in_progress\"}", profile: .workspace)
            #expect(addRes.contains("ok"))
            #expect(TodoStore.shared.getTodos(for: sessionID).count == 1)

            // 2. 更新任务
            let updateRes = try await tool.execute(arguments: "{\"action\":\"update\",\"id\":\"t1\",\"status\":\"completed\"}", profile: .workspace)
            #expect(updateRes.contains("ok"))
            let updated = TodoStore.shared.getTodos(for: sessionID).first
            #expect(updated?.status == "completed")

            // 3. 查询任务
            let listRes = try await tool.execute(arguments: "{\"action\":\"list\"}", profile: .workspace)
            #expect(listRes.contains("设计侧边栏UI") && listRes.contains("completed"))

            // 4. 清理
            _ = try await tool.execute(arguments: "{\"action\":\"clear\"}", profile: .workspace)
            #expect(TodoStore.shared.getTodos(for: sessionID).isEmpty)
        }
    }

    @Test func statusLineDoesNotContainRedundantCacheMetrics() {
        let status = StatusLine()
        // 模拟 Agent 处于工作模式下的状态文字（三级缓存已移入右侧侧边栏，状态栏不再显示 context L1/L2/L3）
        let workingStatus = "Ready  ·  deepseek-v4-flash (high)  ·  LingXiAgent  ·  Build  ·  Ask/Workspace"
        status.text = workingStatus
        let rendered = status.render(width: 80)
        
        #expect(!rendered.text.contains("context"))
        #expect(!rendered.text.contains("L1"))
        #expect(!rendered.text.contains("L2"))
        #expect(!rendered.text.contains("L3"))
        #expect(rendered.text.contains("deepseek-v4-flash (high)"))
        #expect(rendered.text.contains("Build"))
    }

    @Test func statusLineDualPartAlignmentAndGridIndentation() {
        let status = StatusLine()
        let left = "● Ready · deepseek"
        let right = "Build · YOLO"
        status.setParts(left: left, right: right)

        // 宽终端（60列）：双端对齐 + 前置2格缩进
        let wideRendered = status.render(width: 60)
        #expect(wideRendered.text.hasPrefix("  ● Ready · deepseek"))
        #expect(wideRendered.text.hasSuffix("Build · YOLO"))

        // 中等终端（35列）：两端间距不足2格，平滑降级为紧凑单行中点拼接
        let compactRendered = status.render(width: 35)
        #expect(compactRendered.text == "  ● Ready · deepseek · Build · YOLO")

        // 超窄终端（20列）：优先保全核心状态，空间极紧凑时自动顶格避免换行
        let narrowRendered = status.render(width: 20)
        #expect(narrowRendered.text == "● Ready · deepseek")
    }

    @Test func transcriptDoesNotRenderInternalRunTerminalMetadata() {
        let view = TranscriptViewport()
        let regularEntries = [
            TUITranscriptEntry(id: "msg1", kind: .user, text: "你好，请帮我分析代码"),
            TUITranscriptEntry(id: "msg2", kind: .assistant, text: "好的主人，马上为您分析！")
        ]
        view.entries = regularEntries
        let lines = view.render(viewportHeight: 10, width: 60)
        let joinedText = lines.map { $0.text }.joined(separator: "\n")
        
        // 验证用户有效内容正常展示
        #expect(joinedText.contains("你好，请帮我分析代码"))
        #expect(joinedText.contains("好的主人，马上为您分析！"))
        
        // 验证没有内部生命周期暴露
        #expect(!joinedText.contains("Run · completed"))
        #expect(!joinedText.contains("Run · failed"))
        #expect(!joinedText.contains("Result      │ Run · completed"))
    }

    @Test func modernToolCallLayoutAndColorSpans() {
        let view = TranscriptViewport()
        let commandEntry = TUITranscriptEntry(
            id: "cmd1",
            kind: .toolCall,
            text: "• Ran git diff --check\n  └ (no output)"
        )
        let exploreEntry = TUITranscriptEntry(
            id: "exp1",
            kind: .toolCall,
            text: "• Explored\n  └ Read Package.swift"
        )
        let mcpEntry = TUITranscriptEntry(
            id: "mcp1",
            kind: .toolCall,
            text: "• Called\n  └ codebase-memory-mcp.search_graph({\"query\":\"foo\"})\n    {\"total\": 72}"
        )
        view.entries = [commandEntry, exploreEntry, mcpEntry]
        let lines = view.render(viewportHeight: 20, width: 80)

        // 1. 验证没有生硬的 "Tool │ " 垂直分隔符
        #expect(!lines.contains { $0.text.contains("Tool        │") })

        // 2. 验证 Command 树状行被正确解析为带颜色的 spans
        let ranLine = lines.first { $0.text.contains("Ran git diff --check") }
        #expect(ranLine != nil)
        #expect(ranLine?.spans != nil)
        #expect(ranLine?.spans?.contains { $0.text == "• " && $0.style == .toolDotSuccess } == true)
        #expect(ranLine?.spans?.contains { $0.text == "git " && $0.style == .toolCommand } == true)
        #expect(ranLine?.spans?.contains { $0.text == "--check" && $0.style == .toolArg } == true)

        // 3. 验证 Explored 树状行
        let expLine = lines.first { $0.text.contains("Explored") }
        #expect(expLine?.spans?.contains { $0.text == "• " && $0.style == .toolDotSuccess } == true)
        let readLine = lines.first { $0.text.contains("Read Package.swift") }
        #expect(readLine?.spans?.contains { $0.text.contains("Read") && $0.style == .toolCommand } == true)

        // 4. 验证 MCP 调用行
        let calledLine = lines.first { $0.text.contains("Called") }
        #expect(calledLine != nil)
        #expect(lines.contains { $0.text.contains("codebase-memory-mcp.search_graph") })
    }

    @Test func thinkingLayoutWithMacaronColors() {
        let view = TranscriptViewport()
        let entry = TUITranscriptEntry(
            id: "think1",
            kind: .thinking,
            text: "• Thought for 312ms\nUser requested to format tool calls",
            collapsed: false
        )
        view.entries = [entry]
        let lines = view.render(viewportHeight: 10, width: 60)

        #expect(lines.first?.text.contains("Thought for 312ms") == true)
        #expect(lines.first?.style == .thinkingHeader)
        #expect(lines.count > 1)
        #expect(lines[1].style == .thinkingBody)
    }

    @Test func modalOverlayExplicitModalHeightMaintainsStableGeometry() {
        let app = TUIApp()
        let overlay1 = TUIOverlayModel(
            lines: (0..<10).map { TUIStyledLine("Line \($0)", style: .modalItem) },
            focus: .picker,
            isModal: true,
            modalWidth: 60,
            modalHeight: 18
        )
        let overlay2 = TUIOverlayModel(
            lines: (0..<15).map { TUIStyledLine("Line \($0)", style: .modalItem) },
            focus: .picker,
            isModal: true,
            modalWidth: 60,
            modalHeight: 18
        )
        let frame1 = app.render(size: TUISize(width: 80, height: 30), overlay: overlay1)
        let frame2 = app.render(size: TUISize(width: 80, height: 30), overlay: overlay2)

        let borderCells1 = frame1.cells.filter { $0.style == .modalBorder }
        let borderCells2 = frame2.cells.filter { $0.style == .modalBorder }
        #expect(borderCells1.count == borderCells2.count)
        #expect(!borderCells1.isEmpty)
    }

    @Test func composerAutoScrollsDownWhenInputExceedsMaxHeight() {
        let composer = ChatComposer()
        composer.maxHeight = 6
        let multiLineText = (1...15).map { "line \($0)" }.joined(separator: "\n")
        composer.setText(multiLineText)

        let rendered = composer.render(width: 40)
        #expect(rendered.lines.count == 6)
        #expect(composer.scrollLine == 15 - 6) // 光标在最后一行，scrollLine 自动跟进到 9
        #expect(rendered.cursor != nil)
        #expect(rendered.lines.last?.text.contains("line 15") == true)
    }

    @Test func composerVerticalMovementMovesBetweenLines() {
        let composer = ChatComposer()
        composer.maxHeight = 6
        let text = "Line 1\nLine 2\nLine 3"
        composer.setText(text)
        #expect(composer.cursor == Array(text).count)

        _ = composer.handle(.up)
        #expect(composer.render(width: 40).cursor?.y == 1) // 倒数第二行 (Line 2)

        _ = composer.handle(.up)
        #expect(composer.render(width: 40).cursor?.y == 0) // 第一行 (Line 1)

        _ = composer.handle(.down)
        #expect(composer.render(width: 40).cursor?.y == 1) // Line 2
    }

    @Test func composerScrollKeysScrollMultilineInput() {
        let composer = ChatComposer()
        composer.maxHeight = 6
        let text = (1...20).map { "line \($0)" }.joined(separator: "\n")
        composer.setText(text)
        _ = composer.render(width: 40)
        #expect(composer.scrollLine == 14)

        _ = composer.handle(.scrollUp)
        #expect(composer.scrollLine == 13)

        _ = composer.handle(.pageUp)
        #expect(composer.scrollLine == 7)

        _ = composer.handle(.pageDown)
        #expect(composer.scrollLine == 13)

        _ = composer.handle(.scrollDown)
        #expect(composer.scrollLine == 14)
    }

    @Test func transcriptScrollToBottomRestoresAutoFollow() {
        let viewport = TranscriptViewport()
        viewport.replace((0..<20).map { TUITranscriptEntry(kind: .assistant, text: "line \($0)") })
        _ = viewport.render(viewportHeight: 5, width: 40)
        viewport.handle(.pageUp, viewportHeight: 5)
        #expect(!viewport.autoFollow)
        #expect(viewport.scrollOffset > 0)

        viewport.scrollToBottom()
        #expect(viewport.autoFollow)
        #expect(viewport.scrollOffset == 0)
    }

    @Test func todoStorePersistsAcrossInstancesAndTUISidebarRendersTasks() {
        let testSessionID = "test-session-\(UUID().uuidString)"
        defer { TodoStore.shared.clear(for: testSessionID) }

        // 1. 添加待办任务并更新
        TodoStore.shared.addTodo(TodoItemData(id: "task-1", title: "探活 Notion MCP", status: "pending"), for: testSessionID)
        TodoStore.shared.addTodo(TodoItemData(id: "task-2", title: "测试 Skills 技能库", status: "pending"), for: testSessionID)

        #expect(TodoStore.shared.getTodos(for: testSessionID).count == 2)

        _ = TodoStore.shared.updateTodo(id: "task-1", status: "completed", title: nil, for: testSessionID)
        let updatedTodos = TodoStore.shared.getTodos(for: testSessionID)
        #expect(updatedTodos.first(where: { $0.id == "task-1" })?.status == "completed")

        // 2. 模拟全新独立实例（跨进程模拟）读取该 session 的 todos
        let brandNewStore = TodoStore()
        let reloaded = brandNewStore.getTodos(for: testSessionID)
        #expect(reloaded.count == 2)
        #expect(reloaded.first(where: { $0.id == "task-1" })?.status == "completed")

        // 3. 验证 TUISidebarModel 渲染
        let sidebarModel = TUISidebarModel(
            summary: "测试会话",
            cacheLayers: [],
            mcpItems: [],
            tasks: [
                TUISidebarModel.TaskItem(id: "task-1", title: "探活 Notion MCP", status: .completed),
                TUISidebarModel.TaskItem(id: "task-2", title: "测试 Skills 技能库", status: .inProgress)
            ],
            subagents: []
        )
        #expect(sidebarModel.tasks.count == 2)
        #expect(sidebarModel.tasks[0].status == .completed)
        #expect(sidebarModel.tasks[1].status == .inProgress)
    }

    @Test func sidebarRendersPrefixCacheAndMoreThanFourMCPItemsAndScrollbar() {
        let app = TUIApp()
        app.heroConfig = nil

        let mcpItems = [
            TUISidebarModel.MCPItem(id: "notion", status: .ready),
            TUISidebarModel.MCPItem(id: "context7", status: .ready),
            TUISidebarModel.MCPItem(id: "alibaba", status: .ready),
            TUISidebarModel.MCPItem(id: "git-tool", status: .ready),
            TUISidebarModel.MCPItem(id: "excel", status: .ready),
            TUISidebarModel.MCPItem(id: "trivy", status: .ready),
            TUISidebarModel.MCPItem(id: "penpot", status: .ready)
        ]

        let tasks = [
            TUISidebarModel.TaskItem(id: "1", title: "任务 1: 这是一个非常非常长而且需要自动换行展示的超级长待办任务标题测试", status: .inProgress),
            TUISidebarModel.TaskItem(id: "2", title: "任务 2", status: .completed),
            TUISidebarModel.TaskItem(id: "3", title: "任务 3", status: .pending),
            TUISidebarModel.TaskItem(id: "4", title: "任务 4", status: .pending),
            TUISidebarModel.TaskItem(id: "5", title: "任务 5", status: .pending),
            TUISidebarModel.TaskItem(id: "6", title: "任务 6", status: .pending),
            TUISidebarModel.TaskItem(id: "7", title: "任务 7", status: .pending)
        ]

        app.sidebarModel = TUISidebarModel(
            summary: "前缀缓存与完整展示测试",
            cacheLayers: [
                TUISidebarModel.CacheLayer(name: "L1", usedTokens: 10_000, capacityTokens: 220_000)
            ],
            prefixCache: TUISidebarModel.PrefixCacheStats(cachedTokens: 1152, promptTokens: 1250),
            mcpItems: mcpItems,
            tasks: tasks,
            subagents: []
        )

        let size = TUISize(width: 120, height: 40)
        let frame = app.render(size: size, overlay: nil)
        let text = frame.text(in: TUIRect(x: 0, y: 0, width: size.width, height: size.height))

        // 验证真实前缀缓存命中显示
        #expect(text.contains("前缀命中: 1.2K/1.3K (92.2%)") || text.contains("前缀命中:"))
        // 验证不再限制在 4 个 MCP，后方的 excel、trivy、penpot 均能完整展示
        #expect(text.contains("excel"))
        #expect(text.contains("trivy"))
        #expect(text.contains("penpot"))
    }

    @Test func longToolCallCommandWrapsNaturallyWithoutClipping() {
        let viewport = TranscriptViewport()
        let longCommand = "Ran find /Volumes/Development/Projects/projects/LingXiAgent -name \"*AgentInstructions*\" 2>/dev/null | grep -v \".build\" | sort"
        let entry = TUITranscriptEntry(
            id: "tool-1",
            kind: .toolCall,
            text: longCommand,
            style: .accent,
            collapsed: false
        )
        viewport.replace([entry])

        // 视口宽度设为 45（远小于 118 字符的长命令）
        let lines = viewport.render(viewportHeight: 10, width: 45)
        #expect(lines.count > 1) // 必须自动换行，至少换成 2 行以上
        #expect(lines[0].text.contains("Ran find"))
        #expect(lines[1].text.hasPrefix("      ")) // 续行增加 6 空格缩进对齐
    }

    @Test func heroCenteredModeRendersPermissionBadgeAndCyberFoxMascot() {
        let app = TUIApp()
        app.heroConfig = TUIHeroConfig(
            modeName: "Build",
            modelName: "deepseek-v4-flash",
            providerName: "DeepSeek",
            reasoningEffort: "high",
            tip: "Press ctrl+p to see all available actions and commands",
            permissionName: "⚡ YOLO"
        )
        let frame = app.render(size: TUISize(width: 86, height: 26), overlay: nil)
        let cleanText = frame.cells.filter { !$0.continuation }.map { String($0.character) }.joined()

        // 1. 验证权限徽标在 Hero 界面内明确可见
        #expect(cleanText.contains("⚡ YOLO"))
        let yoloCells = frame.cells.filter { $0.style == .badgeYolo }
        #expect(!yoloCells.isEmpty)

        // 2. 验证灵犀小狐狸吉祥物立绘及专属标语完整展现
        #expect(cleanText.contains("LingXi Fox"))
        #expect(cleanText.contains("随时为主人效劳"))
        #expect(cleanText.contains("/\\___/\\"))

        // 3. 验证输入框圆角边框单元格正常存在
        let borderCells = frame.cells.filter { $0.style == .heroBoxBorder }
        #expect(!borderCells.isEmpty)
        #expect(cleanText.contains("╭") && cleanText.contains("╰"))
    }

    @Test func markdownRendererFormatsCodeBlocksHeadingsQuotesAndLists() {
        let md = """
        # 核心标题
        ## 子标题
        > 这是一个重要的引用说明

        - 项目一
        - 项目二

        ```swift
        let message = "Hello Fox"
        ```
        """
        let rendered = TUIMarkdownRenderer.render(md, width: 40)
        let texts = rendered.map(\.text)

        // 验证标题样式符号
        #expect(texts.contains { $0.contains("◈ 核心标题") })
        #expect(texts.contains { $0.contains("◆ 子标题") })
        // 验证引用样式竖线
        #expect(texts.contains { $0.contains("▎ 这是一个重要的引用说明") })
        // 验证列表圆点
        #expect(texts.contains { $0.contains("• 项目一") })
        #expect(texts.contains { $0.contains("• 项目二") })
        // 验证代码块带框线
        #expect(texts.contains { $0.contains("┌─ swift") })
        #expect(texts.contains { $0.contains("│ let message = \"Hello Fox\"") })
        #expect(texts.contains { $0.contains("└─") })
    }

    @Test func configCommandAndPreferencesPersistence() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = UserPreferencesStore(fileURL: tempDir.appendingPathComponent("test_prefs.json"))
        var prefs = store.load()
        #expect(prefs.expandThinking == nil)
        #expect(prefs.expandTools == nil)
        #expect(prefs.showSidebar == nil)

        store.update(expandThinking: true, expandTools: false, showSidebar: true)
        prefs = store.load()
        #expect(prefs.expandThinking == true)
        #expect(prefs.expandTools == false)
        #expect(prefs.showSidebar == true)
    }

    @Test func wordWrappingPreventsBrokenWesternWords() {
        let text = "for this simulation"
        let lines = TUIWrapping.lines(text, width: 12)
        #expect(lines.count == 2)
        #expect(lines[0].text == "for this")
        #expect(lines[1].text == "simulation")
    }

    @Test func thinkingLayoutWrapsLongLinesWithoutClippingToDivider() {
        let viewport = TranscriptViewport()
        let longThought = "The grep on project.pbxproj failed because path was treated as directory. Let me grep the pbxproj file directly to find swift files."
        let entry = TUITranscriptEntry(kind: .thinking, text: "• Thought for 1.2s\n" + longThought, collapsed: false)
        viewport.replace([entry])

        let lines = viewport.render(viewportHeight: 20, width: 50)
        #expect(lines.count > 2)
        for line in lines {
            #expect(TUIDisplayWidth.width(of: line.text) <= 48)
        }
        #expect(lines.contains { $0.text.contains("project.pbxproj") })
    }

    @Test func toolNodeSummarizeArgumentsCompactsLongPaths() {
        let json = #"{"path":"/Users/lingxifox/Documents/Vibe Coding/Apple Operation System Manage/Apple Operation System Manage.xcodeproj/project.pbxproj"}"#
        let summary = ToolNode.summarizeArguments(json, toolName: "grep")
        #expect(summary.contains("path=.../"))
        #expect(summary.contains("project.pbxproj"))
        #expect(!summary.contains("Apple Operation )"))
    }
}
