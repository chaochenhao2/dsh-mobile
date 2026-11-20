import Foundation

// MARK: - Workspaces

/// One durable workspace a new Session can be anchored to.
struct WorkspaceRow: Decodable, Identifiable, Equatable {
    let id: String
    let path: String
    let title: String
    let status: String
    let sessionCount: Int

    /// Whether the directory still exists. A missing workspace cannot host work.
    var isAvailable: Bool { status == "ok" }

    /// The last path component, for a compact row subtitle.
    var folderName: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? path
    }
}

/// Payload of `GET /api/workspaces`.
struct WorkspacesPayload: Decodable {
    let workspaces: [WorkspaceRow]
    let defaultDirectory: String?
}

// MARK: - Agent modes

/// One selectable agent composition mode.
struct AgentMode: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String?
    let builtIn: Bool
    /// A non-nil value means the preset failed to activate and cannot be used.
    let broken: String?

    /// Whether this mode can actually be selected.
    var isUsable: Bool { broken == nil }
}

/// Payload of `GET /api/modes`.
struct ModesPayload: Decodable {
    let modes: [AgentMode]
    let selectedDefault: String?
}

// MARK: - Permissions

/// One permission preset the person can switch to.
struct PermissionOption: Decodable, Identifiable, Equatable {
    let value: String
    let name: String
    let description: String?

    var id: String { value }
}

/// A Session's permission state and the options available to it.
struct PermissionsPayload: Decodable, Equatable {
    let options: [PermissionOption]
    let defaultPreset: String?
    let currentValue: String?

    /// The option matching the current value, when it is one of the presets.
    var current: PermissionOption? {
        guard let currentValue else { return nil }
        return options.first { $0.value == currentValue }
    }
}

/// What a new Session should be created with.
struct SessionDraft {
    /// An existing workspace to anchor to, when one was chosen.
    var workspace: WorkspaceRow?
    /// A directory typed by hand, used when no workspace was chosen.
    var customPath: String = ""
    /// The agent mode, or nil to let the Harness use its default.
    var mode: AgentMode?

    /// The directory to request, if one was named directly.
    var effectivePath: String? {
        let typed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return workspace?.path
    }
}
