import Foundation
import UIKit

/// Stores downloads in the app's Documents container.
///
/// Because the app declares `UIFileSharingEnabled` and
/// `LSSupportsOpeningDocumentsInPlace`, this folder is exactly what the Files
/// app shows under "On My iPhone → DSH Mobile". A sandboxed app cannot write to
/// the system Downloads folder, but it fully owns this one, so downloads land
/// without a share-sheet round trip and stay reachable from the Files app.
enum FileDelivery {
    /// The app's Documents directory, created on first use.
    static var documentsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    /// Write bytes into Documents under a collision-free name.
    /// @param data - the file contents.
    /// @param name - the suggested file name.
    /// @returns the stored file, or nil when writing failed.
    static func store(data: Data, name: String) -> DownloadedFile? {
        let directory = documentsDirectory
        let safeName = sanitize(name)
        let destination = directory.appendingPathComponent(uniqueName(for: safeName))
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            return nil
        }
        return DownloadedFile(name: destination.lastPathComponent, url: destination, bytes: data.count)
    }

    /// Every file currently held in Documents, newest first.
    /// @returns the stored downloads.
    static func storedFiles() -> [DownloadedFile] {
        let directory = documentsDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        ) else { return [] }
        return entries.compactMap { url -> DownloadedFile? in
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            )
            guard values?.isRegularFile == true else { return nil }
            return DownloadedFile(
                name: url.lastPathComponent,
                url: url,
                bytes: values?.fileSize ?? 0,
                modified: values?.contentModificationDate
            )
        }
        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// Delete one stored file.
    /// @param file - the file to remove.
    /// @returns whether it is gone.
    @discardableResult
    static func delete(_ file: DownloadedFile) -> Bool {
        do {
            try FileManager.default.removeItem(at: file.url)
            return true
        } catch {
            return false
        }
    }

    /// Total bytes used by stored downloads.
    /// @returns the sum of file sizes.
    static var storedBytes: Int {
        storedFiles().reduce(0) { $0 + $1.bytes }
    }

    /// Strip path separators and control characters from a suggested name.
    /// @param name - the name from the server.
    /// @returns a filesystem-safe name.
    private static func sanitize(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = name.components(separatedBy: forbidden).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "download.zip" : trimmed
    }

    /// Insert a counter before the extension when the name is taken.
    /// @param name - the desired file name.
    /// @returns a name not yet present in Documents.
    private static func uniqueName(for name: String) -> String {
        let directory = documentsDirectory
        var candidate = name
        var counter = 1
        let base = (name as NSString).deletingPathExtension
        let extensionPart = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = extensionPart.isEmpty
                ? "\(base) (\(counter))"
                : "\(base) (\(counter)).\(extensionPart)"
            counter += 1
        }
        return candidate
    }
}
