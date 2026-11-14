import SwiftUI

/// Every Session on the connected Harness, newest first.
struct SessionsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isCreating = false
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
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
                    Button(action: createSession) {
                        if isCreating {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                    .disabled(isCreating)
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
                    .environmentObject(store)
            }
            .task {
                await store.refreshSessions()
            }
            .refreshable {
                await store.refreshSessions()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.sessions.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    header
                    if let error = store.lastError {
                        ErrorBanner(message: error)
                    }
                    ForEach(store.sessions) { session in
                        NavigationLink {
                            ChatView(sessionID: session.id, title: session.title, endpoint: store.endpoint)
                        } label: {
                            row(session)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(color: Theme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.hostSummary)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(store.sessions.count) 个会话")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
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
            Button("新建会话", action: createSession)
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 220)
                .padding(.top, 8)
        }
        .padding(32)
    }

    // MARK: - Actions

    private func createSession() {
        guard !isCreating else { return }
        isCreating = true
        Task {
            _ = await store.createSession()
            isCreating = false
        }
    }

    private func shortPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        guard components.count > 2 else { return path }
        return components.suffix(2).joined(separator: "/")
    }
}
