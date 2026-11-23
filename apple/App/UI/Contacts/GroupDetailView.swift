import SwiftUI

/// A group (relay-screens 11): photo, name and "Groupe chiffré · N membres", quick actions
/// (Ajouter, Rechercher, Sourdine), members with their role and seal, the note on removing someone,
/// the group settings (disappearing messages, photos and files) and "Quitter le groupe" on its own.
/// Admins change the photo and the name (sent as `group-profile`), add and remove members; leaving
/// sends `group-leave` first (spec section 6).
struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let groupId: String
    /// After leaving: the chat closes too.
    var onLeft: () -> Void = {}
    /// "Rechercher": the chat opens its search bar.
    var onSearch: (() -> Void)?

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
    private var conversationId: String { AppModel.groupId(groupId) }
    private var conversation: ConversationRecord? { model.conversations.first { $0.id == conversationId } }

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

    /// Photos, videos and files sent in the group (on this phone).
    private var mediaCount: Int {
        _ = model.messageVersion
        return model.items(in: conversationId).filter { [.image, .video, .file].contains($0.message.kind) }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    DSProfileHeader(name: name, statusIcon: "lock.fill", statusIconTint: DS.label2, status: "Groupe chiffré · \(group?.members.count ?? 0) membres") {
                        if isAdmin {
                            EditablePhoto(name: name, photo: photo, size: 96, icon: "person.3.fill", cropTitle: "Photo du groupe") { image in
                                model.setGroupProfile(groupId, photo: .some(image))
                            }
                        } else {
                            DSAvatar(name: name, size: 96, icon: "person.3.fill", photo: photo)
                        }
                    }
                    .padding(.top, 8)
                    actions
                        .padding(.horizontal, DS.Space.margin)
                        .padding(.top, 20)
                    DSSection(header: "Membres") {
                        ForEach(Array(members.enumerated()), id: \.element) { index, fp in
                            memberRow(fp, first: index == 0)
                        }
                    } footer: {
                        if isAdmin {
                            Text("Retirer quelqu'un change la clé du groupe : ses futurs messages lui restent illisibles. Touche longuement un membre pour le retirer.")
                        }
                    }
                    .padding(.top, DS.Space.group)
                    settings
                        .padding(.top, DS.Space.group)
                    DSSection {
                        DSRow(first: true) {
                            Button("Quitter le groupe", role: .destructive) { confirmLeave = true }
                                .font(DS.TextStyle.body)
                                .foregroundStyle(DS.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, DS.Space.group)
                }
                .padding(.bottom, 32)
            }
            .background(DS.background)
            .animation(.smooth, value: members)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ContactRoute.self) { ContactDetailView(fingerprint: $0.fingerprint) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer", systemImage: "xmark") { dismiss() }
                        .tint(DS.label)
                }
                if isAdmin {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Renommer le groupe", systemImage: "pencil") {
                            newName = name
                            renaming = true
                        }
                        .tint(DS.label)
                    }
                }
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
        .presentationCornerRadius(DS.Radius.sheet)
    }

    private var candidates: [ContactJSON] {
        let inGroup = Set(group?.members ?? [])
        return model.contacts.filter { !inGroup.contains($0.fingerprint) }
    }

    // MARK: Quick actions

    private var actions: some View {
        HStack(spacing: 10) {
            DSQuickAction(systemName: "person.badge.plus", title: "Ajouter") { adding = true }
                .disabled(!isAdmin || candidates.isEmpty)
                .opacity(!isAdmin || candidates.isEmpty ? 0.45 : 1)
                .accessibilityHint(isAdmin ? "" : "Seuls les admins ajoutent des membres")
            if let onSearch {
                DSQuickAction(systemName: "magnifyingglass", title: "Rechercher") {
                    dismiss()
                    onSearch()
                }
            }
            let muted = conversation?.isMuted() == true
            Menu {
                Button("1 heure") { model.mute(conversationId, for: 3600) }
                Button("8 heures") { model.mute(conversationId, for: 8 * 3600) }
                Button("1 semaine") { model.mute(conversationId, for: 7 * 86_400) }
                Button("Toujours") { model.mute(conversationId, for: nil) }
                if muted {
                    Button("Réactiver les notifications", systemImage: "bell") { model.mute(conversationId, for: 0) }
                }
            } label: {
                DSQuickActionLabel(systemName: muted ? "bell.slash.fill" : "bell.slash", title: muted ? "En sourdine" : "Sourdine", accent: false)
            }
            .buttonStyle(.plain)
            .disabled(conversation == nil)
            .accessibilityLabel(conversation.flatMap(AppModel.muteLabel) ?? "Sourdine")
        }
    }

    // MARK: Members

    @ViewBuilder private func memberRow(_ fp: String, first: Bool) -> some View {
        let isMe = fp == me
        let known = model.contact(fp)
        let row = DSRow(first: first, minHeight: 60, separatorInset: 70) {
            memberLabel(fp, isMe: isMe, known: known)
        }
        .contextMenu {
            if isAdmin, !isMe {
                Button("Retirer du groupe", systemImage: "person.badge.minus", role: .destructive) { removing = fp }
            }
        }
        if let known, !isMe {
            NavigationLink(value: ContactRoute(fingerprint: known.fingerprint)) { row.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            row
        }
    }

    private func memberLabel(_ fp: String, isMe: Bool, known: ContactJSON?) -> some View {
        let display = isMe ? model.displayName : model.name(of: fp)
        return HStack(spacing: 14) {
            DSAvatar(name: display, size: 40, photo: model.photo(for: isMe ? nil : fp))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(isMe ? "Toi" : display).font(DS.TextStyle.body).foregroundStyle(DS.label)
                    if known?.verified == true {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 14)).foregroundStyle(DS.accent).accessibilityLabel("vérifié")
                    }
                }
                if !isMe, let known, !known.verified {
                    Text("Mots pas encore vérifiés").font(DS.TextStyle.footnote).foregroundStyle(DS.label2)
                } else if !isMe, known == nil {
                    Text("Pas dans tes contacts").font(DS.TextStyle.footnote).foregroundStyle(DS.label2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if group?.admins.contains(fp) == true {
                Text("Admin").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.label2)
            }
            if let known, !isMe, !known.verified {
                DSChevron()
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Settings

    private var settings: some View {
        DSSection {
            DSRow(first: true) {
                Menu {
                    Picker("Messages éphémères", selection: Binding(get: { conversation?.expireS ?? 0 }, set: { model.setTimer($0, in: conversationId) })) {
                        ForEach(AppModel.timerChoices, id: \.self) { s in
                            Text(s == 0 ? "Désactivés" : AppModel.timerLabel(s)).tag(s)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Messages éphémères").font(DS.TextStyle.body).foregroundStyle(DS.label)
                        Spacer(minLength: 8)
                        Text((conversation?.expireS ?? 0) == 0 ? "Non" : AppModel.timerLabel(conversation?.expireS ?? 0))
                            .font(DS.TextStyle.body).foregroundStyle(DS.label2)
                        DSChevron()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(conversation == nil)
            }
            DSRow {
                Text("Photos et fichiers").font(DS.TextStyle.body).foregroundStyle(DS.label)
                Spacer(minLength: 8)
                Text("\(mediaCount)").font(DS.TextStyle.body).foregroundStyle(DS.label2).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Contacts with checkmarks (add members), on the design system.
struct ContactPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let action: String
    let contacts: [ContactJSON]
    let done: ([String]) -> Void
    @State private var selected: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                DSSection {
                    ContactChecklist(contacts: contacts, selected: $selected)
                }
                .padding(.top, 8)
            }
            .background(DS.background)
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

/// The rows of a grouped card: face, name, a lime checkmark that springs in.
struct ContactChecklist: View {
    let contacts: [ContactJSON]
    @Binding var selected: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let sorted = contacts.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        ForEach(Array(sorted.enumerated()), id: \.element.id) { index, contact in
            let on = selected.contains(contact.fingerprint)
            Button {
                withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.4)) {
                    if on { selected.removeAll { $0 == contact.fingerprint } } else { selected.append(contact.fingerprint) }
                }
                Haptics.select()
            } label: {
                DSRow(first: index == 0, minHeight: 64, separatorInset: 70) {
                    ContactRow(contact: contact)
                    Spacer()
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(on ? DS.onAccent : DS.label3, on ? DS.accentFill : DS.label3)
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
