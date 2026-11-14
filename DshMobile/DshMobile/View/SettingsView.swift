import SwiftUI

/// What this phone is paired with, and the way out.
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let info = store.info {
                            hostCard(info)
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
                ForEach(info.host.addresses, id: \.self) { address in
                    keyValue("网卡", address)
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
