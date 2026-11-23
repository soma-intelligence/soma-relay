import AVFoundation
import SwiftUI
import VisionKit

/// My card and the scanner on one screen (relay-screens 08 and 09), a glass segment at the top.
///
/// - Ma carte: a glass card with my avatar, name, `@pseudo · node host`, the QR of my `relay1c:`
///   link on its light tile with the mark in the middle, and a short fingerprint. One action:
///   "Partager ma carte". When someone adds me (mesh or node), the QR turns into our four words.
/// - Scanner: the camera with a lime viewfinder and "Vise le code sur sa carte", and a glass panel
///   with one field ("Pseudo ou lien d'invitation": a `relay1:` card, a `relay1c:` or
///   `somarelay://add/` link, `pseudo` or `pseudo@nœud`) and the named people in range on the mesh.
///
/// Whatever the way in, a new contact ends on the safety words, then their chat opens.
struct MyCardView: View {
    enum Mode: Hashable { case card, scan }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var initialMode: Mode = .card
    /// Opens a conversation (after adding someone).
    let open: (String) -> Void

    @State private var mode: Mode = .card
    @State private var stage: CipherQRCode.Stage = .connecting
    @State private var verifying: ContactJSON?
    @State private var input = ""
    @State private var busy = false
    @State private var error: String?
    @State private var torchOn = false
    @FocusState private var fieldFocused: Bool

