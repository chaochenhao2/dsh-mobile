import SwiftUI

/// Lists the files this app has downloaded, with preview and delete.
///
/// These are the app's own Documents, so the same files also appear in the
/// Files app under "On My iPhone → DSH Mobile" — this screen is the shortcut
/// that skips navigating there.
struct FilesView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var files: [DownloadedFile] = []
    @State private var previewTarget: DownloadedFile?
    @State private var pendingDelete: DownloadedFile?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("已下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            // The preview needs the full screen: Quick Look manages its own
            // navigation bar, and embedding it inside this sheet left two bars
            // competing for the same space.
            .fullScreenCover(item: $previewTarget) { file in
                FilePreviewSheet(file: file)
            }
            .confirmationDialog(
                "删除这个文件？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let file = pendingDelete, !FileDelivery.delete(file) {
                        error = "无法删除 \(file.name)。"
                    }
                    pendingDelete = nil
                    reload()
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text(pendingDelete?.name ?? "")
            }
            .onAppear(perform: reload)
        }
    }

    @ViewBuilder
    private var content: some View {
        if files.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
                Text("还没有下载任何文件")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text("在会话里打开「工作区文件」，选择文件后下载。\n这些文件也会出现在「文件」App 的 DSH Mobile 下。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    header
                    if let error {
                        ErrorBanner(message: error)
                    }
                    ForEach(files) { file in
                        row(file)
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .refreshable { reload() }
        }
    }

    private var header: some View {
        HStack {
            Text("\(files.count) 个文件")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Text(totalSize)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.bottom, 4)
    }

    private var totalSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(files.reduce(0) { $0 + $1.bytes }))
    }

    private func row(_ file: DownloadedFile) -> some View {
        HStack(spacing: 12) {
            Button {
                previewTarget = file
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon(for: file))
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.accentAlt)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 8) {
                            Text(file.sizeText)
                            Text(file.ageText)
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                pendingDelete = file
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.danger.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(Theme.surfaceRaised, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    /// Pick a glyph that hints at the file type.
    /// @param file - the stored file.
    /// @returns an SF Symbol name.
    private func icon(for file: DownloadedFile) -> String {
        let ext = file.url.pathExtension.lowercased()
        switch ext {
        case "zip", "gz", "tar", "7z": return "doc.zipper"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "pdf": return "doc.richtext"
        case "md", "txt", "log", "json", "yml", "yaml": return "doc.text"
        case "swift", "ts", "js", "py", "sh", "ps1": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    private func reload() {
        files = FileDelivery.storedFiles()
    }
}
