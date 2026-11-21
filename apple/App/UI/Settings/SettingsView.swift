import SwiftUI

/// Node, identity, visibility, safety words, export and emergency wipe.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var nodeDraft = ""
    @State private var publishing = false
    @State private var confirmWipe = false
    @State private var exportURL: URL?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Avatar(name: model.displayName, size: 56, tint: Theme.mesh.opacity(0.25))
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
                    Toggle("Visible à proximité", isOn: $model.visibleNearby)
                    LabeledContent("Téléphones reliés", value: "\(model.meshPeerCount)")
                } header: {
                    Text("Mesh")
                } footer: {
                    Text("Bluetooth et Wi-Fi direct, sans Internet. Visible : les téléphones proches voient ton nom et peuvent t'ajouter. Invisible : tu relaies quand même les messages des autres, sans pouvoir les lire.")
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
                    Button("Exporter mon identité", systemImage: "square.and.arrow.up") {
                        exportURL = model.exportIdentity()
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Enregistrer le fichier", systemImage: "doc.badge.arrow.up")
                        }
                    }
                } header: {
                    Text("Sauvegarde")
                } footer: {
                    Text("Le fichier contient ta clé privée. Garde-le dans un endroit sûr, jamais dans une conversation.")
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
            .onAppear {
                name = model.displayName
                nodeDraft = model.nodeURL
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
