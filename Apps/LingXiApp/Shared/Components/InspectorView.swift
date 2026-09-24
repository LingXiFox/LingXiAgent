#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol

/// macOS 原生检查器 (Inspector)
/// 遵循设计规范：四标签体系、Aesthetic First，用优雅 Gauge 表达 Context Health，杜绝调试参数罗列
public struct InspectorView: View {
    @ObservedObject public var model: RuntimeInspectorPresentationModel
    public var onOpenTraceWindow: () -> Void

    public init(
        model: RuntimeInspectorPresentationModel,
        onOpenTraceWindow: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onOpenTraceWindow = onOpenTraceWindow
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 四标签分段切换器 (⌥⌘1 ~ ⌥⌘4)
            Picker("", selection: $model.selectedTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)

            Divider()

            // 标签页内容
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.selectedTab {
                    case .overview:
                        OverviewTabView(
                            health: model.contextHealth,
                            criteria: model.criteria,
                            artifacts: model.artifacts
                        )
                    case .agent:
                        AgentTabView(preset: $model.currentPreset)
                    case .tasks:
                        TasksTabView()
                    case .capabilities:
                        CapabilitiesTabView(grants: model.activeGrants)
                    }
                }
                .padding(16)
            }

            Spacer()

            Divider()

            // 底部运行轨迹按钮 (⌥⌘L)
            HStack {
                Button(action: onOpenTraceWindow) {
                    Label("运行轨迹…", systemImage: "waveform.path.ecg")
                }
                .keyboardShortcut("l", modifiers: [.option, .command])
                .help("打开独立运行轨迹窗口 (⌥⌘L)")

                Spacer()
            }
            .padding(12)
            .background(LingXiTheme.surfaceBackground)
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
        .background(LingXiTheme.windowBackground)
    }
}

// MARK: - 1. Overview Tab (美学设计优先：Context Health Gauge, Criteria, Artifacts)

public struct OverviewTabView: View {
    public let health: ContextHealthPresentation
    public let criteria: [SuccessCriterion]
    public let artifacts: [TaskArtifact]

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Context Health Gauge (优雅原生仪表，绝无 PE 核心/分支预测等无意义内部参数)
            GroupBox(label: Label("上下文健康度", systemImage: "gauge.with.dots.needle.bottom.50percent")) {
                VStack(spacing: 8) {
                    Gauge(value: health.healthPercentage, in: 0...1.0) {
                        Text("容量占用")
                            .font(.caption2)
                    } currentValueLabel: {
                        Text(String(format: "%.0f%%", health.healthPercentage * 100))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    } minimumValueLabel: {
                        Text("0%")
                            .font(.system(size: 9))
                    } maximumValueLabel: {
                        Text("100%")
                            .font(.system(size: 9))
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(LingXiTheme.accentColor)

                    HStack {
                        Text("当前使用:")
                            .font(.caption)
                            .foregroundColor(LingXiTheme.secondaryText)
                        Spacer()
                        Text(health.formattedTokens)
                            .font(.caption.monospacedDigit().bold())
                    }
                }
                .padding(6)
            }

            // Success Criteria 清单
            GroupBox(label: Label("成功准则 (Success Criteria)", systemImage: "checklist")) {
                if criteria.isEmpty {
                    Text("当前任务未设定明确成功条件")
                        .font(.caption)
                        .foregroundColor(LingXiTheme.secondaryText)
                        .padding(4)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(criteria, id: \.criterionID) { crit in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: crit.isSatisfied ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(crit.isSatisfied ? .green : .secondary)
                                    .font(.system(size: 11))
                                    .padding(.top, 2)
                                Text(crit.description)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                    }
                    .padding(4)
                }
            }

            // Artifacts 产物清单
            GroupBox(label: Label("产物清单 (Artifacts)", systemImage: "shippingbox")) {
                if artifacts.isEmpty {
                    Text("暂未产生产物")
                        .font(.caption)
                        .foregroundColor(LingXiTheme.secondaryText)
                        .padding(4)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(artifacts, id: \.self) { art in
                            HStack(spacing: 6) {
                                Image(systemName: artifactIcon(for: art.kind))
                                    .foregroundColor(LingXiTheme.accentColor)
                                    .font(.system(size: 12))

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(art.ref)
                                        .font(.caption.bold())
                                        .lineLimit(1)
                                    Text("版本 v\(art.version) · \(art.kind)")
                                        .font(.system(size: 9))
                                        .foregroundColor(LingXiTheme.secondaryText)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(4)
                }
            }
        }
    }

    private func artifactIcon(for kind: String) -> String {
        switch kind {
        case "diff": return "doc.badge.gearshape"
        case "testResult": return "checkmark.diamond"
        case "reviewVerdict": return "text.badge.checkmark"
        case "spec": return "doc.text"
        default: return "doc"
        }
    }
}

// MARK: - 2. Agent Tab

public struct AgentTabView: View {
    @Binding public var preset: AgentPresetInfo

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: Label("当前 Agent 设定", systemImage: "person.crop.square")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(preset.name)
                        .font(.headline)
                    Text(preset.description)
                        .font(.caption)
                        .foregroundColor(LingXiTheme.secondaryText)

                    Divider()

                    // 运行模式切换
                    Picker("模式", selection: $preset.mode) {
                        ForEach(AgentRunMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    // 思考等级调节
                    Picker("思考等级", selection: $preset.reasoningEffort) {
                        ForEach(ReasoningEffortLevel.allCases, id: \.self) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }

                    // 权限策略调节
                    Picker("权限策略", selection: $preset.permissionPolicy) {
                        ForEach(PermissionPolicyLevel.allCases, id: \.self) { policy in
                            Text(policy.rawValue).tag(policy)
                        }
                    }
                }
                .padding(6)
            }
        }
    }
}

// MARK: - 3. Tasks Tab

public struct TasksTabView: View {
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(label: Label("Git Worktree 隔离", systemImage: "arrow.triangle.branch")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("当前分支:")
                            .font(.caption)
                            .foregroundColor(LingXiTheme.secondaryText)
                        Spacer()
                        Text("feat/gui-v1-foundation")
                            .font(.caption.monospaced().bold())
                    }
                    HStack {
                        Text("隔离路径:")
                            .font(.caption)
                            .foregroundColor(LingXiTheme.secondaryText)
                        Spacer()
                        Text(".worktrees/b4-gui")
                            .font(.caption.monospaced())
                    }
                }
                .padding(6)
            }
        }
    }
}

// MARK: - 4. Capabilities Tab

public struct CapabilitiesTabView: View {
    public let grants: [CapabilityGrant]

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(label: Label("安全网关授权 (Capabilities)", systemImage: "lock.shield")) {
                if grants.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("受单调收窄策略保护 (child ⊆ parent)")
                            .font(.caption)
                            .foregroundColor(LingXiTheme.secondaryText)
                        Text("凭据经由 CredentialBroker 权威持有，不向子 Agent / MCP 泄漏原始 Key。")
                            .font(.system(size: 10))
                            .foregroundColor(LingXiTheme.secondaryText)
                    }
                    .padding(6)
                } else {
                    ForEach(grants, id: \.id) { grant in
                        HStack {
                            Text(grant.capabilityKind)
                                .font(.caption.monospaced())
                            Spacer()
                            Text(grant.state.rawValue)
                                .font(.caption2)
                        }
                    }

                }
            }
        }
    }
}
#endif
