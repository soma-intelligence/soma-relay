import SwiftUI

/// Node, identity, lock, safety words, export and emergency wipe. A sheet from the avatar.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var nodeDraft = ""
    @State private var publishing = false
    @State private var confirmWipe = false
    @State private var exportURL: URL?
    @State private var showExport = false
    @State private var lockChanging = false

    var body: some View {
        @Bindable var model = model
        @Bindable var lock = model.lock
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        EditablePhoto(name: model.displayName, photo: model.photos[AppModel.me], size: 64, cropTitle: "Ta photo") { image in
                            model.setMyPhoto(image)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("Ton nom", text: $name)
                                .font(.title3.weight(.semibold))
                                .onSubmit { model.setDisplayName(name) }
                                .submitLabel(.done)
                                .accessibilityLabel("Nom affiché")
                            Text(model.core?.fingerprintHex().groupedFingerprint(groups: 4) ?? "")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                } footer: {
                    Text("Ta photo et ton nom partent chiffrés à tes contacts et à tes groupes, une fois à chaque changement.")
                }
                Section {
                    if let words = model.core?.safetyWords() {
                        WordPills(words: words).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                } header: {
                    Text("Tes mots")
                } footer: {
                    Text("Ils résument ta clé publique. Pour vérifier un contact, comparez plutôt les mots de sa fiche : ils dépendent de vos deux clés.")
                }
                Section {
                    Toggle("Verrouiller Relay", isOn: Binding(get: { model.lock.enabled }, set: setLock))
                        .disabled(lockChanging)
                    if model.lock.enabled {
                        Picker("Verrouiller après", selection: $lock.delay) {
                            ForEach(RelockDelay.allCases) { delay in
                                Text(delay.title).tag(delay)
                            }
                        }
                    }
                } header: {
                    Text("Sécurité")
                } footer: {
                    Text("Relay te demande ta clé d'accès, Face ID ou ton code à l'ouverture. Tes messages continuent d'arriver pendant que l'app est verrouillée.")
                }
                Section {
                    Toggle("Aperçus dans les notifications", isOn: $model.notificationPreviews)
                    Button("Réglages des notifications iOS", systemImage: "bell.badge") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Désactivé : « Nouveau message », sans nom ni texte. Le nœud ne voit jamais le contenu : il réveille seulement l'app, qui déchiffre sur ton téléphone.")
                }
                Section {
                    Toggle("Aperçus des liens", isOn: $model.linkPreviews)
                } header: {
                    Text("Messages")
                } footer: {
                    Text("Ton téléphone prépare l'aperçu d'un lien avant l'envoi. Ton contact ne charge rien.")
                }
                Section {
                    LabeledContent("Téléphones reliés", value: "\(model.meshPeerCount)")
                } header: {
                    Text("Mesh")
                } footer: {
                    Text("Bluetooth et Wi-Fi direct, sans Internet. La visibilité se règle dans l'onglet À proximité.")
                }
                Section {
                    Toggle("Utiliser un nœud", isOn: $model.nodeEnabled)
                    if model.nodeEnabled {
                        TextField(AppConfig.defaultNodeURL, text: $nodeDraft)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(Theme.mono(14))
                            .onSubmit(applyNode)
                        LabeledContent("État", value: nodeStatus)
                        if nodeDraft != model.nodeURL {
                            Button("Utiliser ce nœud", action: applyNode)
                        }
                        if nodeDraft != AppModel.defaultNodeURL {
                            Button("Revenir au nœud Soma Labs") {
                                nodeDraft = AppModel.defaultNodeURL
                                applyNode()
                            }
                        }
                    }
                } header: {
                    Text("Internet")
                } footer: {
                    Text("Un nœud garde tes messages chiffrés quand tu es hors ligne. Il ne peut pas les lire. Tu peux héberger le tien.")
                }
                if model.nodeEnabled {
                    Section {
                        HStack {
                            TextField("pseudo", text: $model.handle)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Text("@" + (URL(string: model.nodeURL)?.host() ?? ""))
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                        }
                        Button {
                            publishing = true
                            Task {
                                defer { publishing = false }
                                do {
                                    try await model.publishHandle()
                                    model.banner = "Pseudo publié."
                                } catch {
                                    model.banner = error.message.isEmpty ? "Publication impossible." : error.message
                                }
                            }
                        } label: {
                            HStack {
                                Text("Publier dans l'annuaire")
                                if publishing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(model.handle.count < 3 || publishing || model.nodeState != .ready)
                    } header: {
                        Text("Pseudo")
                    } footer: {
                        Text("Facultatif. Permet de te trouver par pseudo@nœud, sans numéro ni e-mail.")
                    }
                }
                Section {
                    VaultRow()
                    Button("Exporter mon identité", systemImage: "square.and.arrow.up") {
                        exportURL = nil
                        showExport = true
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Enregistrer le fichier", systemImage: "doc.badge.arrow.up")
                        }
                    }
                } header: {
                    Text("Sauvegarde")
                } footer: {
                    Text("Le passkey chiffre une copie de ton identité sur le nœud, qui ne peut pas la lire. Le fichier contient ta clé privée, chiffrée par une phrase de passe. Garde-le dans un endroit sûr, jamais dans une conversation.")
                }
                Section {
                    Button("Effacement d'urgence", systemImage: "flame", role: .destructive) { confirmWipe = true }
                } footer: {
                    Text("Efface clés, messages et médias de ce téléphone, tout de suite. Irréversible.")
                }
                Section {
                    LabeledContent("Cœur", value: model.usesRealCore ? "relay-core (Rust)" : "test (CryptoKit)")
                    LabeledContent("Version", value: Self.version)
                    Link("Code source (AGPL-3.0)", destination: URL(string: "https://github.com/soma-intelligence/soma-relay")!)
                } footer: {
                    if AppConfig.demoAllowed, !model.usesRealCore {
                        Text("Version de test : chiffrement classique uniquement, pas encore post-quantique.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(DS.label) }
                        .accessibilityLabel("Fermer")
                }
            }
            .onAppear {
                name = model.displayName
                nodeDraft = model.nodeURL
            }
            .sheet(isPresented: $showExport) {
                ExportPassphraseSheet { url in exportURL = url }
            }
            .confirmationDialog("Tout effacer maintenant ?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Effacer clés, messages et médias", role: .destructive) {
                    Haptics.warning()
                    model.wipe()
                }
            } message: {
                Text("Ton identité disparaît de ce téléphone. Sans export, personne ne pourra la récupérer.")
            }
        }
    }

    /// Turning the lock on or off needs one successful unlock.
    private func setLock(_ on: Bool) {
        guard !lockChanging else { return }
        lockChanging = true
        Task {
            defer { lockChanging = false }
            let done = on ? await model.lock.enable() : await model.lock.disable()
            if done {
                Haptics.success()
            } else {
                model.banner = on ? "Verrouillage non activé : le déverrouillage a échoué." : "Verrouillage toujours actif : le déverrouillage a échoué."
            }
        }
    }

    private var nodeStatus: String {
        switch model.nodeState {
        case .ready: "connecté"
        case .connecting: "connexion…"
        case .authenticating: "authentification…"
        case .off: "arrêté"
        case .failed: "injoignable"
        }
    }

    private func applyNode() {
        var text = nodeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasPrefix("http") { text = "https://" + text }
        guard let url = URL(string: text), url.host() != nil else {
            model.banner = "Adresse de nœud invalide."
            return
        }
        nodeDraft = text
        model.nodeURL = text
        Haptics.success()
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}

/// "Protéger avec un passkey": sets up the backup, then shows where it stands. Pending or failed:
/// a tap tries the upload again.
private struct VaultRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let vault = model.vault
        switch vault.status {
        case .off, .failed:
            // `.failed` offers the setup too: a missing passkey or key can only be fixed by making
            // a new one. Other upload retries come from the next save or node connection.
            Button {
                Task {
                    do {
                        _ = try await vault.setUp(userName: model.passkeyUserName)
                        Haptics.success()
                    } catch {
                        Haptics.warning()
                        model.banner = VaultSync.message(setup: error)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Label("Protéger avec un passkey", systemImage: "person.badge.key")
                        if vault.busy { Spacer(); ProgressView() }
                    }
                    if case .failed(let message) = vault.status {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .disabled(vault.busy || !model.vaultCanSeal)
            .accessibilityIdentifier("vault.status")
        case .pending:
            Button {
                Task { await vault.flush() }
            } label: {
                status(vault)
            }
            .accessibilityHint("Réessaie la sauvegarde")
            .accessibilityIdentifier("vault.status")
        case .saved, .lockOnly:
            status(vault)
                .accessibilityIdentifier("vault.status")
        }
    }

    private func status(_ vault: VaultSync) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Protéger avec un passkey", systemImage: "person.badge.key")
                .foregroundStyle(Theme.text)
            Text(vault.statusText)
                .font(.footnote)
                .foregroundStyle(isFailure(vault.status) ? Theme.danger : Theme.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func isFailure(_ status: VaultSync.VaultStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }
}

/// Passphrase for a `.relaykey` export: typed twice, at least 10 characters.
private struct ExportPassphraseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onExported: (URL) -> Void
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var sealing = false
    @State private var failed = false
    @FocusState private var focus: Field?

    private enum Field { case passphrase, confirmation }

    private var tooShort: Bool { passphrase.count < RelayCoreFactory.exportMinPassphrase }
    private var mismatch: Bool { !confirmation.isEmpty && confirmation != passphrase }
    private var canExport: Bool { !tooShort && confirmation == passphrase && !sealing }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Phrase de passe", text: $passphrase)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .passphrase)
                        .submitLabel(.next)
                        .onSubmit { focus = .confirmation }
                        .accessibilityLabel("Phrase de passe")
                    SecureField("Confirmation", text: $confirmation)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .confirmation)
                        .submitLabel(.done)
                        .onSubmit(export)
                        .accessibilityLabel("Confirmation de la phrase de passe")
                } footer: {
                    if mismatch {
                        Text("Les deux phrases ne correspondent pas.").foregroundStyle(Theme.danger)
                    } else if failed {
                        Text("L'export a échoué. Réessaie.").foregroundStyle(Theme.danger)
                    } else {
                        Text("Au moins \(RelayCoreFactory.exportMinPassphrase) caractères. Elle te sera demandée pour restaurer ce fichier. Sans elle, personne ne peut l'ouvrir, pas même nous.")
                    }
                }
                Section {
                    Button(action: export) {
                        HStack {
                            Text(sealing ? "Chiffrement…" : "Chiffrer et exporter")
                            if sealing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!canExport)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Exporter l'identité")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
            .onAppear { focus = .passphrase }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(sealing)
    }

    private func export() {
        guard canExport else { return }
        sealing = true
        failed = false
        Task {
            let url = await model.exportIdentity(passphrase: passphrase)
            sealing = false
            if let url {
                Haptics.success()
                onExported(url)
                dismiss()
            } else {
                failed = true
            }
        }
    }
}
