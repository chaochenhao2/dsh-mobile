import Foundation
import SwiftUI
import UIKit

/// What a stored file can be rendered as without leaving the app.
enum FilePreviewKind {
    case image(UIImage)
    case text(String)
    /// A ZIP-shaped container with its central directory listed.
    case archive([ArchiveMember])
    case unsupported(String)

    /// One file recorded inside an archive.
    struct ArchiveMember: Identifiable, Equatable {
        let id: Int
        let path: String
        let bytes: Int

        var sizeText: String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            return formatter.string(fromByteCount: Int64(bytes))
        }
    }

    /// How the file can be shown, decided from its bytes and extension.
    ///
    /// Only formats the app can draw itself are accepted. Handing the file to a
    /// system preview controller was the previous design, and it is both a
    /// light-themed interruption in a dark app and the cause of a re-entrant
    /// reload loop. Anything else reports why it cannot be drawn, and the
    /// person can still share it out.
    /// @param url - the stored file.
    /// @returns the renderable representation.
    static func load(from url: URL) -> FilePreviewKind {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let ext = url.pathExtension.lowercased()

        guard size <= maxBytes else {
            return .unsupported("文件过大（\(byteText(size))），无法在应用内预览。")
        }

        if imageExtensions.contains(ext) {
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                return .unsupported("无法解码这张图片。")
            }
            return .image(image)
        }

        // A ZIP listing needs the central directory, which is far more useful
        // than the generic placeholder the system shows for an archive.
        if archiveExtensions.contains(ext) {
            if let members = ArchiveReader.listMembers(of: url), !members.isEmpty {
                return .archive(members)
            }
            return .unsupported("无法读取这个压缩包的目录。")
        }

        guard textExtensions.contains(ext) || isProbablyText(url) else {
            return .unsupported("这种格式不支持应用内预览。")
        }

        guard let data = try? Data(contentsOf: url) else {
            return .unsupported("无法读取文件。")
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return .unsupported("文件不是可识别的文本编码。")
        }
        return .text(text)
    }

    /// Largest file the preview reads into memory.
    private static let maxBytes = 4 * 1024 * 1024

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff",
    ]

    private static let archiveExtensions: Set<String> = [
        "zip", "ipa", "jar", "apk", "xpi", "epub", "docx", "xlsx", "pptx",
    ]

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "yml", "yaml", "xml", "csv", "log",
        "swift", "ts", "tsx", "js", "jsx", "py", "rb", "go", "rs", "java", "kt",
        "c", "h", "cpp", "hpp", "cs", "php", "sh", "bash", "zsh", "ps1", "bat",
        "html", "css", "scss", "sql", "toml", "ini", "conf", "env", "gitignore",
        "patch", "diff", "properties", "gradle", "lock",
    ]

    /// Sniff the first bytes for binary content.
    /// @param url - the file to inspect.
    /// @returns true when the head looks like text.
    private static func isProbablyText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 512), !head.isEmpty else { return true }
        return !head.contains(0)
    }

    /// Format a byte count for a message.
    /// @param bytes - the size.
    /// @returns a human label.
    private static func byteText(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// Reads a ZIP's central directory without extracting anything.
///
/// Enough to answer "what is inside this archive" for the formats people
/// actually download here, and it never inflates a member, so a hostile or
/// corrupt archive cannot expand in memory.
enum ArchiveReader {
    /// List the members recorded in a ZIP's central directory.
    /// @param url - the archive to inspect.
    /// @returns the members, or nil when the file is not a readable ZIP.
    static func listMembers(of url: URL) -> [FilePreviewKind.ArchiveMember]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let total = (try? handle.seekToEnd()) ?? 0
        guard total >= 22 else { return nil }

        // The end-of-central-directory record lives in the last 64 KiB plus its
        // own 22-byte body, because a comment may follow it.
        let tailLength = min(Int(total), 65_557)
        guard let tail = try? read(handle, offset: total - UInt64(tailLength), length: tailLength) else {
            return nil
        }
        guard let eocd = lastEndRecord(in: tail) else { return nil }

        let entryCount = Int(eocd.count)
        let directorySize = Int(eocd.size)
        let directoryOffset = Int(eocd.offset)
        guard entryCount > 0, directorySize > 0 else { return [] }
        guard let directory = try? read(handle, offset: UInt64(directoryOffset), length: directorySize) else {
            return nil
        }

        var members: [FilePreviewKind.ArchiveMember] = []
        var cursor = 0
        for index in 0..<entryCount {
            guard cursor + 46 <= directory.count else { break }
            guard directory.readUInt32(cursor) == 0x02014b50 else { break }
            let compressed = Int(directory.readUInt32(cursor + 20))
            let uncompressed = Int(directory.readUInt32(cursor + 24))
            let nameLength = Int(directory.readUInt16(cursor + 28))
            let extraLength = Int(directory.readUInt16(cursor + 30))
            let commentLength = Int(directory.readUInt16(cursor + 32))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= directory.count else { break }
            let nameData = directory.subdata(in: nameStart..<(nameStart + nameLength))
            let rawName = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""
            // A trailing slash marks a directory entry, which has no payload.
            if !rawName.isEmpty, !rawName.hasSuffix("/") {
                members.append(
                    FilePreviewKind.ArchiveMember(
                        id: index,
                        path: rawName,
                        bytes: uncompressed > 0 ? uncompressed : compressed
                    )
                )
            }
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return members
    }

    /// Locate the end-of-central-directory record in the archive tail.
    /// @param tail - the last bytes of the file.
    /// @returns the count, size and offset, or nil when absent.
    private static func lastEndRecord(in tail: Data) -> (count: UInt16, size: UInt32, offset: UInt32)? {
        guard tail.count >= 22 else { return nil }
        var index = tail.count - 22
        while index >= 0 {
            if tail.readUInt32(index) == 0x06054b50 {
                return (
                    count: tail.readUInt16(index + 10),
                    size: tail.readUInt32(index + 12),
                    offset: tail.readUInt32(index + 16)
                )
            }
            index -= 1
        }
        return nil
    }

    /// Read a byte range from an open handle.
    /// @param handle - the file handle.
    /// @param offset - first byte to read.
    /// @param length - number of bytes.
    /// @returns the bytes, or nil on failure.
    private static func read(_ handle: FileHandle, offset: UInt64, length: Int) -> Data? {
        guard let _ = try? handle.seek(toOffset: offset) else { return nil }
        return try? handle.read(upToCount: length)
    }
}

private extension Data {
    /// Read a little-endian unsigned 32-bit value.
    /// @param offset - byte position.
    /// @returns the value, or 0 when out of range.
    func readUInt32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { pointer in
            pointer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    /// Read a little-endian unsigned 16-bit value.
    /// @param offset - byte position.
    /// @returns the value, or 0 when out of range.
    func readUInt16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return withUnsafeBytes { pointer in
            pointer.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }
}

/// Renders one stored file in the app's own style.
struct FilePreviewView: View {
    let file: DownloadedFile
    @Environment(\.dismiss) private var dismiss

    @State private var kind: FilePreviewKind?
    @State private var isLoading = true
    /// Line numbers are useful for code but noise for prose.
    @State private var showsLineNumbers = true

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if case .text = kind {
                        Toggle(isOn: $showsLineNumbers) {
                            Image(systemName: "list.number")
                        }
                        .toggleStyle(.button)
                    }
                }
            }
            .task(id: file.url) { load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("读取中…").tint(Theme.accent)
        } else if let kind {
            switch kind {
            case let .image(image):
                imageView(image)
            case let .text(text):
                textView(text)
            case let .archive(members):
                archiveView(members)
            case let .unsupported(reason):
                unsupportedView(reason)
            }
        }
    }

    private func imageView(_ image: UIImage) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .padding(16)
        }
    }

    private func textView(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 10) {
                if showsLineNumbers {
                    Text(lineNumbers(for: text))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary.opacity(0.6))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.disabled)
                }
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
    }

    /// List what an archive contains, with a size per member.
    private func archiveView(_ members: [FilePreviewKind.ArchiveMember]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack {
                    Text("\(members.count) 个条目")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Text(totalText(members))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                ForEach(members) { member in
                    HStack(spacing: 10) {
                        Image(systemName: "doc")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 16)
                        Text(member.path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(member.sizeText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    Rectangle()
                        .fill(Theme.border)
                        .frame(height: 0.5)
                        .padding(.leading, 42)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func totalText(_ members: [FilePreviewKind.ArchiveMember]) -> String {
        let total = members.reduce(0) { $0 + $1.bytes }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(total))
    }

    private func unsupportedView(_ reason: String) -> some View {        VStack(spacing: 14) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(reason)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Text("\(file.sizeText) · 已保存在「文件 → DSH Mobile」")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
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

    /// Build a right-aligned gutter of line numbers.
    /// @param text - the file contents.
    /// @returns the gutter text.
    private func lineNumbers(for text: String) -> String {
        let count = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let width = String(count).count
        return (1...max(count, 1))
            .map { String($0).leftPadded(to: width) }
            .joined(separator: "\n")
    }

    private func load() {
        isLoading = true
        let url = file.url
        // Read and decode off the main actor so a large file never blocks the
        // sheet, then publish once. The previous design drove a system preview
        // controller from `updateUIViewController` and reloaded it on every
        // SwiftUI pass, which kept re-entering itself and froze the app.
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FilePreviewKind.load(from: url)
            }.value
            kind = result
            isLoading = false
            if case .text = result { showsLineNumbers = true }
        }
    }
}

private extension String {
    /// Pad with leading spaces to a fixed width.
    /// @param width - the target width.
    /// @returns the padded string.
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}