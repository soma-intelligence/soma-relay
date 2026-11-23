import SwiftUI
import WebRTC

/// Call (relay-screens 05): background tinted from the contact's avatar, large name and
/// duration, the "Chiffré post-quantique · mesh, 48 ms" capsule, the glass "Mots de l'appel"
/// card, and labelled standard controls. Always dark. Video calls show the remote video full
/// screen.
struct CallView: View {
    @Environment(AppModel.self) private var model

    private var calls: CallManager { model.calls }
    private var call: CallSession? { calls.current }

    var body: some View {
        ZStack {
            DS.background.ignoresSafeArea()
            if let call { tint(call).ignoresSafeArea() }
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
                    .padding(.top, 72)
                    .padding(.trailing, 20)
            }
        }
    }

    /// The avatar's gradient, fading into the page colour by the lower third.
    private func tint(_ call: CallSession) -> some View {
        let pair = DSAvatar.palette[DSAvatar.paletteIndex(for: model.name(of: call.peer))]
        return LinearGradient(
            stops: [
                .init(color: Color(UIColor(hex: pair.1, alpha: 0.75)), location: 0),
                .init(color: Color(UIColor(hex: pair.1, alpha: 0.45)), location: 0.35),
                .init(color: Color(UIColor(hex: pair.1, alpha: 0)), location: 0.72),
            ],
            startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder private func content(_ call: CallSession) -> some View {
        let name = model.name(of: call.peer)
        VStack(spacing: 0) {
            HStack {
                glassRound("chevron.down", label: "Réduire l'appel") { calls.presented = false }
                Spacer()
                glassRound("bubble.left.fill", label: "Ouvrir la conversation") { calls.presented = false }
            }
            avatar(call, name: name)
                .padding(.top, 8)
            Text(name)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(DS.label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 14)
            status(call)
                .padding(.top, 2)
            securityCapsule(call)
                .padding(.top, 18)
            Spacer(minLength: 16)
            let words = calls.words()
            if !words.isEmpty {
                wordsCard(words, name: name)
            }
            Spacer(minLength: 16)
            controls(call)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private func glassRound(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.label)
                .frame(width: DS.roundButton, height: DS.roundButton)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func avatar(_ call: CallSession, name: String) -> some View {
        TimelineView(.animation(paused: call.state != .ringingIn && call.state != .ringingOut)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let ringing = call.state == .ringingIn || call.state == .ringingOut
            let breathe = ringing ? 1 + 0.04 * sin(t * 3) : 1
            ZStack {
                Circle().fill(Color.white.opacity(0.04)).frame(width: 212, height: 212).scaleEffect(breathe)
                Circle().fill(Color.white.opacity(0.06)).frame(width: 186, height: 186)
                DSAvatar(name: name, size: 160, photo: model.photo(for: call.peer))
                    .environment(\.dynamicTypeSize, .large)
            }
        }
        .frame(width: 212, height: 212)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func status(_ call: CallSession) -> some View {
        Group {
            switch call.state {
            case .active:
                if let started = call.startedAt {
                    TimelineView(.periodic(from: started, by: 1)) { timeline in
                        let s = Int(timeline.date.timeIntervalSince(started))
                        Text(String(format: "%02d:%02d", s / 60, s % 60))
                    }
                }
            case .ringingOut: Text("Appel en cours…")
            case .ringingIn: Text(call.video ? "Appel vidéo entrant" : "Appel entrant")
            case .connecting: Text("Connexion chiffrée…")
            case .ended(let reason): Text(reason)
            }
        }
        .font(.system(size: 22))
        .monospacedDigit()
        .foregroundStyle(DS.label2)
    }

    private func securityCapsule(_ call: CallSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 12))
            Text(securityText(call))
        }
        .font(DS.TextStyle.subheadline)
        .foregroundStyle(DS.label2)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(call.frameEncrypted ? "Appel chiffré de bout en bout, clés post-quantiques" : "Appel chiffré")
    }

    private func securityText(_ call: CallSession) -> String {
        let via = model.routes[call.peer]?.transport == .mesh ? "mesh" : "nœud"
        let link = call.rttMs.map { "\(via), \($0) ms" } ?? via
        return (call.frameEncrypted ? "Chiffré post-quantique" : "Chiffré") + " · " + link
    }

    private func wordsCard(_ words: [String], name: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(DS.accent)
                Text("Mots de l'appel").foregroundStyle(DS.label)
            }
            .font(.system(size: 17, weight: .semibold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { ForEach(words, id: \.self) { wordTile($0) } }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(words, id: \.self) { wordTile($0) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mots de l'appel : " + words.joined(separator: ", "))
            Text("\(name) doit voir les mêmes quatre mots. Sinon, raccroche : quelqu'un s'est glissé dans l'appel.")
                .font(DS.TextStyle.subheadline)
                .foregroundStyle(DS.label2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
    }

    private func wordTile(_ word: String) -> some View {
        Text(word)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(DS.label)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(DS.fill2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private func controls(_ call: CallSession) -> some View {
        if call.state == .ringingIn {
            HStack {
                control("phone.down.fill", label: "Refuser", fill: DS.danger) { calls.decline() }
                Spacer()
                control(call.video ? "video.fill" : "phone.fill", label: "Répondre", fill: DS.accentFill, foreground: DS.onAccent) { calls.accept() }
            }
            .padding(.horizontal, 30)
        } else {
            HStack(alignment: .top, spacing: 0) {
                control(call.speaker ? "speaker.wave.2.fill" : "speaker.wave.2", label: "Haut-parleur", active: call.speaker) { calls.toggleSpeaker() }
                    .frame(maxWidth: .infinity)
                // Audio calls cannot turn into video calls yet: the camera stays visible, dimmed.
                control(call.cameraOff || !call.video ? "video.slash.fill" : "video.fill", label: "Caméra", active: call.video && !call.cameraOff, enabled: call.video) { calls.toggleCamera() }
                    .frame(maxWidth: .infinity)
                control("mic.slash.fill", label: "Muet", active: call.muted) { calls.toggleMute() }
                    .frame(maxWidth: .infinity)
                control("phone.down.fill", label: "Raccrocher", fill: DS.danger) { calls.hangUp() }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Standard call control: 74 pt circle, label under it. Active toggles turn white.
    private func control(
        _ icon: String, label: String, fill: Color? = nil, foreground: Color = .white,
        active: Bool = false, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(active ? Color.black : foreground)
                    .frame(width: 74, height: 74)
                    .background {
                        if let fill {
                            Circle().fill(fill)
                        } else if active {
                            Circle().fill(Color.white.opacity(0.92))
                        } else {
                            Circle().fill(Color.white.opacity(0.08)).glassEffect(.regular, in: Circle())
                        }
                    }
                Text(label)
                    .font(DS.TextStyle.subheadline)
                    .foregroundStyle(DS.label2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityValue(active ? "activé" : "")
        .accessibilityHint(enabled ? "" : "Indisponible pendant un appel audio")
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
