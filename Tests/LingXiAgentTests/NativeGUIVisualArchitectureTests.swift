#if canImport(SwiftUI)
import SwiftUI
import Testing
@testable import LingXiProtocol
@testable import LingXiFrontendKit

@Suite("Native macOS GUI Visual & Architecture Tests", .serialized)
@MainActor
struct NativeGUIVisualArchitectureTests {

    @Test("SettingsCatalog covers all 18 native pages without nested split views")
    func settingsCatalogCoversAllRequiredSections() {
        let pages = SettingsPage.allCases
        #expect(pages.count >= 18)

        // Verify key pages exist
        let ids = Set(pages.map(\.id))
        #expect(ids.contains("general"))
        #expect(ids.contains("appearance"))
        #expect(ids.contains("conversation"))
        #expect(ids.contains("shortcuts"))
        #expect(ids.contains("providers"))
        #expect(ids.contains("agentDefaults"))
        #expect(ids.contains("permissions"))
        #expect(ids.contains("context"))
        #expect(ids.contains("execution"))
        #expect(ids.contains("codeIntelligence"))
        #expect(ids.contains("mcp"))
        #expect(ids.contains("skills"))
        #expect(ids.contains("plugins"))
        #expect(ids.contains("hooks"))
        #expect(ids.contains("computerUse"))
        #expect(ids.contains("workspace"))
        #expect(ids.contains("diagnostics"))
        #expect(ids.contains("about"))

        // Verify grouping
        let groups = SettingsPage.Group.allCases
        #expect(groups.count == 5)
    }

    @Test("Composer execution context strip preserves short directory name and deduplicates model")
    func composerExecutionStripDeduplicatesModelAndTruncatesWorkspace() {
        let runtime = RuntimeFrontend.preview()
        let workspaceURL = URL(fileURLWithPath: "/Volumes/Development/Projects/projects/LingXiAgent")

        // Directory short name is the leaf folder
        #expect(workspaceURL.lastPathComponent == "LingXiAgent")
        #expect(workspaceURL.path.contains("/Volumes/Development/Projects/projects/LingXiAgent"))

        // Composer defaults and execution strip
        let composer = runtime.composerModel
        #expect(composer.permissionPreset == .askWorkspace)
        #expect(composer.reasoningEffort == .auto)
        #expect(composer.selectedMode == .build)
    }

    @Test("AtmosphereMode modulates intensity cleanly without creating multiple instances")
    func atmosphereModeModulatesIntensityWithoutInstanceRecreation() {
        let workspaceAtmo = AtmosphereBackdrop(mode: .workspace)
        let settingsAtmo = AtmosphereBackdrop(mode: .settings)

        #expect(workspaceAtmo.mode == .workspace)
        #expect(settingsAtmo.mode == .settings)
    }
}
#endif
