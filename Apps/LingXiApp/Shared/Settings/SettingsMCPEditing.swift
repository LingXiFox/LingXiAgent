#if canImport(SwiftUI)
import SwiftUI
import LingXiProtocol

// Form for one `mcp.json` server: local process (stdio) or remote (Streamable
// HTTP). Core validates, resolves the command to an absolute path and keeps
// credentials and environment values in its vault.

struct MCPServerDraft: Equatable {
    struct Argument: Identifiable, Equatable {
        let id = UUID()
        var value: String
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }
    }

    struct Variable: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var stored: SecretSource
        var update: SecretUpdate
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name == rhs.name && lhs.stored == rhs.stored && lhs.update == rhs.update
        }
    }

    var id = ""
    var alias = ""
    var transport: MCPServerTransport = .stdio
    var command = ""
    var arguments: [Argument] = []
    var endpoint = "https://"
    var protocolPreference: MCPServerProtocolPreference = .auto
    var enabled = true
    var authentication: MCPAuthenticationKind = .none
    var headerName = ""
    var storedCredential: SecretSource = .none
    var credential: SecretUpdate = .keep
    var environment: [Variable] = []
    var timeoutSeconds = 60

    init() {}

    init(_ detail: MCPServerConfigurationDetail) {
        id = detail.id
        alias = detail.alias
        transport = detail.transport
        command = detail.command ?? ""
        arguments = detail.arguments.map { Argument(value: $0) }
        endpoint = detail.endpoint ?? "https://"
        protocolPreference = detail.protocolPreference
        enabled = detail.enabled
        authentication = detail.authentication
        headerName = detail.headerName ?? ""
        storedCredential = detail.credential
        environment = detail.environment.map { Variable(name: $0.name, stored: $0.value, update: .keep) }
        timeoutSeconds = Int(detail.timeoutSeconds.rounded())
    }

    var request: SaveMCPServerRequest {
        SaveMCPServerRequest(
            id: id.trimmingCharacters(in: .whitespaces),
            alias: alias.trimmingCharacters(in: .whitespaces),
            transport: transport,
            command: transport == .stdio ? command.trimmingCharacters(in: .whitespaces) : nil,
            arguments: transport == .stdio ? arguments.map(\.value).filter { !$0.isEmpty } : [],
            endpoint: transport == .streamableHTTP ? endpoint.trimmingCharacters(in: .whitespaces) : nil,
            protocolPreference: protocolPreference,
            enabled: enabled,
            authentication: transport == .streamableHTTP ? authentication : .none,
            headerName: authentication == .header ? headerName.trimmingCharacters(in: .whitespaces) : nil,
            credential: credential,
            environment: transport == .stdio
                ? environment.map { MCPEnvironmentVariableUpdate(name: $0.name, value: $0.update) } : [],
            timeoutSeconds: Double(timeoutSeconds))
    }

    var isValid: Bool {
        guard id.trimmingCharacters(in: .whitespaces)
                .range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil else { return false }
        switch transport {
        case .stdio:
            return !command.trimmingCharacters(in: .whitespaces).isEmpty
        case .streamableHTTP:
            guard endpoint.count > "https://".count else { return false }
            if authentication == .header && headerName.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            if authentication != .none, storedCredential == .none, case .keep = credential { return false }
            return true
        }
    }
}

/// The editable sections of an MCP server; shared by the detail page and the
/// add sheet. `isNew` unlocks the ID.
struct MCPServerForm: View {
    @Binding var draft: MCPServerDraft
    let isNew: Bool
    @State private var newVariableName = ""
    @State private var newVariableValue = ""
    @State private var isAddingVariable = false

