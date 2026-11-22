import SwiftUI

/// A contact: words to verify, fingerprint, rename, call, remove.
struct ContactDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let fingerprint: String
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmRemove = false

    private var contact: ContactJSON? { model.contact(fingerprint) }

    var body: some View {
        Group {
            if let contact {
                List {
                    Section {
                        VStack(spacing: 10) {
                            Avatar(name: contact.name, size: 84, photo: model.photo(for: contact.fingerprint))
                            Text(contact.name).font(.title2.bold()).foregroundStyle(Theme.text)
                            if let handle = contact.handle {
                                Text("@" + handle).font(Theme.mono(13)).foregroundStyle(Theme.secondary)
                            }
                            HStack(spacing: 12) {
                                action("message.fill", "Écrire") {
                                    model.openDirect(contact.fingerprint)
                                    dismiss()
                                }
                                action("phone.fill", "Appeler") { model.calls.start(with: contact.fingerprint, video: false) }
                                action("video.fill", "Vidéo") { model.calls.start(with: contact.fingerprint, video: true) }
                            }
                            .padding(.top, 6)
                        }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    }
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(contact.verified ? "Vérifié" : "Pas encore vérifié", systemImage: contact.verified ? "checkmark.seal.fill" : "exclamationmark.shield")
                                .font(.headline)
                                .foregroundStyle(contact.verified ? Theme.mesh : Theme.text)
                            Text("Comparez ces mots en face ou au téléphone. Identiques des deux côtés : la clé est la bonne.")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                            WordPills(words: model.safetyWords(with: contact.fingerprint))
                                .frame(maxWidth: .infinity)
                            Text(model.safetyCode(with: contact.fingerprint))
                                .font(Theme.mono(13))
                                .foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity)
                            if contact.verified {
                                Button {
                                    model.setVerified(contact.fingerprint, false)
                                } label: {
                                    Text("Retirer la vérification").frame(maxWidth: .infinity).frame(minHeight: 40)
                                }
                                .buttonStyle(.glass)
                            } else {
                                Button {
                                    model.setVerified(contact.fingerprint, true)
                                } label: {
                                    Text("Les mots sont identiques").frame(maxWidth: .infinity).frame(minHeight: 40)
                                }
                                .buttonStyle(.glassProminent)
                            }
                        }
                        .padding(.vertical, 6)
                    } header: {
                        Text("Mots de sécurité")
                    }
                    Section("Empreinte") {
                        Text(contact.fingerprint.groupedFingerprint(groups: 16))
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                        if let node = contact.nodeUrl {
                            LabeledContent("Nœud", value: URL(string: node)?.host() ?? node)
                        }
                        if let route = model.routes[contact.fingerprint] {
                            LabeledContent("Dernier passage", value: route.transport == .mesh ? "mesh, \(route.hops ?? 1) saut(s)" : route.transport == .node ? "Internet" : "SMS")
                        }
                    }
                    Section {
                        Button("Renommer", systemImage: "pencil") {
                            newName = contact.name
                            renaming = true
                        }
                        Button("Supprimer le contact", systemImage: "trash", role: .destructive) { confirmRemove = true }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .alert("Renommer", isPresented: $renaming) {
                    TextField("Nom", text: $newName)
                    Button("OK") { model.rename(contact.fingerprint, to: newName) }
                    Button("Annuler", role: .cancel) {}
                }
                .confirmationDialog("Supprimer \(contact.name) ?", isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("Supprimer le contact et la conversation", role: .destructive) {
                        model.removeContact(contact.fingerprint)
                        dismiss()
                    }
                } message: {
                    Text("Ses messages sur ce téléphone seront effacés.")
                }
            } else {
                EmptyState(title: "Contact supprimé", message: "", systemImage: "person.crop.circle.badge.xmark")
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func action(_ icon: String, _ label: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.caption)
            }
            .frame(width: 76, height: 56)
        }
        .buttonStyle(.glass)
    }
}

/// Create a private group from contacts.
struct NewGroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let created: (String) -> Void
    @State private var name = ""
    @State private var selected: Set<String> = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Nom du groupe", text: $name)
                }
                Section("Membres") {
                    if model.contacts.isEmpty {
                        Text("Ajoute d'abord des contacts.").foregroundStyle(Theme.secondary)
                    }
                    ForEach(model.contacts) { contact in
                        Button {
                            if selected.contains(contact.fingerprint) { selected.remove(contact.fingerprint) } else { selected.insert(contact.fingerprint) }
                            Haptics.select()
                        } label: {
                            HStack {
                                ContactRow(contact: contact)
                                Spacer()
                                Image(systemName: selected.contains(contact.fingerprint) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(contact.fingerprint) ? Theme.mesh : Theme.secondary)
                                    .font(.title3)
                            }
                        }
                        .accessibilityAddTraits(selected.contains(contact.fingerprint) ? .isSelected : [])
                    }
                }
                if let error {
                    Text(error).foregroundStyle(Theme.danger)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Nouveau groupe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") {
                        do {
                            let id = try model.createGroup(name: name.trimmingCharacters(in: .whitespaces), members: Array(selected))
                            Haptics.success()
                            dismiss()
                            created(id)
                        } catch {
                            self.error = error.message
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
                }
            }
        }
    }
}

extension Error {
    var message: String { (self as? RelayCoreError)?.message ?? localizedDescription }
}
