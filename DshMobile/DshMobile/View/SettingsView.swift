import SwiftUI

/// Device status, plus the way to add or forget a computer.
///
/// The old screen described one live connection; this one describes the set of
/// paired devices, because there may be several and none of them is "the"
/// connection any more.
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        statusCard
                        deviceListCard
                        Button {
                            dismiss()
                        } label: {
                            Text("关闭")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                await store.refreshSessions()
            }
        }
    }

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "状态")
                HStack(spacing: 8) {
                    StatusDot(color: store.hasAnyOnlineDevice ? Theme.success : Theme.warning)
                    Text(store.statusSummary)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                }
                Divider().overlay(Theme.border)
                keyValue("本机名称", DeviceRegistry.phoneName)
                keyValue("已配对", "\(store.registry.devices.count) 台")
                keyValue("在线", "\(store.registry.onlineDevices.count) 台")
            }
        }
    }

    private var deviceListCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "设备")
                if store.registry.devices.isEmpty {
                    Text("还没有配对任何电脑。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(store.registry.devices) { device in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(device.isOnline ? Theme.success : Theme.textTertiary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            Text(device.name)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(device.platformLabel)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                Text("在会话页的设备列表里新增或移除设备。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
            }
        }
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}