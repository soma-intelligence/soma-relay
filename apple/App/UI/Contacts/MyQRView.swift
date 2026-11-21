import SwiftUI

/// My QR with the cipher animation: the code, then (when someone adds me over the mesh or I add
/// them) the exchange, then the four safety words to compare out loud.
struct MyQRView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var stage: CipherQRCode.Stage = .connecting
    @State private var verifying: ContactJSON?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Text(title).font(.title2.bold()).foregroundStyle(Theme.text)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)
                    .animation(.smooth, value: verifying?.id)
                    CipherQRCode(stage: stage)
                        .frame(maxWidth: 300)
                        .accessibilityLabel(verifying == nil ? "QR de ta carte" : "Mots de sécurité")
                    if let verifying {
                        WordPills(words: model.safetyWords(with: verifying.fingerprint))
                        Text(model.safetyCode(with: verifying.fingerprint))
                            .font(Theme.mono(13))
                            .foregroundStyle(Theme.secondary)
                        VStack(spacing: 10) {
                            Button {
                                model.setVerified(verifying.fingerprint, true)
                                dismiss()
                            } label: {
                                Text("Les mots sont identiques").font(.headline).frame(maxWidth: .infinity).frame(minHeight: 44)
                            }
                            .buttonStyle(.glassProminent)
                            Button(role: .destructive) {
                                model.setVerified(verifying.fingerprint, false)
                                Haptics.warning()
                                model.banner = "\(verifying.name) reste non vérifié. Ne partage rien de sensible."
                                dismiss()
                            } label: {
                                Text("Ils sont différents").frame(maxWidth: .infinity).frame(minHeight: 44)
                            }
                            .buttonStyle(.glass)
                        }
                        .padding(.top, 4)
                    } else if let core = model.core {
                        VStack(spacing: 6) {
                            Text(core.fingerprintHex().groupedFingerprint(groups: 8))
                                .font(Theme.mono(12, weight: .medium))
                                .foregroundStyle(Theme.text)
                                .multilineTextAlignment(.center)
                            Text(core.safetyWords().joined(separator: " · "))
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        HStack(spacing: 10) {
                            if let card = model.myCard {
                                ShareLink(item: "somarelay://add/" + card) {
                                    Label("Partager", systemImage: "square.and.arrow.up").frame(minHeight: 36)
                                }
                                .buttonStyle(.glass)
                                Button {
                                    UIPasteboard.general.string = card
                                    copied = true
                                    Haptics.success()
                                } label: {
                                    Label(copied ? "Copiée" : "Copier la carte", systemImage: copied ? "checkmark" : "doc.on.doc").frame(minHeight: 36)
                                }
                                .buttonStyle(.glass)
                            }
                        }
                        Label(
                            model.visibleNearby ? "Visible par les téléphones proches. Ils peuvent t'ajouter sans scanner." : "Invisible à proximité. Seul ce QR permet de t'ajouter.",
                            systemImage: model.visibleNearby ? "dot.radiowaves.left.and.right" : "eye.slash")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
            }
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .onAppear {
            model.justAdded = nil
            if let link = model.myCompactLink { stage = .code(link) }
            if DemoData.screen == "qr-verify" { showVerify(model.contacts.first) }
        }
        .onChange(of: model.justAdded) { _, contact in
            guard let contact else { return }
            stage = .connecting
            Haptics.soft()
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                showVerify(contact)
            }
        }
    }

    private func showVerify(_ contact: ContactJSON?) {
        guard let contact else { return }
        verifying = contact
        stage = .verify(model.safetyWords(with: contact.fingerprint))
        Haptics.success()
    }

    private var title: String { verifying.map { "Vérifie avec \($0.name)" } ?? "Ma carte" }
    private var subtitle: String {
        verifying == nil
            ? "Fais scanner ce QR. Vos téléphones échangent les cartes par le mesh ou par le nœud."
            : "Lisez les quatre mots à voix haute. Les mêmes des deux côtés : personne ne s'est glissé entre vous."
    }
}
