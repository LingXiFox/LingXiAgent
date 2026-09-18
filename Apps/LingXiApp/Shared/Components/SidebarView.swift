import SwiftUI

public struct SidebarView: View {
    @ObservedObject public var model: SidebarPresentationModel
    public let runtime: FakeFrontendRuntime
    public let onSelectSession: (String) -> Void

    public init(
        model: SidebarPresentationModel,
        runtime: FakeFrontendRuntime,
        onSelectSession: @escaping (String) -> Void = { _ in }
    ) {
        self.model = model
        self.runtime = runtime
        self.onSelectSession = onSelectSession
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Workspace Header
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundColor(LingXiGlass.Palette.cyberCyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.workspace.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(LingXiGlass.Palette.textPrimary)
                    HStack(spacing: 4) {
                        Text(model.workspace.rootBadge.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(LingXiGlass.Palette.surfaceElevated)
                            .cornerRadius(4)
                            .foregroundColor(LingXiGlass.Palette.textTertiary)
                        if let branch = model.workspace.gitBranch {
                            Text("⌥ \(branch)")
                                .font(.system(size: 10))
                                .foregroundColor(LingXiGlass.Palette.textSecondary)
                        }
                    }
                }
                Spacer()
                Button(action: {}) {
                    Image(systemName: "square.and.pencil")
                        .foregroundColor(LingXiGlass.Palette.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .lingXiGlass(tier: .card, cornerRadius: 8)
            .padding(.horizontal, 10)
            .padding(.top, 10)

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 10)

            // Sessions List
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.sessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title)
                                    .font(.system(size: 13, weight: session.isActive ? .semibold : .regular))
                                    .foregroundColor(session.isActive ? LingXiGlass.Palette.textPrimary : LingXiGlass.Palette.textSecondary)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(session.mode.uppercased())
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(LingXiGlass.Palette.cyberCyan)
                                    Text("\(session.messageCount) msgs")
                                        .font(.system(size: 10))
                                        .foregroundColor(LingXiGlass.Palette.textTertiary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .lingXiGlass(
                            tier: .card,
                            cornerRadius: 8,
                            ambientColor: session.isActive ? LingXiGlass.Palette.neonPurple : nil
                        )
                        .onTapGesture {
                            model.selectedSessionID = session.id
                            onSelectSession(session.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer()

            // Fixture Scenario Selector (Phase 0 核心控制)
            VStack(alignment: .leading, spacing: 6) {
                Text("PHASE 0 FIXTURE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(LingXiGlass.Palette.textTertiary)

                Picker("", selection: Binding(
                    get: { runtime.currentScenario },
                    set: { runtime.switchScenario($0) }
                )) {
                    ForEach(GUIFixtureScenario.allCases) { sc in
                        Text(sc.rawValue).tag(sc)
                    }
                }
                .labelsHidden()
            }
            .padding(10)
            .lingXiGlass(tier: .panel, cornerRadius: 8)
            .padding(10)
        }
        .frame(minWidth: 220, idealWidth: 260)
        .lingXiGlass(tier: .panel, cornerRadius: 0)
    }
}
