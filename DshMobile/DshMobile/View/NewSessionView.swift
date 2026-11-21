import SwiftUI

/// Creates a Session anchored to a workspace or a typed path, in a chosen mode.
struct NewSessionView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    /// Called with the new Session identity so the caller can navigate to it.
    let onCreate: (_ deviceID: String, _ sessionID: String) -> Void

    @State private var workspaces: [WorkspaceRow] = []
    @State private var modes: [AgentMode] = []
    @State private var defaultDirectory: String?
    @State private var isLoading = true
    @State private var isCreating = false
    @State private var error: String?

    @State private var selectedWorkspaceID: String?
    @State private var useCustomPath = false
    @State private var customPath = ""
    @State private var selectedModeID: String?
    /// Device the Session will be created on; nil means the primary one.
    @State private var selectedDevice: Device?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: create) {
                        if isCreating {
                            ProgressView()
                        } else {
                            Text("创建").fontWeight(.semibold)
                        }
                    }
                    .disabled(isCreating || isLoading)
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error {
                    ErrorBanner(message: error)
                }
                deviceSection
                modeSection
                workspaceSection
                pathSection
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Device

    /// Only shown when there is a choice to make: with one device reachable the
    /// picker would be noise.
    @ViewBuilder
    private var deviceSection: some View {
        let online = store.registry.onlineDevices
        if online.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "在哪台电脑上创建")
                ForEach(online) { device in
                    Button {
                        selectedDevice = device
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: (selectedDevice ?? store.primaryDevice)?.id == device.id
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle((selectedDevice ?? store.primaryDevice)?.id == device.id
                                                 ? Theme.accent : Theme.textTertiary)
                                .font(.system(size: 15))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(device.displayAddress)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill((selectedDevice ?? store.primaryDevice)?.id == device.id
                                  ? Theme.surfaceRaised : Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder((selectedDevice ?? store.primaryDevice)?.id == device.id
                                          ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: 1)
                    )
                }
            }
        }
    }

    // MARK: - Mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "模式")
            if isLoading {
                ProgressView()
            } else if modes.isEmpty {
                Text("这台电脑没有提供可选的模式。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(modes) { mode in
                    Button {
                        selectedModeID = mode.id
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedModeID == mode.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selectedModeID == mode.id ? Theme.accent : Theme.textTertiary)
                                .font(.system(size: 15))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(mode.isUsable ? Theme.textPrimary : Theme.textTertiary)
                                if let description = mode.description, !description.isEmpty {
                                    Text(description)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(2)
                                }
                                if let broken = mode.broken {
                                    Text("不可用：\(broken)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.danger)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!mode.isUsable)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(selectedModeID == mode.id ? Theme.surfaceRaised : Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                selectedModeID == mode.id ? Theme.accent.opacity(0.5) : Theme.border,
                                lineWidth: 1
                            )
                    )
                }
            }
        }
    }

    // MARK: - Workspace

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "工作区")
            if useCustomPath {
                Text("已改为手动输入目录")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else if isLoading {
                ProgressView()
            } else if workspaces.isEmpty {
                Text("没有已登记的工作区，请在下方输入目录。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(workspaces) { workspace in
                    Button {
                        selectedWorkspaceID = workspace.id
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedWorkspaceID == workspace.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selectedWorkspaceID == workspace.id ? Theme.accent : Theme.textTertiary)
                                .font(.system(size: 15))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workspace.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Text(workspace.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                                if !workspace.isAvailable {
                                    Text("目录已不存在")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.warning)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!workspace.isAvailable)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(selectedWorkspaceID == workspace.id ? Theme.surfaceRaised : Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                selectedWorkspaceID == workspace.id ? Theme.accent.opacity(0.5) : Theme.border,
                                lineWidth: 1
                            )
                    )
                }
            }
            Toggle("手动输入目录", isOn: $useCustomPath)
                .font(.system(size: 13))
                .tint(Theme.accent)
                .onChange(of: useCustomPath, perform: { enabled in
                    if enabled { selectedWorkspaceID = nil }
                })
        }
    }

    // MARK: - Path

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "目录")
            if useCustomPath {
                TextField(defaultDirectory ?? "C:\\path\\to\\project", text: $customPath)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("输入这台电脑上的绝对路径。留空则使用默认目录。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            } else if let selected = workspaces.first(where: { $0.id == selectedWorkspaceID }) {
                Text(selected.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            } else if let defaultDirectory {
                Text("默认：\(defaultDirectory)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let device = selectedDevice ?? store.primaryDevice else {
            error = "没有在线设备。"
            return
        }
        let api = BridgeAPI(endpoint: device.endpoint)
        async let workspacesTask = api.workspaces()
        async let modesTask = api.modes()
        do {
            let (payload, modePayload) = try await (workspacesTask, modesTask)
            workspaces = payload.workspaces
            defaultDirectory = payload.defaultDirectory
            // Prefer a healthy workspace as the initial choice.
            selectedWorkspaceID = payload.workspaces.first(where: { $0.isAvailable })?.id
            modes = modePayload.modes
            selectedModeID = modePayload.selectedDefault
                ?? modePayload.modes.first(where: { $0.isUsable })?.id
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func create() {
        guard let device = selectedDevice ?? store.primaryDevice else { return }
        isCreating = true
        error = nil
        Task {
            defer { isCreating = false }
            do {
                let typed = useCustomPath ? customPath : nil
                let sessionID = try await store.createSession(
                    on: device,
                    workspaceID: useCustomPath ? nil : selectedWorkspaceID,
                    cwd: typed,
                    agentPreset: selectedModeID
                )
                dismiss()
                onCreate(device.id, sessionID)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
