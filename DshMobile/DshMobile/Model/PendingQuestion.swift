import Foundation

/// One option a question offers.
struct QuestionOption: Decodable, Equatable, Identifiable {
    let label: String
    let description: String?

    var id: String { label }
}

/// One question in a pending `ask_user_question` request.
struct PendingQuestion: Decodable, Identifiable, Equatable {
    let id: String
    let question: String
    let detail: String?
    let header: String?
    let multiSelect: Bool
    let options: [QuestionOption]

    /// Whether the person must type an answer because no options were offered.
    var requiresTypedAnswer: Bool { options.isEmpty }
}

/// A whole question set waiting for the person.
struct QuestionBatch: Decodable, Identifiable, Equatable {
    let id: String
    let createdAt: Double?
    let expiresAt: Double?
    let sessionId: String?
    let callId: String?
    let questions: [PendingQuestion]
}

/// Payload of `GET /api/questions`.
struct QuestionsPayload: Decodable {
    let items: [QuestionBatch]
}

/// One question's answer, in the shape the bridge sends.
struct QuestionAnswer: Encodable, Equatable {
    let id: String
    var selected: [String]
    var custom: String?

    /// Whether this answer carries anything.
    var isEmpty: Bool {
        selected.isEmpty && (custom ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Draft state for one question while the person answers.
///
/// Kept separate from the wire type so edits stay cheap: the sheet mutates this
/// and only converts to `QuestionAnswer` on submit.
struct QuestionDraft: Equatable {
    let question: PendingQuestion
    /// Labels currently chosen.
    var selected: Set<String> = []
    /// Free text typed into the custom row.
    var custom: String = ""
    /// Whether the custom row is the active choice.
    ///
    /// Picking any option clears it, and typing into it clears the options for a
    /// single-select question, mirroring the official composer where the custom
    /// line is the last row rather than a parallel field.
    var usesCustom: Bool = false

    init(question: PendingQuestion) {
        self.question = question
    }

    /// Toggle one option, respecting the question's arity.
    /// @param label - the option label tapped.
    mutating func toggle(_ label: String) {
        // Choosing a listed option abandons the typed answer: the two are
        // alternatives, not additions, for a single-select question.
        if question.multiSelect {
            if selected.contains(label) {
                selected.remove(label)
            } else {
                selected.insert(label)
            }
            if !selected.isEmpty { usesCustom = false }
        } else {
            if selected == [label] {
                selected.removeAll()
            } else {
                selected = [label]
                usesCustom = false
            }
        }
    }

    /// Whether this question has an answer worth sending.
    var isAnswered: Bool {
        if usesCustom {
            return !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !selected.isEmpty
    }

    /// Convert to the wire answer.
    /// @returns the answer, or nil when nothing was chosen.
    func answer() -> QuestionAnswer? {
        if usesCustom {
            let text = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // A multi-select question keeps both the labels and the typed text,
            // which is what the official answer item allows.
            return QuestionAnswer(
                id: question.id,
                selected: question.multiSelect ? Array(selected) : [],
                custom: text
            )
        }
        guard !selected.isEmpty else { return nil }
        return QuestionAnswer(id: question.id, selected: Array(selected), custom: nil)
    }
}
