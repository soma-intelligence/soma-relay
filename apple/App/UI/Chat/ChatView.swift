import MessageUI
import QuickLook
import SwiftUI

/// Direction E chat: glass header, collapsible path card with the mini radar, grouped
/// transport-coloured bubbles with mono metadata, day and unread separators, dashed bubbles for
/// messages still on their way, reactions, search, and the glass composer.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversationId: String
    var focus: String?

    @State private var items: [ChatItem] = []
    @State private var replyTo: ChatItem?
    @State private var editing: ChatItem?
    @State private var pathExpanded = false
    @State private var smsLink: SMSPayload?
    @State private var viewer: ChatItem?
    @State private var showDetails = false
    @State private var player = VoicePlayer()
    @State private var unreadAnchor: String?
    @State private var unreadCount = 0
    @State private var atBottom = true
    @State private var newBelow = 0
    @State private var scrollRequest: ScrollRequest?
    @State private var flashId: String?
    @State private var width: CGFloat = 390
    // Sheets
    @State private var forwardItem: ChatItem?
    @State private var infoItem: ChatItem?
    @State private var emojiItem: ChatItem?
    @State private var mapItemId: String?
    @State private var docURL: URL?
    @State private var safariURL: IdentifiedURL?
    @State private var confirmDelete: ChatItem?
    // Search
    @State private var searching = false
    @State private var query = ""
    @State private var hits: [String] = []
    @State private var hitIndex = 0
    @FocusState private var searchFocused: Bool

    struct ScrollRequest: Equatable {
        let id: String
        let anchor: UnitPoint
        let flash: Bool
        let token = UUID()
    }

    private var conversation: ConversationRecord? { model.conversations.first { $0.id == conversationId } ?? model.db.conversation(conversationId) }
    private var peer: ContactJSON? { conversation?.kind == .direct ? conversation?.peer.flatMap(model.contact) : nil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !items.isEmpty {
                        Text(Self.header(kind: conversation?.kind ?? .direct))
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.secondary)
                            .padding(.bottom, 4)
                            .accessibilityLabel(conversation?.kind == .channel ? "Canal non chiffré" : "Chiffrement post-quantique ML-KEM-1024 et X25519")
                    }
                    ForEach(rows) { row in
                        rowView(row)
                    }
                    if model.isTyping(conversationId) {
                        TypingBubble()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                            .id("typing")
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85, anchor: .bottomLeading)))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.2), value: items.map(\.id))
                .animation(.smooth, value: model.isTyping(conversationId))
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentSize.height - geo.visibleRect.maxY < 140
            } action: { _, bottom in
                atBottom = bottom
                if bottom { newBelow = 0 }
            }
            .onChange(of: items.last?.id) { old, id in
                guard let id, old != nil, old != id else { return }
                let mine = items.last?.isMine == true
                if mine || atBottom {
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                } else {
                    newBelow += 1
                }
            }
            .onChange(of: model.isTyping(conversationId)) { _, typing in
                if typing, atBottom { withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.45)) {
                    proxy.scrollTo(request.id, anchor: request.anchor)
                }
                guard request.flash else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    flashId = request.id
                    try? await Task.sleep(for: .milliseconds(900))
                    if flashId == request.id { flashId = nil }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
                if searching { searchBar } else { header }
                if conversation?.kind != .channel, !searching {
                    PathCard(conversation: conversation, peer: peer, expanded: $pathExpanded)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .background {
                // Messages fade out under the header instead of showing through the glass.
                LinearGradient(
                    stops: [.init(color: Theme.background, location: 0), .init(color: Theme.background, location: 0.9), .init(color: Theme.background.opacity(0), location: 1)],
                    startPoint: .top, endPoint: .bottom)
                    .padding(.bottom, -14)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
            .animation(.snappy(duration: 0.25), value: searching)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .trailing, spacing: 8) {
                if !atBottom, !items.isEmpty {
                    scrollToBottomButton
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                }
                if !searching {
                    Composer(conversationId: conversationId, replyTo: $replyTo, editing: $editing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .animation(.snappy(duration: 0.25), value: atBottom)
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear(perform: appear)
        .onDisappear {
            if model.activeConversation == conversationId { model.activeConversation = nil }
            player.stop()
        }
        .onChange(of: model.messageVersion) {
            reload()
            if conversation?.unread ?? 0 > 0 { model.markRead(conversationId) }
            if searching { runSearch(keepIndex: true) }
        }
        .onChange(of: model.openRequest) { _, request in
            guard let request, request.conversationId == conversationId else { return }
            model.openRequest = nil
            if let id = request.focus { scrollRequest = ScrollRequest(id: id, anchor: .center, flash: true) }
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
        .fullScreenCover(item: Binding(get: { mapItemId.map(IdentifiedString.init) }, set: { mapItemId = $0?.id })) { wrapped in
            if let item = items.first(where: { $0.id == wrapped.id }) {
                MapViewer(
                    item: item, name: item.isMine ? "Toi" : (item.senderName ?? model.name(of: item.sender)),
                    onStop: item.isMine && model.liveShares[item.id] != nil ? { model.stopLive(item.id) } : nil)
            }
        }
        .sheet(isPresented: $showDetails) {
            if let peer {
                NavigationStack { ContactDetailView(fingerprint: peer.fingerprint) }
            }
        }
        .sheet(item: $forwardItem) { ForwardSheet(item: $0) }
        .sheet(item: $infoItem) { MessageInfoView(item: $0).presentationDetents([.medium, .large]) }
        .sheet(item: $emojiItem) { item in
            EmojiPickerSheet { model.react($0, to: item) }
                .presentationDetents([.medium])
        }
        .sheet(item: $safariURL) { SafariView(url: $0.url).ignoresSafeArea() }
        .quickLookPreview($docURL)
        .onChange(of: docURL) { old, new in
            if new == nil, let old { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
        }
        .confirmationDialog(
            "Supprimer pour tout le monde ?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible, presenting: confirmDelete
        ) { item in
            Button("Supprimer pour tous", role: .destructive) { model.deleteForEveryone(item) }
        } message: { _ in
            Text("Le message devient « Message supprimé » chez chacun, et son média est effacé.")
        }
    }

    // MARK: Rows

    private enum Row: Identifiable {
        case day(String, Int64)
        case unread(Int)
        case message(ChatItem, RunPosition, Bool)
        case system(ChatItem)

        var id: String {
            switch self {
            case .day(_, let ts): "day-\(ts)"
            case .unread: "unread"
            case .message(let item, _, _), .system(let item): item.id
            }
        }
    }

    private var rows: [Row] {
        var out: [Row] = []
        let cal = Calendar.current
        var lastDay: Date?
        let showNames = conversation?.kind != .direct
        func sameRun(_ a: ChatItem, _ b: ChatItem) -> Bool {
            !a.isSystem && !b.isSystem && a.sender == b.sender && b.id != unreadAnchor
                && abs(b.message.ts - a.message.ts) < 180_000
                && cal.isDate(Date(timeIntervalSince1970: Double(a.message.ts) / 1000), inSameDayAs: Date(timeIntervalSince1970: Double(b.message.ts) / 1000))
        }
        for (i, item) in items.enumerated() {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: Double(item.message.ts) / 1000))
            if day != lastDay {
                out.append(.day(DaySeparator.label(for: item.message.ts), item.message.ts))
                lastDay = day
            }
            if item.id == unreadAnchor { out.append(.unread(unreadCount)) }
            if item.isSystem {
                out.append(.system(item))
                continue
            }
            let first = i == 0 || !sameRun(items[i - 1], item)
            let last = i == items.count - 1 || !sameRun(item, items[i + 1])
            out.append(.message(item, RunPosition(first: first, last: last), showNames && !item.isMine && first))
        }
        return out
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        switch row {
        case .day(let text, _):
            DaySeparator(text: text)
        case .unread(let n):
            UnreadSeparator(count: n).id("unread")
        case .system(let item):
            SystemLine(text: AppModel.timerSentence(item.message.settings?.expireS ?? 0, by: item.isMine ? nil : model.name(of: item.sender)))
                .id(item.id)
        case .message(let item, let position, let showSender):
            MessageRow(
                item: item, position: position, showSender: showSender,
                quoted: item.message.replyTo.flatMap { id in items.first { $0.id == id } },
                player: player, flashing: flashId == item.id, maxWidth: width * 0.76, actions: actions)
                .id(item.id)
                .transition(insertion(for: item))
        }
    }

    private func insertion(for item: ChatItem) -> AnyTransition {
        if reduceMotion { return .opacity }
        if item.isMine {
            return .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .scale(scale: 0.88, anchor: .bottomTrailing)).combined(with: .opacity),
                removal: .opacity.combined(with: .scale(scale: 0.9)))
        }
        return .asymmetric(
            insertion: .scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity),
            removal: .opacity.combined(with: .scale(scale: 0.9)))
    }

    private var actions: RowActions {
        RowActions(
            reply: { item in withAnimation(.snappy) { editing = nil; replyTo = item } },
            react: { emoji, item in model.react(emoji, to: item) },
            moreReactions: { emojiItem = $0 },
            forward: { forwardItem = $0 },
            edit: { item in withAnimation(.snappy) { replyTo = nil; editing = item } },
            deleteForMe: { item in withAnimation(.smooth) { model.deleteForMe(item) } },
            deleteForAll: { confirmDelete = $0 },
            info: { infoItem = $0 },
            sms: { sendBySMS($0) },
            retry: { model.retry($0.id) },
            open: open,
            openQuote: { id in
                if items.contains(where: { $0.id == id }) {
                    scrollRequest = ScrollRequest(id: id, anchor: .center, flash: true)
                } else {
                    model.banner = "Le message d'origine n'est plus là."
                }
            },
            openLink: { url in
                if url.scheme == "http" || url.scheme == "https" { safariURL = IdentifiedURL(url: url) } else { UIApplication.shared.open(url) }
            },
            vote: { option, item in model.vote(option, in: item) },
            closePoll: { model.closePoll($0) },
            stopLive: { model.stopLive($0.id) })
    }

    private func open(_ item: ChatItem) {
        switch item.message.kind {
        case .image, .video:
            viewer = item
        case .file:
            guard let path = item.mediaPath, let url = MediaStore.temporaryURL(path, fileName: item.message.attachment?.name ?? "fichier") else {
                model.banner = "Le document arrive, encore un instant."
                return
            }
            docURL = url
        case .location:
            mapItemId = item.id
        default:
            break
        }
    }

    private var scrollToBottomButton: some View {
        Button {
            newBelow = 0
            scrollRequest = ScrollRequest(id: "bottom", anchor: .bottom, flash: false)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 42, height: 42)
                .glassEffect(.regular.interactive(), in: Circle())
                .overlay(alignment: .topTrailing) {
                    if newBelow > 0 {
                        Text("\(newBelow)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.onMesh)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Theme.mesh, in: Capsule())
                            .offset(x: 4, y: -4)
                            .contentTransition(.numericText())
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(newBelow > 0 ? "Aller en bas, \(newBelow) nouveau\(newBelow > 1 ? "x" : "") message\(newBelow > 1 ? "s" : "")" : "Aller en bas")
    }

    // MARK: Lifecycle

    private func appear() {
        model.activeConversation = conversationId
        let unread = conversation?.unread ?? 0
        reload()
        if unread > 0 {
            let incoming = items.filter { !$0.isMine && !$0.isSystem }
            if incoming.count >= unread {
                unreadAnchor = incoming[incoming.count - unread].id
                unreadCount = unread
                scrollRequest = ScrollRequest(id: "unread", anchor: .top, flash: false)
            }
        }
        model.markRead(conversationId)
        if let focus {
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                scrollRequest = ScrollRequest(id: focus, anchor: .center, flash: true)
            }
        }
        runDemo()
    }

    private func reload() {
        items = model.items(in: conversationId)
    }

    /// Debug screens for screenshots (`-RelayDemoScreen`).
    private func runDemo() {
        guard let screen = DemoData.screen else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            switch screen {
            case "document":
                if let doc = items.last(where: { $0.message.kind == .file }) { open(doc) }
            case "map":
                if let loc = items.last(where: { $0.message.kind == .location }) { open(loc) }
            case "search":
                searching = true
                query = "midi"
                runSearch(keepIndex: false)
            case "reactions":
                if let target = items.last(where: { $0.message.kind == .text && !$0.isMine }) { emojiItem = target }
            default:
                break
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
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
                    HStack(spacing: 4) {
                        Text(conversation?.title ?? "")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if conversation?.isMuted() == true {
                            Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(Theme.secondary)
                                .accessibilityLabel("en sourdine")
                        }
                    }
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
            }
            conversationMenu
        }
        .glassBar()
    }

    private var conversationMenu: some View {
        Menu {
            Button("Rechercher", systemImage: "magnifyingglass") {
                withAnimation(.snappy) { searching = true }
                searchFocused = true
            }
            if conversation?.kind != .channel {
                Picker(selection: Binding(get: { conversation?.expireS ?? 0 }, set: { model.setTimer($0, in: conversationId) })) {
                    ForEach(AppModel.timerChoices, id: \.self) { s in
                        Text(s == 0 ? "Désactivés" : AppModel.timerLabel(s)).tag(s)
                    }
                } label: {
                    Label("Messages éphémères", systemImage: "timer")
                    Text(AppModel.timerLabel(conversation?.expireS ?? 0))
                }
                .pickerStyle(.menu)
            }
            Menu {
                Button("1 heure") { model.mute(conversationId, for: 3600) }
                Button("8 heures") { model.mute(conversationId, for: 8 * 3600) }
                Button("1 semaine") { model.mute(conversationId, for: 7 * 86_400) }
                Button("Toujours") { model.mute(conversationId, for: nil) }
                if conversation?.isMuted() == true {
                    Button("Réactiver les notifications", systemImage: "bell") { model.mute(conversationId, for: 0) }
                }
            } label: {
                Label("Sourdine", systemImage: conversation?.isMuted() == true ? "bell.slash.fill" : "bell.slash")
                if let c = conversation, let label = AppModel.muteLabel(c) { Text(label) }
            }
            if peer != nil {
                Button("Fiche du contact", systemImage: "person.crop.circle") { showDetails = true }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).roundIcon()
        }
        .accessibilityLabel("Options de la conversation")
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary).padding(.leading, 10)
            TextField("Rechercher dans la conversation", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { step(1) }
                .onChange(of: query) { runSearch(keepIndex: false) }
                .frame(minHeight: 44)
            if !query.isEmpty {
                Text(hits.isEmpty ? "0" : "\(hitIndex + 1)/\(hits.count)")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            Button { step(-1) } label: { Image(systemName: "chevron.up").roundIcon(size: 36) }
                .buttonStyle(.plain).disabled(hits.count < 2)
                .accessibilityLabel("Résultat précédent")
            Button { step(1) } label: { Image(systemName: "chevron.down").roundIcon(size: 36) }
                .buttonStyle(.plain).disabled(hits.count < 2)
                .accessibilityLabel("Résultat suivant")
            Button("OK") {
                withAnimation(.snappy) { searching = false }
                query = ""
                hits = []
            }
            .font(.body.weight(.semibold))
            .padding(.trailing, 8)
        }
        .glassBar()
    }

    private func runSearch(keepIndex: Bool) {
        let found = model.searchIds(query, in: items)
        hits = found
        if !keepIndex || hitIndex >= found.count { hitIndex = max(0, found.count - 1) }
        if !keepIndex, let id = found[safe: hitIndex] { scrollRequest = ScrollRequest(id: id, anchor: .center, flash: true) }
    }

    private func step(_ delta: Int) {
        guard !hits.isEmpty else { return }
        hitIndex = (hitIndex + delta + hits.count) % hits.count
        Haptics.select()
        scrollRequest = ScrollRequest(id: hits[hitIndex], anchor: .center, flash: true)
    }

    private var subtitle: String {
        var text: String
        switch conversation?.kind {
        case .direct:
            guard let peer else { return "" }
            text = "fp \(peer.fingerprint.groupedFingerprint(groups: 2)) · \(peer.verified ? "vérifiée" : "non vérifiée")"
        case .group:
            let n = model.groups.first { $0.id == conversation?.peer }?.members.count ?? 0
            text = "\(n) membres · groupe chiffré"
        case .channel:
            text = "canal local · non chiffré"
        case nil:
            text = ""
        }
        if let s = conversation?.expireS, s > 0 { text += " · éphémère " + AppModel.timerLabel(s) }
        return text
    }

    static func header(kind: ConversationKind) -> String {
        switch kind {
        case .channel: "ED25519 · NON CHIFFRÉ"
        default: "CHIFFRÉ DE BOUT EN BOUT · ML-KEM-1024 + X25519"
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

struct IdentifiedString: Identifiable {
    let id: String
}

struct SMSPayload: Identifiable {
    let messageId: String
    let text: String
    var id: String { messageId }
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
