#if canImport(SwiftUI)
import Foundation
import SwiftUI
import AppKit
import Testing
@testable import LingXiFrontendKit
import LingXiProtocol

/// The expanded thinking card, and the reasoning menu for toggle-only models.
@MainActor
@Suite("Thinking card and reasoning menu presentation")
struct ThinkingCardPresentationTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - 22. Renders as one card

    @Test("the expanded card renders at a fixed width with text and copy control in one container")
    func cardRenders() throws {
        let card = ThinkingDetailCard(content: "Line one of reasoning.\nLine two.")
            .frame(width: 520)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        #expect(image.size.width == 520)
        #expect(image.size.height > 40, "正文与复制按钮应在同一卡片内纵向排列：\(image.size)")
    }

    // MARK: - 23. Symmetric margins

    @Test("left and right margins are the same value")
    func symmetricMargins() throws {
        #expect(ThinkingDetailCard.trailingMargin == LingXiMetrics.detailIndent,
                "卡片右侧内缩必须等于 EventRow 的左侧 detailIndent")
        let views = try Self.source("Apps/macOS/FrontendKit/Components/TimelineViews.swift")
        let row = try #require(views.range(of: "struct ThinkingRow").map { String(views[$0.lowerBound...].prefix(2_000)) })
        #expect(row.contains("detailTrailingInset: ThinkingDetailCard.trailingMargin"))
        #expect(!row.contains(".lxInsetBlock()"), "ThinkingRow 不得在 detailIndent 之外再叠一层内缩")
    }

    // MARK: - 24. Copy stays wired, inside the card

    @Test("the copy control copies the reasoning and sits inside the card container")
    func copyWiring() throws {
        let views = try Self.source("Apps/macOS/FrontendKit/Components/TimelineViews.swift")
        let card = try #require(views.range(of: "struct ThinkingDetailCard").map { String(views[$0.lowerBound...].prefix(1_600)) })
        #expect(card.contains("LXCopyButton(content, label: \"复制思考\")"))
        // The inset applies to the VStack holding both, not to the text alone.
        let copyIndex = try #require(card.range(of: "LXCopyButton")?.lowerBound)
        let insetIndex = try #require(card.range(of: ".lxInsetBlock()")?.lowerBound)
        #expect(copyIndex < insetIndex, "复制按钮必须在 inset 容器内部")
    }

    // MARK: - 25. Type token

    @Test("reasoning text uses the 15pt token with 23pt line height; messages stay 16pt")
    func typeTokens() {
        #expect(LXType.thinkingBodySize == 15)
        let font = NSFont.systemFont(ofSize: LXType.thinkingBodySize, weight: .medium)
        let lineHeight = font.ascender - font.descender + font.leading + LXType.Leading.thinking
        #expect((22...23.5).contains(lineHeight), "行高应约 22～23pt，实测 \(lineHeight)")
        let tokens = (try? Self.source("Apps/macOS/FrontendKit/DesignSystem/Tokens.swift")) ?? ""
        #expect(tokens.contains("message 16 → 26"), "assistant 正文 16pt 保持不变")
    }

    // MARK: - Reasoning menu for a toggle model

    @Test("a toggle-only model offers exactly Off and On")
    func toggleReasoningMenu() {
        let composer = ComposerModel()
        composer.models = [ProviderModelInfo(
            id: "lmstudio/qwen3.8-9b-q6k", providerID: "lmstudio", modelID: "qwen3.8-9b-q6k",
            displayName: "qwen", contextWindow: 65_536, maxOutputTokens: 8_192, reasoning: true, configured: true,
            reasoningCapability: ReasoningCapability(mode: .toggle, supportedEfforts: [.off, .auto], defaultEffort: .auto),
            modelMaximumContextWindow: 262_144, runtimeContextWindow: 65_536)]
        composer.selectedModelID = "lmstudio/qwen3.8-9b-q6k"
        #expect(composer.reasoningMenuLevels == [.off, .auto])
        #expect(composer.reasoningMenuLevels.map(composer.reasoningLabel) == ["Off", "On"])
        #expect(composer.reasoningLabel(.high) == "On", "开关型模型不得显示 High")
    }

    @Test("a model without a toggle capability keeps the full menu")
    func dialReasoningMenu() {
        let composer = ComposerModel()
        composer.models = [ProviderModelInfo(id: "openai/gpt", providerID: "openai", modelID: "gpt", displayName: "gpt",
                                             contextWindow: 128_000, maxOutputTokens: 8_192, reasoning: true, configured: true)]
        composer.selectedModelID = "openai/gpt"
        #expect(composer.reasoningMenuLevels == ReasoningEffortLevel.allCases)
        #expect(composer.reasoningLabel(.med) == "Med")
    }
}
#endif
