import Foundation
import Testing
@testable import LingXiCore
import LingXiProtocol

/// §14–§17 of the closure contract, checked against the sources that have to agree.
///
/// Settings drift is the quietest failure in this product: a key Core reads but no control writes
/// is invisible, a control that writes a value nobody reads looks finished, and a search result
/// pointing at a removed row is only noticed when someone clicks it. Each of those is a set
/// comparison, so each is compared rather than remembered.
@Suite("Settings closure", .serialized)
struct SettingsClosureTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    private let settingsFiles = ["SettingsAgentPages", "SettingsAppPages", "SettingsSystemPages",
                                        "SettingsProviderEditing", "SettingsMCPEditing", "SettingsControls",
                                        "SettingsWorkbench", "SettingsView", "SettingsStore"]

    private func settingsSources() throws -> String {
        var text = ""
        for name in settingsFiles {
            text += try source("Apps/macOS/FrontendKit/Settings/\(name).swift")
        }
        return text
    }

    // MARK: - §14 Core-adjustable keys must be reachable from Settings

    @Test("the config keys §14 named are declared and driven by a control")
    func namedKeysAreAdjustable() throws {
        let schema = try source("Sources/LingXiCore/Resources/Configuration/Schemas/config.schema.json")
        let keys = try source("Apps/macOS/FrontendKit/Settings/CoreConfigFile.swift")
        let pages = try settingsSources()

        let pairs: [(leaf: String, key: String, control: String)] = [
            ("preferredActiveTokens", "agent.preferredActiveTokens", "ConfigKeys.preferredActiveTokens"),
            ("pressureThreshold", "context.eCore.pressureThreshold", "ConfigKeys.eCorePressureThreshold"),
        ]
        for pair in pairs {
            let quoted = "\"" + pair.leaf + "\""
            #expect(schema.contains(quoted), "\(pair.key) 已不在 Core schema 里，这条检查要跟着改")
            // CoreConfigFile declares them as `static let preferredActiveTokens = ConfigKey(...)`;
            // the `ConfigKeys.` prefix only appears on the consumer side.
            let declaration = "static let " + pair.control.dropFirst("ConfigKeys.".count) + " = ConfigKey("
            #expect(keys.contains(declaration), "\(pair.key) 没有 ConfigKey 声明")
            #expect(pages.contains(pair.control), "\(pair.key) 有 ConfigKey 但没有任何控件引用它")
        }
    }

    /// Every key declared in the drift table must be used by a control, or it is a key the GUI
    /// knows about and shows nowhere — the `l3UseRemaining` case that sat unused for rounds.
    @Test("no declared ConfigKey is orphaned from every control")
    func declaredKeysAreUsed() throws {
        let keys = try source("Apps/macOS/FrontendKit/Settings/CoreConfigFile.swift")
        let pages = try settingsSources()
        var declared: [String] = []
        for line in keys.components(separatedBy: "\n") {
            guard let at = line.range(of: "static let ") else { continue }
            let name = String(line[at.upperBound...].prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
            if line.contains("= ConfigKey(") { declared.append(name) }
        }
        #expect(declared.count > 20, "ConfigKey 解析异常，只找到 \(declared.count) 个")
        let orphans = declared.filter { !pages.contains("ConfigKeys.\($0)") }
        #expect(orphans.isEmpty, "这些键声明了、进了漂移表，却没有任何控件写它：\(orphans.sorted())")
    }

    // MARK: - §14.3 the frozen heat semantics

    @Test("E-Core heat is described as recall ranking, never as eviction")
    func heatCopyMatchesArchitecture() throws {
        let pages = try settingsSources()
        #expect(!pages.contains("按访问热度决定上下文淘汰"),
                "热度文案又在说它决定淘汰——冻结架构里淘汰只由 P 侧 RetentionScore 决定")
        // The copy is a multi-line Swift string literal, so matching line by line would only see
        // the line containing 热度 and miss the disclaimer written on the next one.
        #expect(pages.contains("召回排序"), "热度文案应说明它用于 E-Core 召回排序")
        #expect(pages.contains("不参与 P-Core 淘汰") || pages.contains("不决定淘汰"),
                "热度文案必须明说它不参与 P-Core 淘汰")
    }

    // MARK: - §15 page requirements

    @Test("pages that render Core data declare the domains they need")
    func pageRequirementsAreDeclared() throws {
        let catalog = try source("Apps/macOS/FrontendKit/Settings/SettingsCatalog.swift")
        guard let at = catalog.range(of: "var needsCoreData") else {
            Issue.record("needsCoreData 不存在"); return
        }
        let body = String(catalog[at.lowerBound...])
        // Six pages used to answer `false` while displaying provider lists, effective policy,
        // workspace indexes, tool status, health and runtime info.
        for page in [".agentDefaults", ".context", ".codeIntelligence", ".computerUse",
                     ".diagnostics", ".general"] {
            let line = body.components(separatedBy: "\n").first { $0.contains(page + ":") }
            #expect(line != nil, "\(page) 未在 needsCoreData 里声明")
            #expect(line!.contains("return [."), "\(page) 显示实时 Core 数据却声明不需要")
        }
    }

    /// A settings search that jumps to a control that no longer exists is a dead control with an
    /// extra step. Both lists are read and compared rather than trusted.
    @Test("every settings search anchor resolves to a control that exists")
    func catalogAnchorsResolve() throws {
        let catalog = try source("Apps/macOS/FrontendKit/Settings/SettingsCatalog.swift")
        let anchors = Set(catalog.components(separatedBy: "\n").compactMap { line -> String? in
            guard let at = line.range(of: "anchor: \"") else { return nil }
            return String(line[at.upperBound...].prefix(while: { $0 != "\"" }))
        })
        #expect(anchors.count >= 10, "锚点解析异常，只找到 \(anchors.count) 个")
        let pages = try settingsSources()
        let declared = Set(pages.components(separatedBy: "\n").compactMap { line -> String? in
            guard let at = line.range(of: "settingsAnchor(\"") else { return nil }
            return String(line[at.upperBound...].prefix(while: { $0 != "\"" }))
        })
        let dangling = anchors.subtracting(declared)
        #expect(dangling.isEmpty, "搜索结果指向不存在的控件：\(dangling.sorted())")
    }

    // MARK: - §16 apply semantics

    @Test("a config write offers the action it asks for")
    func noticeOffersItsOwnAction() throws {
        let controls = try source("Apps/macOS/FrontendKit/Settings/SettingsControls.swift")
        let store = try source("Apps/macOS/FrontendKit/Settings/SettingsStore.swift")
        #expect(store.contains("pendingApply"), "写入没有声明生效方式")
        for action in ["重新加载 Core", "重启 Core"] {
            #expect(controls.contains(action), "提示条缺少「\(action)」按钮")
        }
        // The buttons must reach the existing paths rather than start a second one.
        #expect(store.contains("func reloadConfiguration"), "「重新加载 Core」没有接上既有 reload 路径")
        #expect(store.contains("func restartCore"), "「重启 Core」没有接上既有重启路径")
    }

    // MARK: - §17 no silent swallow on user actions

    @Test("user-initiated mutations do not swallow their errors")
    func userActionsReportFailure() throws {
        let gui = try source("Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift")
        let store = try source("Apps/macOS/FrontendKit/Settings/SettingsStore.swift")
        // The statement performing the action must not be wrapped in `try?`.
        for (needle, file) in [("client.task.finalize", gui),
                               ("backend.terminateBackgroundTask", gui),
                               ("client.credential.store", store)] {
            let lines = file.components(separatedBy: "\n").filter { $0.contains(needle) }
            #expect(!lines.isEmpty, "\(needle) 已不在源码里，这条检查要跟着改")
            for line in lines {
                #expect(!line.contains("try? await"),
                        "\(needle) 是用户显式动作，不允许 try? 吞错：\(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// §22 zero tolerance: nothing may ship that looks like a control and reaches nothing.
    ///
    /// 背景氛围 and 浮动面板材质 used to be two working-looking pickers whose values only ever
    /// landed in UserDefaults — `AtmosphereBackdrop` painted a constant gradient and
    /// `LXFloatingChrome` used a fixed fill, so choosing changed nothing on screen. They are
    /// removed rather than left. This is the tripwire: they may come back only with a reader.
    @Test("appearance pickers may not ship without something that reads them")
    func appearanceControlsHaveEffect() throws {
        let pages = try settingsSources()
        let designSystem = ["AppPreferences", "Atmosphere", "WallpaperStyle", "Components", "Surfaces", "Tokens"]
            .reduce(into: "") { partial, name in
                partial += (try? source("Apps/macOS/FrontendKit/DesignSystem/\(name).swift")) ?? ""
            }
        let keys = ["atmosphere", "panelMaterial"]
        for key in keys {
            // Match the control, not prose: the removal is explained in a comment that names
            // both settings, and a comment is not a picker.
            let advertised = pages.contains("Picker(\"背景氛围\"") || pages.contains("Picker(\"浮动面板材质\"")
            if advertised {
                #expect(designSystem.contains("LXPreferenceKey.\(key)"),
                        "外观页又在卖「\(key)」，但渲染层没有一处读它——这就是§22 的死控件")
            } else {
                #expect(!designSystem.contains("static let \(key) ="),
                        "选择器已经移除，这个没有读取者的偏好键也应一起删掉")
            }
        }
    }

    /// Every preference key the GUI defines must be referenced by something other than its own
    /// declaration, or it is a stored value with no behaviour attached.
    @Test("no preference key is defined and then never used")
    func preferenceKeysAreUsed() throws {
        let preferences = try source("Apps/macOS/FrontendKit/DesignSystem/AppPreferences.swift")
        var declared: [String] = []
        for line in preferences.components(separatedBy: "\n") {
            guard let at = line.range(of: "static let ") else { continue }
            let name = String(line[at.upperBound...].prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
            if line.contains("=") && line.contains("\"lx.") { declared.append(name) }
        }
        #expect(declared.count >= 4, "偏好键解析异常，只找到 \(declared.count) 个")
        var corpus = ""
        for url in try allSwiftFiles(under: "Apps/macOS") where !url.hasSuffix("AppPreferences.swift") {
            corpus += try source(url)
        }
        let unused = declared.filter { !corpus.contains("LXPreferenceKey.\($0)") }
        #expect(unused.isEmpty, "这些偏好键没有任何引用者：\(unused.sorted())")
    }

    private func allSwiftFiles(under directory: String) throws -> [String] {
        let base = Self.root.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { $0.path.replacingOccurrences(of: Self.root.path + "/", with: "") }
            .sorted()
    }
}