    var body: some View {
        LXSettingsCard("服务器") {
            LXTextRow(title: "名称", text: $draft.alias, prompt: draft.id)
            if isNew {
                LXTextRow(title: "ID", info: "工具名前缀与 mcp.json 中的键，保存后不能修改。",
                          text: $draft.id, prompt: "github", monospaced: true)
            } else {
                ValueRow(title: "ID", value: draft.id, monospaced: true)
            }
            LabeledContent("传输方式") {
                Picker("传输方式", selection: $draft.transport) {
                    Text("本地进程 (stdio)").tag(MCPServerTransport.stdio)
                    Text("远程 (Streamable HTTP)").tag(MCPServerTransport.streamableHTTP)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .lxSettingsRow()
            if draft.transport == .stdio {
                LXTextRow(title: "命令", info: "可写命令名（如 npx），保存时按 PATH 解析成绝对路径。",
                          text: $draft.command, prompt: "npx", monospaced: true)
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.sm) {
                    Text("参数")
                    ForEach($draft.arguments) { $argument in
                        HStack(spacing: LingXiMetrics.Space.sm) {
                            TextField("参数", text: $argument.value)
                                .textFieldStyle(.roundedBorder)
                                .font(LXType.mono)
                            Button {
                                draft.arguments.removeAll { $0.id == argument.id }
                            } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("删除参数 \(argument.value)")
                        }
                    }
                    Button { draft.arguments.append(.init(value: "")) } label: {
                        Label("添加参数", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LXColor.accentText)
                }
                .lxSettingsRow()
            } else {
                LXTextRow(title: "Endpoint", text: $draft.endpoint, prompt: "https://", monospaced: true)
                LabeledContent("协议") {
                    Picker("协议", selection: $draft.protocolPreference) {
                        Text("自动").tag(MCPServerProtocolPreference.auto)
                        Text("新版").tag(MCPServerProtocolPreference.modern)
                        Text("旧版").tag(MCPServerProtocolPreference.legacy)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .lxSettingsRow()
            }
            LXNumberRow(title: "超时", value: $draft.timeoutSeconds.optional, unit: "秒")
        }

        if draft.transport == .stdio {
            LXSettingsCard(title: LXSettingsSectionHeader("环境变量"), accessory: {
                Button("添加变量…") {
                    newVariableName = ""
                    newVariableValue = ""
                    isAddingVariable = true
                }
                .popover(isPresented: $isAddingVariable, arrowEdge: .bottom) { variableEditor }
            }) {
                if draft.environment.isEmpty {
                    PlaceholderLine("没有环境变量。")
                }
                ForEach($draft.environment) { $variable in
                    HStack(spacing: LingXiMetrics.Space.sm) {
                        LXSecretRow(title: variable.name, stored: variable.stored, pending: $variable.update)
                        Button {
                            draft.environment.removeAll { $0.id == variable.id }
                        } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("删除变量 \(variable.name)")
                    }
                }
            } footer: {
                Text("变量值作为凭据保存在 Core 的凭据库，不以明文显示。")
            }
        } else {
            LXSettingsCard("认证") {
                LabeledContent("方式") {
                    Picker("方式", selection: $draft.authentication) {
                        Text("无").tag(MCPAuthenticationKind.none)
                        Text("Bearer").tag(MCPAuthenticationKind.bearer)
                        Text("自定义请求头").tag(MCPAuthenticationKind.header)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .lxSettingsRow()
                if draft.authentication == .header {
                    LXTextRow(title: "请求头名称", text: $draft.headerName, prompt: "X-API-Key", monospaced: true)
                }
                if draft.authentication != .none {
                    LXSecretRow(title: "凭据", stored: draft.storedCredential, pending: $draft.credential)
                }
            }
        }
    }

    private var variableEditor: some View {
        VStack(alignment: .leading, spacing: LingXiMetrics.Space.md) {
            Text("添加环境变量").font(LXType.headline)
            TextField("变量名，例如 GITHUB_TOKEN", text: $newVariableName)
                .textFieldStyle(.roundedBorder)
                .font(LXType.mono)
            SecureField("值", text: $newVariableValue)
                .textFieldStyle(.roundedBorder)
                .font(LXType.mono)
            HStack {
                Spacer()
                Button("取消") { isAddingVariable = false }
                    .buttonStyle(LXButtonStyle(.secondary, size: .small))
                Button("添加") {
                    let name = newVariableName.trimmingCharacters(in: .whitespaces)
                    draft.environment.removeAll { $0.name == name }
                    draft.environment.append(.init(name: name, stored: .none,
                                                   update: .replace(newVariableValue)))
                    isAddingVariable = false
                }
                .buttonStyle(LXButtonStyle(.primary, size: .small))
                .keyboardShortcut(.defaultAction)
                .disabled(newVariableName.trimmingCharacters(in: .whitespaces)
                            .range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil
                          || newVariableValue.isEmpty)
            }
        }
        .frame(width: 320)
        .padding(LingXiMetrics.Space.lg)
    }
}

/// Detail of the selected server: head, form, save / revert.
struct MCPServerEditor: View {
    @ObservedObject var store: SettingsStore
    let server: MCPServerConfigurationDetail
    @State private var draft: MCPServerDraft
    @State private var isSaving = false
    @State private var confirmRemove = false
    @Environment(\.settingsSelect) private var select

    init(store: SettingsStore, server: MCPServerConfigurationDetail) {
        self.store = store
        self.server = server
        _draft = State(initialValue: MCPServerDraft(server))
    }

    private var live: ExtensionInfo? { store.extensions.first { $0.kind == .mcp && $0.id == server.id } }
    private var isDirty: Bool { draft != MCPServerDraft(server) }

    var body: some View {
        LXSettingsCard(title: EmptyView()) {
            HStack(spacing: LingXiMetrics.Space.md) {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xs) {
                    HStack(spacing: LingXiMetrics.Space.xs) {
                        Text(server.alias.isEmpty ? server.id : server.alias).font(LXType.headline)
                        if let live { LXBadge("v\(live.version)", kind: .outline) }
                    }
                    Text([server.transport == .stdio ? "stdio" : "HTTP",
                          server.enabled ? (live?.lifecycleState ?? "未连接") : "已停用",
                          live?.scope].compactMap { $0 }.joined(separator: " · "))
                        .font(LXType.meta)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: LingXiMetrics.Space.md)
                if let live, ExtensionState(ext: live).isError {
                    LXStatusText("连接失败", systemImage: "xmark.circle", tone: .danger)
                }
                // Enabling is its own write, independent of unsaved form edits.
                Toggle("启用", isOn: Binding(get: { server.enabled }, set: { enabled in
                    var stored = MCPServerDraft(server)
                    stored.enabled = enabled
                    draft.enabled = enabled
                    Task { _ = await store.saveMCPServer(stored.request) }
                }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(LXColor.accent)
                    .accessibilityLabel("\(server.id) 启用状态")
                Button("移除…") { confirmRemove = true }
                    .buttonStyle(LXButtonStyle(.destructive, size: .small))
            }
            .padding(.vertical, LingXiMetrics.Space.sm)
        }
        .settingsAnchor("extension.\(server.id)")

        MCPServerForm(draft: $draft, isNew: false)

        HStack(spacing: LingXiMetrics.Space.sm) {
            Spacer()
            if isDirty {
                Button("还原") { draft = MCPServerDraft(server) }
                    .buttonStyle(LXButtonStyle(.secondary, size: .regular))
            }
            Button(isSaving ? "保存中…" : "保存") { save() }
                .buttonStyle(LXButtonStyle(.secondary, size: .regular))
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty || !draft.isValid || isSaving)
        }
        .confirmationDialog("移除 MCP 服务器 \(server.id)？", isPresented: $confirmRemove) {
            Button("移除", role: .destructive) {
                Task { if await store.deleteMCPServer(server.id) { select(nil) } }
            }
        } message: {
            Text("会从 mcp.json 中删除，保存的凭据与环境变量值一并删除。")
        }
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            if let saved = await store.saveMCPServer(draft.request) {
                draft = MCPServerDraft(saved)
            }
        }
    }
}

/// 添加 MCP 服务器.
struct AddMCPServerSheet: View {
    @ObservedObject var store: SettingsStore
    let onFinish: (MCPServerConfigurationDetail?) -> Void
    @State private var draft = MCPServerDraft()
    @State private var isSaving = false

    private var idTaken: Bool {
        store.mcpServers.contains { $0.id == draft.id.trimmingCharacters(in: .whitespaces) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("添加 MCP 服务器").font(LXType.title)
                Text("本地进程由 Core 启动；远程服务器通过 Streamable HTTP 连接。保存后重启 Core 生效。")
                    .font(LXType.meta).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LingXiMetrics.Space.xxl)
            .padding(.vertical, LingXiMetrics.Space.lg)

            ScrollView {
                VStack(alignment: .leading, spacing: LingXiMetrics.Space.xl) {
                    MCPServerForm(draft: $draft, isNew: true)
                    if idTaken {
                        LXStatusText("已存在这个 ID 的服务器。", systemImage: "exclamationmark.triangle", tone: .warning)
                    }
                }
                .padding(.horizontal, LingXiMetrics.Space.xxl)
                .padding(.bottom, LingXiMetrics.Space.xl)
            }

            LXHairline()
            HStack(spacing: LingXiMetrics.Space.sm) {
                Spacer()
                Button("取消") { onFinish(nil) }
                    .buttonStyle(LXButtonStyle(.secondary, size: .regular))
                    .keyboardShortcut(.cancelAction)
                Button(isSaving ? "添加中…" : "添加") {
                    isSaving = true
                    Task {
                        let saved = await store.saveMCPServer(draft.request)
                        isSaving = false
                        if saved != nil { onFinish(saved) }
                    }
                }
                .buttonStyle(LXButtonStyle(.primary, size: .regular))
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid || idTaken || isSaving)
            }
            .padding(LingXiMetrics.Space.lg)
        }
        .frame(width: 640, height: 620)
        .background(LXColor.window)
        .lxSettingsControlStyles()
    }
}

/// MCP connections are made when Core starts; this says so after a change
/// and offers the one action that applies it.
struct MCPRestartBanner: View {
    @ObservedObject var store: SettingsStore
    @State private var isRestarting = false

    var body: some View {
        if store.mcpNeedsRestart {
            HStack(spacing: LingXiMetrics.Space.md) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(LXType.headline)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已写入 mcp.json").font(LXType.callout)
                    Text("MCP 连接在 Core 启动时建立，重启 Core 后改动生效。")
                        .font(LXType.meta).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isRestarting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("重启 Core") {
                        isRestarting = true
                        Task { await store.restartCore(); isRestarting = false }
                    }
                    .buttonStyle(LXButtonStyle(.secondary, size: .small))
                    .disabled(store.runtime?.conversationModel.isGenerating == true)
                    .help("正在运行的任务结束后再重启")
                }
            }
            .padding(.horizontal, LingXiMetrics.Space.lg)
            .padding(.vertical, LingXiMetrics.Space.md)
            .lxPanel(LXColor.content, cornerRadius: LingXiMetrics.Radius.control)
        }
    }
}
#endif
