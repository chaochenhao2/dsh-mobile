import Foundation
import SwiftUI
import QuickLook

/// Hosts the system preview behind a local navigation bar.
///
/// Quick Look's own chrome cannot be restyled or localized by a third-party app,
/// so it is embedded under a bar this app owns: the sheet then opens and closes
/// with familiar Chinese actions, and everything inside the content area is
/// still the system renderer, which is what makes PDF, Office, video and source
/// files look right.
///
/// The critical difference from the earlier version is that the preview is
/// created once and its data source never changes. Reloading it from
/// `updateUIViewController` re-entered SwiftUI's update pass and froze the app.
struct FilePreviewSheet: View {
    let file: DownloadedFile
    @Environment(\.dismiss) private var dismiss

    /// Set when the system reports it cannot render this file.
    @State private var failure: String?
    /// Toggles a fresh identity for the preview controller when retrying.
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
                if let failure {
                    unavailable(failure)
                } else {
                    QuickLookPreview(url: file.url)
                        .id("\(file.url.lastPathComponent)-\(attempt)")
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if failure != nil {
                        Button("重试") {
                            self.failure = nil
                            self.attempt += 1
                        }
                    } else {
                        ShareLink(item: file.url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    private func unavailable(_ reason: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("这台设备无法预览这个文件")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(reason)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
            ShareLink(item: file.url) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("用其他应用打开")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Theme.accentGradient, in: Capsule())
            }
            .padding(.top, 6)
        }
        .padding(32)
    }
}

/// Presents the system preview for one stored file.
///
/// Quick Look renders far more formats than this app ever could — PDF, Office
/// documents, video, archives, and source — so it is the right renderer. The
/// controller is created once and never reloaded: SwiftUI calls
/// `updateUIViewController` on every pass, and calling `reloadData()` there
/// scheduled another pass, which is what froze the app.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    /// Deliberately empty: the URL is fixed for this preview's lifetime.
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}