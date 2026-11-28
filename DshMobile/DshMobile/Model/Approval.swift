import Foundation

/// One approval prompt waiting for the person's decision.
struct ApprovalPrompt: Decodable, Identifiable, Equatable {
    let id: String
    /// The tool whose operation needs a decision.
    let toolName: String
    /// The asker's explanation, when it gave one.
    let reason: String?
    /// Localized explanations keyed by locale.
    let displayReason: [String: String]?
    let callId: String?
    let sessionId: String?
    let createdAt: Double?
    let expiresAt: Double?

    /// The best available explanation, preferring a Chinese string.
    var explanation: String? {
        if let displayReason {
            for key in ["zh", "zh-CN", "en"] {
                if let text = displayReason[key], !text.isEmpty { return text }
            }
        }
        guard let reason, !reason.isEmpty else { return nil }
        return reason
    }

    /// How long is left before the prompt expires.
    var remainingSeconds: Int? {
        guard let expiresAt else { return nil }
        let remaining = expiresAt / 1000 > Date().timeIntervalSince1970
            ? expiresAt / 1000 - Date().timeIntervalSince1970
            : expiresAt - Date().timeIntervalSince1970
        return max(0, Int(remaining.rounded()))
    }
}

/// Payload of `GET /api/approvals`.
struct ApprovalsPayload: Decodable {
    let items: [ApprovalPrompt]
}

/// Counts the bridge reports alongside the list.
struct SessionCounts: Decodable, Equatable {
    let total: Int
    let subagents: Int
    let archived: Int
}

/// Which rows the session list hides.
///
/// Archive and delegation are independent choices: someone may want their
/// delegated children visible while hiding long-finished work.
struct SessionFilters: Equatable {
    var showsSubagents: Bool
    var showsArchived: Bool

    private static let subagentKey = "com.dshmobile.filter.subagents"
    private static let archivedKey = "com.dshmobile.filter.archived"

    /// Read the saved choices; both default to hidden because the list is
    /// dominated by finished and delegated rows otherwise.
    init() {
        showsSubagents = UserDefaults.standard.bool(forKey: Self.subagentKey)
        showsArchived = UserDefaults.standard.bool(forKey: Self.archivedKey)
    }

    /// Persist the current choices.
    func save() {
        UserDefaults.standard.set(showsSubagents, forKey: Self.subagentKey)
        UserDefaults.standard.set(showsArchived, forKey: Self.archivedKey)
    }

    /// Whether one row survives the filters.
    /// @param row - the Session row to test.
    /// @returns true when it should be listed.
    func admits(_ row: SessionRow) -> Bool {
        // A subagent that is also archived must pass both checks, so the
        // narrower of the two wins.
        if row.subagent && !showsSubagents { return false }
        if row.archived && !showsArchived { return false }
        return true
    }
}
