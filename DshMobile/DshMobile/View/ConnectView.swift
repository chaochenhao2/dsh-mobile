import SwiftUI

extension String {
    /// The value without leading or trailing whitespace.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Pairing screen: find the computer, then prove the token.
struct ConnectView: View {
    @EnvironmentObject private var store: AppStore

    @State private var host = ""
    @State private var port = "5180"
    @State private var token = ""
    @State private var found: [DiscoveredBridge] = []
    @State private var isScanning = false
    @State private var isConnecting = false
    @State private var discovery: UDPDiscovery?
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    connectionCard
                    discoverySection
                    if let error = store.lastError {
                        ErrorBanner(message: error)
                    }
                    connectButton
                    hint
                }
                .padding(20)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear(perform: restore)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
                Text("DSH Mobile")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text("在手机上读取并驱动电脑里的 DeepSeek Harness。")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 24)
    }

    private var connectionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(text: "连接")
                field(title: "主机", placeholder: "192.168.1.10", text: $host, keyboard: .URL)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("端口")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                        TextField("5180", text: $port)
                            .keyboardType(.numberPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 15, design: .monospaced))
                            .padding(12)
                            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .frame(width: 110)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("配对令牌")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    SecureField("config.json 里的 token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 15, design: .monospaced))
                        .padding(12)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func field(title: String, placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 15, design: .monospaced))
                .padding(12)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "局域网")
                Spacer()
                Button(action: toggleScan) {
                    HStack(spacing: 6) {
                        if isScanning {
                            ProgressView()
                                .tint(Theme.accent)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                        Text(isScanning ? "搜索中…" : "自动发现")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .disabled(isScanning)
            }
            if found.isEmpty {
                Text(isScanning ? "正在收听电脑的广播…" : "点“自动发现”，或直接填写上方地址。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(found) { bridge in
                    Button {
                        adopt(bridge)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(Theme.accentAlt)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(bridge.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(subtitle(for: bridge))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(12)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func subtitle(for bridge: DiscoveredBridge) -> String {
        var parts = ["\(bridge.host):\(bridge.port)"]
        if let version = bridge.harnessVersion { parts.append("Harness \(version)") }
        if bridge.token == nil { parts.append("需手动填令牌") }
        return parts.joined(separator: " · ")
    }

    private var connectButton: some View {
        Button(action: connect) {
            HStack(spacing: 8) {
                if isConnecting {
                    ProgressView().tint(.white)
                }
                Text(isConnecting ? "连接中…" : "连接")
            }
        }
        .buttonStyle(PrimaryButtonStyle(isEnabled: !isConnecting))
        .disabled(isConnecting)
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("令牌在电脑上的 ~/.dsh/mobile-bridge/config.json")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Text("手机与电脑需在同一 Wi-Fi，并允许“本地网络”权限。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Actions

    private func restore() {
        host = store.endpoint.host
        port = String(store.endpoint.port)
        token = store.endpoint.token
    }

    private func connect() {
        isConnecting = true
        scanTask?.cancel()
        discovery?.stop()
        isScanning = false
        var next = Endpoint()
        next.host = host.trimmed
        next.port = Int(port.trimmed) ?? 5180
        next.token = token.trimmed
        Task {
            await store.adopt(next)
            isConnecting = false
        }
    }

    private func adopt(_ bridge: DiscoveredBridge) {
        host = bridge.host
        port = String(bridge.port)
        if let bridgedToken = bridge.token, !bridgedToken.isEmpty {
            token = bridgedToken
        }
        connect()
    }

    private func toggleScan() {
        if isScanning {
            scanTask?.cancel()
            scanTask = nil
            discovery?.stop()
            discovery = nil
            isScanning = false
            return
        }
        found = []
        isScanning = true
        let listener = UDPDiscovery()
        listener.start { beacon in
            if !found.contains(where: { $0.id == beacon.id }) {
                found.append(beacon)
            }
        }
        discovery = listener
        scanTask = Task {
            try? await Task.sleep(for: .seconds(6))
            if Task.isCancelled { return }
            listener.stop()
            discovery = nil
            isScanning = false
        }
    }
}
