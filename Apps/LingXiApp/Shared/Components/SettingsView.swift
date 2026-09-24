#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol


/// macOS 原生偏好设置视图 (Settings Scene)
/// 遵循 A6 规范：按 6 大主题分页，每页只放必要项；无硬编码模型名 (G15)
public struct SettingsView: View {
    @ObservedObject public var runtime: RuntimeFrontend

    public init(runtime: RuntimeFrontend) {
        self.runtime = runtime
    }

    public var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(0)

            ModelsProvidersSettingsTab()
                .tabItem { Label("模型与 Provider", systemImage: "cpu") }
                .tag(1)

            PermissionsSandboxSettingsTab()
                .tabItem { Label("权限与沙箱", systemImage: "shield.checkered") }
                .tag(2)

            MCPSettingsTab()
                .tabItem { Label("MCP 扩展", systemImage: "server.rack") }
                .tag(3)

            ShortcutsSettingsTab()
                .tabItem { Label("快捷键", systemImage: "keyboard") }
                .tag(4)

            AppearanceSettingsTab()
                .tabItem { Label("外观", systemImage: "paintpalette") }
                .tag(5)
        }
        .frame(width: 520, height: 380)
        .padding(20)
    }
}

// MARK: - 1. General

private struct GeneralSettingsTab: View {
    @AppStorage("lingxi_notifications_enabled") private var notificationsEnabled: Bool = true
    @AppStorage("lingxi_dock_badge_enabled") private var dockBadgeEnabled: Bool = true

    var body: some View {
        Form {
            Section("工作区与通知") {
                Toggle("启用任务完成与待处理系统通知", isOn: $notificationsEnabled)
                Toggle("在 Dock 图标显示待审批角标", isOn: $dockBadgeEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 2. Models & Providers (无硬编码模型名)

private struct ModelsProvidersSettingsTab: View {
    @State private var defaultTier: String = "smart"

    var body: some View {
        Form {
            Section("默认档位 (按能力档位驱动，无需频繁指定模型名)") {
                Picker("默认档位", selection: $defaultTier) {
                    Text("更聪明 (Deep Reasoning)").tag("smart")
                    Text("均衡档 (Standard Balanced)").tag("balanced")
                    Text("更快速 (High Speed)").tag("fast")
                }
                .pickerStyle(.radioGroup)

                Text("模型目录由 Core 从官方端点动态获取，支持在线实时加载与更新。")
                    .font(.caption2)
                    .foregroundColor(LingXiTheme.secondaryText)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 3. Permissions & Sandbox

private struct PermissionsSandboxSettingsTab: View {
    @State private var defaultPolicy: PermissionPolicyLevel = .ask
    @State private var isolateWorktree: Bool = true

    var body: some View {
        Form {
            Section("安全边界与沙箱策略") {
                Picker("默认权限策略", selection: $defaultPolicy) {
                    ForEach(PermissionPolicyLevel.allCases, id: \.self) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("默认启用 Git Worktree 隔离运行环境", isOn: $isolateWorktree)
                Text("开启 Worktree 隔离可在独立分支进行构建与测试，收尾时再合并至主工作区。")
                    .font(.caption2)
                    .foregroundColor(LingXiTheme.secondaryText)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 4. MCP

private struct MCPSettingsTab: View {
    var body: some View {
        Form {
            Section("已接入的 MCP 服务") {
                List {
                    HStack {
                        Image(systemName: "circle.fill").foregroundColor(.green).font(.system(size: 8))
                        Text("codebase-memory-mcp")
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Text("活跃中").font(.caption).foregroundColor(.secondary)
                    }
                    HStack {
                        Image(systemName: "circle.fill").foregroundColor(.green).font(.system(size: 8))
                        Text("context7")
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Text("活跃中").font(.caption).foregroundColor(.secondary)
                    }
                }
                .frame(height: 120)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 5. Shortcuts

private struct ShortcutsSettingsTab: View {
    var body: some View {
        Form {
            Section("全局与核心快捷键清单") {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        Text("新建会话").bold()
                        Text("⌘N").font(.system(size: 11, design: .monospaced))
                    }
                    GridRow {
                        Text("发送消息").bold()
                        Text("⌘Return").font(.system(size: 11, design: .monospaced))
                    }
                    GridRow {
                        Text("停止生成").bold()
                        Text("⌘.").font(.system(size: 11, design: .monospaced))
                    }
                    GridRow {
                        Text("唤起快捷侧问浮窗").bold()
                        Text("⌥Space").font(.system(size: 11, design: .monospaced))
                    }
                    GridRow {
                        Text("切换检查器标签 (1-4)").bold()
                        Text("⌥⌘1 ~ ⌥⌘4").font(.system(size: 11, design: .monospaced))
                    }
                    GridRow {
                        Text("打开独立运行轨迹窗口").bold()
                        Text("⌥⌘L").font(.system(size: 11, design: .monospaced))
                    }
                }
                .padding(6)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 6. Appearance

private struct AppearanceSettingsTab: View {
    var body: some View {
        Form {
            Section("视觉主题规范") {
                HStack(spacing: 12) {
                    Circle()
                        .fill(LingXiTheme.accentColor)
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("狐橙 (Fox Orange)")
                            .font(.subheadline.bold())
                        Text("单一品牌强调色：浅色 #C24A14 / 深色 #EE6725")
                            .font(.caption2)
                            .foregroundColor(LingXiTheme.secondaryText)
                    }
                }
                .padding(.vertical, 4)

                Text("遵循 macOS HIG 原生语义配色与材质体系，自动适配系统浅色/深色模式。")
                    .font(.caption)
                    .foregroundColor(LingXiTheme.secondaryText)
            }
        }
        .formStyle(.grouped)
    }
}
#endif
