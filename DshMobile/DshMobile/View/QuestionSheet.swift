import SwiftUI

/// Answers one `ask_user_question` request.
///
/// Mirrors the official composer: every question is shown with its options, and
/// the last choice is always a free-text row so the person can say something the
/// model did not anticipate.
struct QuestionSheet: View {
    let batch: QuestionBatch
    /// Called with the answers when the person submits.
    let onSubmit: ([QuestionAnswer]) -> Void
    let onCancel: () -> Void

    @State private var drafts: [QuestionDraft] = []
    @FocusState private var focusedCustom: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach($drafts, id: \.question.id) { $draft in
                            questionSection($draft)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("需要你的回答")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("提交") { submit() }
                        .fontWeight(.semibold)
                        .disabled(!canSubmit)
                }
            }
            .onAppear(perform: prepare)
        }
    }

    /// Every question needs an answer before submitting.
    private var canSubmit: Bool {
        !drafts.isEmpty && drafts.allSatisfy { $0.isAnswered }
    }

    private func prepare() {
        guard drafts.isEmpty else { return }
        drafts = batch.questions.map { QuestionDraft(question: $0) }
    }

    private func submit() {
        let answers = drafts.compactMap { $0.answer() }
        guard answers.count == drafts.count else { return }
        onSubmit(answers)
    }

    @ViewBuilder
    private func questionSection(_ draft: Binding<QuestionDraft>) -> some View {
        let question = draft.wrappedValue.question
        VStack(alignment: .leading, spacing: 10) {
            if let header = question.header, !header.isEmpty {
                Text(header.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .tracking(0.6)
            }
            Text(question.question)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = question.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if question.multiSelect {
                Text("可多选")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accentAlt)
            }

            VStack(spacing: 8) {
                ForEach(question.options) { option in
                    optionRow(option, draft: draft)
                }
                // The custom row is always last, so it reads as "something else"
                // after the offered choices rather than replacing them.
                customRow(draft: draft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private func optionRow(_ option: QuestionOption, draft: Binding<QuestionDraft>) -> some View {
        let chosen = draft.wrappedValue.selected.contains(option.label)
        return Button {
            draft.wrappedValue.toggle(option.label)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: chosen
                    ? (draft.wrappedValue.question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                    : (draft.wrappedValue.question.multiSelect ? "square" : "circle"))
                    .font(.system(size: 15))
                    .foregroundStyle(chosen ? Theme.accent : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                chosen ? Theme.accent.opacity(0.10) : Theme.surfaceRaised,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(chosen ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func customRow(draft: Binding<QuestionDraft>) -> some View {
        let active = draft.wrappedValue.usesCustom
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                draft.wrappedValue.usesCustom = true
                focusedCustom = draft.wrappedValue.question.id
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: active ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(active ? Theme.accent : Theme.textTertiary)
                    Text("其他（自己输入）")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if active {
                TextField(
                    "直接说给模型听…",
                    text: draft.custom,
                    axis: .vertical
                )
                .focused($focusedCustom, equals: draft.wrappedValue.question.id)
                .lineLimit(2...6)
                .font(.system(size: 14))
                .padding(10)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
                )
                .onChange(of: draft.wrappedValue.custom) { value in
                    // Typing is what makes the custom row the chosen answer; a
                    // single-select question then drops its option.
                    if !value.isEmpty {
                        draft.wrappedValue.usesCustom = true
                        if !draft.wrappedValue.question.multiSelect {
                            draft.wrappedValue.selected.removeAll()
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            active ? Theme.accent.opacity(0.10) : Theme.surfaceRaised,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(active ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 1)
        )
    }
}