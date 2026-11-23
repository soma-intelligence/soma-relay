import SwiftUI

/// Contacts: my card and the directory (people in range live in À proximité).
struct ContactsView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var showQR = false
    @State private var search = ""

    private var filtered: [ContactJSON] {
        let list = model.contacts.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        guard !search.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(search) || ($0.handle ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showQR = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "qrcode")
                                .font(.system(size: 22))
                                .frame(width: 50, height: 50)
                                .background(Theme.strong, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .foregroundStyle(Theme.onStrong)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ma carte").font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                                Text(model.handle.isEmpty ? (model.core?.fingerprintHex().groupedFingerprint(groups: 3) ?? "") : "\(model.handle)@\(URL(string: model.nodeURL)?.host() ?? "")")
                                    .font(Theme.mono(11))
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                    .accessibilityHint("Affiche ton QR à scanner")
                }
                Section(model.contacts.isEmpty ? "" : "Contacts") {
                    ForEach(filtered) { contact in
                        NavigationLink {
                            ContactDetailView(fingerprint: contact.fingerprint)
                        } label: {
                            ContactRow(contact: contact)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $search, prompt: "Rechercher")
            .overlay {
                if model.contacts.isEmpty {
                    EmptyState(
                        title: "Personne pour l'instant",
                        message: "Scanne le QR d'un proche ou montre-lui le tien. Pas besoin de réseau.",
                        systemImage: "person.2",
                        action: ("Ajouter un contact", { showAdd = true }))
                        .padding(.top, 120)
                }
            }
            .dsTabChrome(title: "Contacts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "person.badge.plus") }
                        .accessibilityLabel("Ajouter un contact")
                }
            }
            .sheet(isPresented: $showAdd) { AddContactView() }
            .sheet(isPresented: $showQR) { MyQRView() }
            .onAppear { if DemoData.screen == "qr" || DemoData.screen == "qr-verify" { showQR = true } }
        }
    }
}

struct ContactRow: View {
    @Environment(AppModel.self) private var model
    let contact: ContactJSON
    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: contact.name, size: 42, photo: model.photo(for: contact.fingerprint))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(contact.name).font(.body.weight(.medium)).foregroundStyle(Theme.text)
                    if contact.verified {
                        Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(Theme.mesh)
                            .accessibilityLabel("vérifié")
                    }
                }
                Text(contact.handle.map { "@" + $0 } ?? "fp " + contact.fingerprint.groupedFingerprint(groups: 2))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.secondary)
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
}
