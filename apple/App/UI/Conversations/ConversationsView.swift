import SwiftUI

/// Discussions: 1:1 and groups (local channels live in À proximité). Large title, the network
/// state in one plain sentence, filter chips, two-line previews.
struct ConversationsView: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var filter = Filter.all
    @State private var showNewGroup = false
    @State private var showJoinChannel = false
    @State private var showAddContact = false
    @State private var showMyCard = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Filter: CaseIterable { case all, unread, groups, ephemeral
        var title: String {
            switch self {
            case .all: "Toutes"
            case .unread: "Non lues"
            case .groups: "Groupes"
            case .ephemeral: "Éphémères"
            }
        }
    }

    private var chats: [ConversationRecord] { model.conversations.filter { $0.kind != .channel } }

    private var rows: [ConversationRecord] {
        switch filter {
        case .all: chats
        case .unread: chats.filter { $0.unread > 0 }
        case .groups: chats.filter { $0.kind == .group }
        case .ephemeral: chats.filter { $0.expireS > 0 }
        }
    }

    private var unreadCount: Int { chats.filter { $0.unread > 0 }.count }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                SwiftUI.Section {
                    NetworkStatusLine()
                        .listRowInsets(EdgeInsets(top: 0, leading: DS.Space.margin, bottom: 0, trailing: DS.Space.margin))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    filterChips
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 6, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(rows) { conversation in
                    NavigationLink(value: conversation.id) {
                        ConversationRow(conversation: conversation)
                    }
                    .navigationLinkIndicatorVisibility(.hidden)
                    .listRowInsets(EdgeInsets(top: 11, leading: DS.Space.margin, bottom: 11, trailing: DS.Space.margin))
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(DS.separator)
                    .listRowSeparator(conversation.id == rows.last?.id ? .hidden : .automatic, edges: .bottom)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 65 }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            model.deleteConversation(conversation.id)
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if conversation.isMuted() {
                            Button { model.mute(conversation.id, for: 0) } label: { Label("Réactiver", systemImage: "bell") }
                                .tint(Theme.mesh)
                        } else {
                            Button { model.mute(conversation.id, for: 8 * 3600) } label: { Label("Sourdine 8 h", systemImage: "bell.slash") }
                                .tint(Color(UIColor(hex: 0x5B636E, alpha: 1)))
                        }
                    }
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.15), value: rows.map(\.id))
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(DS.background)
            .overlay {
                if rows.isEmpty { empty.padding(.top, 140) }
            }
            .dsTabChrome(title: "Discussions")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showMyCard = true } label: { Image(systemName: "qrcode.viewfinder").foregroundStyle(DS.label) }
                        .accessibilityLabel("Ma carte et scanner")
                        .accessibilityHint("Affiche ton QR en plein écran, pour te faire ajouter ou scanner quelqu'un")
                    Menu {
                        Button("Ajouter un contact", systemImage: "person.badge.plus") { showAddContact = true }
                        Button("Nouveau groupe", systemImage: "person.3") { showNewGroup = true }
                        Button("Rejoindre un canal local", systemImage: "number") { showJoinChannel = true }
                    } label: {
                        Image(systemName: "square.and.pencil").foregroundStyle(DS.label)
                    }
                    .accessibilityLabel("Nouveau message")
                }
            }
            .navigationDestination(for: String.self) { id in
                ChatView(conversationId: id)
            }
            .navigationDestination(for: ChatRoute.self) { route in
                ChatView(conversationId: route.conversationId, focus: route.focus)
            }
            .sheet(isPresented: $showAddContact) { AddContactView() }
            .fullScreenCover(isPresented: $showMyCard) {
                MyCardView { id in
                    showMyCard = false
                    path = NavigationPath()
                    path.append(id)
                }
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupView { id in path.append(id) }
            }
            .alert("Rejoindre un canal local", isPresented: $showJoinChannel) {
                JoinChannelField { name in
                    let id = model.joinChannel(name)
                    if !id.isEmpty { path.append(id) }
                }
            } message: {
                Text("Un nom comme festival. Tout le monde à portée qui choisit le même nom te lira.")
            }
        }
        .onAppear {
            guard path.isEmpty, let screen = DemoData.screen else { return }
            switch screen {
            case "chat", "chat-dark", "edit", "camera-preview", "composer", "route":
                path.append(AppModel.directId(DemoData.ines))
            case "group", "attach", "poll-new", "location", "map", "search", "reactions":
                path.append(AppModel.groupId("stand"))
            case "files", "document":
                path.append(AppModel.directId(DemoData.malik))
            case "mycard":
                showMyCard = true
            case "new-group":
                showNewGroup = true
            case "group-detail", "search-chat":
                path.append(AppModel.groupId("stand"))
            case "channel":
                path.append(AppModel.channelId("festival"))
            default:
                break
            }
        }
        .onChange(of: model.openRequest) { _, request in
            guard let request else { return }
            // An open chat handles its own request (scroll to the message).
            if let active = model.activeConversation, active == request.conversationId { return }
            model.openRequest = nil
            path = NavigationPath()
            path.append(ChatRoute(conversationId: request.conversationId, focus: request.focus))
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { f in
                    DSChip(title: f.title, count: f == .unread ? unreadCount : nil, selected: filter == f) {
                        withAnimation(.snappy(duration: 0.25)) { filter = f }
                    }
                }
            }
            .padding(.horizontal, DS.Space.margin)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder private var empty: some View {
        if chats.isEmpty {
            EmptyState(
                title: "Aucune conversation",
                message: "Ajoute quelqu'un en scannant son QR, même sans réseau : vos téléphones se parlent directement.",
                action: ("Ajouter un contact", { showAddContact = true }))
        } else {
            EmptyState(
                title: filter == .unread ? "Tout est lu" : filter == .groups ? "Aucun groupe" : "Aucune discussion éphémère",
                message: filter == .unread ? "Les nouveaux messages apparaîtront ici." : "Rien dans ce filtre pour l'instant.",
                systemImage: filter == .unread ? "checkmark.circle" : filter == .groups ? "person.3" : "timer")
        }
    }
}

