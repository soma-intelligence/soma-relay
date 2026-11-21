import SwiftUI
import VisionKit

/// Add someone: scan their QR, paste a link or card, look up `pseudo@nœud`, or pick a phone
/// nearby on the mesh. Ends on the safety words.
struct AddContactView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.scan
    @State private var input = ""
    @State private var busy = false
    @State private var error: String?
    @State private var added: ContactJSON?

    enum Mode: String, CaseIterable { case scan = "Scanner", paste = "Lien", handle = "Pseudo", nearby = "À côté" }

    var body: some View {
        NavigationStack {
            Group {
                if let added {
                    VerifyWordsView(contact: added) { dismiss() }
                } else {
                    VStack(spacing: 16) {
                        Picker("Méthode", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        switch mode {
                        case .scan: scan
                        case .paste: field("Colle un lien relay1c: ou une carte relay1:", prompt: "relay1c:…")
                        case .handle: field("Le pseudo publié sur un nœud.", prompt: "ines@" + AppConfig.defaultNodeHost)
                        case .nearby: nearby
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(Theme.danger)
                                .transition(.opacity)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                }
            }
            .background(Theme.background)
            .navigationTitle(added == nil ? "Ajouter un contact" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .animation(.smooth, value: added?.id)
            .animation(.smooth, value: mode)
        }
        .onChange(of: model.justAdded) { _, contact in
            if let contact, added == nil { added = contact }
        }
    }

    @ViewBuilder private var scan: some View {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            QRScanner { text in submit(text) }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.glassStroke, lineWidth: 1)
                }
                .overlay(alignment: .bottom) {
                    Text("Vise le QR de ta ou ton proche")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: Capsule())
                        .padding(14)
                }
                .overlay { if busy { ProgressView().controlSize(.large) } }
                .frame(maxHeight: 420)
                .accessibilityLabel("Caméra, scanne un QR Soma Relay")
        } else {
            EmptyState(
                title: "Caméra indisponible",
                message: "Colle plutôt son lien, cherche son pseudo, ou ajoute un téléphone à côté de toi.",
                systemImage: "camera.metering.unknown")
                .frame(maxHeight: 320)
        }
    }

    private func field(_ hint: String, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(hint).font(.subheadline).foregroundStyle(Theme.secondary)
            HStack(spacing: 8) {
                TextField(prompt, text: $input, axis: .vertical)
                    .font(Theme.mono(14))
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .onSubmit { submit(input) }
                if mode == .paste {
                    Button {
                        input = UIPasteboard.general.string ?? ""
                    } label: {
                        Image(systemName: "doc.on.clipboard").roundIcon()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Coller")
                }
            }
            .glassBar(radius: 22)
            Button {
                submit(input)
            } label: {
                Group {
                    if busy { ProgressView() } else { Text("Ajouter").font(.headline) }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || busy)
        }
    }

    @ViewBuilder private var nearby: some View {
        let peers = model.nearby
        if peers.isEmpty {
            EmptyState(
                title: "Personne à portée",
                message: "Les téléphones avec Soma Relay ouvert apparaissent ici, par Bluetooth ou Wi-Fi direct.",
                systemImage: "dot.radiowaves.left.and.right")
                .frame(maxHeight: 320)
        } else {
            VStack(spacing: 10) {
                RadarView(devices: peers.count, hops: nil, highlight: false)
                    .frame(width: 140, height: 140)
                    .padding(.bottom, 6)
                ForEach(peers) { peer in
                    HStack(spacing: 12) {
                        Avatar(name: peer.name ?? peer.code, size: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(peer.name ?? "Téléphone \(peer.code)").foregroundStyle(Theme.text)
                            Text(peer.connected ? "relié par le mesh" : "en vue, connexion…")
                                .font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Button("Échanger") {
                            if !peer.connected { model.mesh.invite(peer.id) }
                            model.requestCard(from: peer)
                        }
                        .buttonStyle(.glass)
                        .disabled(!peer.connected)
                    }
                    .padding(10)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }

    private func submit(_ text: String) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let contact = try await model.addContact(from: text)
                added = contact
            } catch let e as RelayCoreError {
                error = e.message
                Haptics.warning()
            } catch {
                self.error = "Introuvable. Vérifie le pseudo et le nœud, ou que tu as du réseau."
                Haptics.warning()
            }
        }
    }
}

/// After adding: compare the four words out loud.
struct VerifyWordsView: View {
    @Environment(AppModel.self) private var model
    let contact: ContactJSON
    let done: () -> Void
    @State private var stage: CipherQRCode.Stage = .connecting

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("\(contact.name) est ajouté")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.text)
                Text("Lisez ces quatre mots ensemble, à voix haute ou en face. S'ils sont les mêmes chez vous deux, personne ne s'est glissé entre vous.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                CipherQRCode(stage: stage).frame(maxWidth: 260)
                WordPills(words: model.safetyWords(with: contact.fingerprint))
                Button {
                    model.setVerified(contact.fingerprint, true)
                    done()
                } label: {
                    Text("Les mots sont identiques").font(.headline).frame(maxWidth: .infinity).frame(minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                Button {
                    done()
                } label: {
                    Text("Plus tard").frame(maxWidth: .infinity).frame(minHeight: 44)
                }
                .buttonStyle(.glass)
            }
            .padding(24)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            stage = .verify(model.safetyWords(with: contact.fingerprint))
        }
    }
}

/// VisionKit live QR scanner.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var last: String?
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let code) = item, let text = code.payloadStringValue, text != last,
                    text.hasPrefix("relay1") || text.hasPrefix("somarelay://")
                else { continue }
                last = text
                Haptics.success()
                found(text)
            }
        }
    }
}
