import SwiftUI

/// Browses the Session's workspace on the computer and downloads a selection.
struct FileBrowserView: View {
    let sessionID: String
    let api: BridgeAPI
    @Environment(\.dismiss) private var dismiss

    @State private var listing: FileListing?
    @State private var isLoading = true
    @State private var error: String?
    @State private var isSelecting = false
    /// Absolute paths chosen for download.
    @State private var selection: Set<String> = []
    @State private var isDownloading = false
    @State private var downloadNote: String?
    @State private var showsDownloads = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showsDownloads) {
                FilesView()
            }
            .task { await load() }
        }
    }

    private var title: String {
        guard let listing else { return "工作区文件" }
        if listing.path == listing.root { return "工作区文件" }
        return (listing.path as NSString).lastPathComponent
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && listing == nil {
            ProgressView("读取目录…").tint(Theme.accent)
        } else if let error, listing == nil {
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await load() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 200)
            }
            .padding(32)
        } else if let listing {
            list(listing)
        }
    }

    private func list(_ listing: FileListing) -> some View {
        VStack(spacing: 0) {
            pathBar(listing)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let parent = listing.parent {
                        row(
                            icon: "arrow.up.left",
                            tint: Theme.textSecondary,
                            name: "..",
                            detail: nil,
                            trailing: { EmptyView() }
                        ) {
                            enter(parent)
                        }
                    }
                    ForEach(listing.sorted) { entry in
                        entryRow(entry)
                        Rectangle()
                            .fill(Theme.border)
                            .frame(height: 0.5)
                            .padding(.leading, 52)
                    }
                    if listing.truncated {
                        Text("目录条目过多，仅显示前一部分。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warning)
                            .padding(.vertical, 10)
                    }
                    if listing.sorted.isEmpty {
                        Text("这个文件夹是空的。")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.vertical, 40)
                    }
                }
                .padding(.bottom, 80)
            }
            .refreshable { await load(path: listing.path) }
        }
        .overlay(alignment: .bottom) { downloadBar }
    }

    private func pathBar(_ listing: FileListing) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Text(listing.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if listing.path != listing.root {
                Button("根目录") { enter(listing.root) }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.surface)
    }

    /// One tappable row with a leading icon.
    private func row<Trailing: View>(
        icon: String,
        tint: Color,
        name: String,
        detail: String?,
        @ViewBuilder trailing: () -> Trailing,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func entryRow(_ entry: FileEntry) -> some View {
        let chosen = selection.contains(entry.path)
        if isSelecting {
            row(
                icon: chosen ? "checkmark.circle.fill" : (entry.isDirectory ? "folder" : "doc"),
                tint: chosen ? Theme.accent : (entry.isDirectory ? Theme.accentAlt : Theme.textSecondary),
                name: entry.name,
                detail: entry.isDirectory ? "文件夹" : entry.sizeText,
                trailing: { EmptyView() }
            ) {
                toggle(entry.path)
            }
        } else {
            row(
                icon: entry.isDirectory ? "folder.fill" : "doc.text",
                tint: entry.isDirectory ? Theme.accentAlt : Theme.textSecondary,
                name: entry.name,
                detail: entry.isDirectory ? nil : entry.sizeText,
                trailing: {
                    if entry.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            ) {
                if entry.isDirectory {
                    enter(entry.path)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("关闭") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 14) {
                Button {
                    showsDownloads = true
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                }
                Button(isSelecting ? "取消" : "选择") {
                    isSelecting.toggle()
                    if !isSelecting { selection.removeAll() }
                }
                .disabled(listing == nil)
            }
        }
    }

    @ViewBuilder
    private var downloadBar: some View {
        if isSelecting {
            VStack(spacing: 0) {
                Divider().overlay(Theme.border)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selection.isEmpty ? "未选择" : "已选 \(selection.count) 项")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        if let downloadNote {
                            Text(downloadNote)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(action: download) {
                        if isDownloading {
                            ProgressView().tint(.white)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle")
                                Text("下载")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(
                                Capsule().fill(selection.isEmpty ? Theme.textTertiary : Theme.accent)
                            )
                        }
                    }
                    .disabled(selection.isEmpty || isDownloading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.surface)
            }
        }
    }

    // MARK: - Actions

    private func load(path: String? = nil) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let next = try await api.listFiles(sessionID: sessionID, path: path)
            listing = next
            error = nil
        } catch {
            if RetryPolicy.isCancellation(error) { return }
            self.error = Self.describe(error)
        }
    }

    private func enter(_ path: String) {
        selection.removeAll()
        Task { await load(path: path) }
    }

    private func toggle(_ path: String) {
        if selection.contains(path) {
            selection.remove(path)
        } else {
            selection.insert(path)
        }
    }

    private func download() {
        guard !selection.isEmpty, !isDownloading else { return }
        isDownloading = true
        downloadNote = nil
        Task {
            defer { isDownloading = false }
            do {
                let result = try await api.download(
                    sessionID: sessionID,
                    paths: Array(selection)
                )
                guard let file = FileDelivery.store(
                    fileAt: result.temporaryURL,
                    name: result.fileName
                ) else {
                    downloadNote = "无法保存文件。"
                    return
                }
                downloadNote = "已保存 \(file.name)（\(file.sizeText)）"
                // Leave selection mode so the row list returns to navigation and
                // the person can keep browsing after a successful download.
                isSelecting = false
                selection.removeAll()
            } catch {
                if RetryPolicy.isCancellation(error) { return }
                downloadNote = Self.describe(error)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let bridge = error as? BridgeError {
            return bridge.errorDescription ?? "请求失败。"
        }
        return error.localizedDescription
    }
}