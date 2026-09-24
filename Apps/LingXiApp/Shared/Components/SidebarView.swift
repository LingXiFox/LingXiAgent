#if canImport(SwiftUI)
import SwiftUI

/// macOS 原生侧边栏组件 (NavigationSplitView 侧栏)
/// 遵循 macOS HIG：工作区 Header、项目目录折叠树、会话与任务列表，无底部冗余设置项
public struct SidebarView: View {
    @ObservedObject public var model: SidebarPresentationModel
    public var onNewSession: () -> Void
    public var onSelectSession: (String) -> Void
    public var onSelectTask: (String) -> Void

    public init(
        model: SidebarPresentationModel,
        onNewSession: @escaping () -> Void,
        onSelectSession: @escaping (String) -> Void,
        onSelectTask: @escaping (String) -> Void = { _ in }
    ) {
        self.model = model
        self.onNewSession = onNewSession
        self.onSelectSession = onSelectSession
        self.onSelectTask = onSelectTask
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Workspace Header
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundColor(LingXiTheme.accentColor)
                    .imageScale(.medium)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.workspace.name)
                        .font(.headline)
                        .lineLimit(1)
                    if let branch = model.workspace.gitBranch {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10))
                            Text(branch)
                                .font(.caption2)
                        }
                        .foregroundColor(LingXiTheme.secondaryText)
                    }
                }

                Spacer()

                Button(action: onNewSession) {
                    Image(systemName: "square.and.pencil")
                        .help("新建会话 (⌘N)")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Session & Task Tree
            List {
                ForEach(model.folders) { folder in
                    DisclosureGroup(isExpanded: .constant(true)) {
                        ForEach(folder.sessions) { session in
                            SessionRow(
                                session: session,
                                isSelected: model.selectedSessionID == session.id,
                                onSelect: { onSelectSession(session.id) },
                                onSelectTask: onSelectTask
                            )
                        }
                    } label: {
                        Label(folder.folderName, systemImage: "folder")
                            .font(.subheadline)
                            .foregroundColor(LingXiTheme.secondaryText)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct SessionRow: View {
    let session: SessionItemPresentation
    let isSelected: Bool
    let onSelect: () -> Void
    let onSelectTask: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(session.isActive ? LingXiTheme.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)

                    Text(session.title)
                        .font(.body)
                        .lineLimit(1)

                    Spacer()

                    Text(session.lastUpdated, style: .time)
                        .font(.caption2)
                        .foregroundColor(LingXiTheme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 附带展示该 Session 下的 Tasks
            if !session.tasks.isEmpty && isSelected {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(session.tasks) { task in
                        Button(action: { onSelectTask(task.taskID) }) {
                            HStack(spacing: 6) {
                                Image(systemName: "checklist")
                                    .font(.system(size: 10))
                                    .foregroundColor(LingXiTheme.accentColor)

                                Text(task.objective)
                                    .font(.caption)
                                    .lineLimit(1)

                                Spacer()

                                TaskStatusBadge(state: task.state)
                            }
                            .padding(.leading, 14)
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

public struct TaskStatusBadge: View {
    public let state: String

    public init(state: String) {
        self.state = state
    }

    public var body: some View {
        let (color, icon) = badgeAppearance(for: state)
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(state.capitalized)
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(color.opacity(0.15))
        .foregroundColor(color)
        .clipShape(Capsule())
    }

    private func badgeAppearance(for state: String) -> (Color, String) {
        switch state.lowercased() {
        case "running":
            return (LingXiTheme.accentColor, "play.circle.fill")
        case "completed":
            return (.green, "checkmark.circle.fill")
        case "paused":
            return (.orange, "pause.circle.fill")
        case "waiting":
            return (.yellow, "clock.fill")
        case "failed", "cancelled":
            return (.red, "xmark.circle.fill")
        default:
            return (.secondary, "circle")
        }
    }
}
#endif
