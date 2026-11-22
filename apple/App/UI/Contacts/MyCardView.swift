import SwiftUI
import VisionKit

/// My card, full screen, one tap from the conversations screen: a large QR of the `relay1c:`
/// link, my photo and name, Share (the link) and Scanner. Scanning someone's card adds them and
/// opens the chat.
struct MyCardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Opens a conversation (after a scan).
    let open: (String) -> Void
    @State private var stage: CipherQRCode.Stage = .connecting
    @State private var scanning = false

    private var shareLink: String? { model.myCompactLink.map { "somarelay://add/" + $0 } }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    EditablePhoto(name: model.displayName, photo: model.photos[AppModel.me], size: 88, cropTitle: "Ta photo") { image in
                        model.setMyPhoto(image)
                    }
                    .padding(.top, 36)
                    VStack(spacing: 4) {
                        Text(model.displayName)
                            .font(.title.bold())
                            .foregroundStyle(Theme.text)
                        if !model.handle.isEmpty {
                            Text(model.handle + "@" + (URL(string: model.nodeURL)?.host() ?? ""))
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    CipherQRCode(stage: stage)
                        .frame(maxWidth: 320)
                        .padding(.horizontal, 8)
                        .accessibilityLabel("QR de ta carte. Fais-le scanner pour qu'on t'ajoute.")
                    if let core = model.core {
                        Text(core.safetyWords().joined(separator: " · "))
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.secondary)
                            .accessibilityLabel("Tes mots : " + core.safetyWords().joined(separator: ", "))
                    }
                    HStack(spacing: 12) {
                        if let shareLink {
                            ShareLink(item: shareLink, subject: Text("Ma carte Soma Relay"), message: Text("Ajoute-moi sur Soma Relay")) {
                                Label("Partager", systemImage: "square.and.arrow.up")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: 50)
                            }
                            .buttonStyle(.glass)
                        }
                        Button {
                            Haptics.tap()
                            scanning = true
                        } label: {
                            Label("Scanner", systemImage: "qrcode.viewfinder")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 50)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .padding(.horizontal, 24)
                    Text("Vos téléphones échangent les cartes par le mesh ou par le nœud. Comparez ensuite vos quatre mots.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).roundIcon()
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.top, 4)
            .accessibilityLabel("Fermer")
        }
        .onAppear {
            guard let link = model.myCompactLink else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 250))
                stage = .code(link)
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            CardScanner { id in
                scanning = false
                open(id)
            }
        }
    }
}

/// The camera scanner of a card. Found: the contact is added and its chat opens.
struct CardScanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let added: (String) -> Void
    @State private var busy = false
    @State private var error: String?

    private var supported: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if supported {
                QRScanner { text in submit(text) }
                    .ignoresSafeArea()
                    .accessibilityLabel("Caméra, vise le QR d'une carte Soma Relay")
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .strokeBorder(.white.opacity(0.85), style: StrokeStyle(lineWidth: 3, dash: [28, 18]))
                    .frame(width: 260, height: 260)
                    .allowsHitTesting(false)
            } else {
                EmptyState(
                    title: "Caméra indisponible",
                    message: "Colle plutôt le lien de sa carte.",
                    systemImage: "camera.metering.unknown")
                    .environment(\.colorScheme, .dark)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .accessibilityLabel("Fermer")
                }
                .padding(.horizontal, 16)
                Spacer()
                VStack(spacing: 10) {
                    if let error {
                        Text(error)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    }
                    if busy {
                        ProgressView().tint(.white)
                    } else {
                        Text("Vise le QR de sa carte")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                    }
                    Button("Coller un lien", systemImage: "doc.on.clipboard") {
                        submit(UIPasteboard.general.string ?? "")
                    }
                    .buttonStyle(.glass)
                    .environment(\.colorScheme, .dark)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.bottom, 24)
                .animation(.smooth, value: error)
            }
        }
        .statusBarHidden()
    }

    private func submit(_ text: String) {
        guard !busy else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Rien à coller."
            return
        }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let contact = try await model.addContact(from: trimmed)
                added(AppModel.directId(contact.fingerprint))
            } catch let e as RelayCoreError {
                error = e.message
                Haptics.warning()
            } catch {
                self.error = "Carte introuvable. Vérifie que tu as du réseau, ou approche-toi pour passer par le mesh."
                Haptics.warning()
            }
        }
    }
}
