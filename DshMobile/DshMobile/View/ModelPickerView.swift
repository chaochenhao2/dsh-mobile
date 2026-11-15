import SwiftUI

/// Model picker for one Session: provider-grouped models with an effort control
/// only where the route actually offers one.
struct ModelPickerView: View {
    @ObservedObject var chat: ChatStore
    @Environment(\.dismiss) private var dismiss

    /// The row the person is considering, before it is applied.
    @State private var draftProvider: String?
    @State private var draftModel: String?
    @State private var draftEffort: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: apply) {
                        if chat.isSwitchingModel {
                            ProgressView()
                        } else {
                            Text("应用").fontWeight(.semibold)
                        }
                    }
                    .disabled(!canApply)
                }
            }
            .task {
                await chat.loadCatalogIfNeeded()
                seedDraft()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if chat.isLoadingCatalog && chat.catalog == nil {
            ProgressView("加载模型中…")
                .tint(Theme.accent)
        } else if let catalog = chat.catalog {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    currentBanner(catalog)
                    ForEach(catalog.groups) { group in
                        providerSection(group, catalog: catalog)
                    }
                    if !catalog.failures.isEmpty {
                        failureSection(catalog)
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
                Text("无法读取模型列表")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Button("重试") {
                    Task { await chat.loadCatalogIfNeeded() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 200)
            }
        }
    }

    private func currentBanner(_ catalog: ModelCatalog) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "当前")
                Text(chat.model?.displayName(in: catalog) ?? "未选择")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle(for: chat.model, catalog: catalog))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func providerSection(_ group: ModelGroup, catalog: ModelCatalog) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: group.providerName)
            ForEach(group.models) { option in
                modelRow(option, provider: group.provider)
            }
        }
    }

    private func modelRow(_ option: ModelOption, provider: String) -> some View {
        let isChosen = draftProvider == provider && draftModel == option.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                draftProvider = provider
                draftModel = option.id
                // Default the effort to what the route prefers, so applying a
                // model with efforts never sends a value the route rejects.
                draftEffort = option.reasoning?.defaultEffort ?? option.reasoning?.efforts.first?.id
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isChosen ? Theme.accent : Theme.textTertiary)
                        .font(.system(size: 15))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(option.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            if let badge = option.badge {
                                Text(badge.text.text)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Theme.accentAlt)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Theme.accentAlt.opacity(0.15), in: Capsule())
                            }
                        }
                        if let description = option.description, !description.isEmpty {
                            Text(description)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The effort control exists only where the model advertises
            // choices; a model without them shows nothing extra.
            if isChosen, option.hasReasoning, let reasoning = option.reasoning {
                effortPicker(reasoning)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isChosen ? Theme.surfaceRaised : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isChosen ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: 1)
        )
    }

    private func effortPicker(_ reasoning: ModelOption.ModelReasoning) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("思考等级")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(reasoning.efforts) { effort in
                        let selected = draftEffort == effort.id
                        Button {
                            draftEffort = effort.id
                        } label: {
                            Text(effort.name)
                                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.white : Theme.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(selected ? Theme.accent : Theme.surfaceRaised)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func failureSection(_ catalog: ModelCatalog) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "不可用")
            ForEach(catalog.failures, id: \.id) { failure in
                Text("\(failure.id)：\(failure.message)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    // MARK: - Helpers

    private var canApply: Bool {
        guard let draftProvider, let draftModel else { return false }
        if chat.isSwitchingModel { return false }
        let unchanged = chat.model?.provider == draftProvider && chat.model?.model == draftModel
        return !unchanged || chat.model?.reasoningEffort != draftEffort
    }

    private func seedDraft() {
        guard let model = chat.model else {
            // No recorded selection yet: start on the deployment default.
            if let fallback = chat.catalog?.deploymentDefault {
                draftProvider = fallback.provider
                draftModel = fallback.model
                draftEffort = fallback.reasoningEffort
            }
            return
        }
        draftProvider = model.provider
        draftModel = model.model
        draftEffort = model.reasoningEffort
    }

    private func apply() {
        guard let draftProvider, let draftModel else { return }
        Task {
            let ok = await chat.switchModel(
                provider: draftProvider,
                model: draftModel,
                reasoningEffort: draftEffort
            )
            if ok { dismiss() }
        }
    }

    private func subtitle(for model: SessionModel?, catalog: ModelCatalog) -> String {
        guard let model else { return "—" }
        var parts = [model.providerName(in: catalog), model.model]
        if let effort = model.reasoningEffort, !effort.isEmpty {
            parts.append(effort)
        }
        return parts.joined(separator: " · ")
    }
}
