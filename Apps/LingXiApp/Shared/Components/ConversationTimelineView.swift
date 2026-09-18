import SwiftUI

public struct ConversationTimelineView: View {
    @ObservedObject public var model: ConversationPresentationModel

    public init(model: ConversationPresentationModel) {
        self.model = model
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    if model.items.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 32))
                                .foregroundColor(LingXiGlass.Palette.foxOrange)
                            Text("Ready to co-create with LingXi")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(LingXiGlass.Palette.textSecondary)
                            Text("Select a scenario or type a request below.")
                                .font(.system(size: 12))
                                .foregroundColor(LingXiGlass.Palette.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    }

                    ForEach(model.items) { item in
                        timelineNode(for: item)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .padding(.bottom, 90) // 避开悬浮输入栏
            }
            .onChange(of: model.items.count) { _ in
                if let lastID = model.items.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func timelineNode(for item: TimelineItemPresentation) -> some View {
        switch item.kind {
        case .user(let content, let attachments):
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(content)
                        .font(.system(size: 14))
                        .foregroundColor(LingXiGlass.Palette.textPrimary)

                    if !attachments.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(attachments) { att in
                                HStack(spacing: 4) {
                                    Image(systemName: att.thumbnailSymbol)
                                        .font(.system(size: 10))
                                    Text(att.filename)
                                        .font(.system(size: 11, weight: .medium))
                                    Text("(\(att.formattedSize))")
                                        .font(.system(size: 9))
                                        .foregroundColor(LingXiGlass.Palette.textTertiary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .lingXiGlass(tier: .card, cornerRadius: 6)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .lingXiGlass(
                    tier: .card,
                    cornerRadius: 14,
                    ambientColor: LingXiGlass.Palette.neonPurple
                )
            }

        case .thinking(let content, let isExpanded):
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile")
                            .foregroundColor(LingXiGlass.Palette.cyberCyan)
                            .font(.system(size: 11))
                        Text("Thinking")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(LingXiGlass.Palette.textSecondary)
                    }
                    Text(content)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(LingXiGlass.Palette.textTertiary)
                        .lineLimit(isExpanded ? nil : 3)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lingXiGlass(tier: .card, cornerRadius: 10)
                Spacer(minLength: 40)
            }

        case .tool(_, let toolName, let summary, let status):
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(status == "success" ? LingXiGlass.Palette.statusSuccess :
                                status == "failed" ? LingXiGlass.Palette.statusDanger :
                                LingXiGlass.Palette.statusWarning)
                        .frame(width: 8, height: 8)
                    Text(toolName)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(LingXiGlass.Palette.cyberCyan)
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundColor(LingXiGlass.Palette.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .lingXiGlass(tier: .card, cornerRadius: 8)
                Spacer(minLength: 40)
            }

        case .assistant(let content, let isStreaming):
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("✦ LingXi")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(LingXiGlass.Palette.foxOrange)
                        if isStreaming {
                            Circle()
                                .fill(LingXiGlass.Palette.cyberCyan)
                                .frame(width: 6, height: 6)
                        }
                    }
                    Text(content)
                        .font(.system(size: 14))
                        .foregroundColor(LingXiGlass.Palette.textPrimary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .lingXiGlass(tier: .card, cornerRadius: 14)
                Spacer(minLength: 40)
            }

        case .terminal(let title, let isSuccess, let message):
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(isSuccess ? LingXiGlass.Palette.statusSuccess : LingXiGlass.Palette.statusDanger)
                        Text(title)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(LingXiGlass.Palette.textPrimary)
                    }
                    Text(message)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(LingXiGlass.Palette.textSecondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lingXiGlass(tier: .card, cornerRadius: 10, ambientColor: isSuccess ? nil : LingXiGlass.Palette.statusDanger)
            }
        }
    }
}
