import SwiftUI

/// What this phone is paired with, and the way out.
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var isSwitching = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let info = store.info {
                            hostCard(info)
                            routeCard(info)
                            capabilityCard(info)
                        } else {
                            Card {
                                Text("尚未连接到电脑。")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Button {
                            store.disconnect()
                            dismiss()
                        } label: {
                            Text("断开连接")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.danger)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func hostCard(_ info: BridgeInfo) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "电脑")
                heading(info.host.hostname, subtitle: "\(info.host.platform) · \(store.endpoint.displayAddress)")
                Divider().overlay(Theme.border)
                keyValue("Harness", info.dsh.version ?? "未知")
                keyValue("Electron", info.dsh.electron ?? "—")
                keyValue("桥接", info.bridge.version)
                if let profile = info.profile.name {
                    keyValue("Profile", profile)
                }
                if let web = info.host.webUrl {
                    keyValue("Web GUI", web)
                }
            }
        }
    }

    /// Every network this computer is reachable on, with a one-tap switch.
    ///
    /// A phone that moves between home Wi-Fi and a tailnet needs this: the
    /// address that worked on the sofa stops working on cellular, and the
    /// person should not have to retype anything.
    private func routeCard(_ info: BridgeInfo) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "可用网络")
                ForEach(info.host.orderedCandidates, id: \.address) { candidate in
                    let isCurrent = candidate.address == store.endpoint.host
                    Button {
                        guard !isCurrent else { return }
                        isSwitching = true
                        Task {
                            await store.reconnect(host: candidate.address)
                            isSwitching = false
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isCurrent ? Theme.success : Theme.textTertiary)
                                .font(.system(size: 13))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.label)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(candidate.address)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer(minLength: 0)
                            if isCurrent {
                                Text("当前")
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(Theme.success)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSwitching || isCurrent)
                }
                if isSwitching {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("切换中…")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    private func capabilityCard(_ info: BridgeInfo) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "能力")
                FlowText(items: info.bridge.capabilities)
            }
        }
    }

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

/// A wrapped list of small tags.
struct FlowText: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }
}
