import SwiftUI

/// A group: photo and name (admins change them, sent as `group-profile`), members with their
/// faces, add and remove (admins), and leave (`group-leave` first, spec section 6).
struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let groupId: String
    /// After leaving: the chat closes too.
    var onLeft: () -> Void = {}

    @State private var renaming = false
    @State private var newName = ""
    @State private var adding = false
    @State private var confirmLeave = false
    @State private var removing: String?

    private var group: GroupJSON? { model.group(groupId) }
    private var me: String { model.core?.fingerprintHex() ?? "" }
    private var isAdmin: Bool { model.isAdmin(of: groupId) }
    private var name: String { model.groupName(groupId) }
    private var photo: UIImage? { model.photos[AppModel.groupPhotoKey(groupId)] }

    /// Me first, then admins, then by name.
    private var members: [String] {
        guard let group else { return [] }
        return group.members.sorted { a, b in
            if a == me { return true }
            if b == me { return false }
            let aa = group.admins.contains(a), ba = group.admins.contains(b)
            if aa != ba { return aa }
            return model.name(of: a).localizedCompare(model.name(of: b)) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        if isAdmin {
                            EditablePhoto(name: name, photo: photo, size: 96, icon: "person.3.fill", tint: Theme.incoming, cropTitle: "Photo du groupe") { image in
                                model.setGroupProfile(groupId, photo: .some(image))
                            }
                        } else {
                            Avatar(name: name, size: 96, icon: "person.3.fill", photo: photo)
                        }
                        Button {
                            newName = name
                            renaming = true
                        } label: {
                            HStack(spacing: 6) {
                                Text(name).font(.title2.bold()).foregroundStyle(Theme.text)
                                if isAdmin {
                                    Image(systemName: "pencil").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!isAdmin)
                        .accessibilityHint(isAdmin ? "Renommer le groupe" : "")
                        Text("Groupe chiffré · \(group?.members.count ?? 0) membres")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    if isAdmin {
                        Button {
                            adding = true
                        } label: {
                            Label("Ajouter des membres", systemImage: "person.badge.plus")
                        }
                        .disabled(candidates.isEmpty)
                    }
                    ForEach(members, id: \.self) { fp in
                        memberRow(fp)
                            .swipeActions(edge: .trailing) {
                                if isAdmin, fp != me {
                                    Button("Retirer", systemImage: "person.badge.minus", role: .destructive) { removing = fp }
                                }
                            }
                    }
                } header: {
                    Text("\(group?.members.count ?? 0) membres")
                } footer: {
                    if isAdmin {
                        Text("Retirer quelqu'un change la clé du groupe : ses futurs messages lui restent illisibles.")
                    }
                }
                Section {
                    Button("Quitter le groupe", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLeave = true }
                        .tint(Theme.danger)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .animation(.smooth, value: members)
            .navigationTitle("Infos du groupe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
            .alert("Renommer le groupe", isPresented: $renaming) {
                TextField("Nom du groupe", text: $newName)
                Button("OK") { model.setGroupProfile(groupId, name: newName) }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Tous les membres verront ce nom.")
            }
            .confirmationDialog(
                "Retirer \(removing.map { model.name(of: $0) } ?? "") ?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible
            ) {
                Button("Retirer du groupe", role: .destructive) {
                    if let fp = removing { model.removeMember(fp, from: groupId) }
                    removing = nil
                }
            }
            .confirmationDialog("Quitter « \(name) » ?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Quitter le groupe", role: .destructive) {
                    model.leaveGroup(groupId)
                    dismiss()
                    onLeft()
                }
            } message: {
                Text("Les membres verront que tu es parti. La conversation est effacée de ce téléphone.")
            }
            .sheet(isPresented: $adding) {
                ContactPickerSheet(title: "Ajouter", action: "Ajouter", contacts: candidates) { picked in
                    model.addMembers(picked, to: groupId)
                }
            }
        }
    }

    private var candidates: [ContactJSON] {
        let inGroup = Set(group?.members ?? [])
        return model.contacts.filter { !inGroup.contains($0.fingerprint) }
    }

    private func memberRow(_ fp: String) -> some View {
        let isMe = fp == me
        let display = isMe ? model.displayName : model.name(of: fp)
        let known = model.contact(fp)
        return HStack(spacing: 12) {
            Avatar(name: display, size: 40, tint: Theme.senderColor(isMe ? nil : fp).opacity(0.25), photo: model.photo(for: isMe ? nil : fp))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(isMe ? "Toi" : display).foregroundStyle(Theme.text)
                    if known?.verified == true {
                        Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(Theme.mesh).accessibilityLabel("vérifié")
                    }
                }
                if !isMe, known == nil {
                    Text("pas dans ton répertoire").font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            if group?.admins.contains(fp) == true {
                Text("Admin")
                    .font(Theme.mono(10, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.softButton, in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Contacts with checkmarks (new group, add members).
struct ContactPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let action: String
    let contacts: [ContactJSON]
    let done: ([String]) -> Void
    @State private var selected: [String] = []

    var body: some View {
        NavigationStack {
            List {
                ContactChecklist(contacts: contacts, selected: $selected)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.isEmpty ? action : "\(action) (\(selected.count))") {
                        done(selected)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

/// The rows: face, name, a checkmark that springs in.
struct ContactChecklist: View {
    let contacts: [ContactJSON]
    @Binding var selected: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ForEach(contacts.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }) { contact in
            let on = selected.contains(contact.fingerprint)
            Button {
                withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.4)) {
                    if on { selected.removeAll { $0 == contact.fingerprint } } else { selected.append(contact.fingerprint) }
                }
                Haptics.select()
            } label: {
                HStack {
                    ContactRow(contact: contact)
                    Spacer()
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(on ? Theme.mesh : Theme.dashed)
                        .contentTransition(.symbolEffect(.replace))
                        .scaleEffect(on ? 1 : 0.92)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}
