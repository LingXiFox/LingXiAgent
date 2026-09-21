import Foundation
import LingXiApplication
import LingXiPlatform
import LingXiProtocol
import LingXiTUIComponents

@MainActor
public final class ApplicationTUI: Frontend {

    private struct FrontendCommandItem: Sendable {
        let name: String
        let aliases: [String]
        let description: String
        let category: String
        let argumentSchema: String

        init(name: String, aliases: [String] = [], description: String, category: String, argumentSchema: String = "") {
            self.name = name
            self.aliases = aliases
            self.description = description
            self.category = category
            self.argumentSchema = argumentSchema
        }
    }

    private static let localCommands: [FrontendCommandItem] = [
        FrontendCommandItem(name: "help", description: "Show help and available commands", category: "General"),
        FrontendCommandItem(name: "theme", aliases: ["themes"], description: "Switch or list themes (e.g. /theme light, /theme catppuccin)", category: "Appearance"),
        FrontendCommandItem(name: "keybindings", aliases: ["keys", "shortcuts"], description: "Show active keybindings and shortcuts", category: "General"),
        FrontendCommandItem(name: "clear", description: "Clear current transcript", category: "View"),
        FrontendCommandItem(name: "expand", description: "Expand all collapsed thinking and tool outputs", category: "View"),
        FrontendCommandItem(name: "collapse", description: "Collapse all long thinking and tool outputs", category: "View"),
        FrontendCommandItem(name: "tasks", aliases: ["task", "bg"], description: "Manage background tasks modal", category: "System"),
        FrontendCommandItem(name: "quit", aliases: ["exit"], description: "Exit LingXi TUI", category: "General")
    ]

    private enum Overlay {
        case commandPalette(query: String, selected: Int)
        case completion(tokenStart: Int, selected: Int)
        case modelPicker(query: String, selected: Int)
        case variantPicker(modelID: String, query: String, selected: Int, variants: [String])
        case sessionPicker(query: String, selected: Int)
        case configModal(selected: Int)
        case tasksModal(selected: Int, tasks: [BackgroundTaskSnapshot], expandedDetail: Bool)
        case commandModal(title: String, content: String, scrollOffset: Int)
        case themePicker(query: String, selected: Int)
        case modePicker(selected: Int)
        case permissionsPicker(selected: Int)
        case reasoningPicker(selected: Int)
    }

    public let options: TUILaunchOptions
    private let terminal: any TerminalBackend
    private let view = TUIApp()
    private let completionView = CompletionView()
    private var store: (any FrontendRuntime)?
    private var latestState = ApplicationState()
    private var pendingChanges: ApplicationChangeSet?
    private var activeDisplayedSessionID: SessionID?
    private var commands: [ApplicationCommand] = []
    private var overlay: Overlay?
    private var hitlSelectedOption = 0
    private var activeInteractionID: InteractionID?
    private var referenceCandidates: [String] = []
    private var referenceScanTask: Task<Void, Never>?
    private var renderedPreferences: UserPreferences?
    private var spinnerIndex = 0
    private var commandEntries: [TUITranscriptEntry] = []
    private var shouldQuit = false
    private var renderCount = 0
    private var actionTail: Task<Void, Never>?
    private var eventPump: UIEventPump?
    private let animationTicker = TUIAnimationTicker()
    private let animationClock = ContinuousClock()
    private var animationNow: ContinuousClock.Instant
    private var activityStartedAt: [String: ContinuousClock.Instant] = [:]
    private var activityFinishedDuration: [String: Duration] = [:]
    private var committedEntryCache: [TimelineNodeID: TUITranscriptEntry] = [:]
    private var lastRenderedNodeCount = 0
    private var userToggledEntries: [String: Bool] = [:]
    private var waitingStartedAt: ContinuousClock.Instant?
    private var selectionStart: TUIPoint?
    private var selectionRect: TUIRect?
    private var lastRenderedFrame: TUIFrame?
    private var copyFeedback: String?
    private var lastMousePoint: TUIPoint?
    private var sidebarScrollOffset = 0
    private var mcpScrollOffset = 0
    private var taskScrollOffset = 0

    // MARK: - Sidebar Revision Cache
    private struct SidebarRevisionState: Equatable {
        let sessionID: SessionID?
        let sessionTitle: String?
        let compactionGeneration: Int
        let cacheEpoch: Int
        let contextActivePCoreTokens: Int
        let contextECoreTotalBytes: Int
        let contextECoreObjectCount: Int
        let contextCacheReadTokens: Int
        let extensionsCount: Int
        let extensionsHash: Int
        let workflowsCount: Int
        let backgroundTasksCount: Int
        let failedMCPCount: Int
        let preferencesShowSidebar: Bool?
        let sidebarScrollOffset: Int
        let mcpScrollOffset: Int
        let taskScrollOffset: Int
    }
    private var lastSidebarRevision: SidebarRevisionState?
    private var cachedSidebarModel: TUISidebarModel?

    private lazy var frameScheduler = TUIFrameScheduler(targetFps: 60) { [weak self] dirtyFlags in
        guard let self else { return }
        if dirtyFlags.contains(.content) {
            self.refreshView(self.latestState)
        } else if dirtyFlags.contains(.animation) {
            self.refreshAnimation(self.latestState)
        }
        self.render()
    }

    public init(options: TUILaunchOptions = .default) {
        self.options = options
        self.terminal = POSIXTerminalBackend(noAltScreen: options.noAltScreen)
        animationNow = animationClock.now
        let prefs = UserPreferencesStore.shared.load()
        // No canned default model: with nothing selected the model picker
        // decides. A hardcoded ID here would advertise a model this account may
        // not be able to reach.
        let initialModel = options.initialModelID ?? prefs.lastModelID ?? ""
        let initialEffort = options.reasoningEffort?.rawValue ?? prefs.lastReasoningEffort ?? "auto"
        // The provider is whatever the model reference names, never inferred
        // from the model ID's spelling.
        let initialProvider: String = {
            guard let slashIdx = initialModel.firstIndex(of: "/") else { return "" }
            return String(initialModel[..<slashIdx])
        }()
        let initialPermission = options.isYoloMode ? "⚡ YOLO" : "Ask/Workspace"
        view.heroConfig = TUIHeroConfig(
            modeName: "Build",
            modelName: initialModel,
            providerName: initialProvider,
            reasoningEffort: initialEffort,
            tip: "Press ctrl+p to see all available actions and commands",
            permissionName: initialPermission
        )

        // 注册快捷键配置与主题实时重绘监听
        KeybindingRegistry.shared.loadFromConfigFile()
        ThemeManager.shared.addObserver { [weak self] _ in
            Task { @MainActor in
                self?.committedEntryCache.removeAll()
                if let state = self?.latestState {
                    self?.refreshView(state)
                }
            }
        }
    }

    private var allCommands: [FrontendCommandItem] {
        let currentCommands = commands
        var map: [String: FrontendCommandItem] = [:]
        for item in Self.localCommands {
            map[item.name] = item
        }
        for cmd in currentCommands {
            let existing = map[cmd.name]
            let mergedAliases = Array(Set((existing?.aliases ?? []) + cmd.aliases)).sorted()
            let hasChinese = cmd.description.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            let preferredDesc = hasChinese ? cmd.description : (existing?.description ?? cmd.description)
            map[cmd.name] = FrontendCommandItem(
                name: cmd.name,
                aliases: mergedAliases,
                description: preferredDesc,
                category: existing?.category ?? cmd.category,
                argumentSchema: cmd.argumentSchema
            )
        }
        var result: [FrontendCommandItem] = []
        var seen = Set<String>()
        for item in Self.localCommands {
            if let merged = map[item.name], !seen.contains(item.name) {
                result.append(merged)
                seen.insert(item.name)
            }
        }
        for cmd in currentCommands {
            if let merged = map[cmd.name], !seen.contains(cmd.name) {
                result.append(merged)
                seen.insert(cmd.name)
            }
        }
        return result
    }


    /// 挂载到由外部 Composition Root 装配好的 FrontendRuntime 并启动前端界面
    public func run(with store: any FrontendRuntime) async throws {
        debug("run.begin")
        if let workDir = options.initialWorkingDir, !workDir.isEmpty {
            FileManager.default.changeCurrentDirectoryPath(workDir)
        }
        debug("terminal.start.begin")
        try terminal.start()
        debug("terminal.start.end")
        defer { terminal.stop() }

        debug("connecting.frame.begin")
        let initialWorkspace = FileManager.default.currentDirectoryPath.split(separator: "/").last.map(String.init) ?? "LingXiAgent"
        view.header.subtitle = options.isYoloMode ? "⚡ YOLO · Connecting" : "Connecting"
        view.statusLine.setParts(left: "● 正在连接...", right: "📂 \(initialWorkspace)")
        render()
        debug("connecting.frame.end")

        self.store = store
        commands = await store.availableCommands

        let pump = UIEventPump()
        self.eventPump = pump

        let coalescer = FrontendUpdateCoalescer()

        let updates = Task { [store, coalescer] in
            for await update in await store.updates {
                await coalescer.ingest(update: update)
            }
            await coalescer.finish()
        }
        defer { updates.cancel() }

        let signalTask = Task { [coalescer, pump] in
            for await _ in await coalescer.invalidationSignal {
                pump.markStateInvalidated()
            }
        }
        defer { signalTask.cancel() }
        defer { actionTail?.cancel() }
        defer { referenceScanTask?.cancel() }

        let animationUpdates = Task { [weak self] in
            guard let self else { return }
            for await tick in self.animationTicker.stream() {
                self.animationTick(tick)
            }
        }
        defer { animationUpdates.cancel() }

        let inputReader = Task.detached { [terminal, pump] in
            while !Task.isCancelled {
                if let event = terminal.nextInput() {
                    pump.postInput(event)
                    if case .quit = event { break }
                    if case .interrupt = event { break }
                }
            }
        }
        defer { inputReader.cancel() }

        debug("event.loop.begin")

        eventLoop: for await _ in pump.wakeupStream {
            let batch = pump.drain()

            // 1. 优先消费所有已到达的用户输入（无损 FIFO，零丢键，即时手感）
            for inputEvent in batch.inputs {
                await handle(inputEvent, store: store)
                if case .tick = inputEvent {
                } else if case .mouseDrag = inputEvent {
                    // mouseDrag 仅记录坐标，避免高频拖拽划词打爆渲染帧率
                } else {
                    frameScheduler.markDirty(.input)
                }
                if shouldQuit {
                    frameScheduler.flush()
                    pump.finish()
                    break eventLoop
                }
            }

            // 2. 消费后台本地命令执行结果
            for entry in batch.commandResults {
                commandEntries.append(entry)
                latestState = await store.state
                frameScheduler.markDirty(.content)
            }

            // 3. 处理折叠合并后的状态更新（单次 Drain，杜绝状态暴风雨洪泛）
            if batch.hasStateInvalidation {
                if let (state, changes, _) = await coalescer.drain() {
                    applyStateUpdate(state: state, changes: changes, store: store)
                }
            }
        }
        eventPump = nil
    }

    private func applyStateUpdate(state: ApplicationState, changes: ApplicationChangeSet, store: any FrontendRuntime) {
        if latestState.currentWorkspace?.rootPath != state.currentWorkspace?.rootPath {
            referenceScanTask?.cancel()
            referenceCandidates = []
            referenceScanTask = Task { [weak self, store] in
                let candidates = await store.workspaceReferenceCandidates()
                guard !Task.isCancelled else { return }
                self?.referenceCandidates = candidates
                self?.frameScheduler.markDirty(.content)
            }
        }
        if pendingChanges == nil {
            pendingChanges = changes
        } else {
            pendingChanges?.merge(with: changes)
        }
        latestState = state
        if options.isYoloMode, let interaction = state.activeInteraction, interaction.kind == .permission {
            enqueue { await store.dispatch(.grantPermission(interactionID: interaction.interactionID, decision: .allow)) }
        }
        frameScheduler.markDirty(.content)
    }

    /// 便捷入口：由内置默认 AppCompositionRoot 装配 Stdio Core 并运行
    public func run() async {
        do {
            let root = AppCompositionRoot(configuration: options.applicationConfiguration)
            try await root.launch(with: self)
        } catch {
            print("LingXiTUI 启动失败: \(error)")
        }
    }

