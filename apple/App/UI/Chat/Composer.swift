import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Glass composer: attachment panel (Photo, Caméra, Document, Position, Sondage), the text
/// field ("Message chiffré", up to 6 lines) with the link preview it will send, and the round
/// button that morphs from mic (hold to record, slide left to cancel) to send arrow.
struct Composer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversationId: String
    @Binding var replyTo: ChatItem?
    @Binding var editing: ChatItem?

    @State private var text = ""
    @State private var recorder = VoiceRecorder()
    @State private var cancelDrag: CGFloat = 0
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var showAttach = false
    @State private var showPoll = false
    @State private var showLocation = false
    @State private var working = false
    @State private var preview: LinkState?
    @State private var dismissedURL: URL?
    @FocusState private var focused: Bool

    /// The preview being fetched or ready for the URL in the text.
    struct LinkState: Equatable {
        var url: URL
        var link: AppMessage.LinkPreview?
        var loading: Bool
    }

    private var isChannel: Bool { conversationId.hasPrefix("c:") }
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 8) {
            if showAttach {
                attachPanel
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
            }
            if let editing {
                contextBar(icon: "pencil", title: "Modifier le message", detail: editing.message.text ?? "") {
                    withAnimation(.snappy) { self.editing = nil }
                    text = ""
                }
            } else if let replyTo {
                contextBar(
                    icon: "arrowshape.turn.up.left.fill",
                    title: "Réponse à \(replyTo.isMine ? "toi" : (replyTo.senderName ?? model.name(of: replyTo.sender)))",
                    detail: replyTo.summary
                ) {
                    withAnimation(.snappy) { self.replyTo = nil }
                }
            }
            if let preview, editing == nil {
                linkBar(preview)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 8) {
                if recorder.recording {
                    recordingStrip
                } else {
                    attachButton
                    TextField(editing != nil ? "Message modifié" : "Message chiffré", text: $text, axis: .vertical)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1...6)
                        .focused($focused)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 11)
                        .frame(minHeight: 44)
                        .onChange(of: text) { _, new in
                            if !new.isEmpty { model.userIsTyping(in: conversationId) }
                        }
                        .task(id: text) { await refreshPreview() }
                        .accessibilityLabel(editing != nil ? "Message modifié" : "Message")
                }
                trailingButton
            }
            .glassBar()
        }
        .animation(.snappy(duration: 0.25), value: replyTo?.id)
        .animation(.snappy(duration: 0.25), value: editing?.id)
        .animation(.snappy(duration: 0.25), value: preview)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.32, bounce: 0.25), value: showAttach)
        .animation(.snappy(duration: 0.2), value: recorder.recording)
        .onChange(of: editing?.id) { _, id in
            guard id != nil, let editing else { return }
            text = editing.message.text ?? ""
            focused = true
        }
        .onChange(of: replyTo?.id) { _, id in if id != nil { focused = true } }
        .onChange(of: focused) { _, f in if f { showAttach = false } }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await sendPicked(item) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { result in
                showCamera = false
                Task { await sendCamera(result) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            Task { await sendFile(url) }
        }
        .sheet(isPresented: $showPoll) {
            PollComposer(onSend: { q, options, multi in
                model.sendPoll(question: q, options: options, multi: multi, in: conversationId)
            }, demo: DemoData.screen == "poll-new")
        }
        .sheet(isPresented: $showLocation) {
            LocationSheet { lat, lon, accuracy, live in
                model.sendLocation(lat: lat, lon: lon, accuracy: accuracy, live: live, in: conversationId)
            }
        }
        .onAppear {
            switch DemoData.screen {
            case "attach": showAttach = true
            case "poll-new": showPoll = true
            case "location": showLocation = true
            case "edit":
                if let mine = model.items(in: conversationId).last(where: { model.canEdit($0) }) { editing = mine }
            default: break
            }
        }
    }

    // MARK: Attachments panel

    private var attachButton: some View {
        Button {
            Haptics.select()
            focused = false
            showAttach.toggle()
        } label: {
            Group {
                if working {
                    ProgressView()
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .semibold))
                        .rotationEffect(.degrees(showAttach ? 45 : 0))
                }
            }
            .roundIcon()
        }
        .buttonStyle(.plain)
        .disabled(working || editing != nil)
        .accessibilityLabel(showAttach ? "Fermer les pièces jointes" : "Joindre")
    }

    private struct AttachOption: Identifiable {
        let id: String
        let title: String
        let icon: String
        let tint: Color
        let mediaOnly: Bool
    }

    private var attachOptions: [AttachOption] {
        [
            AttachOption(id: "photo", title: "Photo", icon: "photo.on.rectangle.angled", tint: Theme.net, mediaOnly: true),
            AttachOption(id: "camera", title: "Caméra", icon: "camera.fill", tint: Color(UIColor(hex: 0x5B636E, alpha: 1)), mediaOnly: true),
            AttachOption(id: "document", title: "Document", icon: "doc.fill", tint: Color(UIColor(hex: 0x2B6CDF, alpha: 1)), mediaOnly: true),
            AttachOption(id: "location", title: "Position", icon: "location.fill", tint: Color(UIColor(hex: 0x1E9E5A, alpha: 1)), mediaOnly: false),
            AttachOption(id: "poll", title: "Sondage", icon: "chart.bar.fill", tint: Color(UIColor(hex: 0xE8772E, alpha: 1)), mediaOnly: false),
        ]
    }

    private var attachPanel: some View {
        VStack(spacing: 2) {
            ForEach(attachOptions) { option in
                let disabled = (isChannel && option.mediaOnly) || (option.id == "camera" && !UIImagePickerController.isSourceTypeAvailable(.camera) && !model.demo)
                Button {
                    pick(option.id)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: option.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(option.tint, in: Circle())
                        Text(option.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Theme.text)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.4 : 1)
            }
        }
        .padding(8)
        .frame(width: 230)
        .glassEffect(.regular.tint(Theme.glassFill), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.glassStroke, lineWidth: 1) }
        .shadow(color: Theme.shadow, radius: 16, y: 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pick(_ id: String) {
        showAttach = false
        Haptics.tap()
        switch id {
        case "photo": showPhotos = true
        case "camera": showCamera = true
        case "document": showFiles = true
        case "location": showLocation = true
        case "poll": showPoll = true
        default: break
        }
    }

    // MARK: Context bars

    private func contextBar(icon: String, title: String, detail: String, close: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.mesh)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).roundIcon(size: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Annuler")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func linkBar(_ state: LinkState) -> some View {
        HStack(spacing: 10) {
            Group {
                if let b64 = state.link?.image, let data = Data(base64Encoded: b64), let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "link").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .background(Theme.softButton)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(state.loading ? "Aperçu du lien…" : (state.link?.title ?? state.url.host() ?? ""))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(state.link?.site ?? state.url.host() ?? "")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if state.loading { ProgressView().controlSize(.small) }
            Button {
                dismissedURL = state.url
                withAnimation(.snappy) { preview = nil }
            } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).roundIcon(size: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Envoyer sans aperçu")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Debounced: the preview of the first http(s) URL, while the user types.
    private func refreshPreview() async {
        guard model.linkPreviews, !isChannel, editing == nil else {
            preview = nil
            return
        }
        guard let url = LinkPreviewer.firstURL(in: text), url != dismissedURL else {
            if preview != nil { preview = nil }
            return
        }
        if preview?.url == url { return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        preview = LinkState(url: url, link: nil, loading: true)
        let link = await LinkPreviewer.fetch(url)
        guard preview?.url == url else { return }
        preview = link.map { LinkState(url: url, link: $0, loading: false) }
    }

    // MARK: Send button

    private var trailingButton: some View {
        let showSend = hasText || editing != nil
        return Image(systemName: recorder.recording ? "waveform" : showSend ? (editing != nil ? "checkmark" : "arrow.up") : "mic.fill")
            .font(.system(size: 18, weight: showSend ? .bold : .semibold))
            .contentTransition(.symbolEffect(.replace.downUp))
            .roundIcon(fill: recorder.recording ? Theme.danger : Theme.strong, foreground: recorder.recording ? .white : Theme.onStrong)
            .scaleEffect(recorder.recording ? 1.12 : 1)
            .opacity(!showSend && isChannel ? 0.4 : 1)
            .gesture(showSend ? nil : (isChannel ? nil : holdToRecord))
            .onTapGesture { if showSend { send() } }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(showSend ? (editing != nil ? "Enregistrer la modification" : "Envoyer") : "Note vocale")
            .accessibilityHint(showSend ? "" : "Maintiens pour enregistrer, relâche pour envoyer")
            .accessibilityAction {
                if showSend { send() }
            }
            .accessibilityAction(named: "Enregistrer 10 secondes") { Task { await recordForVoiceOver() } }
    }

    private var holdToRecord: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !recorder.recording && cancelDrag == 0 {
                    cancelDrag = 0.001
                    Haptics.tap()
                    Task {
                        let ok = await recorder.start()
                        if !ok { model.banner = "Autorise le micro dans Réglages pour les notes vocales." }
                    }
                }
                cancelDrag = min(0.001, value.translation.width)
            }
            .onEnded { _ in
                let cancel = cancelDrag < -80
                cancelDrag = 0
                finishRecording(cancel: cancel)
            }
    }

    private var recordingStrip: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.danger).frame(width: 10, height: 10).padding(.leading, 12)
            Text(MessageRow.duration(Int(recorder.elapsed * 1000)))
                .font(Theme.mono(13, weight: .medium))
                .foregroundStyle(Theme.text)
                .monospacedDigit()
            Waveform(levels: Array(recorder.levels.suffix(40)), progress: 1, active: Theme.mesh)
                .frame(height: 24)
            Text(cancelDrag < -80 ? "Relâche pour annuler" : "‹ Glisse pour annuler")
                .font(.caption)
                .foregroundStyle(cancelDrag < -80 ? Theme.danger : Theme.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(x: max(-60, cancelDrag / 3))
        .transition(.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Enregistrement en cours")
    }

    private func finishRecording(cancel: Bool) {
        guard let note = recorder.stop(cancel: cancel) else {
            if cancel { Haptics.warning() }
            return
        }
        Haptics.success()
        Task {
            await model.sendAttachment(
                note.data, kind: .audio, mime: "audio/mp4", durationMs: note.durationMs, levels: note.levels, in: conversationId)
        }
    }

    private func recordForVoiceOver() async {
        guard await recorder.start() else { return }
        try? await Task.sleep(for: .seconds(10))
        finishRecording(cancel: false)
    }

    private func send() {
        let body = text
        if let editing {
            model.edit(editing, text: body)
            text = ""
            withAnimation(.snappy) { self.editing = nil }
            Haptics.success()
            return
        }
        guard hasText else { return }
        text = ""
        let reply = replyTo?.id
        withAnimation(.snappy) { replyTo = nil }
        let pending = preview
        preview = nil
        dismissedURL = nil
        if let pending, pending.loading, LinkPreviewer.firstURL(in: body) == pending.url {
            // Wait for the preview (5 s at most, LPMetadataProvider timeout), then send.
            Task {
                let link = await LinkPreviewer.fetch(pending.url)
                model.send(text: body, in: conversationId, replyTo: reply, link: link)
            }
            return
        }
        let link = pending.flatMap { LinkPreviewer.firstURL(in: body) == $0.url ? $0.link : nil }
        model.send(text: body, in: conversationId, replyTo: reply, link: link)
    }

    // MARK: Attachments

    private func sendPicked(_ item: PhotosPickerItem) async {
        working = true
        defer { working = false }
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { return fail() }
            await sendVideo(movie.url)
        } else {
            guard let data = try? await item.loadTransferable(type: Data.self),
                let encoded = await Task.detached(operation: { MediaEncoder.image(from: data) }).value
            else { return fail() }
            await model.sendAttachment(encoded.data, kind: .image, mime: encoded.mime, width: encoded.width, height: encoded.height, thumb: encoded.thumb, in: conversationId)
        }
    }

    private func sendVideo(_ url: URL) async {
        do {
            let v = try await MediaEncoder.video(url)
            await model.sendAttachment(v.data, kind: .video, mime: "video/mp4", width: v.width, height: v.height, durationMs: v.durationMs, thumb: v.thumb, in: conversationId)
        } catch {
            fail()
        }
    }

    private func sendCamera(_ result: CameraPicker.Result?) async {
        working = true
        defer { working = false }
        switch result {
        case .image(let image):
            guard let encoded = MediaEncoder.image(image) else { return fail() }
            await model.sendAttachment(encoded.data, kind: .image, mime: encoded.mime, width: encoded.width, height: encoded.height, thumb: encoded.thumb, in: conversationId)
        case .movie(let url):
            await sendVideo(url)
        case nil:
            break
        }
    }

    private func sendFile(_ url: URL) async {
        working = true
        defer { working = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count <= 100 * 1024 * 1024 else {
            model.banner = "Fichier illisible ou plus lourd que 100 Mo."
            return
        }
        let mime = MediaEncoder.mime(for: url)
        let isPDF = mime == "application/pdf" || url.pathExtension.lowercased() == "pdf"
        let pages = isPDF ? DocumentInfo.pdfPages(data) : nil
        var thumb = isPDF ? DocumentInfo.pdfThumbnail(data) : nil
        if thumb == nil { thumb = await DocumentInfo.thumbnail(for: url) }
        await model.sendAttachment(data, kind: .file, mime: mime, name: url.lastPathComponent, thumb: thumb, pages: pages, in: conversationId)
    }

    private func fail() {
        model.banner = "Impossible de préparer ce média."
        Haptics.warning()
    }
}

/// A movie from the photo library, copied to a temporary file.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// UIImagePickerController for photos and videos from the camera.
struct CameraPicker: UIViewControllerRepresentable {
    enum Result { case image(UIImage), movie(URL) }
    let done: (Result?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeIFrame1280x720
        picker.videoMaximumDuration = 120
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (Result?) -> Void
        init(done: @escaping (Result?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                done(.movie(url))
            } else if let image = info[.originalImage] as? UIImage {
                done(.image(image))
            } else {
                done(nil)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