    private var shareLink: String? { model.myCompactLink.map { "somarelay://add/" + $0 } }
    private var nodeHost: String? { model.nodeEnabled ? URL(string: model.nodeURL)?.host() : nil }
    private var scannerSupported: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }
    /// Named phones in range that are not contacts yet (anonymous phones stay in À proximité).
    private var nearbyPeople: [NearbyPeer] { model.nearby.filter { $0.name != nil && !model.isContact(nearby: $0) } }

    var body: some View {
        ZStack {
            switch mode {
            case .card: cardPage.transition(.opacity)
            case .scan: scanPage.transition(.opacity)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .animation(.smooth(duration: 0.3), value: mode)
        .onAppear {
            mode = DemoData.screen == "add" ? .scan : initialMode
            model.justAdded = nil
            showCode()
        }
        .onChange(of: model.justAdded) { _, contact in
            guard let contact else { return }
            model.justAdded = nil
            fieldFocused = false
            if mode == .card {
                stage = .connecting
                Haptics.soft()
                Task {
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 900))
                    stage = .verify(model.safetyWords(with: contact.fingerprint))
                    verifying = contact
                }
            } else {
                verifying = contact
            }
        }
        .onChange(of: mode) { _, new in
            if new == .card { showCode() } else { setTorch(false) }
            error = nil
        }
        .sheet(item: $verifying, onDismiss: showCode) { contact in
            VerifyWordsSheet(contact: contact, justAdded: true) {
                open(AppModel.directId(contact.fingerprint))
            }
        }
    }

    private func showCode() {
        guard let link = model.myCompactLink else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 250))
            stage = .code(link)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            DSRoundGlassButton(systemName: "xmark", label: "Fermer") { dismiss() }
            Spacer()
            if mode == .scan, scannerSupported, AVCaptureDevice.default(for: .video)?.hasTorch == true {
                DSRoundGlassButton(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill", label: torchOn ? "Éteindre la lampe" : "Allumer la lampe") {
                    setTorch(!torchOn)
                }
            } else {
                Color.clear.frame(width: DS.roundButton, height: DS.roundButton)
            }
        }
        .overlay {
            DSGlassSegment(options: [(Mode.card, "Ma carte"), (Mode.scan, "Scanner")], selection: $mode)
                .accessibilityIdentifier("mycard.segment")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    // MARK: Ma carte

    private var cardPage: some View {
        ZStack {
            RadialGradient(
                colors: [Theme.dyn(0xE4EBD3, 0x18200F), DS.background],
                center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: 420)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        card
                            .padding(.horizontal, 32)
                            .padding(.top, 20)
                        Text("Fais scanner ce code pour qu'on t'ajoute, même sans réseau. Ta clé ne quitte jamais ce téléphone.")
                            .font(DS.TextStyle.subheadline)
                            .foregroundStyle(DS.label2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 40)
                            .padding(.top, 20)
                    }
                    .padding(.bottom, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
                if let shareLink {
                    ShareLink(item: shareLink, subject: Text("Ma carte Soma Relay"), message: Text("Ajoute-moi sur Soma Relay")) {
                        Label("Partager ma carte", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.dsSecondary)
                    .padding(.horizontal, DS.Space.margin)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            EditablePhoto(name: model.displayName, photo: model.photos[AppModel.me], size: 72, cropTitle: "Ta photo") { image in
                model.setMyPhoto(image)
            }
            .padding(.bottom, 12)
            Text(model.displayName)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(DS.label)
            if let line = handleLine {
                Text(line)
                    .font(DS.TextStyle.subheadline)
                    .foregroundStyle(DS.label2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 2)
            }
            CipherQRCode(stage: stage)
                .frame(maxWidth: 268)
                .padding(.top, 22)
                .accessibilityLabel(stageLabel)
                .contextMenu {
                    if let card = model.myCard {
                        Button("Copier ma carte", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = card
                            Haptics.success()
                        }
                    }
                }
            if let core = model.core {
                Text(core.fingerprintHex().groupedFingerprint(groups: 4).replacingOccurrences(of: "·", with: " "))
                    .font(DS.TextStyle.fingerprint(13).weight(.medium))
                    .tracking(0.5)
                    .foregroundStyle(DS.label3)
                    .padding(.top, 16)
                    .accessibilityLabel("Empreinte " + core.fingerprintHex().groupedFingerprint(groups: 4).replacingOccurrences(of: "·", with: " "))
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 40, style: .continuous))
    }

    /// "@quentin · relay.somalabs.me": the pseudo and the real node host.
    private var handleLine: String? {
        let parts = [model.handle.isEmpty ? nil : "@" + model.handle, nodeHost].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var stageLabel: String {
        if case .verify(let words) = stage { return "Les mots à comparer : " + words.joined(separator: ", ") }
        return "QR de ta carte. Fais-le scanner pour qu'on t'ajoute."
    }

    // MARK: Scanner

    private var scanPage: some View {
        ZStack {
            camera.ignoresSafeArea()
            VStack(spacing: 0) {
                Text(scannerSupported ? (busy ? "Lecture de la carte…" : "Vise le code sur sa carte") : "Caméra indisponible, entre son pseudo")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 110)
                    .accessibilityIdentifier("scanner.hint")
                Viewfinder()
                    .frame(width: 300, height: 300)
                    .padding(.top, 40)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            VStack {
                Spacer()
                addPanel
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var camera: some View {
        if scannerSupported {
            QRScanner { text in submit(text) }
                .accessibilityLabel("Caméra, vise le QR d'une carte Soma Relay")
        } else {
            ZStack {
                LinearGradient(colors: [Color(UIColor(hex: 0x2A2621, alpha: 1)), Color(UIColor(hex: 0x1A1815, alpha: 1)), Color(UIColor(hex: 0x0E0D0B, alpha: 1))], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color(UIColor(hex: 0xFFC88C, alpha: 0.30)), .clear], center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 240)
                RadialGradient(colors: [Color(UIColor(hex: 0x7896C8, alpha: 0.20)), .clear], center: UnitPoint(x: 0.75, y: 0.6), startRadius: 0, endRadius: 260)
            }
        }
    }

    private var addPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.TextStyle.footnote)
                    .foregroundStyle(DS.danger)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
            HStack(spacing: 10) {
                Image(systemName: "at").font(.system(size: 16)).foregroundStyle(DS.label2)
                TextField("Pseudo ou lien d'invitation", text: $input)
                    .font(DS.TextStyle.body)
                    .foregroundStyle(DS.label)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($fieldFocused)
                    .onSubmit { submit(input) }
                    .accessibilityIdentifier("add.field")
                if busy {
                    ProgressView()
                } else if input.isEmpty {
                    Button {
                        submit(UIPasteboard.general.string ?? "")
                    } label: {
                        Image(systemName: "doc.on.clipboard").font(.system(size: 16)).foregroundStyle(DS.label2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Coller un lien")
                } else {
                    Button {
                        submit(input)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(DS.onAccent)
                            .frame(width: 32, height: 32)
                            .background(DS.accentFill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ajouter")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: 50)
            .background(Color.white.opacity(0.08), in: Capsule())
            if !nearbyPeople.isEmpty {
                Text("À portée sur le mesh")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.label2)
                    .padding(.horizontal, 6)
                    .padding(.top, 16)
                Group {
                    if nearbyPeople.count <= 2 {
                        HStack(spacing: 10) {
                            ForEach(nearbyPeople) { peer in nearbyChip(peer, fill: true) }
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(nearbyPeople) { peer in nearbyChip(peer, fill: false) }
                            }
                        }
                        .scrollClipDisabled()
                    }
                }
                .padding(.top, 12)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .animation(.smooth, value: error)
    }

    private func nearbyChip(_ peer: NearbyPeer, fill: Bool) -> some View {
        Button {
            Haptics.tap()
            if !peer.connected { model.mesh.invite(peer.id) }
            model.requestCard(from: peer)
        } label: {
            HStack(spacing: 10) {
                DSAvatar(name: peer.name ?? peer.code, size: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text(peer.name ?? peer.code)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.label)
                    Text(peer.connected ? "Relié directement" : "À portée, pas encore relié")
                        .font(DS.TextStyle.caption)
                        .foregroundStyle(DS.label2)
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 170, maxWidth: fill ? .infinity : nil, alignment: .leading)
            .frame(height: 58)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!peer.connected)
        .accessibilityLabel("Ajouter \(peer.name ?? peer.code)")
    }

    // MARK: Actions

    /// A bare pseudo is looked up on my node (`ines` -> `ines@<node host>`).
    private func normalized(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("@") { t.removeFirst() }
        let isLink = t.hasPrefix("relay1") || t.hasPrefix("somarelay://")
        if !isLink, !t.isEmpty, !t.contains("@"), let host = URL(string: model.nodeURL)?.host() {
            t += "@" + host
        }
        return t
    }

    private func submit(_ text: String) {
        guard !busy else { return }
        let trimmed = normalized(text)
        guard !trimmed.isEmpty else {
            error = "Rien à coller."
            return
        }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                _ = try await model.addContact(from: trimmed)
                input = ""
            } catch let e as RelayCoreError {
                error = e.message
                Haptics.warning()
            } catch {
                self.error = "Introuvable. Vérifie le pseudo et le nœud, ou que tu as du réseau. À côté de toi, le mesh suffit."
                Haptics.warning()
            }
        }
    }

    private func setTorch(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch, (try? device.lockForConfiguration()) != nil else {
            torchOn = false
            return
        }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
        torchOn = on
    }
}

/// Four lime corners around the scan area.
private struct Viewfinder: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, arm: CGFloat = 46, r: CGFloat = 24
            Path { p in
                // Top left.
                p.move(to: CGPoint(x: 0, y: arm)); p.addLine(to: CGPoint(x: 0, y: r))
                p.addArc(tangent1End: .zero, tangent2End: CGPoint(x: r, y: 0), radius: r); p.addLine(to: CGPoint(x: arm, y: 0))
                // Top right.
                p.move(to: CGPoint(x: w - arm, y: 0)); p.addLine(to: CGPoint(x: w - r, y: 0))
                p.addArc(tangent1End: CGPoint(x: w, y: 0), tangent2End: CGPoint(x: w, y: r), radius: r); p.addLine(to: CGPoint(x: w, y: arm))
                // Bottom right.
                p.move(to: CGPoint(x: w, y: h - arm)); p.addLine(to: CGPoint(x: w, y: h - r))
                p.addArc(tangent1End: CGPoint(x: w, y: h), tangent2End: CGPoint(x: w - r, y: h), radius: r); p.addLine(to: CGPoint(x: w - arm, y: h))
                // Bottom left.
                p.move(to: CGPoint(x: arm, y: h)); p.addLine(to: CGPoint(x: r, y: h))
                p.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: h - r), radius: r); p.addLine(to: CGPoint(x: 0, y: h - arm))
            }
            .stroke(DS.accentFill, style: StrokeStyle(lineWidth: 5, lineCap: .butt, lineJoin: .round))
        }
    }
}
