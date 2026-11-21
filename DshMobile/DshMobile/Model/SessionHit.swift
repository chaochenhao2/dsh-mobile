import Foundation

/// One Session search hit, with the text that matched.
struct SessionHit: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let running: Bool
    /// The matching excerpt, present when the match came from a message body.
    let snippet: String?
    /// The device this hit came from, filled in when results are merged.
    var deviceId: String?
    var deviceName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case running
        case snippet
        case deviceId
        case deviceName
    }

    init(
        id: String,
        title: String,
        running: Bool,
        snippet: String?,
        deviceId: String? = nil,
        deviceName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.running = running
        self.snippet = snippet
        self.deviceId = deviceId
        self.deviceName = deviceName
    }

    /// Decode a hit from the bridge.
    ///
    /// Written out because the memberwise initializer above suppresses the
    /// synthesised one; the origin fields are absent on the wire and default to
    /// nil until results are merged.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        running = (try? container.decode(Bool.self, forKey: .running)) ?? false
        snippet = try? container.decode(String.self, forKey: .snippet)
        deviceId = nil
        deviceName = nil
    }

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
    /// How the match was made: the Harness's transcript index, or a title match
    /// when that index is disabled on this deployment.
    let mode: String?

    /// Whether results cover message bodies rather than only titles.
    var isTranscriptSearch: Bool { mode == "transcript" }
}
