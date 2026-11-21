import MessageUI
import SwiftUI

/// Direction E chat: glass header, collapsible path card with the mini radar, transport-coloured
/// bubbles with mono metadata, dashed bubbles for messages still on their way, glass composer.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let conversationId: String

    @State private var items: [ChatItem] = []
    @State private var replyTo: ChatItem?
    @State private var pathExpanded = false
    @State private var smsLink: SMSPayload?
    @State private var viewer: ChatItem?
    @State private var showDetails = false
    @State private var player = VoicePlayer()

    private var conversation: ConversationRecord? { model.conversations.first { $0.id == conversationId } ?? model.db.conversation(conversationId) }
    private var peer: ContactJSON? { conversation?.kind == .direct ? conversation?.peer.flatMap(model.contact) : nil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if let first = items.first {
                        Text(Self.header(for: first.message.ts, kind: conversation?.kind ?? .direct))
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.secondary)
                            .padding(.bottom, 6)
                            .accessibilityLabel(conversation?.kind == .channel ? "Canal non chiffré" : "Chiffrement post-quantique ML-KEM-1024 et X25519")
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0, item.message.ts - items[index - 1].message.ts > 3_600_000 {
                            Text(Self.header(for: item.message.ts, kind: nil))
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.secondary)
                                .padding(.vertical, 6)
                        }
                        MessageRow(
                            item: item,
                            showSender: conversation?.kind != .direct && !item.isMine && (index == 0 || items[index - 1].sender != item.sender),
                            quoted: item.message.replyTo.flatMap { id in items.first { $0.id == id } },
                            player: player,
                            onReply: { withAnimation(.snappy) { replyTo = item } },
                            onSMS: { sendBySMS(item) },
                            onRetry: { model.retry(item.id) },
                            onOpen: { viewer = item })
                            .id(item.id)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                    if model.isTyping(conversationId) {
                        TypingBubble()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("typing")
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
                .animation(.smooth(duration: 0.28), value: items.map(\.id))
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: items.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.smooth) { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: model.isTyping(conversationId)) { _, typing in
                if typing { withAnimation(.smooth) { proxy.scrollTo("typing", anchor: .bottom) } }
            }
        }
        .overlay {
            if items.isEmpty {
                EmptyState(
                    title: "Dis bonjour",
                    message: conversation?.kind == .channel
                        ? "Les messages de ce canal passent à tous les téléphones à portée."
                        : "Ton premier message ouvre une session chiffrée post-quantique.",
                    systemImage: conversation?.kind == .channel ? "number" : "lock")
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 10) {
                header
                if conversation?.kind != .channel {
                    PathCard(conversation: conversation, peer: peer, expanded: $pathExpanded)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Composer(conversationId: conversationId, replyTo: $replyTo)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            model.activeConversation = conversationId
            reload()
            model.markRead(conversationId)
        }
        .onDisappear {
            if model.activeConversation == conversationId { model.activeConversation = nil }
            player.stop()
        }
        .onChange(of: model.messageVersion) {
            reload()
            if conversation?.unread ?? 0 > 0 { model.markRead(conversationId) }
        }
        .sheet(item: $smsLink) { payload in
            MessageComposer(body: payload.text) { sent in
                if sent { model.markSentBySMS(payload.messageId) }
                smsLink = nil
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $viewer) { item in
            MediaViewer(item: item)
        }
        .sheet(isPresented: $showDetails) {
            if let peer {
                NavigationStack { ContactDetailView(fingerprint: peer.fingerprint) }
            }
        }
    }

    private func reload() {
        items = model.items(in: conversationId)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                    .roundIcon()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retour")
            Button {
                if peer != nil { showDetails = true }
            } label: {
                VStack(spacing: 1) {
                    Text(conversation?.title ?? "")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(peer != nil ? "Ouvre la fiche du contact" : "")
            if let peer {
                Button {
                    model.calls.start(with: peer.fingerprint, video: false)
                } label: {
                    Image(systemName: "phone.fill").font(.system(size: 17))
                        .roundIcon(fill: Theme.strong, foreground: Theme.onStrong)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Appel audio", systemImage: "phone") { model.calls.start(with: peer.fingerprint, video: false) }
                    Button("Appel vidéo", systemImage: "video") { model.calls.start(with: peer.fingerprint, video: true) }
                }
                .accessibilityLabel("Appeler")
                .accessibilityAction(named: "Appel vidéo") { model.calls.start(with: peer.fingerprint, video: true) }
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .glassBar()
    }

    private var subtitle: String {
        switch conversation?.kind {
        case .direct:
            guard let peer else { return "" }
            return "fp \(peer.fingerprint.groupedFingerprint(groups: 2)) · \(peer.verified ? "vérifiée" : "non vérifiée")"
        case .group:
            let n = model.groups.first { $0.id == conversation?.peer }?.members.count ?? 0
            return "\(n) membres · groupe chiffré"
        case .channel:
            return "canal local · non chiffré"
        case nil:
            return ""
        }
    }

    static func header(for ms: Int64, kind: ConversationKind?) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let day: String
        if Calendar.current.isDateInToday(date) { day = "AUJOURD'HUI" }
        else if Calendar.current.isDateInYesterday(date) { day = "HIER" }
        else { day = date.formatted(.dateTime.day().month(.abbreviated)).uppercased() }
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        switch kind {
        case .channel: return "\(day) \(time) · ED25519 · NON CHIFFRÉ"
        case .some: return "\(day) \(time) · ML-KEM-1024 + X25519"
        case nil: return "\(day) \(time)"
        }
    }

    private func sendBySMS(_ item: ChatItem) {
        guard let link = model.smsLink(for: item.id) else {
            model.banner = "Ce message est trop long pour un SMS chiffré."
            return
        }
        let text = "Message chiffré Soma Relay : \(link)"
        if MFMessageComposeViewController.canSendText() {
            smsLink = SMSPayload(messageId: item.id, text: text)
        } else {
            UIPasteboard.general.string = text
            model.banner = "Pas de SMS sur cet appareil. Lien chiffré copié."
        }
    }
}

struct SMSPayload: Identifiable {
    let messageId: String
    let text: String
    var id: String { messageId }
}

/// Three dots while the peer types.
struct TypingBubble: View {
    @State private var phase = 0.0
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Theme.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.incoming, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .accessibilityLabel("En train d'écrire")
    }
}

/// System SMS composer, prefilled with the encrypted link. The user taps Send.
struct MessageComposer: UIViewControllerRepresentable {
    let body: String
    let done: (Bool) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let done: (Bool) -> Void
        init(done: @escaping (Bool) -> Void) { self.done = done }

        nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            let sent = result == .sent
            Task { @MainActor in self.done(sent) }
        }
    }
}
