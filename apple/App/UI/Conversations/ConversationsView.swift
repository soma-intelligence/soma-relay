import SwiftUI

/// Conversations (1:1 and groups) and local mesh channels.
struct ConversationsView: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var section = Section.chats
    @State private var showNewGroup = false
    @State private var showJoinChannel = false
    @State private var showAddContact = false
    @State private var query = ""
    @State private var hits: [SearchHit] = []

    enum Section: String, CaseIterable { case chats = "Discussions", channels = "Canaux locaux" }

    private var rows: [ConversationRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            return model.conversations.filter { $0.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return model.conversations.filter { section == .channels ? $0.kind == .channel : $0.kind != .channel }
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if isSearching {
                    searchResults
                } else {
                SwiftUI.Section {
                    Picker("Afficher", selection: $section) {
                        ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    if section == .channels {
                        Label("Les canaux locaux ne sont pas chiffrés de bout en bout. Tout le monde à portée peut les lire.", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                            .listRowBackground(Color.clear)
                    }
                }
                ForEach(rows) { conversation in
                    NavigationLink(value: conversation.id) {
                        ConversationRow(conversation: conversation)
                    }
                    .listRowBackground(Theme.incoming.opacity(0.0))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            if conversation.kind == .channel, let name = conversation.peer {
                                model.leaveChannel(name)
                            } else {
                                model.deleteConversation(conversation.id)
                            }
                        } label: {
                            Label(conversation.kind == .channel ? "Quitter" : "Supprimer", systemImage: "trash")
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
            }
            .searchable(text: $query, prompt: "Noms et messages")
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                hits = model.search(query)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .overlay {
                if isSearching {
                    if rows.isEmpty && hits.isEmpty { ContentUnavailableView.search(text: query) }
                } else if rows.isEmpty {
                    empty
                }
            }
            .navigationTitle(section == .chats ? "Conversations" : "Canaux")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    LinkStatusPill()
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Ajouter un contact", systemImage: "person.badge.plus") { showAddContact = true }
                        Button("Nouveau groupe", systemImage: "person.3") { showNewGroup = true }
                        Button("Rejoindre un canal local", systemImage: "number") { showJoinChannel = true }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("Nouveau")
                }
            }
            .navigationDestination(for: String.self) { id in
                ChatView(conversationId: id)
            }
            .navigationDestination(for: ChatRoute.self) { route in
                ChatView(conversationId: route.conversationId, focus: route.focus)
            }
            .sheet(isPresented: $showAddContact) { AddContactView() }
            .sheet(isPresented: $showNewGroup) {
                NewGroupView { id in path.append(id) }
            }
            .alert("Rejoindre un canal local", isPresented: $showJoinChannel) {
                JoinChannelField { name in
                    let id = model.joinChannel(name)
                    if !id.isEmpty {
                        section = .channels
                        path.append(id)
                    }
                }
            } message: {
                Text("Un nom comme festival. Tout le monde à portée qui choisit le même nom te lira.")
            }
        }
        .onAppear {
            guard path.isEmpty, let screen = DemoData.screen else { return }
            switch screen {
            case "chat", "chat-dark", "edit":
                path.append(AppModel.directId(DemoData.ines))
            case "group", "attach", "poll-new", "location", "map", "search", "reactions":
                path.append(AppModel.groupId("stand"))
            case "files", "document":
                path.append(AppModel.directId(DemoData.malik))
            case "list-search":
                query = "plan"
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

    @ViewBuilder private var empty: some View {
        if section == .chats {
            EmptyState(
                title: "Aucune conversation",
                message: "Ajoute quelqu'un en scannant son QR, même sans réseau : vos téléphones se parlent directement.",
                action: ("Ajouter un contact", { showAddContact = true }))
        } else {
            EmptyState(
                title: "Aucun canal",
                message: "Un canal local réunit tout le monde à portée du mesh, sans Internet.",
                systemImage: "number",
                action: ("Rejoindre un canal", { showJoinChannel = true }))
        }
    }
}

extension ConversationsView {
    @ViewBuilder fileprivate var searchResults: some View {
        if !rows.isEmpty {
            SwiftUI.Section("Conversations") {
                ForEach(rows) { conversation in
                    NavigationLink(value: conversation.id) { ConversationRow(conversation: conversation) }
                        .listRowBackground(Color.clear)
                }
            }
        }
        if !hits.isEmpty {
            SwiftUI.Section("Messages") {
                ForEach(hits) { hit in
                    NavigationLink(value: ChatRoute(conversationId: hit.conversationId, focus: hit.messageId)) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(hit.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                Spacer()
                                Text(ConversationRow.time(hit.ts)).font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                            }
                            Text(highlighted(hit.snippet))
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
    }

    fileprivate func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = out.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            out[r].foregroundColor = Theme.text
            out[r].font = .subheadline.weight(.semibold)
        }
        return out
    }
}

private struct JoinChannelField: View {
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

    var body: some View {
        HStack(spacing: 12) {
            Avatar(
                name: conversation.title, size: 50, tint: Theme.incoming,
                icon: conversation.kind == .channel ? "number" : conversation.kind == .group ? "person.3.fill" : nil,
                photo: model.photo(of: conversation))
                .overlay(alignment: .bottomTrailing) {
                    if conversation.kind == .direct, let peer = conversation.peer, model.contact(peer)?.verified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.mesh)
                            .background(Circle().fill(Theme.background).padding(-1))
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.title)
                        .font(.body.weight(conversation.unread > 0 ? .semibold : .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if conversation.isMuted() {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                            .accessibilityLabel("en sourdine")
                    }
                    if conversation.expireS > 0 {
                        Image(systemName: "timer")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                            .accessibilityLabel("messages éphémères")
                    }
                    Spacer(minLength: 6)
                    Text(Self.time(conversation.lastAt))
                        .font(Theme.mono(11))
                        .foregroundStyle(conversation.unread > 0 ? Theme.mesh : Theme.secondary)
                }
                HStack(spacing: 6) {
                    TransportBadge(transport: conversation.lastTransport)
                    Text(model.isTyping(conversation.id) ? "écrit…" : model.preview(of: conversation))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if conversation.unread > 0 {
                        Text("\(conversation.unread)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.onMesh)
                            .padding(.horizontal, 7)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(conversation.isMuted() ? Theme.dashed : Theme.mesh, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityHint(conversation.unread > 0 ? "\(conversation.unread) non lus" : "")
    }

    static func time(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        if Calendar.current.isDateInToday(date) { return date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "fr_FR"))) }
        if Calendar.current.isDateInYesterday(date) { return "hier" }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR")))
    }
}
