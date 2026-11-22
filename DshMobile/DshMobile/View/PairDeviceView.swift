import SwiftUI

/// Pairs one computer by address, or by picking it from the LAN scan.
///
/// Replaces the old connect screen. Pairing is deliberate and rare, so it asks
/// for the address once and then the device is remembered. A token is only
/// needed when the computer was configured to require one.
struct PairDeviceView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = "5180"
    @State private var token = ""
    @State private var found: [DiscoveredBridge] = []
    @State private var isScanning = false
    @State private var isPairing = false
    @State private var error: String?
    @State private var discovery: UDPDiscovery?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let error {
                            ErrorBanner(message: error)
                        }
                        foundSection
                        fieldsSection
                        hintSection
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("配对电脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: pair) {
                        if isPairing {
                            ProgressView()
                        } else {
                            Text("配对").fontWeight(.semibold)
                        }
                    }
                    .disabled(isPairing || host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { if !isScanning { startScan() } }
            .onDisappear { stopScan() }
        }
    }

    private var foundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "同一网络中发现")
                Spacer()
                Button(isScanning ? "停止" : "扫描") { toggleScan() }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            if found.isEmpty {
                Text(isScanning ? "正在查找…" : "没有自动发现设备，可以手动填写地址。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(found) { bridge in
                    Button {
                        adopt(bridge)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.accentAlt)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bridge.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("\(bridge.host):\(bridge.port)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer(minLength: 0)
                            if bridge.token != nil {
                                Text("可直连")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.success)
                            }
                        }
                        .padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "手动填写")
            field(title: "地址", placeholder: "192.168.1.10", text: $host, keyboard: .URL)
            field(title: "端口", placeholder: "5180", text: $port, keyboard: .numberPad)
            field(title: "令牌（可选）", placeholder: "默认无密，留空即可", text: $token, keyboard: .asciiCapable)
        }
    }

    private var hintSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("默认无需令牌：在电脑侧边栏打开「DSH Mobile」即可看到地址。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Text("配对后两端都会记录这台设备，之后打开 App 自动连接。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func field(
        title: String,
        placeholder: String,
        text: Binding<String>,
        keyboard: UIKeyboardType
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: text)
                .font(.system(size: 13, design: .monospaced))
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - Actions

    private func adopt(_ bridge: DiscoveredBridge) {
        host = bridge.host
        port = String(bridge.port)
        // A beacon may carry the token when the bridge opts in, which removes the
        // step of copying it by hand.
        if let advertised = bridge.token { token = advertised }
        stopScan()
    }

    private func pair() {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard let portValue = Int(port.trimmingCharacters(in: .whitespaces)),
              (1...65_535).contains(portValue) else {
            error = "端口必须是 1 到 65535 之间的数字。"
            return
        }
        isPairing = true
        error = nil
        Task {
            defer { isPairing = false }
            do {
                _ = try await store.pair(
                    host: trimmedHost,
                    port: portValue,
                    token: token.trimmingCharacters(in: .whitespaces)
                )
                stopScan()
                dismiss()
            } catch {
                self.error = Self.describe(error)
            }
        }
    }

    private func toggleScan() {
        if isScanning {
            stopScan()
        } else {
            startScan()
        }
    }

    private func startScan() {
        isScanning = true
        found = []
        let listener = UDPDiscovery()
        discovery = listener
        listener.start { [weak listener] bridge in
            // `start` invokes on the main queue, so mutating state is safe here.
            guard listener != nil else { return }
            let address = "\(bridge.host):\(bridge.port)"
            if let index = found.firstIndex(where: { "\($0.host):\($0.port)" == address }) {
                found[index] = bridge
            } else {
                found.append(bridge)
            }
        }
    }

    private func stopScan() {
        discovery?.stop()
        discovery = nil
        isScanning = false
    }

    private static func describe(_ error: Error) -> String {
        if let bridge = error as? BridgeError {
            return bridge.errorDescription ?? "配对失败。"
        }
        return error.localizedDescription
    }
}

