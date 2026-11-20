import Foundation

/// One entry inside a browsed directory.
struct FileEntry: Decodable, Identifiable, Equatable {
    let name: String
    /// `file`, `directory`, or `other`.
    let type: String
    let size: Int?
    /// Absolute path on the computer, which is what the archive request needs.
    let path: String

    var id: String { path }
    var isDirectory: Bool { type == "directory" }

    /// A compact size label, or nil for a directory.
    var sizeText: String? {
        guard let size else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(size))
    }
}

/// One directory level, as `GET /api/session/:id/files` reports it.
struct FileListing: Decodable, Equatable {
    /// The Session's workspace root.
    let root: String
    /// The directory being shown.
    let path: String
    /// The parent directory, or nil at the filesystem root.
    let parent: String?
    let truncated: Bool
    let entries: [FileEntry]

    /// Entries with directories first, then files, each alphabetically.
    ///
    /// The bridge returns the backend's name order; a person browsing wants
    /// folders grouped before loose files.
    var sorted: [FileEntry] {
        entries.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}

/// One item held in the app's Documents folder.
struct DownloadedFile: Identifiable, Equatable {
    /// Stable across reloads: `sheet(item:)` rebuilds its content whenever this
    /// changes, so a fresh UUID per listing would re-present the sheet forever.
    var id: String { url.lastPathComponent }
    let name: String
    let url: URL
    let bytes: Int
    /// When it was written, for ordering.
    var modified: Date? = nil

    /// A compact size label.
    var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// A relative age label.
    var ageText: String {
        guard let modified else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: modified, relativeTo: Date())
    }
}
