import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// One file being prepared for a prompt.
///
/// The bytes live on the computer already; this holds what the composer needs to
/// show the pending item and what the prompt needs to reference it after upload.
struct PendingAttachment: Identifiable, Equatable {
    /// Stable identity, so a row keeps its place when the upload result replaces
    /// the placeholder that stood in for it.
    let id: UUID
    /// Name shown in the composer.
    let name: String
    /// Classified kind, matching what the bridge records.
    let kind: String
    let bytes: Int
    /// Inline thumbnail for images, so the row shows the picture itself.
    let thumbnail: UIImage?
    /// Absolute path on the computer, set once the upload finishes.
    var remotePath: String?
    /// Whether the upload is still in flight.
    var isUploading: Bool
    /// Failure text when the upload did not complete.
    var failure: String?

    /// Build one row.
    /// @param id - identity to reuse, or a fresh one.
    init(
        id: UUID = UUID(),
        name: String,
        kind: String,
        bytes: Int,
        thumbnail: UIImage?,
        remotePath: String?,
        isUploading: Bool,
        failure: String?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.bytes = bytes
        self.thumbnail = thumbnail
        self.remotePath = remotePath
        self.isUploading = isUploading
        self.failure = failure
    }

    /// A compact size label.
    var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// Whether this item can be sent.
    var isReady: Bool {
        remotePath != nil && failure == nil && !isUploading
    }

    /// Whether the item is a picture.
    var isImage: Bool { kind == "image" }

    /// Whether the item is a video.
    var isVideo: Bool { kind == "video" }

    /// The glyph for a non-image attachment.
    var glyph: String {
        if isVideo { return "video" }
        let extensionPart = (name as NSString).pathExtension.lowercased()
        switch extensionPart {
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "7z": return "doc.zipper"
        case "md", "txt", "log", "json", "yml", "yaml": return "doc.text"
        case "swift", "ts", "js", "py", "sh": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

/// What one picked file looks like before it is uploaded.
struct PickedFile {
    let name: String
    let mediaType: String
    let data: Data
}

extension PickedFile {
    /// Classify a file the same way the bridge will.
    ///
    /// Deciding here lets the composer show the right thumbnail and lets the
    /// request declare a precise MIME type instead of a generic one.
    /// @param name - the file name.
    /// @param type - the type reported by the picker, when it has one.
    /// @returns a PickedFile with a usable media type.
    static func make(name: String, type: UTType?, data: Data) -> PickedFile {
        let resolved = type ?? UTType(filenameExtension: (name as NSString).pathExtension)
        let mediaType = resolved?.preferredMIMEType ?? "application/octet-stream"
        return PickedFile(name: name, mediaType: mediaType, data: data)
    }

    /// Whether these bytes are a picture the composer can show inline.
    var isImage: Bool { mediaType.hasPrefix("image/") }

    /// Whether these bytes are a video.
    var isVideo: Bool { mediaType.hasPrefix("video/") }

    /// The kind string the bridge records.
    var kind: String {
        if isImage { return "image" }
        if isVideo { return "video" }
        return "file"
    }
}
