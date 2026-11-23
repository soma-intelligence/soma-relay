import SwiftUI

/// Réglages (relay-screens 12), a sheet from the avatar: the profile card on top, then grouped
/// sections (Sécurité, Confidentialité, Notifications, Réseau, Sauvegarde, Avancé) and the
/// emergency wipe alone at the bottom. Name, photo, pseudo and the personal words live on the
/// profile page; the node address on its own page.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmWipe = false
    @State private var exportURL: URL?
    @State private var showExport = false
    @State private var lockChanging = false
    @State private var path: [Page] = []

    enum Page: Hashable { case profile, node }

    private static let inset: CGFloat = 60

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: DS.Space.group) {
                    profileCard
                    security(lock: model.lock)
                    privacy(model: model)
                    notifications(model: model)
                    network(model: model)
                    backup
                    advanced
                    danger
                    Text(model.usesRealCore ? "Soma Relay · ML-KEM-1024 + X25519 · code ouvert AGPL" : "Soma Relay · code ouvert AGPL")
                        .font(DS.TextStyle.footnote)
                        .foregroundStyle(DS.label3)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Space.margin)
                        .padding(.top, 4)
                        .id("settings.end")
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .onAppear {
                switch DemoData.screen {
                case "settings-end": proxy.scrollTo("settings.end", anchor: .bottom)
                case "settings-profile": path = [.profile]
                case "settings-node": path = [.node]
                case "settings-export": showExport = true
                default: break
                }
            }
            }
            .background(DS.background)
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer", systemImage: "xmark") { dismiss() }
                        .tint(DS.label)
                }
            }
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .profile: ProfileSettingsView()
                case .node: NodeSettingsView()
                }
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

    // MARK: Profile

    private var profileCard: some View {
        NavigationLink(value: Page.profile) {
            HStack(spacing: 14) {
                DSAvatar(name: model.displayName, size: 60, photo: model.photos[AppModel.me])
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(DS.label)
                        .lineLimit(1)
                    Text(model.handle.isEmpty ? "Nom, photo et tes mots" : "@\(model.handle) · nom, photo et tes mots")
                        .font(.system(size: 14))
                        .foregroundStyle(DS.label2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                DSChevron()
            }
            .padding(.horizontal, DS.Space.cell)
            .padding(.vertical, 14)
            .dsCard()
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.cell, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.Space.margin)
        .accessibilityLabel("Profil, \(model.displayName)")
        .accessibilityHint("Nom, photo, pseudo et tes mots")
        .accessibilityIdentifier("settings.profile")
    }

    // MARK: Sections

    private func security(lock: LockController) -> some View {
        @Bindable var lock = lock
        return DSSection(header: "Sécurité") {
            DSRow(first: true, separatorInset: Self.inset) {
                Toggle(isOn: Binding(get: { model.lock.enabled }, set: setLock)) {
                    DSTileLabel(systemName: "lock.fill", title: "Verrouiller Relay", tile: DS.Tile.red)
                }
                .tint(DS.accentFill)
                .disabled(lockChanging)
            }
            if model.lock.enabled {
                DSRow(separatorInset: Self.inset) {
                    DSTileLabel(systemName: "timer", title: "Verrouiller après", tile: DS.Tile.red)
                    Spacer(minLength: 0)
                    Picker("Verrouiller après", selection: $lock.delay) {
                        ForEach(RelockDelay.allCases) { delay in
                            Text(delay.title).tag(delay)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(DS.label2)
                }
            }
            DSRow(separatorInset: Self.inset) {
                VaultRow()
            }
        } footer: {
            Text("Clé d'accès, Face ID ou code à l'ouverture. Le passkey chiffre aussi une sauvegarde sur le nœud, qui ne peut pas la lire.")
        }
    }

    private func privacy(model: AppModel) -> some View {
        @Bindable var model = model
        return DSSection(header: "Confidentialité") {
            DSRow(first: true, separatorInset: Self.inset) {
                Toggle(isOn: $model.linkPreviews) {
                    DSTileLabel(systemName: "link", title: "Aperçus des liens", tile: DS.Tile.grey)
                }
                .tint(DS.accentFill)
            }
        } footer: {
            Text("Ton téléphone prépare l'aperçu, ton contact ne charge rien. Ta visibilité se règle dans À proximité.")
        }
    }

    private func notifications(model: AppModel) -> some View {
        @Bindable var model = model
        return DSSection(header: "Notifications") {
            DSRow(first: true, separatorInset: Self.inset) {
                Toggle(isOn: $model.notificationPreviews) {
                    DSTileLabel(systemName: "bell.fill", title: "Aperçus dans les notifications", tile: DS.Tile.purple)
                }
                .tint(DS.accentFill)
            }
            DSRow(separatorInset: Self.inset) {
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    HStack(spacing: 0) {
                        DSTileLabel(systemName: "bell.badge.fill", title: "Réglages des notifications iOS", tile: DS.Tile.purple)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.label3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } footer: {
            Text("Sans aperçu : « Nouveau message », sans nom ni texte.")
        }
    }

    private func network(model: AppModel) -> some View {
        @Bindable var model = model
        return DSSection(header: "Réseau") {
            DSRow(first: true, separatorInset: Self.inset) {
                DSTileLabel(systemName: "dot.radiowaves.left.and.right", title: "Mesh", tile: DS.Tile.green)
                Spacer(minLength: 8)
                DSRowValue(text: Self.phones(model.meshPeerCount), dot: model.meshPeerCount > 0)
            }
            .accessibilityElement(children: .combine)
            DSRow(separatorInset: Self.inset) {
                Toggle(isOn: $model.nodeEnabled) {
                    DSTileLabel(systemName: "globe", title: "Utiliser un nœud", tile: DS.Tile.teal)
                }
                .tint(DS.accentFill)
            }
            if model.nodeEnabled {
                DSRow(minHeight: 60, separatorInset: Self.inset) {
                    NavigationLink(value: Page.node) {
                        HStack(spacing: 8) {
                            DSTileLabel(systemName: "server.rack", title: "Nœud", subtitle: Self.host(model.nodeURL), tile: DS.Tile.teal)
                            Spacer(minLength: 8)
                            DSRowValue(text: Self.nodeStatus(model.nodeState), dot: model.nodeState == .ready)
                            DSChevron()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.node")
                }
            }
        } footer: {
            Text("Le nœud garde tes messages chiffrés quand tu es hors ligne, sans pouvoir les lire.")
        }
    }

    private var backup: some View {
        DSSection(header: "Sauvegarde") {
            DSRow(first: true, separatorInset: Self.inset) {
                Button {
                    exportURL = nil
                    showExport = true
                } label: {
                    HStack(spacing: 0) {
                        DSTileLabel(systemName: "square.and.arrow.up", title: "Exporter mon identité", tile: DS.Tile.grey)
                        Spacer(minLength: 8)
                        DSChevron()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Exporter mon identité")
            }
            if let exportURL {
                DSRow(separatorInset: Self.inset) {
                    ShareLink(item: exportURL) {
                        HStack(spacing: 0) {
                            DSTileLabel(systemName: "doc.badge.arrow.up", title: "Enregistrer le fichier", tile: DS.Tile.indigo)
                            Spacer(minLength: 8)
                            DSChevron()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } footer: {
            Text("Un fichier .relaykey chiffré par une phrase de passe. Garde-le hors des conversations.")
        }
    }

    private var advanced: some View {
        DSSection(header: "Avancé") {
            DSRow(first: true, separatorInset: Self.inset) {
                DSTileLabel(systemName: "cpu", title: "Cœur", tile: DS.Tile.grey)
                Spacer(minLength: 8)
                DSRowValue(text: model.usesRealCore ? "relay-core (Rust)" : "test (CryptoKit)")
            }
            .accessibilityElement(children: .combine)
            DSRow(separatorInset: Self.inset) {
                DSTileLabel(systemName: "info.circle", title: "Version", tile: DS.Tile.grey)
                Spacer(minLength: 8)
                DSRowValue(text: Self.version)
            }
            .accessibilityElement(children: .combine)
            DSRow(separatorInset: Self.inset) {
                Link(destination: URL(string: "https://github.com/soma-intelligence/soma-relay")!) {
                    HStack(spacing: 0) {
                        DSTileLabel(systemName: "chevron.left.forwardslash.chevron.right", title: "Code source (AGPL-3.0)", tile: DS.Tile.grey)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.label3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } footer: {
            if AppConfig.demoAllowed, !model.usesRealCore {
                Text("Version de test : chiffrement classique uniquement, pas encore post-quantique.")
            }
        }
    }

    private var danger: some View {
        DSSection {
            DSRow(first: true) {
                Button(role: .destructive) {
                    confirmWipe = true
                } label: {
                    HStack(spacing: 0) {
                        DSTileLabel(
                            systemName: "exclamationmark.triangle.fill", title: "Effacement d'urgence",
                            tile: DS.Tile.danger, glyph: DS.danger, titleColor: DS.danger)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Effacement d'urgence")
            }
        } footer: {
            Text("Efface clés, messages et médias de ce téléphone. Irréversible.")
        }
    }

    // MARK: Actions and values

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

    static func phones(_ count: Int) -> String {
        switch count {
        case 0: "Aucun téléphone"
        case 1: "1 téléphone"
        default: "\(count) téléphones"
        }
    }

    static func host(_ url: String) -> String { URL(string: url)?.host() ?? url }

    static func nodeStatus(_ state: NodeClient.State) -> String {
        switch state {
        case .ready: "Connecté"
        case .connecting: "Connexion…"
        case .authenticating: "Authentification…"
        case .off: "Arrêté"
        case .failed: "Injoignable"
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}

// MARK: Profile page

/// Name and photo, the pseudo in the directory (with a node), and the personal words.
private struct ProfileSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var publishing = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(spacing: DS.Space.group) {
                EditablePhoto(name: model.displayName, photo: model.photos[AppModel.me], size: 96, cropTitle: "Ta photo") { image in
                    model.setMyPhoto(image)
                }
                .padding(.top, 8)
                DSSection(header: "Nom") {
                    DSRow(first: true) {
                        TextField("Ton nom", text: $name)
                            .font(DS.TextStyle.body)
                            .foregroundStyle(DS.label)
                            .onSubmit { model.setDisplayName(name) }
                            .submitLabel(.done)
                            .accessibilityLabel("Nom affiché")
                    }
                } footer: {
                    Text("Ta photo et ton nom partent chiffrés à tes contacts et à tes groupes, une fois à chaque changement.")
                }
                if model.nodeEnabled {
                    DSSection(header: "Pseudo") {
                        DSRow(first: true) {
                            TextField("pseudo", text: $model.handle)
                                .font(DS.TextStyle.body)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Text("@" + SettingsView.host(model.nodeURL))
                                .font(DS.TextStyle.footnote)
                                .foregroundStyle(DS.label2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        DSRow {
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
                                        .font(DS.TextStyle.body)
                                        .foregroundStyle(DS.accent)
                                    Spacer(minLength: 0)
                                    if publishing { ProgressView() }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.handle.count < 3 || publishing || model.nodeState != .ready)
                            .opacity(model.handle.count < 3 || model.nodeState != .ready ? 0.45 : 1)
                        }
                    } footer: {
                        Text("Facultatif. On peut te trouver par pseudo@nœud, sans numéro ni e-mail.")
                    }
                }
                if let core = model.core {
                    DSSection(header: "Tes mots") {
                        VStack(alignment: .leading, spacing: 12) {
                            DSWordGrid(words: core.safetyWords())
                            Text(core.fingerprintHex().groupedFingerprint(groups: 4))
                                .font(DS.TextStyle.fingerprint(12))
                                .foregroundStyle(DS.label2)
                                .textSelection(.enabled)
                                .accessibilityLabel("Ton empreinte")
                        }
                        .padding(DS.Space.cell)
                    } footer: {
                        Text("Ils résument ta clé publique. Pour vérifier un contact, compare plutôt les mots de sa fiche : ils dépendent de vos deux clés.")
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .background(DS.background)
        .navigationTitle("Profil")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = model.displayName }
    }
}

// MARK: Node page

/// The node address, its state, and the way back to the default node.
private struct NodeSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var nodeDraft = ""

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.group) {
                DSSection(header: "Adresse") {
                    DSRow(first: true) {
                        TextField(AppConfig.defaultNodeURL, text: $nodeDraft)
                            .font(DS.TextStyle.body)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(applyNode)
                            .accessibilityLabel("Adresse du nœud")
                    }
                    DSRow {
                        Text("État").font(DS.TextStyle.body).foregroundStyle(DS.label)
                        Spacer(minLength: 8)
                        DSRowValue(text: SettingsView.nodeStatus(model.nodeState), dot: model.nodeState == .ready)
                    }
                    .accessibilityElement(children: .combine)
                } footer: {
                    Text("Un nœud garde tes messages chiffrés quand tu es hors ligne. Il ne peut pas les lire. Tu peux héberger le tien.")
                }
                VStack(spacing: 12) {
                    if nodeDraft != model.nodeURL {
                        Button("Utiliser ce nœud", action: applyNode)
                            .buttonStyle(.dsPrimary)
                    }
                    if nodeDraft != AppModel.defaultNodeURL {
                        Button("Revenir au nœud par défaut") {
                            nodeDraft = AppModel.defaultNodeURL
                            applyNode()
                        }
                        .buttonStyle(.dsSecondary)
                    }
                }
                .padding(.horizontal, DS.Space.margin)
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(DS.background)
        .navigationTitle("Nœud")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { nodeDraft = model.nodeURL }
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
}

// MARK: Passkey row

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
                HStack(spacing: 8) {
                    label(vault, subtitle: failureMessage(vault.status))
                    Spacer(minLength: 0)
                    if vault.busy { ProgressView() } else { DSChevron() }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(vault.busy || !model.vaultCanSeal)
            .opacity(model.vaultCanSeal ? 1 : 0.45)
            .accessibilityIdentifier("vault.status")
        case .pending:
            Button {
                Task { await vault.flush() }
            } label: {
                label(vault, subtitle: vault.statusText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Réessaie la sauvegarde")
            .accessibilityIdentifier("vault.status")
        case .saved, .lockOnly:
            label(vault, subtitle: vault.statusText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("vault.status")
        }
    }

    private func label(_ vault: VaultSync, subtitle: String?) -> some View {
        HStack(spacing: 14) {
            DSIconTile(systemName: "key.fill", size: 30, fill: DS.Tile.indigo, foreground: .white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Protéger avec un passkey")
                    .font(DS.TextStyle.body)
                    .foregroundStyle(DS.label)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DS.TextStyle.footnote)
                        .foregroundStyle(isFailure(vault.status) ? DS.danger : DS.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func failureMessage(_ status: VaultSync.VaultStatus) -> String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    private func isFailure(_ status: VaultSync.VaultStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }
}

// MARK: Export

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
            ScrollView {
                VStack(spacing: DS.Space.group) {
                    DSSection {
                        DSRow(first: true) {
                            SecureField("Phrase de passe", text: $passphrase)
                                .font(DS.TextStyle.body)
                                .textContentType(.newPassword)
                                .focused($focus, equals: .passphrase)
                                .submitLabel(.next)
                                .onSubmit { focus = .confirmation }
                                .accessibilityLabel("Phrase de passe")
                        }
                        DSRow {
                            SecureField("Confirmation", text: $confirmation)
                                .font(DS.TextStyle.body)
                                .textContentType(.newPassword)
                                .focused($focus, equals: .confirmation)
                                .submitLabel(.done)
                                .onSubmit(export)
                                .accessibilityLabel("Confirmation de la phrase de passe")
                        }
                    } footer: {
                        if mismatch {
                            Text("Les deux phrases ne correspondent pas.").foregroundStyle(DS.danger)
                        } else if failed {
                            Text("L'export a échoué. Réessaie.").foregroundStyle(DS.danger)
                        } else {
                            Text("Au moins \(RelayCoreFactory.exportMinPassphrase) caractères. Elle te sera demandée pour restaurer ce fichier. Sans elle, personne ne peut l'ouvrir, pas même nous.")
                        }
                    }
                    Button(action: export) {
                        HStack(spacing: 8) {
                            if sealing { ProgressView().tint(DS.onAccent) }
                            Text(sealing ? "Chiffrement…" : "Chiffrer et exporter")
                        }
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(!canExport)
                    .padding(.horizontal, DS.Space.margin)
                }
                .padding(.top, 8)
            }
            .background(DS.background)
            .navigationTitle("Exporter l'identité")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                        .tint(DS.label)
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
