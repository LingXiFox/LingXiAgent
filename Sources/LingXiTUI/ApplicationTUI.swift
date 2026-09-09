import Foundation
import LingXiApplication
import LingXiTUIComponents

@MainActor
public final class ApplicationTUI {
    private enum UIEvent: Sendable {
        case input(TUIInputEvent)
        case stateUpdate(ApplicationState)
        case commandResult(TUITranscriptEntry)
    }

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
        FrontendCommandItem(name: "clear", description: "Clear current transcript", category: "View"),
        FrontendCommandItem(name: "expand", description: "Expand all collapsed thinking and tool outputs", category: "View"),
        FrontendCommandItem(name: "collapse", description: "Collapse all long thinking and tool outputs", category: "View"),
        FrontendCommandItem(name: "quit", aliases: ["exit"], description: "Exit LingXi TUI", category: "General")
    ]

    private enum Overlay {
        case commandPalette(query: String, selected: Int)
        case completion(tokenStart: Int, selected: Int)
        case modelPicker(query: String, selected: Int)
        case variantPicker(modelID: String, query: String, selected: Int, variants: [String])
    }

    public let options: TUILaunchOptions
    private let terminal: any TerminalBackend
    private let view = TUIApp()
    private let completionView = CompletionView()
    private var store: ApplicationStore?
    private var latestState = ApplicationState()
    private var commands: [ApplicationCommand] = []
    private var overlay: Overlay?
    private var hitlSelectedOption = 0
    private var activeInteractionID: InteractionID?
    private var referenceCandidates: [String] = []
    private var spinnerIndex = 0
    private var commandEntries: [TUITranscriptEntry] = []
    private var shouldQuit = false
    private var renderCount = 0
    private var actionTail: Task<Void, Never>?
    private var uiEventContinuation: AsyncStream<UIEvent>.Continuation?
    private let animationTicker = TUIAnimationTicker()
    private let animationClock = ContinuousClock()
    private var animationNow: ContinuousClock.Instant
    private var activityStartedAt: [String: ContinuousClock.Instant] = [:]
    private var activityFinishedDuration: [String: Duration] = [:]
    private var committedEntryCache: [TimelineNodeID: TUITranscriptEntry] = [:]
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
    private var failedMCPServers: Set<String> = []
    private lazy var frameScheduler = TUIFrameScheduler(targetFps: 60) { [weak self] dirtyFlags in
        guard let self else { return }
        if dirtyFlags.contains(.content) {
            self.refreshView(self.latestState)
        } else if dirtyFlags.contains(.animation) {
            self.view.statusLine.text = self.statusText(self.latestState)
            if self.waitingStartedAt != nil {
                self.refreshWaitingIndicator()
            }
        }
        self.render()
    }

    public init(options: TUILaunchOptions = .default) {
        self.options = options
        self.terminal = POSIXTerminalBackend(noAltScreen: options.noAltScreen)
        animationNow = animationClock.now
        let prefs = UserPreferencesStore.shared.load()
        let initialModel = options.initialModelID ?? prefs.lastModelID ?? "deepseek-v4-flash"
        let initialEffort = options.reasoningEffort?.rawValue ?? prefs.lastReasoningEffort ?? "auto"
        let initialProvider: String = {
            if let slashIdx = initialModel.firstIndex(of: "/") {
                return String(initialModel[..<slashIdx]).uppercased()
            }
            return initialModel.lowercased().contains("deepseek") ? "DeepSeek" : "Provider"
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
    }

    private var allCommands: [FrontendCommandItem] {
        let appItems = commands.map {
            FrontendCommandItem(
                name: $0.name,
                aliases: $0.aliases,
                description: $0.description,
                category: $0.category,
                argumentSchema: $0.argumentSchema
            )
        }
        return Self.localCommands + appItems
    }

    public func run() async {
        do {
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
            view.statusLine.text = "📂 \(initialWorkspace)  ·  ● 正在连接..."
            render()
            debug("connecting.frame.end")

            debug("store.create.begin")
            store = try await ApplicationStore.stdio(autoConnect: false)
            debug("store.create.end")
            guard let store else { return }
            commands = await store.commandRegistry.allCommands

            let (eventStream, eventContinuation) = AsyncStream.makeStream(of: UIEvent.self)
            uiEventContinuation = eventContinuation

            let updates = Task { [store] in
                for await state in await store.stateUpdates {
                    eventContinuation.yield(.stateUpdate(state))
                }
            }
            defer { updates.cancel() }
            defer { actionTail?.cancel() }

            let animationUpdates = Task { [weak self] in
                guard let self else { return }
                for await tick in self.animationTicker.stream() {
                    self.animationTick(tick)
                }
            }
            defer { animationUpdates.cancel() }

            let inputReader = Task.detached { [terminal] in
                while !Task.isCancelled {
                    if let event = terminal.nextInput() {
                        eventContinuation.yield(.input(event))
                        if case .quit = event { break }
                        if case .interrupt = event { break }
                    }
                }
            }
            defer { inputReader.cancel() }

            let connection = Task { [weak self, store] in
                do {
                    self?.debug("connect.begin")
                    try await store.connect()
                    self?.debug("connect.end")
                    self?.referenceCandidates = await store.workspaceReferenceCandidates()
                    self?.debug("workspace.references.end")
                    await store.dispatch(.listSessions)
                    self?.debug("sessions.list.end")

                    if let self {
                        let prefs = UserPreferencesStore.shared.load()
                        if let resumeID = self.options.resumeSessionID, !resumeID.isEmpty {
                            await store.dispatch(.switchSession(SessionID(resumeID)))
                        }
                        if self.options.isYoloMode {
                            await store.dispatch(.setPermissionConfiguration(.yoloFullAccess))
                        }
                        let targetModel = self.options.initialModelID ?? prefs.lastModelID
                        if let modelID = targetModel, !modelID.isEmpty {
                            await store.dispatch(.selectModel(modelID))
                        }
                        let targetEffort = self.options.reasoningEffort ?? prefs.lastReasoningEffort.flatMap(ReasoningEffort.init(rawValue:))
                        if let effort = targetEffort {
                            await store.dispatch(.setReasoningEffort(effort))
                        }
                        if let prompt = self.options.initialPrompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            await store.dispatch(.submitPrompt(prompt))
                        }
                    }
                } catch {
                    self?.debug("connect.failed error=\(error)")
                }
            }
            defer { connection.cancel() }

            debug("event.loop.begin")

            eventLoop: for await event in eventStream {
                switch event {
                case let .input(inputEvent):
                    await handle(inputEvent, store: store)
                    if case .tick = inputEvent {
                    } else {
                        frameScheduler.markDirty(.input)
                    }
                    if shouldQuit {
                        frameScheduler.flush()
                        eventContinuation.finish()
                        break eventLoop
                    }
                case let .stateUpdate(state):
                    if latestState.currentWorkspace?.rootPath != state.currentWorkspace?.rootPath {
                        referenceCandidates = await store.workspaceReferenceCandidates()
                    }
                    latestState = state
                    if options.isYoloMode, let interaction = state.activeInteraction, interaction.kind == .permission {
                        enqueue { await store.dispatch(.grantPermission(interactionID: interaction.interactionID, decision: .allow)) }
                    }
                    frameScheduler.markDirty(.content)
                case let .commandResult(entry):
                    commandEntries.append(entry)
                    latestState = await store.state
                    frameScheduler.markDirty(.content)
                }
            }
            await store.dispatch(.disconnect)
            uiEventContinuation = nil
        } catch {
            print("LingXiTUI 启动失败: \(error)")
        }
    }

    private func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["LINGXI_TUI_DEBUG"] == "1" else { return }
        let timestamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[\(timestamp)] [LingXiTUI] \(message)\n".utf8))
    }

    private func handle(_ event: TUIInputEvent, store: ApplicationStore) async {
        if latestState.activeInteraction != nil {
            await handleInteraction(event, store: store)
            return
        }

        if case .commandPalette = overlay {
            await handleCommandPalette(event, store: store)
            return
        }

        if case .completion = overlay {
            await handleCompletion(event)
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
            lastMousePoint = TUIPoint(x: x, y: y)
            handleMouseClick(at: TUIPoint(x: x, y: y))
        case let .mouseDown(x, y):
            lastMousePoint = TUIPoint(x: x, y: y)
            selectionStart = TUIPoint(x: x, y: y)
            selectionRect = nil
        case let .mouseDrag(x, y):
            lastMousePoint = TUIPoint(x: x, y: y)
            if let start = selectionStart {
                selectionRect = TUIRect(from: start, to: TUIPoint(x: x, y: y))
                frameScheduler.markDirty(.input)
            }
        case let .mouseUp(x, y):
            lastMousePoint = TUIPoint(x: x, y: y)
            if let _ = selectionStart, let rect = selectionRect, (rect.width > 1 || rect.height > 1) {
                if let frame = lastRenderedFrame {
                    let text = frame.text(in: rect)
                    if !text.isEmpty {
                        ClipboardSupport.copy(text)
                        copyFeedback = "✓ 已复制到剪贴板"
                    }
                }
            } else {
                handleMouseClick(at: TUIPoint(x: x, y: y))
            }
            selectionStart = nil
            selectionRect = nil
            frameScheduler.markDirty(.input)
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
        case .enter where view.focus == .transcript,
             .character(" ") where view.focus == .transcript:
            if let selectedID = view.transcript.selectedItemID {
                let current = userToggledEntries[selectedID] ?? view.transcript.isCollapsed(id: selectedID)
                userToggledEntries[selectedID] = !current
                committedEntryCache.removeValue(forKey: TimelineNodeID(selectedID))
                refreshView(latestState)
            }
        case .right where view.focus == .transcript:
            if let selectedID = view.transcript.selectedItemID {
                userToggledEntries[selectedID] = false
                committedEntryCache.removeValue(forKey: TimelineNodeID(selectedID))
                refreshView(latestState)
            }
        case .left where view.focus == .transcript:
            if let selectedID = view.transcript.selectedItemID {
                userToggledEntries[selectedID] = true
                committedEntryCache.removeValue(forKey: TimelineNodeID(selectedID))
                refreshView(latestState)
            }
        case .resize:
            break
        case .tick:
            if isActive { spinnerIndex = (spinnerIndex + 1) % 10 }
        case .escape:
            if overlay != nil {
                overlay = nil
            } else if view.focus == .transcript {
                view.transcript.clearSelection()
                view.setFocus(.composer)
                return
            }
            enqueue { await store.dispatch(.stopCurrentRun) }
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
                view.transcript.scrollToBottom()
                waitingStartedAt = animationNow
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

    private func handleCommandPalette(_ event: TUIInputEvent, store: ApplicationStore) async {
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

    private func handleCompletion(_ event: TUIInputEvent) async {
        guard case let .completion(tokenStart, selected) = overlay else { return }
        switch event {
        case .up, .down, .pageUp, .pageDown:
            completionView.handle(event)
        case .tab, .enter:
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
    }

    private func modelOptions(query: String) -> [ModelOptionItem] {
        var base: [ModelOptionItem] = []
        let currentID = latestState.currentModelID ?? "bai/deepseek-v4-flash"
        let catalog = latestState.models

        // 1. Recent / Active 分组（当前使用的活动模型排首位）
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

        // 辅助映射：将知名内置 providerID 转为友好的分组名称和显示名称
        let knownVendors: [String: String] = [
            "openai-codex": "OpenAI (ChatGPT Plus)",
            "openai-api": "OpenAI API",
            "anthropic-api": "Anthropic",
            "anthropic-claude-subscription": "Anthropic (Claude)",
            "deepseek-api": "DeepSeek",
            "gemini-api": "Google Gemini",
            "gemini-code-assist": "Google Code Assist",
            "antigravity": "Google Antigravity",
            "ollama-local": "Ollama (Local)",
            "llama-cpp-local": "llama.cpp (Local)",
            "lm-studio-local": "LM Studio (Local)",
            "openrouter": "OpenRouter",
            "xai-api": "xAI Grok",
            "xai-grok-subscription": "xAI Grok Subscription",
            "alibaba-bailian-api": "Alibaba Bailian",
            "minimax-api": "MiniMax",
        ]

        // 构造提供商分组字典与排序权值
        func groupInfo(for providerID: String, configured: Bool) -> (groupName: String, orderPriority: Int) {
            if let friendlyName = knownVendors[providerID] {
                if configured {
                    return (friendlyName, 1) // 已配置/已登录的内置提供商（如 ChatGPT Plus）排最前
                } else {
                    return ("\(friendlyName) (Built-in)", 3) // 未配置的内置提供商排在后面
                }
            } else {
                // 自定义提供商 (如 bai)
                let customName = latestState.providers.first(where: { $0.id == providerID || $0.productID == providerID })?.displayName ?? providerID.uppercased()
                return ("Custom: \(customName)", 2) // 自定义提供商
            }
        }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var otherItems: [(item: ModelOptionItem, priority: Int)] = []

        for m in catalog {
            // 跳过当前活动模型，避免在 Recent 之外重复展示
            if m.id == currentID || m.modelID == currentID { continue }

            // 未输入 query 时，绝不展示未配置的内置提供商模型
            if q.isEmpty && !m.configured {
                continue
            }

            let (gName, priority) = groupInfo(for: m.providerID, configured: m.configured)
            let isFree = m.modelID.contains("flash") || m.modelID.contains("free") || m.displayName.lowercased().contains("free")

            let item = ModelOptionItem(
                modelID: m.id,
                displayName: m.displayName.isEmpty ? m.modelID : m.displayName,
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

    private func handleModelPicker(_ event: TUIInputEvent, store: ApplicationStore) async {
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

    private func handleVariantPicker(_ event: TUIInputEvent, store: ApplicationStore) async {
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
            UserPreferencesStore.shared.update(modelID: modelID, reasoningEffort: effort.rawValue)
            commandEntries.append(TUITranscriptEntry(kind: .result, text: "✓ 已选择模型: \(modelID) · 思考等级: \(effort.rawValue)"))
            refreshView(latestState)
        default:
            break
        }
    }

    private func handleInteraction(_ event: TUIInputEvent, store: ApplicationStore) async {
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

    private func cancelInteraction(_ interaction: InteractionSnapshot, store: ApplicationStore) {
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

    private func executeCommand(_ input: String, store: ApplicationStore) async -> TUITranscriptEntry? {
        do {
            let result = try await store.executeCommand(input)
            guard !result.output.isEmpty else { return nil }
            return TUITranscriptEntry(kind: .result, text: result.output)
        } catch {
            return TUITranscriptEntry(kind: .error, text: String(describing: error), style: .error)
        }
    }

    private func executeLocalOrApplicationCommand(_ input: String, store: ApplicationStore) {
        let command = input.split(whereSeparator: \ .isWhitespace).first.map(String.init)?.lowercased()
        switch command {
        case "/quit":
            shouldQuit = true
        case "/clear":
            commandEntries.removeAll()
            view.transcript.entries.removeAll()
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
            let localNames = Self.localCommands.map { "/\($0.name)" }.joined(separator: "  ")
            let names = commands.map { "/\($0.name)" }.joined(separator: "  ")
            commandEntries.append(TUITranscriptEntry(kind: .result, text: "Local: \(localNames)\nAvailable: \(names)"))
            refreshView(latestState)
        case "/new":
            commandEntries.removeAll()
            committedEntryCache.removeAll()
            userToggledEntries.removeAll()
            view.transcript.entries.removeAll()
            enqueue { [weak self] in
                guard let self else { return }
                if let entry = await self.executeCommand(input, store: store) {
                    await self.publishCommandResult(entry)
                }
            }
        case "/model", "/m":
            let parts = input.split(whereSeparator: \ .isWhitespace).map(String.init)
            if parts.count == 1 {
                openModelPicker()
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
        uiEventContinuation?.yield(.commandResult(entry))
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
                    let hasSubs = hasSubcommands(command.name)
                    let completionValue = hasSubs ? "/\(command.name) " : "/\(command.name)"
                    return TUICompletionItem(value: completionValue, label: "/\(command.name)", detail: command.description, kind: .command)
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

    private func hasSubcommands(_ commandName: String) -> Bool {
        let name = commandName.lowercased()
        if ["permissions", "permission", "mode", "connect", "resume"].contains(name) {
            return true
        }
        if let cmd = allCommands.first(where: { $0.name.lowercased() == name || $0.aliases.contains(name) }) {
            return cmd.argumentSchema.contains("|")
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
                rawOptions = [
                    ("deepseek-v4-flash", "deepseek-v4-flash", "DeepSeek Flash 快速模型"),
                    ("deepseek-chat", "deepseek-chat", "DeepSeek V3 通用对话模型"),
                    ("deepseek-reasoner", "deepseek-reasoner", "DeepSeek R1 深度推理模型"),
                    ("claude-3-5-sonnet", "claude-3-5-sonnet", "Anthropic Claude 3.5 Sonnet"),
                    ("gpt-4o", "gpt-4o", "OpenAI GPT-4o")
                ]
            }
        case "resume":
            let currentCwd = FileManager.default.currentDirectoryPath
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MM-dd HH:mm"
            rawOptions = latestState.sessionCatalog.map { s in
                let isCurrent = (s.workingDirectory == currentCwd)
                let dirName = URL(fileURLWithPath: s.workingDirectory ?? currentCwd).lastPathComponent
                let dirTag = isCurrent ? "[当前] " : "[\(dirName)] "
                let timeStr = dateFormatter.string(from: s.updatedAt)
                let shortID = String(s.sessionID.rawValue.prefix(8))
                let msgs = "\(s.messageCount)条消息"
                let label = "\(dirTag)\(shortID) · \(timeStr) (\(msgs))"
                let detail = "\(s.title ?? "未命名") · \(s.workingDirectory ?? "")"
                return (s.sessionID.rawValue, label, detail)
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

    private func refreshView(_ state: ApplicationState) {
        animationNow = animationClock.now
        if activeInteractionID != state.activeInteraction?.interactionID {
            activeInteractionID = state.activeInteraction?.interactionID
            hitlSelectedOption = 0
            if state.activeInteraction != nil { view.composer.clear() }
        }
        if state.activeSessionID != latestState.activeSessionID {
            commandEntries.removeAll()
            committedEntryCache.removeAll(keepingCapacity: true)
            activityStartedAt.removeAll(keepingCapacity: true)
            activityFinishedDuration.removeAll(keepingCapacity: true)
            userToggledEntries.removeAll(keepingCapacity: true)
        }
        let yoloPrefix = options.isYoloMode ? "⚡ YOLO · " : ""
        view.header.subtitle = "\(yoloPrefix)\(state.activeSessionState?.title ?? state.connectionState.status.rawValue)"
        view.statusLine.text = statusText(state)

        let session = state.activeSessionState
        let nodes = session?.timelineNodes ?? []

        var entries: [TUITranscriptEntry] = []
        entries.reserveCapacity(nodes.count + commandEntries.count + 1)

        var hasActiveStreamingNode = false
        for node in nodes {
            if case .runTerminal = node.kind {
                // 内部生命周期元数据（如 Run · completed），不应作为消息暴露给用户
                continue
            }
            let isMutable: Bool
            switch node.kind {
            case let .message(msg):
                isMutable = msg.isStreaming
                if msg.isStreaming { hasActiveStreamingNode = true }
            case let .thinking(th):
                isMutable = th.isStreaming || !th.isComplete
                if th.isStreaming || !th.isComplete { hasActiveStreamingNode = true }
            case let .tool(tl):
                isMutable = [.requested, .waitingPermission, .scheduled, .running].contains(tl.phase)
                if isMutable { hasActiveStreamingNode = true }
            case .interaction, .subagent, .error, .runTerminal:
                isMutable = false
            }

            if !isMutable, let cached = committedEntryCache[node.id] {
                entries.append(cached)
            } else if let rendered = renderEntry(node) {
                if !isMutable {
                    committedEntryCache[node.id] = rendered
                }
                entries.append(rendered)
            }
        }

        let isRateLimited = state.status == .rateLimited || state.activeSessionState?.status == .rateLimited
        let isWaitingForProvider = !hasActiveStreamingNode && isActive(state) && !nodes.isEmpty && (
            state.status == .waitingForProvider ||
            state.activeSessionState?.status == .waitingForProvider ||
            isRateLimited ||
            (state.status == .ready && (state.activeSessionState?.activeRootRunID != nil || (state.activeSessionState?.queuedTurns.count ?? 0) > 0))
        )

        if isWaitingForProvider {
            if waitingStartedAt == nil { waitingStartedAt = animationNow }
            let elapsed = Int(waitingStartedAt!.duration(to: animationNow).components.seconds)
            let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            let spinnerChar = spinnerFrames[spinnerIndex % spinnerFrames.count]
            let modelID = state.currentModelID ?? "model"
            let waitingText: String
            if isRateLimited {
                waitingText = "\(spinnerChar) 上游限流中 (429)，正在等待恢复重试 (\(elapsed)s)..."
            } else if elapsed >= 8 {
                waitingText = "\(spinnerChar) Waiting for \(modelID) (\(elapsed)s)... (上游响应较慢或限流重试中)"
            } else {
                waitingText = "\(spinnerChar) Waiting for \(modelID) (\(elapsed)s)..."
            }
            entries.append(TUITranscriptEntry(
                id: "__waiting_for_provider__",
                kind: .thinking,
                text: waitingText,
                style: .accent,
                collapsed: false,
                timestamp: Date()
            ))
        } else if hasActiveStreamingNode || !isActive(state) {
            waitingStartedAt = nil
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

        view.transcript.replace(allEntries)
        if view.transcript.followsBottom {
            view.transcript.scrollToBottom()
        }
        latestState = state

        let isHero = isHeroEmptyState(state)
        if isHero {
            let prefs = UserPreferencesStore.shared.load()
            let mode = state.activeSessionState?.mode.displayName ?? state.nextTurnMode?.displayName ?? "Build"
            let model = state.currentModelID ?? prefs.lastModelID ?? "deepseek-v4-flash"
            let provider: String = {
                if let slashIdx = model.firstIndex(of: "/") {
                    return String(model[..<slashIdx]).uppercased()
                }
                return model.lowercased().contains("deepseek") ? "DeepSeek" : "Provider"
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
        } else {
            view.heroConfig = nil
            view.sidebarModel = buildSidebarModel(from: state)
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

        // 2. 三级缓存用量 (L1, L2, L3)
        let l1Capacity = 220_000
        let l2Capacity = 350_000
        let l3Capacity = 456_576
        let l1Used = session?.contextState?.l1Tokens ?? 0
        let l2Used = session?.contextState?.l2Tokens ?? 0
        let l3Used = session?.contextState?.l3Tokens ?? 0
        let cacheLayers = [
            TUISidebarModel.CacheLayer(name: "L1", usedTokens: l1Used, capacityTokens: l1Capacity),
            TUISidebarModel.CacheLayer(name: "L2", usedTokens: l2Used, capacityTokens: l2Capacity),
            TUISidebarModel.CacheLayer(name: "L3", usedTokens: l3Used, capacityTokens: l3Capacity)
        ]

        // 从 timelineNodes 动态提取运行时失败或不可用的 MCP 服务
        let nodes = session?.timelineNodes ?? []
        for node in nodes {
            if case let .tool(tl) = node.kind, (tl.phase == .failed || tl.result?.success == false || tl.result?.error != nil) {
                let toolName = tl.toolName
                let content = (tl.result?.summary ?? "") + " " + (tl.result?.preview ?? "") + " " + (tl.result?.error?.message ?? "")
                for ext in state.extensions where ext.kind == .mcp {
                    if toolName.contains(ext.id) || content.contains(ext.id) || content.contains("mcpServerUnavailable") {
                        if content.contains(ext.id) || toolName.hasPrefix("mcp_\(ext.id)") || toolName.contains(ext.id) {
                            failedMCPServers.insert(ext.id)
                        }
                    }
                }
            }
        }

        // 3. 激活的 MCP 具体的名字以及激活状态
        let mcpExtensions = state.extensions.filter { $0.kind == .mcp && $0.enabled }
        let mcpItems: [TUISidebarModel.MCPItem] = mcpExtensions.map { ext in
            let stateStr = ext.lifecycleState.lowercased()
            let isFailed = failedMCPServers.contains(ext.id) || stateStr.contains("err") || stateStr.contains("fail") || stateStr.contains("unavail")
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

        // 4. Agent 的 tasks 显示区域 (从 TodoStore、workflows、timeline 汇聚)
        var taskItems: [TUISidebarModel.TaskItem] = []
        let sessionKey = session?.sessionID.rawValue ?? state.activeSessionID?.rawValue ?? "default"

        let storedTodos = TodoStore.shared.getTodos(for: sessionKey)
        for todo in storedTodos {
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

        if taskItems.isEmpty, let nodes = session?.timelineNodes {
            for node in nodes.reversed() {
                if case let .message(msg) = node.kind, msg.role == .assistant, msg.content.contains("- [") {
                    let lines = msg.content.components(separatedBy: .newlines)
                    for line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("- [ ] ") {
                            let title = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            if !title.isEmpty && !taskItems.contains(where: { $0.title == title }) {
                                taskItems.append(TUISidebarModel.TaskItem(id: "md-\(taskItems.count)", title: title, status: .pending))
                            }
                        } else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                            let title = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            if !title.isEmpty && !taskItems.contains(where: { $0.title == title }) {
                                taskItems.append(TUISidebarModel.TaskItem(id: "md-\(taskItems.count)", title: title, status: .completed))
                            }
                        } else if trimmed.hasPrefix("- [-] ") {
                            let title = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            if !title.isEmpty && !taskItems.contains(where: { $0.title == title }) {
                                taskItems.append(TUISidebarModel.TaskItem(id: "md-\(taskItems.count)", title: title, status: .failed))
                            }
                        }
                    }
                    if !taskItems.isEmpty { break }
                }
            }
        }

        if taskItems.isEmpty, let activeIDs = session?.activeToolCallIDs, !activeIDs.isEmpty {
            for id in activeIDs {
                let toolName = session?.toolNodes[id]?.toolName ?? "工具"
                taskItems.append(TUISidebarModel.TaskItem(id: id.rawValue, title: "运行工具: \(toolName)", status: .inProgress))
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
        let hasActiveWork = state.activeSessionState?.activeTurnID != nil || state.activeSessionState?.activeRootRunID != nil
        let isBusyWorking = [.thinking, .waitingForProvider, .runningTool, .runningSubagents].contains(state.status)
        let hasInteraction = state.activeInteraction != nil
        return hasTimeline || hasActiveWork || isBusyWorking || hasInteraction
    }

    private func isHeroEmptyState(_ state: ApplicationState) -> Bool {
        return !hasAgentStartedWork(state)
    }

    private func animationTick(_ tick: TUIAnimationTick) {
        guard isActive else { return }
        animationNow = tick.timestamp
        spinnerIndex = Int(tick.sequence % 10)
        frameScheduler.markDirty(.animation)
    }

    private func refreshWaitingIndicator() {
        guard let started = waitingStartedAt, view.transcript.entries.last?.id == "__waiting_for_provider__" else { return }
        let elapsed = Int(started.duration(to: animationNow).components.seconds)
        let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let spinnerChar = spinnerFrames[spinnerIndex % spinnerFrames.count]
        let modelID = latestState.currentModelID ?? "model"
        let isRateLimited = latestState.status == .rateLimited || latestState.activeSessionState?.status == .rateLimited
        let text: String
        if isRateLimited {
            text = "\(spinnerChar) 上游限流中 (429)，正在等待恢复重试 (\(elapsed)s)..."
        } else if elapsed >= 8 {
            text = "\(spinnerChar) Waiting for \(modelID) (\(elapsed)s)... (上游响应较慢或限流重试中)"
        } else {
            text = "\(spinnerChar) Waiting for \(modelID) (\(elapsed)s)..."
        }
        view.transcript.updateLast(text)
    }

    private func render() {
        renderCount += 1
        if renderCount <= 5 { debug("render.begin count=\(renderCount)") }
        StreamingLatencyTracker.shared.record("frame-\(renderCount)", stage: .frameScheduled)
        var frame = view.render(size: terminal.size, overlay: overlayModel())
        if let sel = selectionRect {
            frame.highlightSelection(sel)
        }
        lastRenderedFrame = frame
        terminal.render(frame)
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
            lines.append(TUIStyledLine("  No matching models".padding(toLength: innerWidth, withPad: " ", startingAt: 0), style: .modalItemDim))
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

    private func statusText(_ state: ApplicationState) -> String {
        let feedback = copyFeedback.map { "  \($0)" } ?? ""
        if isHeroEmptyState(state) {
            let workspace = state.currentWorkspace?.rootPath.split(separator: "/").last.map(String.init)
                ?? FileManager.default.currentDirectoryPath.split(separator: "/").last.map(String.init)
                ?? "LingXiAgent"
            let mcpCount = state.activeMCPCount
            let skillCount = state.activeSkillCount
            return "📂 \(workspace)  ·  ● \(mcpCount) 激活 MCP  ·  \(skillCount) 激活 Skills\(feedback)"
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
        if isRateLimited {
            baseStatus = "Rate limited (retrying)\(waitingElapsedText)"
        } else if state.status == .ready && (hasActiveWork || queuedCount > 0) && !hasActiveError {
            baseStatus = "Waiting for provider\(waitingElapsedText)"
        } else if state.status == .waitingForProvider {
            baseStatus = "Waiting for provider\(waitingElapsedText)"
        } else {
            baseStatus = statusLabel(state.status)
        }
        let status = "\(baseStatus)\(queuedSuffix)"
        let model = state.currentModelID ?? "no model"
        let effort = state.effectiveReasoningEffort.rawValue
        let modelWithEffort = "\(model) (\(effort))"
        let workspace = state.currentWorkspace?.rootPath.split(separator: "/").last.map(String.init) ?? "cwd"
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
        let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let spinner = isActive(state) ? "\(spinnerFrames[spinnerIndex % spinnerFrames.count]) " : ""
        return "\(spinner)\(status)  ·  \(modelWithEffort)  ·  \(workspace)  ·  \(mode)  ·  \(permissions)\(feedback)"
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

    private func cycleMode(store: ApplicationStore) async {
        let current = latestState.activeSessionState?.mode ?? latestState.nextTurnMode ?? .build
        let nextMode = current.next
        await store.dispatch(.setMode(nextMode))
    }

    private func cycleReasoningEffort(store: ApplicationStore) async {
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
        if let ft = metrics?.firstTokenMs, ft > 0 {
            firstTokenStr = ft >= 1000 ? String(format: "%.1fs", ft / 1000.0) : "\(Int(ft))ms"
        } else if let ms = metrics?.durationMs, ms > 200 {
            firstTokenStr = "\(Int(ms * 0.25))ms"
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

    private func renderEntry(_ node: TimelineNode) -> TUITranscriptEntry? {
        let id = node.id.rawValue
        switch node.kind {
        case let .message(message):
            let kind: TUITranscriptKind = message.role == .user ? .user : .assistant
            var content = message.content
            if message.role == .assistant && !message.isStreaming && !content.isEmpty {
                let params = formatSessionParams(node: node, message: message)
                content += "\n\n" + params
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
            let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            let marker = isStreaming ? "\(spinnerFrames[spinnerIndex % spinnerFrames.count]) " : "• "
            let firstLine = isStreaming ? "Thinking..." : "Thought for \(durationText)"
            let text = "\(marker)\(firstLine)\n\(contentBody)"
            let isCollapsed = userToggledEntries[id] ?? (!isStreaming && thinking.isComplete)
            return TUITranscriptEntry(id: id, kind: .thinking, text: text, style: .dim, collapsed: isCollapsed, timestamp: node.timestamp)
        case let .tool(tool):
            let active = [.requested, .waitingPermission, .scheduled, .running].contains(tool.phase)
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

    private func formatModernToolCall(tool: ToolNode, id: String, active: Bool, timestamp: Date) -> TUITranscriptEntry {
        let isError = tool.phase == .failed || tool.result?.success == false || tool.result?.error != nil
        let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let dotMarker = active ? "\(spinnerFrames[spinnerIndex % spinnerFrames.count]) " : "• "

        let argsDict: [String: Any] = (tool.argumentsJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]

        var lines: [String] = []
        let toolName = tool.toolName

        if toolName == "run_command" || toolName == "bash" || toolName == "shell" || toolName == "exec" {
            let command = (argsDict["CommandLine"] as? String) ?? (argsDict["command"] as? String) ?? tool.argumentsJSON
            lines.append("\(dotMarker)Ran \(command)")

            let rawOutput = [tool.stdout, tool.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            if rawOutput.isEmpty {
                if let summary = tool.result?.summary, !summary.isEmpty {
                    lines.append("  └ \(summary)")
                } else {
                    lines.append("  └ (no output)")
                }
            } else {
                let outLines = rawOutput.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if outLines.count <= 6 {
                    for (i, l) in outLines.enumerated() {
                        lines.append(i == 0 ? "  └ \(l)" : "    \(l)")
                    }
                } else {
                    lines.append("  └ \(outLines[0])")
                    lines.append("    \(outLines[1])")
                    let collapsedCount = outLines.count - 4
                    lines.append("    ... +\(collapsedCount) lines (ctrl + t to view transcript)")
                    lines.append("    \(outLines[outLines.count - 2])")
                    lines.append("    \(outLines[outLines.count - 1])")
                }
            }
        } else if toolName == "view_file" || toolName == "read_file" {
            lines.append("\(dotMarker)Explored")
            let path = (argsDict["AbsolutePath"] as? String) ?? (argsDict["path"] as? String) ?? (argsDict["TargetFile"] as? String) ?? ""
            let fileName = path.split(separator: "/").last.map(String.init) ?? path
            lines.append("  └ Read \(fileName.isEmpty ? "file" : fileName)")
        } else if toolName == "grep_search" || toolName == "search_code" {
            lines.append("\(dotMarker)Explored")
            let query = (argsDict["Query"] as? String) ?? (argsDict["query"] as? String) ?? ""
            let path = (argsDict["SearchPath"] as? String) ?? ""
            let shortPath = path.split(separator: "/").last.map(String.init) ?? "workspace"
            lines.append("  └ Search \(query) in \(shortPath)")
        } else if toolName == "find_by_name" {
            lines.append("\(dotMarker)Explored")
            let pattern = (argsDict["Pattern"] as? String) ?? ""
            let dir = (argsDict["SearchDirectory"] as? String) ?? ""
            let shortDir = dir.split(separator: "/").last.map(String.init) ?? "workspace"
            lines.append("  └ Find \(pattern) in \(shortDir)")
        } else if toolName == "replace_file_content" || toolName == "write_to_file" {
            let path = (argsDict["TargetFile"] as? String) ?? (argsDict["path"] as? String) ?? ""
            let shortPath = path.split(separator: "/").last.map(String.init) ?? path
            lines.append("\(dotMarker)Edit(\(shortPath))")

            if toolName == "replace_file_content" {
                let target = (argsDict["TargetContent"] as? String) ?? ""
                let repl = (argsDict["ReplacementContent"] as? String) ?? ""
                let targetLines = target.split(separator: "\n", omittingEmptySubsequences: false).count
                let replLines = repl.split(separator: "\n", omittingEmptySubsequences: false).count
                lines.append("  └ +\(replLines) / -\(targetLines) lines")
            } else {
                let code = (argsDict["CodeContent"] as? String) ?? (argsDict["content"] as? String) ?? ""
                let count = code.split(separator: "\n", omittingEmptySubsequences: false).count
                lines.append("  └ +\(count) lines")
            }
        } else {
            lines.append("\(dotMarker)Called")
            let cleanSummary = argumentSummary(tool.argumentsJSON, toolName: tool.toolName)
            lines.append("  └ \(tool.toolName)(\(cleanSummary))")
            if let result = tool.result {
                let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let isMetaTool = toolName == "load_tool" || toolName == "todo"
                if !summary.isEmpty {
                    lines.append("    \(summary)")
                } else if !isMetaTool, let preview = result.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
                    let isRawJsonMeta = (preview.hasPrefix("{") || preview.hasPrefix("[")) && (preview.contains("\"status\"") || preview.contains("\"provider_name\"") || preview.contains("\"availability\""))
                    if !isRawJsonMeta || isError {
                        let previewLines = preview.split(separator: "\n", omittingEmptySubsequences: false).prefix(3)
                        for pl in previewLines {
                            lines.append("    \(pl)")
                        }
                    }
                }
            }
        }

        let entryStyle: TUIStyle = isError ? .error : (active ? .accent : .normal)
        let isCollapsed = userToggledEntries[id] ?? false
        return TUITranscriptEntry(id: id, kind: .toolCall, text: lines.joined(separator: "\n"), style: entryStyle, collapsed: isCollapsed, timestamp: timestamp)
    }
}
