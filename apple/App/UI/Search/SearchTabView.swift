import SwiftUI

/// The iOS 26 search tab: names and messages across discussions and local channels.
struct SearchTabView: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var hits: [SearchHit] = []

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var rows: [ConversationRecord] {
        guard !trimmed.isEmpty else { return [] }
        return model.conversations.filter { $0.title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !rows.isEmpty {
                    Section("Discussions") {
                        ForEach(rows) { conversation in
                            NavigationLink(value: conversation.id) { ConversationRow(conversation: conversation, highlight: query) }
                                .navigationLinkIndicatorVisibility(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                }
                if !hits.isEmpty {
                    Section("Messages") {
                        ForEach(hits) { hit in
                            NavigationLink(value: ChatRoute(conversationId: hit.conversationId, focus: hit.messageId)) {
                                hitRow(hit)
                            }
                            .navigationLinkIndicatorVisibility(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DS.background)
            .overlay {
                if trimmed.isEmpty {
                    ContentUnavailableView(
                        "Rechercher", systemImage: "magnifyingglass",
                        description: Text("Un nom, un groupe, un canal ou un mot d'un message. La recherche reste sur ton téléphone."))
                } else if rows.isEmpty && hits.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Rechercher")
            .searchable(text: $query, prompt: "Noms et messages")
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                hits = model.search(query)
            }
            .navigationDestination(for: String.self) { id in ChatView(conversationId: id) }
            .navigationDestination(for: ChatRoute.self) { route in ChatView(conversationId: route.conversationId, focus: route.focus) }
        }
        .onAppear {
            if DemoData.screen == "list-search", query.isEmpty { query = "plan" }
        }
    }

    private func hitRow(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if let c = model.conversations.first(where: { $0.id == hit.conversationId }) {
                    DSAvatar(
                        name: c.title, size: 22, icon: c.kind == .channel ? "number" : c.kind == .group ? "person.3.fill" : nil,
                        photo: model.photo(of: c))
                }
                Text(hit.title).font(.subheadline.weight(.semibold)).foregroundStyle(DS.label)
                Spacer()
                Text(ConversationRow.time(hit.ts)).font(DS.TextStyle.footnote).foregroundStyle(DS.label2)
            }
            Text(Self.highlight(hit.snippet, query: query, font: .subheadline.weight(.semibold)))
                .font(.subheadline)
                .foregroundStyle(DS.label2)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    /// Every match of the query in bold, on a soft lime mark.
    static func highlight(_ text: String, query: String, font: Font) -> AttributedString {
        var out = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return out }
        var start = out.startIndex
        while start < out.endIndex, let r = out[start...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            out[r].foregroundColor = DS.label
            out[r].font = font
            out[r].backgroundColor = DS.accentSoft
            start = r.upperBound
        }
        return out
    }
}
