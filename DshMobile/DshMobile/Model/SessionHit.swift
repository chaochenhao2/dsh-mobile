import Foundation

/// One Session search hit, with the text that matched.
struct SessionHit: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let running: Bool
    /// The matching excerpt, present when the match came from a message body.
    let snippet: String?

    /// The excerpt flattened to one line, since a row can only show one.
    var previewText: String? {
        guard let snippet else { return nil }
        let flattened = snippet
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let collapsed = flattened.split(separator: " ").joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Payload of `GET /api/search`.
struct SearchPayload: Decodable {
    let items: [SessionHit]
    let hasMore: Bool
}
