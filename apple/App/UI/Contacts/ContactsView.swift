import SwiftUI

/// Répertoire: my card, nearby people on the mesh, contacts.
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
                let strangers = model.nearby.filter { $0.name != nil }
                if !strangers.isEmpty {
                    Section("À proximité sur le mesh") {
                        ForEach(strangers) { peer in
                            HStack(spacing: 12) {
                                Avatar(name: peer.name ?? peer.code, size: 40)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(peer.name ?? peer.code).foregroundStyle(Theme.text)
                                    Text(peer.connected ? "relié · \(peer.code)" : "visible · \(peer.code)")
                                        .font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                Button("Ajouter") {
                                    if !peer.connected { model.mesh.invite(peer.id) }
                                    model.requestCard(from: peer)
                                }
                                .buttonStyle(.glass)
                                .disabled(!peer.connected)
                            }
                        }
                    }
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
                if model.contacts.isEmpty && model.nearby.allSatisfy({ $0.name == nil }) {
                    EmptyState(
                        title: "Personne pour l'instant",
                        message: "Scanne le QR d'un proche ou montre-lui le tien. Pas besoin de réseau.",
                        systemImage: "person.2",
                        action: ("Ajouter un contact", { showAdd = true }))
                        .padding(.top, 120)
                }
            }
            .navigationTitle("Répertoire")
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
