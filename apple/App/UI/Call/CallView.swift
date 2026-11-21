import SwiftUI
import WebRTC

/// FusionAppel: security pill, voice ring with initials, name, timer, the four words, glass
/// control bar. Always dark, like the artboard. Video calls show the remote video full screen.
struct CallView: View {
    @Environment(AppModel.self) private var model
    @State private var level = 0.4

    private var calls: CallManager { model.calls }
    private var call: CallSession? { calls.current }
    private let lime = Color(UIColor(hex: 0xC6F24E, alpha: 1))
    private let ink = Color(UIColor(hex: 0xE9ECE6, alpha: 1))
    private let grey = Color(UIColor(hex: 0x9AA196, alpha: 1))

    var body: some View {
        ZStack {
            Color(UIColor(hex: 0x0C0E0D, alpha: 1)).ignoresSafeArea()
            if let remote = calls.remoteVideo, call?.video == true, call?.state == .active {
                VideoTrackView(track: remote).ignoresSafeArea()
                LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            }
            if let call {
                content(call)
            }
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            if let local = calls.localVideo, call?.cameraOff == false {
                VideoTrackView(track: local, mirror: true)
                    .frame(width: 104, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.top, 60)
                    .padding(.trailing, 16)
            }
        }
    }

    @ViewBuilder private func content(_ call: CallSession) -> some View {
        VStack(spacing: 0) {
            securityPill(call)
            ring(call)
                .frame(width: 200, height: 200)
                .padding(.top, 44)
            Text(model.name(of: call.peer))
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.68)
                .foregroundStyle(ink)
                .padding(.top, 22)
            status(call)
                .padding(.top, 4)
            let words = calls.words()
            if !words.isEmpty {
                WordPills(words: words)
                    .environment(\.colorScheme, .dark)
                    .padding(.top, 34)
                Text("Mêmes mots des deux côtés = appel sûr.\nCoupure réseau : les messages repassent par le mesh.")
                    .font(.system(size: 12))
                    .foregroundStyle(grey)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
            }
            Spacer()
            controls(call)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private func securityPill(_ call: CallSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock").font(.system(size: 11, weight: .semibold))
            Text(securityText(call))
        }
        .font(Theme.mono(11))
        .foregroundStyle(grey)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .accessibilityLabel(call.frameEncrypted ? "Appel chiffré de bout en bout, clés post-quantiques" : "Appel chiffré")
    }

    private func securityText(_ call: CallSession) -> String {
        let via = model.routes[call.peer]?.transport == .mesh ? "MESH" : "NET"
        var parts = [via, "SRTP"]
        if call.frameEncrypted { parts.append("CLÉS PQ") }
        if let rtt = call.rttMs { parts.append("\(rtt) ms") }
        return parts.joined(separator: " · ")
    }

    private func ring(_ call: CallSession) -> some View {
        TimelineView(.animation(paused: call.state != .active && call.state != .ringingIn && call.state != .ringingOut)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let fraction = call.state == .active ? 0.3 + 0.18 * (sin(t * 2.3) * 0.5 + 0.5) : 0.12
            let rotation = call.state == .active ? -90.0 : -90 + (t * 120).truncatingRemainder(dividingBy: 360)
            ZStack {
                Circle().stroke(Color(UIColor(hex: 0x1F241F, alpha: 1)), lineWidth: 1).padding(6)
                Circle().stroke(Color(UIColor(hex: 0x2A2F2A, alpha: 1)), lineWidth: 1).padding(28)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(lime, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(rotation))
                    .padding(28)
                Circle().fill(Color(UIColor(hex: 0x1A1E1B, alpha: 1))).padding(50)
                Text(Avatar(name: model.name(of: call.peer)).initials)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(ink)
            }
        }
        .accessibilityLabel("Niveau de voix de \(model.name(of: call.peer))")
    }

    @ViewBuilder private func status(_ call: CallSession) -> some View {
        switch call.state {
        case .active:
            if let started = call.startedAt {
                TimelineView(.periodic(from: started, by: 1)) { timeline in
                    let s = Int(timeline.date.timeIntervalSince(started))
                    Text(String(format: "%02d:%02d", s / 60, s % 60))
                        .font(Theme.mono(15))
                        .foregroundStyle(lime)
                        .monospacedDigit()
                }
            }
        case .ringingOut: Text("Appel en cours…").font(Theme.mono(15)).foregroundStyle(lime)
        case .ringingIn: Text(call.video ? "Appel vidéo entrant" : "Appel entrant").font(Theme.mono(15)).foregroundStyle(lime)
        case .connecting: Text("Connexion chiffrée…").font(Theme.mono(15)).foregroundStyle(lime)
        case .ended(let reason): Text(reason).font(Theme.mono(15)).foregroundStyle(grey)
        }
    }

    @ViewBuilder private func controls(_ call: CallSession) -> some View {
        if call.state == .ringingIn {
            HStack {
                round("phone.down.fill", label: "Refuser", fill: Theme.danger, rotate: false) { calls.decline() }
                Spacer()
                round(call.video ? "video.fill" : "phone.fill", label: "Répondre", fill: lime, foreground: Color(UIColor(hex: 0x0C0E0D, alpha: 1))) { calls.accept() }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 10)
        } else {
            HStack {
                round(call.muted ? "mic.slash.fill" : "mic.slash", label: call.muted ? "Réactiver le micro" : "Couper le micro", active: call.muted) { calls.toggleMute() }
                Spacer()
                if call.video {
                    round(call.cameraOff ? "video.slash.fill" : "video", label: call.cameraOff ? "Rallumer la caméra" : "Couper la caméra", active: call.cameraOff) { calls.toggleCamera() }
                } else {
                    round("speaker.wave.2", label: "Haut-parleur", active: call.speaker) { calls.toggleSpeaker() }
                }
                Spacer()
                round("message", label: "Ouvrir la conversation") { calls.presented = false }
                Spacer()
                round("phone.down.fill", label: "Raccrocher", fill: Theme.danger, rotate: false) { calls.hangUp() }
            }
            .padding(10)
            .background(Color.white.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
            .glassEffect(.clear, in: Capsule())
        }
    }

    private func round(
        _ icon: String, label: String, fill: Color = Color.white.opacity(0.1), foreground: Color = Color(UIColor(hex: 0xE9ECE6, alpha: 1)),
        active: Bool = false, rotate: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 60, height: 60)
                .background(active ? Color.white.opacity(0.85) : fill, in: Circle())
                .foregroundStyle(active ? Color.black : foreground)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// RTCMTLVideoView in SwiftUI.
struct VideoTrackView: UIViewRepresentable {
    let track: RTCVideoTrack
    var mirror = false

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        if mirror { view.transform = CGAffineTransform(scaleX: -1, y: 1) }
        track.add(view)
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {}

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: ()) {}
}
