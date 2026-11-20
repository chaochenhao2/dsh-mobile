import Foundation
import UIKit

/// Writes downloads into a temporary directory and hands them to the system.
///
/// A sandboxed app cannot write to the Files app's Downloads folder directly.
/// The supported path is the share sheet, which offers "Save to Files" and lets
/// the person choose where the file lands — including Downloads. The file is
/// staged in the app's own temporary directory first, because the sheet copies
/// from a URL it can read.
enum FileDelivery {
    /// Directory holding staged downloads.
    private static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("downloads", isDirectory: true)
    }

    /// Write bytes to a unique staged file.
    /// @param data - the file contents.
    /// @param name - the file name to present.
    /// @returns the staged file, or nil when writing failed.
    static func stage(data: Data, name: String) -> DownloadedFile? {
        let directory = stagingDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        // Keep the original name recognizable while avoiding collisions across
        // repeated downloads of the same selection.
        let safeName = sanitize(name)
        let destination = directory.appendingPathComponent(uniqueName(for: safeName))
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            return nil
        }
        return DownloadedFile(name: destination.lastPathComponent, url: destination, bytes: data.count)
    }

    /// Present the system share sheet for one file.
    /// @param file - the staged file to hand over.
    static func present(_ file: DownloadedFile) {
        guard let controller = topViewController() else { return }
        let activity = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        // iPad requires an anchor or the sheet crashes on presentation.
        if let popover = activity.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(
                x: controller.view.bounds.midX,
                y: controller.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        controller.present(activity, animated: true)
    }

    /// Remove staged files older than one hour.
    ///
    /// The share sheet has already copied what it needs, so stale staging is
    /// only wasted space.
    static func pruneStaged() {
        let directory = stagingDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-3_600)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
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
    /// @returns a name not yet present in the staging directory.
    private static func uniqueName(for name: String) -> String {
        let directory = stagingDirectory
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

    /// Find the controller a sheet can be presented from.
    /// @returns the top-most presented controller.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        guard let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            return nil
        }
        var controller = window.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}