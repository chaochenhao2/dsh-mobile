import SwiftUI

/// Pairs computers and shows which of them are reachable.
///
/// This is the replacement for the old connect screen: pairing is a one-time
/// act per computer, and from then on the app reaches every known device on its
/// own.
struct DevicesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var showsPairing = false
    @State private var discovered: [DiscoveredBridge] = []
    @State private var pendingForget: Device?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsPairing = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showsPairing) {
                PairDeviceView()
                    .environmentObject(store)
            }
            .confirmationDialog(
                "移除这台设备？",
                isPresented: Binding(
                    get: { pendingForget != nil },
                    set: { if !$0 { pendingForget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("移除", role: .destructive) {
                    if let device = pendingForget {
                        store.forget(id: device.id)
                    }
                    pendingForget = nil
                }
                Button("取消", role: .cancel) { pendingForget = nil }
            } message: {
                Text(pendingForget?.name ?? "")
            }
            .task {
                await store.refreshSessions()
            }
            .refreshable {
                await store.refreshSessions()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.registry.devices.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    HStack {
                        Text(store.statusSummary)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        if store.registry.isProbing {
                            ProgressView().tint(Theme.accent).scaleEffect(0.7)
                        }
                    }
                    .padding(.bottom, 4)

                    ForEach(store.registry.devices) { device in
                        deviceRow(device)
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("还没有配对的电脑")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("配对一次之后，打开 App 就会自动连上，无需再手动连接。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
            Button("配对新设备") { showsPairing = true }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 220)
                .padding(.top, 8)
        }
        .padding(32)
    }

    private func deviceRow(_ device: Device) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(device.isOnline ? Theme.success : Theme.textTertiary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(device.platformLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.surfaceRaised, in: Capsule())
                }
                Text(device.displayAddress)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                if device.isOnline {
                    Text("在线 · \(device.seenText)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.success.opacity(0.9))
                } else if let reason = store.error(for: device.id) {
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warning)
                        .lineLimit(1)
                } else {
                    Text("离线 · \(device.seenText)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button {
                    pendingForget = device
                } label: {
                    Label("移除设备", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 34, height: 34)
                    .background(Theme.surfaceRaised, in: Circle())
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    device.isOnline ? Theme.success.opacity(0.25) : Theme.border,
                    lineWidth: 1
                )
        )
    }
}