import SwiftUI

/// Contacts (relay-screens 07): my card on top ("Ta carte · @pseudo", QR shortcut), the contacts
/// still to verify with a "Vérifier" action and the risk in one sentence, then everyone with a
/// useful subtitle. People in range live in À proximité.
struct ContactsView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var showCard = false
    @State private var verifying: ContactJSON?
    @State private var search = ""
    @State private var path = NavigationPath()

    private var filtered: [ContactJSON] {
        let list = model.contacts.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        guard !search.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(search) || ($0.handle ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if search.isEmpty { myCard }
                    let toVerify = filtered.filter { !$0.verified }
                    let others = filtered.filter(\.verified)
                    if !toVerify.isEmpty {
                        DSSection(header: "À vérifier") {
                            ForEach(Array(toVerify.enumerated()), id: \.element.id) { index, contact in
                                row(contact, first: index == 0, toVerify: true)
                            }
                        } footer: {
                            Text("Lis-lui les quatre mots de sa fiche, en face ou au téléphone. Tant que ce n'est pas fait, quelqu'un pourrait se glisser entre toi et cette personne.")
                        }
                        .padding(.top, DS.Space.group)
                    }
                    if !others.isEmpty {
                        DSSection(header: "Tous") {
                            ForEach(Array(others.enumerated()), id: \.element.id) { index, contact in
                                row(contact, first: index == 0, toVerify: false)
                            }
                        }
                        .padding(.top, DS.Space.group)
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
            .background(DS.background)
            .searchable(text: $search, prompt: "Rechercher")
            .overlay {
                if model.contacts.isEmpty {
                    EmptyState(
                        title: "Personne pour l'instant",
                        message: "Scanne le QR d'un proche ou montre-lui le tien. Pas besoin de réseau.",
                        systemImage: "person.2",
                        action: ("Ajouter un contact", { showAdd = true }))
                        .padding(.top, 200)
                }
            }
            .dsTabChrome(title: "Contacts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "person.badge.plus").foregroundStyle(DS.label) }
                        .accessibilityLabel("Ajouter un contact")
                }
            }
            .navigationDestination(for: ContactRoute.self) { route in
                ContactDetailView(fingerprint: route.fingerprint)
            }
            .fullScreenCover(isPresented: $showAdd) {
                MyCardView(initialMode: .scan) { id in
                    showAdd = false
                    model.openRequest = ChatRoute(conversationId: id, focus: nil)
                }
            }
            .sheet(item: $verifying) { contact in VerifyWordsSheet(contact: contact) }
            .fullScreenCover(isPresented: $showCard) {
                MyCardView(initialMode: .card) { id in
                    showCard = false
                    model.openRequest = ChatRoute(conversationId: id, focus: nil)
                }
            }
            .onAppear {
                switch DemoData.screen {
                case "qr": showCard = true
                case "add": showAdd = true
                case "qr-verify": verifying = model.contacts.first { !$0.verified } ?? model.contacts.first
                case "contact" where path.isEmpty: path.append(ContactRoute(fingerprint: DemoData.ines))
                default: break
                }
            }
        }
    }

    // MARK: My card

    private var myCard: some View {
        HStack(spacing: 14) {
            DSAvatar(name: model.displayName, size: 56, photo: model.photos[AppModel.me])
            VStack(alignment: .leading, spacing: 0) {
                Text(model.displayName)
                    .font(DS.TextStyle.headline)
                    .foregroundStyle(DS.label)
                Text(model.handle.isEmpty ? "Ta carte" : "Ta carte · @" + model.handle)
                    .font(DS.TextStyle.subheadline)
                    .foregroundStyle(DS.label2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "qrcode")
                .font(.system(size: 20))
                .foregroundStyle(DS.label)
                .frame(width: 44, height: 44)
                .background(DS.fill2, in: Circle())
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DS.Space.cell)
        .padding(.vertical, 14)
        .dsCard()
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.cell, style: .continuous))
        .onTapGesture {
            Haptics.tap()
            showCard = true
        }
        .padding(.horizontal, DS.Space.margin)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Ta carte")
        .accessibilityHint("Affiche ton QR à scanner")
        .accessibilityIdentifier("contacts.mycard")
    }

    // MARK: Rows

    private func row(_ contact: ContactJSON, first: Bool, toVerify: Bool) -> some View {
        DSRow(first: first, minHeight: 64, separatorInset: 70) {
            NavigationLink(value: ContactRoute(fingerprint: contact.fingerprint)) {
                HStack(spacing: 14) {
                    DSAvatar(name: contact.name, size: 40, photo: model.photo(for: contact.fingerprint))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(contact.name)
                                .font(DS.TextStyle.body)
                                .foregroundStyle(DS.label)
                            if contact.verified {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(DS.accent)
                                    .accessibilityLabel("vérifié")
                            }
                        }
                        Text(toVerify ? model.addedLine(contact) : model.contactSubtitle(contact))
                            .font(DS.TextStyle.footnote)
                            .foregroundStyle(DS.label2)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !toVerify { DSChevron() }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            if toVerify {
                Button("Vérifier") {
                    Haptics.tap()
                    verifying = contact
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.label2)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(DS.fill, in: Capsule())
                .buttonStyle(.plain)
                .accessibilityLabel("Vérifier \(contact.name)")
            }
        }
    }
}

