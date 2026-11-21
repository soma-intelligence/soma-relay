import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Glass composer: attachments, the text field ("Message chiffré"), and the voice button
/// (hold to record, slide left to cancel) that turns into Send when there is text.
struct Composer: View {
    @Environment(AppModel.self) private var model
    let conversationId: String
    @Binding var replyTo: ChatItem?

    @State private var text = ""
    @State private var recorder = VoiceRecorder()
    @State private var cancelDrag: CGFloat = 0
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var working = false
    @FocusState private var focused: Bool

    private var isChannel: Bool { conversationId.hasPrefix("c:") }

    var body: some View {
        VStack(spacing: 8) {
            if let replyTo {
                HStack(spacing: 10) {
                    Capsule().fill(Theme.mesh).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Réponse à \(replyTo.isMine ? "toi" : (replyTo.senderName ?? model.name(of: replyTo.sender)))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.text)
                        Text(replyTo.message.text ?? AppModel.previewText(replyTo.message))
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        withAnimation(.snappy) { self.replyTo = nil }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).roundIcon(size: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Annuler la réponse")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 8) {
                if recorder.recording {
                    recordingStrip
                } else {
                    attachMenu
                    TextField("Message chiffré", text: $text, axis: .vertical)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1...5)
                        .focused($focused)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 11)
                        .frame(minHeight: 44)
                        .onChange(of: text) { _, new in
                            if !new.isEmpty { model.userIsTyping(in: conversationId) }
                        }
                        .accessibilityLabel("Message")
                }
                trailingButton
            }
            .glassBar()
        }
        .animation(.snappy(duration: 0.25), value: replyTo?.id)
        .animation(.snappy(duration: 0.2), value: recorder.recording)
        .animation(.snappy(duration: 0.2), value: text.isEmpty)
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
    }

    private var attachMenu: some View {
        Menu {
            Button("Photo ou vidéo", systemImage: "photo.on.rectangle") { showPhotos = true }
            Button("Caméra", systemImage: "camera") { showCamera = true }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Button("Fichier", systemImage: "doc") { showFiles = true }
        } label: {
            Group {
                if working {
                    ProgressView()
                } else {
                    Image(systemName: "plus").font(.system(size: 19, weight: .semibold))
                }
            }
            .roundIcon()
        }
        .disabled(isChannel || working)
        .accessibilityLabel("Joindre")
    }

    @ViewBuilder private var trailingButton: some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold))
                    .roundIcon(fill: Theme.strong, foreground: Theme.onStrong)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Envoyer")
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else {
            Image(systemName: recorder.recording ? "waveform" : "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .roundIcon(fill: recorder.recording ? Theme.danger : Theme.strong, foreground: recorder.recording ? .white : Theme.onStrong)
                .scaleEffect(recorder.recording ? 1.12 : 1)
                .opacity(isChannel ? 0.4 : 1)
                .gesture(isChannel ? nil : holdToRecord)
                .accessibilityLabel("Note vocale")
                .accessibilityHint("Maintiens pour enregistrer, relâche pour envoyer")
                .accessibilityAction(named: "Enregistrer 10 secondes") { Task { await recordForVoiceOver() } }
        }
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
        text = ""
        model.send(text: body, in: conversationId, replyTo: replyTo?.id)
        withAnimation(.snappy) { replyTo = nil }
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
        await model.sendAttachment(data, kind: .file, mime: MediaEncoder.mime(for: url), name: url.lastPathComponent, in: conversationId)
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
