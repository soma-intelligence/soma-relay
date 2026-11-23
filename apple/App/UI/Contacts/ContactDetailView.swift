import SwiftUI

/// A contact (relay-screens 10): large avatar and name, the verification state, four quick
/// actions (Écrire, Appeler, Vidéo, Sourdine), the safety words card, the details (pseudo, current
/// route, disappearing messages, fingerprint) and "Supprimer le contact" on its own. Renaming and
/// removing the verification live in the edit menu.
struct ContactDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let fingerprint: String
    /// Presented as a sheet (from a chat): a close button instead of the back button.
    var showsClose = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmRemove = false
    @State private var verifying: ContactJSON?

    private var contact: ContactJSON? { model.contact(fingerprint) }
    private var conversationId: String { AppModel.directId(fingerprint) }
    private var conversation: ConversationRecord? { model.conversations.first { $0.id == conversationId } }

    var body: some View {
        Group {
            if let contact {
                ScrollView {
                    VStack(spacing: 0) {
                        DSProfileHeader(
                            name: contact.name,
                            statusIcon: contact.verified ? "checkmark.seal.fill" : "exclamationmark.shield",
                            statusIconTint: contact.verified ? DS.accent : DS.label2,
                            status: contact.verified ? "Mots de sécurité vérifiés" : "Mots pas encore vérifiés"
                        ) {
                            DSAvatar(name: contact.name, size: 96, photo: model.photo(for: contact.fingerprint))
                        }
                        .padding(.top, 8)
                        actions(contact)
                            .padding(.horizontal, DS.Space.margin)
                            .padding(.top, 20)
                        wordsCard(contact)
                            .padding(.horizontal, DS.Space.margin)
                            .padding(.top, DS.Space.group)
                        details(contact)
                            .padding(.top, DS.Space.group)
                        DSSection {
                            DSRow(first: true) {
                                Button("Supprimer le contact", role: .destructive) { confirmRemove = true }
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
                .toolbar { toolbar(contact) }
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
                .sheet(item: $verifying) { VerifyWordsSheet(contact: $0) }
            } else {
                EmptyState(title: "Contact supprimé", message: "", systemImage: "person.crop.circle.badge.xmark")
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ToolbarContentBuilder private func toolbar(_ contact: ContactJSON) -> some ToolbarContent {
        if showsClose {
            ToolbarItem(placement: .topBarLeading) {
                Button("Fermer", systemImage: "xmark") { dismiss() }
                    .tint(DS.label)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Renommer", systemImage: "pencil") {
                    newName = contact.name
                    renaming = true
                }
                if contact.verified {
                    Button("Retirer la vérification", systemImage: "xmark.seal") {
                        model.setVerified(contact.fingerprint, false)
                    }
                }
            } label: {
                Image(systemName: "pencil").foregroundStyle(DS.label)
            }
            .accessibilityLabel("Modifier")
            .accessibilityIdentifier("contact.edit")
        }
    }

    // MARK: Quick actions

    private func actions(_ contact: ContactJSON) -> some View {
        HStack(spacing: 10) {
            DSQuickAction(systemName: "message.fill", title: "Écrire") {
                model.openDirect(contact.fingerprint)
                model.openRequest = ChatRoute(conversationId: conversationId, focus: nil)
                dismiss()
            }
            DSQuickAction(systemName: "phone.fill", title: "Appeler") { model.calls.start(with: contact.fingerprint, video: false) }
            DSQuickAction(systemName: "video.fill", title: "Vidéo") { model.calls.start(with: contact.fingerprint, video: true) }
            muteAction
        }
    }

    /// Sourdine: the same choices as the chat menu, on the direct conversation.
    private var muteAction: some View {
        let muted = conversation?.isMuted() == true
        return Menu {
            Button("1 heure") { mute(3600) }
            Button("8 heures") { mute(8 * 3600) }
            Button("1 semaine") { mute(7 * 86_400) }
            Button("Toujours") { mute(nil) }
            if muted {
                Button("Réactiver les notifications", systemImage: "bell") { mute(0) }
            }
        } label: {
            DSQuickActionLabel(systemName: muted ? "bell.slash.fill" : "bell.slash", title: muted ? "En sourdine" : "Sourdine", accent: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(conversation.flatMap(AppModel.muteLabel) ?? "Sourdine")
    }

    private func mute(_ seconds: TimeInterval?) {
        model.openDirect(fingerprint)
        model.mute(conversationId, for: seconds)
    }

    // MARK: Safety words

    private func wordsCard(_ contact: ContactJSON) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Mots de sécurité")
                    .font(DS.TextStyle.headline)
                    .foregroundStyle(DS.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if contact.verified {
                    DSMatchBadge()
                } else {
                    Button("Vérifier") { verifying = contact }
                        .buttonStyle(.dsSmallCapsule)
                        .accessibilityLabel("Vérifier les mots avec \(contact.name)")
                }
            }
            DSWordGrid(words: model.safetyWords(with: contact.fingerprint))
                .padding(.top, 14)
                .padding(.bottom, 12)
            Text(contact.verified
                ? "Ces mots viennent de ta clé et de la sienne. Tant qu'ils restent les mêmes, personne ne s'est glissé entre toi et \(contact.name)."
                : "Lis-lui ces mots, en face ou au téléphone. Les mêmes sur son écran : personne ne s'est glissé entre toi et \(contact.name).")
                .font(DS.TextStyle.footnote)
                .foregroundStyle(DS.label2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .dsCard()
    }

    // MARK: Details

    private func details(_ contact: ContactJSON) -> some View {
        let route = ChatView.routeSubtitle(route: model.routes[contact.fingerprint], meshPeers: model.meshPeerCount, nodeReady: model.nodeState == .ready)
        return DSSection {
            DSRow(first: true) {
                valueRow("Pseudo", contact.handle.map { "@" + $0 } ?? "Aucun")
            }
            if let node = contact.nodeUrl {
                DSRow {
                    valueRow("Nœud", URL(string: node)?.host() ?? node)
                }
            }
            DSRow {
                valueRow("Chemin actuel", route.text)
            }
            DSRow {
                Menu {
                    Picker("Messages éphémères", selection: Binding(
                        get: { conversation?.expireS ?? 0 },
                        set: { seconds in
                            model.openDirect(contact.fingerprint)
                            model.setTimer(seconds, in: conversationId)
                        })) {
                        ForEach(AppModel.timerChoices, id: \.self) { s in
                            Text(s == 0 ? "Désactivés" : AppModel.timerLabel(s)).tag(s)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Messages éphémères").font(DS.TextStyle.body).foregroundStyle(DS.label)
                        Spacer(minLength: 8)
                        Text((conversation?.expireS ?? 0) == 0 ? "Non" : AppModel.timerLabel(conversation?.expireS ?? 0))
                            .font(DS.TextStyle.body)
                            .foregroundStyle(DS.label2)
                        DSChevron()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            DSRow(minHeight: 64) {
                Text("Empreinte").font(DS.TextStyle.body).foregroundStyle(DS.label)
                Spacer(minLength: 8)
                Text(fingerprintLines(contact.fingerprint))
                    .font(DS.TextStyle.fingerprint(13))
                    .foregroundStyle(DS.label2)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(DS.TextStyle.body).foregroundStyle(DS.label)
            Spacer(minLength: 8)
            Text(value)
                .font(DS.TextStyle.body)
                .foregroundStyle(DS.label2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    /// The whole fingerprint, four groups of four a line.
    private func fingerprintLines(_ fp: String) -> String {
        let groups = fp.groupedFingerprint(groups: 16).split(separator: "·")
        return stride(from: 0, to: groups.count, by: 4)
            .map { groups[$0..<min($0 + 4, groups.count)].joined(separator: " ") }
            .joined(separator: "\n")
    }
}

extension Error {
    var message: String { (self as? RelayCoreError)?.message ?? localizedDescription }
}
