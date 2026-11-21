import SwiftUI

/// Sessions merged from every paired computer, newest first.
///
/// The list is no longer tied to one connection: each row carries the device it
/// came from, and a device going offline never removes the others' rows.
struct SessionsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showsSettings = false
    @State private var showsNewSession = false
    @State private var showsFiles = false
    @State private var showsDevices = false
    @State private var searchWork: Task<Void, Never>?
    /// Session being renamed, and the draft title.
    @State private var renaming: DeviceSession?
    @State private var renameDraft = ""
    /// Drives navigation; the value is the merged key `deviceId/sessionId`.
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            showsDevices = true
                        } label: {
                            Image(systemName: "desktopcomputer")
                        }
                        Button {
                            showsFiles = true
                        } label: {
                            Image(systemName: "tray.and.arrow.down")
                        }
                        Button {
                            showsNewSession = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .disabled(!store.hasAnyOnlineDevice)
                    }
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView().environmentObject(store)
            }
            .sheet(isPresented: $showsFiles) {
                FilesView()
            }
            .sheet(isPresented: $showsDevices) {
                DevicesView().environmentObject(store)
            }
            .sheet(isPresented: $showsNewSession) {
                NewSessionView { deviceID, sessionID in
                    openCreated(deviceID: deviceID, sessionID: sessionID)
                }
                .environmentObject(store)
            }
            .navigationDestination(for: String.self) { key in
                if let target = store.sessions.first(where: { $0.id == key }) {
                    ChatView(
                        sessionID: target.row.id,
                        title: target.row.title,
                        endpoint: target.endpoint
                    )
                } else {
                    Text("这台设备上的会话已不可用。")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .alert("重命名会话", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("标题", text: $renameDraft)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    guard let target = renaming else { return }
                    let title = renameDraft
                    renaming = nil
                    Task {
                        await store.rename(
                            sessionID: target.row.id,
                            deviceID: target.deviceId,
                            title: title
                        )
                    }
                }
            }
            .searchable(
                text: $store.searchQuery,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索会话内容"
            )
            // Debounced rather than per-keystroke: every character would
            // otherwise scan every transcript on every computer.
            .onChange(of: store.searchQuery) { _ in
                scheduleSearch()
            }
            .task {
                await store.refreshSessions()
            }
            .refreshable {
                await store.refreshSessions()
            }
        }
    }

    /// Wait for typing to settle before asking the devices.
    private func scheduleSearch() {
        searchWork?.cancel()
        let query = store.searchQuery
        searchWork = Task {
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled else { return }
            await store.search(query)
        }
    }

    /// Navigate into a freshly created Session.
    /// @param deviceID - the device that owns it.
    /// @param sessionID - the Session identity inside that device.
    private func openCreated(deviceID: String, sessionID: String) {
        path.append("\(deviceID)/\(sessionID)")
    }

    @ViewBuilder
    private var content: some View {
        if !store.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            searchResults
        } else if !store.hasPairedDevice {
            pairedEmptyState
        } else if store.sessions.isEmpty && !store.hasAnyOnlineDevice {
            allOfflineState
        } else if store.sessions.isEmpty && store.isLoadingSessions {
            ProgressView("读取会话…").tint(Theme.accent)
        } else if store.sessions.isEmpty {
            noSessionsState
        } else {
            sessionList
        }
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                header
                if let error = store.lastError {
                    ErrorBanner(message: error)
                }
                ForEach(store.sessions) { entry in
                    NavigationLink(value: entry.id) {
                        row(entry)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renaming = entry
                            renameDraft = entry.row.title
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
    }

    /// Shown when nothing is paired yet: pairing is the only prerequisite.
    private var pairedEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("还没有配对的电脑")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("配对一次即可，之后打开 App 会自动连接。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
            Button("配对电脑") { showsDevices = true }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 220)
                .padding(.top, 8)
        }
        .padding(32)
    }

    /// Shown when every paired device is unreachable.
    ///
    /// The list stays empty rather than showing stale rows, and the reason per
    /// device is one tap away.
    private var allOfflineState: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.warning.opacity(0.8))
            Text("所有设备都离线")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("检查电脑上的 DSH 是否在运行，以及手机与电脑是否在同一网络。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("重试") { Task { await store.refreshSessions() } }
                    .buttonStyle(PrimaryButtonStyle())
                Button("设备列表") { showsDevices = true }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.surfaceRaised, in: Capsule())
            }
            .padding(.top, 8)
        }
        .padding(32)
    }

    private var noSessionsState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("还没有会话")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("点右上角新建一个，或先在电脑上开始对话。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
            Button("新建会话") { showsNewSession = true }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 220)
                .padding(.top, 8)
        }
        .padding(32)
    }

    /// Results of the active search, with the matching excerpt per row.
    @ViewBuilder
    private var searchResults: some View {
        if store.isSearching && store.hits.isEmpty {
            ProgressView("搜索中…")
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.hits.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
                Text("没有找到包含这段文字的会话")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(32)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    HStack {
                        Text("\(store.hits.count) 个结果")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        if !store.searchIsTranscript {
                            Text("仅匹配标题")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.warning.opacity(0.9))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.warning.opacity(0.12), in: Capsule())
                        }
                    }
                    ForEach(store.hits) { hit in
                        if let deviceID = hit.deviceId, let raw = hit.id.split(separator: "/").last {
                            NavigationLink(value: "\(deviceID)/\(raw)") {
                                hitRow(hit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
    }

    private func hitRow(_ hit: SessionHit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(hit.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if hit.running {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                }
                Spacer(minLength: 0)
                if let deviceName = hit.deviceName {
                    Text(deviceName)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.surfaceRaised, in: Capsule())
                }
            }
            if let preview = hit.previewText {
                Text(preview)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(color: store.isRetrying ? Theme.warning : (store.hasAnyOnlineDevice ? Theme.success : Theme.textTertiary))
            Text(store.statusSummary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            if store.isLoadingSessions {
                ProgressView().tint(Theme.accent).scaleEffect(0.7)
            }
        }
        .padding(.bottom, 4)
    }

    private func row(_ entry: DeviceSession) -> some View {
        HStack(spacing: 12) {
            StatusDot(color: entry.row.running ? Theme.accent : Theme.textTertiary.opacity(0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.row.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    Text(entry.deviceName)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accentAlt.opacity(0.9))
                    if let updated = entry.row.updatedAt {
                        Text(Self.relative(updated))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary.opacity(0.6))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(entry.row.running ? Theme.accent.opacity(0.35) : Theme.border, lineWidth: 1)
        )
    }

    /// Format an epoch-seconds timestamp as a short relative age.
    /// @param timestamp - seconds since 1970.
    /// @returns a relative label.
    private static func relative(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp > 1e12 ? timestamp / 1000 : timestamp)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

