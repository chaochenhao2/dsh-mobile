import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// One Session's conversation, followed live.
struct ChatView: View {
    @StateObject private var chat: ChatStore
    /// The shared pairing, used by sheets that need their own transport (files).
    @EnvironmentObject private var store: AppStore
    @State private var draft = ""
    /// Node ids whose reasoning section the person opened by hand.
    @State private var expandedReasoning: Set<String> = []
    @State private var showsModelPicker = false
    @State private var showsFileBrowser = false
    /// Files queued for the next prompt, including ones still uploading.
    @State private var attachments: [PendingAttachment] = []
    @State private var showsAttachmentMenu = false
    @State private var showsPhotoPicker = false
    @State private var showsFileImporter = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @FocusState private var isComposerFocused: Bool

    /// Whether the composer has anything to send.
    private var canSend: Bool {
        let hasText = !draft.trimmed.isEmpty
        let hasReady = attachments.contains { $0.isReady }
        // While an upload is still running the send button stays idle rather
        // than promising to deliver a file that has no path yet.
        return (hasText || hasReady) && !attachments.contains { $0.isUploading }
    }

    private let title: String

    init(sessionID: String, title: String, endpoint: Endpoint) {
        self.title = title
        // The store is built first so the transport's retry reporter can call
        // back into it; `ChatStore.api` is immutable and holds a copy of the
        // struct, so the closure must be installed before that copy is made.
        let store = ChatStore(
            sessionID: sessionID,
            title: title,
            api: BridgeAPI(endpoint: endpoint)
        )
        _chat = StateObject(wrappedValue: store)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                transcript
                composer
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    if let permissions = chat.permissions, !permissions.options.isEmpty {
                        Menu {
                            ForEach(permissions.options) { option in
                                Button {
                                    Task { await chat.switchPermission(option.value) }
                                } label: {
                                    if option.value == permissions.currentValue {
                                        Label(option.name, systemImage: "checkmark")
                                    } else {
                                        Text(option.name)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(permissions.currentValue == nil ? Theme.textTertiary : Theme.accentAlt)
                        }
                        .disabled(chat.isSwitchingPermission)
                    }
                    Button {
                        showsModelPicker = true
                    } label: {
                        Image(systemName: "cpu")
                    }
                    Menu {
                        Button {
                            showsFileBrowser = true
                        } label: {
                            Label("工作区文件", systemImage: "folder")
                        }
                        Divider()
                        Toggle("显示上下文注入", isOn: $chat.showNotices)
                        Button("重新读取") {
                            Task { await chat.load() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showsModelPicker) {
            ModelPickerView(chat: chat)
        }
        .sheet(isPresented: $showsFileBrowser) {
            if let api = store.api {
                FileBrowserView(sessionID: chat.sessionID, api: api)
            } else {
                Text("尚未连接。")
                    .foregroundStyle(Theme.textSecondary)
                    .padding(32)
            }
        }
        .task {
            chat.attachRetryReporter()
            await chat.start()
        }
        .onDisappear {
            chat.stop()
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chat.isLoading && chat.nodes.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("读取中…")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                    }
                    ForEach(chat.visibleNodes) { node in
                        nodeView(node)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.tick, perform: { _ in
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            })
        }
    }

    @ViewBuilder
    private func nodeView(_ node: TranscriptNode) -> some View {
        switch node.role {
        case .user:
            userBubble(node)
        case .assistant:
            assistantBubble(node)
        case .tool:
            toolRow(node)
        case .notice, .unknown:
            noticeRow(node)
        }
    }

    private func userBubble(_ node: TranscriptNode) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(node.text)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func assistantBubble(_ node: TranscriptNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accentAlt)
                Text("Harness")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
                if node.isStreaming {
                    ProgressView()
                        .tint(Theme.accentAlt)
                }
            }
            if node.hasReasoning, let reasoning = node.reasoning {
                reasoningSection(node, reasoning)
            }
            if node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(node.isStreaming ? "思考中…" : "（空回复）")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                MarkdownView(text: node.text)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        // Long-press actions on the bubble. Selecting text already works, but
        // taking the whole message needs a menu: quoting an assistant answer
        // into the composer is the common follow-up on a phone.
        .contextMenu {
            Button {
                UIPasteboard.general.string = node.text
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button {
                draft = node.text
            } label: {
                Label("引用到输入框", systemImage: "text.bubble")
            }
        }
    }

    /// Collapsible thinking trace. It stays open while the model is still
    /// reasoning so the person sees progress, and folds away once the answer
    /// starts arriving so it does not bury the result.
    private func reasoningSection(_ node: TranscriptNode, _ reasoning: String) -> some View {
        let isOpen = expandedReasoning.contains(node.id) || node.isStreaming
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if expandedReasoning.contains(node.id) {
                    expandedReasoning.remove(node.id)
                } else {
                    expandedReasoning.insert(node.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("思考过程")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Text("\(reasoning.count) 字")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)

            if isOpen {
                Text(reasoning)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.surfaceRaised.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func toolRow(_ node: TranscriptNode) -> some View {
        let info = node.tool
        let status = info?.status ?? "running"
        let tint: Color = {
            switch status {
            case "error": return Theme.danger
            case "done": return Theme.success
            default: return Theme.warning
            }
        }()
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let arguments = info?.arguments, !arguments.isEmpty {
                    Text(arguments)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let result = info?.result, !result.isEmpty {
                    Text(result)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if status == "running" {
                    Text("执行中…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
                if let reason = info?.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.danger)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(info?.name ?? node.text)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(status)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(tint)
            }
        }
        .padding(10)
        .background(Theme.surfaceRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func noticeRow(_ node: TranscriptNode) -> some View {
        Text(node.text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(4)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if let error = chat.lastError {
                ErrorBanner(message: error)
                    .padding(.horizontal, 16)
            }
            HStack(spacing: 6) {
                StatusDot(color: chat.isRetrying ? Theme.warning : (chat.isRunning ? Theme.success : Theme.textTertiary))
                if chat.isRetrying {
                    Text("重连中… \(chat.retryCount)/\(RetryPolicy.maxAttempts - 1)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.warning)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(chat.runningDescription)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                if let model = chat.model {
                    Text("·").foregroundStyle(Theme.textTertiary)
                    Button {
                        showsModelPicker = true
                    } label: {
                        Text(model.displayName(in: chat.catalog))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.accentAlt)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                if let permission = chat.permissions?.current {
                    Text("·").foregroundStyle(Theme.textTertiary)
                    Text(permission.name)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(permissionTint(permission.value))
                        .lineLimit(1)
                }
                Spacer()
                if !chat.pendingInput.isEmpty {
                    Text("需要你在电脑上确认")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                }
            }
            .padding(.horizontal, 18)

            // Pending attachments sit above the input so the person sees what is
            // about to be sent, including any that failed to upload.
            if !attachments.isEmpty {
                attachmentStrip
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    showsAttachmentMenu = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 21))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 34, height: 42)
                }
                .confirmationDialog("添加附件", isPresented: $showsAttachmentMenu) {
                    Button("照片与视频") { showsPhotoPicker = true }
                    Button("文件") { showsFileImporter = true }
                    Button("取消", role: .cancel) {}
                }
                TextField("给 Harness 发消息…", text: $draft, axis: .vertical)
                    .focused($isComposerFocused)
                    .lineLimit(1...5)
                    .font(.system(size: 15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                if chat.isRunning {
                    Button {
                        Task { await chat.cancel() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.danger)
                            .frame(width: 42, height: 42)
                            .background(Theme.surfaceRaised, in: Circle())
                    }
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(
                                Circle().fill(canSend ? Theme.accent : Theme.surfaceRaised)
                            )
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .padding(.top, 8)
        .background(Theme.background.opacity(0.98))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
        }
        .photosPicker(
            isPresented: $showsPhotoPicker,
            selection: $photoSelection,
            maxSelectionCount: 10,
            matching: .any(of: [.images, .videos])
        )
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .onChange(of: photoSelection) { _ in
            loadPickedPhotos()
        }
    }

    /// Horizontal strip of pending attachments.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachmentChip(attachment)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    private func attachmentChip(_ attachment: PendingAttachment) -> some View {
        VStack(spacing: 3) {
            ZStack {
                if let thumbnail = attachment.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: attachment.glyph)
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accentAlt)
                }
                if attachment.isUploading {
                    Color.black.opacity(0.45)
                    ProgressView().tint(.white).scaleEffect(0.7)
                }
                if attachment.failure != nil {
                    Color.black.opacity(0.55)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.warning)
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        attachment.failure == nil ? Theme.border : Theme.warning.opacity(0.7),
                        lineWidth: 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    attachments.removeAll { $0.id == attachment.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white, Color.black.opacity(0.6))
                }
                .offset(x: 4, y: -4)
            }

            Text(attachment.sizeText)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// Colour a permission preset by how much it allows, so a dangerous
    /// selection is visible at a glance rather than only by its name.
    /// @param value - preset value from the catalog.
    /// @returns the tint for that preset.
    private func permissionTint(_ value: String) -> Color {
        switch value {
        case "read-only": return Theme.textSecondary
        case "workspace-write": return Theme.accentAlt
        case "danger-full-access", "auto": return Theme.warning
        default: return Theme.textTertiary
        }
    }

    private func send() {
        let text = draft.trimmed
        let ready = attachments.filter { $0.isReady }
        guard !text.isEmpty || !ready.isEmpty else { return }
        draft = ""
        attachments = []
        Task {
            await chat.send(text, attachments: ready)
        }
    }

    /// Enqueue files picked from the photo library.
    ///
    /// Each item is loaded and uploaded independently: one failure leaves the
    /// others usable instead of discarding the whole selection.
    private func loadPickedPhotos() {
        let items = photoSelection
        photoSelection = []
        guard !items.isEmpty else { return }
        for (index, item) in items.enumerated() {
            Task {
                let load = Task {
                    try? await item.loadTransferable(type: Data.self)
                }
                guard let data = await load.value else { return }
                // A picked item carries no file name, so one is derived from the
                // type and position; the bridge prefixes a timestamp regardless.
                let type = item.supportedContentTypes.first
                let extensionPart = type?.preferredFilenameExtension ?? "bin"
                let name = "IMG-\(Int(Date().timeIntervalSince1970))-\(index).\(extensionPart)"
                let picked = PickedFile.make(name: name, type: type, data: data)
                await upload(picked)
            }
        }
    }

    /// Enqueue files chosen from the document picker.
    /// @param result - the picker's outcome.
    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        for url in urls {
            Task {
                // Files outside the app's container need explicit access before
                // their bytes can be read.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                let type = UTType(filenameExtension: url.pathExtension)
                let picked = PickedFile.make(name: url.lastPathComponent, type: type, data: data)
                await upload(picked)
            }
        }
    }

    /// Upload one file and keep its row in the strip until the send clears it.
    /// @param picked - the bytes to upload.
    private func upload(_ picked: PickedFile) async {
        // The row is inserted before the upload starts so the spinner is visible
        // immediately, then replaced with the finished one.
        let placeholder = PendingAttachment(
            name: picked.name,
            kind: picked.kind,
            bytes: picked.data.count,
            thumbnail: picked.isImage ? UIImage(data: picked.data) : nil,
            remotePath: nil,
            isUploading: true,
            failure: nil
        )
        attachments.append(placeholder)
        let finished = await chat.upload(picked)
        if let index = attachments.firstIndex(where: { $0.id == placeholder.id }) {
            // Keep the published identity so SwiftUI updates the row in place
            // instead of animating a removal and an insertion.
            attachments[index] = PendingAttachment(
                id: placeholder.id,
                name: finished.name,
                kind: finished.kind,
                bytes: finished.bytes,
                thumbnail: finished.thumbnail ?? placeholder.thumbnail,
                remotePath: finished.remotePath,
                isUploading: finished.isUploading,
                failure: finished.failure
            )
        }
    }
}

extension String {
    /// The value with surrounding whitespace removed.
    ///
    /// Used for emptiness checks on composed input, where a message of spaces
    /// should not enable the send button.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
