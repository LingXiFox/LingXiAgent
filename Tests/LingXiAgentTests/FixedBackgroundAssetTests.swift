import Foundation
import Testing

/// The fixed-background freeze.
///
/// The backdrop stopped being a user preference and became a product visual asset: every text
/// colour, opacity, material, scrim, shadow and separator in this GUI was calibrated against one
/// specific backdrop, so a free choice of image made legibility accidental. These checks keep it
/// from drifting back — a removed picker reappearing, a workspace-relative path sneaking into a
/// runtime read, or "adapting to the new background" turning into a layout redesign.
///
/// Reads the sources rather than rendering: what is protected here is a structural rule, and a
/// structural rule is checked against the files that express it.
@Suite("Fixed background asset", .serialized)
struct FixedBackgroundAssetTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - §1 §2 packaged, not a path in the workspace

    @Test("the background ships inside the app bundle")
    func assetIsPackaged() throws {
        let url = Self.root.appendingPathComponent("Apps/macOS/FrontendKit/Resources/Background.jpg")
        #expect(FileManager.default.fileExists(atPath: url.path),
                "固定背景必须作为 FrontendKit 资源打包，而不是留在工作区目录里被运行时读取")
        let size = try #require((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize)
        #expect(size > 100_000, "背景资源只有 \(size) 字节，不像是主人提供的那张图")

        // Package.swift copies the whole Resources directory, so a new file needs no manifest
        // edit — but the rule has to stay there or the asset silently stops shipping.
        let package = try source("Package.swift")
        #expect(package.contains(".copy(\"Resources\")"),
                "LingXiFrontendKit 不再整目录拷贝 Resources，新增资产会被静默漏打包")
    }

    @Test("the backdrop resolves the image from the bundle, never a filesystem path")
    func noRuntimePathRead() throws {
        let backdrop = try source("Apps/macOS/FrontendKit/DesignSystem/WallpaperStyle.swift")
        #expect(backdrop.contains("Bundle.module.url(forResource:"), "背景必须从 Bundle 资源解析")
        #expect(!backdrop.contains("URL(fileURLWithPath:"),
                "运行时读取工作区或用户绝对路径，等于把产品视觉资产退回用户配置")
    }

    /// The owner's staging copy and the packaged copy must be the same pixels. `Picture/` is
    /// ignored in git, so this compares only when that directory is present locally.
    @Test("the packaged copy equals the owner's source asset, when it is on disk")
    func packagedCopyMatchesSource() throws {
        let stagedURL = Self.root.appendingPathComponent("Picture/background.JPG")
        guard FileManager.default.fileExists(atPath: stagedURL.path) else { return }
        let staged = try Data(contentsOf: stagedURL)
        let packaged = try Data(contentsOf: Self.root
            .appendingPathComponent("Apps/macOS/FrontendKit/Resources/Background.jpg"))
        #expect(staged == packaged, "主人换过源图，打包副本还是旧的——两处必须同源")
    }

    // MARK: - §4 §5 no picker, no legacy override

    @Test("no control lets a user change the background")
    func pickerIsGone() throws {
        var code = try settingsAndSceneSources()
        // Strip comments: a doc comment explaining the removal has to be allowed to name the
        // thing it removed, and that is not a control.
        code = code.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for needle in ["选择背景图片", "恢复内置背景", "chooseImage", "wallpaperPath",
                       "背景氛围", "浮动面板材质"] {
            #expect(!code.contains(needle),
                    "代码里又出现了「\(needle)」——背景已经不是用户配置项（§4）")
        }
        // `NSOpenPanel` is legitimate elsewhere — choosing a workspace directory is a real
        // feature — so the claim is scoped to the file that used to host the background picker.
        let wallpaperCode = try source("Apps/macOS/FrontendKit/DesignSystem/WallpaperStyle.swift")
            .components(separatedBy: "\n").filter { !isComment($0) }.joined(separator: "\n")
        #expect(!wallpaperCode.contains("NSOpenPanel"),
                "背景层里又出现了文件选择面板，等于把可配置背景带了回来")
    }

    private func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//")
    }

    @Test("the app no longer writes background preferences")
    func nothingWritesBackgroundPrefs() throws {
        let backdrop = try source("Apps/macOS/FrontendKit/DesignSystem/WallpaperStyle.swift")
        #expect(!backdrop.contains("UserDefaults.standard.set"), "固定背景不该再写任何用户偏好")
        #expect(!backdrop.contains("@AppStorage"), "背景不再是可持久化的用户选择")
    }

    // MARK: - §3 display behaviour, §11 accessibility, §12 fail loud

    @Test("the image is aspect-filled over the designed gradient, clipped by the window")
    func displayBehaviourIsFrozen() throws {
        let backdrop = try source("Apps/macOS/FrontendKit/DesignSystem/WallpaperStyle.swift")
        #expect(backdrop.contains(".scaledToFill()"), "保持宽高比填满，禁止拉伸变形")
        #expect(backdrop.contains(".clipped()"), "窗口 resize 时裁切而不是挤压")
        #expect(backdrop.contains("LinearGradient(colors: [Color(red: 0.10, green: 0.13"),
                "设计好的底层渐变被换掉了")
        let resourceNameDeclarations = backdrop.components(separatedBy: "static let resourceName").count - 1
        #expect(resourceNameDeclarations == 1,
                "出现第二个背景资源名（找到 \(resourceNameDeclarations) 个），等于把固定背景又变成可切换的")
    }

    /// Owner decision, recorded because background freeze §11 points the other way.
    ///
    /// §11 reads as "adjust the overlay, never swap the backdrop", which argues for keeping the
    /// photo and darkening the scrim. Both variants were rendered from the same colour maths and
    /// put in front of the Owner, who chose the original behaviour: under Reduce Transparency the
    /// photo and the scrim both come off, leaving the designed gradient. That is the more legible
    /// of the two and it is what this setting has always meant here. Pinned so a later pass
    /// "fixing §11" cannot silently repaint the app.
    @Test("reduce transparency takes the photo and scrim off, as the Owner ruled")
    func reduceTransparencyKeepsOriginalBehaviour() throws {
        let backdrop = try source("Apps/macOS/FrontendKit/DesignSystem/WallpaperStyle.swift")
        #expect(backdrop.contains("if !reduceTransparency { WallpaperScrim() }"),
                "遮罩不再受降低透明度控制——主人明确选定过这个行为，要改需重新确认")
        #expect(backdrop.contains("if let image, !reduceTransparency"),
                "照片在降低透明度时仍被绘制，属于已被否决的方案")
        #expect(!backdrop.contains("WallpaperScrim(reduceTransparency:"),
                "遮罩被改成了加深而不是撤掉")
    }

    @Test("a missing bundle asset fails loudly in debug and falls back in release")
    func missingAssetFailsLoud() throws {
        let backdrop = try source("Apps/macOS/FrontendKit/DesignSystem/WallpaperStyle.swift")
        #expect(backdrop.contains("#if DEBUG"), "开发/测试环境必须显式失败（§12）")
        #expect(backdrop.contains("fatalError"), "缺资源要 assertion，而不是静默兜底")
        #expect(backdrop.contains("#else") && backdrop.contains("return nil"),
                "生产环境回退到稳定底色")
    }

    // MARK: - §10 theme decoupling, §6 §13 no redesign

    @Test("theme selection cannot choose a different background")
    func themeDoesNotDriveBackground() throws {
        let backdrop = try source("Apps/macOS/FrontendKit/DesignSystem/WallpaperStyle.swift")
        #expect(!backdrop.contains("colorScheme"),
                "主题可以影响前景 UI token，切换背景图就是重新引入可配置背景（§10）")
    }

    /// The strongest constraint in the freeze: fixing the background authorises contrast tuning,
    /// not layout work. These landmarks must still be where they were.
    @Test("the background change did not touch the layout it was not allowed to touch")
    func layoutIsUntouched() throws {
        let workbench = try source("Apps/macOS/FrontendKit/Components/WarmWorkbench.swift")
        let rail = try source("Apps/macOS/FrontendKit/Components/WarmToolPane.swift")
        let hud = try source("Apps/macOS/FrontendKit/Components/AgentStatusHUD.swift")

        #expect(rail.contains("case .browser:") && rail.contains("case .git:") && rail.contains("case .terminal:"),
                "最右侧工具轨的 Browser / Terminal / Git 被改动了（§8）")
        #expect(workbench.contains("MainStageView(runtime: runtime)")
                && workbench.contains("AgentStatusHUD(runtime: runtime, compact: false)"),
                "三栏结构被改动了（§13）")
        for marker in ["Text(\"运行上下文\")", "contextChart", "metric(\"缓存命中\"", "metric(\"P-Core\""] {
            #expect(hud.contains(marker), "运行上下文卡片少了「\(marker)」——§7 禁止为适配背景改它")
        }
    }

    private func settingsAndSceneSources() throws -> String {
        var text = try source("Apps/macOS/FrontendKit/Settings/SettingsAppPages.swift")
        text += try source("Apps/macOS/FrontendKit/Frontend/LingXiWorkbenchScene.swift")
        text += try source("Apps/macOS/FrontendKit/Settings/SettingsCatalog.swift")
        text += try source("Apps/macOS/FrontendKit/DesignSystem/WallpaperStyle.swift")
        return text
    }
}