    private func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["LINGXI_TUI_DEBUG"] == "1" else { return }
        let timestamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[\(timestamp)] [LingXiTUI] \(message)\n".utf8))
    }

    private func handle(_ event: TUIInputEvent, store: any FrontendRuntime) async {
        if event == .quit || event == .interrupt {
            shouldQuit = true
            return
        }
        if event == .escape {
            let hasRunningBg = latestState.backgroundTasks.contains(where: { $0.status == .running })
            let running = isActive(latestState)
                || waitingStartedAt != nil
                || !(latestState.activeSessionState?.activeToolCallIDs.isEmpty ?? true)
                || hasRunningBg

            if running {
                Task {
                    await store.dispatch(.stopCurrentRun)
                }
                waitingStartedAt = nil
                overlay = nil
                view.transcript.clearSelection()
                view.setFocus(.composer)
                return
            }
        }
        if latestState.activeInteraction != nil {
            await handleInteraction(event, store: store)
            return
        }

        if case .commandPalette = overlay {
            await handleCommandPalette(event, store: store)
            return
        }

        if case .completion = overlay {
            await handleCompletion(event, store: store)
            return
        }

        if case .modelPicker = overlay {
            await handleModelPicker(event, store: store)
            return
        }

        if case .variantPicker = overlay {
            await handleVariantPicker(event, store: store)
            return
        }

        if case .sessionPicker = overlay {
            await handleSessionPicker(event, store: store)
            return
        }

        if case .configModal = overlay {
            await handleConfigModal(event)
            return
        }

        if case .tasksModal = overlay {
            await handleTasksModal(event, store: store)
            return
        }

        if case .commandModal = overlay {
            await handleCommandModal(event)
            return
        }

        if case .themePicker = overlay {
            await handleThemePicker(event, store: store)
            return
        }

        if case .modePicker = overlay {
            await handleModePicker(event)
            return
        }

        if case .permissionsPicker = overlay {
            await handlePermissionsPicker(event)
            return
        }

        if case .reasoningPicker = overlay {
            await handleReasoningPicker(event)
            return
        }

        // 快捷键引擎拦截与分发
        if let stroke = KeybindingDispatcher.toKeyStroke(from: event),
           let action = KeybindingDispatcher.shared.dispatch(stroke: stroke) {
            switch action {
            case .toggleTheme:
                openThemePicker()
                refreshView(latestState)
                return
            case .showHelp:
                executeLocalOrApplicationCommand("/keybindings", store: store)
                return
            case .clearScreen:
                executeLocalOrApplicationCommand("/clear", store: store)
                return
            default:
                break
            }
        }

        switch event {
        case .quit, .interrupt:
            shouldQuit = true
        case .commandPalette:
            overlay = .commandPalette(query: "", selected: 0)
        case .cycleReasoningEffort:
            await cycleReasoningEffort(store: store)
        case .shiftTab:
            await cycleMode(store: store)
        case let .mouseClick(x, y):
            let pt = TUIPoint(x: x, y: y)
            lastMousePoint = pt
            selectionStart = nil
            selectionRect = nil
            handleMouseClick(at: pt)
            frameScheduler.markDirty(.input)
        case let .mouseDown(x, y):
            let pt = TUIPoint(x: x, y: y)
            lastMousePoint = pt
            selectionStart = pt
            selectionRect = nil
        case let .mouseDrag(x, y):
            let pt = TUIPoint(x: x, y: y)
            lastMousePoint = pt
            if let start = selectionStart {
                let rect = TUIRect(from: start, to: pt)
                if rect.width > 0 && rect.height > 0 {
                    selectionRect = rect
                    frameScheduler.markDirty(.input)
                }
            }
        case let .mouseUp(x, y):
            let pt = TUIPoint(x: x, y: y)
            lastMousePoint = pt
            if let rect = selectionRect, (rect.width > 1 || rect.height > 1) {
                // 用户划词框选结束，自动复制选中文本至剪贴板
                if let frame = lastRenderedFrame {
                    let text = frame.text(in: rect)
                    if !text.isEmpty {
                        ClipboardSupport.copy(text)
                        copyFeedback = "✓ Copied (\(text.count) chars)"
                        frameScheduler.markDirty(.input)
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(2.5))
                            if self?.copyFeedback?.hasPrefix("✓ Copied") == true {
                                self?.copyFeedback = nil
                                self?.frameScheduler.markDirty(.input)
                            }
                        }
                    }
                }
                selectionStart = nil
            } else {
                selectionStart = nil
                selectionRect = nil
                handleMouseClick(at: pt)
                frameScheduler.markDirty(.input)
            }
        case .pageUp, .pageDown, .scrollUp, .scrollDown:
            let layout = view.layout(size: terminal.size, overlay: overlayModel())
            if let lastMouse = selectionStart ?? lastMousePoint,
               let sb = layout.sidebar,
               lastMouse.x >= sb.x && lastMouse.x < sb.x + sb.width &&
               lastMouse.y >= sb.y && lastMouse.y < sb.y + sb.height {
                let isTopHalf = lastMouse.y < sb.y + (sb.height / 2)
                if event == .scrollUp || event == .pageUp {
                    if isTopHalf {
                        mcpScrollOffset = max(0, mcpScrollOffset - 1)
                    } else {
                        taskScrollOffset = max(0, taskScrollOffset - 1)
                    }
                    sidebarScrollOffset = max(0, sidebarScrollOffset - 1)
                } else {
                    if isTopHalf {
                        mcpScrollOffset += 1
                    } else {
                        taskScrollOffset += 1
                    }
                    sidebarScrollOffset += 1
                }
                refreshView(latestState)
                frameScheduler.markDirty(.content)
                return
            }
            let contentWidth = max(1, terminal.size.width - 10)
            let wrappedCount = TUIWrapping.lines(view.composer.text, width: contentWidth).count
            if view.focus == .composer && wrappedCount > 1 {
                _ = view.composer.handle(event)
                frameScheduler.markDirty(.input)
            } else {
                view.handleTranscriptInput(event, viewportHeight: layout.transcript.height)
            }
        case .up, .down, .home, .end:
            let layout = view.layout(size: terminal.size, overlay: overlayModel())
            if view.focus == .transcript {
                if event == .up {
                    view.transcript.selectPrevious()
                } else if event == .down {
                    if view.transcript.selectedIndex >= view.transcript.entries.count - 1 {
                        view.transcript.clearSelection()
                        view.setFocus(.composer)
                        return
                    } else {
                        view.transcript.selectNext()
                    }
                }
                view.handleTranscriptInput(event, viewportHeight: layout.transcript.height)
            } else if event == .up && view.composer.isEmpty && view.composer.history.isEmpty && !view.transcript.entries.isEmpty {
                view.setFocus(.transcript)
                view.transcript.selectPrevious()
            } else {
                _ = view.composer.handle(event)
                frameScheduler.markDirty(.input)
            }
        case .enter where view.focus == .transcript && view.transcript.selectedItemID != nil,
             .character(" ") where view.focus == .transcript && view.transcript.selectedItemID != nil:
            if let selectedID = view.transcript.selectedItemID {
                let current = userToggledEntries[selectedID] ?? view.transcript.isCollapsed(id: selectedID)
                userToggledEntries[selectedID] = !current
                committedEntryCache.removeValue(forKey: TimelineNodeID(selectedID))
                refreshView(latestState)
            }
        case .right where view.focus == .transcript && view.transcript.selectedItemID != nil:
            if let selectedID = view.transcript.selectedItemID {
                userToggledEntries[selectedID] = false
                committedEntryCache.removeValue(forKey: TimelineNodeID(selectedID))
                refreshView(latestState)
            }
        case .left where view.focus == .transcript && view.transcript.selectedItemID != nil:
            if let selectedID = view.transcript.selectedItemID {
                userToggledEntries[selectedID] = true
                committedEntryCache.removeValue(forKey: TimelineNodeID(selectedID))
                refreshView(latestState)
            }
        case .resize:
            break
        case .tick:
            let hasRunningBg = latestState.backgroundTasks.contains(where: { $0.status == .running })
            if isActive || hasRunningBg {
                spinnerIndex = (spinnerIndex + 1) % 10
                view.backgroundSpinnerIndex = spinnerIndex
            }
        case .escape:
            if selectionRect != nil {
                selectionRect = nil
                selectionStart = nil
                frameScheduler.markDirty(.input)
                return
            }
            if overlay != nil {
                overlay = nil
            } else if view.focus == .transcript {
                view.transcript.clearSelection()
                view.setFocus(.composer)
                return
            }
            Task { await store.dispatch(.stopCurrentRun) }
            view.setFocus(.composer)
        default:
            view.setFocus(.composer)
            switch view.composer.handle(event) {
            case .submit:
                let prompt = view.composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prompt.isEmpty else { return }
                view.composer.commitHistory()
                view.composer.clear()
                overlay = nil
                let now = animationClock.now
                animationNow = now
                waitingStartedAt = now
                if prompt.hasPrefix("/") {
                    executeLocalOrApplicationCommand(prompt, store: store)
                } else {
                    enqueue { await store.dispatch(.submitPrompt(prompt)) }
                }
            case .changed, .ignored:
                updateCompletion()
            }
        }
    }

    private func handleCommandPalette(_ event: TUIInputEvent, store: any FrontendRuntime) async {
        guard case let .commandPalette(query, selected) = overlay else { return }
        let candidates = paletteCommands(query: query)
        switch event {
        case .up:
            overlay = .commandPalette(query: query, selected: max(0, selected - 1))
        case .down:
            overlay = .commandPalette(query: query, selected: min(max(0, candidates.count - 1), selected + 1))
        case .pageUp:
            overlay = .commandPalette(query: query, selected: max(0, selected - 5))
        case .pageDown:
            overlay = .commandPalette(query: query, selected: min(max(0, candidates.count - 1), selected + 5))
        case .enter:
            guard candidates.indices.contains(selected) else { return }
            overlay = nil
            executeLocalOrApplicationCommand("/\(candidates[selected].name)", store: store)
        case .escape:
            overlay = nil
            view.setFocus(.composer)
        case let .character(character):
            updatePalette(query: query + String(character))
        case let .paste(value):
            updatePalette(query: query + value)
        case .backspace:
            updatePalette(query: String(query.dropLast()))
        case .deleteWordBackward:
            updatePalette(query: String(query.split(separator: " ").dropLast().joined(separator: " ")))
        default:
            break
        }
    }

    private func handleCompletion(_ event: TUIInputEvent, store: any FrontendRuntime) async {
        guard case let .completion(tokenStart, selected) = overlay else { return }
        let input = view.composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstToken = input.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? input.lowercased()

        // 1. 如果用户敲了 Enter，且首个 token 已经构成已知命令，直接提交整条命令
        if event == .enter, tokenStart == 0, allCommands.contains(where: {
            (["/" + $0.name] + $0.aliases.map { "/" + $0 }).contains(firstToken)
        }) {
            view.composer.commitHistory()
            view.composer.clear()
            overlay = nil
            view.setFocus(.composer)
            executeLocalOrApplicationCommand(input, store: store)
            return
        }

        switch event {
        case .up, .down, .pageUp, .pageDown:
            completionView.handle(event)
        case .enter:
            if let item = completionView.selectedItem {
                let target = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if item.value.hasSuffix(" ") {
                    let end = view.composer.cursor
                    view.composer.replaceRange(start: tokenStart, end: end, with: item.value)
                    view.setFocus(.composer)
                    updateCompletion()
                } else {
                    view.composer.commitHistory()
                    view.composer.clear()
                    overlay = nil
                    view.setFocus(.composer)
                    executeLocalOrApplicationCommand(target, store: store)
                }
            } else {
                overlay = nil
                view.setFocus(.composer)
            }
        case .tab:
            if let item = completionView.selectedItem {
                let end = view.composer.cursor
                view.composer.replaceRange(start: tokenStart, end: end, with: item.value)
                view.setFocus(.composer)
                if item.value.hasSuffix(" ") {
                    updateCompletion()
                } else {
                    overlay = nil
                }
            } else {
                overlay = nil
                view.setFocus(.composer)
            }
        case .escape:
            overlay = nil
            view.setFocus(.composer)
        default:
            _ = view.composer.handle(event)
            updateCompletion()
        }
        if case .completion = overlay, completionView.selectedIndex != selected {
            overlay = .completion(tokenStart: tokenStart, selected: completionView.selectedIndex)
        }
    }


    // MARK: - Model Picker & Variant Modal

    private struct ModelOptionItem: Equatable {
        let modelID: String
        let displayName: String
        let providerID: String
        let group: String
        let isFree: Bool
    }

    private func openModelPicker() {
        overlay = .modelPicker(query: "", selected: 0)
        if let store = self.store, latestState.models.isEmpty {
            enqueue { await store.dispatch(.listModels) }
        }
    }

    private func modelOptions(query: String) -> [ModelOptionItem] {
        var base: [ModelOptionItem] = []
        let currentID = latestState.currentModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let catalog = latestState.models

        // 1. Recent / Active 分组（当前使用的活动模型排首位，仅在当前模型非空时追加）
        if !currentID.isEmpty {
            let activeDisplayName: String
            let activeProviderID: String
            if let match = catalog.first(where: { $0.id == currentID || $0.modelID == currentID }) {
                activeDisplayName = match.displayName.isEmpty ? match.modelID : match.displayName
                activeProviderID = match.providerID
            } else {
                activeDisplayName = currentID.contains("/") ? String(currentID.split(separator: "/").last ?? "") : currentID
                activeProviderID = currentID.contains("/") ? String(currentID.split(separator: "/").first ?? "Active") : "Active"
            }

            base.append(ModelOptionItem(
                modelID: currentID,
                displayName: activeDisplayName,
                providerID: activeProviderID,
                group: "Recent",
                isFree: false
            ))
        }

        // Grouping uses whatever display name the registry publishes for the
        // product. No product is special-cased here, so a product added to the
        // registry groups correctly without a client change.
        func groupInfo(for providerID: String, configured: Bool) -> (groupName: String, orderPriority: Int) {
            let displayName = latestState.providers
                .first(where: { $0.id == providerID || $0.productID == providerID })?
                .displayName ?? providerID
            return configured ? (displayName, 1) : ("\(displayName) (Built-in)", 3)
        }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var otherItems: [(item: ModelOptionItem, priority: Int)] = []
        var seenDisplayKeys = Set<String>()

        for m in catalog {
            // 跳过当前活动模型，避免在 Recent 之外重复展示
            if m.id == currentID || m.modelID == currentID { continue }

            // 未输入 query 时，过滤内部 watermark 影子镜像
            if m.modelID.contains("-wm") && !q.contains("wm") {
                continue
            }

            // 未输入 query 时，绝不展示未配置的内置提供商模型
            if q.isEmpty && !m.configured {
                continue
            }

            let (gName, priority) = groupInfo(for: m.providerID, configured: m.configured)
            let isFree = m.modelID.contains("flash") || m.modelID.contains("free") || m.displayName.lowercased().contains("free")

            // 智能消歧：若 displayName 相同，按 modelID 补充变体标签，防止视觉重复
            var cleanDisplayName = m.displayName.isEmpty ? m.modelID : m.displayName
            let lowerModelID = m.modelID.lowercased()
            let lowerDisplay = cleanDisplayName.lowercased()
            if lowerModelID.contains("instant") && !lowerDisplay.contains("instant") {
                cleanDisplayName += " Instant"
            } else if (lowerModelID.contains("thinking") || lowerModelID.contains("-t-mini")) && !lowerDisplay.contains("thinking") {
                if lowerModelID.contains("mini") && !lowerDisplay.contains("mini") {
                    cleanDisplayName += " Thinking Mini"
                } else {
                    cleanDisplayName += " Thinking"
                }
            } else if lowerModelID.contains("mini") && !lowerDisplay.contains("mini") {
                cleanDisplayName += " Mini"
            }

            // 避免同 provider 下完全相同的 displayName 重复
            let dedupeKey = "\(m.providerID)::\(cleanDisplayName)"
            if seenDisplayKeys.contains(dedupeKey) {
                cleanDisplayName = "\(cleanDisplayName) (\(m.modelID))"
            }
            seenDisplayKeys.insert("\(m.providerID)::\(cleanDisplayName)")

            let item = ModelOptionItem(
                modelID: m.id,
                displayName: cleanDisplayName,
                providerID: m.providerID,
                group: gName,
                isFree: isFree
            )
            otherItems.append((item, priority))
        }

        // 严格按分组优先级、分组名称、模型名称排序，确保同组聚合在一起，避免标题反复跳跃
        otherItems.sort { a, b in
            if a.priority != b.priority {
                return a.priority < b.priority
            }
            if a.item.group != b.item.group {
                return a.item.group < b.item.group
            }
            return a.item.displayName < b.item.displayName
        }

        base.append(contentsOf: otherItems.map(\.item))

        if q.isEmpty { return base }
        return base.filter {
            $0.modelID.lowercased().contains(q) ||
            $0.displayName.lowercased().contains(q) ||
            $0.providerID.lowercased().contains(q) ||
            $0.group.lowercased().contains(q)
        }
    }

    private func handleModelPicker(_ event: TUIInputEvent, store: any FrontendRuntime) async {
        guard case let .modelPicker(query, selected) = overlay else { return }
        let items = modelOptions(query: query)
        switch event {
        case .up, .scrollUp:
            overlay = .modelPicker(query: query, selected: max(0, selected - 1))
        case .down, .scrollDown:
            overlay = .modelPicker(query: query, selected: min(max(0, items.count - 1), selected + 1))
        case .pageUp:
            overlay = .modelPicker(query: query, selected: max(0, selected - 5))
        case .pageDown:
            overlay = .modelPicker(query: query, selected: min(max(0, items.count - 1), selected + 5))
        case .escape:
            overlay = nil
        case .backspace:
            var newQuery = query
            _ = newQuery.popLast()
            overlay = .modelPicker(query: newQuery, selected: 0)
        case let .character(c):
            let newQuery = query + String(c)
            overlay = .modelPicker(query: newQuery, selected: 0)
        case .enter:
            guard items.indices.contains(selected) else { return }
            let chosen = items[selected]
            let variants = ["Default", "low", "high", "max"]
            overlay = .variantPicker(modelID: chosen.modelID, query: "", selected: 0, variants: variants)
        default:
            break
        }
    }

    private func handleVariantPicker(_ event: TUIInputEvent, store: any FrontendRuntime) async {
        guard case let .variantPicker(modelID, query, selected, variants) = overlay else { return }
        let q = query.lowercased()
        let filtered = query.isEmpty ? variants : variants.filter { $0.lowercased().contains(q) }
        switch event {
        case .up, .scrollUp:
            overlay = .variantPicker(modelID: modelID, query: query, selected: max(0, selected - 1), variants: variants)
        case .down, .scrollDown:
            overlay = .variantPicker(modelID: modelID, query: query, selected: min(max(0, filtered.count - 1), selected + 1), variants: variants)
        case .escape:
            overlay = .modelPicker(query: "", selected: 0)
        case .backspace:
            var newQuery = query
            _ = newQuery.popLast()
            overlay = .variantPicker(modelID: modelID, query: newQuery, selected: 0, variants: variants)
        case let .character(c):
            let newQuery = query + String(c)
            overlay = .variantPicker(modelID: modelID, query: newQuery, selected: 0, variants: variants)
        case .enter:
            guard filtered.indices.contains(selected) else { return }
            let chosenVariant = filtered[selected]
            let effort: ReasoningEffort = switch chosenVariant.lowercased() {
            case "default", "auto": .auto
            case "low": .low
            case "high": .high
            case "max": .max
            case "off": .off
            default: .auto
            }
            overlay = nil
            await store.dispatch(.selectModel(modelID))
            await store.dispatch(.setReasoningEffort(effort))
            if latestState.currentModelID == modelID {
                UserPreferencesStore.shared.update(modelID: modelID, reasoningEffort: effort.rawValue)
                commandEntries.append(TUITranscriptEntry(kind: .result, text: "✓ 已选择模型: \(modelID) · 思考等级: \(effort.rawValue)"))
            }
            refreshView(latestState)
        default:
            break
        }
    }

    // MARK: - Theme Picker Modal (/theme)

    private func openThemePicker() {
        let currentID = ThemeManager.shared.currentTheme.id
        let allThemes = ThemeManager.shared.availableThemes
        let initialSelected = allThemes.firstIndex(where: { $0.id == currentID }) ?? 0
        overlay = .themePicker(query: "", selected: initialSelected)
    }

    private func handleThemePicker(_ event: TUIInputEvent, store: any FrontendRuntime) async {
        guard case let .themePicker(query, selected) = overlay else { return }
        let allThemes = ThemeManager.shared.availableThemes
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredThemes = q.isEmpty ? allThemes : allThemes.filter {
            $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
        let safeSelected = filteredThemes.isEmpty ? 0 : max(0, min(filteredThemes.count - 1, selected))

        switch event {
        case .up, .scrollUp:
            overlay = .themePicker(query: query, selected: max(0, safeSelected - 1))
            refreshView(latestState)
        case .down, .scrollDown:
            overlay = .themePicker(query: query, selected: min(max(0, filteredThemes.count - 1), safeSelected + 1))
            refreshView(latestState)
        case .pageUp:
            overlay = .themePicker(query: query, selected: max(0, safeSelected - 5))
            refreshView(latestState)
        case .pageDown:
            overlay = .themePicker(query: query, selected: min(max(0, filteredThemes.count - 1), safeSelected + 5))
            refreshView(latestState)
        case .escape:
            overlay = nil
            refreshView(latestState)
        case .backspace:
            var newQuery = query
            _ = newQuery.popLast()
            overlay = .themePicker(query: newQuery, selected: 0)
            refreshView(latestState)
        case let .character(c):
            let newQuery = query + String(c)
            overlay = .themePicker(query: newQuery, selected: 0)
            refreshView(latestState)
        case .enter:
            guard filteredThemes.indices.contains(safeSelected) else { return }
            let chosen = filteredThemes[safeSelected]
            _ = ThemeManager.shared.setTheme(by: chosen.id)
            committedEntryCache.removeAll()
            commandEntries.append(TUITranscriptEntry(kind: .result, text: "🎨 Theme switched to '\(chosen.name)' (\(chosen.appearance.rawValue))", style: .systemNotice))
            overlay = nil
            refreshView(latestState)
        default:
            break
        }
    }

    // MARK: - Mode Picker (/mode)

    private struct TUIModeOption {
        let mode: AgentMode
        let icon: String
        let title: String
        let description: String
    }

    private var availableModeOptions: [TUIModeOption] {
        [
            TUIModeOption(
                mode: .build,
                icon: "🔨",
                title: "Build (构建模式)",
                description: "全能模式 · 允许代码编写、文件修改、运行终端与执行工具（默认）"
            ),
            TUIModeOption(
                mode: .plan,
                icon: "📐",
                title: "Plan (规划模式)",
                description: "只读模式 · 分析环境、设计架构方案与实施计划，不直接修改代码"
            ),
            TUIModeOption(
                mode: .explore,
                icon: "🔍",
                title: "Explore (探索模式)",
                description: "分析模式 · 专注代码库检索、符号定义与知识图谱探查，快速调研"
            )
        ]
    }

    private func openModePicker() {
        let currentMode = latestState.nextTurnMode ?? latestState.activeSessionState?.mode ?? .build
        let idx = availableModeOptions.firstIndex(where: { $0.mode == currentMode }) ?? 0
        overlay = .modePicker(selected: idx)
        refreshView(latestState)
    }

    private func handleModePicker(_ event: TUIInputEvent) async {
        guard case let .modePicker(selected) = overlay else { return }
        let options = availableModeOptions
        let safeSelected = options.isEmpty ? 0 : max(0, min(options.count - 1, selected))

        switch event {
        case .up, .scrollUp:
            overlay = .modePicker(selected: max(0, safeSelected - 1))
            refreshView(latestState)
        case .down, .scrollDown:
            overlay = .modePicker(selected: min(max(0, options.count - 1), safeSelected + 1))
            refreshView(latestState)
        case .escape:
            overlay = nil
            view.setFocus(.composer)
            refreshView(latestState)
        case .enter:
            guard options.indices.contains(safeSelected) else { return }
            let chosen = options[safeSelected]
            overlay = nil
            view.setFocus(.composer)
            if let store = store {
                await store.dispatch(.setMode(chosen.mode))
                commandEntries.append(TUITranscriptEntry(
                    kind: .result,
                    text: "✓ Agent 模式已切换为: \(chosen.title)",
                    style: .systemNotice
                ))
                let fresh = await store.state
                refreshView(fresh)
            } else {
                refreshView(latestState)
            }
        default:
            break
        }
    }

    // MARK: - Permissions Picker (/permissions)

    private struct TUIPermissionOption {
        let config: PermissionConfiguration
        let key: String
        let icon: String
        let title: String
        let description: String
    }

    private var availablePermissionOptions: [TUIPermissionOption] {
        [
            TUIPermissionOption(
                config: .askWorkspace,
                key: "ask",
                icon: "🛡️",
                title: "Ask (逐次询问)",
                description: "最高安全 · 工具执行与敏感操作均弹窗确认（默认推荐）"
            ),
            TUIPermissionOption(
                config: .autoWorkspace,
                key: "auto",
                icon: "⚡",
                title: "Auto (工作区沙箱)",
                description: "平衡实用 · 工作区内读写与安全命令自动放行，跨目录或高危需确认"
            ),
            TUIPermissionOption(
                config: .yoloFullAccess,
                key: "yolo",
                icon: "🚀",
                title: "YOLO (自由执行)",
                description: "完全自动化 · 跳过所有审批与安全中断，适合全自动流水线无感执行"
            )
        ]
    }

    private func openPermissionsPicker() {
        let currentProfile = latestState.nextTurnPermission?.profile.rawValue
            ?? latestState.activeSessionState?.permissionConfiguration.profile.rawValue
            ?? "ask"
        let idx = availablePermissionOptions.firstIndex(where: { $0.key == currentProfile }) ?? 0
        overlay = .permissionsPicker(selected: idx)
        refreshView(latestState)
    }

    private func handlePermissionsPicker(_ event: TUIInputEvent) async {
        guard case let .permissionsPicker(selected) = overlay else { return }
        let options = availablePermissionOptions
        let safeSelected = options.isEmpty ? 0 : max(0, min(options.count - 1, selected))

        switch event {
        case .up, .scrollUp:
            overlay = .permissionsPicker(selected: max(0, safeSelected - 1))
            refreshView(latestState)
        case .down, .scrollDown:
            overlay = .permissionsPicker(selected: min(max(0, options.count - 1), safeSelected + 1))
            refreshView(latestState)
        case .escape:
            overlay = nil
            view.setFocus(.composer)
            refreshView(latestState)
        case .enter:
            guard options.indices.contains(safeSelected) else { return }
            let chosen = options[safeSelected]
            overlay = nil
            view.setFocus(.composer)
            if let store = store {
                await store.dispatch(.setPermissionConfiguration(chosen.config))
                commandEntries.append(TUITranscriptEntry(
                    kind: .result,
                    text: "✓ 权限策略已更新为: \(chosen.title)",
                    style: .systemNotice
                ))
                let fresh = await store.state
                refreshView(fresh)
            } else {
                refreshView(latestState)
            }
        default:
            break
        }
    }

    // MARK: - Reasoning Picker (/reasoning)

    private struct TUIReasoningOption {
        let effort: ReasoningEffort
        let icon: String
        let title: String
        let description: String
    }

    private var availableReasoningOptions: [TUIReasoningOption] {
        [
            TUIReasoningOption(
                effort: .auto,
                icon: "✨",
                title: "Auto (自适应推荐)",
                description: "根据当前模型能力和输入复杂度自适应启用最合适的思考等级"
            ),
            TUIReasoningOption(
                effort: .off,
                icon: "⭕",
                title: "Off (关闭思考)",
                description: "完全关闭思维链 (Thought) 生成，获得最快首字响应速度"
            ),
            TUIReasoningOption(
                effort: .low,
                icon: "🌱",
                title: "Low (轻度思考)",
                description: "轻微思考，分配较少 Thought Token，适合简单问答与快速任务"
            ),
            TUIReasoningOption(
                effort: .medium,
                icon: "🌿",
                title: "Medium (适度思考)",
                description: "适度思考预算，平衡推理深度与响应时间"
            ),
            TUIReasoningOption(
                effort: .high,
                icon: "🧠",
                title: "High (深度思考)",
                description: "深度思考预算，适合复杂算法推导、架构重构与跨文件审查"
            ),
            TUIReasoningOption(
                effort: .max,
                icon: "🔥",
                title: "Max (极限思考)",
                description: "顶格思考预算，开启最强推理深度与反思链"
            )
        ]
    }

    private func openReasoningPicker() {
        let currentEffort = latestState.effectiveReasoningEffort
        let idx = availableReasoningOptions.firstIndex(where: { $0.effort == currentEffort }) ?? 0
        overlay = .reasoningPicker(selected: idx)
        refreshView(latestState)
    }

    private func handleReasoningPicker(_ event: TUIInputEvent) async {
        guard case let .reasoningPicker(selected) = overlay else { return }
        let options = availableReasoningOptions
        let safeSelected = options.isEmpty ? 0 : max(0, min(options.count - 1, selected))

        switch event {
        case .up, .scrollUp:
            overlay = .reasoningPicker(selected: max(0, safeSelected - 1))
            refreshView(latestState)
        case .down, .scrollDown:
            overlay = .reasoningPicker(selected: min(max(0, options.count - 1), safeSelected + 1))
            refreshView(latestState)
        case .escape:
            overlay = nil
            view.setFocus(.composer)
            refreshView(latestState)
        case .enter:
            guard options.indices.contains(safeSelected) else { return }
            let chosen = options[safeSelected]
            overlay = nil
            view.setFocus(.composer)
            if let store = store {
                await store.dispatch(.setReasoningEffort(chosen.effort))
                commandEntries.append(TUITranscriptEntry(
                    kind: .result,
                    text: "✓ 思考等级已切换为: \(chosen.title)",
                    style: .systemNotice
                ))
                let fresh = await store.state
                refreshView(fresh)
            } else {
                refreshView(latestState)
            }
        default:
            break
        }
    }

    // MARK: - Session Picker Modal (/resume)

    private func openSessionPicker() {
        overlay = .sessionPicker(query: "", selected: 0)
    }

    private func sessionOptions(query: String) -> [SessionSummary] {
        SessionCatalog.timeGroups(latestState.sessionCatalog, query: query).flatMap(\.sessions)
    }

    private var currentDirectory: String {
        latestState.currentWorkspace?.rootPath ?? FileManager.default.currentDirectoryPath
    }

    private func handleSessionPicker(_ event: TUIInputEvent, store: any FrontendRuntime) async {
        guard case let .sessionPicker(query, selected) = overlay else { return }
        let items = sessionOptions(query: query)
        switch event {
        case .up, .scrollUp:
            overlay = .sessionPicker(query: query, selected: max(0, selected - 1))
        case .down, .scrollDown:
            overlay = .sessionPicker(query: query, selected: min(max(0, items.count - 1), selected + 1))
        case .pageUp:
            overlay = .sessionPicker(query: query, selected: max(0, selected - 5))
        case .pageDown:
            overlay = .sessionPicker(query: query, selected: min(max(0, items.count - 1), selected + 5))
        case .escape:
            overlay = nil
            view.setFocus(.composer)
        case .backspace:
            var newQuery = query
            _ = newQuery.popLast()
            overlay = .sessionPicker(query: newQuery, selected: 0)
        case let .character(c):
            let newQuery = query + String(c)
            overlay = .sessionPicker(query: newQuery, selected: 0)
        case .enter:
            guard items.indices.contains(selected) else { return }
            let chosen = items[selected]
            overlay = nil
            view.setFocus(.composer)
            commandEntries.append(TUITranscriptEntry(kind: .result, text: "✓ 已恢复会话: \(chosen.title ?? chosen.sessionID.rawValue)"))
            enqueue {
                await store.dispatch(.switchSession(chosen.sessionID))
            }
        default:
            break
        }
    }

    // MARK: - Config Modal (/config)

    private func openConfigModal() {
        overlay = .configModal(selected: 0)
    }

    private struct TUIConfigItem {
        let key: String
        let title: String
        let description: String
        let isOn: Bool
    }

    private func currentConfigItems() -> [TUIConfigItem] {
        let prefs = UserPreferencesStore.shared.load()
        return [
            TUIConfigItem(
                key: "thinking",
                title: "思考过程默认展开",
                description: "开启后模型思考过程自动展开显示，折叠时仅保留概要标签",
                isOn: prefs.expandThinking ?? false
            ),
            TUIConfigItem(
                key: "tools",
                title: "工具调用详情展开",
                description: "开启后工具调用入参和输出自动展开，折叠时以紧凑胶囊显示",
                isOn: prefs.expandTools ?? false
            ),
            TUIConfigItem(
                key: "sidebar",
                title: "监控侧边栏显示",
                description: "开启后屏幕右侧显示活动状态、MCP 服务与任务监控面板",
                isOn: prefs.showSidebar ?? true
            )
        ]
    }

    private func handleConfigModal(_ event: TUIInputEvent) async {
        guard case let .configModal(selected) = overlay else { return }
        let items = currentConfigItems()
        switch event {
        case .up, .scrollUp:
            overlay = .configModal(selected: max(0, selected - 1))
        case .down, .scrollDown:
            overlay = .configModal(selected: min(max(0, items.count - 1), selected + 1))
        case .escape:
            overlay = nil
            view.setFocus(.composer)
        case .enter, .left, .right, .character(" "):
            guard items.indices.contains(selected) else { return }
            let item = items[selected]
            let newStatus = !item.isOn
            switch item.key {
            case "thinking":
                UserPreferencesStore.shared.update(expandThinking: newStatus)
                committedEntryCache.removeAll(keepingCapacity: true)
            case "tools":
                UserPreferencesStore.shared.update(expandTools: newStatus)
                committedEntryCache.removeAll(keepingCapacity: true)
            case "sidebar":
                UserPreferencesStore.shared.update(showSidebar: newStatus)
            default:
                break
            }
            refreshView(latestState)
            overlay = .configModal(selected: selected)
        default:
            break
        }
    }

    // MARK: - Tasks Modal (/tasks)

    private func openTasksModal(store: any FrontendRuntime) async {
        let tasks = (try? await store.getBackgroundTasks()) ?? []
        overlay = .tasksModal(selected: 0, tasks: tasks, expandedDetail: false)
        refreshView(latestState)
    }

    private func handleTasksModal(_ event: TUIInputEvent, store: any FrontendRuntime) async {
        guard case let .tasksModal(selected, tasks, expandedDetail) = overlay else { return }
        switch event {
        case .up, .scrollUp:
            overlay = .tasksModal(selected: max(0, selected - 1), tasks: tasks, expandedDetail: expandedDetail)
            refreshView(latestState)
        case .down, .scrollDown:
            overlay = .tasksModal(selected: min(max(0, tasks.count - 1), selected + 1), tasks: tasks, expandedDetail: expandedDetail)
            refreshView(latestState)
        case .escape:
            overlay = nil
            view.setFocus(.composer)
            refreshView(latestState)
        case .enter, .character(" "):
            overlay = .tasksModal(selected: selected, tasks: tasks, expandedDetail: !expandedDetail)
            refreshView(latestState)
        case .character("k"), .character("K"), .character("x"), .character("X"):
            guard tasks.indices.contains(selected) else { return }
            let task = tasks[selected]
            if task.status == .running {
                _ = try? await store.terminateBackgroundTask(id: task.id)
            }
            let freshTasks = (try? await store.getBackgroundTasks()) ?? []
            overlay = .tasksModal(
                selected: min(selected, max(0, freshTasks.count - 1)),
                tasks: freshTasks,
                expandedDetail: expandedDetail
            )
            refreshView(latestState)
        case .character("r"), .character("R"):
            let freshTasks = (try? await store.getBackgroundTasks()) ?? []
            overlay = .tasksModal(
                selected: min(selected, max(0, freshTasks.count - 1)),
                tasks: freshTasks,
                expandedDetail: expandedDetail
            )
            refreshView(latestState)
        default:
            break
        }
    }

    // MARK: - Command Modal (/plugins & Plugin Commands)

    private func openCommandModal(title: String, content: String) {
        overlay = .commandModal(title: title, content: content, scrollOffset: 0)
        refreshView(latestState)
        frameScheduler.markDirty(.content)
    }

    private func handleCommandModal(_ event: TUIInputEvent) async {
        guard case let .commandModal(title, content, scrollOffset) = overlay else { return }
        let totalLines = content.components(separatedBy: .newlines).count
        let viewportHeight = max(6, min(18, terminal.size.height - 10))
        let maxScroll = max(0, totalLines - viewportHeight)

        switch event {
        case .up, .scrollUp, .character("k"), .character("K"):
            let nextOffset = max(0, scrollOffset - 1)
            overlay = .commandModal(title: title, content: content, scrollOffset: nextOffset)
            refreshView(latestState)
            frameScheduler.markDirty(.input)
        case .down, .scrollDown, .character("j"), .character("J"):
            let nextOffset = min(maxScroll, scrollOffset + 1)
            overlay = .commandModal(title: title, content: content, scrollOffset: nextOffset)
            refreshView(latestState)
            frameScheduler.markDirty(.input)
        case .pageUp:
            let nextOffset = max(0, scrollOffset - 5)
            overlay = .commandModal(title: title, content: content, scrollOffset: nextOffset)
            refreshView(latestState)
            frameScheduler.markDirty(.input)
        case .pageDown:
            let nextOffset = min(maxScroll, scrollOffset + 5)
            overlay = .commandModal(title: title, content: content, scrollOffset: nextOffset)
            refreshView(latestState)
            frameScheduler.markDirty(.input)
        case .escape, .enter, .character("q"), .character("Q"):
            overlay = nil
            view.setFocus(.composer)
            refreshView(latestState)
            frameScheduler.markDirty(.input)
        default:
            break
        }
    }

    private func handleInteraction(_ event: TUIInputEvent, store: any FrontendRuntime) async {
        guard let interaction = latestState.activeInteraction else { return }
        switch event {
        case .up where interaction.questionRequest != nil || interaction.decisionRequest != nil:
            hitlSelectedOption = max(0, hitlSelectedOption - 1)
        case .down where interaction.questionRequest != nil || interaction.decisionRequest != nil:
            let count = interaction.questionRequest?.options.count ?? interaction.decisionRequest?.options.count ?? 1
            hitlSelectedOption = min(max(0, count - 1), hitlSelectedOption + 1)
        case .escape:
            cancelInteraction(interaction, store: store)
        case let .character(character) where interaction.kind == .permission:
            let pending = latestState.activeSessionState?.pendingInteractions.filter { $0.kind == .permission } ?? []
            switch character.lowercased() {
            case "y":
                enqueue {
                    for p in pending {
                        await store.dispatch(.grantPermission(interactionID: p.interactionID, decision: .allow))
                    }
                    if pending.isEmpty {
                        await store.dispatch(.grantPermission(interactionID: interaction.interactionID, decision: .allow))
                    }
                }
            case "n":
                enqueue {
                    for p in pending {
                        await store.dispatch(.grantPermission(interactionID: p.interactionID, decision: .deny))
                    }
                    if pending.isEmpty {
                        await store.dispatch(.grantPermission(interactionID: interaction.interactionID, decision: .deny))
                    }
                }
            default: break
            }
        case .enter where interaction.kind == .permission,
             .right where interaction.kind == .permission:
            let pending = latestState.activeSessionState?.pendingInteractions.filter { $0.kind == .permission } ?? []
            enqueue {
                for p in pending {
                    await store.dispatch(.grantPermission(interactionID: p.interactionID, decision: .allow))
                }
                if pending.isEmpty {
                    await store.dispatch(.grantPermission(interactionID: interaction.interactionID, decision: .allow))
                }
            }
        case .left where interaction.kind == .permission:
            let pending = latestState.activeSessionState?.pendingInteractions.filter { $0.kind == .permission } ?? []
            enqueue {
                for p in pending {
                    await store.dispatch(.grantPermission(interactionID: p.interactionID, decision: .deny))
                }
                if pending.isEmpty {
                    await store.dispatch(.grantPermission(interactionID: interaction.interactionID, decision: .deny))
                }
            }
        case let .character(character) where interaction.kind == .question:
            _ = view.composer.handle(.character(character))
        case let .character(character) where interaction.kind == .decision:
            _ = view.composer.handle(.character(character))
        case .backspace, .delete, .left, .right, .home, .end, .shiftEnter, .paste:
            _ = view.composer.handle(event)
        case .enter:
            let text = view.composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let request = interaction.questionRequest {
                let typedIndices = optionIndices(text, options: request.options)
                let selected = typedIndices.isEmpty && !request.options.isEmpty && text.isEmpty ? [hitlSelectedOption] : typedIndices
                let indices = request.allowsMultiple ? selected : Array(selected.prefix(1))
                let reply = QuestionReply(questionID: request.questionID, selectedOptionIndices: indices, text: indices.isEmpty ? (text.isEmpty ? nil : text) : nil)
                enqueue { await store.dispatch(.replyQuestion(interactionID: interaction.interactionID, reply: reply)) }
                hitlSelectedOption = 0
            } else if interaction.decisionRequest != nil {
                let request = interaction.decisionRequest
                let decision = text.isEmpty ? safeElement(request?.options ?? [], at: hitlSelectedOption) ?? "cancelled" : text
                enqueue { await store.dispatch(.submitDecision(interactionID: interaction.interactionID, decision: decision)) }
            }
            view.composer.clear()
        default:
            break
        }
    }

    private func cancelInteraction(_ interaction: InteractionSnapshot, store: any FrontendRuntime) {
        switch interaction.kind {
        case .permission:
            enqueue { await store.dispatch(.grantPermission(interactionID: interaction.interactionID, decision: .deny)) }
        case .question:
            guard let request = interaction.questionRequest else { return }
            enqueue { await store.dispatch(.replyQuestion(
                interactionID: interaction.interactionID,
                reply: QuestionReply(questionID: request.questionID, cancelled: true)
            )) }
        case .decision:
            enqueue { await store.dispatch(.respondInteraction(interactionID: interaction.interactionID, resolution: .unknown("cancelled"))) }
        case .unknown:
            enqueue { await store.dispatch(.respondInteraction(interactionID: interaction.interactionID, resolution: .unknown("cancelled"))) }
        }
        view.composer.clear()
    }

    private func executeCommand(_ input: String, store: any FrontendRuntime) async -> TUITranscriptEntry? {
        do {
            let result = try await store.executeCommand(input)
            if let reverted = result.revertedComposerText {
                view.composer.setText(reverted)
                let now = animationClock.now
                animationNow = now
                waitingStartedAt = nil
                activityStartedAt.removeAll(keepingCapacity: true)
                activityFinishedDuration.removeAll(keepingCapacity: true)
                committedEntryCache.removeAll(keepingCapacity: true)
                userToggledEntries.removeAll(keepingCapacity: true)
                let fresh = await store.state
                refreshView(fresh)
            }
            if result.presentation == .modal {
                await MainActor.run {
                    self.openCommandModal(
                        title: result.modalTitle ?? "命令输出",
                        content: result.output
                    )
                }
                return nil
            }
            guard !result.output.isEmpty else { return nil }
            return TUITranscriptEntry(kind: .result, text: result.output, style: .systemNotice)
        } catch {
            return TUITranscriptEntry(kind: .error, text: String(describing: error), style: .error)
        }
    }

    private func executeLocalOrApplicationCommand(_ input: String, store: any FrontendRuntime) {
        let command = input.split(whereSeparator: \ .isWhitespace).first.map(String.init)?.lowercased()
        switch command {
        case "/quit":
            shouldQuit = true
        case "/theme", "/themes":
            let parts = input.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count == 1 || (parts.count >= 2 && parts[1] == "list") {
                openThemePicker()
                refreshView(latestState)
                return
            }
            let targetQuery = parts[1...].joined(separator: " ")
            if ThemeManager.shared.setTheme(by: targetQuery) {
                let newTheme = ThemeManager.shared.currentTheme
                committedEntryCache.removeAll()
                commandEntries.append(TUITranscriptEntry(kind: .result, text: "🎨 Theme switched to '\(newTheme.name)' (\(newTheme.appearance.rawValue))", style: .systemNotice))
                refreshView(latestState)
            } else {
                commandEntries.append(TUITranscriptEntry(kind: .error, text: "Theme '\(targetQuery)' not found. Type /theme to select from list.", style: .error))
                refreshView(latestState)
            }
            return
        case "/keybindings", "/keys", "/shortcuts":
            var helpText = "⌨️ Active Keybindings & Shortcuts:\n"
            let rules = KeybindingRegistry.shared.allRules()
            let grouped = Dictionary(grouping: rules, by: { $0.context.rawValue.capitalized })
            for (ctx, items) in grouped.sorted(by: { $0.key < $1.key }) {
                helpText += "\n[\(ctx)]\n"
                for item in items {
                    helpText += "  \(item.stroke.description.padding(toLength: 16, withPad: " ", startingAt: 0)) -> \(item.action.displayName)\n"
                }
            }
            helpText += "\nConfiguration: Edit ~/.lingxiagent/keybindings.json to customize bindings."
            openCommandModal(title: "⌨️ 快捷键速查 (Keybindings & Shortcuts)", content: helpText)
            return
        case "/clear":
            commandEntries.removeAll()
            view.transcript.entries.removeAll()
            view.transcript.clearSelection()
            view.setFocus(.composer)
            refreshView(latestState)
        case "/expand":
            let nodes = latestState.activeSessionState?.timelineNodes ?? []
            for node in nodes {
                userToggledEntries[node.id.rawValue] = false
            }
            committedEntryCache.removeAll(keepingCapacity: true)
            refreshView(latestState)
        case "/collapse":
            let nodes = latestState.activeSessionState?.timelineNodes ?? []
            for node in nodes {
                userToggledEntries[node.id.rawValue] = true
            }
            committedEntryCache.removeAll(keepingCapacity: true)
            refreshView(latestState)
        case "/help":
            let localNames = Self.localCommands.map { "• /\($0.name) - \($0.description)" }.joined(separator: "\n  ")
            let names = commands.map { "• /\($0.name) - \($0.description)" }.joined(separator: "\n  ")
            let helpContent = """
            【本地快捷交互指令】
              \(localNames)

            【已就绪业务核心指令】
              \(names)

            💡 交互提示:
              • 输入 '/' 可呼出交互式指令补全与搜索调色板
              • /mode、/permissions、/reasoning、/theme 均支持弹出快捷浮层直选
              • 按 Esc 键可随时退出当前模态浮层
            """
            openCommandModal(title: "📖 帮助中心与命令指南 (/help)", content: helpContent)
            return
        case "/new":
            commandEntries.removeAll()
            committedEntryCache.removeAll()
            userToggledEntries.removeAll()
            view.transcript.entries.removeAll()
            view.transcript.clearSelection()
            view.setFocus(.composer)
            view.composer.clear()
            enqueue { [weak self] in
                guard let self else { return }
                if let entry = await self.executeCommand(input, store: store) {
                    await self.publishCommandResult(entry)
                }
            }
        case "/undo", "/rewind":
            enqueue { [weak self] in
                guard let self else { return }
                await MainActor.run { self.waitingStartedAt = nil }
                await store.dispatch(.stopCurrentRun)
                if let entry = await self.executeCommand(input, store: store) {
                    await self.publishCommandResult(entry)
                }
                let fresh = await store.state
                await MainActor.run {
                    self.waitingStartedAt = nil
                    self.refreshView(fresh)
                }
            }
        case "/model", "/m":
            let parts = input.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count == 1 {
                openModelPicker()
                enqueue { await store.dispatch(.listModels) }
                return
            }
            fallthrough
        case "/resume":
            let parts = input.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count == 1 {
                openSessionPicker()
                enqueue { await store.dispatch(.listSessions) }
                return
            }
            fallthrough
        case "/config", "/preference", "/set":
            let parts = input.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count == 1 {
                openConfigModal()
                return
            }
            fallthrough
        case "/tasks", "/task", "/bg":
            let parts = input.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count == 1 {
                Task { [weak self] in
                    await self?.openTasksModal(store: store)
                }
                return
            }
            fallthrough
        case "/mode":
            let parts = input.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count == 1 {
                openModePicker()
                return
            }
            fallthrough
        case "/permissions", "/permission":
            let parts = input.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count == 1 {
                openPermissionsPicker()
                return
            }
            fallthrough
        case "/reasoning", "/think", "/thought":
            let parts = input.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count == 1 {
                openReasoningPicker()
                return
            }
            fallthrough
        default:
            enqueue { [weak self] in
                guard let self else { return }
                if let entry = await self.executeCommand(input, store: store) {
                    await self.publishCommandResult(entry)
                }
            }
        }
    }

    private func publishCommandResult(_ entry: TUITranscriptEntry) {
        eventPump?.postCommandResult(entry)
    }

    private func enqueue(_ action: @escaping @Sendable () async -> Void) {
        let previous = actionTail
        actionTail = Task {
            await previous?.value
            await action()
        }
    }

    private func optionIndices(_ text: String, options: [String]) -> [Int] {
        let indices = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { $0 - 1 }
        let valid = indices.filter { options.indices.contains($0) }
        return valid
    }

    private func safeElement<T>(_ array: [T], at index: Int) -> T? {
        array.indices.contains(index) ? array[index] : nil
    }

    private func updateCompletion() {
        let text = view.composer.text
        let cursor = view.composer.cursor
        let characters = Array(text)
        let prefix = String(characters.prefix(cursor))

        if prefix.first == "/" {
            let afterSlash = String(prefix.dropFirst())
            if let firstSpace = afterSlash.firstIndex(where: \.isWhitespace) {
                let commandName = String(afterSlash[..<firstSpace])
                if let lastSpaceIndex = prefix.lastIndex(where: \.isWhitespace) {
                    let tokenStart = prefix.distance(from: prefix.startIndex, to: prefix.index(after: lastSpaceIndex))
                    let subQuery = String(prefix[prefix.index(after: lastSpaceIndex)...])
                    let items = subcommandCandidates(for: commandName, query: subQuery)
                    completionView.update(items: items, query: subQuery, selectedIndex: completionView.selectedIndex)
                    overlay = items.isEmpty ? nil : .completion(tokenStart: tokenStart, selected: completionView.selectedIndex)
                    return
                }
            } else {
                let query = afterSlash
                let items = allCommands.filter { command in
                    query.isEmpty || command.name.localizedCaseInsensitiveContains(query) || command.description.localizedCaseInsensitiveContains(query)
                }.map { command -> TUICompletionItem in
                    let hasSubs = Self.hasSubcommands(command.name)
                    let completionValue = hasSubs ? "/\(command.name) " : "/\(command.name)"
                    let badge: String
                    switch command.category.lowercased() {
                    case "plugin": badge = " · 插件"
                    case "custom": badge = " · 自定义"
                    default: badge = ""
                    }
                    return TUICompletionItem(
                        value: completionValue,
                        label: "/\(command.name)\(badge)",
                        detail: command.description,
                        kind: .command
                    )
                }
                completionView.update(items: items, query: query, selectedIndex: completionView.selectedIndex)
                overlay = items.isEmpty ? nil : .completion(tokenStart: 0, selected: completionView.selectedIndex)
                return

            }
        }

        guard let at = characters[..<min(cursor, characters.count)].lastIndex(of: "@"),
              at == 0 || characters[at - 1].isWhitespace else {
            overlay = nil
            return
        }
        let query = String(characters[(at + 1)..<cursor])
        guard !query.contains(where: \.isWhitespace) else { overlay = nil; return }
        let items = referenceItems(query: query)
        completionView.update(items: items, query: query, selectedIndex: completionView.selectedIndex)
        overlay = items.isEmpty ? nil : .completion(tokenStart: at, selected: completionView.selectedIndex)
    }

    static func hasSubcommands(_ commandName: String) -> Bool {
        let name = commandName.lowercased()
        if ["permissions", "permission", "mode", "connect"].contains(name) {
            return true
        }
        if let cmd = BuiltinCommands.all.first(where: { $0.name.lowercased() == name || $0.aliases.contains(name) }) {
            let schema = cmd.argumentSchema
            return schema.contains("|") && !schema.hasPrefix("[")
        }
        return false
    }

    private func subcommandCandidates(for commandName: String, query: String) -> [TUICompletionItem] {
        let normalizedCommand = commandName.lowercased()
        var rawOptions: [(value: String, label: String, detail: String)] = []

        switch normalizedCommand {
        case "permissions", "permission":
            rawOptions = [
                ("ask", "ask", "只读安全，写操作与执行需询问确认 (Ask/Workspace)"),
                ("auto", "auto", "工作区内文件与执行自动允许 (Auto/Workspace)"),
                ("yolo", "yolo", "完全放开所有权限，全自动执行 (YOLO)")
            ]
        case "mode":
            rawOptions = [
                ("build", "build", "构建模式 (代码修改与测试执行)"),
                ("plan", "plan", "规划模式 (分析与设计方案，只读)"),
                ("explore", "explore", "探索模式 (快速只读调研与检索)")
            ]
        case "connect":
            rawOptions = [
                ("deepseek", "deepseek", "DeepSeek API 模型"),
                ("anthropic", "anthropic", "Anthropic Claude 模型"),
                ("openai", "openai", "OpenAI GPT 模型"),
                ("gemini", "gemini", "Google Gemini 模型"),
                ("ollama", "ollama", "Ollama 本地服务")
            ]
            for p in latestState.providers where !rawOptions.contains(where: { $0.value == p.productID }) {
                rawOptions.append((p.productID, p.productID, p.displayName))
            }
        case "model", "m":
            if !latestState.models.isEmpty {
                rawOptions = latestState.models.map { ($0.id, $0.id, "\($0.displayName) (\($0.providerID))") }
            } else {
                // No models known yet — either no product is connected or
                // discovery has not completed. A canned roster here would offer
                // models this account may not be able to reach at all.
                rawOptions = []
            }
        default:
            if let cmd = allCommands.first(where: { $0.name.lowercased() == normalizedCommand || $0.aliases.contains(normalizedCommand) }),
               !cmd.argumentSchema.isEmpty {
                let schema = cmd.argumentSchema.trimmingCharacters(in: CharacterSet(charactersIn: "[]<>"))
                let parts = schema.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
                if parts.count > 1 {
                    rawOptions = parts.map { ($0, $0, "选项: \($0)") }
                }
            }
        }

        let q = query.lowercased()
        return rawOptions
            .filter { q.isEmpty || $0.value.lowercased().contains(q) || $0.detail.lowercased().contains(q) || $0.label.lowercased().contains(q) }
            .map { TUICompletionItem(value: $0.value, label: $0.label, detail: $0.detail, kind: .command) }
    }

    private func referenceItems(query: String) -> [TUICompletionItem] {
        let normalized = query.lowercased()
        return referenceCandidates
            .filter { normalized.isEmpty || $0.lowercased().contains(normalized) }
            .prefix(12)
            .map { TUICompletionItem(value: "@\($0)", label: "@\($0)", detail: "workspace", kind: .reference) }
    }

    private func paletteCommands(query: String) -> [FrontendCommandItem] {
        allCommands.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query)
        }
    }

    private func updatePalette(query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        overlay = .commandPalette(query: normalized, selected: 0)
    }

    private func refreshSessionIdentityIfNeeded(_ state: ApplicationState) {
        if state.activeSessionID != activeDisplayedSessionID {
            activeDisplayedSessionID = state.activeSessionID
            commandEntries.removeAll()
            committedEntryCache.removeAll(keepingCapacity: true)
            activityStartedAt.removeAll(keepingCapacity: true)
            activityFinishedDuration.removeAll(keepingCapacity: true)
            userToggledEntries.removeAll(keepingCapacity: true)
            lastSidebarRevision = nil
            cachedSidebarModel = nil
            view.transcript.replace([])
            view.transcript.clearSelection()
            view.setFocus(.composer)
        }
    }

    private func refreshInteraction(_ state: ApplicationState) {
        if activeInteractionID != state.activeInteraction?.interactionID {
            activeInteractionID = state.activeInteraction?.interactionID
            hitlSelectedOption = 0
            if state.activeInteraction != nil { view.composer.clear() }
        }
    }

    private func refreshStatus(_ state: ApplicationState) {
        let yoloPrefix = options.isYoloMode ? "⚡ YOLO · " : ""
        view.header.subtitle = "\(yoloPrefix)\(state.activeSessionState?.title ?? state.connectionState.status.rawValue)"
        view.backgroundTasks = state.backgroundTasks
        view.backgroundSpinnerIndex = spinnerIndex
        updateStatusLine(state)
    }

    private func refreshHero(_ state: ApplicationState) -> Bool {
        let isHero = isHeroEmptyState(state)
        let prefs = UserPreferencesStore.shared.load()
        if isHero {
            let mode = state.activeSessionState?.mode.displayName ?? state.nextTurnMode?.displayName ?? "Build"
            let model = state.currentModelID ?? prefs.lastModelID ?? ""
            let provider: String = {
                guard let slashIdx = model.firstIndex(of: "/") else { return "" }
                return String(model[..<slashIdx])
            }()
            let effort = state.nextTurnReasoningEffort?.rawValue ?? prefs.lastReasoningEffort ?? state.effectiveReasoningEffort.rawValue
            let permission = currentPermissionDisplayName(from: state)
            view.heroConfig = TUIHeroConfig(
                modeName: mode,
                modelName: model,
                providerName: provider,
                reasoningEffort: effort,
                tip: "Press ctrl+p to see all available actions and commands",
                permissionName: permission
            )
            view.sidebarModel = nil
            return true
        } else {
            view.heroConfig = nil
            return false
        }
    }

    private func refreshSidebar(_ state: ApplicationState) {
        let prefs = UserPreferencesStore.shared.load()
        guard (prefs.showSidebar ?? true) else {
            view.sidebarModel = nil
            cachedSidebarModel = nil
            lastSidebarRevision = nil
            return
        }

        let session = state.activeSessionState
        let ctx = session?.contextState
        let currentRevision = SidebarRevisionState(
            sessionID: state.activeSessionID,
            sessionTitle: session?.title,
            compactionGeneration: ctx?.compactionGeneration ?? 0,
            cacheEpoch: ctx?.cacheEpoch ?? 0,
            contextActivePCoreTokens: ctx?.activePCoreTokens ?? 0,
            contextECoreTotalBytes: ctx?.eCoreTotalBytes ?? 0,
            contextECoreObjectCount: ctx?.eCoreObjectCount ?? 0,
            contextCacheReadTokens: ctx?.cacheReadTokens ?? 0,
            extensionsCount: state.extensions.count,
            extensionsHash: state.extensions.reduce(0) { $0 ^ $1.id.hashValue ^ $1.enabled.hashValue ^ $1.lifecycleState.hashValue },
            workflowsCount: state.workflows.count,
            backgroundTasksCount: state.backgroundTasks.count,
            failedMCPCount: state.extensions.filter { $0.kind == .mcp && ($0.lifecycleState.lowercased().contains("err") || $0.lifecycleState.lowercased().contains("fail") || $0.lifecycleState.lowercased().contains("unavail")) }.count,
            preferencesShowSidebar: prefs.showSidebar,
            sidebarScrollOffset: sidebarScrollOffset,
            mcpScrollOffset: mcpScrollOffset,
            taskScrollOffset: taskScrollOffset
        )

        if let cached = cachedSidebarModel, lastSidebarRevision == currentRevision {
            view.sidebarModel = cached
            return
        }

        TUIPerformanceMetrics.shared.recordSidebarRebuild()
        let model = buildSidebarModel(from: state)
        cachedSidebarModel = model
        lastSidebarRevision = currentRevision
        view.sidebarModel = model
    }

    private func refreshAnimation(_ state: ApplicationState) {
        updateStatusLine(state)
        if waitingStartedAt != nil {
            refreshWaitingIndicator()
        }
        refreshActiveTimeNodes(state)
    }

    private func refreshActiveTimeNodes(_ state: ApplicationState) {
        guard let session = state.activeSessionState else { return }
        for node in session.timelineNodes {
            switch node.kind {
            case let .thinking(th) where !th.isComplete:
                if let rendered = renderEntry(node, isTerminalAssistant: false) {
                    view.transcript.update(id: node.id.rawValue, text: rendered.text, style: rendered.style)
                }
            case let .tool(tl) where tl.phase == .running:
                if let rendered = renderEntry(node, isTerminalAssistant: false) {
                    view.transcript.update(id: node.id.rawValue, text: rendered.text, style: rendered.style)
                }
            default:
                break
            }
        }
    }

    private func refreshTranscript(_ state: ApplicationState) {
        let transcriptProjStart = ContinuousClock.now
        let session = state.activeSessionState
        let nodes = session?.timelineNodes ?? []

        if (nodes.isEmpty && commandEntries.isEmpty) || view.transcript.entries.isEmpty {
            if view.focus == .transcript {
                view.transcript.clearSelection()
                view.setFocus(.composer)
            }
        }
        if nodes.count < lastRenderedNodeCount {
            committedEntryCache.removeAll(keepingCapacity: true)
            activityStartedAt.removeAll(keepingCapacity: true)
            activityFinishedDuration.removeAll(keepingCapacity: true)
            userToggledEntries.removeAll(keepingCapacity: true)
        }

        let lastAssistantNodeID: TimelineNodeID? = nodes.reversed().first(where: { node in
            if case let .message(msg) = node.kind, msg.role == .assistant {
                return true
            }
            return false
        })?.id

        var hasActiveStreamingNode = false
        for node in nodes {
            switch node.kind {
            case let .message(msg):
                if msg.isStreaming { hasActiveStreamingNode = true }
            case let .thinking(th):
                if th.isStreaming || !th.isComplete { hasActiveStreamingNode = true }
            case let .tool(tl):
                if [.requested, .waitingPermission, .scheduled, .running].contains(tl.phase) && tl.result == nil && tl.error == nil { hasActiveStreamingNode = true }
            case .interaction, .subagent, .error, .runTerminal:
                break
            }
        }

        let isRateLimited = state.status == .rateLimited || state.activeSessionState?.status == .rateLimited
        let hasActiveTurn = state.activeSessionState?.activeTurnID != nil || state.activeSessionState?.activeRootRunID != nil || (state.activeSessionState?.queuedTurns.count ?? 0) > 0
        let isWaitingForProvider = !hasActiveStreamingNode && isActive(state) && !nodes.isEmpty && (
            state.status == .waitingForProvider ||
            state.activeSessionState?.status == .waitingForProvider ||
            state.status == .thinking ||
            state.activeSessionState?.status == .thinking ||
            isRateLimited ||
            (state.status == .ready && hasActiveTurn)
        )
        let isSessionIdle = !hasActiveStreamingNode && !isWaitingForProvider && !isActive(state)

        var entries: [TUITranscriptEntry] = []
        entries.reserveCapacity(nodes.count + commandEntries.count + 1)

        for node in nodes {
            if case .runTerminal = node.kind {
                continue
            }
            let isMutable: Bool
            switch node.kind {
            case let .message(msg):
                isMutable = msg.isStreaming
            case let .thinking(th):
                isMutable = th.isStreaming || !th.isComplete
            case let .tool(tl):
                isMutable = [.requested, .waitingPermission, .scheduled, .running].contains(tl.phase) && tl.result == nil && tl.error == nil
            case .interaction, .subagent, .error, .runTerminal:
                isMutable = false
            }

            let isTerminalAssistant = isSessionIdle && (node.id == lastAssistantNodeID)
            if !isMutable && !isTerminalAssistant, let cached = committedEntryCache[node.id] {
                entries.append(cached)
            } else if let rendered = renderEntry(node, isTerminalAssistant: isTerminalAssistant) {
                if !isMutable && !isTerminalAssistant {
                    committedEntryCache[node.id] = rendered
                }
                entries.append(rendered)
            }
        }

        var allEntries = entries + commandEntries
        if !commandEntries.isEmpty && !entries.isEmpty {
            allEntries.sort { a, b in
                if a.timestamp != b.timestamp {
                    return a.timestamp < b.timestamp
                }
                return false
            }
        }

        if isWaitingForProvider {
            if waitingStartedAt == nil { waitingStartedAt = animationNow }
            let elapsed = Int(waitingStartedAt!.duration(to: animationNow).components.seconds)
            let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            let spinnerChar = spinnerFrames[spinnerIndex % spinnerFrames.count]
            let rawModel = state.currentModelID ?? "model"
            let modelSlug = rawModel.split(separator: "/").last.map(String.init) ?? rawModel
            let waitingText: String
            if let detail = state.activeSessionState?.activeProviderRequestDetail, !detail.isEmpty {
                waitingText = "\(spinnerChar) \(detail) (\(elapsed)s)..."
            } else if isRateLimited {
                waitingText = "\(spinnerChar) 上游限流中 (429)，正在等待恢复重试 (\(elapsed)s)..."
            } else {
                waitingText = "\(spinnerChar) 正在思考与整理方案，等待 \(modelSlug) 响应 (\(elapsed)s)..."
            }
            allEntries.append(TUITranscriptEntry(
                id: "__waiting_for_provider__",
                kind: .thinking,
                text: waitingText,
                style: .accent,
                collapsed: false,
                timestamp: Date.distantFuture
            ))
        } else if hasActiveStreamingNode || !isActive(state) {
            waitingStartedAt = nil
        }

        view.transcript.replace(allEntries)
        if view.transcript.followsBottom {
            view.transcript.scrollToBottom()
        }
        if TUIPerformanceMetrics.shared.isEnabled {
            let transcriptNs = TUIPerformanceMetrics.durationNs(from: transcriptProjStart)
            TUIPerformanceMetrics.shared.recordTranscriptProjection(durationNs: transcriptNs)
        }
        lastRenderedNodeCount = nodes.count
    }

    private func refreshTranscriptIncremental(_ state: ApplicationState, changedNodes: Set<TimelineNodeID>) {
        let transcriptProjStart = ContinuousClock.now
        guard let session = state.activeSessionState else { return }
        let isSessionIdle = !isActive(state)
        let lastAssistantNodeID: TimelineNodeID? = session.timelineNodes.reversed().first(where: { node in
            if case let .message(msg) = node.kind, msg.role == .assistant {
                return true
            }
            return false
        })?.id

        for nodeID in changedNodes {
            guard let node = session.node(for: nodeID) else { continue }
            let isTerminalAssistant = isSessionIdle && (node.id == lastAssistantNodeID)
            if let rendered = renderEntry(node, isTerminalAssistant: isTerminalAssistant) {
                view.transcript.updateEntry(rendered)
            }
        }

        if view.transcript.followsBottom {
            view.transcript.scrollToBottom()
        }

        if TUIPerformanceMetrics.shared.isEnabled {
            let transcriptNs = TUIPerformanceMetrics.durationNs(from: transcriptProjStart)
            TUIPerformanceMetrics.shared.recordTranscriptProjection(durationNs: transcriptNs)
        }
        lastRenderedNodeCount = session.timelineNodes.count
    }

    private func refreshView(_ state: ApplicationState) {
        let refreshStart = ContinuousClock.now
        let preferences = UserPreferencesStore.shared.load()
        if renderedPreferences != preferences {
            renderedPreferences = preferences
            committedEntryCache.removeAll(keepingCapacity: true)
            lastSidebarRevision = nil
        }
        animationNow = animationClock.now

        let changes = pendingChanges
        pendingChanges = nil

        refreshSessionIdentityIfNeeded(state)
        refreshInteraction(state)
        refreshStatus(state)

        let canIncrementalTranscript: Bool = {
            guard let changes = changes else { return false }
            guard !changes.sessionChanged,
                  !changes.transcriptStructureChanged,
                  !changes.transcriptNodesChanged.isEmpty,
                  commandEntries.isEmpty,
                  !view.transcript.entries.isEmpty else {
                return false
            }
            return true
        }()

        if canIncrementalTranscript, let changes = changes {
            refreshTranscriptIncremental(state, changedNodes: changes.transcriptNodesChanged)
        } else {
            refreshTranscript(state)
        }

        let isHero = refreshHero(state)
        if !isHero {
            let sidebarStart = ContinuousClock.now
            refreshSidebar(state)
            if TUIPerformanceMetrics.shared.isEnabled {
                let sidebarNs = TUIPerformanceMetrics.durationNs(from: sidebarStart)
                TUIPerformanceMetrics.shared.recordSidebarProjection(durationNs: sidebarNs)
            }
        }

        latestState = state

        if TUIPerformanceMetrics.shared.isEnabled {
            let refreshTotalNs = TUIPerformanceMetrics.durationNs(from: refreshStart)
            TUIPerformanceMetrics.shared.recordRefreshViewTotal(durationNs: refreshTotalNs)
            TUIPerformanceMetrics.shared.recordRefresh(
                isFull: !canIncrementalTranscript,
                nodesCount: state.activeSessionState?.timelineNodes.count ?? 0,
                entriesCount: view.transcript.entries.count
            )
        }
    }

    private func currentPermissionDisplayName(from state: ApplicationState?) -> String {
        guard let state else {
            return options.isYoloMode ? "⚡ YOLO" : "Ask/Workspace"
        }
        let currentPermission = state.activeTurnPermissionConfiguration
        let isYolo = (currentPermission?.displayName == "YOLO")
            || (state.nextTurnPermission?.displayName == "YOLO")
            || (options.isYoloMode)
        return isYolo ? "⚡ YOLO" : (currentPermission?.displayName ?? state.nextTurnPermission?.displayName ?? "Ask/Workspace")
    }

    private func buildSidebarModel(from state: ApplicationState) -> TUISidebarModel {
        let session = state.activeSessionState

        // 1. 会话摘要 (使用现有 title，若无则从首条消息或事件生成)
        var summary = session?.title ?? ""
        if summary.isEmpty || summary.lowercased().contains("new session") {
            if let firstUserMsg = session?.timelineNodes.compactMap({ node -> String? in
                if case let .message(msg) = node.kind, msg.role == .user {
                    return msg.content
                }
                return nil
            }).first, !firstUserMsg.isEmpty {
                let singleLine = firstUserMsg.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                summary = String(singleLine.prefix(40))
            } else {
                summary = "新会话"
            }
        }

        // 2. P-Core / E-Core 双核心架构用量与缓存状态（由 Core 权威状态驱动，杜绝 UI 臆想推算）
        let ctx = session?.contextState
        let pCoreUsed = ctx?.activePCoreTokens ?? 0
        // P-Core 容量从 Core 发布的 targetTokens / hardLimitTokens 读取，绝不在 UI 硬编码 128_000
        let pCoreCapacity = ctx?.pCore?.targetTokens ?? ctx?.pCore?.hardLimitTokens ?? 0
        let pCoreDetail: String
        if pCoreCapacity > 0 {
            pCoreDetail = "\(TokenFormatter.format(pCoreUsed))/\(TokenFormatter.format(pCoreCapacity))"
        } else {
            pCoreDetail = "\(TokenFormatter.format(pCoreUsed))"
        }

        let eCoreBytes = ctx?.eCore?.totalBytes ?? ctx?.eCoreTotalBytes ?? 0
        let eCoreCount = ctx?.eCore?.objectCount ?? ctx?.eCoreObjectCount ?? 0
        // E-Core 为对象存储，不再用 bytes / 4 伪装 token，也不硬编码 100_000
        let eCoreDetail = "\(eCoreCount) objs · \(TokenFormatter.formatBytes(eCoreBytes))"

        let cacheRead = ctx?.providerCache?.cacheReadTokens ?? ctx?.cacheReadTokens ?? 0
        let cachePrompt = ctx?.providerCache?.promptTokens ?? ctx?.promptTokens ?? max(1, pCoreUsed)
        let cacheDebt = ctx?.providerCache?.cacheDebt ?? ctx?.cacheDebt ?? 0
        let cacheDetail = "Read \(TokenFormatter.format(cacheRead)) · Debt \(cacheDebt)"

        let cacheLayers = [
            TUISidebarModel.CacheLayer(
                name: "P-Core",
                usedTokens: pCoreUsed,
                capacityTokens: max(pCoreUsed, pCoreCapacity > 0 ? pCoreCapacity : 1),
                detailText: pCoreDetail
            ),
            TUISidebarModel.CacheLayer(
                name: "E-Core",
                usedTokens: eCoreBytes,
                capacityTokens: nil,
                detailText: eCoreDetail
            ),
            TUISidebarModel.CacheLayer(
                name: "Cache",
                usedTokens: cacheRead,
                capacityTokens: max(1, cachePrompt),
                detailText: cacheDetail
            )
        ]

        // 3. 激活的 MCP 具体的名字以及激活状态（直接由 Core 权威状态驱动）
        let mcpExtensions = state.extensions.filter { $0.kind == .mcp && $0.enabled }
        let mcpItems: [TUISidebarModel.MCPItem] = mcpExtensions.map { ext in
            let stateStr = ext.lifecycleState.lowercased()
            let isFailed = stateStr.contains("err") || stateStr.contains("fail") || stateStr.contains("unavail")
            let isEmpty = stateStr == "empty" || stateStr.contains("empty")
            let status: TUISidebarModel.MCPStatus
            if isFailed {
                status = .error("错误")
            } else if isEmpty {
                status = .empty
            } else if stateStr.contains("auth") || stateStr.contains("login") {
                status = .needsAuth
            } else if !ext.enabled || stateStr.contains("disab") {
                status = .disabled
            } else {
                status = .ready
            }
            return TUISidebarModel.MCPItem(id: ext.id, status: status)
        }

        // 4. Agent 的 tasks 显示区域 (从权威 session.todos 与 workflows 汇聚，拒绝 markdown 历史推断)
        var taskItems: [TUISidebarModel.TaskItem] = []
        let sessionTodos = session?.todos ?? []
        for todo in sessionTodos {
            let status: TUISidebarModel.TaskStatus
            switch todo.status.lowercased() {
            case "completed", "done", "success":
                status = .completed
            case "in_progress", "running":
                status = .inProgress
            case "failed", "error":
                status = .failed
            default:
                status = .pending
            }
            taskItems.append(TUISidebarModel.TaskItem(id: todo.id, title: todo.title, status: status))
        }

        for wf in state.workflows {
            for task in wf.tasks {
                let status: TUISidebarModel.TaskStatus
                switch task.status {
                case .completed:
                    status = .completed
                case .running:
                    status = .inProgress
                case .failed, .cancelled, .timedOut:
                    status = .failed
                default:
                    status = .pending
                }
                let title = task.definition.title ?? task.definition.task
                if !taskItems.contains(where: { $0.title == title }) {
                    taskItems.append(TUISidebarModel.TaskItem(id: task.definition.id.rawValue, title: title, status: status))
                }
            }
        }

        // 5. 子代理摘要
        var subagentItems: [TUISidebarModel.SubagentItem] = []
        if let subMap = session?.subagents {
            for (_, sub) in subMap {
                subagentItems.append(TUISidebarModel.SubagentItem(
                    id: String(sub.runID.rawValue.prefix(6)),
                    role: "子代理",
                    status: sub.status
                ))
            }
        }

        let prefixCache: TUISidebarModel.PrefixCacheStats? = {
            guard let cs = session?.contextState else { return nil }
            if let status = cs.cacheStatus, status == "unavailable" {
                return TUISidebarModel.PrefixCacheStats(
                    cachedTokens: 0,
                    promptTokens: cs.promptTokens ?? 0,
                    status: "unavailable",
                    cacheEpoch: cs.cacheEpoch,
                    epochReason: cs.epochReason,
                    clientHealthStatus: cs.clientHealthStatus,
                    clientBustRate: cs.clientCausedBustRate,
                    clientCausedBusts: cs.clientCausedBusts,
                    comparableRequests: cs.comparableRequests
                )
            }
            if let status = cs.cacheStatus, status == "coldNewEpoch" {
                return TUISidebarModel.PrefixCacheStats(
                    cachedTokens: 0,
                    promptTokens: cs.promptTokens ?? 0,
                    status: "coldNewEpoch",
                    cacheEpoch: cs.cacheEpoch,
                    epochReason: cs.epochReason,
                    clientHealthStatus: cs.clientHealthStatus,
                    clientBustRate: cs.clientCausedBustRate,
                    clientCausedBusts: cs.clientCausedBusts,
                    comparableRequests: cs.comparableRequests
                )
            }
            guard let prompt = cs.promptTokens, prompt > 0,
                  let cached = cs.cacheReadTokens else {
                if cs.clientHealthStatus != nil {
                    return TUISidebarModel.PrefixCacheStats(
                        cachedTokens: 0,
                        promptTokens: 0,
                        status: "unavailable",
                        cacheEpoch: cs.cacheEpoch,
                        clientHealthStatus: cs.clientHealthStatus,
                        clientBustRate: cs.clientCausedBustRate,
                        clientCausedBusts: cs.clientCausedBusts,
                        comparableRequests: cs.comparableRequests
                    )
                }
                return nil
            }
            return TUISidebarModel.PrefixCacheStats(
                cachedTokens: cached,
                promptTokens: prompt,
                previousPromptTokens: cs.previousPromptTokens,
                status: cs.cacheStatus ?? "active",
                cacheEpoch: cs.cacheEpoch,
                epochReason: cs.epochReason,
                clientHealthStatus: cs.clientHealthStatus,
                clientBustRate: cs.clientCausedBustRate,
                clientCausedBusts: cs.clientCausedBusts,
                comparableRequests: cs.comparableRequests
            )
        }()

        return TUISidebarModel(
            summary: summary,
            cacheLayers: cacheLayers,
            prefixCache: prefixCache,
            mcpItems: mcpItems,
            tasks: taskItems,
            subagents: subagentItems,
            scrollOffset: sidebarScrollOffset,
            mcpScrollOffset: mcpScrollOffset,
            taskScrollOffset: taskScrollOffset
        )
    }

    private func hasAgentStartedWork(_ state: ApplicationState) -> Bool {
        let hasTimeline = !(state.activeSessionState?.timelineNodes.isEmpty ?? true)
        let hasCommandEntries = !commandEntries.isEmpty
        let hasActiveWork = state.activeSessionState?.activeTurnID != nil || state.activeSessionState?.activeRootRunID != nil
        let isBusyWorking = [.thinking, .waitingForProvider, .runningTool, .runningSubagents].contains(state.status)
        let hasInteraction = state.activeInteraction != nil
        return hasTimeline || hasCommandEntries || hasActiveWork || isBusyWorking || hasInteraction
    }


    private func isHeroEmptyState(_ state: ApplicationState) -> Bool {
        return !hasAgentStartedWork(state)
    }

    private func hasLiveAnimatedContent(_ state: ApplicationState) -> Bool {
        guard let session = state.activeSessionState else { return false }
        if session.timelineNodes.contains(where: { node in
            switch node.kind {
            case let .message(msg):
                return msg.isStreaming
            case let .thinking(th):
                return th.isStreaming || !th.isComplete
            case let .tool(tl):
                return [.requested, .waitingPermission, .scheduled, .running].contains(tl.phase)
            case .interaction, .subagent, .error, .runTerminal:
                return false
            }
        }) {
            return true
        }
        if state.status == .waitingForProvider ||
            session.status == .waitingForProvider ||
            state.status == .thinking ||
            session.status == .thinking ||
            state.status == .rateLimited ||
            session.status == .rateLimited {
            return true
        }
        return false
    }

    private func animationTick(_ tick: TUIAnimationTick) {
        animationNow = tick.timestamp
        let hasRunningBgTasks = latestState.backgroundTasks.contains(where: { $0.status == .running })
        guard isActive || hasRunningBgTasks else { return }
        spinnerIndex = Int(tick.sequence % 10)
        view.backgroundSpinnerIndex = spinnerIndex

        // 后台任务运行中时，每秒触发一次后台任务状态增量同步，无需用户主动操作即可自动刷新
        if hasRunningBgTasks && tick.sequence % 10 == 0 {
            Task { [store] in
                _ = try? await store?.getBackgroundTasks()
            }
        }

        frameScheduler.markDirty(.animation)
    }

    private func refreshWaitingIndicator() {
        guard let started = waitingStartedAt, view.transcript.entries.last?.id == "__waiting_for_provider__" else { return }
        let elapsed = Int(started.duration(to: animationNow).components.seconds)
        let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let spinnerChar = spinnerFrames[spinnerIndex % spinnerFrames.count]
        let rawModel = latestState.currentModelID ?? "model"
        let modelSlug = rawModel.split(separator: "/").last.map(String.init) ?? rawModel
        let isRateLimited = latestState.status == .rateLimited || latestState.activeSessionState?.status == .rateLimited
        let text: String
        if let detail = latestState.activeSessionState?.activeProviderRequestDetail, !detail.isEmpty {
            text = "\(spinnerChar) \(detail) (\(elapsed)s)..."
        } else if isRateLimited {
            text = "\(spinnerChar) 上游限流中 (429)，正在等待恢复重试 (\(elapsed)s)..."
        } else {
            text = "\(spinnerChar) 正在思考与整理方案，等待 \(modelSlug) 响应 (\(elapsed)s)..."
        }
        view.transcript.updateLast(text)
    }

    private func render() {
        let frameStart = ContinuousClock.now
        renderCount += 1
        if renderCount <= 5 { debug("render.begin count=\(renderCount)") }
        StreamingLatencyTracker.shared.record("frame-\(renderCount)", stage: .frameScheduled)

        let viewRenderStart = ContinuousClock.now
        var frame = view.render(size: terminal.size, overlay: overlayModel())
        if let sel = selectionRect {
            frame.highlightSelection(sel)
        }
        lastRenderedFrame = frame
        if TUIPerformanceMetrics.shared.isEnabled {
            let viewRenderNs = TUIPerformanceMetrics.durationNs(from: viewRenderStart)
            TUIPerformanceMetrics.shared.recordViewRender(durationNs: viewRenderNs)
        }

        let presentStart = ContinuousClock.now
        terminal.render(frame)
        if TUIPerformanceMetrics.shared.isEnabled {
            let presentNs = TUIPerformanceMetrics.durationNs(from: presentStart)
            TUIPerformanceMetrics.shared.recordTerminalPresent(durationNs: presentNs)
            let frameTotalNs = TUIPerformanceMetrics.durationNs(from: frameStart)
            TUIPerformanceMetrics.shared.recordFrameTotal(durationNs: frameTotalNs)
            TUIPerformanceMetrics.shared.recordFramePresent(changedRows: frame.size.height, changedCells: frame.cells.count)
        }
        StreamingLatencyTracker.shared.record("frame-\(renderCount)", stage: .openTUIPresented)
        if renderCount <= 5 { debug("render.end count=\(renderCount)") }
    }

    private func overlayModel() -> TUIOverlayModel? {
        if latestState.activeInteraction != nil {
            let focus: TUIFocus = latestState.activeInteraction?.kind == .permission ? .permission : .overlay
            return TUIOverlayModel(lines: interactionLines(latestState), focus: focus)
        }
        switch overlay {
        case let .commandPalette(query, selected):
            let rows = paletteCommands(query: query).enumerated().map { index, command in
                TUIStyledLine("\(index == selected ? ">" : " ") /\(command.name)  \(command.description)", style: index == selected ? .overlayHighlight : .overlayItem)
            }
            let filter = query.isEmpty ? "" : "Filter: \(query)"
            return TUIOverlayModel(lines: [TUIStyledLine("Command Palette  \(filter)", style: .overlayTitle)] + rows, focus: .picker)
        case .completion:
            return TUIOverlayModel(lines: [TUIStyledLine("Completion", style: .overlayTitle)] + completionView.render(), focus: .completion)
        case let .modelPicker(query, selected):
            return renderModelPickerOverlay(query: query, selected: selected)
        case let .variantPicker(modelID, query, selected, variants):
            return renderVariantPickerOverlay(modelID: modelID, query: query, selected: selected, variants: variants)
        case let .sessionPicker(query, selected):
            return renderSessionPickerOverlay(query: query, selected: selected)
        case let .configModal(selected):
            return renderConfigModalOverlay(selected: selected)
        case let .tasksModal(selected, tasks, expandedDetail):
            return renderTasksModalOverlay(selected: selected, tasks: tasks, expandedDetail: expandedDetail)
        case let .commandModal(title, content, scrollOffset):
            return renderCommandModalOverlay(title: title, content: content, scrollOffset: scrollOffset)
        case let .themePicker(query, selected):
            return renderThemePickerOverlay(query: query, selected: selected)
        case let .modePicker(selected):
            return renderModePickerOverlay(selected: selected)
        case let .permissionsPicker(selected):
            return renderPermissionsPickerOverlay(selected: selected)
        case let .reasoningPicker(selected):
            return renderReasoningPickerOverlay(selected: selected)
        case nil:
            return nil
        }
    }

    private func renderModelPickerOverlay(query: String, selected: Int) -> TUIOverlayModel {
        let items = modelOptions(query: query)
        let totalWidth = min(max(56, terminal.size.width - 6), 66)
        let innerWidth = totalWidth - 4
        var lines: [TUIStyledLine] = []

        // 1. Header: Select model ... esc
        let titleLeft = "Select model"
        let titleRight = "esc"
        let padSpaces = max(1, innerWidth - titleLeft.count - titleRight.count)
        lines.append(TUIStyledLine(titleLeft + String(repeating: " ", count: padSpaces) + titleRight, style: .modalTitle))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 2. Search box
        let searchContent = query.isEmpty ? "│Search" : "\(query)│"
        let searchStyle: TUIStyle = query.isEmpty ? .modalSearchPlaceholder : .modalItem
        lines.append(TUIStyledLine(searchContent.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: searchStyle))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 3. Groups & Items (平铺视口，固定内容行数，彻底杜绝上下抽搐)
        let contentRowCount = 13
        let safeSelected = items.isEmpty ? 0 : max(0, min(items.count - 1, selected))

        enum PickerDisplayRow {
            case group(String)
            case item(actualIndex: Int, item: ModelOptionItem)
        }

        var allRows: [PickerDisplayRow] = []
        var lastGroup = ""
        for (i, it) in items.enumerated() {
            if query.isEmpty && it.group != lastGroup {
                lastGroup = it.group
                allRows.append(.group(it.group))
            }
            allRows.append(.item(actualIndex: i, item: it))
        }

        let selectedRowIdx = allRows.firstIndex(where: {
            if case let .item(idx, _) = $0 { return idx == safeSelected }
            return false
        }) ?? 0

        let scrollOffset = max(0, min(selectedRowIdx - contentRowCount / 2, max(0, allRows.count - contentRowCount)))
        let visibleRows = allRows.dropFirst(scrollOffset).prefix(contentRowCount)

        var renderedCount = 0
        if items.isEmpty {
            let emptyMsg = latestState.models.isEmpty ? "  Loading models..." : "  No matching models"
            lines.append(TUIStyledLine(emptyMsg.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))
            renderedCount += 1
        } else {
            for row in visibleRows {
                switch row {
                case let .group(groupName):
                    lines.append(TUIStyledLine(groupName.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalGroup))
                case let .item(actualIdx, item):
                    let isSelected = actualIdx == safeSelected
                    let isActive = item.modelID == latestState.currentModelID
                    let dot = isActive ? "● " : "  "
                    let left = "\(dot)\(item.displayName)"
                    let right = item.isFree ? "Free" : item.providerID
                    let pad = max(1, innerWidth - left.count - right.count)
                    let rowText = left + String(repeating: " ", count: pad) + right

                    if isSelected {
                        lines.append(TUIStyledLine(rowText, style: .modalHighlight))
                    } else {
                        lines.append(TUIStyledLine(rowText, style: isActive ? .modalActiveDot : .modalItem))
                    }
                }
                renderedCount += 1
            }
        }

        while renderedCount < contentRowCount {
            lines.append(TUIStyledLine("".padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalBackground))
            renderedCount += 1
        }

        // 4. Footer
        lines.append(TUIStyledLine("", style: .modalBackground))
        let footer = "Connect provider ctrl+a   Favorite ctrl+f"
        lines.append(TUIStyledLine(footer.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))

        let totalModalHeight = lines.count + 2
        return TUIOverlayModel(lines: lines, focus: .picker, isModal: true, modalWidth: totalWidth, modalHeight: totalModalHeight)
    }

    private func renderVariantPickerOverlay(modelID: String, query: String, selected: Int, variants: [String]) -> TUIOverlayModel {
        let totalWidth = min(max(56, terminal.size.width - 6), 66)
        let innerWidth = totalWidth - 4
        var lines: [TUIStyledLine] = []

        // 1. Header: Select variant ... esc
        let titleLeft = "Select variant"
        let titleRight = "esc"
        let padSpaces = max(1, innerWidth - titleLeft.count - titleRight.count)
        lines.append(TUIStyledLine(titleLeft + String(repeating: " ", count: padSpaces) + titleRight, style: .modalTitle))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 2. Search box
        let searchContent = query.isEmpty ? "│Search" : "\(query)│"
        let searchStyle: TUIStyle = query.isEmpty ? .modalSearchPlaceholder : .modalItem
        lines.append(TUIStyledLine(searchContent.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: searchStyle))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 3. Variant Items (固定 6 行高度)
        let contentRowCount = 6
        let q = query.lowercased()
        let filtered = query.isEmpty ? variants : variants.filter { $0.lowercased().contains(q) }
        let safeSelected = filtered.isEmpty ? 0 : max(0, min(filtered.count - 1, selected))

        let scrollOffset = max(0, min(safeSelected - contentRowCount / 2, max(0, filtered.count - contentRowCount)))
        let visibleVariants = filtered.enumerated().dropFirst(scrollOffset).prefix(contentRowCount)

        var renderedCount = 0
        if filtered.isEmpty {
            lines.append(TUIStyledLine("  No matching variants".padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))
            renderedCount += 1
        } else {
            for (idx, variant) in visibleVariants {
                let isSelected = idx == safeSelected
                let rowText = "  \(variant)".padding(toLength: innerWidth, withPad: " ", startingAt: 0)
                if isSelected {
                    lines.append(TUIStyledLine(rowText, style: .modalHighlight))
                } else {
                    lines.append(TUIStyledLine(rowText, style: .modalItem))
                }
                renderedCount += 1
            }
        }

        while renderedCount < contentRowCount {
            lines.append(TUIStyledLine("".padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalBackground))
            renderedCount += 1
        }

        lines.append(TUIStyledLine("", style: .modalBackground))
        let totalModalHeight = lines.count + 2
        return TUIOverlayModel(lines: lines, focus: .picker, isModal: true, modalWidth: totalWidth, modalHeight: totalModalHeight)
    }

    private func renderThemePickerOverlay(query: String, selected: Int) -> TUIOverlayModel {
        let allThemes = ThemeManager.shared.availableThemes
        let currentThemeID = ThemeManager.shared.currentTheme.id
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredThemes = q.isEmpty ? allThemes : allThemes.filter {
            $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }

        let totalWidth = min(max(56, terminal.size.width - 6), 68)
        let innerWidth = totalWidth - 4
        var lines: [TUIStyledLine] = []

        // 1. Header: Select Theme ... esc
        let titleLeft = "Select Theme"
        let titleRight = "esc"
        let padSpaces = max(1, innerWidth - titleLeft.count - titleRight.count)
        lines.append(TUIStyledLine(titleLeft + String(repeating: " ", count: padSpaces) + titleRight, style: .modalTitle))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 2. Search box
        let searchContent = query.isEmpty ? "│Search themes..." : "\(query)│"
        let searchStyle: TUIStyle = query.isEmpty ? .modalSearchPlaceholder : .modalItem
        lines.append(TUIStyledLine(searchContent.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: searchStyle))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 3. Theme Items
        let contentRowCount = max(6, min(10, filteredThemes.count))
        let safeSelected = filteredThemes.isEmpty ? 0 : max(0, min(filteredThemes.count - 1, selected))

        let scrollOffset = max(0, min(safeSelected - contentRowCount / 2, max(0, filteredThemes.count - contentRowCount)))
        let visibleThemes = filteredThemes.enumerated().dropFirst(scrollOffset).prefix(contentRowCount)

        var renderedCount = 0
        if filteredThemes.isEmpty {
            lines.append(TUIStyledLine("  No matching themes".padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))
            renderedCount += 1
        } else {
            for (idx, theme) in visibleThemes {
                let isSelected = idx == safeSelected
                let isActive = theme.id == currentThemeID
                let dot = isActive ? "● " : "○ "
                let left = "  \(dot)\(theme.name) (\(theme.id))"
                let right = "[\(theme.appearance.rawValue.capitalized)]"
                let pad = max(1, innerWidth - left.count - right.count)
                let rowText = left + String(repeating: " ", count: pad) + right

                if isSelected {
                    lines.append(TUIStyledLine(rowText, style: .modalHighlight))
                } else {
                    lines.append(TUIStyledLine(rowText, style: isActive ? .modalActiveDot : .modalItem))
                }
                renderedCount += 1
            }
        }

        while renderedCount < contentRowCount {
            lines.append(TUIStyledLine("".padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalBackground))
            renderedCount += 1
        }

        // 4. Footer
        lines.append(TUIStyledLine("", style: .modalBackground))
        let footer = "Enter Confirm · Esc Close · ↑/↓ Navigate"
        lines.append(TUIStyledLine(footer.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))

        let totalModalHeight = lines.count + 2
        return TUIOverlayModel(lines: lines, focus: .picker, isModal: true, modalWidth: totalWidth, modalHeight: totalModalHeight)
    }

    private func renderModePickerOverlay(selected: Int) -> TUIOverlayModel {
        let options = availableModeOptions
        let currentMode = latestState.nextTurnMode ?? latestState.activeSessionState?.mode ?? .build
        let totalWidth = max(50, min(72, terminal.size.width - 4))
        let innerWidth = max(1, totalWidth - 4)
        var lines: [TUIStyledLine] = []

        // 1. Header: Select Agent Mode ... esc
        let titleLeft = "切换 Agent 行为模式 (Agent Mode)"
        let titleRight = "esc"
        let padSpaces = max(1, innerWidth - TUIDisplayWidth.width(of: titleLeft) - TUIDisplayWidth.width(of: titleRight))
        lines.append(TUIStyledLine(titleLeft + String(repeating: " ", count: padSpaces) + titleRight, style: .modalTitle))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 2. Tip
        let tip = "  ↑/↓ 选择模式 · Enter 确认切换 · Esc 退出"
        lines.append(TUIStyledLine(tip.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 3. Options
        let safeSelected = options.isEmpty ? 0 : max(0, min(options.count - 1, selected))
        for (i, opt) in options.enumerated() {
            let isSelected = i == safeSelected
            let isActive = opt.mode == currentMode
            let cursor = isSelected ? "> " : "  "
            let tag = isActive ? "[ ACTIVE ]" : "         "
            let left = "\(cursor)\(opt.icon) \(opt.title)"
            let pad = max(1, innerWidth - TUIDisplayWidth.width(of: left) - TUIDisplayWidth.width(of: tag))
            let rowText = left + String(repeating: " ", count: pad) + tag

            if isSelected {
                lines.append(TUIStyledLine(rowText, style: .modalHighlight))
            } else {
                lines.append(TUIStyledLine(rowText, style: isActive ? .modalActiveDot : .modalItem))
            }

            let descText = "    \(opt.description)"
            lines.append(TUIStyledLine(descText.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))
            lines.append(TUIStyledLine("", style: .modalBackground))
        }

        lines = lines.map { TUIStyledLine(Self.modalText($0.text, width: innerWidth), style: $0.style) }
        let totalModalHeight = lines.count + 2
        return TUIOverlayModel(lines: lines, focus: .picker, isModal: true, modalWidth: totalWidth, modalHeight: totalModalHeight)
    }

    private func renderPermissionsPickerOverlay(selected: Int) -> TUIOverlayModel {
        let options = availablePermissionOptions
        let currentProfile = latestState.nextTurnPermission?.profile.rawValue
            ?? latestState.activeSessionState?.permissionConfiguration.profile.rawValue
            ?? "ask"
        let totalWidth = max(50, min(76, terminal.size.width - 4))
        let innerWidth = max(1, totalWidth - 4)
        var lines: [TUIStyledLine] = []

        // 1. Header: Select Permission Strategy ... esc
        let titleLeft = "配置安全与权限策略 (Permission Policy)"
        let titleRight = "esc"
        let padSpaces = max(1, innerWidth - TUIDisplayWidth.width(of: titleLeft) - TUIDisplayWidth.width(of: titleRight))
        lines.append(TUIStyledLine(titleLeft + String(repeating: " ", count: padSpaces) + titleRight, style: .modalTitle))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 2. Tip
        let tip = "  ↑/↓ 选择安全档位 · Enter 确认切换 · Esc 退出"
        lines.append(TUIStyledLine(tip.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 3. Options
        let safeSelected = options.isEmpty ? 0 : max(0, min(options.count - 1, selected))
        for (i, opt) in options.enumerated() {
            let isSelected = i == safeSelected
            let isActive = opt.key == currentProfile
            let cursor = isSelected ? "> " : "  "
            let tag = isActive ? "[ ACTIVE ]" : "         "
            let left = "\(cursor)\(opt.icon) \(opt.title)"
            let pad = max(1, innerWidth - TUIDisplayWidth.width(of: left) - TUIDisplayWidth.width(of: tag))
            let rowText = left + String(repeating: " ", count: pad) + tag

            if isSelected {
                lines.append(TUIStyledLine(rowText, style: .modalHighlight))
            } else {
                lines.append(TUIStyledLine(rowText, style: isActive ? .modalActiveDot : .modalItem))
            }

            let descText = "    \(opt.description)"
            lines.append(TUIStyledLine(descText.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))
            lines.append(TUIStyledLine("", style: .modalBackground))
        }

        lines = lines.map { TUIStyledLine(Self.modalText($0.text, width: innerWidth), style: $0.style) }
        let totalModalHeight = lines.count + 2
        return TUIOverlayModel(lines: lines, focus: .picker, isModal: true, modalWidth: totalWidth, modalHeight: totalModalHeight)
    }

    private func renderReasoningPickerOverlay(selected: Int) -> TUIOverlayModel {
        let options = availableReasoningOptions
        let currentEffort = latestState.effectiveReasoningEffort
        let totalWidth = max(50, min(74, terminal.size.width - 4))
        let innerWidth = max(1, totalWidth - 4)
        var lines: [TUIStyledLine] = []

        // 1. Header
        let titleLeft = "设置思考等级 (Reasoning Effort)"
        let titleRight = "esc"
        let padSpaces = max(1, innerWidth - TUIDisplayWidth.width(of: titleLeft) - TUIDisplayWidth.width(of: titleRight))
        lines.append(TUIStyledLine(titleLeft + String(repeating: " ", count: padSpaces) + titleRight, style: .modalTitle))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 2. Tip
        let tip = "  ↑/↓ 选择等级 · Enter 确认切换 · Esc 退出"
        lines.append(TUIStyledLine(tip.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 3. Options
        let safeSelected = options.isEmpty ? 0 : max(0, min(options.count - 1, selected))
        for (i, opt) in options.enumerated() {
            let isSelected = i == safeSelected
            let isActive = opt.effort == currentEffort
            let cursor = isSelected ? "> " : "  "
            let tag = isActive ? "[ ACTIVE ]" : "         "
            let left = "\(cursor)\(opt.icon) \(opt.title)"
            let pad = max(1, innerWidth - TUIDisplayWidth.width(of: left) - TUIDisplayWidth.width(of: tag))
            let rowText = left + String(repeating: " ", count: pad) + tag

            if isSelected {
                lines.append(TUIStyledLine(rowText, style: .modalHighlight))
            } else {
                lines.append(TUIStyledLine(rowText, style: isActive ? .modalActiveDot : .modalItem))
            }

            let descText = "    \(opt.description)"
            lines.append(TUIStyledLine(descText.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))
        }

        lines.append(TUIStyledLine("", style: .modalBackground))
        lines = lines.map { TUIStyledLine(Self.modalText($0.text, width: innerWidth), style: $0.style) }
        let totalModalHeight = lines.count + 2
        return TUIOverlayModel(lines: lines, focus: .picker, isModal: true, modalWidth: totalWidth, modalHeight: totalModalHeight)
    }

    private func renderSessionPickerOverlay(query: String, selected: Int) -> TUIOverlayModel {
        Self.sessionPickerOverlay(sessions: latestState.sessionCatalog, currentDirectory: currentDirectory,
                                  activeSessionID: latestState.activeSessionID, query: query, selected: selected, size: terminal.size)
    }

    static func sessionPickerOverlay(sessions: [SessionSummary], currentDirectory: String, activeSessionID: SessionID?,
                                     query: String, selected: Int, size: TUISize) -> TUIOverlayModel {
        let timeGroups = SessionCatalog.timeGroups(sessions, query: query)
        let items = timeGroups.flatMap(\.sessions)
        let totalWidth = max(28, min(78, size.width - 4))
        let innerWidth = max(1, totalWidth - 4)
        var lines: [TUIStyledLine] = []

        // 1. Header: Select session ... esc
        let titleLeft = "Select session"
        let titleRight = "esc"
        let padSpaces = max(1, innerWidth - titleLeft.count - titleRight.count)
        lines.append(TUIStyledLine(titleLeft + String(repeating: " ", count: padSpaces) + titleRight, style: .modalTitle))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 2. Search box
        let searchContent = query.isEmpty ? "│Search" : "\(query)│"
        let searchStyle: TUIStyle = query.isEmpty ? .modalSearchPlaceholder : .modalItem
        lines.append(TUIStyledLine(searchContent, style: searchStyle))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 3. Time Groups & Items (平铺视口，固定内容行数，彻底杜绝上下抽搐)
        let contentRowCount = max(3, min(13, size.height - 8))
        let safeSelected = items.isEmpty ? 0 : max(0, min(items.count - 1, selected))

        enum SessionDisplayRow {
            case group(String)
            case item(actualIndex: Int, session: SessionSummary)
        }

        var allRows: [SessionDisplayRow] = []
        var groupIndices: [Int] = []
        var actualCounter = 0
        for group in timeGroups {
            groupIndices.append(allRows.count)
            allRows.append(.group(group.title))
            for session in group.sessions {
                allRows.append(.item(actualIndex: actualCounter, session: session))
                actualCounter += 1
            }
        }

        let selectedRowIdx = allRows.firstIndex(where: {
            if case let .item(idx, _) = $0 { return idx == safeSelected }
            return false
        }) ?? 0

        let visibleRows: [SessionDisplayRow]
        if allRows.count <= contentRowCount {
            visibleRows = allRows
        } else {
            let groupHeaderIdx = groupIndices.last(where: { $0 <= selectedRowIdx }) ?? 0
            var offset = max(0, min(selectedRowIdx - contentRowCount / 2, allRows.count - contentRowCount))

            if offset > groupHeaderIdx {
                let remainingSlots = contentRowCount - 1
                let pinnedHeader = allRows[groupHeaderIdx]
                var dataStart = max(groupHeaderIdx + 1, min(selectedRowIdx - remainingSlots / 2, allRows.count - remainingSlots))
                if selectedRowIdx >= dataStart + remainingSlots {
                    dataStart = selectedRowIdx - remainingSlots + 1
                }
                if selectedRowIdx < dataStart {
                    dataStart = selectedRowIdx
                }
                let dataRows = Array(allRows[dataStart ..< min(allRows.count, dataStart + remainingSlots)])
                visibleRows = [pinnedHeader] + dataRows
            } else {
                if selectedRowIdx >= offset + contentRowCount {
                    offset = selectedRowIdx - contentRowCount + 1
                }
                if selectedRowIdx < offset {
                    offset = selectedRowIdx
                }
                visibleRows = Array(allRows[offset ..< min(allRows.count, offset + contentRowCount)])
            }
        }

        let timeFormatter = DateFormatter()
        let calendar = Calendar.current
        let now = Date()

        var renderedCount = 0
        if items.isEmpty {
            lines.append(TUIStyledLine("  No matching sessions", style: .modalItemDim))
            renderedCount += 1
        } else {
            for row in visibleRows {
                switch row {
                case let .group(groupTitle):
                    lines.append(TUIStyledLine(groupTitle, style: .modalGroup))
                case let .item(actualIdx, session):
                    let isSelected = actualIdx == safeSelected
                    let isActive = session.sessionID == activeSessionID
                    let dot = isActive ? "● " : "  "
                    let title = (session.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? session.title! : "未命名会话")
                        .replacingOccurrences(of: "\n", with: " ")

                    let dateStr: String
                    if calendar.isDateInToday(session.updatedAt) {
                        timeFormatter.dateFormat = "HH:mm"
                        dateStr = timeFormatter.string(from: session.updatedAt)
                    } else if calendar.isDateInYesterday(session.updatedAt) {
                        dateStr = "昨天"
                    } else if let days = calendar.dateComponents([.day], from: session.updatedAt, to: now).day, days < 7 {
                        timeFormatter.dateFormat = "E"
                        dateStr = timeFormatter.string(from: session.updatedAt)
                    } else {
                        timeFormatter.dateFormat = "MM-dd"
                        dateStr = timeFormatter.string(from: session.updatedAt)
                    }

                    let right = "\(session.messageCount)条 · \(dateStr)"
                    let rightW = TUIDisplayWidth.width(of: right)
                    let leftPrefixW = TUIDisplayWidth.width(of: dot)
                    let availableForTitle = max(4, innerWidth - rightW - leftPrefixW - 2)
                    let displayTitle = truncateToWidth(title, width: availableForTitle)
                    let left = "\(dot)\(displayTitle)"
                    let leftW = TUIDisplayWidth.width(of: left)
                    let pad = max(1, innerWidth - leftW - rightW)
                    let rowText = left + String(repeating: " ", count: pad) + right

                    if isSelected {
                        lines.append(TUIStyledLine(rowText, style: .modalHighlight))
                    } else {
                        lines.append(TUIStyledLine(rowText, style: isActive ? .modalActiveDot : .modalItem))
                    }
                }
                renderedCount += 1
            }
        }

        while renderedCount < contentRowCount {
            lines.append(TUIStyledLine("", style: .modalBackground))
            renderedCount += 1
        }

        // 4. Footer
        lines.append(TUIStyledLine("", style: .modalBackground))
        let footerLeft = "\(items.count) sessions"
        let footerRight = "↑↓ 移动 · Enter 恢复 · Esc 关闭"
        let leftW = TUIDisplayWidth.width(of: footerLeft)
        let rightW = TUIDisplayWidth.width(of: footerRight)
        let footerPad = max(1, innerWidth - leftW - rightW)
        let footer = footerLeft + String(repeating: " ", count: footerPad) + footerRight
        lines.append(TUIStyledLine(footer, style: .modalItemDim))

        lines = lines.map { TUIStyledLine(truncateToWidth($0.text, width: innerWidth), style: $0.style) }
        let totalModalHeight = lines.count + 2
        return TUIOverlayModel(lines: lines, focus: .picker, isModal: true, modalWidth: totalWidth, modalHeight: totalModalHeight)
    }

    private static func truncateToWidth(_ text: String, width: Int) -> String {
        var current = ""
        var w = 0
        for ch in text {
            let chW = TUIDisplayWidth.width(of: String(ch))
            if w + chW > width { break }
            current.append(ch)
            w += chW
        }
        if w < width {
            current += String(repeating: " ", count: width - w)
        }
        return current
    }

    private static func modalText(_ text: String, width: Int) -> String {
        let text = text.components(separatedBy: .controlCharacters).joined(separator: " ")
        var result = ""
        var used = 0
        for character in text {
            let cells = TUIDisplayWidth.width(of: character)
            if used + cells > width { break }
            result.append(character)
            used += cells
        }
        return result + String(repeating: " ", count: max(0, width - used))
    }

    private func renderConfigModalOverlay(selected: Int) -> TUIOverlayModel {
        let items = currentConfigItems()
        let totalWidth = max(4, min(72, terminal.size.width - 2))
        let innerWidth = max(1, totalWidth - 4)
        var lines: [TUIStyledLine] = []

        // 1. Header
        let titleLeft = "TUI 偏好配置 (Preferences)"
        let titleRight = "esc"
        let padSpaces = max(1, innerWidth - TUIDisplayWidth.width(of: titleLeft) - TUIDisplayWidth.width(of: titleRight))
        lines.append(TUIStyledLine(titleLeft + String(repeating: " ", count: padSpaces) + titleRight, style: .modalTitle))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 2. Tip
        let tip = "  ↑/↓ 切换选项 · Space/Enter/←/→ 切换状态 · Esc 退出"
        lines.append(TUIStyledLine(tip.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 3. Items
        let safeSelected = items.isEmpty ? 0 : max(0, min(items.count - 1, selected))
        for (i, item) in items.enumerated() {
            let isSelected = i == safeSelected
            let cursor = isSelected ? "> " : "  "
            let statusTag = item.isOn ? "[ ON ]" : "[ OFF ]"
            let left = "\(cursor)\(item.title)"
            let pad = max(1, innerWidth - TUIDisplayWidth.width(of: left) - TUIDisplayWidth.width(of: statusTag))
            let rowText = left + String(repeating: " ", count: pad) + statusTag

            if isSelected {
                lines.append(TUIStyledLine(rowText, style: .modalHighlight))
            } else {
                lines.append(TUIStyledLine(rowText, style: item.isOn ? .modalActiveDot : .modalItem))
            }

            let descText = "    \(item.description)"
            lines.append(TUIStyledLine(descText.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))
            lines.append(TUIStyledLine("", style: .modalBackground))
        }

        lines = lines.map { TUIStyledLine(Self.modalText($0.text, width: innerWidth), style: $0.style) }
        let totalModalHeight = lines.count + 2
        return TUIOverlayModel(lines: lines, focus: .picker, isModal: true, modalWidth: totalWidth, modalHeight: totalModalHeight)
    }

    private func renderTasksModalOverlay(selected: Int, tasks: [BackgroundTaskSnapshot], expandedDetail: Bool) -> TUIOverlayModel {
        Self.tasksModalOverlay(selected: selected, tasks: tasks, expandedDetail: expandedDetail, size: terminal.size)
    }

    static func tasksModalOverlay(selected: Int, tasks: [BackgroundTaskSnapshot], expandedDetail: Bool, size: TUISize) -> TUIOverlayModel {
        let totalWidth = max(50, min(80, size.width - 2))
        let innerWidth = max(1, totalWidth - 4)
        var lines: [TUIStyledLine] = []

        // 1. Header
        let titleLeft = "后台任务监控 (Background Tasks)"
        let titleRight = "esc"
        let padSpaces = max(1, innerWidth - TUIDisplayWidth.width(of: titleLeft) - TUIDisplayWidth.width(of: titleRight))
        lines.append(TUIStyledLine(titleLeft + String(repeating: " ", count: padSpaces) + titleRight, style: .modalTitle))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 2. Tip
        let tip = "  ↑/↓ 切换 · Enter 详情 · k 终止 · r 刷新 · Esc 退出"
        lines.append(TUIStyledLine(tip.padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 3. Tasks List
        if tasks.isEmpty {
            lines.append(TUIStyledLine("  暂无后台任务 (No background tasks)".padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))
            lines.append(TUIStyledLine("", style: .modalBackground))
        } else {
            let safeSelected = max(0, min(tasks.count - 1, selected))
            for (i, task) in tasks.enumerated() {
                let isSelected = i == safeSelected
                let cursor = isSelected ? "> " : "  "

                let statusBadge: String
                let statusStyle: TUIStyle
                switch task.status {
                case .running:
                    statusBadge = "[ RUNNING ]"
                    statusStyle = .accent
                case .exited:
                    if let code = task.exitCode, code == 0 {
                        statusBadge = "[ SUCCESS ]"
                        statusStyle = .modalActiveDot
                    } else {
                        statusBadge = "[ FAILED (\(task.exitCode ?? -1)) ]"
                        statusStyle = .warning
                    }
                case .timedOut:
                    statusBadge = "[ TIMEOUT ]"
                    statusStyle = .warning
                case .terminated:
                    statusBadge = "[ KILLED ]"
                    statusStyle = .modalItemDim
                }

                let pidText = task.pid.map { "PID:\($0)" } ?? ""
                let elapsedText = String(format: "%.1fs", task.elapsedSeconds)
                let metaRight = "\(pidText) \(elapsedText) \(statusBadge)".trimmingCharacters(in: .whitespaces)

                let availableLeftWidth = max(5, innerWidth - TUIDisplayWidth.width(of: metaRight) - 2)
                var cmdShort = "#\(i + 1) \(task.command)"
                if TUIDisplayWidth.width(of: cursor + cmdShort) > availableLeftWidth {
                    let maxCmdChars = max(4, availableLeftWidth - cursor.count - 3)
                    cmdShort = String(cmdShort.prefix(maxCmdChars)) + "..."
                }
                let left = "\(cursor)\(cmdShort)"

                let pad = max(1, innerWidth - TUIDisplayWidth.width(of: left) - TUIDisplayWidth.width(of: metaRight))
                let rowText = left + String(repeating: " ", count: pad) + metaRight

                if isSelected {
                    lines.append(TUIStyledLine(rowText, style: .modalHighlight))
                } else {
                    lines.append(TUIStyledLine(rowText, style: statusStyle))
                }

                if isSelected && expandedDetail {
                    lines.append(TUIStyledLine("    Task ID: \(task.id)", style: .modalItemDim))
                    lines.append(TUIStyledLine("    Command: \(task.command)", style: .modalItem))
                    lines.append(TUIStyledLine("    Directory: \(task.cwd)", style: .modalItemDim))
                    lines.append(TUIStyledLine("    Timeout: \(task.timeoutSeconds)s  (Elapsed: \(String(format: "%.1f", task.elapsedSeconds))s)", style: .modalItemDim))

                    let combinedOutput = (task.stdout + (task.stderr.isEmpty ? "" : "\n" + task.stderr)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !combinedOutput.isEmpty {
                        lines.append(TUIStyledLine("    Log Tail:", style: .modalGroup))
                        let outputLines = combinedOutput.components(separatedBy: "\n")
                        let tail = outputLines.suffix(6)
                        for logLine in tail {
                            let truncated = logLine.count > innerWidth - 8 ? String(logLine.prefix(innerWidth - 11)) + "..." : logLine
                            lines.append(TUIStyledLine("      │ \(truncated)", style: .modalItemDim))
                        }
                    } else {
                        lines.append(TUIStyledLine("    (No logs output yet)", style: .modalItemDim))
                    }
                    lines.append(TUIStyledLine("", style: .modalBackground))
                }
            }
        }

        lines = lines.map { TUIStyledLine(Self.modalText($0.text, width: innerWidth), style: $0.style) }
        let totalModalHeight = min(size.height - 2, lines.count + 2)
        return TUIOverlayModel(lines: lines, focus: .picker, isModal: true, modalWidth: totalWidth, modalHeight: totalModalHeight)
    }

    private func renderCommandModalOverlay(title: String, content: String, scrollOffset: Int) -> TUIOverlayModel {
        let totalWidth = min(max(58, terminal.size.width - 4), 78)
        let innerWidth = max(10, totalWidth - 4)
        var lines: [TUIStyledLine] = []

        // 1. Header
        let titleLeft = title.hasPrefix("🦊") ? title : "🦊 \(title)"
        let titleRight = "esc / q"
        let padSpaces = max(1, innerWidth - TUIDisplayWidth.width(of: titleLeft) - TUIDisplayWidth.width(of: titleRight))
        lines.append(TUIStyledLine(titleLeft + String(repeating: " ", count: padSpaces) + titleRight, style: .modalTitle))
        lines.append(TUIStyledLine("", style: .modalBackground))

        // 2. Content lines
        let rawLines = content.components(separatedBy: .newlines)
        let viewportHeight = max(6, min(16, terminal.size.height - 8))
        let maxScroll = max(0, rawLines.count - viewportHeight)
        let safeOffset = max(0, min(maxScroll, scrollOffset))
        let visibleLines = rawLines.dropFirst(safeOffset).prefix(viewportHeight)

        var renderedCount = 0
        for line in visibleLines {
            let padded = Self.truncateToWidth(line, width: innerWidth)
            lines.append(TUIStyledLine(padded, style: .modalItem))
            renderedCount += 1
        }
        while renderedCount < viewportHeight {
            lines.append(TUIStyledLine(String(repeating: " ", count: innerWidth), style: .modalBackground))
            renderedCount += 1
        }

        // 3. Footer
        lines.append(TUIStyledLine("", style: .modalBackground))
        let footerLeft = "↑↓/jk 滚动 · Esc/Enter/q 关闭"
        let footerRight = rawLines.count > viewportHeight ? "[\(safeOffset + 1)-\(min(rawLines.count, safeOffset + viewportHeight))/\(rawLines.count)]" : ""
        let pad = max(1, innerWidth - TUIDisplayWidth.width(of: footerLeft) - TUIDisplayWidth.width(of: footerRight))
        let footer = footerLeft + String(repeating: " ", count: pad) + footerRight
        lines.append(TUIStyledLine(footer, style: .modalItemDim))

        lines = lines.map { TUIStyledLine(Self.modalText($0.text, width: innerWidth), style: $0.style) }
        let totalModalHeight = min(terminal.size.height - 2, lines.count + 2)
        return TUIOverlayModel(lines: lines, focus: .picker, isModal: true, modalWidth: totalWidth, modalHeight: totalModalHeight)
    }

    private func interactionLines(_ state: ApplicationState) -> [TUIStyledLine] {
        guard let interaction = state.activeInteraction else { return [] }
        switch interaction.kind {
        case .permission:
            let request = interaction.permissionRequest
            let pendingCount = state.activeSessionState?.pendingInteractions.filter { $0.kind == .permission }.count ?? 1
            let countLabel = pendingCount > 1 ? " (\(pendingCount) 待确认)" : ""
            let actionLabel = pendingCount > 1 ? "[y/Enter] 全部允许  [n] 全部拒绝" : "[y/Enter] 允许  [n] 拒绝"
            return [
                TUIStyledLine("Permission required\(countLabel)", style: .warning),
                TUIStyledLine(request?.description ?? "Operation requires approval"),
                TUIStyledLine(request?.resource ?? "", style: .dim),
                TUIStyledLine(actionLabel, style: .accent)
            ]
        case .question:
            let request = interaction.questionRequest
            let options = request?.options.enumerated().map { "\($0.offset == hitlSelectedOption ? ">" : " ") \($0.offset + 1). \($0.element)" } ?? []
            let multiple = request?.allowsMultiple == true ? " · comma-separated" : ""
            return [TUIStyledLine(request?.question ?? "Question", style: .warning)] + options.map { TUIStyledLine($0) } + [TUIStyledLine("Enter answer\(multiple) · Esc cancel", style: .dim)]
        case .decision:
            let request = interaction.decisionRequest
            let options = request?.options.enumerated().map { "\($0.offset == hitlSelectedOption ? ">" : " ") \($0.offset + 1). \($0.element)" } ?? []
            return [TUIStyledLine(request?.question ?? "Decision", style: .warning)] + options.map { TUIStyledLine($0) } + [TUIStyledLine("Enter decision · Esc cancel", style: .dim)]
        case .unknown:
            return [TUIStyledLine("Action required", style: .warning)]
        }
    }

    private func statusParts(_ state: ApplicationState) -> (left: String, right: String) {
        let feedback = copyFeedback.map { "  \($0)" } ?? ""
        if isHeroEmptyState(state) {
            let workspace = state.currentWorkspace?.rootPath.split(separator: "/").last.map(String.init)
                ?? FileManager.default.currentDirectoryPath.split(separator: "/").last.map(String.init)
                ?? "LingXiAgent"
            let mcpCount = state.activeMCPCount
            let skillCount = state.activeSkillCount
            let graphInfo = state.currentWorkspace?.codebaseNodes.map { " · ☊ \($0) 节点" } ?? ""
            return ("📂 \(workspace)\(graphInfo)", "● \(mcpCount) 激活 MCP · \(skillCount) 激活 Skills\(feedback)")
        }

        let queuedCount = state.activeSessionState?.queuedTurns.count ?? 0
        let queuedSuffix = queuedCount > 0 ? " (\(queuedCount) queued)" : ""
        let hasActiveWork = (state.activeSessionState?.activeRootRunID != nil || state.activeSessionState?.activeTurnID != nil)
        let hasActiveError = state.activeSessionState?.hasActiveError == true || state.hasActiveError
        let baseStatus: String
        let waitingElapsedText: String
        if let started = waitingStartedAt {
            let elapsed = Int(started.duration(to: animationNow).components.seconds)
            waitingElapsedText = " (\(elapsed)s)"
        } else {
            waitingElapsedText = ""
        }
        let isRateLimited = state.status == .rateLimited || state.activeSessionState?.status == .rateLimited
        if let detail = state.activeSessionState?.activeProviderRequestDetail, !detail.isEmpty {
            baseStatus = "\(detail)\(waitingElapsedText)"
        } else if isRateLimited {
            baseStatus = "Rate limited (retrying)\(waitingElapsedText)"
        } else if state.status == .ready && (hasActiveWork || queuedCount > 0) && !hasActiveError {
            baseStatus = "Waiting for provider\(waitingElapsedText)"
        } else if state.status == .waitingForProvider {
            baseStatus = "Waiting for provider\(waitingElapsedText)"
        } else {
            baseStatus = statusLabel(state.status)
        }
        let status = "\(baseStatus)\(queuedSuffix)"
        let rawModel = state.currentModelID ?? "no model"
        let modelSlug = rawModel.split(separator: "/").last.map(String.init) ?? rawModel
        let effort = state.effectiveReasoningEffort.rawValue
        let modelWithEffort = "\(modelSlug) (\(effort))"

        let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let statusIndicator: String
        if isActive(state) {
            statusIndicator = "\(spinnerFrames[spinnerIndex % spinnerFrames.count]) \(status)"
        } else {
            statusIndicator = "● \(status)"
        }
        let left = "\(statusIndicator) · \(modelWithEffort)"

        let workspace = state.currentWorkspace?.rootPath.split(separator: "/").last.map(String.init) ?? "cwd"
        let graphSuffix = state.currentWorkspace?.codebaseNodes.map { " · ☊ \($0)n" } ?? ""
        let mode = state.activeSessionState?.mode.displayName ?? state.nextTurnMode?.displayName ?? "Build"
        let currentPermission = state.activeTurnPermissionConfiguration
        let isYolo = (currentPermission?.displayName == "YOLO")
            || (state.nextTurnPermission?.displayName == "YOLO")
            || (options.isYoloMode)
        let currentPermissionName = isYolo ? "⚡ YOLO" : (currentPermission?.displayName ?? "Ask/Workspace")
        let permissions: String
        if state.activeSessionState?.activeTurnID != nil, let next = state.nextTurnPermission, next != currentPermission {
            let nextName = next.displayName == "YOLO" ? "⚡ YOLO" : next.displayName
            permissions = "\(currentPermissionName) · next \(nextName)"
        } else {
            permissions = currentPermissionName
        }
        let right = "\(workspace)\(graphSuffix) · \(mode) · \(permissions)\(feedback)"
        return (left, right)
    }

    private func statusText(_ state: ApplicationState) -> String {
        let (left, right) = statusParts(state)
        return "\(left) · \(right)"
    }

    private func updateStatusLine(_ state: ApplicationState) {
        let (left, right) = statusParts(state)
        view.statusLine.setParts(left: left, right: right)
    }

    private func handleMouseClick(at point: TUIPoint) {
        copyFeedback = nil
        let layout = view.layout(size: terminal.size, overlay: overlayModel())
        let bounds = layout.transcript
        let y = point.y
        if y >= bounds.y && y < bounds.y + bounds.height {
            let clickRow = y - bounds.y
            if let entryID = view.transcript.entryID(atRow: clickRow, viewportHeight: bounds.height, width: terminal.size.width) {
                let current = userToggledEntries[entryID] ?? view.transcript.isCollapsed(id: entryID)
                userToggledEntries[entryID] = !current
                committedEntryCache.removeValue(forKey: TimelineNodeID(entryID))
                refreshView(latestState)
            }
        } else if y >= layout.bottomPane.y {
            view.setFocus(.composer)
        }
    }

    private func cycleMode(store: any FrontendRuntime) async {
        let current = latestState.activeSessionState?.mode ?? latestState.nextTurnMode ?? .build
        let nextMode = current.next
        await store.dispatch(.setMode(nextMode))
    }

    private func cycleReasoningEffort(store: any FrontendRuntime) async {
        let current = latestState.effectiveReasoningEffort
        let candidates: [ReasoningEffort] = [.auto, .off, .low, .medium, .high, .max]
        let nextIndex: Int
        if let idx = candidates.firstIndex(of: current) {
            nextIndex = (idx + 1) % candidates.count
        } else {
            nextIndex = 0
        }
        let nextEffort = candidates[nextIndex]
        await store.dispatch(.setReasoningEffort(nextEffort))
        UserPreferencesStore.shared.update(reasoningEffort: nextEffort.rawValue)
    }

    private var isActive: Bool {
        isActive(latestState)
    }

    private func isActive(_ state: ApplicationState) -> Bool {
        let queuedCount = state.activeSessionState?.queuedTurns.count ?? 0
        let hasActiveWork = (state.activeSessionState?.activeRootRunID != nil || state.activeSessionState?.activeTurnID != nil)
        let hasActiveError = state.activeSessionState?.hasActiveError == true || state.hasActiveError
        if (queuedCount > 0 || hasActiveWork) && !hasActiveError {
            return true
        }
        switch state.status {
        case .thinking, .waitingForProvider, .rateLimited, .runningTool, .runningSubagents, .paging, .reconnecting, .actionRequired:
            return true
        case .ready, .disconnected, .error:
            return false
        }
    }

    private func statusLabel(_ status: ProductRuntimeStatus) -> String {
        switch status {
        case .waitingForProvider: return "Waiting for provider"
        case .rateLimited: return "Rate limited"
        case .runningTool: return "Running tool"
        case .runningSubagents: return "Running subagents"
        case .actionRequired: return "Action Required"
        case .reconnecting: return "Reconnecting"
        default: return status.rawValue
        }
    }

    private func formatDuration(_ duration: Duration) -> String {
        ToolNode.formatDuration(duration)
    }

    private func formatSessionParams(node: TimelineNode, message: MessageNode) -> String {
        let metrics = message.metrics
        let model = metrics?.model ?? latestState.currentModelID ?? "model"

        let durationStr: String
        if let ms = metrics?.durationMs, ms > 0 {
            durationStr = ms >= 1000 ? String(format: "%.1fs", ms / 1000.0) : "\(Int(ms))ms"
        } else if let dur = activityFinishedDuration[node.id.rawValue] {
            durationStr = formatDuration(dur)
        } else {
            durationStr = "1.2s"
        }

        let firstTokenStr: String?
        if let ft = metrics?.firstTokenMs, ft >= 10.0 {
            firstTokenStr = ft >= 1000 ? String(format: "%.1fs", ft / 1000.0) : "\(Int(round(ft)))ms"
        } else if let ms = metrics?.durationMs, ms > 200 {
            let estimatedFt = min(ms * 0.25, max(150.0, ms * 0.15))
            firstTokenStr = estimatedFt >= 1000 ? String(format: "%.1fs", estimatedFt / 1000.0) : "\(Int(round(estimatedFt)))ms"
        } else {
            firstTokenStr = nil
        }

        let speedStr: String?
        if let rate = metrics?.tokenRate, rate > 0 {
            speedStr = String(format: "%.1f tok/s", rate)
        } else {
            let chars = message.content.count
            if chars > 0 {
                let durMs = metrics?.durationMs ?? 1200.0
                let sec = max(0.1, durMs / 1000.0)
                let tokens = max(1, Int(ceil(Double(chars) / 1.5)))
                speedStr = String(format: "%.1f tok/s", Double(tokens) / sec)
            } else {
                speedStr = nil
            }
        }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let completedTime = metrics?.completedAt ?? node.timestamp
        let timeStr = timeFormatter.string(from: completedTime)

        var segments: [String] = []
        segments.append("⚡️ \(model)")
        segments.append("耗时 \(durationStr)")
        if let ft = firstTokenStr {
            segments.append("首字 \(ft)")
        }
        if let sp = speedStr {
            segments.append(sp)
        }
        segments.append(timeStr)

        return segments.joined(separator: " · ")
    }

    private func renderEntry(_ node: TimelineNode, isTerminalAssistant: Bool) -> TUITranscriptEntry? {
        let id = node.id.rawValue
        switch node.kind {
        case let .message(message):
            let kind: TUITranscriptKind = message.role == .user ? .user : .assistant
            var content = message.content
            if message.role == .assistant && !message.isStreaming && !content.isEmpty && isTerminalAssistant {
                let params = formatSessionParams(node: node, message: message)
                content += "\n" + params
            }
            return TUITranscriptEntry(id: id, kind: kind, text: content, timestamp: node.timestamp)
        case let .thinking(thinking):
            let durationText: String
            if thinking.isComplete {
                if let dur = thinking.duration {
                    activityFinishedDuration[id] = dur
                    durationText = formatDuration(dur)
                } else if let started = thinking.startedAt, let completed = thinking.completedAt {
                    let s = completed.timeIntervalSince(started)
                    let dur = Duration.milliseconds(max(0, s * 1000))
                    activityFinishedDuration[id] = dur
                    durationText = formatDuration(dur)
                } else if let recorded = activityFinishedDuration[id] {
                    durationText = formatDuration(recorded)
                } else if let started = activityStartedAt.removeValue(forKey: id) {
                    let dur = started.duration(to: animationNow)
                    activityFinishedDuration[id] = dur
                    durationText = formatDuration(dur)
                } else {
                    durationText = "0s"
                }
            } else {
                let elapsed = elapsedSeconds(for: id)
                durationText = "\(elapsed)s"
            }
            let contentBody = thinking.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let isStreaming = thinking.isStreaming && !thinking.isComplete
            if contentBody.isEmpty && (!isStreaming || thinking.isComplete) {
                return nil
            }
            let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            let marker = isStreaming ? "\(spinnerFrames[spinnerIndex % spinnerFrames.count]) " : "• "
            let firstLine = isStreaming ? "Thinking..." : "Thought for \(durationText)"
            let text = "\(marker)\(firstLine)\n\(contentBody)"

            let prefs = UserPreferencesStore.shared.load()
            let isCollapsed: Bool
            if let userToggled = userToggledEntries[id] {
                isCollapsed = userToggled
            } else if prefs.expandThinking == true {
                isCollapsed = false
            } else {
                isCollapsed = !isStreaming && thinking.isComplete
            }
            return TUITranscriptEntry(id: id, kind: .thinking, text: text, style: .dim, collapsed: isCollapsed, timestamp: node.timestamp)
        case let .tool(tool):
            let sessionState = latestState.activeSessionState
            let isSessionIdle = (sessionState?.activeRootRunID == nil && sessionState?.activeTurnID == nil && (sessionState?.status == .ready || latestState.status == .ready))
            let isExplicitlyActive = sessionState?.activeToolCallIDs.contains(tool.callID) ?? false
            let rawActive = [.requested, .waitingPermission, .scheduled, .running].contains(tool.phase) && tool.result == nil && tool.error == nil
            let active = rawActive && !isSessionIdle && isExplicitlyActive
            return formatModernToolCall(tool: tool, id: id, active: active, timestamp: node.timestamp)
        case let .interaction(interaction):
            let detail = interaction.permissionRequest?.description ?? interaction.questionRequest?.question ?? interaction.decisionRequest?.question ?? "Action required"
            return TUITranscriptEntry(id: id, kind: .question, text: "\(interaction.kind.rawValue.capitalized): \(detail)", timestamp: node.timestamp)
        case let .subagent(subagent):
            return TUITranscriptEntry(id: id, kind: .subagent, text: "Subagent · \(subagent.status)", timestamp: node.timestamp)
        case .runTerminal:
            return nil
        case let .error(error):
            return TUITranscriptEntry(id: id, kind: .error, text: "\(error.code): \(error.message)", style: .error, timestamp: node.timestamp)
        }
    }

    private func elapsedSeconds(for id: String) -> Int {
        if activityStartedAt[id] == nil { activityStartedAt[id] = animationNow }
        guard let started = activityStartedAt[id] else { return 0 }
        let duration = started.duration(to: animationNow)
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return max(0, Int(seconds))
    }

    private func argumentSummary(_ argumentsJSON: String, toolName: String? = nil) -> String {
        ToolNode.summarizeArguments(argumentsJSON, toolName: toolName)
    }

    private func unwrapOutputText(_ raw: String) -> String {
        let cleanRaw = raw.replacingOccurrences(of: "\\/", with: "/")
        let trimmed = cleanRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
           let data = trimmed.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let stdout = dict["stdout"] as? String, !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return stdout.replacingOccurrences(of: "\\/", with: "/")
            }
            if let stderr = dict["stderr"] as? String, !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return stderr.replacingOccurrences(of: "\\/", with: "/")
            }
            if let summary = dict["summary"] as? String, !summary.isEmpty {
                return summary.replacingOccurrences(of: "\\/", with: "/")
            }
            if let message = dict["message"] as? String, !message.isEmpty {
                return message.replacingOccurrences(of: "\\/", with: "/")
            }
            if let error = dict["error"] as? String, !error.isEmpty {
                return error.replacingOccurrences(of: "\\/", with: "/")
            }
            if let exitCode = (dict["exit_code"] as? NSNumber)?.intValue ?? (dict["exitCode"] as? NSNumber)?.intValue {
                return exitCode == 0 ? "(no output)" : "exit code \(exitCode)"
            }
            return cleanRaw
        }

        // 针对因字符截断未闭合的 JSON，智能提取 stdout
        if trimmed.contains("\"stdout\"") {
            if let regex = try? NSRegularExpression(pattern: #""stdout"\s*:\s*"((?:[^"\\]|\\.)*)"#),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed) {
                let extracted = String(trimmed[range])
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\t", with: "\t")
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\/", with: "/")
                if !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return extracted
                }
            }
        }
        return cleanRaw
    }

    private func compactToolPath(_ path: String, maxLength: Int = 45) -> String {
        var p = path.replacingOccurrences(of: "\\/", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return "file" }
        if p.hasPrefix("$HOME/") {
            p = String(p.dropFirst(6))
        } else if p.hasPrefix("${HOME}/") {
            p = String(p.dropFirst(8))
        } else if p.hasPrefix("~/") {
            p = String(p.dropFirst(2))
        }
        let commonPrefixes = [
            "/Volumes/Development/Projects/projects/LingXiAgent/",
            "/Volumes/Development/Projects/",
            NSHomeDirectory() + "/"
        ]
        for prefix in commonPrefixes {
            if p.hasPrefix(prefix) {
                p = String(p.dropFirst(prefix.count))
                break
            }
        }
        if p.hasPrefix("/") {
            return p.split(separator: "/").last.map(String.init) ?? p
        }
        if p.count <= maxLength { return p }
        let parts = p.split(separator: "/")
        if parts.count >= 2 {
            let candidate = ".../" + parts.suffix(2).joined(separator: "/")
            if candidate.count <= maxLength { return candidate }
        }
        return parts.last.map(String.init) ?? p
    }

    private func capitalizeToolName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Tool" || trimmed == "unknown" { return "Tool" }
        let parts = trimmed.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." })
        let capitalized = parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return capitalized.isEmpty ? trimmed : capitalized
    }

    private func leftPad(_ text: String, toLength length: Int, pad: Character = " ") -> String {
        if text.count >= length { return text }
        return String(repeating: pad, count: length - text.count) + text
    }

    private func formatGitAddLines(content: String, maxVisible: Int = 12) -> [String] {
        let rawLines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !rawLines.isEmpty else { return [] }

        var result: [String] = []
        let total = rawLines.count
        let numWidth = max(2, String(total).count)

        if total <= maxVisible {
            for (idx, line) in rawLines.enumerated() {
                let numStr = leftPad(String(idx + 1), toLength: numWidth)
                result.append("     + \(numStr) | \(line)")
            }
        } else {
            let headCount = 5
            let tailCount = 3
            for i in 0..<headCount {
                let numStr = leftPad(String(i + 1), toLength: numWidth)
                result.append("     + \(numStr) | \(rawLines[i])")
            }
            let collapsed = total - headCount - tailCount
            result.append("     ... +\(collapsed) lines (ctrl + t to view transcript)")
            for i in (total - tailCount)..<total {
                let numStr = leftPad(String(i + 1), toLength: numWidth)
                result.append("     + \(numStr) | \(rawLines[i])")
            }
        }
        return result
    }

    private func formatGitPatchLines(oldString: String, newString: String, maxVisible: Int = 16) -> [String] {
        let oldLines = oldString.isEmpty ? [] : oldString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = newString.isEmpty ? [] : newString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []

        let maxNum = max(oldLines.count, newLines.count)
        let numWidth = max(2, String(maxNum).count)
        let half = maxVisible / 2

        if oldLines.count <= half || newLines.isEmpty {
            for (idx, line) in oldLines.enumerated() {
                let numStr = leftPad(String(idx + 1), toLength: numWidth)
                result.append("     - \(numStr) | \(line)")
            }
        } else {
            for i in 0..<min(3, oldLines.count) {
                let numStr = leftPad(String(i + 1), toLength: numWidth)
                result.append("     - \(numStr) | \(oldLines[i])")
            }
            let collapsed = oldLines.count - 4
            if collapsed > 0 {
                result.append("     ... -\(collapsed) lines")
            }
            if let last = oldLines.last, oldLines.count > 3 {
                let numStr = leftPad(String(oldLines.count), toLength: numWidth)
                result.append("     - \(numStr) | \(last)")
            }
        }

        if newLines.count <= half || oldLines.isEmpty {
            for (idx, line) in newLines.enumerated() {
                let numStr = leftPad(String(idx + 1), toLength: numWidth)
                result.append("     + \(numStr) | \(line)")
            }
        } else {
            for i in 0..<min(3, newLines.count) {
                let numStr = leftPad(String(i + 1), toLength: numWidth)
                result.append("     + \(numStr) | \(newLines[i])")
            }
            let collapsed = newLines.count - 4
            if collapsed > 0 {
                result.append("     ... +\(collapsed) lines")
            }
            if let last = newLines.last, newLines.count > 3 {
                let numStr = leftPad(String(newLines.count), toLength: numWidth)
                result.append("     + \(numStr) | \(last)")
            }
        }

        return result
    }

    private func formatGitApplyPatch(_ patch: String, maxVisible: Int = 16) -> (lines: [String], summary: String) {
        let rawLines = patch.components(separatedBy: "\n")
        var addCount = 0
        var delCount = 0
        var diffLines: [String] = []

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("+") && !trimmed.hasPrefix("+++") {
                addCount += 1
                diffLines.append("     \(line)")
            } else if trimmed.hasPrefix("-") && !trimmed.hasPrefix("---") {
                delCount += 1
                diffLines.append("     \(line)")
            }
        }

        let summary = "+\(addCount) / -\(delCount) lines"
        if diffLines.count <= maxVisible {
            return (diffLines, summary)
        } else {
            var collapsed: [String] = []
            collapsed.append(contentsOf: diffLines.prefix(6))
            let rem = diffLines.count - 9
            collapsed.append("     ... +\(rem) lines (ctrl + t to view transcript)")
            collapsed.append(contentsOf: diffLines.suffix(3))
            return (collapsed, summary)
        }
    }

    private func parseBashFileWrite(command: String) -> (path: String, content: String)? {
        let trimmedCmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCmd.isEmpty else { return nil }

        let lines = trimmedCmd.components(separatedBy: "\n")
        guard let firstLine = lines.first else { return nil }

        var targetPath: String?
        var delimiter: String?

        if firstLine.contains("cat") && firstLine.contains("<<") {
            if let delimRange = firstLine.range(of: "<<") {
                let afterDelim = firstLine[delimRange.upperBound...].trimmingCharacters(in: .whitespaces)
                let delimWord = afterDelim.components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ">"))).first ?? ""
                let cleanDelim = delimWord.trimmingCharacters(in: CharacterSet(charactersIn: "'\"\\"))
                if !cleanDelim.isEmpty {
                    delimiter = cleanDelim
                }
            }
            if let redirRange = firstLine.range(of: ">") {
                let afterRedir = firstLine[redirRange.upperBound...].trimmingCharacters(in: .whitespaces)
                if afterRedir.hasPrefix("\"") {
                    let sub = afterRedir.dropFirst()
                    if let endQuote = sub.firstIndex(of: "\"") {
                        targetPath = String(sub[..<endQuote])
                    }
                } else if afterRedir.hasPrefix("'") {
                    let sub = afterRedir.dropFirst()
                    if let endQuote = sub.firstIndex(of: "'") {
                        targetPath = String(sub[..<endQuote])
                    }
                } else {
                    let candidate = afterRedir.components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "<"))).first ?? ""
                    if !candidate.isEmpty {
                        targetPath = candidate
                    }
                }
            }
        } else if firstLine.contains("tee ") && firstLine.contains("<<") {
            if let delimRange = firstLine.range(of: "<<") {
                let afterDelim = firstLine[delimRange.upperBound...].trimmingCharacters(in: .whitespaces)
                let delimWord = afterDelim.components(separatedBy: .whitespaces).first ?? ""
                let cleanDelim = delimWord.trimmingCharacters(in: CharacterSet(charactersIn: "'\"\\"))
                if !cleanDelim.isEmpty {
                    delimiter = cleanDelim
                }
            }
            let parts = firstLine.components(separatedBy: .whitespaces)
            if let teeIdx = parts.firstIndex(of: "tee"), teeIdx + 1 < parts.count {
                var candidate = parts[teeIdx + 1]
                if candidate == "-a" && teeIdx + 2 < parts.count {
                    candidate = parts[teeIdx + 2]
                }
                if !candidate.hasPrefix("<") {
                    targetPath = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                }
            }
        }

        guard let path = targetPath, !path.isEmpty, let delim = delimiter, !delim.isEmpty else {
            return nil
        }

        guard lines.count > 1 else { return nil }
        var contentLines: [String] = []
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == delim {
                break
            }
            contentLines.append(line)
        }

        return (path: path, content: contentLines.joined(separator: "\n"))
    }

    func formatModernToolCall(tool: ToolNode, id: String, active: Bool, timestamp: Date) -> TUITranscriptEntry {
        let isDuplicateReuse = (tool.result?.error?.code == "duplicateToolCall")
        let isError = (tool.phase == .failed || tool.result?.success == false || tool.result?.error != nil) && !isDuplicateReuse
        let rawErrorMsg = isDuplicateReuse ? nil : (tool.error?.message ?? tool.result?.error?.message)
        let errorMsg = rawErrorMsg?.trimmingCharacters(in: .whitespacesAndNewlines)
        let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let effectiveActive = active && tool.result == nil && tool.error == nil
        let dotMarker = effectiveActive ? "\(spinnerFrames[spinnerIndex % spinnerFrames.count]) " : "● "
        let durText: String
        if !effectiveActive {
            if let dur = tool.executionDuration {
                durText = " (\(formatDuration(dur)))"
            } else if let ms = tool.result?.timing.executionMilliseconds, ms > 0 {
                durText = " (\(formatDuration(Duration.milliseconds(Int64(ms)))))"
            } else if let dur = activityFinishedDuration[id] {
                durText = " (\(formatDuration(dur)))"
            } else if let started = activityStartedAt.removeValue(forKey: id) {
                let dur = started.duration(to: animationNow)
                activityFinishedDuration[id] = dur
                durText = " (\(formatDuration(dur)))"
            } else {
                durText = ""
            }
        } else {
            durText = ""
        }

        let argsDict: [String: Any] = (tool.argumentsJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        let previewDict: [String: Any]? = (tool.result?.preview?.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })

        var lines: [String] = []
        var toolName = tool.toolName

        if toolName.isEmpty || toolName == "Tool" || toolName == "unknown" {
            if argsDict["CommandLine"] != nil || argsDict["command"] != nil || previewDict?["exit_code"] != nil || previewDict?["command"] != nil {
                toolName = "run_command"
            } else if argsDict["TargetContent"] != nil || (argsDict["TargetFile"] != nil && argsDict["ReplacementContent"] != nil) || argsDict["old_string"] != nil {
                toolName = "replace_file_content"
            } else if argsDict["CodeContent"] != nil || (argsDict["path"] != nil && argsDict["content"] != nil) {
                toolName = "write_file"
            } else if argsDict["patch"] != nil {
                toolName = "apply_patch"
            } else if argsDict["AbsolutePath"] != nil || (argsDict["path"] != nil && argsDict["StartLine"] != nil) {
                toolName = "view_file"
            } else if argsDict["Pattern"] != nil || argsDict["SearchDirectory"] != nil {
                toolName = "find_by_name"
            } else if argsDict["Query"] != nil || argsDict["SearchPath"] != nil {
                toolName = "grep_search"
            }
        }

        if toolName == "run_command" || toolName == "bash" || toolName == "shell" || toolName == "exec" {
            var command = (argsDict["CommandLine"] as? String) ?? (argsDict["command"] as? String)
            if command == nil, let pCmd = previewDict?["command"] as? String {
                command = pCmd
            }
            let rawArgs = tool.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayCommand = command ?? (!rawArgs.isEmpty && rawArgs != "{}" ? rawArgs : "command")

            if let bashWrite = parseBashFileWrite(command: displayCommand) {
                let shortPath = compactToolPath(bashWrite.path)
                lines.append("\(dotMarker)Write(\(shortPath))\(durText)")

                if isError {
                    let msg = errorMsg?.isEmpty == false ? errorMsg! : "Write failed"
                    lines.append("  └  \(msg)")
                } else {
                    let count = bashWrite.content.split(separator: "\n", omittingEmptySubsequences: false).count
                    lines.append("  └  +\(count) lines")
                    lines.append(contentsOf: formatGitAddLines(content: bashWrite.content))
                }
            } else {
                let singleLineCmd = displayCommand.split(separator: "\n").first.map(String.init) ?? displayCommand
                let cleanCmd = singleLineCmd.count > 65 ? String(singleLineCmd.prefix(62)) + "..." : singleLineCmd
                lines.append("\(dotMarker)Bash(\(cleanCmd))\(durText)")

                var rawOutput = [tool.stdout, tool.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                if rawOutput.isEmpty {
                    if isError, let errorMsg, !errorMsg.isEmpty {
                        rawOutput = errorMsg
                    } else if let preview = tool.result?.preview, !preview.isEmpty {
                        rawOutput = unwrapOutputText(preview)
                    } else if let summary = tool.result?.summary, !summary.isEmpty {
                        rawOutput = summary
                    }
                } else {
                    rawOutput = unwrapOutputText(rawOutput)
                }

                let trimmedOutput = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedOutput.isEmpty || trimmedOutput == "(no output)" {
                    if !effectiveActive {
                        lines.append("  └  (no output)")
                    }
                } else {
                    let outLines = trimmedOutput.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    if outLines.count <= 5 {
                        for (i, l) in outLines.enumerated() {
                            lines.append(i == 0 ? "  └  \(l)" : "     \(l)")
                        }
                    } else {
                        lines.append("  └  \(outLines[0])")
                        lines.append("     \(outLines[1])")
                        let collapsedCount = outLines.count - 3
                        lines.append("     ... +\(collapsedCount) lines (ctrl + t to view transcript)")
                        lines.append("     \(outLines[outLines.count - 1])")
                    }
                }
            }
        } else if toolName == "view_file" || toolName == "read_file" || toolName == "read" {
            let path = (argsDict["AbsolutePath"] as? String) ?? (argsDict["path"] as? String) ?? (argsDict["TargetFile"] as? String) ?? ""
            let shortPath = compactToolPath(path)
            lines.append("\(dotMarker)Read(\(shortPath))\(durText)")

            if isError {
                let msg = errorMsg?.isEmpty == false ? errorMsg! : "Read failed"
                lines.append("  └  \(msg)")
            } else if let summary = tool.result?.summary, !summary.isEmpty {
                lines.append("  └  \(summary)")
            } else if !tool.stdout.isEmpty {
                let count = tool.stdout.split(separator: "\n", omittingEmptySubsequences: false).count
                lines.append("  └  Read \(count) lines")
            } else if let start = argsDict["StartLine"] as? Int, let end = argsDict["EndLine"] as? Int {
                let count = max(1, end - start + 1)
                lines.append("  └  Read \(count) lines")
            } else {
                lines.append("  └  Read file")
            }
        } else if toolName == "grep" || toolName == "grep_search" || toolName == "search_code" {
            let query = (argsDict["Query"] as? String) ?? (argsDict["query"] as? String) ?? (argsDict["pattern"] as? String) ?? ""
            let path = (argsDict["SearchPath"] as? String) ?? (argsDict["path"] as? String) ?? ""
            let shortPath = compactToolPath(path, maxLength: 30)
            let argText = shortPath.isEmpty || shortPath == "file" ? query : "\(query) in \(shortPath)"
            let cleanArg = argText.count > 60 ? String(argText.prefix(57)) + "..." : argText
            lines.append("\(dotMarker)Search(\(cleanArg.isEmpty ? "code" : cleanArg))\(durText)")

            if isError {
                let msg = errorMsg?.isEmpty == false ? errorMsg! : "Search failed"
                lines.append("  └  \(msg)")
            } else if let summary = tool.result?.summary, !summary.isEmpty {
                lines.append("  └  \(summary)")
            } else if !tool.stdout.isEmpty {
                let count = tool.stdout.split(separator: "\n", omittingEmptySubsequences: false).count
                lines.append("  └  Found \(count) matches")
            } else {
                lines.append("  └  Search completed")
            }
        } else if toolName == "glob" || toolName == "find_by_name" {
            let pattern = (argsDict["Pattern"] as? String) ?? (argsDict["pattern"] as? String) ?? ""
            let dir = (argsDict["SearchDirectory"] as? String) ?? (argsDict["path"] as? String) ?? ""
            let shortDir = compactToolPath(dir, maxLength: 30)
            let argText = shortDir.isEmpty || shortDir == "file" ? pattern : "\(pattern) in \(shortDir)"
            let cleanArg = argText.count > 60 ? String(argText.prefix(57)) + "..." : argText
            lines.append("\(dotMarker)Search(\(cleanArg.isEmpty ? "files" : cleanArg))\(durText)")

            if isError {
                let msg = errorMsg?.isEmpty == false ? errorMsg! : "Find failed"
                lines.append("  └  \(msg)")
            } else if let summary = tool.result?.summary, !summary.isEmpty {
                lines.append("  └  \(summary)")
            } else {
                lines.append("  └  Find completed")
            }
        } else if toolName == "write_file" || toolName == "write_to_file" {
            let path = (argsDict["path"] as? String) ?? (argsDict["TargetFile"] as? String) ?? (argsDict["target_file"] as? String) ?? (argsDict["AbsolutePath"] as? String) ?? ""
            let code = (argsDict["content"] as? String) ?? (argsDict["CodeContent"] as? String) ?? (argsDict["code_content"] as? String) ?? ""
            let shortPath = compactToolPath(path)
            lines.append("\(dotMarker)Write(\(shortPath))\(durText)")

            if isError {
                let msg = errorMsg?.isEmpty == false ? errorMsg! : "Write failed"
                lines.append("  └  \(msg)")
            } else {
                let count = code.split(separator: "\n", omittingEmptySubsequences: false).count
                lines.append("  └  +\(count) lines")
                lines.append(contentsOf: formatGitAddLines(content: code))
            }
        } else if toolName == "replace_file_content" || toolName == "edit_file" {
            let path = (argsDict["TargetFile"] as? String) ?? (argsDict["path"] as? String) ?? (argsDict["target_file"] as? String) ?? (argsDict["AbsolutePath"] as? String) ?? ""
            let shortPath = compactToolPath(path)
            lines.append("\(dotMarker)Edit(\(shortPath))\(durText)")

            if isError {
                let msg = errorMsg?.isEmpty == false ? errorMsg! : "Edit failed"
                lines.append("  └  \(msg)")
            } else {
                let target = (argsDict["TargetContent"] as? String) ?? (argsDict["old_string"] as? String) ?? (argsDict["target_content"] as? String) ?? ""
                let repl = (argsDict["ReplacementContent"] as? String) ?? (argsDict["new_string"] as? String) ?? (argsDict["replacement_content"] as? String) ?? ""
                let targetLines = target.split(separator: "\n", omittingEmptySubsequences: false).count
                let replLines = repl.split(separator: "\n", omittingEmptySubsequences: false).count
                lines.append("  └  +\(replLines) / -\(targetLines) lines")
                lines.append(contentsOf: formatGitPatchLines(oldString: target, newString: repl))
            }
        } else if toolName == "apply_patch" || toolName == "patch_file" {
            let patchText = (argsDict["patch"] as? String) ?? ""
            var path = ""
            for line in patchText.components(separatedBy: "\n") {
                if line.hasPrefix("*** Update File: ") {
                    path = String(line.dropFirst("*** Update File: ".count)).trimmingCharacters(in: .whitespaces)
                    break
                } else if line.hasPrefix("*** Add File: ") {
                    path = String(line.dropFirst("*** Add File: ".count)).trimmingCharacters(in: .whitespaces)
                    break
                } else if line.hasPrefix("*** Delete File: ") {
                    path = String(line.dropFirst("*** Delete File: ".count)).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            let shortPath = compactToolPath(path.isEmpty ? "file" : path)
            lines.append("\(dotMarker)Patch(\(shortPath))\(durText)")

            if isError {
                let msg = errorMsg?.isEmpty == false ? errorMsg! : "Patch failed"
                lines.append("  └  \(msg)")
            } else {
                let (patchDiffLines, patchSummary) = formatGitApplyPatch(patchText)
                lines.append("  └  \(patchSummary)")
                lines.append(contentsOf: patchDiffLines)
            }
        } else if toolName == "todo" {
            let action = (argsDict["action"] as? String) ?? "manage"
            let title = (argsDict["title"] as? String) ?? ""
            let arg = title.isEmpty ? action : "\(action) \(title)"
            lines.append("\(dotMarker)Todo(\(arg))\(durText)")
            if isError {
                let msg = errorMsg?.isEmpty == false ? errorMsg! : "Todo failed"
                lines.append("  └  \(msg)")
            } else if let summary = tool.result?.summary, !summary.isEmpty {
                lines.append("  └  \(summary)")
            }
        } else {
            let isMcp = toolName == "call_mcp_tool"
            let canonicalName: String
            if isMcp, let mcpName = argsDict["ToolName"] as? String, !mcpName.isEmpty {
                canonicalName = capitalizeToolName(mcpName)
            } else if toolName.isEmpty || toolName == "Tool" || toolName == "unknown" {
                canonicalName = "Tool"
            } else {
                canonicalName = capitalizeToolName(toolName)
            }

            let cleanSummary = argumentSummary(tool.argumentsJSON, toolName: toolName)
            let hasArgs = !cleanSummary.isEmpty && cleanSummary != "{}"
            if canonicalName == "Tool" && !hasArgs {
                lines.append("\(dotMarker)Tool\(durText)")
            } else {
                let argDisplay = hasArgs ? cleanSummary : ""
                let truncatedArg = argDisplay.count > 60 ? String(argDisplay.prefix(57)) + "..." : argDisplay
                lines.append("\(dotMarker)\(canonicalName)(\(truncatedArg))\(durText)")
            }

            if isError {
                let msg = errorMsg?.isEmpty == false ? errorMsg! : "Tool failed"
                lines.append("  └  \(msg)")
            } else if let result = tool.result {
                let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                if !summary.isEmpty {
                    lines.append("  └  \(summary.replacingOccurrences(of: "\t", with: "  "))")
                } else if let preview = result.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
                    let unwrapped = unwrapOutputText(preview)
                    let previewLines = unwrapped.split(separator: "\n", omittingEmptySubsequences: false).prefix(3)
                    for (idx, pl) in previewLines.enumerated() {
                        let cleanL = pl.replacingOccurrences(of: "\t", with: "  ")
                        lines.append(idx == 0 ? "  └  \(cleanL)" : "     \(cleanL)")
                    }
                }
            }
        }

        let entryStyle: TUIStyle = isError ? .error : (active ? .accent : .normal)
        let prefs = UserPreferencesStore.shared.load()
        let defaultCollapsed = !(prefs.expandTools ?? false) && !active
        let isCollapsed = userToggledEntries[id] ?? defaultCollapsed
        return TUITranscriptEntry(id: id, kind: .toolCall, text: lines.joined(separator: "\n"), style: entryStyle, collapsed: isCollapsed, timestamp: timestamp)
    }
}

#if DEBUG
extension ApplicationTUI {
    public func refreshViewForTesting(_ state: ApplicationState, changes: ApplicationChangeSet? = nil) {
        if let changes {
            self.pendingChanges = changes
        }
        refreshView(state)
    }

    public var sidebarModelForTesting: TUISidebarModel? {
        view.sidebarModel
    }

    public func buildSidebarModelForTesting(from state: ApplicationState) -> TUISidebarModel {
        buildSidebarModel(from: state)
    }
}
#endif

extension ApplicationTUI {
    /// Renders one frame and reports whether the terminal legs were walked, so the caller can say
    /// which of the two it actually verified.
    public static func smokeCheck() throws -> Bool {
        let backend = POSIXTerminalBackend(noAltScreen: true)
        // Raw mode is a tcsetattr on the controlling terminal, and a piped or CI run has none -
        // EIO there is not a defect, so the check falls back to the frame pipeline, which is the
        // renderer path a redirected run would take anyway.
        let interactive = LingXiPlatform.terminal.isInteractive()
        if interactive { try backend.start() }
        let frame = TUIFrame(size: backend.size)
        backend.render(frame)
        if interactive { backend.stop() }
        return interactive
    }
}