/// A contact pushed on the Contacts stack.
struct ContactRoute: Hashable {
    let fingerprint: String
}

/// One contact row (new group, add members): face, name, seal, a short subtitle.
struct ContactRow: View {
    @Environment(AppModel.self) private var model
    let contact: ContactJSON
    var body: some View {
        HStack(spacing: 14) {
            DSAvatar(name: contact.name, size: 40, photo: model.photo(for: contact.fingerprint))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(contact.name).font(DS.TextStyle.body).foregroundStyle(DS.label)
                    if contact.verified {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 14)).foregroundStyle(DS.accent)
                            .accessibilityLabel("vérifié")
                    }
                }
                Text(contact.handle.map { "@" + $0 } ?? "Mots pas encore vérifiés")
                    .font(DS.TextStyle.footnote)
                    .foregroundStyle(DS.label2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension AppModel {
    /// A nearby phone that is already in the directory (its compact link names a contact).
    func isContact(nearby peer: NearbyPeer) -> Bool {
        guard let link = peer.compactLink, let core, let fp = Self.fingerprint(ofCompact: link, core: core) else { return false }
        return contacts.contains { $0.fingerprint == fp }
    }

    /// Contacts in range right now: a nearby phone whose card names them, or a mesh route
    /// seen in the last ten minutes.
    func inRange(_ fp: String) -> Bool {
        if let route = routes[fp], route.transport == .mesh, route.at.timeIntervalSinceNow > -600 { return true }
        guard let core else { return false }
        return nearby.contains { peer in
            peer.compactLink.flatMap { Self.fingerprint(ofCompact: $0, core: core) } == fp
        }
    }

    /// "@ines · à portée sur le mesh", "@malik · dernier message hier": the pseudo and the
    /// freshest real signal (no fingerprint).
    func contactSubtitle(_ contact: ContactJSON) -> String {
        var parts: [String] = []
        if let handle = contact.handle, !handle.isEmpty { parts.append("@" + handle) }
        if inRange(contact.fingerprint) {
            parts.append("à portée sur le mesh")
        } else if nodeOnline.contains(contact.mailbox) {
            parts.append("en ligne par le nœud")
        } else if let c = conversations.first(where: { $0.id == Self.directId(contact.fingerprint) }), c.previewSealed != nil {
            parts.append("dernier message " + Self.relativeDay(c.lastAt))
        }
        return parts.isEmpty ? "Dans tes contacts depuis " + Self.relativeSpan(contact.addedAt) : parts.joined(separator: " · ")
    }

    /// "Dans tes contacts depuis 2 jours" (no gendered "ajoutée").
    func addedLine(_ contact: ContactJSON) -> String {
        "Dans tes contacts depuis " + Self.relativeSpan(contact.addedAt)
    }

    /// "aujourd'hui", "hier", "il y a 3 jours", "le 12 nov.".
    static func relativeDay(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "aujourd'hui" }
        if calendar.isDateInYesterday(date) { return "hier" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
        if days > 1, days < 7 { return "il y a \(days) jours" }
        return "le " + date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR")))
    }

    /// "aujourd'hui", "hier", "2 jours", "3 semaines", "le 12 nov.".
    static func relativeSpan(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "aujourd'hui" }
        if calendar.isDateInYesterday(date) { return "hier" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
        if days < 14 { return "\(days) jours" }
        if days < 60 { return "\(days / 7) semaines" }
        return "le " + date.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "fr_FR")))
    }
}