/// "Mesh actif, 5 téléphones à portée · Nœud connecté": the network state in plain words.
struct NetworkStatusLine: View {
    @Environment(AppModel.self) private var model

    private var meshText: String {
        let n = model.meshPeerCount
        if n == 0 { return "Personne à portée sur le mesh" }
        return "Mesh actif, \(n) téléphone\(n > 1 ? "s" : "") à portée"
    }

    private var nodeText: String? {
        guard model.nodeEnabled else { return nil }
        switch model.nodeState {
        case .ready: return "Nœud connecté"
        case .off: return "Nœud hors ligne"
        case .connecting, .authenticating: return "Connexion au nœud…"
        case .failed: return "Nœud injoignable"
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(compact: false)
            line(compact: true)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(DS.label2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([meshText, nodeText].compactMap { $0 }.joined(separator: ", "))
    }

    private func line(compact: Bool) -> some View {
        HStack(spacing: 7) {
            DSStatusDot(active: model.meshPeerCount > 0)
            Text(compact && model.meshPeerCount > 0 ? "Mesh, \(model.meshPeerCount) à portée" : meshText)
            if let nodeText {
                Text("·").foregroundStyle(DS.label3)
                Image(systemName: "globe").font(.system(size: 13))
                Text(nodeText)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

struct JoinChannelField: View {
    let onJoin: (String) -> Void
    @State private var name = ""

    var body: some View {
        TextField("festival", text: $name)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        Button("Rejoindre") { onJoin(name) }
        Button("Annuler", role: .cancel) {}
    }
}

struct ConversationRow: View {
    @Environment(AppModel.self) private var model
    let conversation: ConversationRecord
    /// Search text to mark in the title.
    var highlight = ""

    private var unread: Bool { conversation.unread > 0 }
    private var typing: Bool { model.isTyping(conversation.id) }

    private var verified: Bool {
        conversation.kind == .direct && conversation.peer.flatMap { model.contact($0)?.verified } == true
    }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            DSAvatar(
                name: conversation.title, size: 52,
                icon: conversation.kind == .channel ? "number" : conversation.kind == .group ? "person.3.fill" : nil,
                photo: model.photo(of: conversation), verified: verified)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(SearchTabView.highlight(conversation.title, query: highlight, font: .system(size: 17, weight: .bold)))
                        .font(.system(size: 17, weight: unread ? .semibold : .medium))
                        .foregroundStyle(DS.label)
                        .lineLimit(1)
                    if conversation.isMuted() {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.label3)
                            .accessibilityLabel("en sourdine")
                    }
                    if conversation.expireS > 0 {
                        Image(systemName: "timer")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.label3)
                            .accessibilityLabel("messages éphémères")
                    }
                    Spacer(minLength: 6)
                    Text(Self.time(conversation.lastAt))
                        .font(.system(size: 15, weight: unread ? .medium : .regular))
                        .monospacedDigit()
                        .foregroundStyle(unread ? DS.accent : DS.label2)
                }
                HStack(alignment: .top, spacing: 10) {
                    preview
                        .font(.system(size: 15))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if unread {
                        DSCountBadge(count: conversation.unread, muted: conversation.isMuted())
                            .padding(.top, 1)
                            .contentTransition(.numericText())
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .animation(.snappy(duration: 0.25), value: conversation.unread)
        .accessibilityElement(children: .combine)
        .accessibilityHint(unread ? "\(conversation.unread) non lus" : "")
    }

    /// The preview, with a transport glyph only when it is unusual: globe for the node, amber
    /// bubble for the SMS fallback. The mesh is the normal case and shows nothing.
    private var preview: Text {
        if typing { return Text("écrit…").foregroundStyle(DS.accent) }
        let body = Text(model.preview(of: conversation)).foregroundStyle(unread ? DS.label.opacity(0.86) : DS.label2)
        switch conversation.lastTransport {
        case .node?:
            let glyph = Text(Image(systemName: "globe")).font(.system(size: 12)).foregroundStyle(DS.label3)
            return Text("\(glyph) \(body)")
        case .sms?:
            let glyph = Text(Image(systemName: "message.fill")).font(.system(size: 12)).foregroundStyle(DS.sms)
            return Text("\(glyph) \(body)")
        default:
            return body
        }
    }

    static func time(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        if Calendar.current.isDateInToday(date) { return date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "fr_FR"))) }
        if Calendar.current.isDateInYesterday(date) { return "hier" }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR")))
    }
}
