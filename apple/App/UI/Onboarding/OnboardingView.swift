import SwiftUI

/// Name, identity creation (post-quantum keys), the passkey step (skippable), then the QR card.
/// Or a restore: from a passkey (the backup on the node), or from a `.relaykey` file.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = Step.welcome
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var showImporter = false
    @State private var importText = ""
    @State private var passphrase = ""
    @State private var restoring = false
    @State private var restoringPasskey = false
    @State private var restoreError: String?
    @FocusState private var passphraseFocused: Bool
    @State private var protecting = false
    @State private var passkeyError: String?

    enum Step: Int { case welcome, name, creating, passkey, card, restore }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .welcome: welcome
            case .name: nameStep
            case .creating: creating
            case .passkey: passkeyStep
            case .card: card
            case .restore: restoreStep
            }
        }
        .padding(.horizontal, 24)
        .animation(.smooth(duration: 0.35), value: step)
        .onAppear {
            switch DemoData.screen {
            case "onboarding-card": name = "Quentin"; create(offerPasskey: false)
            case "onboarding-name": name = "Quentin"; step = .name
            case "onboarding-passkey": step = .passkey
            case "onboarding-restore": step = .restore
            default: break
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            pickedFile(url)
        }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            BrandIcon(size: 112)
                .background { BrandHalo().frame(width: 560, height: 560) }
                .padding(.bottom, 28)
            Text("Soma Relay")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(DS.label)
            Text("Tes messages passent de téléphone en téléphone, même sans réseau.")
                .font(DS.TextStyle.title3.weight(.regular))
                .foregroundStyle(DS.label2)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 22) {
                feature("point.3.connected.trianglepath.dotted", "Sans réseau", "Bluetooth et Wi-Fi direct entre téléphones proches.")
                feature("lock.shield.fill", "Chiffré pour de bon", "De bout en bout, post-quantique. Personne d'autre ne lit.")
                feature("person.crop.circle", "Ni numéro, ni e-mail", "Juste une clé qui reste sur ton téléphone.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 24)
            primary("Créer mon identité", disabled: restoring) { step = .name }
                .accessibilityIdentifier("onboarding.start")
            Button {
                restoreWithPasskey()
            } label: {
                HStack(spacing: 8) {
                    if restoringPasskey { ProgressView() }
                    Text(restoringPasskey ? "Restauration…" : "Restaurer avec un passkey")
                }
            }
            .buttonStyle(.dsSecondary)
            .disabled(restoring)
            .accessibilityLabel("Restaurer avec un passkey")
            .padding(.top, 12)
            Button {
                restoreError = nil
                showImporter = true
            } label: {
                Text("Restaurer depuis un fichier")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.label2)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(restoring)
            .accessibilityLabel("Restaurer depuis un fichier")
            .padding(.top, 4)
            if let restoreError, step == .welcome {
                Text(restoreError)
                    .font(DS.TextStyle.footnote)
                    .foregroundStyle(DS.danger)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 4)
            }
            Text("Code ouvert sous licence AGPL")
                .font(DS.TextStyle.footnote)
                .foregroundStyle(DS.label3)
                .padding(.bottom, 8)
        }
        .transition(.opacity)
    }

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            DSIconTile(systemName: icon, size: 48, fill: DS.cell, foreground: DS.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.TextStyle.headline)
                    .foregroundStyle(DS.label)
                Text(text)
                    .font(DS.TextStyle.subheadline)
                    .foregroundStyle(DS.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Title and explanation at the top of a step.
    private func stepHeader(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(DS.TextStyle.largeTitle)
                .foregroundStyle(DS.label)
                .fixedSize(horizontal: false, vertical: true)
            Text(text)
                .font(DS.TextStyle.body)
                .foregroundStyle(DS.label2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A single-field card of the steps (prénom, phrase de passe).
    private func fieldCard<Field: View>(@ViewBuilder _ field: () -> Field) -> some View {
        field()
            .font(DS.TextStyle.title3.weight(.regular))
            .foregroundStyle(DS.label)
            .padding(.horizontal, DS.Space.cell + 2)
            .frame(height: 58)
            .dsCard()
    }

    /// Quiet text action under the main button ("Plus tard", "Retour").
    private func quiet(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.TextStyle.headline)
                .foregroundStyle(DS.label)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer().frame(height: 40)
            stepHeader("Comment on t'appelle ?", "Ton prénom ou un surnom. Il voyage avec ta carte, tu peux le changer quand tu veux.")
            fieldCard {
                TextField("Prénom", text: $name)
                    .textContentType(.givenName)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit(create)
                    .accessibilityLabel("Ton prénom")
            }
            .padding(.top, 8)
            Spacer()
            primary("Créer mon identité", disabled: name.trimmingCharacters(in: .whitespaces).isEmpty, action: create)
                .padding(.bottom, 12)
        }
        .onAppear { nameFocused = true }
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
    }

    private var creating: some View {
        VStack(spacing: 22) {
            Spacer()
            CipherQRCode(stage: .connecting)
                .frame(width: 220)
            Text("Génération de tes clés")
                .font(DS.TextStyle.title2)
                .foregroundStyle(DS.label)
            Text("ML-KEM-1024 + X25519 · ML-DSA-87 + Ed25519")
                .font(DS.TextStyle.footnote)
                .foregroundStyle(DS.label2)
            Spacer()
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    private var card: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 24)
            Text("Ta carte est prête")
                .font(DS.TextStyle.largeTitle)
                .foregroundStyle(DS.label)
            Text("Fais scanner ce QR pour qu'on t'ajoute. Ta clé ne quitte jamais ce téléphone.")
                .font(DS.TextStyle.body)
                .foregroundStyle(DS.label2)
                .multilineTextAlignment(.center)
            if let link = model.myCompactLink {
                CipherQRCode(stage: .code(link))
                    .frame(maxWidth: 280)
                    .accessibilityLabel("QR de ta carte de contact")
            }
            if let core = model.core {
                VStack(spacing: 6) {
                    Text(core.fingerprintHex().groupedFingerprint(groups: 4))
                        .font(DS.TextStyle.fingerprint(14))
                        .foregroundStyle(DS.label)
                    Text(core.safetyWords().joined(separator: " · "))
                        .font(DS.TextStyle.subheadline)
                        .foregroundStyle(DS.label2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Ton empreinte")
            }
            Spacer()
            primary("C'est parti") { model.finishOnboarding() }
                .padding(.bottom, 12)
        }
        .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
    }

    private func primary(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            // Dark text on lime (white on lime failed contrast).
            Text(title)
        }
        .buttonStyle(.dsPrimary)
        .disabled(disabled)
    }

    /// Shown only for a `relaystate2:` file: the passphrase it was sealed with.
    private var restoreStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer().frame(height: 40)
            stepHeader("Phrase de passe", "Ce fichier est chiffré. Saisis la phrase de passe choisie lors de l'export.")
            fieldCard {
                SecureField("Phrase de passe", text: $passphrase)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($passphraseFocused)
                    .onSubmit { restore(passphrase: passphrase) }
                    .accessibilityLabel("Phrase de passe du fichier")
            }
            .padding(.top, 8)
            if let restoreError {
                Text(restoreError)
                    .font(DS.TextStyle.footnote)
                    .foregroundStyle(DS.danger)
            }
            Spacer()
            primary(restoring ? "Déchiffrement…" : "Restaurer", disabled: passphrase.isEmpty || restoring) {
                restore(passphrase: passphrase)
            }
            quiet("Retour") {
                passphrase = ""
                importText = ""
                restoreError = nil
                step = .welcome
            }
            .disabled(restoring)
            .padding(.bottom, 12)
        }
        .onAppear { passphraseFocused = true }
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
    }

    private func pickedFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // A .relaykey is a short text line; refuse anything large before reading it as text.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 4 * 1024 * 1024, let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            restoreError = ExportError.unreadable.message
            return
        }
        importText = text
        if ExportError.needsPassphrase(text) {
            passphrase = ""
            restoreError = nil
            step = .restore
        } else {
            restore(passphrase: nil)
        }
    }

    private func restore(passphrase: String?) {
        guard !restoring, !importText.isEmpty else { return }
        restoring = true
        restoreError = nil
        Task {
            defer { restoring = false }
            do {
                try await model.importIdentity(text: importText, passphrase: passphrase)
                importText = ""
                self.passphrase = ""
                Haptics.success()
                model.finishOnboarding()
            } catch {
                Haptics.warning()
                restoreError = error.message
            }
        }
    }

    /// New phone: the passkey (here or on another device) opens the backup on the node.
    private func restoreWithPasskey() {
        guard !restoring else { return }
        restoring = true
        restoringPasskey = true
        restoreError = nil
        Task {
            defer {
                restoring = false
                restoringPasskey = false
            }
            do throws(PasskeyRestoreError) {
                try await model.restoreFromPasskey()
                Haptics.success()
                model.banner = AppModel.restoredBanner
                model.finishOnboarding()
            } catch {
                if error != .cancelled { Haptics.warning() }
                restoreError = error.message
            }
        }
    }

    private func create() { create(offerPasskey: true) }

    private func create(offerPasskey: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        nameFocused = false
        step = .creating
        Task {
            let started = Date()
            await model.createIdentity(name: trimmed)
            // Let the cipher play a moment: the user should see that keys were made.
            let wait = max(0, 1.4 - Date().timeIntervalSince(started))
            try? await Task.sleep(for: .seconds(wait))
            Haptics.success()
            step = offerPasskey && model.vaultCanSeal ? .passkey : .card
        }
    }

    /// After the keys: one passkey locks Relay and encrypts the backup on the node. Skippable.
    private var passkeyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer().frame(height: 40)
            DSIconTile(systemName: "key.fill", size: 64, fill: DS.accentSoft, foreground: DS.accent)
            stepHeader("Protéger avec un passkey", "Ton passkey verrouille Relay et chiffre une sauvegarde de ton identité sur le nœud. Le nœud ne peut pas la lire. Sur un nouveau téléphone, ce même passkey la restaure.")
            if let passkeyError {
                Text(passkeyError)
                    .font(DS.TextStyle.footnote)
                    .foregroundStyle(DS.danger)
            }
            Spacer()
            primary(protecting ? "Création…" : "Créer un passkey", disabled: protecting, action: protect)
            quiet("Plus tard") {
                passkeyError = nil
                step = .card
            }
            .disabled(protecting)
            .padding(.bottom, 12)
        }
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
    }

    private func protect() {
        guard !protecting else { return }
        protecting = true
        passkeyError = nil
        Task {
            defer { protecting = false }
            do {
                // The person chose the passkey: the lock goes on through the setup's own
                // assertion (two system prompts in all: create, then one assertion).
                _ = try await model.vault.setUp(userName: model.passkeyUserName, enableLock: true)
                Haptics.success()
                step = .card
            } catch {
                Haptics.warning()
                passkeyError = VaultSync.message(setup: error)
            }
        }
    }
}
