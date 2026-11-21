import SwiftUI

/// Every Session on the connected Harness, newest first.
struct SessionsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showsSettings = false
    @State private var showsNewSession = false
    @State private var showsFiles = false
    @State private var searchWork: Task<Void, Never>?
    /// Session being renamed, and the draft title.
    @State private var renaming: SessionRow?
    @State private var renameDraft = ""
    /// Drives programmatic navigation into a freshly created Session.
    /// iOS 16 has no `navigationDestination(item:)`, so a path is pushed instead.
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
                            showsFiles = true
                        } label: {
                            Image(systemName: "tray.and.arrow.down")
                        }
                        Button {
                            showsNewSession = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showsFiles) {
                FilesView()
            }
            .sheet(isPresented: $showsNewSession) {
                NewSessionView { sessionID in
                    openCreated(sessionID)
                }
                .environmentObject(store)
            }
            .navigationDestination(for: String.self) { sessionID in
                ChatView(
                    sessionID: sessionID,
                    title: store.sessions.first { $0.id == sessionID }?.title ?? "会话",
                    endpoint: store.endpoint
                )
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
                    Task { await store.rename(sessionID: target.id, title: title) }
                }
            }
            .task {
                await store.refreshSessions()
            }
            .refreshable {
                await store.refreshSessions()
            }
            .searchable(
                text: $store.searchQuery,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索会话内容"
            )
            // Debounced rather than per-keystroke: every character would
            // otherwise scan every transcript on the computer.
            .onChange(of: store.searchQuery) { _ in
                scheduleSearch()
            }
        }
    }

    /// Wait for typing to settle before asking the bridge.
    private func scheduleSearch() {
        searchWork?.cancel()
        let query = store.searchQuery
        searchWork = Task {
            // A short pause keeps one search per burst of typing.
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled else { return }
            await store.search(query)
        }
    }

    /// Navigate into a freshly created Session.
    /// @param sessionID - the identity the bridge returned.
    private func openCreated(_ sessionID: String) {
        path.append(sessionID)
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
                    }
                    ForEach(store.hits) { hit in
                        NavigationLink(value: hit.id) {
                            hitRow(hit)
                        }
                        .buttonStyle(.plain)
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
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                }
                Spacer(minLength: 0)
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

    /// The ordinary list, or the empty state before anything exists.
    @ViewBuilder
    private var content: some View {
        if !store.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            searchResults
        } else if store.sessions.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    header
                    if let error = store.lastError {
                        ErrorBanner(message: error)
                    }
                    ForEach(store.sessions) { session in
                        NavigationLink(value: session.id) {
                            row(session)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                renaming = session
                                renameDraft = session.title
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
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(color: store.isRetrying ? Theme.warning : Theme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.hostSummary)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(store.isRetrying ? "网络不稳定，正在重试…" : "\(store.sessions.count) 个会话")
                    .font(.system(size: 12))
                    .foregroundStyle(store.isRetrying ? Theme.warning : Theme.textTertiary)
            }
            Spacer()
            if store.isLoadingSessions {
                ProgressView()
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ session: SessionRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(session.running ? Theme.success : Theme.textTertiary.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                Text(session.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    Text(session.ageText)
                    if let cwd = session.cwd, !cwd.isEmpty {
                        Text(shortPath(cwd))
                            .lineLimit(1)
                    }
                    if session.origin == "subagent" {
                        Text("子代理")
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 4)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(session.running ? Theme.success.opacity(0.35) : Theme.border, lineWidth: 1)
        )
    }

    private var emptyState: some View {
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

    // MARK: - Actions

    private func shortPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        guard components.count > 2 else { return path }
        return components.suffix(2).joined(separator: "/")
    }
}
